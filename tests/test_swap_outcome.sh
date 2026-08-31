#!/bin/bash
# Cross-swap OUTCOME reporting. A staged swap releases asynchronously, and when
# the buy leg can't fill within slippage it used to refund SILENTLY ("staged,
# never completed"). releaseCrossSwap now records the outcome (getMyRecentSwap)
# so the frontend can tell the user what happened.
#
# RUN WITH THE TRADING BOT PAUSED:
#     bash scripts/stop_bots_local.sh
#     bash tests/test_swap_outcome.sh
#
#   A. tiny slippage (0.1%) < AMM half-spread → buy leg unreachable → outcome
#      filled=false (funds returned), NOT a silent vanish.
#      (The swap endpoint doesn't clamp slippage to the 1%–25% market-order
#      band, so 0.1% still stages — that's what makes this case reachable.)
#   B. normal slippage (5%) → fills → outcome filled=true, toAmount>0.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

# Integer-money migration: trading/admin methods take Nat BASE UNITS (10^8), and
# balances / swap outcomes come back as base-unit Nats (Candid may print them
# with underscores — strip those BEFORE grepping). e8 converts human→base for
# call args; from_e8 base→human so the human-scale assertions stay unchanged.
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
u()   { icp canister call --identity swo_user backend "$@" 2>&1; }
# bal / avail → HUMAN units: pull the base-unit Nat and /1e8.
bal()   { local n; n=$(adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+"); [ -z "$n" ] && n=0; from_e8 "$n"; }
avail() { local n; n=$(u getMyAvailableBalance "(\"$1\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+"); [ -z "$n" ] && n=0; from_e8 "$n"; }
freshrequote() { adm setAmmRefPrice "(\"$1\", $(e8 "$2") : nat)" >/dev/null; adm requoteAmm "(\"$1\")" >/dev/null; }
release() { freshrequote "ICP-ICPUSD" 10.0; freshrequote "BTC-ICPUSD" 100.0; adm adminRunDeferredSwaps "()" >/dev/null 2>&1; }
swap_filled() { u getMyRecentSwap '()' | grep -oE "filled = (true|false)" | grep -oE "(true|false)"; }
# toAmount is a base-unit Nat now — strip underscores, then /1e8 for the report.
swap_to()     { local n; n=$(u getMyRecentSwap '()' | tr -d '_' | grep -oE "toAmount = [0-9]+" | grep -oE "[0-9]+" | head -1); [ -z "$n" ] && n=0; from_e8 "$n"; }

S=$(mkid swo_seed); U=$(mkid swo_user)
seed() { icp canister call --identity swo_seed backend "$@" 2>&1; }

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
# (quoteDepthBase is a base-unit Nat quantity now; spread/levels/spacing/window stay plain nats.)
for m in "ICP-ICPUSD" "BTC-ICPUSD"; do adm createAmmPool "(\"$m\")" >/dev/null 2>&1; adm setAmmConfig "(\"$m\", 20:nat, $(e8 5.0) : nat, 5:nat, 15:nat, 5:nat)" >/dev/null; done
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)"  >/dev/null
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 100.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$S\", \"ICP\", $(e8 100000.0) : nat)"      >/dev/null
adm setTestBalance "(principal \"$S\", \"BTC\", $(e8 1000.0) : nat)"        >/dev/null
adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 10000000.0) : nat)" >/dev/null
seed seedAmmPool "(\"ICP-ICPUSD\", $(e8 10000.0) : nat, $(e8 200000.0) : nat)" >/dev/null
seed seedAmmPool "(\"BTC-ICPUSD\", $(e8 500.0) : nat, $(e8 200000.0) : nat)"   >/dev/null
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null
freshrequote "ICP-ICPUSD" 10.0; freshrequote "BTC-ICPUSD" 100.0
adm setTestBalance "(principal \"$U\", \"ICP\", $(e8 1000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$U\", \"BTC\", $(e8 0.0) : nat)"    >/dev/null

# ── A. Unfillable swap (slippage below the spread) reports, doesn't vanish ──
echo ""
echo "── A. Swap 50 ICP → BTC @ 1% slippage vs a 3% BUY-leg spread (→ unreachable) ──"
# W4-04 floors maxSlippage at 1%, so "slippage below the venue's 0.2% spread"
# is no longer expressible. Same property, new mechanism — and the leg
# matters: the cross-swap sizes its fill against the BUY market's asks
# capped at THAT pool's refPrice × (1+slippage) (main.mo buyCap). Widening
# the SELL leg does nothing. Widen BTC-ICPUSD to 3% (restored below): asks
# rest ≈1.5% over ref, the 1% cap can't reach them, absorb=0 → the swap
# records filled=false and refunds.
adm setAmmConfig "(\"BTC-ICPUSD\", 300:nat, $(e8 1.0):nat, 15:nat, 35:nat, 8:nat)" >/dev/null
adm requoteAmm '("BTC-ICPUSD")' >/dev/null
RA=$(u swap "(record { fromToken=\"ICP\"; toToken=\"BTC\"; amount=$(e8 50.0) : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.01) : nat } }; noPartialFill=false })")
if echo "$RA" | grep -q "swapOrderId = opt"; then ok "swap staged (swapOrderId returned)"; else nok "swap should stage" "$(echo "$RA" | head -c 120)"; fi
release
FA=$(swap_filled); BTCA=$(bal "$U" BTC)
ICPA=$(avail ICP)
echo "   outcome filled=$FA ; user BTC=$BTCA ; user ICP avail=$ICPA"
if [ "$FA" = "false" ]; then ok "outcome recorded as NOT filled (no silent vanish)"; else nok "unfillable swap should record filled=false" "filled=$FA"; fi
if awk -v b="$BTCA" 'BEGIN{exit (b<0.0000001?0:1)}' && awk -v i="$ICPA" 'BEGIN{exit (i>999.0?0:1)}'; then
  ok "no BTC received and ICP refunded (avail $ICPA ≈ 1000)"
else nok "funds should be returned on an unfilled swap" "btc=$BTCA icpAvail=$ICPA"; fi

# ── B. Fillable swap reports filled=true with a real toAmount ──
# restore the seeded spread first (values = scripts/play_start.sh:223)
adm setAmmConfig "(\"BTC-ICPUSD\", 20:nat, $(e8 1.0):nat, 15:nat, 35:nat, 8:nat)" >/dev/null
adm requoteAmm '("BTC-ICPUSD")' >/dev/null
echo ""
echo "── B. Swap 50 ICP → BTC @ 5% slippage → fills ──"
RB=$(u swap "(record { fromToken=\"ICP\"; toToken=\"BTC\"; amount=$(e8 50.0) : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.05) : nat } }; noPartialFill=false })")
release
FB=$(swap_filled); TB=$(swap_to); BTCB=$(bal "$U" BTC)
echo "   outcome filled=$FB toAmount=$TB ; user BTC=$BTCB"
if [ "$FB" = "true" ] && awk -v t="$TB" 'BEGIN{exit (t>0.0000001?0:1)}'; then
  ok "outcome recorded as filled with toAmount=$TB BTC"
else nok "fillable swap should record filled=true with toAmount>0" "filled=$FB to=$TB"; fi
if awk -v b="$BTCB" 'BEGIN{exit (b>0.0000001?0:1)}'; then ok "user actually received $BTCB BTC"; else nok "user should hold BTC after a filled swap" "btc=$BTCB"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
