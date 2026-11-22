#!/bin/bash
# Slippage band anchored to the AMM/oracle MID, not the book's best order.
#
# Regression for "ICP trades spiking above the displayed ask depth": when the
# AMM ask ladder is pulled (oracle stall → quote expiry sweep), the book's best
# ask jumps to a STRANDED far order. A market order's cap used to be
# bestAsk×(1+slippage), so the reference jumped with it and the order executed
# at the stranded price. Anchoring the cap to the AMM mid keeps it tied to fair
# value, so the order fills the fresh AMM quotes but NEVER the stranded far ask.
#
# RUN WITH THE TRADING BOT PAUSED:
#     bash scripts/stop_bots_local.sh
#     bash tests/test_slippage_anchor.sh
#
# Setup: mid=10, slippage=20% → mid-anchored cap=12.0. A stranded ask sits at
# 13.0 (above the 12.0 cap but below the OLD best-ask-anchored cap 13×1.2=15.6).
# A market buy must fill the ~10 AMM ladder and leave the 13.0 ask untouched.
# §4-5 (H-12) repeat the frame for swap()'s direct market path with
# noPartialFill=true (fill-or-kill): FOK skips the #3a ladder-edge clamp, so
# the cap parked at entry IS the execution band — it must come from the mid.
# §6-7 (H-20, F14) mirror it for CROSS-swaps (ICP → BTC): the sell leg used to
# take its band from the engine's own findBestMatch reference and its SIZE from
# the book's best bid, so with the AMM bids withdrawn a funded lowball bid was
# both the reference and the fill — the staged release (§6) and the FOK
# cross-swap (§7 — staged too since H-21, gated all-or-nothing at release)
# must leave the lowball untouched and report why.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

