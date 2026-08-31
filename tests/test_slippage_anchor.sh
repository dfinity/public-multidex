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

set -u
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
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
adm()  { icp canister call --identity anonymous backend "$@" 2>&1; }
w()    { icp canister call --identity slip_whale backend "$@" 2>&1; }
st()   { icp canister call --identity slip_strand backend "$@" 2>&1; }
sd()   { icp canister call --identity slip_seed backend "$@" 2>&1; }
# Balances are now Nat base units — strip underscores, take the nat, → human.
bal()  { local v; v=$(adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+" | head -1); [ -n "$v" ] && from_e8 "$v"; }
freshrequote() { adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null; adm requoteAmm "(\"$MKT\")" >/dev/null; }
amm_ask_ids() { adm getAmmPool "(\"$MKT\")" | grep -oE "activeAskIds = vec \{[^}]*\}" | grep -oE "[0-9_]+ : nat" | grep -oE "[0-9_]+" | tr -d '_'; }
# Quantity (human) resting at price 13.0 on the book (the stranded ask), or empty
# if gone. Book qty/price are Nat base units now, so match the e8 price and
# convert the matched e8 quantity back to human. (icp pretty-prints one field per
# line, so join + squeeze before matching the quantity that precedes the price.)
stranded_qty() { local v; v=$(adm getOrderBook "(\"$MKT\")" | tr -d '_' | tr '\n' ' ' | tr -s ' ' | grep -oE "quantity = [0-9]+ : nat; price = $(e8 13.0) " | grep -oE "quantity = [0-9]+" | grep -oE "[0-9]+" | head -1); [ -n "$v" ] && from_e8 "$v"; }

S=$(mkid slip_seed); W=$(mkid slip_whale); ST=$(mkid slip_strand)

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
adm createAmmPool "(\"$MKT\")" >/dev/null 2>&1
# small ladder: depth 1 × 3 levels = 3 ICP capacity, near mid 10
# (setAmmConfig: only quoteDepthBase — the 2nd arg — is a base-unit Nat → e8;
#  spreadBps/numLevels/levelSpacingBps/protectionWindowSec stay as-is.)
adm setAmmConfig "(\"$MKT\", 20:nat, $(e8 1.0):nat, 3:nat, 15:nat, 5:nat)" >/dev/null
adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null
adm setTestBalance "(principal \"$S\", \"ICP\", $(e8 3.0):nat)"      >/dev/null
adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 100000.0):nat)" >/dev/null
sd seedAmmPool "(\"$MKT\", $(e8 3.0):nat, $(e8 1000.0):nat)" >/dev/null
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

adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
