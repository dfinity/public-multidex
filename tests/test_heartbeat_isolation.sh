#!/bin/bash
# W3-08 — a trapping heartbeat subtask cannot take the beat down.
#
# Nine subtasks used to run INLINE in the heartbeat: one trap killed the
# whole beat message and every subtask after it, permanently. They now run
# as isolated self-sends (hbRun) behind a dispatch/completion breaker with
# geometric backoff (mirror of the liquidation breaker).
#
#   §1 baseline: beats advance; subtask completions accrue
#   §2 forced trap in the every-beat "drain" subtask: the BEAT keeps
#      advancing, other subtasks keep completing, the streak grows, and
#      the breaker backs the trapping task off (dispatches ≪ beats)
#   §3 clearing the trap: the subtask recovers and its streak resets
#   §4 #47.1 — the dead-man sweep outruns the timer brake: an armed
#      cancelAllAfter still fires while setTestTimersPaused(true) is set
#      (the dispatch sits ABOVE the pause gate), and the armed-status
#      surfaces (getMyCancelAllAfter / getAccessPolicy / whyAmIRefused)
#      cross-reference the brake as timersPaused
#   §5 H-09 (D7, extension of W3-08): the finaliser is dispatched through
#      the breaker too (hbRunAsync "finalise") — a forced trap leaves the
#      beat and its siblings alive, grows its streak, backs it off, recovers
#   §6 H-09 (D7): the AMM tick is dispatched PER MARKET ("amm:<marketId>")
#      — a forced trap in one market's requote/release leaves the OTHER
#      market serviced on the next beat, backs only the trapping market off,
#      and recovers when cleared
#
# Needs #dev (setTestHbTrap) and RUNNING timers; §6 needs ≥2 AMM pools
# (creates BTC-ICPUSD when the venue holds only one).

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }

hb() { adm getCanisterInfo '()' --query | tr -d '_\n' | tr -s ' ' | grep -oE "lastHeartbeatNs = [0-9-]+" | awk '{print $3}'; }
field() { # field <name> <subtask>  from getHbHealth
  adm getHbHealth '()' --query | tr -d '_\n' | tr -s ' ' | grep -oE "\"$2\"; record \{[^}]*" | grep -oE "$1 = [0-9]+" | awk '{print $3}';
}

wait_streak0() { # wait_streak0 <subtask> <maxsecs> — poll until the breaker reports streak 0 (a completed run)
  local i=0 n=$(( $2 / 2 ))
  while [ "$i" -lt "$n" ]; do
    [ "$(field streak "$1")" = "0" ] && return 0
    sleep 2; i=$((i+1))
  done
  return 1
}

adm setTestTimersPaused '(false)' >/dev/null 2>&1

echo "── §1 baseline: beats + completions ──"
H0=$(hb); sleep 3; H1=$(hb)
[ "${H1:-0}" != "${H0:-0}" ] && ok "heartbeat advancing" || nok "heartbeat stalled before the test" "h0=$H0 h1=$H1"
D0=$(field completions drain); sleep 2; D1=$(field completions drain)
[ "${D1:-0}" -gt "${D0:-0}" ] && ok "drain subtask completing (isolated dispatch works)" || nok "drain not completing" "d0=$D0 d1=$D1"

echo "── §2 a trapping subtask leaves the beat + siblings alive ──"
adm setTestHbTrap '(opt "drain")' >/dev/null
sleep 6
H2=$(hb); sleep 3; H3=$(hb)
[ "${H3:-0}" != "${H2:-0}" ] && ok "beat still advancing with 'drain' trapping every run" || nok "trap took the heartbeat down (the finding)" "h2=$H2 h3=$H3"
S=$(field streak drain)
[ "${S:-0}" -ge 1 ] && ok "breaker sees the failures (streak=$S)" || nok "streak not growing" "s=$S"
A0=$(field completions arrears); sleep 3; A1=$(field completions arrears)
[ "${A1:-0}" -gt "${A0:-0}" ] && ok "sibling subtask (arrears) still completing" || nok "sibling starved" "a0=$A0 a1=$A1"
DD0=$(field dispatches drain); sleep 8; DD1=$(field dispatches drain)
DELTA=$(( DD1 - DD0 ))
if [ "$DELTA" -lt 8 ]; then ok "backoff engaged: $DELTA dispatches in 8s (an unbroken every-beat task would make ~8)"; else nok "no backoff" "delta=$DELTA"; fi