MKT="ICP-ICPUSD"
# Integer-money helpers: methods take/return Nat base units (10^8).
# e8: human → base units (call args, grep needles); from_e8: base units → human
# (reading money — balances, book qty/price — out of results).
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }
adm()  { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
w()    { icp canister call --candid "$MDX_CANDID" --identity slip_whale backend "$@" 2>&1; }
st()   { icp canister call --candid "$MDX_CANDID" --identity slip_strand backend "$@" 2>&1; }
sd()   { icp canister call --candid "$MDX_CANDID" --identity slip_seed backend "$@" 2>&1; }
# Balances are now Nat base units — strip underscores, take the nat, → human.
bal()  { local v; v=$(adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+" | head -1); [ -n "$v" ] && from_e8 "$v"; }
freshrequote() { adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null; adm requoteAmm "(\"$MKT\")" >/dev/null; }
amm_ask_ids() { adm getAmmPool "(\"$MKT\")" | grep -oE "activeAskIds = vec \{[^}]*\}" | grep -oE "[0-9_]+ : nat" | grep -oE "[0-9_]+" | tr -d '_'; }
# Quantity (human) resting at price 13.0 on the book (the stranded ask), or empty
# if gone. Book qty/price are Nat base units now, so match the e8 price and
# convert the matched e8 quantity back to human. (icp pretty-prints one field per
# line, so join + squeeze before matching the quantity that precedes the price.)
resting_qty() { local v; v=$(adm getOrderBook "(\"$MKT\")" | tr -d '_' | tr '\n' ' ' | tr -s ' ' | grep -oE "quantity = [0-9]+ : nat; price = $(e8 "$1") " | grep -oE "quantity = [0-9]+" | grep -oE "[0-9]+" | head -1); [ -n "$v" ] && from_e8 "$v"; }
stranded_qty() { resting_qty 13.0; }
amm_bid_ids() { adm getAmmPool "(\"$MKT\")" | grep -oE "activeBidIds = vec \{[^}]*\}" | grep -oE "[0-9_]+ : nat" | grep -oE "[0-9_]+" | tr -d '_'; }
# Pull one AMM side (oracle-stall simulation): backdate every active id on that
# side to expired and sweep. Echoes the count swept.
pull_amm_side() { local n=0 id; for id in $($1); do adm setTestOrderExpiry "($id : nat, 1 : int)" >/dev/null 2>&1; n=$((n+1)); done; adm adminSweepExpiredOrders "()" >/dev/null 2>&1; echo "$n"; }
# Best resting price on one side of the book (human): asks → min, bids → max.
best_of() { local side="$1" e8; if [ "$side" = asks ]; then e8=$(adm getOrderBook "(\"$MKT\")" | tr -d '_' | tr '}' '\n' | sed -n '/asks =/,/bids =/p' | grep -oE "price = [0-9]+" | grep -oE "[0-9]+" | sort -g | head -1); else e8=$(adm getOrderBook "(\"$MKT\")" | tr -d '_' | tr '}' '\n' | sed -n '/bids =/,$p' | grep -oE "price = [0-9]+" | grep -oE "[0-9]+" | sort -g | tail -1); fi; [ -n "$e8" ] && from_e8 "$e8"; }
# FOK direct swap by the whale: fromToken → toToken, `amount` (human, fromToken
# units), 20% slippage, noPartialFill=true. Echoes the raw result.
w_fok_swap() { w swap "(record { fromToken = \"$1\"; toToken = \"$2\"; amount = $(e8 "$3"):nat; mode = variant { marketOrder = record { maxSlippage = $(e8 0.2):nat } }; noPartialFill = true })"; }
near() { awk -v a="$1" -v b="$2" 'BEGIN{exit ((a-b<0?b-a:a-b) < 0.0001 ? 0 : 1)}'; }

mdx_identity_new slip_seed; S=$(principal_of slip_seed); mdx_identity_new slip_whale; W=$(principal_of slip_whale); mdx_identity_new slip_strand; ST=$(principal_of slip_strand)

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
adm createAmmPool "(\"$MKT\")" >/dev/null 2>&1
# small ladder: depth 1 × 3 levels = 3 ICP capacity, near mid 10
# (setAmmConfig: only quoteDepthBase — the 2nd arg — is a base-unit Nat → e8;
#  spreadBps/numLevels/levelSpacingBps/protectionWindowSec stay as-is.)
adm setAmmConfig "(\"$MKT\", 20:nat, $(e8 1.0):nat, 3:nat, 15:nat)" >/dev/null
adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null
adm setTestBalance "(principal \"$S\", \"ICP\", $(e8 3.0):nat)"      >/dev/null
adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 100000.0):nat)" >/dev/null
mdx_lp_deposit slip_seed "$MKT" "$(e8 3.0)" "$(e8 1000.0)" >/dev/null
adm setTestBalance "(principal \"$W\",  \"ICPUSD\", $(e8 100000.0):nat)" >/dev/null
adm setTestBalance "(principal \"$W\",  \"ICP\", $(e8 0.0):nat)"         >/dev/null
adm setTestBalance "(principal \"$ST\", \"ICP\", $(e8 100.0):nat)"       >/dev/null
adm setTestBalance "(principal \"$ST\", \"ICPUSD\", $(e8 0.0):nat)"      >/dev/null
adm enableAmm "(\"$MKT\", true)" >/dev/null
freshrequote

# ── 1. Stranded ask rests far above market (13.0, +30% of mid 10) ──
echo ""
echo "── 1. A stranded ask rests at 13.0 (far above the AMM ladder ~10) ──"
st placeLimitOrder "(\"$MKT\", variant { sell }, $(e8 13.0):nat, $(e8 10.0):nat)" >/dev/null
freshrequote
SQ0=$(stranded_qty)
if [ -n "$SQ0" ] && awk -v q="$SQ0" 'BEGIN{exit (q>9.9?0:1)}'; then ok "stranded ask of $SQ0 ICP rests at 13.0"; else nok "stranded ask should rest at 13.0" "qty=$SQ0"; fi

# ── 2. Pull the AMM ladder (oracle-stall simulation): book best ask → 13.0 ──
echo ""
echo "── 2. Pull the AMM ladder (expire + sweep) → book's best ask is now the stranded 13.0 ──"
n=0; for id in $(amm_ask_ids); do adm setTestOrderExpiry "($id : nat, 1 : int)" >/dev/null 2>&1; n=$((n+1)); done
adm adminSweepExpiredOrders "()" >/dev/null 2>&1
# Book prices are Nat base units — strip underscores, take the min e8 price, → human.
BESTASK_E8=$(adm getOrderBook "(\"$MKT\")" | tr -d '_' | tr '}' '\n' | sed -n '/asks =/,/bids =/p' | grep -oE "price = [0-9]+" | grep -oE "[0-9]+" | sort -g | head -1)
BESTASK=$([ -n "$BESTASK_E8" ] && from_e8 "$BESTASK_E8")
if [ "$n" -gt 0 ] && awk -v b="$BESTASK" 'BEGIN{exit (b>12.5?0:1)}'; then ok "AMM ladder pulled ($n asks swept) — book best ask is now $BESTASK"; else nok "AMM asks should be swept, leaving the stranded 13.0 as best" "swept=$n bestAsk=$BESTASK"; fi

# ── 3. Market buy (slippage 20%) placed while the ladder is pulled ──
# Cap is fixed at park time. NEW: anchored to mid 10 → cap 12.0. OLD would have
# anchored to bestAsk 13.0 → cap 15.6 and filled the stranded ask.
echo ""
echo "── 3. Market buy 5 ICP @ 20% slippage (parks with a mid-anchored cap of 12.0) ──"
w placeMarketOrder "(\"$MKT\", variant { buy }, $(e8 5.0):nat, $(e8 0.2):nat, false)" >/dev/null
freshrequote   # re-posts the fresh AMM ladder (~10) and releases the staged buy
WICP=$(bal "$W" ICP)
SQ1=$(stranded_qty)
echo "   whale filled $WICP ICP ; stranded 13.0 ask qty now = ${SQ1:-0}"

# Filled from the fresh AMM ladder (≈3 ICP capacity), NOT the stranded ask.
if awk -v x="$WICP" 'BEGIN{exit (x>2.0 && x<3.5 ? 0 : 1)}'; then
  ok "whale filled ≈3 ICP from the AMM ladder (within the mid-anchored cap)"
else nok "whale should fill the AMM ladder (~3 ICP), not spike into the stranded ask" "filled=$WICP"; fi

# The decisive check: the stranded 13.0 ask is UNTOUCHED (cap 12.0 < 13.0).
if [ -n "$SQ1" ] && awk -v a="$SQ1" -v b="$SQ0" 'BEGIN{exit ((b-a<0?a-b:b-a) < 0.0001 ? 0 : 1)}'; then
  ok "stranded 13.0 ask UNTOUCHED ($SQ1 = $SQ0) — slippage band stayed anchored to the mid, no spike"
else nok "stranded ask was consumed — the buy spiked above fair value" "before=$SQ0 after=${SQ1:-gone}"; fi

# Whale's average fill price is near the AMM mid, nowhere near 13.0.
USD_SPENT=$(awk -v s="$(bal "$W" ICPUSD)" 'BEGIN{printf "%.4f", 100000 - s}')
AVG=$(awk -v u="$USD_SPENT" -v i="$WICP" 'BEGIN{ if (i>0.0001) printf "%.4f", u/i; else print "0" }')
if awk -v a="$AVG" 'BEGIN{exit (a>0 && a<10.6 ? 0 : 1)}'; then
  ok "average fill price $AVG ≈ mid (10), not the stranded 13.0"
else nok "average fill price should be near the mid" "avg=$AVG"; fi

# ── 4. H-12: a FOK direct SWAP (executeSwapDirect #marketOrder) anchors to the mid too ──
# swap()'s market path used to anchor its cap to the book's best order with NO
# pool-mid fallback, so with the ladder pulled a FOK swap parked with cap
# 13×1.2 = 15.6 — and FOK is excluded from the #3a ladder-edge clamp, so it
# executed at that raw far cap: 3 ICP from the fresh ladder + the rest from
# the stranded 13.0 ask. Mid-anchored (cap 12.0) the 13.0 ask is out of band,
# the ladder alone (3 ICP) is short of the ~5 ICP the FOK is sized to, and the
# order is KILLED — nothing fills, the reservation comes back.
echo ""
echo "── 4. FOK swap ICPUSD→ICP (60 ICPUSD @ 20%) while the ladder is pulled ──"
# Re-stock the AMM's inventory (§3 sold its 3 ICP) so a fresh ladder can post.
adm setTestBalance "(principal \"$S\", \"ICP\", $(e8 10.0):nat)"       >/dev/null
adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 1000.0):nat)"  >/dev/null
mdx_lp_deposit slip_seed "$MKT" "$(e8 10.0)" "$(e8 1000.0)" >/dev/null
freshrequote
n=$(pull_amm_side amm_ask_ids)
BESTASK=$(best_of asks)
if [ "$n" -gt 0 ] && near "$BESTASK" 13.0; then ok "ladder pulled again ($n asks swept) — book best ask is the stranded 13.0"; else nok "AMM asks should be swept, leaving the stranded 13.0 as best" "swept=$n bestAsk=$BESTASK"; fi
W_ICP0=$(bal "$W" ICP); W_USD0=$(bal "$W" ICPUSD); SQ2=$(stranded_qty)
R=$(w_fok_swap ICPUSD ICP 60.0)
if echo "$R" | grep -q "swapOrderId = opt"; then ok "FOK swap accepted + staged (the mid keeps the market priced while the ladder is gone)"; else nok "FOK swap should stage" "$R"; fi
freshrequote   # re-posts the ~10 ladder (3 ICP) and releases the staged FOK
W_ICP1=$(bal "$W" ICP); W_USD1=$(bal "$W" ICPUSD); SQ3=$(stranded_qty)
echo "   whale ICP $W_ICP0 → $W_ICP1 ; ICPUSD $W_USD0 → $W_USD1 ; stranded 13.0 ask qty $SQ2 → ${SQ3:-gone}"
if [ -n "$SQ3" ] && near "$SQ3" "$SQ2"; then
  ok "stranded 13.0 ask UNTOUCHED — the FOK swap's cap is mid×1.2 = 12.0, not bestAsk×1.2 = 15.6"
