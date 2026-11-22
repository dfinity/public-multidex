#!/bin/bash
# Minimum order notional (Types.MIN_ORDER_ICPUSD = 10 ICPUSD) with the
# dust-out exemption: an order below the minimum is refused UNLESS it commits
# the caller's entire remaining balance of the funding token — dust must never
# be stranded. Covers limit (both sides), market sell, and swap; the minimum
# is published via getAccessPolicy.thresholds.minOrderNotionalUsd.
# ⚠️ Calls resetExchange (via the matching fixture).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_min_order ──"
setup_mode matching   # BTC-ICPUSD market, no AMM pool

mdx_identity_new dusty
DU=$(principal_of dusty)
# Rich in ICPUSD; a DUST BTC balance worth ~$6 at the test price of 60,000.
call setTestBalance "(principal \"$DU\", \"ICPUSD\", $(e8 100000) : nat)" --identity alice > /dev/null
call setTestBalance "(principal \"$DU\", \"BTC\",    $(e8 0.0001) : nat)" --identity alice > /dev/null

# (0) the minimum is published policy
POL=$(call getAccessPolicy '()' --identity dusty --query)
assert_contains "minimum published in policy" "$POL" "minOrderNotionalUsd = $(e8 10)"

# (1) limit BUY below the minimum (rich balance) → refused
A=$(call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 60000) : nat, $(e8 0.0001) : nat)" --identity dusty)   # $6
assert_contains "limit buy \$6 refused" "$A" "below the"
# …at the minimum → accepted
B=$(call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 60000) : nat, $(e8 0.0002) : nat)" --identity dusty)   # $12
assert_ok "limit buy \$12 accepted" "$B"

# (2) limit SELL of HALF the dust balance → refused (not a full dust-out)
C=$(call placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 60000) : nat, $(e8 0.00005) : nat)" --identity dusty) # $3 of $6
assert_contains "half-dust sell refused" "$C" "below the"
# …selling the ENTIRE remaining BTC → exempt, accepted ($6 < $10 but it's all of it)
D=$(call placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 60000) : nat, $(e8 0.0001) : nat)" --identity dusty)
assert_ok "full dust-out sell accepted" "$D"

# (3) market SELL below the minimum with a rich balance → refused.
#     Needs an AMM ref price for the notional anchor: create+price the pool
#     (disabled — no quoting, just the anchor).
call createAmmPool '("BTC-ICPUSD")' --identity alice > /dev/null 2>&1
call setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 60000) : nat)" --identity alice > /dev/null
call setTestBalance "(principal \"$DU\", \"BTC\", $(e8 1.0) : nat)" --identity alice > /dev/null   # now rich in BTC
E=$(call placeMarketOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 0.0001) : nat, $(e8 0.05) : nat, false)" --identity dusty)  # $6 of $60k held
assert_contains "market sell \$6 refused (rich balance)" "$E" "below the"

# (4) swap below the minimum with a rich balance → refused; full-balance swap exempt
F=$(call swap "(record { fromToken=\"ICPUSD\"; toToken=\"BTC\"; amount=$(e8 5) : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.05) : nat } }; noPartialFill=false })" --identity dusty)
assert_contains "swap \$5 refused" "$F" "below the"

finish_test "test_min_order"
