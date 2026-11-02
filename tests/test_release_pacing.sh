#!/bin/bash
# H-22 (F22c + F28) — both fresh-price release passes are PACED: a pass stops
# after MAX_RELEASES_PER_PASS releases / RELEASE_PASS_FILL_BUDGET settled
# fills, leaves the remainder staged in priority order (the GEPTOR re-armed),
# and the next tick resumes from the head. processDeferred (the per-market
# GEPTOR/tick release) and processDeferredSwaps (the cross-swap release) used
# to release EVERY due entry in one message with no cap — unlike the expiry
# pass (MAX_EXPIRY_RELEASES_PER_PASS) — so a due cohort of identities ×
# STAGED_CAP_PER_OWNER could trap the message that also carried the fetched
# mark, and re-trap at every retry.
#
#   §1 the REAL constant: 9 virgin identities × 32 non-crossing bids = 288
#      staged on one market; one release pass leaves EXACTLY 32 staged (256
#      released, the default cap), the survivors are the YOUNGEST 32 (oldest-
#      first within a tier — priority order kept), the next pass drains them,
#      nothing is dropped (288 resting afterwards)
#   §2 the dev pin (setTestReleasePacing): cap 8 → 20 staged drain 12 → 4 → 0
#   §3 the FILL budget: cap on fills, not releases — marketable entries that
#      each settle a fill stop the pass once the budget is spent, and the
#      remainder drains on later passes
#   §4 the cross-swap pass is paced by the SAME helper: 5 staged swaps under a
#      cap of 2 drain 3 → 1 → 0 across adminRunDeferredSwaps passes
#   §5 liveness: with the timers RUNNING a paced cohort drains to zero with no
#      manual pass (the tick/GEPTOR resume it); the probe's sort cost at 5,000
#      synthetic staged entries is recorded and bounded
#
# Needs #dev (setTestReleasePacing, setAmmRefPrice, setTestBalance). Uses the
# venue's BTC-ICPUSD and ICP-ICPUSD pools — PROVISIONED below rather than
# assumed: "as seeded" held only on a fresh seed, and after a predecessor's
# resetExchange this suite redded on its first fixture line ("no priced
# BTC-ICPUSD pool") — or, when a wiper's successor rebuilt only BTC, on §4's
# "no priced ICP-ICPUSD" with every swap assertion following (task
# 1788556083). Leaves nothing resting.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of / mdx_ok — the sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

[ "$(venue_posture)" = "dev" ] || skip_posture "test_release_pacing" "setTestReleasePacing / setAmmRefPrice are #dev hooks"

adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
as()  { local who="$1"; shift; icp canister call --candid "$MDX_CANDID" --identity "$who" backend "$@" 2>&1; }
e8()  { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
mid_of() { adm getAmmPool "(\"$1\")" --query | tr -d '_' | grep -oE 'refPrice = [0-9]+' | head -1 | awk '{print $3}'; }
# icp prints a big vec on ONE line — count matches, never lines (hygiene §6aj)
staged_n()   { as "$1" getMyStagedOrderIds '()' --query | grep -oF ': nat' | wc -l | tr -d ' '; }
staged_ids() { as "$1" getMyStagedOrderIds '()' --query | tr -d '_' | grep -oE '[0-9]+ : nat' | grep -oE '^[0-9]+'; }
resting_n()  { as "$1" getMyOrdersOnMarket "(\"$MKT\")" --query | grep -oE "[{ ]id = [0-9]" | wc -l | tr -d ' '; }
staged_count_of() { as "$1" getAccessPolicy '()' --query | tr -d '_' | grep -oE 'myStagedCount = [0-9]+' | awk '{print $3}'; }
# bulk <identity> <side> <price> <qty> <n>
bulk() {
  local items="" i=0
  while [ "$i" -lt "$5" ]; do
    items="$items record { marketId=\"$MKT\"; side=variant { $2 }; price=$3 : nat; quantity=$4 : nat; expiresInSec=null; postOnly=false };"
    i=$((i+1))
  done
  as "$1" placeLimitOrdersBulk "(vec { ${items%;} })"
}
release() { adm setAmmRefPrice "(\"$MKT\", $MID : nat)" >/dev/null; adm requoteAmm "(\"$MKT\")" >/dev/null; }
pin() { adm setTestReleasePacing "($1, $2)"; }   # (opt N | null, opt M | null)
cancel_all_of() { local i=0; while [ "$i" -lt 6 ] && [ "$(resting_n "$1")" -gt 0 ]; do as "$1" cancelAllMyOrders "(opt \"$MKT\")" >/dev/null 2>&1; i=$((i+1)); done; }

# ── fixture: both markets provisioned here (header) ──
# Per market, the trio test_initial_margin runs per market — createAmmPool
# (idempotent) · a FRESH mark (mdx_restamp_mark, _lib.sh: an unpriced pool or
# one the feed agrees with pins to the aggregate, any other priced pool keeps
# its own mark — a one-stamp jump to live blows the AMM's volRegime and the
# ladder then quotes outside §3's 3% / §4's 5% reach; the pend is cleared
# either way) · enableAmm — plus the seed's ladder config (20bps · 15 levels
# · 35bps · 8s) at a per-market depth, an inventory floor for the AMM through
# the dev balance hook, which mints NO LP (the invariants elsewhere read what
# the predecessors left), and a calm gate (mdx_calm_ladder: both sides within
# 2% of the mark, requoting until they are). setTestBalance SETS a balance,
# so a floor only ever raises a short leg; every floor sits far under a fresh
# seed's legs, so a seeded venue is never touched (and its auto-inventory
# re-derives the depth on the first requote). The depths are what the
# sections consume: §3's four 0.0005 BTC takers, §4's five 10 ICP swaps into
# ICP bids and BTC asks. The quote floor comes first: a ladder with no cash
# has no bid side to calm.
AMM=$(adm getAmmPrincipal '()' --query | grep -oE 'principal "[^"]+"' | head -1 | sed -E 's/principal "(.+)"/\1/')
[ -n "${AMM:-}" ] || { nok "fixture" "no AMM principal (getAmmPrincipal)"; echo -e "${RED}FAIL: test_release_pacing${NC}"; exit 1; }
amm_holding() {   # <basket leg: btc|eth|sol|icp|icpusd> → base units; the vault basket IS the AMM's balances
  adm getVaultValue '()' --query | tr -d '\n' | grep -oE "basket = record \{[^}]*\}" | grep -oE "$1 = [0-9_]+" | tr -d '_' | grep -oE '[0-9]+$'
}
floor_amm() {   # <token> <basket leg> <floor e8>
  local have; have=$(amm_holding "$2")
  if [ "${have:-0}" -lt "$3" ]; then
    adm setTestBalance "(principal \"$AMM\", \"$1\", $3 : nat)" >/dev/null
    echo "  (AMM held $(from_e8 "${have:-0}") $1 — floored to $(from_e8 "$3") through the dev balance hook; no LP minted)"
  fi
}
provision() {   # <market> <base token> <fallback px> <depth per level> <base floor e8>
  local mkt="$1" base="$2" fb="$3" depth="$4" bfloor="$5" pin px
  adm createAmmPool "(\"$mkt\")" >/dev/null 2>&1 || true
  adm setAmmConfig "(\"$mkt\", 20:nat, $(e8 "$depth") : nat, 15:nat, 35:nat)" >/dev/null
  pin=$(mdx_restamp_mark "$base" "$mkt" "$(e8 "$fb")") || { nok "fixture: $mkt" "no mark could be pinned (no aggregate, no pool price, fallback refused)"; return 1; }
  px=${pin% *}
  adm enableAmm "(\"$mkt\", true)" >/dev/null
  floor_amm "$base" "$(echo "$base" | tr 'A-Z' 'a-z')" "$bfloor"
  adm requoteAmm "(\"$mkt\")" >/dev/null
  if mdx_calm_ladder "$mkt" "$px" 200 40; then
    ok "fixture: $mkt at $(from_e8 "$px") (mark ${pin#* }), enabled, ladder 20bps · $depth $base × 15 calm within 2%"
  else
    nok "fixture: $mkt" "ladder never calmed to within 2% of $(from_e8 "$px") after 40 requotes: $(adm getOrderBookDepth "(\"$mkt\", opt (1 : nat))" --query | tr -d '\n' | tr -s ' ' | head -c 200)"
  fi
}
floor_amm ICPUSD icpusd "$(e8 200000)"
provision BTC-ICPUSD BTC 80000 0.05 "$(e8 1)"
provision ICP-ICPUSD ICP 5 100 "$(e8 5000)"

MKT=BTC-ICPUSD
MID=$(mid_of "$MKT")
[ -n "${MID:-}" ] && [ "$MID" -gt 0 ] || { nok "fixture" "no priced $MKT pool on the venue"; echo -e "${RED}FAIL: test_release_pacing${NC}"; exit 1; }
FAR=$(( MID / 2 ))          # a bid at half the mark: never crosses, rests at release (inside the 100× band)
QTY=$(e8 0.001)

adm setTestTimersPaused '(true)' >/dev/null 2>&1
on_exit "icp canister call --candid \"$MDX_CANDID\" --identity anonymous backend setTestReleasePacing '(null, null)' >/dev/null 2>&1"
on_exit "icp canister call --candid \"$MDX_CANDID\" --identity anonymous backend setTestTimersPaused '(false)' >/dev/null 2>&1"

echo "── §1 the real constant: 288 due entries → 256 released, 32 left in priority order, nothing dropped ──"
COHORT=""
for k in 1 2 3 4 5 6 7 8 9; do
  mdx_identity_new "rlp_$k"; P=$(principal_of "rlp_$k")
  adm setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 200000.0) : nat)" >/dev/null
  COHORT="$COHORT rlp_$k"