else nok "stranded ask was consumed — the FOK swap executed at the raw book-best-anchored cap" "before=$SQ2 after=${SQ3:-gone}"; fi
if near "$W_ICP1" "$W_ICP0"; then ok "FOK KILLED (whale ICP unchanged): the 3 ICP ladder is short of the ~5 ICP sized at cap 12.0, and nothing else is in band"
else nok "FOK should be killed, not filled beyond the mid band" "icp $W_ICP0 → $W_ICP1"; fi
if near "$W_USD1" "$W_USD0"; then ok "reservation returned (whale ICPUSD unchanged)"; else nok "a killed FOK must return its reservation" "usd $W_USD0 → $W_USD1"; fi

# 4b (adjacent case): a FOK that FITS in the band still fills — 20 ICPUSD sizes
# to ~1.66 ICP at cap 12.0, within the fresh 3 ICP ladder at ~10.
echo ""
echo "── 4b. FOK swap ICPUSD→ICP (20 ICPUSD @ 20%) fills from the ladder inside the band ──"
n=$(pull_amm_side amm_ask_ids)
R=$(w_fok_swap ICPUSD ICP 20.0)
if echo "$R" | grep -q "swapOrderId = opt"; then ok "in-band FOK swap staged"; else nok "in-band FOK swap should stage" "$R"; fi
freshrequote
W_ICP2=$(bal "$W" ICP); W_USD2=$(bal "$W" ICPUSD); SQ4=$(stranded_qty)
GOT=$(awk -v a="$W_ICP2" -v b="$W_ICP1" 'BEGIN{printf "%.4f", a-b}')
AVG=$(awk -v u="$(awk -v a="$W_USD1" -v b="$W_USD2" 'BEGIN{printf "%.6f", a-b}')" -v i="$GOT" 'BEGIN{ if (i>0.0001) printf "%.4f", u/i; else print "0" }')
echo "   whale got $GOT ICP at avg $AVG ; stranded 13.0 ask qty ${SQ4:-gone}"
if awk -v x="$GOT" 'BEGIN{exit (x>1.4 && x<2.0 ? 0 : 1)}' && awk -v a="$AVG" 'BEGIN{exit (a>0 && a<10.6 ? 0 : 1)}'; then ok "in-band FOK filled ≈$GOT ICP from the ladder at ≈ mid ($AVG)"; else nok "in-band FOK should fill fully from the ladder near the mid" "got=$GOT avg=$AVG"; fi
if [ -n "$SQ4" ] && near "$SQ4" "$SQ2"; then ok "stranded 13.0 ask still untouched"; else nok "stranded ask must stay untouched" "qty=${SQ4:-gone}"; fi

