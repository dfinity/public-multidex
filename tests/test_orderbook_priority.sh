#!/bin/bash
# OrderBook O(log N) best-price index — correctness.
#
# Replaces the old O(N) linear scan with a price-ordered level index
# (minEntry = best ask, maxEntry = best bid). This test pins the behaviour
# the index must preserve: a taker always crosses the true touch, the index
# advances correctly when the best is cancelled/filled, and it stays correct
# across many price levels (the scale case the old scan choked on).
#
# No AMM here — only the maker's resting limit orders, so the touch is fully
# controlled.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

# Integer-money helpers: trading/admin methods take Nat base units (10^8).
# e8: human → base units (for call args); from_e8: base units → human (for
# reading money out of results, e.g. avgPrice).
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

mdx_identity_new ob_maker; PM=$(principal_of ob_maker); mdx_identity_new ob_taker; PT=$(principal_of ob_taker)
adm()  { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
mk()   { icp canister call --candid "$MDX_CANDID" --identity ob_maker backend "$@" 2>&1; }
tk()   { icp canister call --candid "$MDX_CANDID" --identity ob_taker backend "$@" 2>&1; }
# Sealed-until-GEPTOR: orders stage off-book and execute on the next GEPTOR
# release, so no fill price comes back inline. The realized price is the NEWEST
# trade for the market instead.
#   last_trade_id      → id of the most recent BTC-ICPUSD trade (empty if none)
#   newest_trade_px    → price (human units) of the most recent trade
last_trade_id()   { tk getRecentTrades '("BTC-ICPUSD")' | grep -oE "id = [0-9_]+ : nat" | tail -1 | grep -oE "[0-9_]+" | tr -d '_'; }
newest_trade_px() { local v; v=$(tk getRecentTrades '("BTC-ICPUSD")' | grep -oE "price = [0-9_]+ : nat" | tail -1 | grep -oE "[0-9_]+" | tr -d '_'); [ -n "$v" ] && from_e8 "$v"; }
# Cross the book with a marketable LIMIT taker (NOT a market order): a spot
# MARKET order walks the AMM curve and is capped at the quoted ladder edge —
# with no ladder here that cap falls back to ±2% of mid, so it could never
# reach the test's far levels (by design: no wicking into stranded book). A
# marketable limit crosses resting orders AT THE MAKER'S PRICE with no edge
# cap, which is exactly the "which level does the index pick?" probe we need.
# One bound DOES apply to the taker: a marketable limit must price within ±5%
# of the mark (MARKETABLE_BAND_BPS = 500, 2026-07) or it is rejected at
# placement. So the taker prices sit just inside the band edges ([47500,
# 52500] around the 50000 ref), and every ladder level a taker must reach
# lives inside the band too.
# Fire (failing LOUDLY on rejection — a collared taker would otherwise burn
# the whole wait loop), release (fresh stamp postdates the staged taker),
# wait for the trade, echo the realized fill price in human units.
place_and_price() {
  local side="$1" qty="$2" prev="$3" elapsed=0 px r
  case "$side" in buy) px=52400.0 ;; sell) px=47600.0 ;; esac
  r=$(tk placeLimitOrder "(\"BTC-ICPUSD\", variant { $side }, $(e8 "$px") : nat, $(e8 "$qty") : nat)")
  if ! echo "$r" | grep -q "ok = record"; then
    echo "taker $side @ $px REJECTED: $(echo "$r" | tr '\n' ' ')" >&2
    echo "rejected"   # deliberately non-numeric → the caller's price check fails now, not after 20s
    return 1
  fi
  release   # fresh stamp postdating the staged taker → it releases + crosses the book
  while [ "$elapsed" -lt 20 ]; do
    local cur; cur=$(last_trade_id)
    if [ -n "$cur" ] && [ "$cur" != "$prev" ]; then break; fi
    sleep 1; elapsed=$((elapsed+1))
  done
  newest_trade_px
}
clean(){ for t in BTC ETH SOL ICP ICPUSD; do adm setTestBalance "(principal \"$1\", \"$t\", 0 : nat)" >/dev/null; done; }

