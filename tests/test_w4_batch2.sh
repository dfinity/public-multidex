#!/bin/bash
# W4 batch 2 — replay single-flight, blackholed observability, vault fee
# weight, season/bridge coherence.
#
#   §1 W4-09: overlapping adminReplayStep calls cannot double-fold — the
#      audit completes with ZERO mismatches (pre-fix: false reserve alarm)
#   §1b #54.2: adminReplayReset inside a live step is refused (trap), the
#      fold stays intact and the report clean; an idle reset is accepted
#   §2 W4-11: a skewing LP deposit mints less than a balancing one of equal
#      value (the pre-deposit snapshot charged the skew NOTHING)
#   §3 W4-10: a blackholed sealed segment is still observed (via its own
#      stats()) and its chain row is marked degraded
#   §4 W4-12: admit → season reset → the Bridge's half is wiped WITH the
#      DEX's; a fresh deposit afterwards charges the allowance exactly once
#      (LAST: the reset wipes the venue)
#
# Needs #dev. ⚠️ §4 wipes the venue — reseed afterwards.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
u()   { icp canister call --candid "$MDX_CANDID" --identity w42_u backend "$@" 2>&1; }
mdx_identity_new w42_u; U=$(principal_of w42_u)

STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }
adm setTestTimersPaused '(false)' >/dev/null 2>&1   # shipper must run for §1/§4

# Self-contained venue setup (§2 needs a seeded vault; prior runs may have
# season-wiped the venue). Provision ONLY when the vault is empty or the
# ICP-ICPUSD pool is missing (task 3088469974): the vault is ONE basket
# across every pool, and on a seed.sh-full venue (cold_start --mode full:
# 4 pools, ~$2M, cash at its 50% target) an unconditional
# setAmmRefPrice("ICP-ICPUSD", 10.0) re-marked the ~100k seeded ICP ~4× up
# (the seed price is refreshed toward live ~$2.5 by the oracle), which
# dropped the cash weight to ~37% — UNDER target — so no quote deposit paid
# any fee and §2 red on every first run while a wiped venue went green.
mdx_identity_new w42_seed; SEED=$(principal_of w42_seed)
vault_total() { adm getVaultValue '()' --query | tr -d '_' | grep -oE "totalQuoteValue = [0-9]+" | grep -oE "[0-9]+"; }
VT=$(vault_total)
if [ "${VT:-0}" = "0" ] || ! adm getAmmPool '("ICP-ICPUSD")' --query | grep -q 'marketId = "ICP-ICPUSD"'; then
  adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
  adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 100.0) : nat, 5:nat, 10:nat)" >/dev/null
  adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
  adm setTestBalance "(principal \"$SEED\", \"ICP\", $(e8 10000.0) : nat)" >/dev/null
  adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 200000.0) : nat)" >/dev/null
  mdx_lp_deposit w42_seed "ICP-ICPUSD" "$(e8 10000.0)" "$(e8 100000.0)" >/dev/null 2>&1
  adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
  adm requoteAmm '("ICP-ICPUSD")' >/dev/null
  echo "  (self-provisioned ICP-ICPUSD: vault was empty / pool missing — total was ${VT:-0})"
else
  echo "  (venue already seeded: vault total $VT — leaving the seed's prices alone)"
fi

echo "── §1 W4-09: replay is single-flight, audit stays truthful ──"
adm adminReplayReset '()' >/dev/null
# Fire two overlapping steps; the guard must refuse one.
OUT_A=$(scratch_new w42_a.out) || exit 1
OUT_B=$(scratch_new w42_b.out) || exit 1
adm adminReplayStep '(5_000 : nat)' >"$OUT_A" 2>&1 &
P1=$!
adm adminReplayStep '(5_000 : nat)' >"$OUT_B" 2>&1 &
P2=$!
wait $P1 $P2
# Drive the fold to completion.
for i in $(seq 1 40); do
  R=$(adm adminReplayStep '(20_000 : nat)')
  echo "$R" | grep -q "done = true" && break
  sleep 1
done
REP=$(adm adminReplayReport '()' --query | tr -d '_\n' | tr -s ' ')
MIS=$(echo "$REP" | grep -oE "mismatches = vec \{[^}]*" | head -1)
if echo "$REP" | grep -q "mismatches = vec {}"; then
  ok "fold completed with ZERO balance mismatches (no double-count)"
