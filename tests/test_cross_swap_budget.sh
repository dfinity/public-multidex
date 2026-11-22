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
# Both shapes are covered (both release through releaseCrossSwap since H-21
# staged the all-or-nothing path — the FOK one adds fokCrossGate in front):
#   §1 FOK cross-swap   (noPartialFill=true: staged, gated all-or-nothing at
#      release — the budget bound holds AND the whole amount converts)
#   §2 plain cross-swap (noPartialFill=false: staged, absorb-sized at release)
# Both released via setAmmRefPrice + requoteAmm on BOTH legs +
# adminRunDeferredSwaps.
#
# §3 (task 1788662146) — the FOK gate and the live BUY leg must agree on a
# maker funded for LESS than its order but MORE than the budget-affordable
# slice at its price. The $6 ask is a SECOND wallet maker (csb_maker2), rested
# fully funded then drained to 140 BTC (resting orders hold no reservation).
# The buy leg's second slice is min(buyQty − 50, 150) = 149.80 BTC unshrunk
# and 124.83 BTC after the $749.75 remaining-budget shrink; 124.83 < 140 <
# 149.80. The gate (walkFillable's #quoteSpend arm) trims the take to the
# budget BEFORE the maker's funding check and credits maker2 → the gate
# passes. Pre-fix executeMarketOrderProtected gated makerNeeds on the
# UNSHRUNK 149.80, cancelled maker2 with the mid-match notice, and the swap
# settled 50 BTC against a fully settled 100 ICP sell — W2-03's settle-then-
# short, one maker wide. Post-fix the engine shrinks first (the limit
# variant's and the walker's ordering) and maker2 fills its 124.83 slice.
# §3b: maker2 drained BELOW the shrunk slice (120 BTC) — gate and engine
# agree the other way: the FOK is killed at the gate, nothing settles.
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

mdx_identity_new csb_maker
mdx_identity_new csb_maker2
mdx_identity_new csb_user
MAKER=$(principal_of csb_maker)
MAKER2=$(principal_of csb_maker2)
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
# $1 (optional, §3): the $6 ask is owned by csb_maker2, rested with 400 BTC
# and then DRAINED to $1 BTC (human units) once it rests — a wallet maker
# funded for less than its order.
build_fixture() {
  local m2_after="${1:-}"
  local ask6_id=csb_maker
  [ -n "$m2_after" ] && ask6_id=csb_maker2
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
  if [ -n "$m2_after" ]; then
    call setTestBalance "(principal \"$MAKER2\", \"BTC\", $(e8 400) : nat)" > /dev/null
    call setTestBalance "(principal \"$MAKER2\", \"ICPUSD\", 0 : nat)" > /dev/null
  fi
  call placeLimitOrder "(\"$BUYM\", variant { sell }, $(e8 6) : nat, $(e8 150) : nat)"  --identity "$ask6_id" > /dev/null
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
  if [ -n "$m2_after" ]; then
    # Drain maker2 AFTER its ask rests (no reservation on resting orders).
    call setTestBalance "(principal \"$MAKER2\", \"BTC\", $(e8 "$m2_after") : nat)" > /dev/null
    assert_eq "maker2 drained to ${m2_after} BTC under its 150 BTC ask" "$(e8 "$m2_after")" "$(bal_of "$MAKER2" BTC)"
  fi
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

# ── §1 FOK cross-swap (staged since H-21; fokCrossGate at release) ─────────
echo ""
echo "── §1 FOK cross-swap: 100 ICP → BTC @ 25% slippage (staged, all-or-nothing at release) ──"
build_fixture
USD0=$(bal_of "$USER" ICPUSD)
SW=$(call swap "(record {
  fromToken = \"ICP\";
  toToken   = \"BTC\";
  amount    = $(e8 100) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.25) : nat } };
  noPartialFill = true
})" --identity csb_user)
assert_contains "FOK cross-swap staged (swapOrderId returned, nothing settled in the call)" "$SW" "swapOrderId = opt"
assert_contains "the staging reply carries no settlement" "$SW" "fromAmount = 0"
release_all
wait_for "[ \"\$(bal_of \"$USER\" BTC)\" -gt 0 ]" 20 1
OUTCOME=$(call getMyRecentSwap '()' --identity csb_user)
assert_contains "FOK outcome recorded as filled" "$OUTCOME" "filled = true"
FROM_GOT=$(extract_nat "fromAmount" "$OUTCOME")
assert_eq "sell leg fully converted (fromAmount = 100 ICP — all-or-nothing)" "$(e8 100)" "${FROM_GOT:-0}"
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