# ── 5. Sell-side mirror: FOK swap ICP→ICPUSD with the AMM BIDS pulled and a lowball bid at 7.0 ──
# cap = mid×(1−0.2) = 8.0 under the mid anchor (was bestBid×0.8 = 5.6, which
# admitted the 7.0 lowball). The 3 ICP bid ladder is short of the 4 ICP FOK →
# killed; the lowball bid stays whole.
echo ""
echo "── 5. FOK swap ICP→ICPUSD (4 ICP @ 20%) while the bid ladder is pulled; lowball bid rests at 7.0 ──"
adm setTestBalance "(principal \"$ST\", \"ICPUSD\", $(e8 1000.0):nat)" >/dev/null
st placeLimitOrder "(\"$MKT\", variant { buy }, $(e8 7.0):nat, $(e8 10.0):nat)" >/dev/null
adm setTestBalance "(principal \"$W\", \"ICP\", $(e8 10.0):nat)" >/dev/null
freshrequote
LQ0=$(resting_qty 7.0)
if [ -n "$LQ0" ] && awk -v q="$LQ0" 'BEGIN{exit (q>9.9?0:1)}'; then ok "lowball bid of $LQ0 ICP rests at 7.0"; else nok "lowball bid should rest at 7.0" "qty=$LQ0"; fi
n=$(pull_amm_side amm_bid_ids)
BESTBID=$(best_of bids)
if [ "$n" -gt 0 ] && near "$BESTBID" 7.0; then ok "bid ladder pulled ($n bids swept) — book best bid is the lowball 7.0"; else nok "AMM bids should be swept, leaving the lowball 7.0 as best" "swept=$n bestBid=$BESTBID"; fi
W_ICP3=$(bal "$W" ICP); W_USD3=$(bal "$W" ICPUSD)
R=$(w_fok_swap ICP ICPUSD 4.0)
if echo "$R" | grep -q "swapOrderId = opt"; then ok "FOK sell swap staged"; else nok "FOK sell swap should stage" "$R"; fi
freshrequote
W_ICP4=$(bal "$W" ICP); W_USD4=$(bal "$W" ICPUSD); LQ1=$(resting_qty 7.0)
echo "   whale ICP $W_ICP3 → $W_ICP4 ; ICPUSD $W_USD3 → $W_USD4 ; lowball 7.0 bid qty $LQ0 → ${LQ1:-gone}"
if [ -n "$LQ1" ] && near "$LQ1" "$LQ0"; then ok "lowball 7.0 bid UNTOUCHED — the sell cap is mid×0.8 = 8.0, not bestBid×0.8 = 5.6"; else nok "lowball bid was hit — the FOK sell executed at the raw book-best-anchored cap" "before=$LQ0 after=${LQ1:-gone}"; fi
if near "$W_ICP4" "$W_ICP3" && near "$W_USD4" "$W_USD3"; then ok "FOK sell KILLED (whale balances unchanged)"; else nok "FOK sell should be killed, not filled below the mid band" "icp $W_ICP3 → $W_ICP4 usd $W_USD3 → $W_USD4"; fi