else nok "replay mismatches present (double-fold or real drift)" "$(echo "$MIS" | head -c 200)"; fi

echo "── §1b #54.2: a reset landing INSIDE a live step is refused, the fold stays intact ──"
# The bug shape: a reset between a page's fetch and its fold emptied the maps
# after page one was folded; the continuation folded the rest into empty maps,
# finished done=true, and the report raised a FALSE reserve alarm for every
# account active in page one. A seeded venue's whole fold is ~5 archive
# round-trips (far under one CLI call), so the dev hold widens the window and
# the report's cursor (a query) tells us page one has landed before we fire.
tape_len() { adm getCanisterInfo '()' --query | tr -d '_' | grep -oE "archivedEvents = [0-9]+" | grep -oE "[0-9]+"; }
TAPE=$(tape_len)
if [ "${TAPE:-0}" -lt 300 ]; then
  # Two pages minimum (page = 200 events): top the tape up with balance
  # deltas — one bulk call is 150 #delta events — then let the shipper land
  # them. (`principal` is a Candid keyword, hence the quoted label.)
  mdx_identity_new w42_fill; FILL=$(principal_of w42_fill)
  for round in 1 2 3; do
    ENT=""; for i in $(seq 1 150); do ENT="$ENT record { \"principal\" = principal \"$FILL\"; balances = vec { record { token = \"ICPUSD\"; amount = $((100000000 + round * 1000 + i)) : nat } } };"; done
    adm bulkSetTestBalances "(vec { $ENT })" >/dev/null 2>&1
    for _ in $(seq 1 30); do
      INFO=$(adm getCanisterInfo '()' --query | tr -d '_')
      UNSH=$(echo "$INFO" | grep -oE "journalUnshipped = [0-9]+" | grep -oE "[0-9]+")
      JP=$(echo "$INFO" | grep -oE "ledgerJournalPending = [0-9]+" | grep -oE "[0-9]+")
      [ "${UNSH:-1}" = "0" ] && [ "${JP:-1}" = "0" ] && break
      sleep 2
    done
    TAPE=$(tape_len); [ "${TAPE:-0}" -ge 300 ] && break
  done
fi
[ "${TAPE:-0}" -ge 300 ] && ok "tape holds >=2 replay pages ($TAPE events)" || nok "tape too short for a multi-page step" "archivedEvents=$TAPE"
# The hold applies from the SECOND page on (page one folds in-round), so a
# reset fired a moment after the step's ingress lands after page one is
# folded and before page two is. No query polling: queries starve while the
# local replica runs the step's self-call chain. Ingress DOES interleave, but
# pocket-ic's lock fairness sometimes starves the submit past the window, so
# the race re-arms; each attempt is classified from the step's OWN output —
# a reset accepted mid-step zeroes the fold counter, so folded < cursor.
ARMED=0; ACCEPTED=0; ATT=0
for ATT in 1 2 3 4 5; do
  adm adminReplayReset '()' >/dev/null
  adm setTestReplayStepHold '(1500 : nat)' >/dev/null   # ~11ms/round locally: a ~16s window
  HOLD_OUT=$(scratch_new w42_hold.out) || exit 1
  adm adminReplayStep '(20_000 : nat)' >"$HOLD_OUT" 2>&1 &
  PS=$!
  sleep 1.5
  RR=$(adm adminReplayReset '()')
  adm setTestReplayStepHold '(0 : nat)' >/dev/null    # release the hold; the step finishes
  wait $PS
  ST=$(tr -d '_\n' < "$HOLD_OUT" | tr -s ' ')
  F=$(echo "$ST" | grep -oE "folded = [0-9]+" | grep -oE "[0-9]+")
  C=$(echo "$ST" | grep -oE "cursor = [0-9]+" | grep -oE "[0-9]+")
  if echo "$RR" | grep -qi "in flight"; then ARMED=1; break; fi
  if [ "${F:-0}" -lt "${C:-0}" ]; then ARMED=1; ACCEPTED=1; break; fi
done
[ "$ARMED" = "1" ] && ok "race armed on attempt $ATT: the reset landed inside a live step" \
  || nok "race never armed in $ATT attempts (submit starved past the window every time)" "last step=$(echo "$ST" | head -c 120)"
if [ "$ARMED" = "1" ] && [ "$ACCEPTED" = "0" ]; then
  ok "adminReplayReset REFUSED loudly while a step was in flight (step fold intact: folded=$F cursor=$C)"