# ── §3 gate ↔ engine agreement on a partially funded maker (task 1788662146) ──
echo ""
echo "── §3 FOK cross-swap: the \$6 ask's maker holds 140 BTC — under its 150 BTC order, over the 124.83 BTC budget slice ──"
notice_count() { call getMyReleaseRejections '()' --query --identity "$1" | tr -d '\n' | grep -o 'mid-match' | wc -l | tr -d ' '; }
build_fixture 140
USD0=$(bal_of "$USER" ICPUSD)
N2_0=$(notice_count csb_maker2)
SW=$(call swap "(record {
  fromToken = \"ICP\";
  toToken   = \"BTC\";
  amount    = $(e8 100) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.25) : nat } };
  noPartialFill = true
})" --identity csb_user)
assert_contains "§3 FOK cross-swap staged" "$SW" "swapOrderId = opt"
release_all
wait_for "call getMyRecentSwap '()' --identity csb_user | grep -q 'filled ='" 20 1
OUTCOME=$(call getMyRecentSwap '()' --identity csb_user)
BTC_GOT=$(from_e8 "$(bal_of "$USER" BTC)")
N2_1=$(notice_count csb_maker2)
echo "   §3: outcome=$(echo "$OUTCOME" | tr -d '\n' | tr -s ' ' | head -c 240)"
echo "   §3: received ${BTC_GOT} BTC; maker2 mid-match notices before=$N2_0 after=$N2_1"
# The gate passed (it credits maker2's 124.83 slice) — so the swap MUST have
# converted the whole 100 ICP and the engine MUST have taken that same slice:
# 50 @ \$5 + 124.83 @ \$6 ≈ 174.83 BTC, maker2 NOT cancelled, its ask still
# resting with ≈ 25.17 BTC. Pre-fix: 50 BTC, maker2 cancelled with one notice.
assert_contains "§3 outcome recorded as filled (the gate passed)" "$OUTCOME" "filled = true"
FROM_GOT=$(extract_nat "fromAmount" "$OUTCOME")
assert_eq "§3 sell leg fully converted (fromAmount = 100 ICP)" "$(e8 100)" "${FROM_GOT:-0}"
assert_gt "§3 buy leg took maker2's budget-shrunk slice (> 170 BTC received; pre-fix 50)" "$BTC_GOT" "170"
assert_lt "§3 buy leg never exceeded the budget (< 175 BTC)" "$BTC_GOT" "175"
assert_eq "§3 maker2 was NOT cancelled mid-match (no new notice)" "$N2_0" "$N2_1"
BOOK=$(call getOrderBook "(\"$BUYM\")" --query | tr -d '_')
assert_contains "§3 maker2's \$6 ask still rests (its unfilled 25.17 BTC)" "$BOOK" "600000000"
assert_budget "§3 partially funded maker" "$USD0"

# ── §3b the other agreement: maker2 under the shrunk slice → gate kills, nothing settles ──
echo ""
echo "── §3b FOK cross-swap: the \$6 ask's maker holds 120 BTC — under the 124.83 BTC budget slice ──"
build_fixture 120
USD0=$(bal_of "$USER" ICPUSD)
N2_0=$(notice_count csb_maker2)
SW=$(call swap "(record {
  fromToken = \"ICP\";
  toToken   = \"BTC\";
  amount    = $(e8 100) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.25) : nat } };
  noPartialFill = true
})" --identity csb_user)
assert_contains "§3b FOK cross-swap staged" "$SW" "swapOrderId = opt"
release_all
wait_for "call getMyRecentSwap '()' --identity csb_user | grep -q 'filled ='" 20 1
OUTCOME=$(call getMyRecentSwap '()' --identity csb_user)
N2_1=$(notice_count csb_maker2)
echo "   §3b: outcome=$(echo "$OUTCOME" | tr -d '\n' | tr -s ' ' | head -c 240)"
assert_contains "§3b FOK killed at the gate (filled = false)" "$OUTCOME" "filled = false"
assert_contains "§3b kill names the buy leg's absorbable depth" "$OUTCOME" "absorbs only"
assert_eq "§3b nothing settled: user still holds 100 ICP" "$(e8 100)" "$(bal_of "$USER" ICP)"
assert_eq "§3b nothing settled: user received no BTC" "0" "$(bal_of "$USER" BTC)"
assert_eq "§3b unrelated ICPUSD untouched" "$USD0" "$(bal_of "$USER" ICPUSD)"
assert_eq "§3b maker2 untouched by the engine (no notice — the gate refused before any fill)" "$N2_0" "$N2_1"

call setTestTimersPaused '(false)' > /dev/null

finish_test "test_cross_swap_budget"
