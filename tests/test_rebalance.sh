#!/bin/bash
# Regression: AMM inventory-rebalance must actually FIRE when inventory
# drifts off target. This is the regression lock for the bug where
# the dust check `quoteDepthBase * 0.5` always rejected rebalances on
# any pool whose `quoteDepthBase < maxQtyPerTick * 2` — silently
# disabling the entire rebalance defense.
#
# Setup:
#   1. Create an AMM pool (refPrice 75000, 2 BTC + 150k seeded).
#   2. Configure aggressive rebalance: 5% threshold, no cooldown.
#   3. Manipulate the AMM principal's BTC balance to be 50% over
#      target (i.e. 3 BTC against a 2 BTC target).
#   4. Manually trigger rebalance.
#   5. Assert: rebalance ran (lastRebalanceNs > 0), AMM placed a SELL
#      market order (some BTC sold, ICPUSD reserves grew).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_rebalance ──"
setup_mode amm

# Get the AMM's principal — it has the inventory we'll skew.
AMM_PRI=$(call getAmmPrincipal '()' | grep -oE 'principal "[^"]+"' | head -1 | sed 's/principal "//; s/"//')

# seed_amm doesn't configure skew/rebalance. Set inventoryTargetBase
# explicitly — without it, decideRebalance bails out at the first
# guard (`if (pool.inventoryTargetBase <= 0.0) return null`) and the
# whole rebalance defense is silently a no-op.
call setAmmSkewConfig "(\"BTC-ICPUSD\", $(e8 2.0) : nat, 200 : nat)" --identity alice > /dev/null

# Force inventory deviation: target is 2 BTC; bump AMM's BTC to 3.0
# (50% over target) so rebalance is justified.
call setTestBalance "(principal \"$AMM_PRI\", \"BTC\", $(e8 3.0))" --identity alice > /dev/null

# Aggressive rebalance config: 5% threshold (we're at 50% over), no
# cooldown (so the manual trigger isn't gated). maxQtyPerTick large
# enough to clear the dust check (target * 0.05 = 0.1 BTC).
# (thresholdPct/fractionPerTick/maxSlippage are Float; only maxQtyPerTick
#  is a base-unit Nat quantity → e8.)
call setAmmRebalanceConfig \
  "(\"BTC-ICPUSD\", 0.05 : float64, 0.20 : float64, 0 : nat, $(e8 0.5) : nat, 0.05 : float64)" \
  --identity alice > /dev/null

# The CORE regression we're locking: rebalance fires when inventory
# is off-target. The previous bug silently disabled it via a dust-
# threshold misconfiguration. So the high-leverage assertion is
# "lastRebalanceNs goes from 0 to non-zero after the trigger."
#
# We DON'T assert exact inventory deltas because the AMM's 2-second
# requote tick interleaves with our test calls and produces protected-
# maker pending matches with 8s windows; the resulting balance flow
# is timing-dependent and not what this test exists to verify. The
# `decideRebalance` math is exercised separately in unit tests.
# Drain-fix regression: the AUTO rebalancer must ship OFF. Inventory recovery
# is passive (one-sided skewed quotes); the taker loop is opt-in for ops only.
AUTO=$(call getAmmRebalanceEnabled '()')
assert_contains "auto-rebalancer defaults OFF" "$AUTO" "false"

# Need a counterparty bid so the rebalance's market SELL has somewhere to
# land — without one, the call would still set lastRebalanceNs but wouldn't
# exercise the trade-execution path. The bid must sit INSIDE the tightened
# forced-taker cap (spread + one level = 35bp → floor 74,737.5); the old
# 74,500 bid is now correctly out of reach — that price being takeable was
# exactly the "park an order and wait for the vault" leak.
mdx_identity_new buyer
BUYER=$(principal_of buyer)
call setTestBalance "(principal \"$BUYER\", \"ICPUSD\", $(e8 100000.0))" --identity alice > /dev/null
call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 74850.0) : nat, $(e8 0.5) : nat)" --identity buyer > /dev/null

# Trigger rebalance (manual controller path — works regardless of the flag).
REBAL=$(call rebalanceAmm '("BTC-ICPUSD")' --identity alice)
assert_ok "rebalance call returned" "$REBAL"

# Verify: lastRebalanceNs is now set (was 0 in the seed_amm fixture).
# This single assertion is the regression lock for the dust-threshold
# bug — if decideRebalance silently rejects every gap as dust again,
# this stays at 0 and the test fails.
POOL=$(call getAmmPool '("BTC-ICPUSD")')
LRN_AFTER=$(extract_nat "lastRebalanceNs" "$POOL")
assert_gt "rebalance fired (lastRebalanceNs advanced)" "${LRN_AFTER:-0}" "0"

finish_test "test_rebalance"