else nok "reset was accepted inside a live step (the finding)" "r=$(echo "$RR" | head -c 80) folded=$F cursor=$C"; fi
# The interrupted step must finish its fold; drive any remainder to done.
for i in $(seq 1 40); do
  R=$(adm adminReplayStep '(20_000 : nat)')
  echo "$R" | grep -q "done = true" && break
  sleep 1
done
REP=$(adm adminReplayReport '()' --query | tr -d '_\n' | tr -s ' ')
MIS=$(echo "$REP" | grep -oE "mismatches = vec \{[^}]*" | head -1)
if echo "$REP" | grep -q "mismatches = vec {}"; then
  ok "report stays clean after the raced reset (no false reserve alarm)"
else nok "false reserve alarm after a reset inside a step (the finding)" "$(echo "$MIS" | head -c 200)"; fi
# Control: with nothing in flight the reset is accepted and zeroes the cursor.
RR=$(adm adminReplayReset '()')
C1=$(adm adminReplayReport '()' --query | tr -d '_\n' | grep -oE "cursor = [0-9]+" | grep -oE "[0-9]+")
if echo "$RR" | grep -q "^()" && [ "${C1:-1}" = "0" ]; then
  ok "reset with no step in flight is accepted (cursor back to 0)"
else nok "idle reset misbehaved" "r=$(echo "$RR" | head -c 100) cursor=$C1"; fi

echo "── §2 W4-11: skewing deposit pays, balancing does not ──"
# Freshness: depositLp pauses vault-wide when ANY held leg's refPrice is older
# than LP_DEPOSIT_MAX_REF_AGE_NS (60s). A seeded venue with no live price loop
# goes stale during §1/§1b, so re-stamp every pool at its current refPrice
# (cold-venue physics: re-stamp, never sleep).
pools()   { adm getAmmPools '()' --query | grep -oE 'marketId = "[^"]+"' | grep -oE '"[^"]+"' | tr -d '"'; }
pool_px() { adm getAmmPool "(\"$1\")" --query | tr -d '_' | grep -oE "refPrice = [0-9]+" | grep -oE "[0-9]+" | head -1; }
restamp() { local M P; for M in $(pools); do P=$(pool_px "$M"); [ -n "$P" ] && [ "$P" != "0" ] && adm setAmmRefPrice "(\"$M\", $P : nat)" >/dev/null; done; }
vault_cash() { adm getVaultValue '()' --query | tr -d '_' | grep -oE "icpusd = [0-9]+" | grep -oE "[0-9]+" | head -1; }
restamp
# Headroom (task 3088497236): the skew probe below is a QUOTE deposit, and
# depositLp refuses any quote leg that lands cash past its 1.5× concentration
# cap (75%) while worsening the weight. On a dirty venue — the fixture's own
# $10 self-seed re-marked to ~$2.5 by the oracle, or other suites' quote
# deposits — cash already sits at/over the cap, so the probe was refused for
# CONCENTRATION and the fee rule was never observed. Open headroom the way
# test_vault_weights moves weights: deposit the NON-cash leg in kind, pool by
# pool, each asset up to (97% of) its own 2.5× cap (31.25%), until cash is
# back near its 50% target. A one-pool vault can only get cash down to
# ~69% (the asset cap binds); the D sizing below then takes it from there.
mdx_identity_new w42_rb; RB=$(principal_of w42_rb)
CASH_TGT_PCT=52
pool_hdr() {   # base units of $1's leg to deposit into pool $1 (0 = nothing useful)
  local M="$1" B="${1%%-ICPUSD}" C T P VA
  C=$(vault_cash); T=$(vault_total); P=$(pool_px "$M")
  [ -n "$P" ] && [ "$P" != "0" ] && [ "${T:-0}" -gt 0 ] || { echo 0; return; }
  VA=$(adm getVaultWeights '()' --query | tr -d '_\n' | grep -oE "token = \"$B\";[^}]*" | grep -oE "currentWeight = [0-9]+" | grep -oE "[0-9]+")
  awk -v C="$C" -v T="$T" -v w="${VA:-0}" -v p="$P" -v tgt="$CASH_TGT_PCT" 'BEGIN{
    va=w*T/1e8; need=C*100/tgt-T; capw=0.125*2.5*0.97; room=(capw*T-va)/(1-capw);
    x=(need<room)?need:room; if (x<=0) { print 0; exit }; printf "%.0f", x*1e8/p }'
}
cash_pct() { awk -v C="$(vault_cash)" -v T="$(vault_total)" 'BEGIN{ if (T<=0) { print 0; exit }; printf "%d", 100*C/T }'; }
W_START=$(cash_pct)
if [ "${W_START:-0}" -gt "$CASH_TGT_PCT" ]; then
  for M in $(pools); do
    case "${M%%-ICPUSD}" in BTC|ETH|SOL|ICP) ;; *) continue ;; esac
    BASE=$(pool_hdr "$M"); [ "${BASE:-0}" -gt 0 ] || continue
    adm setTestBalance "(principal \"$RB\", \"${M%%-ICPUSD}\", $BASE : nat)" >/dev/null
    R=$(mdx_lp_deposit w42_rb "$M" "$BASE" 0 2>&1)
    echo "  (headroom: cash ${W_START}% > ${CASH_TGT_PCT}% — deposited ${M%%-ICPUSD} in kind ($BASE base units) → $(echo "$R" | tr -d '\n' | tr -s ' ' | head -c 70); cash now $(cash_pct)%)"
    [ "$(cash_pct)" -gt "$CASH_TGT_PCT" ] || break
  done
  restamp   # the in-kind legs took a few round-trips; keep every held leg inside the 60s gate
