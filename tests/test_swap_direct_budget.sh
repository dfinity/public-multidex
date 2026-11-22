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
# §2 (#55 flat-rate sizing, task 1788465038): the same swap by an L3 caller on
# a FLAT book must deliver its quoteSwap preview to the base unit — the qty
# is sized at the caller's LADDER rate (quoteFeeFor), not the flat L0 rate.
#
# §3 (#55 silent "complete", task 1788465056): a caller whose ICPUSD is partly
# RESERVED by an open bid is previewed/accepted for the full amount, but the
# staged budget is min(amount, available). The staging reply must carry that
# effective budget (stagedBudget), and when the release stops at it the
# caller must be TOLD (getMyRecentSwap non-null, stopReason = budgetExhausted,
# converted X of Y) instead of the old silent "complete" — while a full-budget
# swap (§1/§2) still records NOTHING spurious.
# §3 rider (the PREVIEW half, task 1788478363): quoteSwap's reply carries
# availableFrom (spendable `from` balance) + clampedByReserve, so the UI can
# say "only $399.40 of this is available" while typing; the walk itself stays
# a full-amount market estimate and §1's unreserved caller reads unchanged.
#
# NOTE: resets + rebuilds the venue (resetExchange). Reseed after, like
# test_swap_outcome / test_state_reset. Needs #dev (setTestScorecard too).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_swap_direct_budget ──"

if [ "$(venue_posture)" != "dev" ]; then
  skip_posture "test_swap_direct_budget" "resetExchange/setTestBalance/setAmmRefPrice dev hooks"
fi

MKT="ICP-ICPUSD"

mdx_identity_new sdb_maker
mdx_identity_new sdb_user
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
# #55 preview half (task 1788478363): an UNRESERVED caller's reply names the
# whole spendable balance and is not clamped — the estimate is unchanged.
Q_AVAIL=$(extract_nat "availableFrom" "$Q")
assert_eq       "§1 quoteSwap availableFrom = the caller's whole \$5000 (nothing reserved)" "500000000000" "${Q_AVAIL:-MISSING}"
assert_contains "§1 quoteSwap clampedByReserve = false for the unreserved caller"           "$Q" "clampedByReserve = false"

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
# Silent-complete rider (task 1788465056): a swap whose WHOLE budget converted
# has nothing to report — the outcome record stays null (nothing spurious).
OUT1=$(call getMyRecentSwap '()' --identity sdb_user --query)
assert_contains "§1 full-budget swap records no outcome (nothing spurious)" "$OUT1" "null"

# ── §2 Ladder-rate sizing (#55 flat-rate sizing, task 1788465038) ─────────
# The qty was sized with the FLAT L0 taker rate (TAKER_FEE_BPS, 10 bps) carved
# out while quoteSwap previews — and the release charges — the caller's
# EARNED ladder rate (quoteFeeFor; L3 = 7 bps). On a FLAT book the qty cap,
# not the budget, binds: an L3 caller was previewed amount/(1.0007·p) and
# received amount/(1.001·p) — 0.03% short, with amount×(10−7)bps/1.001 left
# unconverted, no rejection record. §1 cannot see this: its walking book
# makes the BUDGET bind first, which is rate-agnostic. So: a fresh maker
# posts ONE deep level at $5.00 (300 ICP; §1's ~150 ICP @ $5.08 leftover sits
# behind it and is never reached), the taker is ticked to L3 through the
# scorecard #dev hook (W = 2×$50k maker vol ≥ the 1%-scaled $20k L3 bar; L4
# also needs uptime samples, so volume alone stops at L3), and the SAME
# $1000 swap must deliver its preview to the base unit with no residue beyond
# one base unit's worth of quote (price/SCALE, plus the fee-floor crumb).
#   pre-fix : qty = (1000/1.001)/5 = 199.80 ICP → debit ≈ $999.70, $0.30
#             unconverted, preview 199.86                                  ✗
#   post-fix: qty = (1000/1.0007)/5 = 199.86 ICP → debit ≈ $1000.00       ✓
mdx_identity_new sdb_maker3
mdx_identity_new sdb_user3
MAKER3=$(principal_of sdb_maker3)
USER3=$(principal_of sdb_user3)

call setTestBalance "(principal \"$MAKER3\", \"ICP\", $(e8 300) : nat)" > /dev/null
call placeLimitOrder "(\"$MKT\", variant { sell }, $(e8 5) : nat, $(e8 300) : nat)" --identity sdb_maker3 > /dev/null
release_market
wait_for "call getOrderBook '(\"$MKT\")' --query | tr -d '_' | grep -q 'price = 500000000'" 15 1
BOOK3=$(call getOrderBook "(\"$MKT\")" --query | tr -d '_')
assert_contains "§2 book: best ask back at \$5.00 (flat 300 ICP level)" "$BOOK3" "500000000"

