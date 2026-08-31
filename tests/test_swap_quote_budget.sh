#!/bin/bash
# test_swap_quote_budget.sh — issue #48.5: the market swap is quote-consistent
# with quoteSwap's budget ("spend ≤ amount").
#
# executeSwapDirect's market #buy used to size the base quantity at the BEST
# price p0 (qty = amount/p0) while capping fills at p0×(1+maxSlippage) — so the
# settled debit could reach amount×(1+maxSlippage)+fee, up to 25% over the
# previewed spend (W4-04 bounds the band at 25%). The fix sizes the quantity at
# the slippage-CAP price with the worst-case taker fee carved out, so
# fillCost + fee ≤ amount whatever mix of prices ≤ cap the release finds.
#
# Fixture (the finding's own numbers): users-only book of 50 ICP @ $5 +
# 150 ICP @ $6; swap $1,000 → ICP at 25% slippage (cap $6.25), fill-or-kill.
#   pre-fix : qty = 1000/5 = 200 → fills 50@5 + 150@6 → debit ≈ $1,151  ✗
#   post-fix: qty = (1000 − fee)/6.25 ≈ 159.8 → debit ≈ $910 ≤ $1,000   ✓
# FOK keeps the release single-shot (the spot #3a AMM-ladder walk re-defers
# partial remainders across requotes — needless nondeterminism here).
#
# The AMM pool must EXIST + be ENABLED for the GEPTOR release to run, but it is
# deliberately left UNFUNDED so it posts no quotes: the book stays exactly the
# two maker levels (asserted below).
#
# NOTE: resets + rebuilds the venue (resetExchange). Reseed after, like
# test_swap_outcome / test_state_reset.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_swap_quote_budget ──"

if [ "$(venue_posture)" != "dev" ]; then
  skip_posture "test_swap_quote_budget" "resetExchange/setTestBalance/setAmmRefPrice dev hooks"
fi

MKT="ICP-ICPUSD"

icp identity new sqb_maker --storage plaintext 2>/dev/null || true
icp identity new sqb_user  --storage plaintext 2>/dev/null || true
MAKER=$(principal_of sqb_maker)
USER=$(principal_of sqb_user)

call resetExchange '()' > /dev/null
call setTestTimersPaused '(true)' > /dev/null

# Pool: exists + enabled (release path) but unfunded (no AMM quotes).
call createAmmPool "(\"$MKT\")" > /dev/null
call setAmmRefPrice "(\"$MKT\", $(e8 5) : nat)" > /dev/null
call enableAmm "(\"$MKT\", true)" > /dev/null

# Re-stamp the ref price + requote: counts as a fresh fetch, so the GEPTOR
# that follows releases everything staged before the stamp.
release_market() {
  call setAmmRefPrice "(\"$MKT\", $(e8 5) : nat)" > /dev/null
  call requoteAmm "(\"$MKT\")" > /dev/null
}

bal_of() { # principal token → base units
  local n; n=$(extract_first_nat "$(call getTestBalance "(principal \"$1\", \"$2\")")"); echo "${n:-0}"
}

# ── Book: 50 @ $5 + 150 @ $6, users only ─────────────────────────
call setTestBalance "(principal \"$MAKER\", \"ICP\", $(e8 200) : nat)" > /dev/null
call placeLimitOrder "(\"$MKT\", variant { sell }, $(e8 5) : nat, $(e8 50) : nat)"  --identity sqb_maker > /dev/null
call placeLimitOrder "(\"$MKT\", variant { sell }, $(e8 6) : nat, $(e8 150) : nat)" --identity sqb_maker > /dev/null
release_market
wait_for "call getOrderBook '(\"$MKT\")' --query | tr -d '_' | grep -q '600000000'" 15 1
BOOK=$(call getOrderBook "(\"$MKT\")" --query | tr -d '_')
assert_contains "book has the \$5 ask"  "$BOOK" "500000000"
assert_contains "book has the \$6 ask"  "$BOOK" "600000000"
ASK_COUNT=$(echo "$BOOK" | grep -oE "price = [0-9]+" | wc -l | tr -d ' ')
assert_eq "book is users-only (exactly the 2 maker levels)" "2" "$ASK_COUNT"

# ── Preview: quoteSwap's budget promise ───────────────────────────
call setTestBalance "(principal \"$USER\", \"ICPUSD\", $(e8 5000) : nat)" > /dev/null
# Zero the user's ICP explicitly — resetExchange does not wipe balances, and a
# leftover holding from a previous run breaks the received-amount assertions.
call setTestBalance "(principal \"$USER\", \"ICP\", 0 : nat)" > /dev/null
Q=$(call quoteSwap "(\"ICPUSD\", \"ICP\", $(e8 1000) : nat, $(e8 0.25) : nat)" --identity sqb_user --query)
Q_OUT=$(extract_nat "outAmount" "$Q")
Q_CONSUMED=$(extract_nat "consumedFrom" "$Q")
assert_gt "quoteSwap previews a real fill" "$(from_e8 "${Q_OUT:-0}")" "50"
assert_lt "quoteSwap consumedFrom ≤ amount" "$(from_e8 "${Q_CONSUMED:-0}")" "1000.00001"

# ── Execute: swap $1000 → ICP, 25% slippage, FOK ──────────────────
USD0=$(bal_of "$USER" ICPUSD)
SW=$(call swap "(record {
  fromToken = \"ICPUSD\";
  toToken   = \"ICP\";
  amount    = $(e8 1000) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.25) : nat } };
  noPartialFill = true
})" --identity sqb_user)
assert_contains "swap accepted + staged" "$SW" "swapOrderId = opt"

release_market
wait_for "[ \"\$(bal_of \"$USER\" ICP)\" -gt 0 ]" 20 1

ICP_GOT=$(from_e8 "$(bal_of "$USER" ICP)")
USD1=$(bal_of "$USER" ICPUSD)
DEBIT=$(from_e8 "$(( USD0 - USD1 ))")
echo "   swapped: received ${ICP_GOT} ICP, debited \$${DEBIT} (amount was \$1000)"

# The finding's assertion: the debit must respect the previewed budget —
# pre-fix this reads ≈ $1151 (amount × 1.25 walked into the $6 level) and FAILS.
assert_lt "debit ≤ amount (quote-budget honoured)" "$DEBIT" "1000.00001"
# The fill genuinely walked past the best level (>50 ICP means the $6 level
# filled too) — the scenario exercises multi-price fills, not a trivial fill.
assert_gt "fill walked into the \$6 level" "$ICP_GOT" "50"
# Substantially filled: the sizing converts most of the budget, not a sliver.
assert_gt "debit is a real conversion (> \$800)" "$DEBIT" "800"
# VWAP within the user's slippage band (≤ $6.25).
VWAP=$(python3 -c "print($DEBIT / $ICP_GOT)")
assert_lt "settled VWAP ≤ slippage cap \$6.25" "$VWAP" "6.2500001"
# Conservative direction only: execution never promises more than the preview.
assert_lt "executed outAmount ≤ quoted outAmount" "$ICP_GOT" "$(python3 -c "print($(from_e8 "${Q_OUT:-0}") + 0.00001)")"

call setTestTimersPaused '(false)' > /dev/null

finish_test "test_swap_quote_budget"