# ── 6. H-20: a staged CROSS-swap's sell leg executes under the mid-anchored floor ──
# ICP → BTC, 4 ICP @ 20%, staged (noPartialFill=false) and released with the
# ICP bid ladder pulled and the 7.0 lowball as the book's best bid. The sell
# leg's engine band anchored to that best bid (floor 5.6) and its size divided
# by it, so the whole 4 ICP printed at 7.0 into the lowball. Fixed: the floor is
# mid×0.8 = 8.0 (and the AMM bids being absent → the #3a ±2% clamp, 9.8); the
# lowball stays whole, nothing moves, and the outcome says why.
echo ""
echo "── 6. Staged cross-swap ICP→BTC (4 ICP @ 20%) with the ICP bid ladder pulled; lowball bid at 7.0 ──"
BMKT="BTC-ICPUSD"
wq()   { icp canister call --candid "$MDX_CANDID" --identity slip_whale backend "$@" --query 2>&1; }
b_resting_qty() { local v; v=$(adm getOrderBook "(\"$BMKT\")" | tr -d '_' | tr '\n' ' ' | tr -s ' ' | grep -oE "quantity = [0-9]+ : nat; price = $(e8 "$1") " | grep -oE "quantity = [0-9]+" | grep -oE "[0-9]+" | head -1); [ -n "$v" ] && from_e8 "$v"; }
# Stage-and-release: stamp BOTH marks fresh (postdating the staging; a stamp
# never re-posts a ladder), requote the legs NAMED as arguments, and run the
# deferred-swap pass by hand. H-23 (F39): a leg releases against the AMM only
# once the ladder on the side it takes was requoted after its mark — so the
# BTC buy leg (live asks) must be requoted here, while the ICP sell leg's
# pulled bids are left exactly as pulled (no live AMM bid → the mark alone
# decides, as before); §6b names both legs once the ICP ladder is back.
release_cross() {
  adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null; adm setAmmRefPrice "(\"$BMKT\", $(e8 100.0):nat)" >/dev/null
  local m; for m in "$@"; do adm requoteAmm "(\"$m\")" >/dev/null; done
  adm adminRunDeferredSwaps "()" >/dev/null 2>&1
}
w_cross_swap() { w swap "(record { fromToken = \"ICP\"; toToken = \"BTC\"; amount = $(e8 "$1"):nat; mode = variant { marketOrder = record { maxSlippage = $(e8 0.2):nat } }; noPartialFill = $2 })"; }
recent() { wq getMyRecentSwap '()' | tr -d '_' | tr '\n' ' ' | tr -s ' '; }
adm createAmmPool "(\"$BMKT\")" >/dev/null 2>&1
adm setAmmConfig "(\"$BMKT\", 20:nat, $(e8 1.0):nat, 3:nat, 15:nat)" >/dev/null
adm setAmmRefPrice "(\"$BMKT\", $(e8 100.0):nat)" >/dev/null
adm setTestBalance "(principal \"$S\", \"BTC\", $(e8 10.0):nat)"       >/dev/null
adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 1000.0):nat)"  >/dev/null
mdx_lp_deposit slip_seed "$BMKT" "$(e8 10.0)" "$(e8 1000.0)" >/dev/null
adm enableAmm "(\"$BMKT\", true)" >/dev/null
adm requoteAmm "(\"$BMKT\")" >/dev/null
adm setTestBalance "(principal \"$W\", \"BTC\", $(e8 0.0):nat)" >/dev/null
freshrequote
BASK=$(adm getOrderBook "(\"$BMKT\")" | tr -d '_' | tr '}' '\n' | sed -n '/asks =/,/bids =/p' | grep -oE "price = [0-9]+" | grep -oE "[0-9]+" | sort -g | head -1)
if [ -n "$BASK" ] && awk -v a="$(from_e8 "$BASK")" 'BEGIN{exit (a>99 && a<102 ? 0 : 1)}'; then ok "BTC buy leg quoting (best ask $(from_e8 "$BASK") ≈ mid 100)"; else nok "BTC AMM should quote asks near 100" "bestAsk=${BASK:-none}"; fi
n=$(pull_amm_side amm_bid_ids)
BESTBID=$(best_of bids)
if [ "$n" -gt 0 ] && near "$BESTBID" 7.0; then ok "ICP bid ladder pulled ($n bids swept) — book best bid is the lowball 7.0"; else nok "AMM bids should be swept, leaving the lowball 7.0 as best" "swept=$n bestBid=$BESTBID"; fi
LQ2=$(resting_qty 7.0); W_ICP5=$(bal "$W" ICP); W_BTC5=$(bal "$W" BTC)
R=$(w_cross_swap 4.0 false)
if echo "$R" | grep -q "swapOrderId = opt"; then ok "cross-swap staged (sealed until both marks re-quote)"; else nok "cross-swap should stage" "$R"; fi
release_cross "$BMKT"
W_ICP6=$(bal "$W" ICP); W_BTC6=$(bal "$W" BTC); LQ3=$(resting_qty 7.0); RC=$(recent)
echo "   whale ICP $W_ICP5 → $W_ICP6 ; BTC $W_BTC5 → $W_BTC6 ; lowball 7.0 bid qty $LQ2 → ${LQ3:-gone}"
if [ -n "$LQ3" ] && near "$LQ3" "$LQ2"; then ok "lowball 7.0 bid UNTOUCHED — the sell leg's floor is mid-anchored (8.0, clamped to 9.8 with the AMM bids absent), not bestBid×0.8 = 5.6"; else nok "lowball bid was hit — the cross-swap's sell leg executed at the book-best-anchored band" "before=$LQ2 after=${LQ3:-gone}"; fi
if near "$W_ICP6" "$W_ICP5" && near "$W_BTC6" "$W_BTC5"; then ok "nothing moved (whale ICP and BTC unchanged — the reservation came back)"; else nok "no leg should settle when the only bid sits past the floor" "icp $W_ICP5 → $W_ICP6 btc $W_BTC5 → $W_BTC6"; fi
if echo "$RC" | grep -q "filled = false" && echo "$RC" | grep -q "within your slippage" && echo "$RC" | grep -q "variant { slippage }"; then ok "outcome: not filled, \"no liquidity within your slippage\", stopReason = slippage"; else nok "outcome should say no liquidity within slippage (stop = slippage)" "$RC"; fi

