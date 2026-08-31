#!/bin/bash
# test_swap_direct_budget.sh — task 1787209266 (split from 1787204744): the
# NON-FOK direct market swap converts its WHOLE stated amount, not
# amount/(1+maxSlippage).
#
# executeSwapDirect's market #buy used to size its base quantity at the
# slippage-CAP price (the #48.5 quote-consistency fix), which honoured the
# budget but stranded up to amount×slip/(1+slip) UNCONVERTED on below-cap
# fills — the user asked to spend $1000 and got $1000/(1+slip) worth. The fix
# sizes the quantity at the BEST price with the worst-case taker fee carved
# out and stages the amount as a quote-spend budget (deferredBudget → the
# release engine's maxQuoteSpend): every slice stops at
# min(balance, remaining budget), so a walking book converts the FULL amount
# to within rounding crumbs — never past it.
#
# Fixture: users-only book of 50 ICP @ $5.00 + 300 ICP @ $5.08; swap
# $1,000 → ICP at 25% slippage, noPartialFill = FALSE (the staged
# releaseDeferred path — FOK keeps cap-sizing and is covered byte-for-byte by
# test_swap_quote_budget). Both levels sit inside the unfunded-AMM ladder-edge
# clamp (±2% of the $5 mid → $5.10), so ONE release cycle reaches both.
#   pre-fix : qty = (1000−fee)/6.25 ≈ 159.8 → debit ≈ $808.8, ≈ $191
#             returned unconverted                                        ✗
#   post-fix: qty = (1000−fee)/5.00 ≈ 199.8 → fills 50@5.00, then the
#             $5.08 slice SHRINKS to the remaining budget → debit ≈ $1000 ✓
# Budget truthfulness rider: the base remainder left when the budget is
# exhausted is a COMPLETE conversion — it must NOT record the "no liquidity
# within the slippage cap" drop note (asserted via getMyReleaseRejections).
#
# The AMM pool must EXIST + be ENABLED for the GEPTOR release to run, but it
# is deliberately left UNFUNDED so it posts no quotes: the book stays exactly
# the two maker levels (asserted below).
#
# NOTE: resets + rebuilds the venue (resetExchange). Reseed after, like
# test_swap_outcome / test_state_reset. Needs #dev.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_swap_direct_budget ──"

if [ "$(venue_posture)" != "dev" ]; then
  skip_posture "test_swap_direct_budget" "resetExchange/setTestBalance/setAmmRefPrice dev hooks"
fi

MKT="ICP-ICPUSD"

icp identity new sdb_maker --storage plaintext 2>/dev/null || true
icp identity new sdb_user  --storage plaintext 2>/dev/null || true
MAKER=$(principal_of sdb_maker)
USER=$(principal_of sdb_user)

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

# ── Book: 50 @ $5.00 + 300 @ $5.08, users only, both inside the ±2% edge ──
call setTestBalance "(principal \"$MAKER\", \"ICP\", $(e8 350) : nat)" > /dev/null
call placeLimitOrder "(\"$MKT\", variant { sell }, $(e8 5) : nat, $(e8 50) : nat)"     --identity sdb_maker > /dev/null
call placeLimitOrder "(\"$MKT\", variant { sell }, $(e8 5.08) : nat, $(e8 300) : nat)" --identity sdb_maker > /dev/null
release_market
wait_for "call getOrderBook '(\"$MKT\")' --query | tr -d '_' | grep -q '508000000'" 15 1
BOOK=$(call getOrderBook "(\"$MKT\")" --query | tr -d '_')
assert_contains "book has the \$5.00 ask" "$BOOK" "500000000"
assert_contains "book has the \$5.08 ask" "$BOOK" "508000000"
ASK_COUNT=$(echo "$BOOK" | grep -oE "price = [0-9]+" | wc -l | tr -d ' ')
assert_eq "book is users-only (exactly the 2 maker levels)" "2" "$ASK_COUNT"

# ── Fund the taker; zero any leftover ICP from a previous run ─────────────
call setTestBalance "(principal \"$USER\", \"ICPUSD\", $(e8 5000) : nat)" > /dev/null
call setTestBalance "(principal \"$USER\", \"ICP\", 0 : nat)" > /dev/null
Q=$(call quoteSwap "(\"ICPUSD\", \"ICP\", $(e8 1000) : nat, $(e8 0.25) : nat)" --identity sdb_user --query)
Q_OUT=$(extract_nat "outAmount" "$Q")

# ── Execute: swap $1000 → ICP, 25% slippage, NON-FOK (partial fill OK) ─────
USD0=$(bal_of "$USER" ICPUSD)
SW=$(call swap "(record {
  fromToken = \"ICPUSD\";
  toToken   = \"ICP\";
  amount    = $(e8 1000) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.25) : nat } };
  noPartialFill = false
})" --identity sdb_user)
assert_contains "swap accepted + staged" "$SW" "swapOrderId = opt"

release_market
wait_for "[ \"\$(bal_of \"$USER\" ICP)\" -gt 0 ]" 20 1

ICP_RAW=$(bal_of "$USER" ICP)
ICP_GOT=$(from_e8 "$ICP_RAW")
USD1=$(bal_of "$USER" ICPUSD)
DEBIT=$(from_e8 "$(( USD0 - USD1 ))")
echo "   swapped: received ${ICP_GOT} ICP, debited \$${DEBIT} (amount was \$1000)"

# Budget still honoured: never spend PAST the stated amount.
assert_lt "debit ≤ amount (budget honoured)" "$DEBIT" "1000.00001"
# THE assertion (red pre-change): the WHOLE amount converts, to within crumbs —
# not amount/(1+slip). Pre-fix cap-sizing reads ≈ $808.8 here and FAILS.
assert_gt "debit ≈ amount — residual eliminated (≥ \$999)" "$DEBIT" "999"
# The fill genuinely walked past the best level (>50 ICP means the $5.08
# level filled too, via the budget-shrunk slice).
assert_gt "fill walked into the \$5.08 level" "$ICP_GOT" "50"
# VWAP within the band the release actually ran at (≤ the $5.10 edge clamp).
VWAP=$(python3 -c "print($DEBIT / $ICP_GOT)")
assert_lt "settled VWAP ≤ users-only edge \$5.10" "$VWAP" "5.1000001"
# Preview parity (task 1787210750): quoteSwap's walker runs the ENGINE's exact
# per-slice budget arithmetic (floored tradeCost, per-slice fee, the
# mulDiv(rem,10⁴,10⁴+eff)/price shrink), so execution can never over-deliver
# past the preview: executed ≤ quoted + 1 base unit. The pre-parity walker
# carved ONE aggregate fee upfront and under-quoted by the second-order fee
# crumb (~amount×eff² — 0.00019 ICP on this fixture), which this caught.
assert_lt "executed ≤ quoted + 1 base unit (preview parity)" "$ICP_RAW" "$(( ${Q_OUT:-0} + 2 ))"

# Drop-note truthfulness: the base remainder left at budget exhaustion is a
# COMPLETE conversion — it must NOT surface as a "remainder dropped: no
# liquidity within the slippage cap" rejection.
REJ=$(call getMyReleaseRejections '()' --identity sdb_user --query)
assert_not_contains "no false 'remainder dropped' note on a complete conversion" "$REJ" "remainder dropped"

call setTestTimersPaused '(false)' > /dev/null

finish_test "test_swap_direct_budget"