# Tier tick: L3 earned through the scorecard hook (controller-only, #dev).
call setTestBalance "(principal \"$USER3\", \"ICPUSD\", $(e8 5000) : nat)" > /dev/null
call setTestBalance "(principal \"$USER3\", \"ICP\", 0 : nat)" > /dev/null
call setTestScorecard "(principal \"$USER3\", $(e8 50000) : nat, 0 : nat, 0 : nat, 0 : nat)" > /dev/null
POL3=$(call getAccessPolicy '()' --identity sdb_user3 --query)
assert_contains "§2 taker earned L3"              "$POL3" "myLevel = 3"
assert_contains "§2 L3 taker rate is 7.0 bps"     "$POL3" "myTakerFeeTenthBps = 70"

Q3=$(call quoteSwap "(\"ICPUSD\", \"ICP\", $(e8 1000) : nat, $(e8 0.25) : nat)" --identity sdb_user3 --query)
Q3_OUT=$(extract_nat "outAmount" "$Q3")
# The preview itself is at the ladder rate: strictly MORE than the L0-sized
# quantity (1000/1.001/5 = 199.80 ICP) — the gap the caller was short by.
assert_gt "§2 L3 preview exceeds the L0-sized qty (199.80 ICP)" "$(from_e8 "${Q3_OUT:-0}")" "199.85"

USD0_3=$(bal_of "$USER3" ICPUSD)
SW3=$(call swap "(record {
  fromToken = \"ICPUSD\";
  toToken   = \"ICP\";
  amount    = $(e8 1000) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.25) : nat } };
  noPartialFill = false
})" --identity sdb_user3)
assert_contains "§2 L3 swap accepted + staged" "$SW3" "swapOrderId = opt"

release_market
wait_for "[ \"\$(bal_of \"$USER3\" ICP)\" -gt 0 ]" 20 1

ICP3_RAW=$(bal_of "$USER3" ICP)
USD1_3=$(bal_of "$USER3" ICPUSD)
DEBIT3_RAW=$(( USD0_3 - USD1_3 ))
RESIDUE3=$(( 100000000000 - DEBIT3_RAW ))     # amount − debit, e8 units
echo "   §2 L3: received $(from_e8 "$ICP3_RAW") ICP (preview $(from_e8 "${Q3_OUT:-0}")), debited \$$(from_e8 "$DEBIT3_RAW"), residue ${RESIDUE3} e8-units"

assert_lt "§2 debit ≤ amount (budget honoured)" "$DEBIT3_RAW" "100000000001"
# THE assertions (red pre-fix): received == preview to the base unit, and
# the unconverted residue is at most one base unit's quote (price/SCALE = 5
# e8-units at $5.00) plus the fee-floor crumb — never the 0.03% ladder gap
# (≈ 30,000,000 e8-units here).
assert_abs_close "§2 received == L3 preview (to the base unit)" "${Q3_OUT:-0}" "$ICP3_RAW" 1
assert_lt "§2 residue ≤ price/SCALE + fee crumb (≤ 10 e8-units)" "$RESIDUE3" "11"
# Fill stayed on the flat level: no walk into the $5.08 leftover.
assert_lt "§2 fill stayed within the \$5.00 level (< 300 ICP)" "$(from_e8 "$ICP3_RAW")" "300"
REJ3=$(call getMyReleaseRejections '()' --identity sdb_user3 --query)
assert_not_contains "§2 no 'remainder dropped' note on the L3 conversion" "$REJ3" "remainder dropped"
OUT3=$(call getMyRecentSwap '()' --identity sdb_user3 --query)
assert_contains "§2 full-budget L3 swap records no outcome (nothing spurious)" "$OUT3" "null"

# L0 control unchanged: §1 above already asserted the flat-rate caller's
# executed ≤ quoted + 1 and debit ≈ amount on the walking book.