done
release   # a clean, fresh ladder before the cohort stages (nothing of ours is staged yet)
TOTAL=0
for who in $COHORT; do
  R=$(bulk "$who" buy "$FAR" "$QTY" 32)
  n=$(echo "$R" | grep -oF 'ok = record' | wc -l | tr -d ' ')
  TOTAL=$((TOTAL + n))
done
[ "$TOTAL" = "288" ] && ok "fixture: 288 bids staged from 9 identities (32 each, one bulk call each)" || nok "fixture: staged $TOTAL of 288" "check funding / the staged cap"
LAST_IDS=$(staged_ids rlp_9 | sort -n)
release
LEFT=0; for who in $COHORT; do LEFT=$((LEFT + $(staged_n "$who"))); done
[ "$LEFT" = "32" ] && ok "one pass released exactly 256 (the default MAX_RELEASES_PER_PASS): 32 still staged" || nok "pass 1 left $LEFT staged (want 32: 288 − 256)" "unpaced release (the finding) or a different cap"
L9=$(staged_n rlp_9); LO=$((LEFT - L9))
if [ "$LEFT" = "32" ] && [ "$L9" = "32" ] && [ "$LO" = "0" ] && [ "$(staged_ids rlp_9 | sort -n)" = "$LAST_IDS" ]; then
  ok "the survivors are the YOUNGEST 32 (rlp_9's whole batch) — released oldest-first, remainder kept in priority order"
else nok "survivors are not the youngest cohort" "rlp_9 staged=$L9 others=$LO"; fi
release
LEFT=0; for who in $COHORT; do LEFT=$((LEFT + $(staged_n "$who"))); done
[ "$LEFT" = "0" ] && ok "the next pass drained the remainder (0 staged)" || nok "remainder not drained" "staged=$LEFT"
REST=0; for who in $COHORT; do REST=$((REST + $(resting_n "$who"))); done
[ "$REST" = "288" ] && ok "nothing dropped: 288 bids resting across the cohort" || nok "resting count is $REST (want 288)" "entries lost across passes"
for who in $COHORT; do cancel_all_of "$who"; done
REST=0; for who in $COHORT; do REST=$((REST + $(resting_n "$who"))); done
[ "$REST" = "0" ] && ok "cleanup: cohort bids cancelled" || nok "cleanup: $REST bids still resting" ""