else
  echo "  (headroom: cash ${W_START}% of the vault — under the ${CASH_TGT_PCT}% line, no in-kind rebalance needed)"
fi
adm setTestBalance "(principal \"$U\", \"ICP\", $(e8 200.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$U\", \"ICPUSD\", $(e8 4000.0) : nat)" >/dev/null
LP0=$(u getMyVaultLp '()' --query | tr -d '_' | grep -oE "[0-9]+" | head -1)
# THE finding's shape: quote sits AT target (50%), so the PRE-deposit
# snapshot priced any quote deposit at multiplier 1.0 — however far it
# skewed. A small deposit barely moves the weight (≈ free either way); a
# LARGE one lands the vault deep over target and must now pay, because the
# fee reads the MIDPOINT weight (W4-11). Compare per-USD minting.
#
# Venue-shape independence (task 3088469974): the vault is one basket across
# every pool, so what a quote deposit pays depends on the WHOLE venue's cash
# value C and total value T — a fixed $100k skews a $200k self-seeded vault
# deep past target and a $2M seed.sh vault not at all. So the skewing deposit
# D is SIZED from the live weights: midpoint cash weight (C + D/2)/(T + D/2)
# = 62.5% (gap 0.25 over the 50% target → fee 0.1 × 0.25² = 0.625%), clamped
# so the POST weight stays ≤ 72% (the 1.5× cash concentration cap refuses at
# 75%) and floored at 5% of T. The expected multipliers come from the same
# midpoint rule over the same live figures (VaultMath.feeMultiplier:
# 1 − 0.1 × min(1, ((w − 0.5)/0.5)²) when w > 0.5, else 1), so the observed
# per-USD ratio pins the rule itself, not a venue-specific number.
mult_at() { awk -v C="$1" -v T="$2" -v L="$3" 'BEGIN{ if (T <= 0) { print "1.000000000"; exit }; w=(C+L/2)/(T+L/2); tg=0.5; if (w<=tg) { print "1.000000000"; exit }; g=(w-tg)/tg; g2=g*g; if (g2>1) g2=1; printf "%.9f", 1-0.1*g2 }'; }
SMALL_USD=200
C0=$(vault_cash); T0=$(vault_total)
M_SMALL=$(mult_at "${C0:-0}" "${T0:-0}" "$(e8 $SMALL_USD)")
R_SMALL=$(mdx_lp_deposit w42_u "ICP-ICPUSD" 0 "$(e8 $SMALL_USD)")      # $200 from ≈target: ≈ free (staged door: settles before returning)
LP1=$(u getMyVaultLp '()' --query | tr -d '_' | grep -oE "[0-9]+" | head -1)
SMALL=$(( ${LP1:-0} - ${LP0:-0} ))
C1=$(vault_cash); T1=$(vault_total)
D=$(awk -v T="${T1:-0}" -v C="${C1:-0}" 'BEGIN{ d=(10*T-16*C)/3; dmax=(0.72*T-C)/0.28; if (d<=0) d=dmax; if (d>dmax) d=dmax; if (d<T/20) d=T/20; printf "%.0f", d }')   # cash already past the 62.5% midpoint (one-pool headroom): take the cap-clamped max, not the floor
M_BIG=$(mult_at "${C1:-0}" "${T1:-0}" "$D")
adm setTestBalance "(principal \"$U\", \"ICPUSD\", $(( D + $(e8 1000.0) )) : nat)" >/dev/null   # D + slack for §3's withdraws
R=$(mdx_lp_deposit w42_u "ICP-ICPUSD" 0 "$D")                             # skews deep past target
LP2=$(u getMyVaultLp '()' --query | tr -d '_' | grep -oE "[0-9]+" | head -1)
BIG=$(( ${LP2:-0} - ${LP1:-0} ))
# Three outcomes, kept DISTINGUISHABLE: a concentration-cap refusal is the
# fixture failing to open headroom (task 3088497236), not the fee finding;
# "did not mint" is any other refusal; only a mint on both probes reaches the
# fee rule.
if echo "$R_SMALL$R" | grep -q "concentration cap"; then
  nok "skew probe refused at the ICPUSD concentration cap — fixture could not open headroom (cash ${W_START}% → $(cash_pct)% of vault)" "small=$SMALL big=$BIG D=$D C=$C1 T=$T1 r=$(echo "$R_SMALL$R" | tr -d '\n' | tr -s ' ' | head -c 160)"