# 6b (adjacent, positive control): with the ICP bid ladder BACK, the same
# cross-swap converts against the ladder (≈3 ICP capacity at ~9.9, inside the
# 8.0 floor) and stops there — the 7.0 lowball is still past the floor.
echo ""
echo "── 6b. Same cross-swap with the ICP bid ladder restored: fills the ladder, never the 7.0 lowball ──"
adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 1000.0):nat)"  >/dev/null
adm setTestBalance "(principal \"$S\", \"ICP\", $(e8 3.0):nat)"        >/dev/null
mdx_lp_deposit slip_seed "$MKT" "$(e8 3.0)" "$(e8 1000.0)" >/dev/null
freshrequote
R=$(w_cross_swap 4.0 false)
if echo "$R" | grep -q "swapOrderId = opt"; then ok "cross-swap staged"; else nok "cross-swap should stage" "$R"; fi
release_cross "$MKT" "$BMKT"
W_ICP7=$(bal "$W" ICP); W_BTC7=$(bal "$W" BTC); LQ4=$(resting_qty 7.0); RC=$(recent)
SOLD=$(awk -v a="$W_ICP6" -v b="$W_ICP7" 'BEGIN{printf "%.4f", a-b}')
echo "   whale sold $SOLD ICP, BTC $W_BTC6 → $W_BTC7 ; lowball 7.0 bid qty ${LQ4:-gone}"
if awk -v x="$SOLD" 'BEGIN{exit (x>2.0 && x<3.5 ? 0 : 1)}' && awk -v a="$W_BTC7" -v b="$W_BTC6" 'BEGIN{exit (a-b>0.15 ? 0 : 1)}'; then ok "sold ≈$SOLD ICP into the ladder and bought BTC (in-band liquidity still converts)"; else nok "the ladder's ~3 ICP should convert" "sold=$SOLD btc $W_BTC6 → $W_BTC7"; fi
if [ -n "$LQ4" ] && near "$LQ4" "$LQ2"; then ok "lowball 7.0 bid still untouched"; else nok "lowball must stay untouched" "qty=${LQ4:-gone}"; fi
if echo "$RC" | grep -q "filled = true"; then ok "outcome: filled (partly — the unconverted remainder returned)"; else nok "outcome should report a fill" "$RC"; fi