echo "── §3 clearing the trap recovers the subtask ──"
adm setTestHbTrap '(null)' >/dev/null
sleep 12
S2=$(field streak drain); C0=$(field completions drain); sleep 3; C1=$(field completions drain)
[ "${S2:-9}" = "0" ] && ok "streak reset on recovery" || nok "streak stuck" "s=$S2"
[ "${C1:-0}" -gt "${C0:-0}" ] && ok "drain completing again" || nok "no recovery" "c0=$C0 c1=$C1"

echo "── §4 the dead-man sweep outruns the timer brake (#47.1) ──"
# Arm a minimum-window switch as a non-anonymous user, then set the brake.
# The armed-status surfaces must cross-reference the brake, and the switch
# must STILL fire while braked: the deadman dispatch deliberately sits ABOVE
# the heartbeat pause gate (trading is not brake-gated, so a dead bot's
# orders stay liftable while braked — the switch is what bounds that).
ali() { icp canister call --candid "$MDX_CANDID" --identity alice backend "$@" 2>&1; }
ARM=$(ali cancelAllAfter '(opt (5 : nat))')
if mdx_ok "$ARM"; then ok "deadman armed (5s window)"; else nok "arm failed" "$ARM"; fi
adm setTestTimersPaused '(true)' >/dev/null
S1=$(ali getMyCancelAllAfter '()' --query | tr -d '_\n' | tr -s ' ')
if echo "$S1" | grep -q "timersPaused = true"; then ok "getMyCancelAllAfter cross-references the brake"; else nok "getMyCancelAllAfter silent about the brake" "$S1"; fi
AP=$(ali getAccessPolicy '()' --query | tr -d '_\n' | tr -s ' ')
if echo "$AP" | grep -q "myDeadmanArmed = true" && echo "$AP" | grep -q "timersPaused = true"; then
  ok "getAccessPolicy reports armed + brake"
else nok "getAccessPolicy missing armed/brake flags" "$AP"; fi
WR=$(ali whyAmIRefused '()' --query | tr -d '_\n' | tr -s ' ')
if echo "$WR" | grep -q "deadmanArmed = true" && echo "$WR" | grep -q "timersPaused = true"; then
  ok "whyAmIRefused reports armed + brake"
else nok "whyAmIRefused missing armed/brake flags" "$WR"; fi
sleep 9   # past the 5s window, with slack for the beat + isolated sweep
S2=$(ali getMyCancelAllAfter '()' --query | tr -d '\n' | tr -s ' ')
if echo "$S2" | grep -q "(null)"; then
  ok "switch FIRED while braked (entry swept by the heartbeat)"
else nok "switch did not fire under the brake (the #47.1 finding)" "$S2"; fi
adm setTestTimersPaused '(false)' >/dev/null