# Fresh state; BTC market exists with a ref price but NO AMM quoting: the pool
# is ENABLED with numLevels=0 so requoteAmm never posts quotes, yet its GEPTOR
# pass still runs processDeferred — which is what RELEASES staged orders under
# the sealed model (a disabled pool's requote early-exits and releases nothing).
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1   # deterministic releases (via release() only)
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
adm setAmmConfig "(\"BTC-ICPUSD\", 20:nat, 0 : nat, 0:nat, 10:nat)" >/dev/null
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null
# Stamp a fresh oracle price + run the GEPTOR pass → releases everything staged
# BEFORE the stamp (anti-snipe: an order releases only once the price postdates it).
release() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
clean "$PM"; clean "$PT"
adm setTestBalance "(principal \"$PM\", \"BTC\",    $(e8 100.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$PT\", \"ICPUSD\", $(e8 5000000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$PT\", \"BTC\",    $(e8 100.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$PM\", \"ICPUSD\", $(e8 5000000.0) : nat)" >/dev/null

# ── 1. Best ASK = lowest price (minEntry) ──
echo "── 1. Taker buy crosses the LOWEST ask among several ──"
mk placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 52450.0) : nat, $(e8 0.1) : nat)" >/dev/null
mk placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 52000.0) : nat, $(e8 0.1) : nat)" >/dev/null
mk placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 52200.0) : nat, $(e8 0.1) : nat)" >/dev/null
release   # maker asks rest on the public book
PREV=$(last_trade_id)
PX=$(place_and_price buy 0.05 "$PREV")
echo "   filled @ $PX (expect 52000)"
if awk -v p="$PX" 'BEGIN { exit (p>51999 && p<52001 ? 0 : 1) }'; then ok "matched the lowest ask (52000)"; else nok "did not match best ask" "avgPrice=$PX"; fi

# ── 2. Fully consuming the best level prunes it → next-lowest becomes touch ──
echo ""
echo "── 2. Exhaust the 52000 ask → next buy crosses 52200 ──"
# Step 1 left 0.05 of the 0.1 @ 52000; buy it out (full fill → the level is
# pruned from the index via removeFromOpenIndexes, the same path cancel uses).
# (Wait for this exhausting buy to settle before measuring the next one, so the
#  two sealed releases don't race.)
PREV=$(last_trade_id)
place_and_price buy 0.05 "$PREV" >/dev/null
PREV=$(last_trade_id)
PX=$(place_and_price buy 0.05 "$PREV")
echo "   filled @ $PX (expect 52200)"
if awk -v p="$PX" 'BEGIN { exit (p>52199 && p<52201 ? 0 : 1) }'; then ok "index advanced to next-lowest after the best level was fully filled"; else nok "did not advance correctly" "avgPrice=$PX"; fi

# ── 3. Best BID = highest price (maxEntry) ──
echo ""
echo "── 3. Taker sell crosses the HIGHEST bid among several ──"
mk placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 40000.0) : nat, $(e8 0.1) : nat)" >/dev/null
mk placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 48000.0) : nat, $(e8 0.1) : nat)" >/dev/null
mk placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 45000.0) : nat, $(e8 0.1) : nat)" >/dev/null
release   # maker bids rest on the public book
PREV=$(last_trade_id)
PX=$(place_and_price sell 0.05 "$PREV")
echo "   filled @ $PX (expect 48000)"
if awk -v p="$PX" 'BEGIN { exit (p>47999 && p<48001 ? 0 : 1) }'; then ok "matched the highest bid (48000)"; else nok "did not match best bid" "avgPrice=$PX"; fi

# ── 4. Scale: best price correct among MANY distinct levels ──
echo ""
echo "── 4. Seed 40 asks at distinct prices; buy must cross the lowest ──"
# Lowest will be 50050; prices 50050, 50100, ... 52000.
for i in $(seq 0 39); do
  p=$(awk -v i="$i" 'BEGIN{printf "%.1f", 50050 + i*50}')
  mk placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 "$p") : nat, $(e8 0.02) : nat)" >/dev/null
done
release   # all 40 asks rest on the public book
PREV=$(last_trade_id)
PX=$(place_and_price buy 0.01 "$PREV")
echo "   filled @ $PX (expect 50050 — the lowest of 40 levels)"
if awk -v p="$PX" 'BEGIN { exit (p>50049 && p<50051 ? 0 : 1) }'; then ok "correct best price across 40 levels"; else nok "wrong best among many levels" "avgPrice=$PX"; fi

echo ""
adm setTestTimersPaused '(false)' >/dev/null 2>&1   # resume background timers
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
