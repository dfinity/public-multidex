#!/bin/bash
# Sealed model — the SETTLEMENT path. Replaces the retired
# test_pending_finalize.sh: there is no PendingMatch window to finalise anymore
# — orders stage sealed and release on the next GEPTOR (or, on a market with no
# AMM pool like this fixture, via the heartbeat's deferred-expiry users-only
# release within a few seconds). What must still hold end-to-end through a live
# user↔user cross:
#   • the cross settles into exactly one real trade,
#   • BOTH sides' reservations return to zero,
#   • balances actually move (seller's base down, buyer's base up),
#   • the symmetric maker/taker quote-leg fee accrues to the TREASURY
#     (this is the live-fill fee guard — the arithmetic is unit-tested in
#     MatchingEngine.test.mo; this proves the deployed wiring skims it).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_staged_settlement ──"
setup_mode staged    # alice: BUY 1.0 BTC @ 75000 (staged→resting); bob: 5 BTC

# Treasury baseline (the staged seed resets the exchange, so this is 0).
TRE0=$(extract_nat lifetimeFeesUsd "$(call getTreasury '()')")
# Alice's BTC baseline: the fixture sets her ICPUSD but does NOT zero her BTC
# (identities persist across seeds), so assert the DELTA of the buy, not an
# absolute balance.
ALICE_BTC0=$(extract_first_nat "$(call getBalance '("BTC")' --identity alice)")

# Snapshot trades, then trigger the cross.
TRADES_BEFORE=$(call getRecentTrades '("BTC-ICPUSD")' | grep -c "id = " || true)
call placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 75000.0) : nat, $(e8 1.0) : nat)" --identity bob > /dev/null

# Sealed model: both orders release + settle within the deferred-release window.
wait_for "call getRecentTrades '(\"BTC-ICPUSD\")' | grep -q 'id = '" 25 1

# Exactly one new trade printed.
TRADES_AFTER=$(call getRecentTrades '("BTC-ICPUSD")' | grep -c "id = " || true)
DELTA=$(( TRADES_AFTER - TRADES_BEFORE ))
assert_eq "exactly one new trade recorded" "1" "$DELTA"

# Both reservations returned to zero (settlement consumed them).
ALICE_RES=$(call getMyReservedBalance '("ICPUSD")' --identity alice | tr -d '_' | grep -oE "[0-9]+" | head -1)
BOB_RES=$(call getMyReservedBalance '("BTC")' --identity bob | tr -d '_' | grep -oE "[0-9]+" | head -1)
assert_eq "alice ICPUSD reservation cleared" "0" "${ALICE_RES:-x}"
assert_eq "bob BTC reservation cleared"      "0" "${BOB_RES:-x}"

# Balances moved: bob 5 → 4 BTC (sold 1; the fixture DOES set his BTC), and
# alice's BTC grew by exactly the 1.0 she bought.
BOB_BTC=$(from_e8 "$(extract_first_nat "$(call getBalance '("BTC")' --identity bob)")")
ALICE_BTC1=$(extract_first_nat "$(call getBalance '("BTC")' --identity alice)")
ALICE_DELTA=$(from_e8 "$(( ${ALICE_BTC1:-0} - ${ALICE_BTC0:-0} ))")
assert_float_close "bob BTC after sale"      "4.0" "$BOB_BTC"     0.01
assert_float_close "alice BTC delta = +1.0"  "1.0" "$ALICE_DELTA" 0.01

# The live fill skimmed the symmetric maker/taker fee — 75,000 notional ×
# (5+10) bps = ~112.50 USD — SPLIT 50/50 between the LP vault and the
# treasury (drain fix 4; exact-split arithmetic is test_fee_split.sh's job).
TRE=$(call getTreasury '()')
TRE1=$(extract_nat lifetimeFeesUsd "$TRE")
VLT1=$(extract_nat lifetimeVaultFeesUsd "$TRE")
FEE=$(( ${TRE1:-0} - ${TRE0:-0} ))
assert_gt "treasury accrued the quote-leg fees" "$FEE" "0"
assert_float_close "treasury books half of the ~112.50 fee" "56.25" "$(from_e8 "$FEE")" 0.02
assert_gt "the vault booked the other half" "${VLT1:-0}" "0"

finish_test "test_staged_settlement"
