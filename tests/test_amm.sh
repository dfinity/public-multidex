#!/bin/bash
# Regression: AMM seed should produce a pool at refPrice 75000, and a
# manual requote should place numLevels bids + numLevels asks around
# that price, tagged with a protection window.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_amm ──"
setup_mode amm

POOL=$(call getAmmPool '("BTC-ICPUSD")')
# refPrice is a base-unit Nat (75000 * 10^8); the old "75000.0" needle's `.`
# was a grep wildcard over the digits, not a decimal point (#51.8).
assert_contains "pool refPrice 75000"  "$POOL" "refPrice = 7500000000000 "
assert_contains "pool enabled"         "$POOL" "enabled = true"
assert_contains "pool has baseToken"   "$POOL" "baseToken = \"BTC\""

# Trigger an explicit requote and count the orders placed. (We do NOT
# assert the ladder is empty beforehand — the AMM tick timer fires
# every 2s, so depending on wall-clock timing the ladder may already
# be populated by the time the first query lands.)
REQUOTE=$(call requoteAmm '("BTC-ICPUSD")' --identity alice)
assert_contains "requote ok" "$REQUOTE" "ok"

POOL2=$(call getAmmPool '("BTC-ICPUSD")')
# The default pool config has numLevels = 3 → 6 orders (3 bids + 3 asks).
# Six nat IDs appear as "N : nat;" entries in activeBidIds + activeAskIds.
BID_COUNT=$(echo "$POOL2" | tr ',' '\n' | grep -c "_\+.*nat.*activeBid" || true)
# Simpler heuristic: split on "activeBidIds = vec {" and count nats in that
# section. Grep for nat count between "activeBidIds = vec {" and "}".
BIDS=$(echo "$POOL2" | awk '/activeBidIds = vec {/,/}/' | grep -oE "[0-9_]+ : nat" | wc -l | tr -d ' ')
ASKS=$(echo "$POOL2" | awk '/activeAskIds = vec {/,/}/' | grep -oE "[0-9_]+ : nat" | wc -l | tr -d ' ')
assert_eq "3 active bids"  "3" "$BIDS"
assert_eq "3 active asks"  "3" "$ASKS"

finish_test "test_amm"