echo "── §5 H-09/D7: the finaliser runs behind the breaker ──"
# Pre-H-09 finaliseExpiredPending was a bare self-send from the beat: a trap
# rolled back removeDeferredExec and the same entry re-trapped at full 0.5s
# cadence forever, with no accounting anywhere. Dispatched through
# hbRunAsync("finalise") it gets the W3-08 isolation + breaker for free.
F0=$(field completions finalise); sleep 2; F1=$(field completions finalise)
[ "${F1:-0}" -gt "${F0:-0}" ] && ok "finalise subtask completing under the breaker" || nok "finalise has no breaker accounting (the H-09 gap)" "f0=$F0 f1=$F1"
adm setTestHbTrap '(opt "finalise")' >/dev/null
sleep 6
H4=$(hb); sleep 3; H5=$(hb)
[ "${H5:-0}" != "${H4:-0}" ] && ok "beat still advancing with 'finalise' trapping every run" || nok "finalise trap took the heartbeat down" "h4=$H4 h5=$H5"
SF=$(field streak finalise)
[ "${SF:-0}" -ge 1 ] && ok "breaker sees the finaliser's failures (streak=$SF)" || nok "finalise streak not growing" "s=$SF"
DR0=$(field completions drain); sleep 3; DR1=$(field completions drain)
[ "${DR1:-0}" -gt "${DR0:-0}" ] && ok "sibling subtask (drain) still completing" || nok "sibling starved by the finalise trap" "d0=$DR0 d1=$DR1"
FD0=$(field dispatches finalise); sleep 8; FD1=$(field dispatches finalise)
FDELTA=$(( FD1 - FD0 ))
if [ -n "${FD0:-}" ] && [ "$FDELTA" -lt 8 ]; then ok "backoff engaged: $FDELTA finalise dispatches in 8s (an unbroken 0.5s task would make ~16)"; else nok "no finalise backoff" "delta=$FDELTA"; fi
adm setTestHbTrap '(null)' >/dev/null
wait_streak0 finalise 40   # the backed-off cadence caps at 0.5s × 32 = 16s; the poll bounds the wait, not the guess
SF2=$(field streak finalise); FC0=$(field completions finalise); sleep 3; FC1=$(field completions finalise)
[ "${SF2:-9}" = "0" ] && ok "finalise streak reset on recovery" || nok "finalise streak stuck" "s=$SF2"
[ "${FC1:-0}" -gt "${FC0:-0}" ] && ok "finalise completing again" || nok "finalise did not recover" "c0=$FC0 c1=$FC1"

echo "── §6 H-09/D7: the AMM tick is dispatched per market ──"
# tickAmm used to requote every pool in ONE bare self-send: a trap in one
# market's requote/release rolled back every market's and re-trapped at full
# cadence, unaccounted. Each pool now runs as its own hbRun("amm:<marketId>")
# behind the breaker — one market's trap backs THAT market off and leaves the
# others serviced on the next beat.
#
# Fixture (task 1788654090, the 1788556083 self-provision class): the two
# pools this section and §7 pick must be PRICED and ENABLED, and the venue
# this suite inherits does not guarantee either. A wiping predecessor (the
# archive trio's resetExchange → Map.clear(pools)) leaves ONE pool, and a
# bare createAmmPool yields enabled = false, refPrice = 0; a predecessor's
# create-without-enable (ghsa_round4's quote-only genesis, oracle_time_bases,
# season_seal, …) leaves that same shape on a venue that already holds ≥ 2
# pools, so the < 2 branch alone would not cover it. §6 tolerates the shape
# (the heartbeat dispatches amm:<mkt> for EVERY pool in the map, enabled or
# not — the breaker accounting is what §6 reads), §7 does not: it needs
# refPrice > 0 for its bid, and the fetch it waits for (tickPriceRefresh)
# services enabled pools only. So, per picked pool, unconditionally:
# mdx_restamp_mark (_lib.sh — an unpriced pool pins to the live aggregate,
# primed by one admin fetch when the wipe cleared lastAggregates, the
# fallback below only on a feed-less venue; a priced pool KEEPS its mark,
# pend cleared, freshness re-stamped, so a seeded venue is never moved) then
# enableAmm(true), idempotent where the seed already did it. No inventory,
# no ladder config: neither section trades against the AMM.
POOLS=$(adm getAmmPools '()' --query | grep -oE 'marketId = "[^"]+"' | grep -oE '"[^"]+"' | tr -d '"')
NPOOLS=$(echo "$POOLS" | grep -c . || true)
if [ "${NPOOLS:-0}" -lt 2 ]; then
  adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
  adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
  POOLS=$(adm getAmmPools '()' --query | grep -oE 'marketId = "[^"]+"' | grep -oE '"[^"]+"' | tr -d '"')
  NPOOLS=$(echo "$POOLS" | grep -c . || true)
