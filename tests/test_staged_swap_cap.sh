#!/bin/bash
# H-13 (F22 a/b) — staged cross-swaps count toward the per-owner staged cap
# and the shed-floor's staged-depth signal.
#
# executeSwapCross's staged branch used to reserve, allocate an id and insert
# into deferredSwaps with no STAGED_CAP_PER_OWNER check and no incStagedCount,
# and recomputeShedFloor keyed on Map.size(deferredExecs) alone — so one
# account could soft-lock ~10k refundable cross-swaps that neither the cap
# nor the floor ever saw. The fix: the cap check + counter in the staged
# branch (same scorecardKeyOf key as parkDeferred), decStagedCount in
# removeDeferredSwap, the floor sums deferredExecs + deferredSwaps, and
# getStagedIndexAudit (f) reconciles the counter against both maps.
#
#   §1 baseline: fresh identity, timers paused, count 0, audit consistent
#   §2 32 cross-swaps stage; myStagedCount / whyAmIRefused.stagedCount = 32
#   §3 the 33rd is REFUSED with the cap text and moves nothing
#   §4 adjacent cases: the immediate (FOK) path is not the staged path, so
#      it is not cap-refused; cancelling ONE frees exactly one slot
#      (one-unit case), which the next swap takes, then the cap holds again;
#      (c) task 1788520988: the DIRECT staged path (ICP→ICPUSD through
#      executeSwapDirect) and placeMarketOrder say the SAME cap text at the
#      cap — not their balance texts — while below the cap with a zero
#      available balance the balance texts still appear
#   §5 staged bands pinned relative to the OTHER staged depth (execLive) →
#      the floor rises from cross-swap depth ALONE; `swap` refused at the
#      gate; bands released → floor 0
#   §6 cancelAllMyOrders drains them through removeDeferredSwap → count 0,
#      audit consistent, swapLive back to the baseline
#
# State-light: no resetExchange, no seeding — safe against any #dev venue
# with ICP-ICPUSD and BTC-ICPUSD markets. Needs #dev (setTestBalance,
# setTestTimersPaused, setTestStagedShedBands).

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of / mdx_ok — the sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8()  { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
u()   { icp canister call --candid "$MDX_CANDID" --identity sswc_u backend "$@" 2>&1; }
mdx_identity_new sswc_u; U=$(principal_of sswc_u)

CAP=32
gate_refused() { echo "$1" | grep -qiE "refus|inspect|403"; }
# Candid nat field readers (underscore separators stripped, first match).
policy_nat() { u getAccessPolicy '()' --query 2>/dev/null | tr -d '_\n' | tr -s ' ' | grep -oE "$1 = [0-9]+" | grep -oE '[0-9]+' | head -1; }
why_nat()    { u whyAmIRefused '()' --query 2>/dev/null | tr -d '_\n' | tr -s ' ' | grep -oE "$1 = [0-9]+" | grep -oE '[0-9]+' | head -1; }
avail_icp()  { u getMyAvailableBalance '("ICP")' --query 2>/dev/null | tr -d '_\n' | grep -oE '[0-9]+' | head -1; }
AUDIT=""
audit()  { AUDIT=$(adm getStagedIndexAudit '()' --query | tr -d '_\n' | tr -s ' '); }
afield() { echo "$AUDIT" | grep -oE "$1 = [0-9]+" | head -1 | grep -oE "[0-9]+"; }
assert_consistent() {
  audit
  if echo "$AUDIT" | grep -q 'consistent = true'; then ok "$1: audit consistent"
  else nok "$1: audit INCONSISTENT" "$(echo "$AUDIT" | head -c 300)"; fi
}
# ICP → BTC, 10 ICP, 5% slippage: the sealed (staged) cross path.
xswap() { u swap "(record { fromToken=\"ICP\"; toToken=\"BTC\"; amount=$(e8 10.0) : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.05) : nat } }; noPartialFill=${1:-false} })"; }

ANCHOR_BOOT=0   # §4(c) bootstrapped an ICP-ICPUSD anchor on a wiped venue → disable it again at exit
restore() {  # leave the venue as found: bands off, our swaps gone, timers running
  adm setTestStagedShedBands '(null)' >/dev/null 2>&1
  [ "$ANCHOR_BOOT" = 1 ] && adm enableAmm '("ICP-ICPUSD", false)' >/dev/null 2>&1
  sleep 4   # past the 3s commit window so the bulk cancel sweeps the youngest swap too
  u cancelAllMyOrders '(null)' >/dev/null 2>&1
  adm setTestTimersPaused '(false)' >/dev/null 2>&1
}
on_exit restore   # registered, not installed directly: _scratch.sh (via _lib.sh) owns the one exit hook, and the identity cleanup rides it

echo "── §1 baseline ──"
adm setTestTimersPaused '(true)' >/dev/null    # no GEPTOR release / expiry sweep underneath the counts
R=$(adm setTestBalance "(principal \"$U\", \"ICP\", $(e8 1000.0) : nat)")
if gate_refused "$R"; then nok "setTestBalance refused — cannot fund/register" "$R"; else ok "sswc_u funded with 1000 ICP (registered)"; fi
C0=$(policy_nat myStagedCount); C0=${C0:-x}
[ "$C0" = "0" ] && ok "myStagedCount = 0 at start" || nok "myStagedCount not 0 at start" "got $C0"
assert_consistent "§1"
S0=$(afield swapLive); S0=${S0:-0}; E0=$(afield execLive); E0=${E0:-0}
echo "   venue baseline: execLive = $E0, swapLive = $S0"

echo "── §2 $CAP cross-swaps stage from one account ──"
staged=0; i=0; LAST_ID=""
while [ $i -lt $CAP ]; do
  R=$(xswap)
  if mdx_ok "$R" && echo "$R" | grep -q "swapOrderId = opt"; then staged=$((staged+1)); LAST_ID=$(echo "$R" | tr -d '_' | grep -oE "swapOrderId = opt \([0-9]+" | grep -oE '[0-9]+'); else echo "   swap #$((i+1)) did not stage: $(echo "$R" | tr -s '[:space:]' ' ' | head -c 160)"; fi
  i=$((i+1))
done
[ "$staged" = "$CAP" ] && ok "$CAP cross-swaps staged" || nok "only $staged of $CAP staged" "see above"
C=$(policy_nat myStagedCount); C=${C:-x}
[ "$C" = "$CAP" ] && ok "getAccessPolicy.myStagedCount = $CAP (cross-swaps counted)" || nok "myStagedCount ignores staged cross-swaps" "got $C, want $CAP"
W=$(why_nat stagedCount); W=${W:-x}
[ "$W" = "$CAP" ] && ok "whyAmIRefused.stagedCount = $CAP" || nok "whyAmIRefused.stagedCount" "got $W, want $CAP"
assert_consistent "§2"
S=$(afield swapLive); S=${S:-0}
[ "$S" -ge $((S0 + CAP)) ] && ok "swapLive grew by $CAP ($S0 → $S)" || nok "swapLive did not grow by $CAP" "$S0 → $S"

echo "── §3 swap #$((CAP+1)) is refused and moves nothing ──"
A_BEFORE=$(avail_icp); A_BEFORE=${A_BEFORE:-0}
R=$(xswap)
if echo "$R" | grep -q "Staged-order cap reached"; then ok "swap #$((CAP+1)) refused: cap text"; else nok "swap #$((CAP+1)) NOT refused with the cap text" "$(echo "$R" | tr -s '[:space:]' ' ' | head -c 200)"; fi
A_AFTER=$(avail_icp); A_AFTER=${A_AFTER:-0}
[ "$A_AFTER" = "$A_BEFORE" ] && ok "available ICP unchanged by the refusal ($A_AFTER)" || nok "refusal moved balance" "$A_BEFORE → $A_AFTER"
C=$(policy_nat myStagedCount); C=${C:-x}
[ "$C" = "$CAP" ] && ok "myStagedCount still $CAP" || nok "count moved on a refusal" "got $C"

echo "── §4 adjacent cases ──"
# (a) noPartialFill=true STAGES too (H-21 retired the immediate two-leg path) — the same cap, the same refusal, nothing moved.
A_BEFORE=$(avail_icp); A_BEFORE=${A_BEFORE:-0}
R=$(xswap true)
if echo "$R" | grep -q "Staged-order cap reached"; then ok "FOK cross-swap is staged too: cap-refused at $CAP (no immediate path)"; else nok "FOK cross-swap bypassed the staged cap (an immediate path)" "$(echo "$R" | tr -s '[:space:]' ' ' | head -c 160)"; fi
A_AFTER=$(avail_icp); A_AFTER=${A_AFTER:-0}
[ "$A_AFTER" = "$A_BEFORE" ] && ok "available ICP unchanged by the FOK refusal ($A_AFTER)" || nok "FOK refusal moved balance" "$A_BEFORE → $A_AFTER"
# (b) the one-unit case: cancel exactly one (after the 3s commit window; the id
# is the swapOrderId the staging reply returned — staged swaps are not in
# getMyOrders) → one slot → taken → cap holds again.
sleep 4
OID=$LAST_ID
CR=$(u cancelMyOrder "(${OID:-0} : nat)")
if mdx_ok "$CR"; then ok "cancelMyOrder(${OID:-?}) on one staged swap"; else nok "cancel refused" "$(echo "$CR" | head -c 160)"; fi
C=$(policy_nat myStagedCount); C=${C:-x}
[ "$C" = "$((CAP-1))" ] && ok "myStagedCount = $((CAP-1)) after one cancel (decStagedCount in removeDeferredSwap)" || nok "count after cancel" "got $C, want $((CAP-1))"
R=$(xswap)
if mdx_ok "$R" && echo "$R" | grep -q "swapOrderId = opt"; then ok "the freed slot admits one more cross-swap"; else nok "freed slot not admitted" "$(echo "$R" | head -c 160)"; fi
REFILL_ID=$(echo "$R" | tr -d '_' | grep -oE "swapOrderId = opt \([0-9]+" | grep -oE '[0-9]+')
R=$(xswap)
if echo "$R" | grep -q "Staged-order cap reached"; then ok "cap holds again at $CAP"; else nok "cap did not hold after the refill" "$(echo "$R" | tr -s '[:space:]' ' ' | head -c 160)"; fi
# (c) task 1788520988: executeSwapDirect's staged arms and placeMarketOrder
# used to map EVERY parkDeferred null onto their balance texts ("Insufficient
# available balance to stage this swap" / "Could not stage the order"), but
# parkDeferred returns null for the per-owner cap too — a bot at the cap was
# told its balance was short and retried forever. Same cause, same sentence
# as the cross path (§3): the cap is checked BEFORE parkDeferred. The balance
# texts stay for the cause they name: below the cap with ZERO available ICP
# (raw balance pinned to exactly the reserved amount) both paths still say them.
CAP_TEXT="Staged-order cap reached"
DSWAP_BAL="Insufficient available balance to stage this swap"
MKT_BAL="Could not stage the order"
# Both direct paths need a slippage anchor on ICP-ICPUSD (slippageAnchor: the
# enabled AMM's refPrice, else book-best — and with timers paused nothing
# releases onto the book), which the cross path never needed at staging. A
# missing anchor refuses "No liquidity" BEFORE the cap, so the assertions
# below would test the wrong refusal. Under suite order the cross_swap
# siblings leave the venue wiped (resetExchange at exit), so bootstrap an
# anchor ONLY when there is none: an empty pool at a pinned ref price,
# enabled, no liquidity (the test_cross_swap_budget shape) — undone at exit.
anchor_rp() { adm getAmmPool '("ICP-ICPUSD")' --query 2>/dev/null | tr -d '_\n' | tr -s ' ' | grep 'enabled = true' | grep -oE 'refPrice = [0-9]+' | grep -oE '[0-9]+' | head -1; }
RP=$(anchor_rp); RP=${RP:-0}
if [ "$RP" -gt 0 ]; then ok "ICP-ICPUSD anchor present (AMM refPrice $RP) — the direct paths can reach the cap check"
else
  ANCHOR_BOOT=1
  adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
  adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null 2>&1
  adm enableAmm '("ICP-ICPUSD", true)' >/dev/null 2>&1
  RP=$(anchor_rp); RP=${RP:-0}
  [ "$RP" -gt 0 ] && ok "ICP-ICPUSD anchor bootstrapped on a wiped venue (empty pool, refPrice $RP, enabled; disabled again at exit)" || nok "could not bootstrap an ICP-ICPUSD anchor (non-vacuity guard: the direct paths would refuse 'No liquidity' before the cap)" "getAmmPool: $(adm getAmmPool '("ICP-ICPUSD")' --query 2>&1 | tr -s '[:space:]' ' ' | head -c 200)"
fi
# ICP → ICPUSD, 10 ICP: the DIRECT staged path (a #sell on ICP-ICPUSD).
dswap() { u swap "(record { fromToken=\"ICP\"; toToken=\"ICPUSD\"; amount=$(e8 10.0) : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.05) : nat } }; noPartialFill=false })"; }
mkt()   { u placeMarketOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 10.0) : nat, $(e8 0.05) : nat, false)"; }
A_BEFORE=$(avail_icp); A_BEFORE=${A_BEFORE:-0}
R=$(dswap)
if echo "$R" | grep -q "$CAP_TEXT"; then ok "direct ICP→ICPUSD swap at the cap: the cap text"; else nok "direct swap at the cap did NOT say the cap text" "$(echo "$R" | tr -s '[:space:]' ' ' | head -c 200)"; fi
if echo "$R" | grep -q "$DSWAP_BAL"; then nok "direct swap at the cap blamed the balance" "$(echo "$R" | tr -s '[:space:]' ' ' | head -c 200)"; else ok "direct swap at the cap did not blame the balance"; fi
R=$(mkt)
if echo "$R" | grep -q "$CAP_TEXT"; then ok "placeMarketOrder at the cap: the cap text"; else nok "placeMarketOrder at the cap did NOT say the cap text" "$(echo "$R" | tr -s '[:space:]' ' ' | head -c 200)"; fi
if echo "$R" | grep -q "$MKT_BAL"; then nok "placeMarketOrder at the cap blamed the balance" "$(echo "$R" | tr -s '[:space:]' ' ' | head -c 200)"; else ok "placeMarketOrder at the cap did not blame the balance"; fi
A_AFTER=$(avail_icp); A_AFTER=${A_AFTER:-0}
[ "$A_AFTER" = "$A_BEFORE" ] && ok "available ICP unchanged by both direct-path refusals ($A_AFTER)" || nok "a direct-path cap refusal moved balance" "$A_BEFORE → $A_AFTER"
C=$(policy_nat myStagedCount); C=${C:-x}
[ "$C" = "$CAP" ] && ok "myStagedCount still $CAP after the direct-path refusals" || nok "count moved on a direct-path refusal" "got $C"
# Below the cap with ZERO available: free one slot (commit window), pin the
# raw ICP balance to the reserved amount (raw − available) → available 0.
sleep 4
CR=$(u cancelMyOrder "(${REFILL_ID:-0} : nat)")
if mdx_ok "$CR"; then ok "cancelMyOrder(${REFILL_ID:-?}) frees one slot for the balance case"; else nok "cancel for the balance case refused" "$(echo "$CR" | head -c 160)"; fi
AV=$(avail_icp); AV=${AV:-0}
RESERVED=$(( $(e8 1000.0) - AV ))
adm setTestBalance "(principal \"$U\", \"ICP\", $RESERVED : nat)" >/dev/null
AV0=$(avail_icp); AV0=${AV0:-x}
[ "$AV0" = "0" ] && ok "available ICP pinned to 0 (raw = reserved $RESERVED) below the cap" || nok "could not pin available ICP to 0 (non-vacuity guard)" "available=$AV0 reserved=$RESERVED"
R=$(dswap)
if echo "$R" | grep -q "$DSWAP_BAL"; then ok "direct swap below the cap, zero available: the balance text"; else nok "direct swap with zero available lost its balance text" "$(echo "$R" | tr -s '[:space:]' ' ' | head -c 200)"; fi
if echo "$R" | grep -q "$CAP_TEXT"; then nok "direct swap below the cap blamed the cap" "$(echo "$R" | tr -s '[:space:]' ' ' | head -c 200)"; else ok "direct swap below the cap did not blame the cap"; fi
R=$(mkt)
if echo "$R" | grep -q "$MKT_BAL"; then ok "placeMarketOrder below the cap, zero available: the balance text"; else nok "placeMarketOrder with zero available lost its balance text" "$(echo "$R" | tr -s '[:space:]' ' ' | head -c 200)"; fi
if echo "$R" | grep -q "$CAP_TEXT"; then nok "placeMarketOrder below the cap blamed the cap" "$(echo "$R" | tr -s '[:space:]' ' ' | head -c 200)"; else ok "placeMarketOrder below the cap did not blame the cap"; fi
# Back to the §2 shape for §5/§6: raw ICP 1000 again, the freed slot refilled.
adm setTestBalance "(principal \"$U\", \"ICP\", $(e8 1000.0) : nat)" >/dev/null
R=$(xswap)
if mdx_ok "$R" && echo "$R" | grep -q "swapOrderId = opt"; then ok "slot refilled: back at $CAP for §5/§6"; else nok "refill after the balance case not admitted" "$(echo "$R" | head -c 160)"; fi
C=$(policy_nat myStagedCount); C=${C:-x}
[ "$C" = "$CAP" ] && ok "myStagedCount = $CAP again" || nok "count after the (c) round-trip" "got $C, want $CAP"
assert_consistent "§4"