elif [ "$SMALL" -gt 0 ] && [ "$BIG" -gt 0 ]; then
  # LP minted per USD deposited, for the message; the ratio test is in floats.
  SMALL_PER=$(( SMALL / SMALL_USD )); BIG_PER=$(awk -v b="$BIG" -v d="$D" 'BEGIN{ printf "%.0f", b*100000000/d }')
  # Observed ratio big/small per-USD vs the midpoint rule's M_BIG/M_SMALL —
  # within 0.15% (oracle ticks move T by ~1e-5 between the two deposits;
  # the retained fee moves valuePerLP by ~1e-7); the sized fee is ≥ 0.3%
  # even when the cap clamp bites, so a zero fee cannot pass.
  VERDICT=$(awk -v b="$BIG" -v d="$D" -v s="$SMALL" -v su="$(e8 $SMALL_USD)" -v mb="$M_BIG" -v ms="$M_SMALL" 'BEGIN{
    obs=(b/d)/(s/su); ex=mb/ms; diff=obs-ex; if (diff<0) diff=-diff;
    printf "%s obs=%.6f exp=%.6f mBig=%.6f mSmall=%.6f", ((diff<0.0015 && mb<0.997) ? "OK" : "BAD"), obs, ex, mb, ms }')
  if [ "$BIG_PER" -lt "$SMALL_PER" ] && [ "${VERDICT%% *}" = "OK" ]; then
    ok "a skewing deposit (\$$(( D / 100000000 )), midpoint rule) pays per-USD more than a \$$SMALL_USD one ($BIG_PER < $SMALL_PER LP/USD; ${VERDICT#OK }) — pre-fix both were free"
  else nok "large skew paid no fee / off the midpoint rule (the finding)" "smallPer=$SMALL_PER bigPer=$BIG_PER D=$D C=$C1 T=$T1 $VERDICT"; fi
else nok "deposits did not mint" "small=$SMALL big=$BIG D=$D C=$C1 T=$T1 r=$(echo "$R_SMALL$R" | tr -d '\n' | tr -s ' ' | head -c 160)"; fi

echo "── §3 W4-10: blackholed segment stays observed, marked degraded ──"
adm setTestArchiveCap '(opt (20 : nat))' >/dev/null
adm setBlackholeAtSeal '(true)' >/dev/null
i=0; while [ $i -lt 15 ]; do icp canister call --candid "$MDX_CANDID" --identity w42_u backend withdraw '("ICPUSD", 1_000_000_000 : nat, "w42-bh")' >/dev/null 2>&1; i=$((i+1)); done
BH=0
for _ in $(seq 1 15); do
  adm getRecentEvents '(120 : nat)' --query 2>/dev/null | grep -q "BLACKHOLED" && { BH=1; break; }
  sleep 3