# ── 7. H-20 + H-21: the FOK cross-swap STAGES and its sell leg is gated at the mid-anchored floor ──
# noPartialFill=true used to run both legs at once inside the call (H-21
# retired that path: it stages like every cross-swap and fokCrossGate runs at
# release). Its sell leg had no anchor at all: band off the best bid → with
# the ladder pulled the 7.0 lowball filled 2 ICP, and the buy leg bought
# nothing — #ok with 2 ICP gone for ICPUSD. Fixed: the call returns a staged
# id and moves nothing; at release the floor is mid×0.8 = 8.0 (FOK is outside
# the #3a sidelined clamp — the user's own slippage off the mid is the band),
# the lowball sits past it, the gate finds 0 takeable → KILLED, nothing moves.
echo ""
echo "── 7. FOK cross-swap ICP→BTC (2 ICP @ 20%) with the ICP bid ladder pulled; lowball bid at 7.0 ──"
adm setTestBalance "(principal \"$W\", \"ICP\", $(e8 5.0):nat)" >/dev/null   # the staging reserves the amount: fund it explicitly
freshrequote
n=$(pull_amm_side amm_bid_ids)
BESTBID=$(best_of bids)
if [ "$n" -gt 0 ] && near "$BESTBID" 7.0; then ok "ICP bid ladder pulled ($n bids swept) — best bid is the lowball 7.0"; else nok "AMM bids should be swept" "swept=$n bestBid=$BESTBID"; fi
LQ5=$(resting_qty 7.0); W_ICP8=$(bal "$W" ICP); W_USD8=$(bal "$W" ICPUSD); W_BTC8=$(bal "$W" BTC)
R=$(w_cross_swap 2.0 true)
W_ICP8b=$(bal "$W" ICP); W_USD8b=$(bal "$W" ICPUSD); LQ5b=$(resting_qty 7.0)
if echo "$R" | grep -q "swapOrderId = opt"; then ok "FOK cross-swap STAGED (a staged id, no immediate two-leg path)"; else nok "FOK cross-swap should stage (H-21)" "$R"; fi
if near "$W_ICP8b" "$W_ICP8" && near "$W_USD8b" "$W_USD8" && [ -n "$LQ5b" ] && near "$LQ5b" "$LQ5"; then ok "the call itself settled nothing (whale unchanged, lowball whole)"; else nok "the call settled inside its own message" "icp $W_ICP8 → $W_ICP8b usd $W_USD8 → $W_USD8b lowball $LQ5 → ${LQ5b:-gone}"; fi
release_cross "$BMKT"            # H-23: the ICP bids stay pulled (no live AMM bid → mark alone); the BTC ask ladder must postdate its mark
W_ICP9=$(bal "$W" ICP); W_USD9=$(bal "$W" ICPUSD); W_BTC9=$(bal "$W" BTC); LQ6=$(resting_qty 7.0); RC=$(recent)
echo "   whale ICP $W_ICP8 → $W_ICP9 ; ICPUSD $W_USD8 → $W_USD9 ; lowball 7.0 bid qty $LQ5 → ${LQ6:-gone}"
if echo "$RC" | grep -q "filled = false" && echo "$RC" | grep -q "Fill-or-kill swap killed" && echo "$RC" | grep -q "only 0.00 ICP of 2.00 was takeable"; then ok "outcome: KILLED at release — \"only 0.00 ICP of 2.00 was takeable within your slippage\" (nothing inside the mid-anchored floor 8.0)"; else nok "the FOK should be killed at release for want of in-band bids" "$RC"; fi
if [ -n "$LQ6" ] && near "$LQ6" "$LQ5"; then ok "lowball 7.0 bid UNTOUCHED — the FOK sell leg's floor is mid×0.8 = 8.0"; else nok "lowball bid was hit — the FOK sell leg executed off the book-best band" "before=$LQ5 after=${LQ6:-gone}"; fi
if near "$W_ICP9" "$W_ICP8" && near "$W_USD9" "$W_USD8" && near "$W_BTC9" "$W_BTC8"; then ok "nothing moved (killed ⇒ no balance moved, the reservation came back)"; else nok "a killed FOK cross-swap must move nothing" "icp $W_ICP8 → $W_ICP9 usd $W_USD8 → $W_USD9"; fi

