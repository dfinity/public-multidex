#!/bin/bash
# Regression: the 0-qty-zombie-order bug (fixed earlier) must stay
# fixed. Specifically: a taker whose entire quantity goes into a
# pending match must NOT leave a 0-qty order in the open-book indexes.
#
# Reproducer:
#   1. Alice places a protected BUY @75000 qty 1.0 (10s window).
#   2. Bob sells 1.0 → taker slice fully goes to pending.
#   3. Before the fix, a zombie ask at 75000 qty=0 would appear in
#      bob's open orders. After the fix, bob has zero open orders.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_zombie_free ──"
setup_mode staged

# Fire the cross.
call placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 75000.0) : nat, $(e8 1.0) : nat)" --identity bob > /dev/null

# Sealed matching: bob's crossing sell STAGES off-book and settles against alice's
# resting buy on the next GEPTOR release — wait for the trade to post before we
# inspect the book, otherwise bob's still-staged order trips the check for a
# benign reason (nothing to do with the zombie bug we're guarding).
wait_for "call getRecentTrades '(\"BTC-ICPUSD\")' | grep -q 'id = '" 20 1

# Bob's open orders on this market MUST be empty — his taker slice
# fully settled, never leaving a leftover (zombie) order on the book.
BOB_OPEN=$(call getMyOrdersOnMarket '("BTC-ICPUSD")' --identity bob)
# The return is `(vec { })` when empty. Normalize and check.
assert_contains "bob has no open orders" "$BOB_OPEN" "vec {}"

# Order book should also have no 0-qty entries at all.
# (base-unit qty is a Nat now, so a zero level prints `quantity = 0 : nat`.)
BOOK=$(call getOrderBook '("BTC-ICPUSD")')
ZEROES=$(echo "$BOOK" | grep -c "quantity = 0 :")
assert_eq "zero 0-qty levels on book" "0" "$ZEROES"

finish_test "test_zombie_free"