fi
PA=$(echo "$POOLS" | sed -n 1p); PB=$(echo "$POOLS" | sed -n 2p)
[ "${NPOOLS:-0}" -ge 2 ] && ok "fixture: $NPOOLS AMM pools (A=$PA, B=$PB)" || nok "fixture: §6 needs two AMM pools" "pools=$NPOOLS"
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
provision_mark() {   # <market> — price (restamp) + enable the pool; feed-less fallback by base
  local mkt="$1" base="${1%%-*}" fb pin en
  case "$base" in BTC) fb=$(e8 80000) ;; ETH) fb=$(e8 3000) ;; SOL) fb=$(e8 100) ;; *) fb=$(e8 5) ;; esac
  pin=$(mdx_restamp_mark "$base" "$mkt" "$fb") \
    && ok "fixture: $mkt marked at ${pin% *} (${pin#* })" \
    || nok "fixture: $mkt could not be marked" "no aggregate, no pool price, fallback refused"
  en=$(adm enableAmm "(\"$mkt\", true)")
  mdx_ok "$en" && ok "fixture: $mkt enabled" || nok "fixture: enableAmm $mkt" "$(echo "$en" | tr -s '[:space:]' ' ' | head -c 160)"
}
for mkt in $PA $PB; do provision_mark "$mkt"; done
PA0=$(field completions "amm:$PA"); sleep 5; PA1=$(field completions "amm:$PA")
[ "${PA1:-0}" -gt "${PA0:-0}" ] && ok "per-market subtask amm:$PA completing under the breaker" || nok "no per-market amm accounting (the H-09 gap)" "a0=$PA0 a1=$PA1"
adm setTestHbTrap "(opt \"amm:$PA\")" >/dev/null
sleep 5
H6=$(hb); sleep 2; H7=$(hb)
[ "${H7:-0}" != "${H6:-0}" ] && ok "beat still advancing with amm:$PA trapping" || nok "amm trap took the heartbeat down" "h6=$H6 h7=$H7"
SA=$(field streak "amm:$PA")
[ "${SA:-0}" -ge 1 ] && ok "breaker sees market A's failures (streak=$SA)" || nok "amm:$PA streak not growing" "s=$SA"
PB0=$(field completions "amm:$PB"); sleep 3; PB1=$(field completions "amm:$PB")
[ "${PB1:-0}" -gt "${PB0:-0}" ] && ok "market B (amm:$PB) still serviced while A traps" || nok "one market's trap starved the other (the F4 wedge)" "b0=$PB0 b1=$PB1"
AD0=$(field dispatches "amm:$PA"); sleep 6; AD1=$(field dispatches "amm:$PA")
ADELTA=$(( AD1 - AD0 ))
if [ -n "${AD0:-}" ] && [ "$ADELTA" -lt 3 ]; then ok "backoff engaged on A only: $ADELTA dispatches in 6s (an unbroken 2s task would make 3)"; else nok "no per-market backoff" "delta=$ADELTA"; fi
adm setTestHbTrap '(null)' >/dev/null
wait_streak0 "amm:$PA" 70   # cadence backs off 4/8/16/32/64s; the poll returns at the first healthy completion
SA2=$(field streak "amm:$PA"); AC0=$(field completions "amm:$PA"); sleep 5; AC1=$(field completions "amm:$PA")
[ "${SA2:-9}" = "0" ] && ok "market A's streak reset on recovery" || nok "amm:$PA streak stuck" "s=$SA2"
[ "${AC1:-0}" -gt "${AC0:-0}" ] && ok "market A completing again" || nok "amm:$PA did not recover" "c0=$AC0 c1=$AC1"