# ── §3 Silent "complete" (#55, task 1788465056) ──────────────────────────
# A caller holding $1,000 ICPUSD with a resting bid reserving $600.60
# (150 ICP @ $4.00 + the L0 worst-case fee) asks to swap the full $1,000.
# swap() pre-checks the RAW balance and accepts; parkDeferred clamps the
# budget to AVAILABLE — $399.40 — and the release converts exactly that.
# Pre-fix the caller learned NOTHING: the staging reply said fromAmount 0
# with no budget, the release judged the $399.40 budget "spent" and recorded
# neither a SwapOutcome nor a rejection. Post-fix:
#   - the staging reply carries stagedBudget = $399.40 (the toast can say
#     "$399.40 of $1,000 will convert; $600.60 is reserved");
#   - the release records a SwapOutcome for the direct path with the ENGINE's
#     stop reason (#budgetExhausted), fromAmount = the spend, toAmount = the
#     ICP received, and a note naming the reserved shortfall;
#   - still no "remainder dropped" rejection (the budget DID complete).
# The book: a fresh 300 ICP @ $5.00 level (plus §1/§2 leftovers behind it) —
# deep enough that the walk stops on the BUDGET, not the book.
mdx_identity_new sdb_maker4
mdx_identity_new sdb_user4
MAKER4=$(principal_of sdb_maker4)
USER4=$(principal_of sdb_user4)

call setTestBalance "(principal \"$MAKER4\", \"ICP\", $(e8 300) : nat)" > /dev/null
call placeLimitOrder "(\"$MKT\", variant { sell }, $(e8 5) : nat, $(e8 300) : nat)" --identity sdb_maker4 > /dev/null
release_market
wait_for "call getOrderBook '(\"$MKT\")' --query | tr -d '_' | grep -q 'price = 500000000'" 15 1

call setTestBalance "(principal \"$USER4\", \"ICPUSD\", $(e8 1000) : nat)" > /dev/null
call setTestBalance "(principal \"$USER4\", \"ICP\", 0 : nat)" > /dev/null
# The reservation: a NON-crossing bid, 150 ICP @ $4.00 → $600 + $0.60 fee.
BID4=$(call placeLimitOrder "(\"$MKT\", variant { buy }, $(e8 4) : nat, $(e8 150) : nat)" --identity sdb_user4)
assert_ok "§3 reserving bid accepted" "$BID4"
AVAIL4=$(extract_first_nat "$(call getMyAvailableBalance '("ICPUSD")' --identity sdb_user4 --query)")
echo "   §3 available ICPUSD after the bid: $(from_e8 "${AVAIL4:-0}") (raw balance \$1000)"
assert_abs_close "§3 available = \$399.40 (\$600.60 reserved)" "39940000000" "${AVAIL4:-0}" 1000000

# THE preview assertions (#55 preview half, task 1788478363 — red pre-fix: the
# reply carried neither field): quoteSwap for the FULL $1,000 still estimates
# the full amount (a market estimate — outAmount ≈ 200 ICP at $5, the walk is
# untouched) but says beside it that only $399.40 is available and that a
# reservation is what clamps it. The UI renders this while the user types;
# pre-fix the shortfall surfaced first in the staging toast.
Q4=$(call quoteSwap "(\"ICPUSD\", \"ICP\", $(e8 1000) : nat, $(e8 0.25) : nat)" --identity sdb_user4 --query)
Q4_OUT=$(extract_nat "outAmount" "$Q4")
Q4_AVAIL=$(extract_nat "availableFrom" "$Q4")
echo "   §3 preview: outAmount $(from_e8 "${Q4_OUT:-0}") ICP, availableFrom $(from_e8 "${Q4_AVAIL:-0}")"
assert_gt        "§3 quoteSwap still estimates the FULL \$1000 (≈ 199 ICP; the walk is unclamped)" "$(from_e8 "${Q4_OUT:-0}")" "190"
assert_abs_close "§3 quoteSwap availableFrom = \$399.40 (the getMyAvailableBalance figure)" "${AVAIL4:-0}" "${Q4_AVAIL:-0}" 1
assert_contains  "§3 quoteSwap clampedByReserve = true (a reservation clamps this amount)" "$Q4" "clampedByReserve = true"
assert_contains  "§3 quoteSwap exhausted keeps its meaning (book not thin: false)"          "$Q4" "exhausted = false"

USD0_4=$(bal_of "$USER4" ICPUSD)
SW4=$(call swap "(record {
  fromToken = \"ICPUSD\";
  toToken   = \"ICP\";
  amount    = $(e8 1000) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.25) : nat } };
  noPartialFill = false
})" --identity sdb_user4)
assert_contains "§3 swap for the FULL \$1000 accepted + staged (raw-balance pre-check)" "$SW4" "swapOrderId = opt"
SWID4=$(echo "$SW4" | tr -d '_' | grep -oE "swapOrderId = opt \(?[0-9]+" | grep -oE "[0-9]+$")
# THE staging assertion (red pre-fix: the reply carried no budget at all):
# stagedBudget = the effective (available-clamped) budget, not the amount.
EFF4=$(echo "$SW4" | tr -d '_' | grep -oE "stagedBudget = opt \(?[0-9]+" | grep -oE "[0-9]+$")
echo "   §3 staged: id ${SWID4:-?}, stagedBudget $(from_e8 "${EFF4:-0}")"
assert_abs_close "§3 staging reply carries eff = \$399.40 (stagedBudget)" "39940000000" "${EFF4:-0}" 1000000

