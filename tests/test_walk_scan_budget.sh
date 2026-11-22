#!/bin/bash
# H-09 (F4 · HIGH) — every book-walking simulator has a scan budget.
#
# crossableDepth / walkFillable iterate OrderBook.findBestMatchExcluding with
# a growing exclude set: O(N²) in the resting orders inside the price cap, a
# count anyone can inflate (resting orders hold no reservation; spend-all
# placements are exempt from min notional). Sinks: the PUBLIC getTakeableDepth
# and quoteSwap queries (caller-chosen cap / 25% slippage), the FOK gate, the
# post-only probe and releaseCrossSwap — all on the release path the AMM tick
# runs. The walker now counts every entry it visits against WALK_SCAN_MAX
# (512; the FOK gate uses the engine's 256-iteration budget instead) and
# returns `truncated`; the public depth query additionally clamps its cap to
# a ±25% band around the pool's refPrice.
#
#   §1 junk-band fixture: 2,048 UNFUNDED 2-ICP asks inside a 5% cap (behind
#      the AMM ladder), from 4 identities drained after resting
#   §2 the public queries complete and answer with the AMM's real depth
#   §3 devSweepCostProbe: the walk is TRUNCATED at ≤ WALK_SCAN_MAX visits and
#      its instruction cost is pinned (a measurement, not a claim — W5-19)
#   §4 one release pass over the band completes (the AMM fills; the junk
#      cancels 256 per engine call) and a FOK over the band records a kill
#
# Needs #dev (devSweepCostProbe, setTestOrderCap, setTestBalance). Timers are
# paused for determinism; releases are driven by requoteAmm.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }
adm()  { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
bal()  { local n; n=$(adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+"); [ -z "$n" ] && n=0; from_e8 "$n"; }
freshrequote() { adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null; adm requoteAmm '("ICP-ICPUSD")' >/dev/null; }
resting_count() { icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyOrders '()' --query 2>&1 | grep -oE "[{ ]id = [0-9]" | wc -l | tr -d ' '; }   # icp prints big vecs on ONE line: count matches, not lines
cancel_all_of() { local i=0; while [ "$i" -lt 6 ] && [ "$(resting_count "$1")" -gt 0 ]; do icp canister call --candid "$MDX_CANDID" --identity "$1" backend cancelAllMyOrders "(opt \"ICP-ICPUSD\")" >/dev/null 2>&1; i=$((i+1)); done; }
# One placeLimitOrdersBulk call: 32 × 2-ICP asks (20 ICPUSD — clear of the 10 ICPUSD
# min-notional gate), round-robin over the junk levels.
JUNK_PRICES=(10.10 10.15 10.20 10.25 10.30 10.35 10.40 10.45)
bulk32() { # bulk32 <identity> <cycle>
  local items="" k=0 pr
  while [ "$k" -lt 32 ]; do
    pr=${JUNK_PRICES[$(( (k + $2) % ${#JUNK_PRICES[@]} ))]}
    items="$items record { marketId = \"ICP-ICPUSD\"; side = variant { sell }; price = $(e8 "$pr") : nat; quantity = $(e8 2.0) : nat; expiresInSec = null; postOnly = false };"
    k=$((k+1))
  done
  icp canister call --candid "$MDX_CANDID" --identity "$1" backend placeLimitOrdersBulk "(vec { ${items%;} })" >/dev/null 2>&1
}

mdx_identity_new wsb_seed; S=$(principal_of wsb_seed); mdx_identity_new wsb_uA; UA=$(principal_of wsb_uA)
u() { icp canister call --candid "$MDX_CANDID" --identity wsb_uA backend "$@" 2>&1; }
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 100.0) : nat, 5:nat, 10:nat)" >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$S\", \"ICP\", $(e8 10000.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
mdx_lp_deposit wsb_seed "ICP-ICPUSD" "$(e8 10000.0)" "$(e8 100000.0)" >/dev/null 2>&1
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
adm setTestBalance "(principal \"$UA\", \"ICP\", 0 : nat)" >/dev/null
adm setTestBalance "(principal \"$UA\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
adm setTestOrderCap "(opt (5000 : nat))" >/dev/null 2>&1

echo ""
echo "── §1 junk-band fixture: 2,048 unfunded 2-ICP asks inside the 5% cap ──"
JUNK_IDS="wsb_j1 wsb_j2 wsb_j3 wsb_j4"
# 600 ICP each at placement: sells are capped at 2.5× the owner's balance
# (512 × 2 ICP = 1,024 needs ≥410). Drained to 0 once resting — the cap is
# placement-time only and resting orders hold no reservation.
for j in $JUNK_IDS; do
  mdx_identity_new "$j"; P=$(principal_of "$j"); adm setTestBalance "(principal \"$P\", \"ICP\", $(e8 600.0) : nat)" >/dev/null
done
c=0
while [ "$c" -lt 16 ]; do
  for j in $JUNK_IDS; do bulk32 "$j" "$c" & done
  wait
  freshrequote   # release the 4 × 32 staged asks → they rest behind the AMM ladder
  c=$((c+1))
done
TOTAL=0
for j in $JUNK_IDS; do n=$(resting_count "$j"); TOTAL=$((TOTAL + n)); done
if [ "$TOTAL" -ge 2000 ]; then ok "fixture: $TOTAL junk asks resting on ICP-ICPUSD"; else nok "fixture: expected ≥2,000 resting junk asks" "resting=$TOTAL"; fi
for j in $JUNK_IDS; do P=$(icp identity principal --identity "$j" 2>/dev/null | tail -1); adm setTestBalance "(principal \"$P\", \"ICP\", 0 : nat)" >/dev/null; done
ok "fixture: every junk owner drained to 0 ICP (all $TOTAL asks unfunded)"

echo ""
echo "── §2 the public depth queries complete over the band ──"
T0=$(date +%s)
TKD=$(adm getTakeableDepth "(\"ICP-ICPUSD\", variant { buy }, $(e8 10.50):nat)" | tr -d '_' | grep -oE "[0-9]+" | head -1)
T1=$(date +%s)
TKD_H=$(from_e8 "${TKD:-0}")
if awk -v t="$TKD_H" 'BEGIN{exit (t>400 && t<600?0:1)}'; then
  ok "getTakeableDepth answers the AMM's real depth over the band (${TKD_H} ≈ 500, $((T1 - T0))s)"
else nok "getTakeableDepth must return ~500 (AMM) with the junk counting 0" "got '$TKD_H'"; fi
Q=$(u quoteSwap "(\"ICPUSD\", \"ICP\", $(e8 100000) : nat, $(e8 0.05) : nat)" --query | tr -d '_\n' | tr -s ' ')
Q_OUT=$(echo "$Q" | grep -oE "outAmount = [0-9]+" | grep -oE "[0-9]+")
if echo "$Q" | grep -q "exhausted = true" && awk -v o="$(from_e8 "${Q_OUT:-0}")" 'BEGIN{exit (o>400 && o<600?0:1)}'; then
  ok "quoteSwap answers the AMM's depth and reports exhausted over the band (out=$(from_e8 "${Q_OUT:-0}"))"
else nok "quoteSwap must complete with ~500 ICP and exhausted=true" "$(echo "$Q" | head -c 300)"; fi

echo ""
echo "── §3 devSweepCostProbe: the walk is truncated at the scan budget and its cost is pinned ──"
PR=$(adm devSweepCostProbe '()' --query | tr -d '_\n' | tr -s ' ')
W_SCAN=$(echo "$PR" | grep -oE "walkScanned = [0-9]+" | grep -oE "[0-9]+")
W_DEPTH=$(echo "$PR" | grep -oE "walkDepth = [0-9]+" | grep -oE "[0-9]+")
W_SWAP=$(echo "$PR" | grep -oE "walkSwap = [0-9]+" | grep -oE "[0-9]+")
W_GATE=$(echo "$PR" | grep -oE "walkFokGate = [0-9]+" | grep -oE "[0-9]+")
if echo "$PR" | grep -q "walkTruncated = true"; then ok "the depth walk reports truncated over the band"; else nok "the walk must report truncated on a band wider than WALK_SCAN_MAX" "$(echo "$PR" | grep -oE 'walk[A-Za-z]+ = [a-z0-9]+' | tr '\n' ' ')"; fi
if [ -n "${W_SCAN:-}" ] && [ "$W_SCAN" -gt 0 ] && [ "$W_SCAN" -le 512 ]; then ok "visited $W_SCAN entries ≤ WALK_SCAN_MAX (512)"; else nok "walkScanned must be 1..512" "scanned='${W_SCAN:-}' probe: $(echo "$PR" | head -c 400)"; fi
# Cost pins (instructions; W5-19: a bound is a measurement at a known N). Each
# exclude-set skip costs ~5.5k instructions (the pre-fix 2,053-entry walk hit
# the 5B limit at ~2.1M skips); at N = 512 the walk is ~131k skips, measured
# 0.73B (depth) / 0.72B (swap) / 0.18B (the 256-maker gate) on 2026-09-03.
# 1B leaves headroom while still failing loudly if the budget stops binding.
if [ -n "${W_DEPTH:-}" ] && [ "$W_DEPTH" -lt 1000000000 ]; then ok "getTakeableDepth-shaped walk cost $W_DEPTH instructions (< 1B)"; else nok "depth walk cost unbounded or unreported" "walkDepth='${W_DEPTH:-}'"; fi
if [ -n "${W_SWAP:-}" ] && [ "$W_SWAP" -lt 1000000000 ]; then ok "quoteSwap-shaped walk cost $W_SWAP instructions (< 1B)"; else nok "swap walk cost unbounded or unreported" "walkSwap='${W_SWAP:-}'"; fi
if [ -n "${W_GATE:-}" ] && [ "$W_GATE" -lt 500000000 ]; then ok "FOK-gate-shaped walk (256-maker budget) cost $W_GATE instructions (< 0.5B)"; else nok "FOK gate walk cost unbounded or unreported" "walkFokGate='${W_GATE:-}'"; fi

echo ""
echo "── §4 one release pass over the band completes; a FOK over it records a kill ──"
ICP_R0=$(bal "$UA" ICP)
# 300 < the AMM's ~500 ladder: fills completely IN ONE PASS, so no #3a
# remainder re-defers into the FOK's release below. The one-pass fill is
# pinned by ammRequote committing the fresh ladder to the pool map BEFORE its
# release pass (task 1788541235): before that, the #3a cap read the PREVIOUS
# requote's ids, every level the quote-liveness jitter had just re-placed
# read as closed, and the fill stopped at the highest kept old level — 199 or
# 299 of 300 here, the rest landing in the FOK's release (green or red on the
# jitter's clock; the earlier "freshness" reading of that red was wrong).
u placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 300.0) : nat, $(e8 0.05) : nat, false)" >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
RQ=$(adm requoteAmm '("ICP-ICPUSD")')
ICP_R1=$(bal "$UA" ICP)
if ! echo "$RQ" | grep -qiE "trap|error|reject"; then ok "requoteAmm release pass returned cleanly over the band"; else nok "the release pass must not trap on a junk band (the F4 wedge)" "$(echo "$RQ" | head -c 300)"; fi
if awk -v a="$ICP_R0" -v b="$ICP_R1" 'BEGIN{exit (b-a>299?0:1)}'; then ok "the market buy filled the AMM's ladder through the band (${ICP_R0}→$ICP_R1 ICP)"; else nok "the release must fill the AMM depth ahead of the junk" "icp ${ICP_R0}→$ICP_R1"; fi
RJ0=$(u getMyReleaseRejections '()' --query | grep -oE "Fill-or-kill" | grep -c . || true)
u placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 600.0) : nat, $(e8 0.05) : nat, true)" >/dev/null
ICP_F0=$(bal "$UA" ICP)
freshrequote
ICP_F1=$(bal "$UA" ICP)
RJ1=$(u getMyReleaseRejections '()' --query | grep -oE "Fill-or-kill" | grep -c . || true)
if [ "${RJ1:-0}" -gt "${RJ0:-0}" ] && awk -v a="$ICP_F0" -v b="$ICP_F1" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.0001?0:1)}'; then
  ok "FOK over the band: kill recorded, nothing settled (Fill-or-kill ${RJ0}→$RJ1, ICP unchanged)"
else nok "a FOK the band cannot fill must KILL with a record" "rejections ${RJ0}→$RJ1, icp ${ICP_F0}→$ICP_F1"; fi

# Cleanup: the band is the fixture, not the venue's state.
for j in $JUNK_IDS; do cancel_all_of "$j"; done
LEFT=0; for j in $JUNK_IDS; do n=$(resting_count "$j"); LEFT=$((LEFT + n)); done
[ "$LEFT" -eq 0 ] && ok "cleanup: junk band cancelled" || nok "cleanup: junk still resting" "left=$LEFT"
adm setTestOrderCap "(null)" >/dev/null 2>&1
adm setTestTimersPaused '(false)' >/dev/null 2>&1

echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