echo "── §2 the dev pin: cap 8 → 20 staged drain 12 → 4 → 0 ──"
mdx_identity_new rlp_pin; PP=$(principal_of rlp_pin)
adm setTestBalance "(principal \"$PP\", \"ICPUSD\", $(e8 200000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$PP\", \"BTC\", $(e8 1.0) : nat)" >/dev/null
R=$(pin 'opt (8 : nat)' 'null')
if echo "$R" | grep -q 'dev-only\|not found\|no method\|Error\|error'; then nok "setTestReleasePacing(8, default) refused" "$(echo "$R" | tr -s '[:space:]' ' ' | head -c 200)"; else ok "setTestReleasePacing(opt 8, null) pinned"; fi
R=$(bulk rlp_pin buy "$FAR" "$QTY" 20)
[ "$(echo "$R" | grep -oF 'ok = record' | wc -l | tr -d ' ')" = "20" ] && ok "20 bids staged" || nok "bulk staging" "$(echo "$R" | head -c 200)"
IDS0=$(staged_ids rlp_pin | sort -n | head -8 | tr '\n' ' ')
release; N1=$(staged_n rlp_pin)
[ "$N1" = "12" ] && ok "pass 1: 8 released, 12 staged" || nok "pass 1 left $N1 (want 12)" "pin ignored or unpaced"
IDS1=$(staged_ids rlp_pin | sort -n | head -1)
if [ -n "$IDS1" ] && ! echo " $IDS0 " | grep -q " $IDS1 "; then ok "the 8 oldest went first (lowest surviving id $IDS1 is younger than every released id)"; else nok "release order not oldest-first" "released=[$IDS0] oldest survivor=$IDS1"; fi
release; N2=$(staged_n rlp_pin)
[ "$N2" = "4" ] && ok "pass 2: 4 staged" || nok "pass 2 left $N2 (want 4)" ""
release; N3=$(staged_n rlp_pin)
[ "$N3" = "0" ] && ok "pass 3: drained" || nok "pass 3 left $N3 (want 0)" ""
[ "$(resting_n rlp_pin)" = "20" ] && ok "all 20 resting — nothing dropped" || nok "resting=$(resting_n rlp_pin) (want 20)" ""
cancel_all_of rlp_pin

echo "── §3 the fill budget: marketable entries stop the pass once the settled-fill budget is spent ──"
pin 'null' 'opt (2 : nat)' >/dev/null    # release cap default (256), fill budget 2
NEAR=$(( MID + MID * 3 / 100 ))           # 3% through the mark: marketable inside the 5% collar
SMALL=$(e8 0.0005)
release   # fresh ladder for the takers to lift
R=$(bulk rlp_pin buy "$NEAR" "$SMALL" 4)
[ "$(echo "$R" | grep -oF 'ok = record' | wc -l | tr -d ' ')" = "4" ] && ok "4 marketable buys staged (each settles ≥1 fill at release)" || nok "marketable staging" "$(echo "$R" | head -c 300)"
release; F1=$(staged_n rlp_pin)
if [ "$F1" -ge 1 ] && [ "$F1" -le 3 ]; then ok "pass 1 stopped on the fill budget: $F1 of 4 still staged (budget 2 fills)"; else nok "fill budget did not pace the pass" "staged after pass 1 = $F1 (want 1..3)"; fi
i=0; while [ "$i" -lt 4 ] && [ "$(staged_n rlp_pin)" -gt 0 ]; do release; i=$((i+1)); done
[ "$(staged_n rlp_pin)" = "0" ] && ok "later passes drained the marketable remainder (in $((i+1)) passes)" || nok "marketable remainder stuck" "staged=$(staged_n rlp_pin)"
cancel_all_of rlp_pin
pin 'null' 'null' >/dev/null