done
[ "$BH" = "1" ] && ok "a sealed segment was blackholed" || nok "no blackhole happened" "cap/seal flow"
adm setBlackholeAtSeal '(false)' >/dev/null
adm setTestArchiveCap '(null)' >/dev/null
# run a fuel pass NOW (the heartbeat cadence is 5min)
adm adminRunArchiveFuelPass '()' >/dev/null 2>&1
DEG=0
for _ in $(seq 1 5); do
  CH=$(adm getArchiveChain '()' --query | tr -d '_\n' | tr -s ' ')
  if echo "$CH" | grep -q "degraded = opt true"; then DEG=1; break; fi
  adm adminRunArchiveFuelPass '()' >/dev/null 2>&1
  sleep 2
done
if [ "$DEG" = "1" ]; then
  ok "blackholed segment re-observed via stats() and marked degraded"
  echo "$CH" | grep -oE "degraded = opt true[^}]*" | head -1 >/dev/null
else nok "no degraded observation (stale ok persists — the finding)" "$(echo "${CH:-none}" | head -c 200)"; fi

echo "── §4 W4-12: season boundary wipes BOTH halves of the deposit pair ──"
# email is per-run: w42_u is a VIRGIN principal every run (mdx_identity_new
# deletes it on EXIT), and one email binds to one principal for good — a fixed
# address re-bound to a new principal is refused, and every deposit below then
# reads "unbound" (test_bridge_write_ahead red 8/23 on its first virgin run).
W42_EMAIL="w42${RANDOM}$$@example.com"
R=$(adm setTestEmailBinding "(principal \"$U\", \"$W42_EMAIL\")")
mdx_ok "$R" && ok "w42_u bound to a per-run verified email" || nok "binding refused (deposits below will read unbound)" "$(echo "$R" | head -c 200)"
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
adm setAmmRefPrice '("BTC-ICPUSD", 10_000_000_000 : nat)' >/dev/null 2>&1
adm requoteAmm '("BTC-ICPUSD")' >/dev/null 2>&1
R=$(icp canister call --identity w42_u bridge devSimulateDeposit '("BTC", 100_000_000 : nat)' 2>&1)
mdx_ok "$R" && ok "pre-reset deposit admitted" || nok "admit failed" "$(echo "$R" | head -c 150)"
U1=$(u getPlayDepositAllowance '()' | tr -d '_\n' | tr -s ' ' | grep -oE "usedUsd = [0-9]+" | awk '{print $3}')
# drain the tape so the reset's gates pass
for i in $(seq 1 45); do
  INFO=$(adm getCanisterInfo '()' --query | tr -d '_' )
  UNSH=$(echo "$INFO" | grep -oE "journalUnshipped = [0-9]+" | grep -oE "[0-9]+")
  JP=$(echo "$INFO" | grep -oE "ledgerJournalPending = [0-9]+" | grep -oE "[0-9]+")
  [ "${UNSH:-1}" = "0" ] && [ "${JP:-1}" = "0" ] && break
  sleep 2
done
R=$(adm resetSeason '()')
if mdx_ok "$R"; then ok "season reset completed (two-phase with the Bridge)"; else nok "reset refused" "$(echo "$R" | head -c 200)"; fi
DEP=$(icp canister call --identity w42_u bridge getMyDeposits '()' --query 2>&1 | tr -d '_\n')
if echo "$DEP" | grep -qE "confirmed = 0[^0-9]" && echo "$DEP" | grep -qE "pending = 0[^0-9]"; then
  ok "Bridge half wiped with the DEX half (no surviving claimable)"
else nok "Bridge kept claimables across the boundary (the finding)" "$(echo "$DEP" | head -c 200)"; fi
adm setTestEmailBinding "(principal \"$U\", \"$W42_EMAIL\")" >/dev/null 2>&1
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
adm setAmmRefPrice '("BTC-ICPUSD", 10_000_000_000 : nat)' >/dev/null 2>&1
adm requoteAmm '("BTC-ICPUSD")' >/dev/null 2>&1
R=$(icp canister call --identity w42_u bridge devSimulateDeposit '("BTC", 100_000_000 : nat)' 2>&1)
U2=$(u getPlayDepositAllowance '()' | tr -d '_\n' | tr -s ' ' | grep -oE "usedUsd = [0-9]+" | awk '{print $3}')
if mdx_ok "$R" && [ "${U2:-0}" = "10000000000" ]; then
  ok "fresh post-reset deposit charges exactly once (used=$U2)"
else nok "post-reset charge wrong" "r=$(echo "$R" | head -c 80) used=$U2"; fi

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_w4_batch2 ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_w4_batch2 ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