release_market
wait_for "[ \"\$(bal_of \"$USER4\" ICP)\" -gt 0 ]" 20 1

ICP4_RAW=$(bal_of "$USER4" ICP)
USD1_4=$(bal_of "$USER4" ICPUSD)
DEBIT4_RAW=$(( USD0_4 - USD1_4 ))
echo "   §3 released: received $(from_e8 "$ICP4_RAW") ICP, debited \$$(from_e8 "$DEBIT4_RAW") of the \$1000 asked"
assert_lt "§3 debit ≤ the effective budget (\$399.40)" "$DEBIT4_RAW" "39940000001"
assert_gt "§3 the effective budget converted (debit ≥ \$399.3)" "$DEBIT4_RAW" "39930000000"
assert_gt "§3 received ICP (≈79.8)" "$(from_e8 "$ICP4_RAW")" "79"

# THE outcome assertions (red pre-fix: getMyRecentSwap stayed null — the
# silent "complete"): the direct path now records the stop.
OUT4=$(call getMyRecentSwap '()' --identity sdb_user4 --query | tr -d '_')
assert_not_contains "§3 getMyRecentSwap is non-null (the swap said what happened)" "$OUT4" "(null)"
assert_contains "§3 outcome id = the staged swapOrderId"            "$OUT4" "id = ${SWID4:-NOID} :"
assert_contains "§3 outcome carries the engine's stop reason"       "$OUT4" "budgetExhausted"
assert_contains "§3 outcome filled = true (ICP was received)"       "$OUT4" "filled = true"
OUT4_FROM=$(extract_nat "fromAmount" "$OUT4")
OUT4_TO=$(extract_nat "toAmount" "$OUT4")
assert_eq  "§3 outcome fromAmount == the actual debit"              "$DEBIT4_RAW" "${OUT4_FROM:-0}"
assert_eq  "§3 outcome toAmount == the ICP received"                "$ICP4_RAW"   "${OUT4_TO:-0}"
assert_contains "§3 outcome note names the reserved shortfall"      "$OUT4" "reserved"
REJ4=$(call getMyReleaseRejections '()' --identity sdb_user4 --query)
assert_not_contains "§3 no 'remainder dropped' note (the budget completed)" "$REJ4" "remainder dropped"

# ── §4 Exactly-funded L3 FOK: the reservation trim sizes at the earned rate ─
# (#55 flat-rate sizing, the reservation side — task 1788475362.) §2 fixed
# the SIZING sites; parkDeferred's `(#buy, null)` branch (FOK carries no
# budget) still reserved qty×cap + fee at the L0 CEILING and, when that
# exceeded the caller's available ICPUSD, TRIMMED the parked qty to
# avail/(1+L0)/cap — the L0-sized figure §2 had just shed. An L3 caller
# funded with EXACTLY the swap amount is the sharpest case: the sizing site
# picks qty = amount/(1+7bps)/cap, the ceiling reservation wants
# amount×(1+10bps)/(1+7bps) > amount, and the trim hands back 0.03% less
# ICP than the caller was sized for — no rejection, no outcome. §2 never
# saw it (funded $5000 for a $1000 swap: full headroom, no trim).
# Fixture: the same flat $5.00 level (300 ICP of §2/§3 depth remains — the
# §2 walk took ~200, §3 ~80, §3's maker posted 300 more), a fresh L3 taker
# holding EXACTLY $1,000, a FOK swap at the 1% slippage floor (cap $5.05;
# FOK keeps cap-sizing, so its qty is amount/(1+eff)/cap — the figure the
# release must deliver in full, since a FOK is all-or-nothing).
#   pre-fix : parked = ⌊⌊1000/1.0010⌋/5.05⌋ = 197.82 ICP (trimmed at L0)  ✗
#   post-fix: parked = ⌊⌊1000/1.0007⌋/5.05⌋ = 197.88 ICP (= sized qty)   ✓
mdx_identity_new sdb_user5
USER5=$(principal_of sdb_user5)