# 7b (adjacent, positive control): in-band liquidity on both legs — a 9.9 user
# bid beside the restored ICP ladder, a 100.6 user ask beside the BTC ladder —
# and the same FOK, staged and released, converts its FULL 2 ICP; the lowball
# still whole.
echo ""
echo "── 7b. Same FOK cross-swap with in-band liquidity (9.9 bid, 100.6 BTC ask, ladders back): converts in full ──"
adm setTestBalance "(principal \"$ST\", \"BTC\", $(e8 1.0):nat)" >/dev/null
adm setTestBalance "(principal \"$W\", \"ICP\", $(e8 5.0):nat)" >/dev/null   # top the whale back up (the pre-fix build drains it above)
st placeLimitOrder "(\"$MKT\", variant { buy }, $(e8 9.9):nat, $(e8 2.0):nat)" >/dev/null
st placeLimitOrder "(\"$BMKT\", variant { sell }, $(e8 100.6):nat, $(e8 0.5):nat)" >/dev/null   # 100.6: off the AMM's 100.2/100.35/100.5 ladder levels (getOrderBook aggregates per level)
freshrequote; adm setAmmRefPrice "(\"$BMKT\", $(e8 100.0):nat)" >/dev/null; adm requoteAmm "(\"$BMKT\")" >/dev/null   # release both staged limits and re-post both ladders (takeable on the release path)
IQ=$(resting_qty 9.9); BQ=$(b_resting_qty 100.6); W_ICP9=$(bal "$W" ICP); W_BTC9=$(bal "$W" BTC)
if [ -n "$IQ" ] && [ -n "$BQ" ]; then ok "user liquidity resting: $IQ ICP bid at 9.9, $BQ BTC ask at 100.6"; else nok "the in-band user orders should rest" "bid9.9=${IQ:-none} ask100.6=${BQ:-none}"; fi
R=$(w_cross_swap 2.0 true)
if echo "$R" | grep -q "swapOrderId = opt"; then ok "FOK cross-swap staged"; else nok "FOK cross-swap should stage" "$R"; fi
release_cross "$MKT" "$BMKT"     # H-23: both ladders live again → both requoted after their marks
W_ICP10=$(bal "$W" ICP); W_BTC10=$(bal "$W" BTC); LQ7=$(resting_qty 7.0); RC=$(recent)
echo "   whale ICP $W_ICP9 → $W_ICP10 ; BTC $W_BTC9 → $W_BTC10 ; lowball 7.0 bid qty ${LQ7:-gone}"
if echo "$RC" | grep -q "filled = true" && echo "$RC" | grep -q "fromAmount = $(e8 2.0) " && awk -v a="$W_BTC10" -v b="$W_BTC9" 'BEGIN{exit (a-b>0.15 ? 0 : 1)}'; then ok "FOK cross-swap converted its FULL 2 ICP into ≈$(awk -v a="$W_BTC10" -v b="$W_BTC9" 'BEGIN{printf "%.4f", a-b}') BTC (outcome filled, fromAmount = 2)"; else nok "in-band FOK cross-swap should convert in full at release" "$RC btc $W_BTC9 → $W_BTC10"; fi
if near "$W_ICP10" "$(awk -v a="$W_ICP9" 'BEGIN{printf "%.8f", a-2.0}')"; then ok "exactly 2 ICP left the whale"; else nok "the FOK must sell exactly its amount" "icp $W_ICP9 → $W_ICP10"; fi
if [ -n "$LQ7" ] && near "$LQ7" "$LQ5"; then ok "lowball 7.0 bid still untouched"; else nok "lowball must stay untouched" "qty=${LQ7:-gone}"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
