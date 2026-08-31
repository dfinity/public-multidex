#!/bin/bash
# test_cross_swap_budget.sh — #48.5 sibling: BOTH cross-swap BUY legs are
# budget-bound by the SELL leg's proceeds (task 1787189218).
#
# Both cross-swap BUY legs used to size their quantity at the BEST ask
# (qty = proceeds/bestAsk, fee carved out) while executing with the full
# maxSlippage band (fills allowed up to bestAsk×(1+maxSlippage)). The engine
# caps a taker's spend only by their WHOLE available ICPUSD — so when fills
# landed above the best ask the buy leg dipped into the user's UNRELATED
# ICPUSD, up to proceeds×maxSlippage beyond the swap's own money. The fix
# sizes at the CAP price (bestAsk×(1+maxSlippage), fee carved out — the
# executeSwapDirect #48.5 shape), so fillCost+fee ≤ proceeds whatever mix of
# prices ≤ cap the fills find; the flat-book cost is a smaller conversion,
# never an overspend.
#
# Fixture (per phase; the brief's numbers): user swaps 100 ICP → BTC at 25%
# slippage. Sell book: users-only bid 200 ICP @ $10 → proceeds $1000. Buy
# book: users-only asks 50 BTC @ $5 + 150 BTC @ $6. User pre-funded with an
# UNRELATED $5000 ICPUSD.
#   pre-fix : buyQty ≈ 1000/5 ≈ 200 → fills 50@5 + ~150@6 ≈ $1149 debit —
#             ≈ $150 of the user's unrelated ICPUSD spent  ✗
#   post-fix: buyQty ≈ 1000/6.25 ≈ 160 → fills 50@5 + ~110@6 ≈ $909 ≤ $1000;
#             net ICPUSD change ≥ −(taker fee)  ✓
# Both sites are covered:
#   §1 FOK immediate path   (executeSwapCross, noPartialFill=true)
#   §2 deferred release path (releaseCrossSwap via setAmmRefPrice + requoteAmm
#      on BOTH legs + adminRunDeferredSwaps)
#
# AMM pools exist + are enabled (release path) but stay UNFUNDED, so the books
# are exactly the maker levels (asserted).
#
# NOTE: resets + rebuilds the venue (resetExchange). Reseed after, like
# test_swap_outcome / test_state_reset. Needs #dev.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_cross_swap_budget ──"

if [ "$(venue_posture)" != "dev" ]; then
  skip_posture "test_cross_swap_budget" "resetExchange/setTestBalance/setAmmRefPrice dev hooks"
fi

SELLM="ICP-ICPUSD"
BUYM="BTC-ICPUSD"

icp identity new csb_maker --storage plaintext 2>/dev/null || true
icp identity new csb_user  --storage plaintext 2>/dev/null || true
MAKER=$(principal_of csb_maker)
USER=$(principal_of csb_user)