BOOK5=$(call getOrderBook "(\"$MKT\")" --query | tr -d '_')
assert_contains "§4 book: the flat \$5.00 ask level is still resting" "$BOOK5" "500000000"

call setTestBalance "(principal \"$USER5\", \"ICPUSD\", $(e8 1000) : nat)" > /dev/null
call setTestBalance "(principal \"$USER5\", \"ICP\", 0 : nat)" > /dev/null
call setTestScorecard "(principal \"$USER5\", $(e8 50000) : nat, 0 : nat, 0 : nat, 0 : nat)" > /dev/null
POL5=$(call getAccessPolicy '()' --identity sdb_user5 --query)
assert_contains "§4 taker earned L3 (7.0 bps)" "$POL5" "myTakerFeeTenthBps = 70"
AVAIL5=$(extract_first_nat "$(call getMyAvailableBalance '("ICPUSD")' --identity sdb_user5 --query)")
assert_eq "§4 taker holds EXACTLY the \$1000 swap amount, nothing reserved" "100000000000" "${AVAIL5:-0}"

# The FOK-sized qty (executeSwapDirect's arithmetic, e8 units): cap =
# ceil(ref×1.01), qty = ⌊⌊amount×10⁴/(10⁴+eff)⌋×SCALE/cap⌋ — and the L0-trimmed
# figure the pre-fix reservation parked instead. Python: the products pass
# 2⁶³ (bash arithmetic would wrap).
SIZED5=$(python3 -c "s=100000000000*10000//10007; print(s*100000000//505000000)")
TRIM5=$(python3 -c "s=100000000000*10000//10010; print(s*100000000//505000000)")
echo "   §4 sized qty $(from_e8 "$SIZED5") ICP; the L0-trimmed figure would be $(from_e8 "$TRIM5") ICP"

USD0_5=$(bal_of "$USER5" ICPUSD)
SW5=$(call swap "(record {
  fromToken = \"ICPUSD\";
  toToken   = \"ICP\";
  amount    = $(e8 1000) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.01) : nat } };
  noPartialFill = true
})" --identity sdb_user5)
assert_contains "§4 exactly-funded L3 FOK accepted + staged" "$SW5" "swapOrderId = opt"
# The staged entry IS the parked qty: getMyOrders shows it (status #open,
# quantity = parkedQty) until the release — the trim is visible before any
# fill. THE assertion (red pre-fix: 197.82, the L0 figure).
STAGED5=$(call getMyOrders '()' --identity sdb_user5 --query | tr -d '_' | grep -oE "quantity = [0-9]+" | head -1 | grep -oE "[0-9]+$")
echo "   §4 staged qty $(from_e8 "${STAGED5:-0}") ICP"
assert_abs_close "§4 staged qty == the FOK-sized qty (reservation trim at the EARNED rate, to the base unit)" "$SIZED5" "${STAGED5:-0}" 1
assert_gt "§4 staged qty exceeds the L0-trimmed figure ($(from_e8 "$TRIM5") ICP)" "${STAGED5:-0}" "$TRIM5"

release_market
wait_for "[ \"\$(bal_of \"$USER5\" ICP)\" -gt 0 ]" 20 1

ICP5_RAW=$(bal_of "$USER5" ICP)
USD1_5=$(bal_of "$USER5" ICPUSD)
DEBIT5_RAW=$(( USD0_5 - USD1_5 ))
echo "   §4 released: received $(from_e8 "$ICP5_RAW") ICP, debited \$$(from_e8 "$DEBIT5_RAW") of the \$1000 held"
# The FOK delivered its sized qty in full at the flat $5.00 level, within the
# exact balance: received == sized qty to the base unit, debit ≤ the amount.
assert_abs_close "§4 received == the FOK-sized qty (to the base unit)" "$SIZED5" "$ICP5_RAW" 1
assert_lt "§4 debit ≤ amount (the exact balance covered cost + the 7 bps fee)" "$DEBIT5_RAW" "100000000001"
assert_gt "§4 debit ≈ qty × \$5.00 × 1.0007 (≥ \$989)" "$DEBIT5_RAW" "98900000000"
REJ5=$(call getMyReleaseRejections '()' --identity sdb_user5 --query)
assert_contains "§4 no rejection on the exactly-funded FOK (empty vec)" "$REJ5" "(vec {})"
# L0 control: §1's flat-rate caller (funded $5000, full headroom) is
# unchanged — the ceiling still reserves for callers who have it.

call setTestTimersPaused '(false)' > /dev/null

finish_test "test_swap_direct_budget"