echo "── §5 staged bands relative to execLive → the floor rises from cross-swap depth ALONE ──"
audit; E=$(afield execLive); E=${E:-0}; S=$(afield swapLive); S=${S:-0}
# Bands strictly above the exec depth and at/below exec + our swaps: only
# counting deferredSwaps can reach them. Pre-fix (execs only) the floor stays 0.
SOFT=$((E + 8)); HARD=$((E + 24)); SL=$((E + 4)); HL=$((E + 16))
adm setTestStagedShedBands "(opt record { 0 = $SOFT : nat; 1 = $HARD : nat; 2 = $SL : nat; 3 = $HL : nat })" >/dev/null
FLOOR=$(policy_nat shedFloor); FLOOR=${FLOOR:-0}
if [ "$FLOOR" -ge 1 ]; then ok "shedFloor = $FLOOR from staged cross-swap depth alone (execLive=$E swapLive=$S bands=$SOFT/$HARD)"; else nok "floor did not rise — deferredSwaps not in the staged-depth signal" "execLive=$E swapLive=$S bands=$SOFT/$HARD floor=$FLOOR"; fi
R=$(xswap)
if gate_refused "$R"; then ok "swap refused pre-consensus under the staged floor"; else nok "entry method was NOT shed under the floor" "$(echo "$R" | tr -s '[:space:]' ' ' | head -c 200)"; fi
WHY=$(u whyAmIRefused '()' --query | tr -d '\n' | tr -s ' ')
echo "$WHY" | grep -q "admittedNow = false" && ok "whyAmIRefused: admittedNow = false under the floor" || nok "diagnostic says admitted while the gate refused" "$WHY"
adm setTestStagedShedBands '(null)' >/dev/null
FLOOR2=$(policy_nat shedFloor); FLOOR2=${FLOOR2:-9}
[ "$FLOOR2" -eq 0 ] && ok "floor back to 0 under the real 2,000 bands" || nok "floor stuck after band release" "floor=$FLOOR2"

echo "── §6 drain through removeDeferredSwap ──"
sleep 4   # commit window on the youngest swap
N=$(u cancelAllMyOrders '(null)' | tr -d '_' | grep -oE '[0-9]+' | head -1); N=${N:-0}
[ "$N" -ge "$CAP" ] && ok "cancelAllMyOrders swept $N staged swaps" || nok "bulk cancel swept too few" "got $N, want ≥ $CAP"
C=$(policy_nat myStagedCount); C=${C:-x}
[ "$C" = "0" ] && ok "myStagedCount = 0 after the sweep" || nok "count leaks after cancel-all" "got $C"
assert_consistent "§6"
S=$(afield swapLive); S=${S:-0}
[ "$S" = "$S0" ] && ok "swapLive back to baseline ($S0)" || nok "swapLive did not return to baseline" "$S0 → $S"
A_END=$(avail_icp); A_END=${A_END:-0}
[ "$A_END" -ge "$(e8 985.0)" ] && ok "reservations refunded (available ICP = $A_END)" || nok "ICP still reserved after the sweep" "available=$A_END"

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_staged_swap_cap ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_staged_swap_cap ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