echo "── §4 the cross-swap pass is paced by the same helper ──"
mdx_identity_new rlp_sw; SP=$(principal_of rlp_sw)
adm setTestBalance "(principal \"$SP\", \"ICP\", $(e8 1000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SP\", \"ICPUSD\", $(e8 1000.0) : nat)" >/dev/null
MKT2=ICP-ICPUSD; MID2=$(mid_of "$MKT2")
[ -n "${MID2:-}" ] && [ "$MID2" -gt 0 ] && ok "fixture: $MKT2 priced ($MID2)" || nok "fixture: no priced $MKT2 pool" ""
pin 'opt (2 : nat)' 'null' >/dev/null
staged=0
for k in 1 2 3 4 5; do
  R=$(as rlp_sw swap "(record { fromToken=\"ICP\"; toToken=\"BTC\"; amount=$(e8 10.0) : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.05) : nat } }; noPartialFill=false })")
  if mdx_ok "$R" && echo "$R" | grep -q "swapOrderId = opt"; then staged=$((staged+1)); fi
done
[ "$staged" = "5" ] && ok "5 cross-swaps staged (myStagedCount=$(staged_count_of rlp_sw))" || nok "only $staged of 5 swaps staged" "$(echo "$R" | tr -s '[:space:]' ' ' | head -c 200)"
# BOTH legs fresh: a mark dispatched after the swaps + a ladder requoted on it (H-23)
adm setAmmRefPrice "(\"$MKT2\", $MID2 : nat)" >/dev/null; adm requoteAmm "(\"$MKT2\")" >/dev/null
release
adm adminRunDeferredSwaps '()' >/dev/null; S1=$(staged_count_of rlp_sw)
[ "$S1" = "3" ] && ok "swap pass 1: 2 released, 3 staged" || nok "swap pass 1 left $S1 (want 3)" "unpaced swap release (the finding)"
adm adminRunDeferredSwaps '()' >/dev/null; S2=$(staged_count_of rlp_sw)
[ "$S2" = "1" ] && ok "swap pass 2: 1 staged" || nok "swap pass 2 left $S2 (want 1)" ""
adm adminRunDeferredSwaps '()' >/dev/null; S3=$(staged_count_of rlp_sw)
[ "$S3" = "0" ] && ok "swap pass 3: drained" || nok "swap pass 3 left $S3 (want 0)" ""
BTC_SW=$(as rlp_sw getBalance '("BTC")' --query | tr -d '_' | grep -oE '[0-9]+' | head -1)
[ "${BTC_SW:-0}" -gt 0 ] && ok "the swaps converted (BTC received: $BTC_SW e8)" || nok "no BTC received across the paced passes" "bal=$BTC_SW"
pin 'null' 'null' >/dev/null

