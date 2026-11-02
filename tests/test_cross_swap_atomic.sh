#!/bin/bash
# H-21 (F19 + F38) — the all-or-nothing cross-swap is STAGED and fill-or-kill
# checked at release; nothing player-reachable settles inside the caller's
# own message, and a killed FOK moves nothing.
#
# executeSwapCross's noPartialFill=true branch used to run both legs
# synchronously inside swap() itself (buildProtectionCtx — no fresh-price
# gate, no sweep-before-release, no L4 shield: the one taker that bypassed
# the sealed model), and it was not FOK either: both engine legs ran with
# noPartialFill=false, so a thin buy book left the sell leg's proceeds
# unconverted under an honest-partial #ok (W2-03 fixed the settle-then-#err
# half of that; the semantics stayed "partial"). Fixed: every cross-swap
# stages; the FOK flag rides the swapFok side map; releaseCrossSwap runs
# fokCrossGate FIRST — both legs simulated under the release ctx and caps —
# and a short leg kills the swap before anything moves.
#
#   §1 buy market has NO liquidity → swap(FOK) returns a STAGED id; the
#      resting bid's owner is untouched by the call (nothing matched
#      synchronously — F19); at release the swap is KILLED: outcome not
#      filled, the seller's balance byte-identical, no fill on the tape
#   §2 buy market has a THIN resting ask (absorbs less than the proceeds) →
#      FOK killed at release, nothing moved, the thin ask whole (F38: the
#      pre-fix build converted 3 ICP and left most proceeds as ICPUSD)
#   §2b (adjacent) the SAME thin book with noPartialFill=false → the plain
#      cross-swap still fills what it can (honest partial, note says so)
#   §3 (adjacent, positive control) buy depth ≥ proceeds → the FOK converts
#      the FULL amount at release: fromAmount == amount, BTC received, the
#      bid owner's balances move only NOW, the sell fill is on the tape
#   §4 (1788661917) the sell leg's maker gates ROUND LIKE THEIR DEBIT: a
#      bid funded to exactly ⌊qty × price⌋ + fee (non-integral cost) is
#      TAKEN whole by the FOK's sell leg with a residue of 0; one quote
#      unit less is a clean kill (nothing moves, the bid survives, no
#      mid-match notice)
#
# Books are users-only (AMM pools exist + enabled but UNFUNDED, so the
# release path is exercised with exactly the maker levels shown). Timers
# paused throughout (journal stays inspectable). ⚠️ resetExchange.
# Needs #dev.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
m1() { icp canister call --candid "$MDX_CANDID" --identity xsa_m1 backend "$@" 2>&1; }
s2() { icp canister call --candid "$MDX_CANDID" --identity xsa_s2 backend "$@" 2>&1; }
w()  { icp canister call --candid "$MDX_CANDID" --identity xsa_w  backend "$@" 2>&1; }
wq() { icp canister call --candid "$MDX_CANDID" --identity xsa_w  backend "$@" --query 2>&1; }
mdx_identity_new xsa_m1; M1=$(principal_of xsa_m1); mdx_identity_new xsa_s2; S2=$(principal_of xsa_s2); mdx_identity_new xsa_w; W=$(principal_of xsa_w)

STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }

