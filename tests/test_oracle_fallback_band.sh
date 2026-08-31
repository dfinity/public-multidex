#!/bin/bash
# Users-only oracle-fallback band clamp. When a staged order can't get a fresh
# GEPTOR price within its expiry, it releases against USER liquidity only (AMM
# sidelined). Without a clamp, a wide taker slippage dumps into a stale STRANDED
# order far outside the band (the −10% ICP / +12% SOL candle wicks). The fix
# clamps that fallback fill to ±2% of the last mid, so near-mid user liquidity
# still fills but distant stranded orders are out of reach.
#
# RUN WITH THE TRADING BOT PAUSED:
#     bash scripts/stop_bots_local.sh
#     bash tests/test_oracle_fallback_band.sh
#
# Setup: mid 10. A near-band user bid @ 9.85 (-1.5%, inside the 2% clamp) and a
# stranded user bid @ 8.5 (-15%, outside). A whale market-sell @ 20% slippage
# (cap 8.0) expires into the users-only fallback. Expect: 9.85 fills, 8.5 intact.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

MKT="ICP-ICPUSD"
# Integer-money helpers: methods take/return Nat base units (10^8).
# e8: human → base units (call args, grep needles); from_e8: base units → human.
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
adm()  { icp canister call --identity anonymous backend "$@" 2>&1; }
a()    { icp canister call --identity ofb_user backend "$@" 2>&1; }
w()    { icp canister call --identity ofb_whale backend "$@" 2>&1; }
# Balances are Nat base units now — strip underscores, take the nat, → human.
bal()  { local v; v=$(adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+" | head -1); [ -n "$v" ] && from_e8 "$v"; }
# quantity (human) resting at a given HUMAN bid price (or empty). Book qty/price
# are Nat base units, so match the e8 price and convert the matched e8 qty back.
bid_qty() { local v; v=$(adm getOrderBook "(\"$MKT\")" | tr -d '_' | tr '\n' ' ' | tr -s ' ' | sed -E 's/.*bids = vec \{//' | grep -oE "quantity = [0-9]+ : nat; price = $(e8 "$1") " | grep -oE "quantity = [0-9]+" | grep -oE "[0-9]+" | head -1); [ -n "$v" ] && from_e8 "$v"; }
freshrequote() { adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null; adm requoteAmm "(\"$MKT\")" >/dev/null; }

S=$(mkid ofb_seed); U=$(mkid ofb_user); W=$(mkid ofb_whale)

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
adm createAmmPool "(\"$MKT\")" >/dev/null 2>&1
# setAmmConfig: only quoteDepthBase (2nd arg) is a base-unit Nat → e8.
adm setAmmConfig "(\"$MKT\", 20:nat, $(e8 5.0):nat, 5:nat, 15:nat, 5:nat)" >/dev/null
adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null
adm setTestBalance "(principal \"$S\", \"ICP\", $(e8 10000.0):nat)"     >/dev/null
adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 200000.0):nat)" >/dev/null
icp canister call --identity ofb_seed backend seedAmmPool "(\"$MKT\", $(e8 10000.0):nat, $(e8 200000.0):nat)" >/dev/null 2>&1
adm enableAmm "(\"$MKT\", true)" >/dev/null
adm setTestBalance "(principal \"$U\", \"ICPUSD\", $(e8 100000.0):nat)" >/dev/null
adm setTestBalance "(principal \"$W\", \"ICP\", $(e8 1000.0):nat)"      >/dev/null
freshrequote

# ── 1. Rest a near-band bid (9.85) and a stranded far bid (8.5) ──
a placeLimitOrder "(\"$MKT\", variant { buy }, $(e8 9.85):nat, $(e8 3.0):nat)" >/dev/null
a placeLimitOrder "(\"$MKT\", variant { buy }, $(e8 8.5):nat, $(e8 5.0):nat)" >/dev/null
freshrequote
Q96=$(bid_qty 9.85); Q85=$(bid_qty 8.5)
echo ""
echo "── 1. Resting user bids: 9.85 (qty ${Q96:-none}), 8.5 (qty ${Q85:-none}) ──"
if [ -n "$Q96" ] && [ -n "$Q85" ]; then ok "near-band bid @9.85 and stranded bid @8.5 both rest"; else nok "both user bids should rest" "q9.85=$Q96 q8.5=$Q85"; fi

# ── 2. Pull the AMM ladder (mimic the stall that forces the users-only path) ──
for id in $(adm getAmmPool "(\"$MKT\")" | grep -oE "activeBidIds = vec \{[^}]*\}|activeAskIds = vec \{[^}]*\}" | grep -oE "[0-9_]+ : nat" | grep -oE "[0-9_]+" | tr -d '_'); do
  adm setTestOrderExpiry "($id : nat, 1 : int)" >/dev/null 2>&1
done
adm adminSweepExpiredOrders "()" >/dev/null 2>&1

echo ""
echo "── 2. AMM ladder pulled; whale sells 10 ICP @20% slippage → users-only fallback ──"
WICP0=$(bal "$W" ICP)
w placeMarketOrder "(\"$MKT\", variant { sell }, $(e8 10.0):nat, $(e8 0.2):nat, false)" >/dev/null
SID=$(w getMyStagedOrderIds '()' | grep -oE "[0-9_]+ : nat" | grep -oE "[0-9_]+" | tr -d '_' | head -1)
adm setTestDeferredExpiry "($SID : nat, 1 : int)" >/dev/null 2>&1   # backdate → expired (no wall-clock wait)
adm adminRunDeferredExpiry "()" >/dev/null 2>&1

Q96b=$(bid_qty 9.85); Q85b=$(bid_qty 8.5); WICP1=$(bal "$W" ICP)
SOLD=$(awk -v a="$WICP0" -v b="$WICP1" 'BEGIN{printf "%.4f", a-b}')
echo "   after fallback: bid@9.85=${Q96b:-gone} bid@8.5=${Q85b:-gone} ; whale sold $SOLD ICP"

# Stranded 8.5 bid must be UNTOUCHED (outside the 2% clamp).
if [ -n "$Q85b" ] && awk -v x="$Q85b" -v y="$Q85" 'BEGIN{exit ((x-y<0?y-x:x-y)<0.0001?0:1)}'; then
  ok "stranded bid @8.5 UNTOUCHED ($Q85b) — clamp kept the fallback inside the band"
else nok "stranded 8.5 bid should not be filled by the users-only fallback" "before=$Q85 after=${Q85b:-gone}"; fi

# Near-band 9.85 bid SHOULD have filled (inside the clamp) — legit liquidity still trades.
if [ -z "$Q96b" ] || awk -v x="${Q96b:-0}" 'BEGIN{exit (x<2.9?0:1)}'; then
  ok "near-band bid @9.85 filled (sold ≈3 ICP at 9.85) — clamp doesn't block in-band liquidity"
else nok "near-band 9.85 bid should still fill" "after=$Q96b"; fi

# Whale sold only the in-band amount (~3), not all 10 into the stranded order.
if awk -v s="$SOLD" 'BEGIN{exit (s>2.5 && s<3.5 ? 0 : 1)}'; then
  ok "whale converted only the in-band ≈3 ICP; the rest dropped (not dumped at 8.5)"
else nok "whale should fill ~3 ICP (the 9.85 bid), not reach 8.5" "sold=$SOLD"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