echo "── §5 liveness: a paced cohort drains under the running timers; the sort cost is bounded ──"
pin 'opt (8 : nat)' 'null' >/dev/null
R=$(bulk rlp_pin buy "$FAR" "$QTY" 20)
[ "$(echo "$R" | grep -oF 'ok = record' | wc -l | tr -d ' ')" = "20" ] && ok "20 bids staged under a cap of 8" || nok "bulk staging" ""
adm setTestTimersPaused '(false)' >/dev/null
adm setAmmRefPrice "(\"$MKT\", $MID : nat)" >/dev/null    # the mark postdates the cohort; the AMM tick's requote (2s cadence) releases from here
if wait_for "[ \"\$(staged_n rlp_pin)\" = \"0\" ]" 60 2; then ok "the cohort drained to 0 with no manual pass (tick/GEPTOR resumed the remainder)"; else nok "cohort did not drain under the running timers" "staged=$(staged_n rlp_pin) after 60s"; fi
[ "$(resting_n rlp_pin)" = "20" ] && ok "all 20 resting after the live drain" || nok "resting=$(resting_n rlp_pin) (want 20)" ""
cancel_all_of rlp_pin
pin 'null' 'null' >/dev/null
PR=$(adm devSweepCostProbe '()' --query | tr -d '_\n' | tr -s ' ')
SORT_LIVE=$(echo "$PR" | grep -oE 'releaseSort = [0-9]+' | awk '{print $3}')
SORT_SYN=$(echo "$PR" | grep -oE 'releaseSortSynth = [0-9]+' | awk '{print $3}')
SYN_N=$(echo "$PR" | grep -oE 'releaseSynthAtProbe = [0-9]+' | awk '{print $3}')
CAP_R=$(echo "$PR" | grep -oE 'releaseMaxPerPass = [0-9]+' | awk '{print $3}')
CAP_F=$(echo "$PR" | grep -oE 'releaseFillBudget = [0-9]+' | awk '{print $3}')
# Task 1788550465: the pre-pass is a market-index collect + top-k heap (k = the
# release cap), not a sort of every staged entry — 49.9M instr at 5,000 on the
# seat venue, down from 622M on the full sort (1.19B on H-22's venue). The bound
# sits 5× over the measured cost and BELOW the pre-index number, so a regression
# to the whole-map sort reds this line.
if [ -n "${SORT_SYN:-}" ] && [ "${SYN_N:-0}" -ge 5000 ] && [ "$SORT_SYN" -lt 250000000 ]; then
  ok "probe: the pre-pass sort at $SYN_N staged costs $SORT_SYN instr (live S: $SORT_LIVE); caps $CAP_R releases / $CAP_F fills per pass"
else nok "probe fields missing or the sort at the L1 floor is unbounded" "releaseSortSynth=$SORT_SYN at=$SYN_N"; fi
# Task 1788552852: the two sibling pre-loop terms at the same 5,000 floor.
# swapSortSynth — the cross-swap pass's whole-map collect + ts sort, KEPT
# (24.1M instr at 5,000 on the seat venue: 0.06% of the message budget and
# under half the release pre-pass above; the per-candidate freshness
# predicate makes the loop O(N) regardless, so a ts-ordered index would
# only shave the sort's share). The bound is 5× the measurement so a
# regression to an O(N)-per-compare shape reds it.
# expiryScanSynth — the expiry pass's due-cohort collect with NOTHING due
# at 5,000 staged, the every-tick case: 8.38M instr on the whole-map scan →
# 2.4K off the expiresAt-keyed index (deferredIdsByExpiry). The bound sits
# well under the old scan, so a regression to the scan reds this line.
SW_SYN=$(echo "$PR" | grep -oE 'swapSortSynth = [0-9]+' | awk '{print $3}')
SW_N=$(echo "$PR" | grep -oE 'swapSynthAtProbe = [0-9]+' | awk '{print $3}')
EX_SYN=$(echo "$PR" | grep -oE 'expiryScanSynth = [0-9]+' | awk '{print $3}')
EX_N=$(echo "$PR" | grep -oE 'expirySynthAtProbe = [0-9]+' | awk '{print $3}')
if [ -n "${SW_SYN:-}" ] && [ "${SW_N:-0}" -ge 5000 ] && [ "$SW_SYN" -lt 120000000 ]; then
  ok "probe: the cross-swap pass's collect + sort at $SW_N staged swaps costs $SW_SYN instr (measured bound, sort kept)"
else nok "probe fields missing or the cross-swap sort at the floor is unbounded" "swapSortSynth=$SW_SYN at=$SW_N"; fi
if [ -n "${EX_SYN:-}" ] && [ "${EX_N:-0}" -ge 5000 ] && [ "$EX_SYN" -lt 1000000 ]; then
  ok "probe: the expiry pass's collect at $EX_N staged (none due) costs $EX_SYN instr (index, not a scan)"
else nok "probe fields missing or the expiry collect still scans the staged map" "expiryScanSynth=$EX_SYN at=$EX_N"; fi
[ "${CAP_R:-0}" = "256" ] && [ "${CAP_F:-0}" = "1024" ] && ok "defaults restored after the pins (256 / 1024)" || nok "pacing defaults" "releases=$CAP_R fills=$CAP_F"

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_release_pacing ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_release_pacing ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