echo "── §7 H-22 (F28): a tripped market's release never rides the message that commits the fetched mark ──"
# Pre-H-22 the GEPTOR finalizer requoted AND released inline for every market,
# breaker or no breaker: a trap in the release discarded the fetched mark and
# the fresh ladder with it, on EVERY fetch (the arm re-armed by each new
# placement). Now the finalizer requotes but leaves the release pass to the
# market's own hbRun("amm:<mkt>") message while that breaker holds a streak —
# the mark commits (releaseRefNs advances past the entry) while the entry
# stays staged, and the breaker's message releases it on recovery.
mdx_identity_new hbi_u; UP=$(principal_of hbi_u)
usr() { icp canister call --candid "$MDX_CANDID" --identity hbi_u backend "$@" 2>&1; }
staged_n() { usr getMyStagedOrderIds '()' --query | grep -oF ': nat' | wc -l | tr -d ' '; }
release_ref() { adm getReleaseInfo "(\"$PA\")" --query | tr -d '_\n' | tr -s ' ' | grep -oE 'releaseRefNs = [0-9-]+' | awk '{print $3}'; }
adm setTestBalance "(principal \"$UP\", \"ICPUSD\", $(e8 200000.0) : nat)" >/dev/null
MIDA=$(adm getAmmPool "(\"$PA\")" --query | tr -d '_' | grep -oE 'refPrice = [0-9]+' | head -1 | awk '{print $3}')
if [ -z "${MIDA:-}" ] || [ "$MIDA" = "0" ]; then nok "§7 fixture: $PA carries no mark" "refPrice=$MIDA"; fi
adm setTestHbTrap "(opt \"amm:$PA\")" >/dev/null
i=0; while [ "$i" -lt 15 ] && [ "$(field streak "amm:$PA")" = "0" ]; do sleep 2; i=$((i+1)); done
SA7=$(field streak "amm:$PA")
[ "${SA7:-0}" -ge 1 ] && ok "amm:$PA tripped (streak=$SA7) — its release pass now runs only under its own backed-off message" || nok "could not trip amm:$PA" "s=$SA7"
R0=$(release_ref)
PL=$(usr placeLimitOrder "(\"$PA\", variant { buy }, $(( MIDA / 2 )) : nat, $(e8 0.001) : nat)")
if mdx_ok "$PL" && [ "$(staged_n)" = "1" ]; then ok "a bid staged on $PA (arms the GEPTOR; releaseRefNs was $R0)"; else nok "staging failed" "$(echo "$PL" | tr -s '[:space:]' ' ' | head -c 200)"; fi
i=0; while [ "$i" -lt 25 ] && [ "$(release_ref)" = "$R0" ]; do sleep 2; i=$((i+1)); done
R1=$(release_ref)
[ -n "${R1:-}" ] && [ "$R1" != "$R0" ] && ok "the GEPTOR's fetched mark COMMITTED while amm:$PA is tripped (releaseRefNs $R0 → $R1)" || nok "no fetch landed for $PA within 50s (feed down, or the mark was discarded)" "ref=$R1"
S7=$(staged_n)
[ "$S7" = "1" ] && ok "the entry stayed staged: the finalizer left the release to the breaker's message (pre-H-22 it released inline, trap or no trap)" || nok "the tripped market's entry released inside the fetch's message (the F28 shape)" "staged=$S7"
adm setTestHbTrap '(null)' >/dev/null
wait_streak0 "amm:$PA" 70
i=0; while [ "$i" -lt 20 ] && [ "$(staged_n)" != "0" ]; do sleep 2; i=$((i+1)); done
[ "$(staged_n)" = "0" ] && ok "on recovery the market's own hbRun released it (staged=0)" || nok "the entry never released after the breaker recovered" "staged=$(staged_n)"
usr cancelAllMyOrders "(opt \"$PA\")" >/dev/null 2>&1

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_heartbeat_isolation ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_heartbeat_isolation ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
