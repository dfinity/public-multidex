#!/bin/bash
# Regression: matching engine should cross a taker BUY at 67600 against
# alice's resting ASK at the same price, producing exactly one trade
# and leaving one open order (bob's unchanged resting BID at 67400).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_matching_engine ──"
setup_mode matching

# Use a fresh identity for the taker so we don't clobber alice/bob's positions.
mdx_identity_new taker
TAKER=$(icp identity principal --identity taker)
call setTestBalance "(principal \"$TAKER\", \"ICPUSD\", $(e8 1000000.0))" --identity alice > /dev/null

# Taker BUYS 0.5 BTC at 67600 → should cross alice's ask and fully fill.
RESP=$(call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 67600) : nat, $(e8 0.5) : nat)" --identity taker)
assert_ok "taker order accepted" "$RESP"

# Sealed matching: a user↔user cross settles on the next GEPTOR release, not
# inline — wait for the trade to post before asserting.
wait_for "call getRecentTrades '(\"BTC-ICPUSD\")' | grep -q 'id = '" 20 1

# Recent trades should now contain exactly one trade for BTC-ICPUSD.
TRADES=$(call getRecentTrades '("BTC-ICPUSD")' | tr ';' '\n' | grep -c "id = ")
assert_eq "trades recorded" "1" "$TRADES"

# Alice's ask (1.0 BTC) is half-filled → 0.5 remaining.
ORDERS=$(call getMyOrdersOnMarket '("BTC-ICPUSD")' --identity alice)
assert_contains "alice ask still open at 67600" "$ORDERS" "$(e8 67600)"
assert_contains "alice ask remaining 0.5"       "$ORDERS" "$(e8 0.5)"

# Bob's bid at 67400 should be untouched.
BOB_ORDERS=$(call getMyOrdersOnMarket '("BTC-ICPUSD")' --identity bob)
assert_contains "bob bid untouched at 67400" "$BOB_ORDERS" "$(e8 67400)"

finish_test "test_matching_engine"