SELLM="ICP-ICPUSD"; BUYM="BTC-ICPUSD"
balN() { adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+"; }
# Quantity (base units) resting at an e8 price level on a market's book, or
# empty when gone (icp prints one field per line: join + squeeze first).
level_qty() { adm getOrderBook "(\"$1\")" | tr -d '_' | tr '\n' ' ' | tr -s ' ' | grep -oE "quantity = [0-9]+ : nat; price = $2 " | grep -oE "quantity = [0-9]+" | grep -oE "[0-9]+" | head -1; }
# Stamp a market's mark fresh + requote: releases everything staged before
# the stamp (an unfunded pool posts no ladder, so the book stays users-only).
stamp() { adm setAmmRefPrice "(\"$1\", $2 : nat)" >/dev/null; adm requoteAmm "(\"$1\")" >/dev/null; }
# Release staged cross-swaps: both marks postdate the staging, then the
# deferred-swap pass runs by hand (timers are paused).
release_cross() { adm setAmmRefPrice "(\"$SELLM\", $(e8 10.0) : nat)" >/dev/null; adm setAmmRefPrice "(\"$BUYM\", $(e8 100.0) : nat)" >/dev/null; adm adminRunDeferredSwaps '()' >/dev/null 2>&1; }
fok_swap() { w swap "(record { fromToken=\"ICP\"; toToken=\"BTC\"; amount=$(e8 3.0) : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.05) : nat } }; noPartialFill=$1 })" | tr -d '_\n' | tr -s ' '; }
recent() { wq getMyRecentSwap '()' | tr -d '_\n' | tr -s ' '; }
fills_on_tape() { wq getMyUnshippedEvents '()' | tr -d '_\n' | tr -s ' ' | grep -oF 'fill' | wc -l | tr -d ' '; }

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
for m in "$SELLM" "$BUYM"; do adm createAmmPool "(\"$m\")" >/dev/null 2>&1; adm enableAmm "(\"$m\", true)" >/dev/null; done
adm setAmmRefPrice "(\"$SELLM\", $(e8 10.0) : nat)" >/dev/null
adm setAmmRefPrice "(\"$BUYM\", $(e8 100.0) : nat)" >/dev/null

adm setTestBalance "(principal \"$M1\", \"ICPUSD\", $(e8 1000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$M1\", \"ICP\", 0 : nat)" >/dev/null
adm setTestBalance "(principal \"$W\", \"ICP\", $(e8 3.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$W\", \"ICPUSD\", 0 : nat)" >/dev/null
adm setTestBalance "(principal \"$W\", \"BTC\", 0 : nat)" >/dev/null
adm setTestBalance "(principal \"$S2\", \"BTC\", $(e8 1.0) : nat)" >/dev/null

echo "── setup: a passive user bid rests on the sell market; the buy market is empty ──"
m1 placeLimitOrder "(\"$SELLM\", variant { buy }, $(e8 9.90) : nat, $(e8 5.0) : nat)" >/dev/null
stamp "$SELLM" "$(e8 10.0)"
BIDQ0=$(level_qty "$SELLM" "$(e8 9.90)")
if [ "${BIDQ0:-0}" = "$(e8 5.0)" ]; then ok "maker bid 5 ICP resting at 9.90 (users-only book)"; else nok "bid did not rest" "qty=${BIDQ0:-none}"; fi
BBOOK=$(adm getOrderBook "(\"$BUYM\")" | tr -d '_\n' | tr -s ' ')
if ! echo "$BBOOK" | grep -q "price ="; then ok "buy market has no liquidity at all"; else nok "buy market should be empty" "$(echo "$BBOOK" | head -c 200)"; fi

echo "── §1 no buy-side liquidity → FOK stages, matches nothing in the call, is KILLED at release ──"
W_ICP0=$(balN "$W" ICP); M1_USD0=$(balN "$M1" ICPUSD); M1_ICP0=$(balN "$M1" ICP)
R=$(fok_swap true)
if echo "$R" | grep -q "swapOrderId = opt"; then ok "swap(noPartialFill=true) returns a STAGED id (no immediate path)"; else nok "FOK cross-swap should stage" "$(echo "$R" | head -c 250)"; fi
if echo "$R" | grep -q "fromAmount = 0 "; then ok "the reply carries no settlement (fromAmount = 0)"; else nok "reply should report nothing settled" "$(echo "$R" | head -c 250)"; fi
BIDQ1=$(level_qty "$SELLM" "$(e8 9.90)"); M1_USD1=$(balN "$M1" ICPUSD); M1_ICP1=$(balN "$M1" ICP)
if [ "${BIDQ1:-0}" = "$BIDQ0" ] && [ "${M1_USD1:-0}" = "$M1_USD0" ] && [ "${M1_ICP1:-x}" = "$M1_ICP0" ]; then
  ok "the bid owner is untouched by the call (bid $BIDQ1 whole, ICPUSD $M1_USD1, ICP ${M1_ICP1:-0}) — nothing matched synchronously"
else nok "the call matched against the resting bid (the immediate path, resurfaced)" "bid $BIDQ0 → ${BIDQ1:-gone} usd $M1_USD0 → $M1_USD1"; fi
release_cross
RC=$(recent); W_ICP1=$(balN "$W" ICP); W_USD1=$(balN "$W" ICPUSD); BIDQ2=$(level_qty "$SELLM" "$(e8 9.90)")
echo "   outcome: $(echo "$RC" | head -c 300)"
if echo "$RC" | grep -q "filled = false" && echo "$RC" | grep -q "Fill-or-kill swap killed"; then ok "outcome: not filled — \"Fill-or-kill swap killed at release\""; else nok "the FOK should be killed at release" "$RC"; fi
if echo "$RC" | grep -q "BTC book absorbs only"; then ok "the note names the short leg (the BTC book)"; else nok "note should name the buy leg" "$RC"; fi
if [ "${W_ICP1:-0}" = "$W_ICP0" ] && [ "${W_USD1:-1}" = "0" ]; then ok "killed ⇒ nothing settled (ICP byte-identical $W_ICP1, ICPUSD 0)"; else nok "the sell leg settled under a kill" "icp $W_ICP0 → $W_ICP1 usd → $W_USD1"; fi
if [ "${BIDQ2:-0}" = "$BIDQ0" ]; then ok "the 9.90 bid is whole after the release pass"; else nok "the bid was hit by a killed FOK" "before=$BIDQ0 after=${BIDQ2:-gone}"; fi
F1=$(fills_on_tape)
if [ "${F1:-1}" = "0" ]; then ok "no fill on the tape (event journal empty of fills)"; else nok "a killed FOK left fills on the tape" "fills=$F1"; fi

echo "── §2 THIN buy-side ask (absorbs less than the proceeds) → FOK killed at release, nothing moved ──"
s2 placeLimitOrder "(\"$BUYM\", variant { sell }, $(e8 101.0) : nat, $(e8 0.15) : nat)" >/dev/null
stamp "$BUYM" "$(e8 100.0)"
ASKQ0=$(level_qty "$BUYM" "$(e8 101.0)")
if [ "${ASKQ0:-0}" = "$(e8 0.15)" ]; then ok "thin ask 0.15 BTC resting at 101 (≈\$15 of depth against ≈\$29.7 of proceeds)"; else nok "thin ask did not rest" "qty=${ASKQ0:-none}"; fi
R=$(fok_swap true)
if echo "$R" | grep -q "swapOrderId = opt"; then ok "FOK cross-swap staged"; else nok "FOK cross-swap should stage" "$(echo "$R" | head -c 250)"; fi
release_cross
RC=$(recent); W_ICP2=$(balN "$W" ICP); W_USD2=$(balN "$W" ICPUSD); W_BTC2=$(balN "$W" BTC); ASKQ1=$(level_qty "$BUYM" "$(e8 101.0)"); S2_BTC=$(balN "$S2" BTC)
echo "   outcome: $(echo "$RC" | head -c 300)"
if echo "$RC" | grep -q "filled = false" && echo "$RC" | grep -q "Fill-or-kill swap killed" && echo "$RC" | grep -q "BTC book absorbs only"; then ok "outcome: killed — the BTC book absorbs only part of the proceeds"; else nok "thin buy book should kill the FOK" "$RC"; fi
if [ "${W_ICP2:-0}" = "$W_ICP0" ] && [ "${W_USD2:-1}" = "0" ] && [ "${W_BTC2:-1}" = "0" ]; then ok "nothing moved (ICP $W_ICP2, ICPUSD 0, BTC 0)"; else nok "a killed FOK moved balances (the pre-fix honest-partial)" "icp $W_ICP0 → $W_ICP2 usd $W_USD2 btc $W_BTC2"; fi
if [ "${ASKQ1:-0}" = "$ASKQ0" ] && [ "${S2_BTC:-0}" = "$(e8 1.0)" ]; then ok "the thin ask is whole (0.15 BTC) and its owner untouched"; else nok "the thin ask was hit by a killed FOK" "ask $ASKQ0 → ${ASKQ1:-gone} s2btc=$S2_BTC"; fi
F2=$(fills_on_tape)
if [ "${F2:-1}" = "0" ]; then ok "still no fill on the tape"; else nok "fills on the tape under a kill" "fills=$F2"; fi

echo "── §2b (adjacent) the SAME thin book, noPartialFill=false → the plain cross-swap fills what it can ──"
R=$(fok_swap false)
if echo "$R" | grep -q "swapOrderId = opt"; then ok "plain cross-swap staged"; else nok "plain cross-swap should stage" "$(echo "$R" | head -c 250)"; fi
release_cross
RC=$(recent); W_ICP3=$(balN "$W" ICP); W_BTC3=$(balN "$W" BTC)
echo "   outcome: $(echo "$RC" | head -c 300)"
if echo "$RC" | grep -q "filled = true" && echo "$RC" | grep -q "Partly filled"; then ok "outcome: filled, \"Partly filled — unconverted ICP returned\" (partial is the non-FOK default)"; else nok "the plain swap should partially fill" "$RC"; fi
if [ "${W_ICP3:-0}" -lt "$W_ICP0" ] && [ "${W_ICP3:-0}" -gt 0 ] && [ "${W_BTC3:-0}" -gt 0 ]; then ok "some ICP converted ($W_ICP0 → $W_ICP3), BTC received ($W_BTC3)"; else nok "partial conversion expected" "icp $W_ICP0 → $W_ICP3 btc $W_BTC3"; fi
F3=$(fills_on_tape)
if [ "${F3:-0}" -gt 0 ]; then ok "the partial's fills ARE on the tape ($F3 fill events)"; else nok "settled fills missing from the tape" "fills=$F3"; fi

echo "── §3 (positive control) buy depth ≥ proceeds → the FOK converts the FULL amount at release ──"
adm setTestBalance "(principal \"$W\", \"ICP\", $(e8 3.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$W\", \"ICPUSD\", 0 : nat)" >/dev/null
adm setTestBalance "(principal \"$W\", \"BTC\", 0 : nat)" >/dev/null
s2 placeLimitOrder "(\"$BUYM\", variant { sell }, $(e8 101.5) : nat, $(e8 0.5) : nat)" >/dev/null   # 101.5: its own level, off the thin 101 remainder
stamp "$BUYM" "$(e8 100.0)"
ASKQ2=$(level_qty "$BUYM" "$(e8 101.5)")
if [ "${ASKQ2:-0}" = "$(e8 0.5)" ]; then ok "deep ask 0.5 BTC resting at 101.5 (≈\$50 of depth)"; else nok "deep ask did not rest" "qty=${ASKQ2:-none}"; fi
M1_ICP2=$(balN "$M1" ICP); BIDQ3=$(level_qty "$SELLM" "$(e8 9.90)"); F3=$(fills_on_tape)
R=$(fok_swap true)
if echo "$R" | grep -q "swapOrderId = opt"; then ok "FOK cross-swap staged"; else nok "FOK cross-swap should stage" "$(echo "$R" | head -c 250)"; fi
M1_ICP3=$(balN "$M1" ICP); BIDQ4=$(level_qty "$SELLM" "$(e8 9.90)")
if [ "${M1_ICP3:-x}" = "$M1_ICP2" ] && [ "${BIDQ4:-0}" = "$BIDQ3" ]; then ok "bid owner unchanged until the release pass (ICP $M1_ICP3, bid $BIDQ4)"; else nok "the call itself matched" "icp $M1_ICP2 → $M1_ICP3 bid $BIDQ3 → ${BIDQ4:-gone}"; fi
release_cross
RC=$(recent); W_ICP4=$(balN "$W" ICP); W_BTC4=$(balN "$W" BTC); M1_ICP4=$(balN "$M1" ICP); F4=$(fills_on_tape)
echo "   outcome: $(echo "$RC" | head -c 300)"
if echo "$RC" | grep -q "filled = true" && echo "$RC" | grep -q "fromAmount = $(e8 3.0) "; then ok "outcome: filled, fromAmount = 3 ICP (the FULL amount)"; else nok "the FOK should convert the full amount" "$RC"; fi
if [ "${W_ICP4:-1}" = "0" ] && [ "${W_BTC4:-0}" -gt "$(e8 0.28)" ]; then ok "3 ICP sold (ICP 0), $(awk -v b="$W_BTC4" 'BEGIN{printf "%.4f", b/1e8}') BTC received"; else nok "balances should reflect the full conversion" "icp $W_ICP4 btc $W_BTC4"; fi
if [ "${M1_ICP4:-0}" = "$((M1_ICP3 + $(e8 3.0)))" ]; then ok "the bid owner received the 3 ICP at the release pass, not before"; else nok "bid owner's fill wrong" "icp $M1_ICP3 → $M1_ICP4"; fi
if [ "${F4:-0}" -gt "${F3:-0}" ]; then ok "the FOK's fills are on the tape ($F3 → $F4 fill events)"; else nok "settled FOK fills missing from the tape" "fills $F3 → $F4"; fi

# ═══ 1788661917: the sell leg's maker gates round like their DEBIT. A maker-buy
# slice settles at tradeCost = ⌊qty × price⌋ + fee(⌊…⌋) (conservation: the
# seller is credited on the SAME floored cost). 33.33333333 ICP @ 9.99 costs
# 3,333,333,333 × 9.99 = 33,299,999,996.67 quote units — floor 33,299,999,996,
# + the 5 bps maker fee on it (16,649,999) = 33,316,649,995 exactly; the ceil
# is one unit more. (9.99: strictly inside the AMM's default 20 bps ladder —
# above its 9.98 best bid, below its 10.02 best ask — so M2 is the unique
# best bid and the engine sizes its FIRST slice off it: the fee-funded AMM
# ladder must never share the level, or a same-price AMM crumb ahead of M2
# shrinks M2's slice to one it CAN fund and the control fills, honestly.) executeMarketOrderProtected's early makerNeeds pre-gate
# and its FOK pre-check simulateAvailableFill — the cross-swap legs' engine —
# CEILED that cost, one unit above their own settlement, so a bid funded to
# the unit was refused on this path while the release path (releaseDeferred →
# executeLimitOrderProtected, test_fok_market §15) fills it whole. Pre-fix
# shape here: fokCrossGate (walkFillable, floored) passes the swap, the sell
# leg's engine pre-check refuses the maker, the FOK is killed "No liquidity
# for ICP" — a kill for a maker that could pay. Both engine sites floor now.
echo "── §4 (1788661917) a bid funded to exactly ⌊cost⌋ + fee on the sell leg is TAKEN by the FOK (residue 0); one quote unit less is a clean kill ──"
mdx_identity_new xsa_m2; M2=$(principal_of xsa_m2)
m2()  { icp canister call --candid "$MDX_CANDID" --identity xsa_m2 backend "$@" 2>&1; }
m2_notices() { m2 getMyReleaseRejections '()' --query | tr -d '\n' | grep -oE "mid-match" | grep -c . || true; }
fok_swap_qty() { w swap "(record { fromToken=\"ICP\"; toToken=\"BTC\"; amount=$1 : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.05) : nat } }; noPartialFill=true })" | tr -d '_\n' | tr -s ' '; }
QTY4=3333333333; PX4=$(e8 9.99); NEED4=33316649995   # ⌊3,333,333,333 × 9.99⌋ + ⌊that × 5 ÷ 10,000⌋
recent_id() { recent | grep -oE "id = [0-9]+" | head -1 | grep -oE "[0-9]+"; }
# A staged swap releases only when BOTH legs are fresh (crossSwapLegFresh):
# the release reference must POSTDATE the staging AND — H-23, once the AMM
# has a LIVE quote on the side the leg lifts — the ladder must have been
# REQUOTED on that mark ("a fresh mark is not a fresh ladder"). The fills
# above fund the AMM pools with their fees (15 bps of case 1's $331.67 ≈
# $0.50 posts a 0.0499 ICP bid at 9.9499 on the next requote), so from here
# a bare re-stamp leaves the swap STAGED — not killed, not expired, no
# outcome. Stamp + requote both markets, run the pass, repeat until the
# owner's recent swap advances past $1.
release_cross_for() {
  local i=0
  while [ "$i" -lt 6 ]; do
    stamp "$SELLM" "$(e8 10.0)"; stamp "$BUYM" "$(e8 100.0)"
    adm adminRunDeferredSwaps '()' >/dev/null 2>&1
    [ "$(recent_id)" != "$1" ] && return 0
    i=$((i+1))
  done
}
# Rest M2's bid funded generously, then DRAIN to the exact figure (resting
# orders hold no reservation — by design; test_fok_market §14 does the same).
# Any earlier M2 bid is cancelled first so the level holds ONE bid whatever
# the previous case did (a RED first case leaves its bid resting).
rest_m2_bid() {
  m2 cancelAllMyOrders "(opt \"$SELLM\")" >/dev/null 2>&1
  adm setTestBalance "(principal \"$M2\", \"ICPUSD\", $(e8 1500.0) : nat)" >/dev/null
  m2 placeLimitOrder "(\"$SELLM\", variant { buy }, $PX4 : nat, $QTY4 : nat)" >/dev/null
  stamp "$SELLM" "$(e8 10.0)"
  adm setTestBalance "(principal \"$M2\", \"ICPUSD\", $1 : nat)" >/dev/null
}
# Deep buy-side depth so the buy leg never decides the outcome (5 BTC @ 101.5
# ≈ $507 against ≈ $331 of proceeds, inside the 105 buy cap).
adm setTestBalance "(principal \"$S2\", \"BTC\", $(e8 10.0) : nat)" >/dev/null
s2 placeLimitOrder "(\"$BUYM\", variant { sell }, $(e8 101.5) : nat, $(e8 5.0) : nat)" >/dev/null
stamp "$BUYM" "$(e8 100.0)"
rest_m2_bid "$NEED4"
adm setTestBalance "(principal \"$W\", \"ICP\", $QTY4 : nat)" >/dev/null
adm setTestBalance "(principal \"$W\", \"ICPUSD\", 0 : nat)" >/dev/null
adm setTestBalance "(principal \"$W\", \"BTC\", 0 : nat)" >/dev/null
BIDQ5=$(level_qty "$SELLM" "$PX4"); M2_USD0=$(balN "$M2" ICPUSD); N4_0=$(m2_notices)
if [ "${BIDQ5:-0}" = "$QTY4" ] && [ "${M2_USD0:-0}" = "$NEED4" ]; then ok "fixture: M2's bid 33.33333333 ICP @ 9.99 rests, funded to exactly ⌊cost⌋ + fee = $NEED4 quote units"; else nok "fixture: the exact-funded bid must rest" "bid=${BIDQ5:-none} usd=${M2_USD0:-none}"; fi
RID4=$(recent_id)
R=$(fok_swap_qty "$QTY4")
if echo "$R" | grep -q "swapOrderId = opt"; then ok "FOK cross-swap 33.33333333 ICP staged"; else nok "FOK cross-swap should stage" "$(echo "$R" | head -c 250)"; fi
release_cross_for "$RID4"
RC=$(recent); W_ICP5=$(balN "$W" ICP); W_BTC5=$(balN "$W" BTC); M2_USD1=$(balN "$M2" ICPUSD); M2_ICP1=$(balN "$M2" ICP); N4_1=$(m2_notices); BIDQ6=$(level_qty "$SELLM" "$PX4")
echo "   outcome: $(echo "$RC" | head -c 300)"
if echo "$RC" | grep -q "filled = true" && echo "$RC" | grep -q "fromAmount = $QTY4 "; then ok "outcome: filled, fromAmount = 33.33333333 ICP — the exact-funded bid IS depth for the sell leg (pre-fix: killed 'No liquidity for ICP' by the ceiling pre-check)"; else nok "a bid funded to ⌊cost⌋ + fee must be TAKEN by the cross-swap's sell leg (the release path fills it — test_fok_market §15)" "$RC"; fi
if [ "${W_ICP5:-1}" = "0" ] && [ "${W_BTC5:-0}" -gt 0 ]; then ok "the whole 33.33333333 ICP sold (ICP 0), $(awk -v b="$W_BTC5" 'BEGIN{printf "%.4f", b/1e8}') BTC received"; else nok "balances should reflect the full conversion" "icp $W_ICP5 btc $W_BTC5"; fi
if [ "${M2_USD1:-1}" = "0" ] && [ "${M2_ICP1:-0}" = "$QTY4" ]; then ok "the maker's debit is exactly its balance: ICPUSD residue 0, ICP +33.33333333 (the gate and the debit agree to the quote unit)"; else nok "the settlement must debit ⌊cost⌋ + fee exactly (residue 0)" "usd $M2_USD0 → ${M2_USD1:-none} icp ${M2_ICP1:-none}"; fi
if [ -z "${BIDQ6:-}" ] && [ "${N4_1:-0}" = "${N4_0:-0}" ]; then ok "the bid is consumed (level gone) with NO mid-match notice (notices $N4_0 → $N4_1)"; else nok "a maker that can pay must never be cancelled as unfunded" "bid=${BIDQ6:-gone} notices $N4_0 → $N4_1"; fi
# CONTROL: one quote unit short of ⌊cost⌋ + fee → the FOK gate (walkFillable,
# the same floor) counts the bid ZERO and kills the swap cleanly: nothing
# moves, the bid survives whole, no mid-match notice (a probe cancels nothing).
# (The buy book is re-topped so only the sell leg can decide this one too.)
s2 placeLimitOrder "(\"$BUYM\", variant { sell }, $(e8 101.5) : nat, $(e8 5.0) : nat)" >/dev/null
stamp "$BUYM" "$(e8 100.0)"
rest_m2_bid "$((NEED4 - 1))"
adm setTestBalance "(principal \"$W\", \"ICP\", $QTY4 : nat)" >/dev/null
adm setTestBalance "(principal \"$W\", \"ICPUSD\", 0 : nat)" >/dev/null
adm setTestBalance "(principal \"$W\", \"BTC\", 0 : nat)" >/dev/null
BIDQ7=$(level_qty "$SELLM" "$PX4"); M2_USD2=$(balN "$M2" ICPUSD); N4_2=$(m2_notices)
if [ "${BIDQ7:-0}" = "$QTY4" ] && [ "${M2_USD2:-0}" = "$((NEED4 - 1))" ]; then ok "control fixture: the bid rests again, funded one quote unit short ($((NEED4 - 1)))"; else nok "control fixture: the one-short bid must rest" "bid=${BIDQ7:-none} usd=${M2_USD2:-none}"; fi
RID4b=$(recent_id)
R=$(fok_swap_qty "$QTY4")
if echo "$R" | grep -q "swapOrderId = opt"; then ok "control: FOK cross-swap staged"; else nok "control: FOK cross-swap should stage" "$(echo "$R" | head -c 250)"; fi
release_cross_for "$RID4b"
RC=$(recent); W_ICP6=$(balN "$W" ICP); W_USD6=$(balN "$W" ICPUSD); M2_USD3=$(balN "$M2" ICPUSD); N4_3=$(m2_notices); BIDQ8=$(level_qty "$SELLM" "$PX4")
echo "   outcome: $(echo "$RC" | head -c 300)"
if echo "$RC" | grep -q "filled = false" && echo "$RC" | grep -q "Fill-or-kill swap killed"; then ok "control: one unit short → killed at release (\"Fill-or-kill swap killed\")"; else nok "control: a bid one unit short of ⌊cost⌋ + fee is no depth — the FOK must kill" "$RC"; fi
if [ "${W_ICP6:-0}" = "$QTY4" ] && [ "${W_USD6:-1}" = "0" ] && [ "${M2_USD3:-0}" = "$((NEED4 - 1))" ]; then ok "control: nothing moved (W ICP $W_ICP6, ICPUSD 0; M2 ICPUSD untouched)"; else nok "control: a killed FOK moved balances" "w icp $W_ICP6 usd $W_USD6 m2 usd $M2_USD3"; fi
if [ "${BIDQ8:-0}" = "$QTY4" ] && [ "${N4_3:-0}" = "${N4_2:-0}" ]; then ok "control: the bid survives whole with no mid-match notice (the gate is a probe, it cancels nothing)"; else nok "control: a killed FOK must leave the maker's bid resting, un-noticed" "bid=${BIDQ8:-gone} notices $N4_2 → $N4_3"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_cross_swap_atomic ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_cross_swap_atomic ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