bal_of() { # principal token → base units
  local n; n=$(extract_first_nat "$(call getTestBalance "(principal \"$1\", \"$2\")")"); echo "${n:-0}"
}

# Re-stamp both legs' ref prices + requote (fresh-fetch semantics: releases
# everything staged before the stamp), then run the deferred-swap pass.
release_all() {
  call setAmmRefPrice "(\"$SELLM\", $(e8 10) : nat)" > /dev/null
  call requoteAmm "(\"$SELLM\")" > /dev/null
  call setAmmRefPrice "(\"$BUYM\", $(e8 5) : nat)" > /dev/null
  call requoteAmm "(\"$BUYM\")" > /dev/null
  call adminRunDeferredSwaps '()' > /dev/null
}

# Full fixture reset: users-only two-level buy book + deep sell bid, user
# holding 100 ICP to convert plus $5000 of UNRELATED ICPUSD.
build_fixture() {
  call resetExchange '()' > /dev/null
  call setTestTimersPaused '(true)' > /dev/null
  # Pools: exist + enabled (release path) but unfunded (no AMM quotes).
  for m in "$SELLM" "$BUYM"; do call createAmmPool "(\"$m\")" > /dev/null; done
  call setAmmRefPrice "(\"$SELLM\", $(e8 10) : nat)" > /dev/null
  call setAmmRefPrice "(\"$BUYM\", $(e8 5) : nat)" > /dev/null
  call enableAmm "(\"$SELLM\", true)" > /dev/null
  call enableAmm "(\"$BUYM\", true)" > /dev/null
  # Maker: a $10 bid the sell leg hits, and the 50@$5 + 150@$6 ask ladder.
  call setTestBalance "(principal \"$MAKER\", \"ICPUSD\", $(e8 10000) : nat)" > /dev/null
  call setTestBalance "(principal \"$MAKER\", \"BTC\", $(e8 400) : nat)" > /dev/null
  call setTestBalance "(principal \"$MAKER\", \"ICP\", 0 : nat)" > /dev/null
  call placeLimitOrder "(\"$SELLM\", variant { buy }, $(e8 10) : nat, $(e8 200) : nat)" --identity csb_maker > /dev/null
  call placeLimitOrder "(\"$BUYM\", variant { sell }, $(e8 5) : nat, $(e8 50) : nat)"   --identity csb_maker > /dev/null
  call placeLimitOrder "(\"$BUYM\", variant { sell }, $(e8 6) : nat, $(e8 150) : nat)"  --identity csb_maker > /dev/null
  release_all
  wait_for "call getOrderBook '(\"$BUYM\")' --query | tr -d '_' | grep -q '600000000'" 15 1
  wait_for "call getOrderBook '(\"$SELLM\")' --query | tr -d '_' | grep -q '1000000000'" 15 1
  local sbook; sbook=$(call getOrderBook "(\"$SELLM\")" --query | tr -d '_')
  assert_contains "sell book has the \$10 bid" "$sbook" "1000000000"
  local book; book=$(call getOrderBook "(\"$BUYM\")" --query | tr -d '_')
  assert_contains "buy book has the \$5 ask" "$book" "500000000"
  assert_contains "buy book has the \$6 ask" "$book" "600000000"
  local lvls; lvls=$(echo "$book" | grep -oE "price = [0-9]+" | wc -l | tr -d ' ')
  assert_eq "buy book is users-only (exactly the 2 maker levels)" "2" "$lvls"
  # User: 100 ICP to convert + $5000 UNRELATED ICPUSD; no BTC.
  call setTestBalance "(principal \"$USER\", \"ICP\", $(e8 100) : nat)" > /dev/null
  call setTestBalance "(principal \"$USER\", \"ICPUSD\", $(e8 5000) : nat)" > /dev/null
  call setTestBalance "(principal \"$USER\", \"BTC\", 0 : nat)" > /dev/null
}

# The finding's assertion, shared by both phases: the net ICPUSD debit beyond
# the sell proceeds is ~0 (taker-fee tolerance, $1 on $1000 at 10 bps — we
# allow $3), NOT proceeds×maxSlippage (≈ $150 pre-fix).
assert_budget() { # $1 = phase label, $2 = USD before (base units)
  local usd1 btc_got extra
  usd1=$(bal_of "$USER" ICPUSD)
  btc_got=$(from_e8 "$(bal_of "$USER" BTC)")
  extra=$(python3 -c "print(($2 - $usd1) / 100000000.0)")
  echo "   $1: received ${btc_got} BTC, ICPUSD debit beyond sell proceeds = \$${extra}"
  assert_lt "$1: extra ICPUSD debit beyond sell proceeds ~0 (≤ \$3 fee tolerance)" "$extra" "3"
  assert_gt "$1: fill walked into the \$6 level (>50 BTC)" "$btc_got" "50"
  assert_gt "$1: substantial conversion (>100 BTC)" "$btc_got" "100"
}

# ── §1 FOK immediate path (executeSwapCross, noPartialFill=true) ──────────
echo ""
echo "── §1 immediate FOK cross-swap: 100 ICP → BTC @ 25% slippage ──"
build_fixture
USD0=$(bal_of "$USER" ICPUSD)
SW=$(call swap "(record {
  fromToken = \"ICP\";
  toToken   = \"BTC\";
  amount    = $(e8 100) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.25) : nat } };
  noPartialFill = true
})" --identity csb_user)
assert_contains "immediate swap settled (fromAmount > 0)" "$SW" "fromAmount ="
FROM_GOT=$(extract_nat "fromAmount" "$SW")
assert_eq "sell leg fully converted (fromAmount = 100 ICP)" "$(e8 100)" "${FROM_GOT:-0}"
assert_budget "FOK path" "$USD0"

# ── §2 deferred release path (releaseCrossSwap) ───────────────────────────
echo ""
echo "── §2 deferred cross-swap: 100 ICP → BTC @ 25% slippage ──"
build_fixture
USD0=$(bal_of "$USER" ICPUSD)
SW=$(call swap "(record {
  fromToken = \"ICP\";
  toToken   = \"BTC\";
  amount    = $(e8 100) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.25) : nat } };
  noPartialFill = false
})" --identity csb_user)
assert_contains "cross-swap staged (swapOrderId returned)" "$SW" "swapOrderId = opt"
release_all
wait_for "[ \"\$(bal_of \"$USER\" BTC)\" -gt 0 ]" 20 1
OUTCOME=$(call getMyRecentSwap '()' --identity csb_user)
assert_contains "outcome recorded as filled" "$OUTCOME" "filled = true"
assert_budget "deferred path" "$USD0"

call setTestTimersPaused '(false)' > /dev/null

finish_test "test_cross_swap_budget"
