#!/bin/bash
# Unified vault LP accounting — anchor, cost-basis P&L, proportional withdraw.
#
# Under the fees-only model the FIRST deposit anchors valuePerLP at 1.0 (no
# genesis bonus) and seeds the cost basis. The vault reports gain/loss vs the
# total VALUE deposited (costBasis), not vs a fixed 1.0 anchor. A withdrawal
# pays the pro-rata basket NET of the 40bp exit fee (drain fix 5a: makes the
# deposit→withdraw round trip strictly dearer than trading the spread); the
# withheld slice stays in the vault, so an exit is a small GAIN for those who
# remain, never a loss — and on the FINAL exit (no one remains) it is routed
# to the treasury so zero supply always means zero value (GHSA-h888). The
# first deposit into an empty vault must clear the $1000 floor
# (anti-inflation); alice (a canister controller) seeds it. Since task
# 1788465539 every share redeems at NAV (held + loan book − arrears) — the
# pro-rata basket above is that at zero utilisation — capped by the caller's
# pro-rata share of the HELD basket; §7 pins the NAV/liquidity model (F1-F6).

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
near() { awk -v a="$1" -v b="$2" -v t="${3:-0.01}" 'BEGIN{d=(a-b); d=(d<0?-d:0-(-d)); exit ((d<0?-d:d) <= t*(b<0?-b:b)+t ? 0 : 1)}'; }

# Integer-money: methods take/return Nat BASE UNITS (10^8). e8 converts
# human → base for call args; from_e8 base → human so the assertions stay in
# human scale (valuePerLP ≈ 1.0, costBasis ≈ 150000, …). gainLossPct is a
# SIGNED Int at 10^8, so extraction keeps the sign.
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

A=$(icp identity principal --identity alice 2>/dev/null | tail -1)   # alice = controller
adm()  { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
asA()  { icp canister call --candid "$MDX_CANDID" --identity alice backend "$@" 2>&1; }
vv()   { yes | adm getVaultValue "()" 2>&1; }
# base-unit field extractor: strip Candid underscores FIRST, keep any sign.
field(){ tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "\-?[0-9]+" | tail -1; }
# same, converted to human units for the human-scale assertions.
fieldh(){ local n; n=$(field "$1"); [ -z "$n" ] && n=0; from_e8 "$n"; }
# Wall-clock in ms (the HOST clock). pocket-ic's live-mode block time follows
# the host clock, so a host window opened before a call is dispatched and
# closed after a later read has returned BRACKETS the replica-side instants of
# both — the accrual bounds of task 1788736589 are measured this way where the
# replica publishes no timestamp for the read.
ms()   { perl -MTime::HiRes=time -e 'printf "%.0f", time*1000'; }
# The interest a debt of $1 base units books over $2 ns at APR $3 (at 10^8:
# 5000000 = 5 %), exactly as BorrowEngine.accrueLoan floors it —
# P × apr × elapsed / (10^8 × YEAR_NS) — in bc (the products pass 2^63).
interest_ns() { echo "${1:-0} * ${3:-0} * ${2:-0} / (100000000 * 31536000000000000)" | bc; }
interest_ms() { interest_ns "$1" "$(( ${2:-0} * 1000000 ))" "$3"; }   # same over a host window of $2 ms
APR_ICPUSD=5000000   # Types.borrowApr("ICPUSD"): 5 %

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
# Fund alice with 1 BTC + 100k cash for the genesis deposit.
for t in BTC ETH SOL ICP ICPUSD; do adm setTestBalance "(principal \"$A\", \"$t\", 0 : nat)" >/dev/null; done
adm setTestBalance "(principal \"$A\", \"BTC\",    $(e8 1.0) : nat)"      >/dev/null
adm setTestBalance "(principal \"$A\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null

echo "── 1. Genesis deposit (controller) anchors valuePerLP=1.0 + cost basis ──"
# 1 BTC ($50k) + $100k cash = $150k value into an empty vault → mint == value.
MINT=$(mdx_lp_deposit alice "BTC-ICPUSD" "$(e8 1.0)" "$(e8 100000.0)")
MINT_H=$(from_e8 "${MINT:-0}")
echo "   minted: $MINT_H LP for \$150k deposited"
if near "$MINT_H" 150000 0.001; then ok "first deposit minted == value (150000, no bonus)"; else nok "genesis mint" "$MINT_H"; fi
V=$(vv)
if near "$(echo "$V" | fieldh valuePerLP)" 1.0 0.001; then ok "valuePerLP anchored at 1.0"; else nok "valuePerLP" "$(echo "$V" | fieldh valuePerLP)"; fi
if near "$(echo "$V" | fieldh costBasis)" 150000 0.001; then ok "costBasis == deposited (150000)"; else nok "costBasis" "$(echo "$V" | fieldh costBasis)"; fi
if near "$(echo "$V" | fieldh gainLossPct)" 0.0 0.0001; then ok "gainLoss 0% at genesis"; else nok "gainLoss" "$(echo "$V" | fieldh gainLossPct)"; fi

echo ""
echo "── 2. Vault value rises 10% → reported gain tracks cost basis ──"
# BTC appreciates 50k→65k: vault 165k vs 150k basis → +10%.
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 65000.0) : nat)" >/dev/null
V=$(vv)
echo "   value=$(echo "$V" | fieldh totalQuoteValue) basis=$(echo "$V" | fieldh costBasis) gainLoss=$(echo "$V" | fieldh gainLossPct)"
if near "$(echo "$V" | fieldh gainLossPct)" 0.10 0.005; then ok "gainLoss reports +10% vs deposited cost basis"; else nok "gainLoss not +10%" "$(echo "$V" | fieldh gainLossPct)"; fi
if near "$(echo "$V" | fieldh valuePerLP)" 1.10 0.005; then ok "valuePerLP rose to 1.10"; else nok "valuePerLP" "$(echo "$V" | fieldh valuePerLP)"; fi

echo ""
echo "── 3. Withdraw half → pro-rata basket NET of 40bp exit fee; basis scales ──"
SUPPLY=$(echo "$V" | field lpSupply)   # base-unit Nat; halve as an integer
HALF=$(awk -v s="$SUPPLY" 'BEGIN{printf "%.0f", s/2}')
WD=$(mdx_lp_withdraw alice "${HALF}")
WD_BTC=$(echo "$WD" | fieldh btc)
WD_USD=$(echo "$WD" | fieldh icpusd)
echo "   withdrew $(from_e8 "$HALF") LP → btc=$WD_BTC icpusd=$WD_USD"
# Gross half-share = 0.5 BTC + 50,000 ICPUSD; net of the 40bp exit fee =
# 0.498 / 49,800. A payout at the old gross values means the fee regressed
# (and the free at-mid basket swap is back).
if near "$WD_BTC" 0.498 0.002; then ok "withdrew 0.498 BTC (half share − 40bp exit fee)"; else nok "withdraw BTC not net-of-fee" "$WD_BTC"; fi
if near "$WD_USD" 49800 0.002; then ok "withdrew 49,800 ICPUSD (net of exit fee)"; else nok "withdraw USD not net-of-fee" "$WD_USD"; fi
V=$(vv)
if near "$(echo "$V" | fieldh costBasis)" 75000 0.01; then ok "costBasis scaled to 75000 (half)"; else nok "costBasis after withdraw" "$(echo "$V" | fieldh costBasis)"; fi
# The withheld fee slice stays in the vault: remaining LPs' gain RISES from
# +10.0% to ≈ +10.44% (82,830 value on a 75,000 basis). An exit must never
# cost those who remain.
if near "$(echo "$V" | fieldh gainLossPct)" 0.1044 0.003; then ok "gainLoss rose to ≈+10.44% (exit fee accrues to remaining LPs)"; else nok "gainLoss after exit" "$(echo "$V" | fieldh gainLossPct)"; fi

echo ""
echo "── 4. Final exit → supply zero; fee residue routed to the treasury ──"
# GHSA-h888: the 40bp slice of a NON-final exit accrues to the remaining LPs
# (§3). On the FINAL exit there are none — pre-fix the slice stayed in the
# vault at zero supply and the next genesis deposit minted 1:1 against it,
# capturing it for free (mintAmount's zero-supply branch never reads vault
# value). The fix routes the final exit's residue to the treasury, so
# supply→0 implies value→0. The exiter still pays the 40bp fee (net basket
# unchanged); only the residue's DESTINATION moved.
# NB the field name prints QUOTED ("principal" is a Candid keyword).
TRS=$(adm getTreasury '()' | grep -oE '"principal" = "[^"]+"' | head -1 | sed -E 's/.*= "(.+)"/\1/')
tbal() { local n; n=$(adm getTestBalance "(principal \"$TRS\", \"$1\")" | tr -d '_' | grep -oE '[0-9]+' | head -1); echo "${n:-0}"; }
T_BTC0=$(tbal BTC); T_USD0=$(tbal ICPUSD)
REM=$(asA getMyVaultLp "()" | tr -d '_' | grep -oE "[0-9]+" | head -1)
mdx_lp_withdraw alice "${REM}" >/dev/null
V=$(vv); LPLEFT=$(asA getMyVaultLp "()" | tr -d '_' | grep -oE "[0-9]+" | head -1)
if near "$(echo "$V" | fieldh lpSupply)" 0.0 0.01 && near "$(from_e8 "${LPLEFT:-0}")" 0.0 0.01; then ok "vault + user LP both zero after full withdraw"; else nok "not zeroed" "supply=$(echo "$V" | fieldh lpSupply) user=${LPLEFT:-0}"; fi
if near "$(echo "$V" | fieldh costBasis)" 0.0 0.01; then ok "costBasis returns to zero"; else nok "costBasis not zero" "$(echo "$V" | fieldh costBasis)"; fi
TQV=$(echo "$V" | fieldh totalQuoteValue)
if near "$TQV" 0.0 0.01; then ok "vault value 0 at zero supply (no unowned residue)"; else nok "residue left in vault at supply 0 (GHSA-h888)" "\$$TQV"; fi
# The residue (≈ $331: 40bp of the ~$82.8k final basket) must land in the
# treasury: Δ = 0.002008 BTC ($130.52 at 65k) + 200.80 ICPUSD.
T_BTC1=$(tbal BTC); T_USD1=$(tbal ICPUSD)
RES_USD=$(awk -v b0="$T_BTC0" -v b1="$T_BTC1" -v u0="$T_USD0" -v u1="$T_USD1" 'BEGIN{ printf "%.2f", ((b1-b0)*65000 + (u1-u0))/100000000 }')
if near "$RES_USD" 331 0.15; then ok "exit-fee residue routed to treasury (~\$331, got \$$RES_USD)"; else nok "residue not in treasury" "\$$RES_USD"; fi

echo ""
echo "── 4b. First post-zero deposit captures nothing (GHSA-h888) ──"
# A virgin principal deposits into the post-final-exit vault. Pre-fix it was
# minted 1:1 against a vault still holding the $331 residue and owned 100% of
# supply — instant free capture (and the residue basket's weights taxed the
# mint via the over-weight fee curve besides). Post-fix the vault is truly
# empty, so genesis is honest: minted == value, valuePerLP == 1.0, and the
# vault is worth exactly what was deposited. Deposit is shaped like the old
# residue basket (BTC + cash) so the PRE-fix run demonstrates capture rather
# than a concentration-cap refusal; it clears the $1000 first-deposit floor.
CAROL_ID=vlp_carol; mdx_identity_new $CAROL_ID
CAROL_P=$(icp identity principal --identity $CAROL_ID 2>/dev/null | tail -1)
asC() { icp canister call --candid "$MDX_CANDID" --identity $CAROL_ID backend "$@" 2>&1; }
adm setTestBalance "(principal \"$CAROL_P\", \"BTC\",    $(e8 0.01) : nat)"   >/dev/null
adm setTestBalance "(principal \"$CAROL_P\", \"ICPUSD\", $(e8 1350.0) : nat)" >/dev/null
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 65000.0) : nat)" >/dev/null   # fresh stamp for the mint gate
CMINT=$(mdx_lp_deposit $CAROL_ID "BTC-ICPUSD" "$(e8 0.01)" "$(e8 1350.0)")
CMINT_H=$(from_e8 "${CMINT:-0}")
# 0.01 BTC ($650 at 65k) + $1350 = $2000; an empty vault charges no
# over-weight fee, so the mint is exactly 1:1.
if near "$CMINT_H" 2000 0.001; then ok "post-zero genesis minted == value (2000, no fee, 1:1)"; else nok "post-zero mint" "$CMINT_H"; fi
V=$(vv)
if near "$(echo "$V" | fieldh totalQuoteValue)" 2000 0.001; then ok "vault worth exactly the deposit (nothing captured)"; else nok "depositor captured residue (GHSA-h888)" "\$$(echo "$V" | fieldh totalQuoteValue)"; fi
if near "$(echo "$V" | fieldh valuePerLP)" 1.0 0.001; then ok "valuePerLP re-anchored at 1.0 (owns only what was funded)"; else nok "valuePerLP" "$(echo "$V" | fieldh valuePerLP)"; fi
mdx_lp_withdraw $CAROL_ID "${CMINT:-0}" >/dev/null 2>&1   # leave the vault empty for §5

echo ""
echo "── 4c. Value re-entering at supply 0 is swept at deposit time (GHSA-h888 residual) ──"
# The final-exit sweep (§4) empties the vault WHEN the last LP leaves — but
# value can re-enter the AMM principal AFTERWARDS: loan-book repayments land in
# its balances (withdrawLp pays exits from holdings and leaves receivables
# behind), and a pending match that fails un-reserves a leg the exit sweep left
# in place. Pre-fix that value sat ownerless until the next genesis deposit
# captured it 1:1 (mintAmount's zero-supply branch never reads vault value).
# The fix mirrors the sweep at DEPOSIT time: performLpDeposit at supply 0
# routes un-reserved AMM balances to the treasury before snapshotting the
# vault, so genesis always anchors on a truly empty vault. Model the re-entry
# with setTestBalance (a loan repayment in miniature): 0.005 BTC + $500 cash
# = $825 at 65k lands in the AMM at supply 0.
AMM4C=$(adm getAmmPrincipal '()' | grep -oE 'principal "[^"]+"' | head -1 | sed -E 's/principal "(.+)"/\1/')
adm setTestBalance "(principal \"$AMM4C\", \"BTC\",    $(e8 0.005) : nat)" >/dev/null
adm setTestBalance "(principal \"$AMM4C\", \"ICPUSD\", $(e8 500.0) : nat)" >/dev/null
V=$(vv)
if near "$(echo "$V" | fieldh lpSupply)" 0.0 0.01 && near "$(echo "$V" | fieldh totalQuoteValue)" 825 0.01; then
  ok "re-entry staged: \$825 sits in the vault at supply 0 (capture precondition live)"
else nok "re-entry staging failed" "supply=$(echo "$V" | fieldh lpSupply) value=\$$(echo "$V" | fieldh totalQuoteValue)"; fi
T_BTC2=$(tbal BTC); T_USD2=$(tbal ICPUSD)
# carol (again a stranger to the vault) makes the next genesis deposit.
adm setTestBalance "(principal \"$CAROL_P\", \"BTC\",    $(e8 0.01) : nat)"   >/dev/null
adm setTestBalance "(principal \"$CAROL_P\", \"ICPUSD\", $(e8 1350.0) : nat)" >/dev/null
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 65000.0) : nat)" >/dev/null   # fresh stamp for the mint gate
CMINT=$(mdx_lp_deposit $CAROL_ID "BTC-ICPUSD" "$(e8 0.01)" "$(e8 1350.0)")
CMINT_H=$(from_e8 "${CMINT:-0}")
if near "$CMINT_H" 2000 0.001; then ok "genesis after re-entry minted == value (2000, 1:1)"; else nok "post-re-entry mint" "$CMINT_H"; fi
V=$(vv)
# Pre-fix the vault reads $2825 here and carol owns all of it — $825 captured.
if near "$(echo "$V" | fieldh totalQuoteValue)" 2000 0.001; then ok "vault worth exactly the deposit (re-entered \$825 not captured)"; else nok "depositor captured re-entered value (GHSA-h888 residual)" "\$$(echo "$V" | fieldh totalQuoteValue)"; fi
if near "$(echo "$V" | fieldh valuePerLP)" 1.0 0.001; then ok "valuePerLP anchored at 1.0"; else nok "valuePerLP" "$(echo "$V" | fieldh valuePerLP)"; fi
# The re-entered value must be IN THE TREASURY, not vanished: Δ = 0.005 BTC + $500.
T_BTC3=$(tbal BTC); T_USD3=$(tbal ICPUSD)
RES4C=$(awk -v b2="$T_BTC2" -v b3="$T_BTC3" -v u2="$T_USD2" -v u3="$T_USD3" 'BEGIN{ printf "%.2f", ((b3-b2)*65000 + (u3-u2))/100000000 }')
if near "$RES4C" 825 0.01; then ok "re-entered value routed to treasury (\$825, got \$$RES4C)"; else nok "re-entered value not in treasury" "\$$RES4C"; fi
mdx_lp_withdraw $CAROL_ID "${CMINT:-0}" >/dev/null 2>&1   # leave the vault empty for §5

echo ""
echo "── 5. Round trip while insurance arrears are outstanding nets ≤ 0 ──"
# GHSA-3j44 / #48.3 / #50.1-root. currentVaultValue haircuts NAV by
# insuranceOwedUsd (arrears the vault owes the fund), so depositLp MINTS against
# a reduced figure — more LP per dollar. Before this fix, withdrawLp paid GROSS
# holdings (the arrears deduction was confined to the CASH leg, which is ≈ 0 in
# the reachable persistent-arrears state — settleInsuranceArrears pays
# min(W, cash) so W > 0 ⟹ cash ≈ 0 — and was double-prorated by the exiter's
# fraction f besides). A deposit→immediate-withdraw round trip then came out
# net-POSITIVE, funded by the LPs who stayed. The fix spreads the FULL arrears W
# across the whole HELD basket, so mint (NAV) and redeem (holdings) agree on the
# arrears axis and the round trip is ≤ 0 by construction (payout ≤ f·NAV) — here
# it costs exactly the 40bp exit fee, regardless of W. Tested at φ = f < 1 (a
# sole LP makes shipped and intended coincide by arithmetic).
LIQ_ID=vlp_liq; mdx_identity_new $LIQ_ID
BOB_ID=vlp_bob; mdx_identity_new $BOB_ID
LIQ_P=$(icp identity principal --identity $LIQ_ID 2>/dev/null | tail -1)
BOB_P=$(icp identity principal --identity $BOB_ID 2>/dev/null | tail -1)
asL()   { icp canister call --candid "$MDX_CANDID" --identity $LIQ_ID  backend "$@" 2>&1; }
asBob() { icp canister call --candid "$MDX_CANDID" --identity $BOB_ID backend "$@" 2>&1; }
pyf()   { adm getInsuranceFund '()' | tr -d '_' | grep -oE 'pendingYieldUsd = [0-9]+' | grep -oE '[0-9]+'; }
# Drain the banked arrears (the §5/§6 hygiene step). The arrears heartbeat
# (settleInsuranceArrears, interval 0) pays min(W, vault cash) per BEAT, and a
# beat is a timer firing, not an update call — so a fixed count of
# setAmmRefPrice ticks measured the machine, not the drain (task 1788744110:
# 136/1 at load avg 25, 138/0 at load avg 10, same build). Poll the drain
# instead, bounded: one re-stamp per one-second round (an update lands every
# second for the beat to ride), up to 30 rounds. The caller asserts pyf == 0;
# DRAIN_SECS and DRAIN_LOAD feed its nok text so a load red names the load.
drain_arrears() {
  local t0; t0=$(date +%s)
  wait_for 'adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null; [ "$(pyf)" = "0" ]' 30 1 || true
  DRAIN_SECS=$(( $(date +%s) - t0 )); DRAIN_LOAD=$(uptime | sed 's/.*load averages*: *//')
}
# bob's whole wallet, valued in USD base units at 50k/BTC (he only ever holds BTC + cash)
bobUsd() {
  local b u
  b=$(adm getTestBalance "(principal \"$BOB_P\", \"BTC\")"    | tr -d '_' | grep -oE '[0-9]+' | head -1)
  u=$(adm getTestBalance "(principal \"$BOB_P\", \"ICPUSD\")" | tr -d '_' | grep -oE '[0-9]+' | head -1)
  awk -v b="${b:-0}" -v u="${u:-0}" 'BEGIN{ printf "%.0f", b*50000 + u }'
}

# ONE reset, FIRST — everything below is built on, and read from, the
# post-wipe world. performWorldWipe zeroes insuranceOwedUsd and clears the
# staker shares (#49.4), so arrears banked BEFORE a reset are gone by the time
# the round trip runs: issue #54 §54.3 caught this fixture doing exactly that
# (its W > 0 read predated the reset, the round trip ran at W = 0 where the
# fixed and unfixed withdrawLp agree, and the pin could no longer fail). So the
# vault, the staker shares, the arrears and the cash drain are all established
# AFTER this line, and W is read AFTER this line and BEFORE withdrawLp.
adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange '()' >/dev/null 2>&1
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat)" >/dev/null 2>&1
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1
adm setAutoFuel '(false)' >/dev/null 2>&1   # else Stage-1 auto-fuel buys trader ICP into treasury and fakes a leak
AMM=$(adm getAmmPrincipal '()' | grep -oE 'principal "[^"]+"' | head -1 | sed -E 's/principal "(.+)"/\1/')
for t in BTC ETH SOL ICP ICPUSD; do
  for p in "$A" "$BOB_P" "$AMM" "$LIQ_P"; do adm setTestBalance "(principal \"$p\", \"$t\", 0 : nat)" >/dev/null; done
done
# Vault = 4 BTC + \$40k cash genesis (alice stays, so the exiter's φ < 1).
adm setTestBalance "(principal \"$A\",     \"BTC\",    $(e8 4.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$A\",     \"ICPUSD\", $(e8 40000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$BOB_P\", \"ICPUSD\", $(e8 40000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$LIQ_P\", \"ICPUSD\", $(e8 2000000.0) : nat)" >/dev/null
mdx_lp_deposit alice "BTC-ICPUSD" "$(e8 4.0)" "$(e8 40000.0)" >/dev/null
adm seedInsuranceFund "($(e8 3000.0) : nat)" >/dev/null   # mints shares (caller = staker) AFTER the wipe, so penalties can accrue

# Drive persistent arrears via the liquidation-penalty path (#48.2: both arms
# accrue) WITH alice's vault live. Each pass: fund a leveraged long, DRAIN the
# vault cash so the accrued penalty cannot settle (models cash ≈ 0), crash into
# insolvency, liquidate. Four passes bank ≈ $5.1k of arrears. The pool's loan
# is written off at liquidation, so the loan book is back to 0 afterwards
# (getMaxInstantWithdraw.vaultLentOutUsd = 0) and the instant-liquidity cap
# cannot bind bob's exit. §6(b) reuses this helper against ITS live vault.
bank_arrears() {
  adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
  adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 2000000.0) : nat)" >/dev/null
  adm setTestBalance "(principal \"$AMM\", \"BTC\",    $(e8 20.0) : nat)"      >/dev/null
  local R PID
  R=$(asL createMarginPool '("vlp arrears", false)')
  PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | tail -1)
  asL fundMarginPool "($PID, $(e8 100000.0) : nat)" >/dev/null
  asL openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 5.0) : nat, $(e8 0.25) : nat, null)" >/dev/null
  adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null
  adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", 0 : nat)" >/dev/null      # cash ≈ 0: penalty can't settle
  adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 10000.0) : nat)" >/dev/null           # collateral < debt → insolvent
  adm adminRunLiquidationBatch '()' >/dev/null 2>&1
}
for _ in 1 2 3 4; do bank_arrears; done
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
# The passes parked inventory on the AMM principal; restore the intended held
# basket — 4 BTC, cash DRAINED to 0 — so the vault is BTC-heavy with cash ≈ 0,
# the reachable persistent-arrears state where a cash-leg-only deduction would
# vanish. Balances are set directly; W is untouched (nothing settles it: the
# timers are paused and there is no cash to pay it from).
for t in BTC ETH SOL ICP ICPUSD; do adm setTestBalance "(principal \"$AMM\", \"$t\", 0 : nat)" >/dev/null; done
adm setTestBalance "(principal \"$AMM\", \"BTC\", $(e8 4.0) : nat)" >/dev/null
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null            # fresh stamp for the mint gate

# THE W > 0 READ — after the last reset, immediately before bob's deposit, and
# the figure the round-trip lines print. The round trip below is a pin only
# while this is non-zero: at W = 0 the fixed and unfixed withdrawLp coincide.
W5=$(pyf); W5_H=$(from_e8 "${W5:-0}")
if [ -n "${W5:-}" ] && awk -v w="${W5:-0}" 'BEGIN{exit (w>0?0:1)}'; then
  ok "liquidation-penalty path drove insuranceOwedUsd > 0 after the last reset (\$${W5_H} arrears live at withdraw time)"
else nok "arrears not live at withdraw time (pendingYieldUsd) — the round trip below cannot discriminate" "W=${W5:-0}"; fi

# bob (the exiter) deposits the under-weight cash leg and immediately withdraws
# ALL of it. A redeem that ignores the arrears the mint counted (gross
# holdings — the GHSA-3j44 shape) pays bob his instant cap, ≈ +\$705 here;
# the fix makes the trip cost exactly the exit fee.
BOB_BEFORE=$(bobUsd)
BOB_MINT=$(mdx_lp_deposit $BOB_ID "BTC-ICPUSD" "0" "$(e8 40000.0)")
if [ -z "${BOB_MINT:-}" ] || ! [ "${BOB_MINT:-0}" -gt 0 ] 2>/dev/null; then nok "bob's LP deposit minted nothing" "$BOB_MINT"; BOB_MINT=0; fi
mdx_lp_withdraw $BOB_ID "${BOB_MINT:-0}" >/dev/null 2>&1
BOB_AFTER=$(bobUsd)
NET5=$(awk -v a="${BOB_AFTER:-0}" -v b="${BOB_BEFORE:-0}" 'BEGIN{ printf "%.0f", a-b }')
NET5_H=$(from_e8 "${NET5:-0}")
# ≤ 0 by construction; allow \$1 of base-unit rounding slack. A gross-holdings
# redeem nets ≈ +\$705 at this W, far above the slack. W5_H is the post-reset
# read above, so the line names the arrears that were actually outstanding.
if awk -v n="${NET5:-0}" 'BEGIN{exit (n <= 100000000 ? 0 : 1)}'; then
  ok "deposit→immediate-withdraw with \$${W5_H} arrears live nets ≤ 0 (net \$${NET5_H})"
else nok "round trip extracted value while arrears outstanding (LP mint/redeem basis misaligned)" "net=\$${NET5_H} (arrears \$${W5_H})"; fi
# F3 (task 1788465539): arrears are deducted ONCE, inside NAV — mint and redeem
# read the same valuePerLP, so the round trip is EXACTLY −fee: −0.4% × $40k =
# −$160 (±$0.50: the virtual-offset dilution on the mint and the base-unit
# floors on the legs). The pre-NAV payout f·(keepBps·H − W) charged the fee on
# the gross basket and then deducted W in full — ≈ −$163.5 here, outside the
# window.
if awk -v n="${NET5:-0}" 'BEGIN{exit (n >= -16050000000 && n <= -15950000000 ? 0 : 1)}'; then
  ok "round trip with arrears outstanding is exactly −fee (net \$${NET5_H} ≈ −\$160): arrears deducted once, inside NAV"
else nok "round trip with arrears ≠ −fee (arrears double-deducted or NAV/redeem basis misaligned)" "net=\$${NET5_H}, expected −160 ± 0.50"; fi

# HYGIENE: settle the banked arrears back to 0 so this suite strands no global
# state — the closing resetExchange would zero W too (#49.4), but the settle
# proves the arrears path DRAINS and leaves the timers unpaused for whoever
# runs next. The arrears heartbeat (settleInsuranceArrears, interval 0) pays
# min(W, vault cash) every beat; give the vault cash ≥ W, UNPAUSE timers, and
# poll the drain with a re-stamp per round (drain_arrears, bounded at 30 s).
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 5000000.0) : nat)" >/dev/null
adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
drain_arrears
if [ "$(pyf)" = "0" ]; then ok "arrears settled back to 0 (no stranded global state)"; else nok "section 5 stranded arrears" "W=\$$(from_e8 "$(pyf)") after ${DRAIN_SECS}s of re-stamps; load avg ${DRAIN_LOAD}"; fi
adm resetExchange '()' >/dev/null 2>&1

echo ""
echo "── 6. An all-zero basket is REFUSED, never burned for nothing (#54.6) ──"
# Issue #54 §54.6. withdrawLp floors each leg (held × f × arrearsNum / H), so
# three inputs reach a basket of exactly 0 in every token: dust (one LP unit
# against a large vault), holdingsUsd == 0, and the arrears saturation
# arrearsNum == 0 (insuranceOwedUsd ≥ 0.996·holdings — the cascade state the
# fund exists for). Pre-fix the burn still completed: shares worth f·NAV were
# removed, the cost basis rescaled, and a permanent #lpWithdraw row with an
# all-zero basket written, all under #ok. performLpDeposit already refuses the
# mirror image ("would mint 0 LP shares"); the fix refuses here too, BEFORE any
# mutation, so the caller keeps shares that still carry NAV. It fires only on
# an exactly-zero basket — a small non-zero one still pays (no exit minimum).
# alice's #lpWithdraw rows on the hash-chained tape (transit queue; timers are
# paused so nothing ships mid-section — a refused exit must not ADD a row).
lpev() { asA getMyUnshippedEvents '()' | grep -c lpWithdraw; }
mylp() { asA getMyVaultLp "()" | tr -d '_' | grep -oE "[0-9]+" | head -1; }
adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAutoFuel '(false)' >/dev/null 2>&1
for t in BTC ETH SOL ICP ICPUSD; do adm setTestBalance "(principal \"$A\", \"$t\", 0 : nat)" >/dev/null; done
adm setTestBalance "(principal \"$A\", \"BTC\",    $(e8 4.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$A\", \"ICPUSD\", $(e8 40000.0) : nat)" >/dev/null
# (a) dust: 1 LP base unit against a $240k vault (supply 2.4e13 units) floors
# every leg to 0 — pre-fix this burned the unit and wrote a zero-basket row.
mdx_lp_deposit alice "BTC-ICPUSD" "$(e8 4.0)" "$(e8 40000.0)" >/dev/null
LP6=$(mylp); EV6=$(lpev); V=$(vv); SUP6=$(echo "$V" | field lpSupply); CB6=$(echo "$V" | field costBasis)
R6=$(mdx_lp_withdraw alice "1")
if echo "$R6" | grep -q "cancelled" && echo "$R6" | grep -q "receive nothing"; then ok "dust withdraw (1 LP unit vs \$240k vault) refused: $(echo "$R6" | grep -oE 'Withdrawal too small[^.]*' | head -1)"; else nok "dust withdraw not refused" "$R6"; fi
if [ "$(mylp)" = "$LP6" ]; then ok "dust: LP balance unchanged ($(from_e8 "$LP6") LP kept)"; else nok "dust: LP burned for nothing" "before=${LP6} after=$(mylp)"; fi
V=$(vv)
if [ "$(echo "$V" | field lpSupply)" = "$SUP6" ] && [ "$(echo "$V" | field costBasis)" = "$CB6" ]; then ok "dust: vault supply + cost basis untouched"; else nok "dust: vault state mutated by a refused exit" "supply ${SUP6}→$(echo "$V" | field lpSupply) basis ${CB6}→$(echo "$V" | field costBasis)"; fi
if [ "$(lpev)" = "$EV6" ]; then ok "dust: no #lpWithdraw tape row emitted"; else nok "dust: refused exit still wrote a tape row" "rows ${EV6}→$(lpev)"; fi
# Fires ONLY on an exactly-zero basket: a small non-zero exit (1.0 LP of
# 240k → 1,659 BTC sats after the fee) still pays out. No exit minimum.
R6S=$(mdx_lp_withdraw alice "$(e8 1.0)")
if echo "$R6S" | grep -q "redeemed =" && [ "$(echo "$R6S" | field btc)" != "0" ] && [ -n "$(echo "$R6S" | field btc)" ]; then ok "small non-zero exit still pays (btc=$(echo "$R6S" | field btc) sats) — no exit minimum"; else nok "small non-zero exit refused or paid nothing" "$R6S"; fi

# (b) arrears-saturated: insuranceOwedUsd ≥ 0.996·holdings zeroes arrearsNum,
# so EVERY exiter's basket is 0 whatever the size. Bank ≈ \$5k of arrears via
# the §5 liquidation-penalty path WITH alice's vault live (resetExchange would
# wipe the receivable — performWorldWipe zeroes insuranceOwedUsd, #49.4), then
# shrink what the vault HOLDS to 0.02 BTC = \$1k (cash ≈ 0, the reachable
# persistent-arrears state) so holdings sit far below W. Pre-fix an exiter
# here burned real shares for \$0 under #ok — the cascade-state capture.
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat)" >/dev/null 2>&1
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1
adm setTestBalance "(principal \"$LIQ_P\", \"ICPUSD\", $(e8 2000000.0) : nat)" >/dev/null
adm seedInsuranceFund "($(e8 3000.0) : nat)" >/dev/null   # §5's hygiene wipe cleared the staker shares; re-mint so penalties accrue
for _ in 1 2 3 4; do bank_arrears; done
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
for t in BTC ETH SOL ICP ICPUSD; do adm setTestBalance "(principal \"$AMM\", \"$t\", 0 : nat)" >/dev/null; done
adm setTestBalance "(principal \"$AMM\", \"BTC\", $(e8 0.02) : nat)" >/dev/null   # holdings = 0.02 BTC = \$1k, cash 0
W6B=$(pyf); W6B_H=$(from_e8 "${W6B:-0}")
if awk -v w="${W6B:-0}" 'BEGIN{exit (w >= 99600000000 ? 0 : 1)}'; then ok "arrears saturate the vault (W=\$${W6B_H} ≥ 0.996 × \$1k holdings)"; else nok "arrears not saturating (precondition)" "W=\$${W6B_H}"; fi
LP6B=$(mylp); EV6B=$(lpev); V=$(vv); SUP6B=$(echo "$V" | field lpSupply)
HALF6=$(awk -v s="${LP6B:-0}" 'BEGIN{printf "%.0f", s/2}')
R6B=$(mdx_lp_withdraw alice "${HALF6}")
# Under NAV redemption (task 1788465539) the cascade state refuses on one of
# two gates, both BEFORE any mutation: NAV == 0 (W ≥ H + L) floors every leg
# → the zero-basket refusal; NAV > 0 only because a liquidated pool's loan
# principal is still outstanding (L > W − H) → the half-exit's NAV value
# exceeds alice's share of the $1k held → the instant-liquidity refusal.
# Either way: refused, nothing burned (pinned next).
if echo "$R6B" | grep -q "cancelled" && echo "$R6B" | grep -qE "receive nothing|exceeds your instant liquidity"; then ok "arrears-saturated exit ($(from_e8 "$HALF6") LP) refused instead of burned for \$0"; else nok "arrears-saturated exit not refused" "$R6B"; fi
if [ "$(mylp)" = "$LP6B" ] && [ "$(vv | field lpSupply)" = "$SUP6B" ]; then ok "saturated: LP balance + supply unchanged (shares keep their NAV)"; else nok "saturated: shares burned for nothing" "lp ${LP6B}→$(mylp) supply ${SUP6B}→$(vv | field lpSupply)"; fi
if [ "$(lpev)" = "$EV6B" ]; then ok "saturated: no #lpWithdraw tape row emitted"; else nok "saturated: refused exit still wrote a tape row" "rows ${EV6B}→$(lpev)"; fi

# HYGIENE (as §5): settle the banked arrears back to 0 so nothing global is
# stranded — vault cash ≥ W, timers unpaused, poll the drain (drain_arrears).
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 5000000.0) : nat)" >/dev/null
adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
drain_arrears
if [ "$(pyf)" = "0" ]; then ok "arrears settled back to 0 (no stranded global state)"; else nok "section 6 stranded arrears" "W=\$$(from_e8 "$(pyf)") after ${DRAIN_SECS}s of re-stamps; load avg ${DRAIN_LOAD}"; fi
adm resetExchange '()' >/dev/null 2>&1

echo ""
echo "── 7. Redemption at NAV + pro-rata instant liquidity (task 1788465539, F1-F6) ──"
# Operator decision 2026-09-03. Pre-fix, withdrawLp paid every share its
# fraction of HOLDINGS only and forfeited that share's slice of the loan book
# to the LPs who stayed — at 50% utilisation an exiter received half of NAV per
# share, permanently. Now every share redeems at NAV (held + loan book −
# arrears, per share: the figure deposits mint at), net of the 40bp exit fee,
# paid in kind from the held basket and CAPPED by the caller's pro-rata share
# of the held basket (a loan cannot be handed out). Un-redeemed shares stay
# the caller's, keep earning, and become redeemable as loans repay. Since task
# 1788475756 the cap is race-proof under REPEATED exits too: an exit LOCKS the
# exiter's remaining shares (a max exit locks all of them — cap 0 until a
# repayment), every other LP's cap is unchanged by it, and a repayment releases
# every lock by one common factor (VaultLock). Fixture: alice (10 BTC + $300k
# genesis) and bob ($100k cash) as LPs; vlp_liq runs TWO margin pools that
# borrow from the vault (the second closes first — a PARTIAL repayment); carol
# is the informed depositor.
liq7() { yes | icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMaxInstantWithdraw '()' 2>&1; }
lpq()  { echo "$1" | field "$2"; }
# USD value of a withdrawLp basket at the 50k mark (only BTC + cash are held).
bskUsd() { local b u; b=$(echo "$1" | field btc); u=$(echo "$1" | field icpusd); awk -v b="${b:-0}" -v u="${u:-0}" 'BEGIN{ printf "%.0f", b*50000 + u }'; }
release7() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
# THE CAP DRIFTS; THE EARN CARD UNDER-ASKS (task 1788746837, operator policy
# (a), 2026-11-01). The quote is exact at its instant (lpBal × H / NAV over
# unlocked shares) and the settlement check is the same inequality, exact —
# but a request is STAGED and settles at the next fresh mark, NAV carries the
# loan book, which ACCRUES (every pool interaction, the 30 s sweep, and —
# since 1788736589 — every mark update and heartbeat beat: the world-driven
# impairment scans accrue each pool before pricing it; the LP paths' own
# scans do not), and every mark move re-prices H and NAV besides. So a request for EXACTLY the quote is
# cancelled whenever any of those lands between the quote and the settlement
# (Δcap = cap × ΔL / NAV: thousands of base units per handful of seconds on
# this fixture's ≈ $135k book). The backend stays exact — nothing clamped,
# nothing queued — and the Earn card fills the quote × (1 −
# LP_WITHDRAW_DRIFT_ALLOWANCE) = 0.01 %, floored to the LP base unit
# (src/frontend/src/main.js lpWithdrawMaxFill); every "max exit" fixture below
# asks the same way through `underask` (bc: the products pass 2^53; integer bc
# truncates = floor). The pins that followed an EXACT max exit (cap 0, every
# retained share locked, 1 LP refused naming $0.00, five more max exits take
# $0) are re-expressed on the allowance's RESIDUE — the 0.01 % the exiter
# deliberately left: lockAfterExit locks ceil(x·NAV/H) − x of the retained
# shares, so ≈ a × lpBal stay unlocked with a cap ≈ a × the cap quoted, and
# that residue is HIS to take later — never the stayers'. "Cap + 1 is refused"
# stays at the EXACT cap. Exits at ZERO utilisation (L = 0: the cap IS the
# balance, H ≡ NAV, nothing accrues) stay exact — there is no race to under-ask
# against there.
LP_DRIFT_ALLOWANCE_PPM=100   # 0.01 % = 100 ppm — the frontend's LP_WITHDRAW_DRIFT_ALLOWANCE (1e-4)
underask() { echo "${1:-0} * (1000000 - $LP_DRIFT_ALLOWANCE_PPM) / 1000000" | bc; }
adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat)" >/dev/null 2>&1
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1
adm setAutoFuel '(false)' >/dev/null 2>&1
for t in BTC ETH SOL ICP ICPUSD; do
  for p in "$A" "$BOB_P" "$AMM" "$LIQ_P" "$CAROL_P"; do adm setTestBalance "(principal \"$p\", \"$t\", 0 : nat)" >/dev/null; done
done
adm setTestBalance "(principal \"$A\",       \"BTC\",    $(e8 10.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$A\",       \"ICPUSD\", $(e8 300000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$BOB_P\",   \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$LIQ_P\",   \"ICPUSD\", $(e8 90000.0) : nat)"  >/dev/null
adm setTestBalance "(principal \"$CAROL_P\", \"ICPUSD\", $(e8 20000.0) : nat)"  >/dev/null
mdx_lp_deposit alice "BTC-ICPUSD" "$(e8 10.0)" "$(e8 300000.0)" >/dev/null
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null   # fresh stamp for the mint gate
# bob's cash leg is under-weight (cash 300k of 800k) → no deposit fee: mint == value.
BOB7=$(mdx_lp_deposit $BOB_ID "BTC-ICPUSD" "0" "$(e8 100000.0)")
if near "$(from_e8 "${BOB7:-0}")" 100000 0.001; then ok "bob minted 100k LP for \$100k (at NAV, no fee)"; else nok "bob's mint" "$(from_e8 "${BOB7:-0}")"; fi

# Zero utilisation: everything is withdrawable — cap == NAV × keepBps.
Q0=$(liq7 $BOB_ID)
if near "$(lpq "$Q0" withdrawableNowUsd)" "$(lpq "$Q0" totalNavUsd)" 0.005 && [ "$(lpq "$Q0" lentOutFraction)" = "0" ] \
   && [ "$(lpq "$Q0" withdrawableNowLp)" = "${BOB7:-x}" ]; then
  ok "zero utilisation: withdrawable now == NAV × 0.996 (\$$(from_e8 "$(lpq "$Q0" withdrawableNowUsd)") of \$$(from_e8 "$(lpq "$Q0" totalNavUsd)")), every LP redeemable"
else nok "zero-utilisation quote" "$Q0"; fi

# vlp_liq borrows from the vault: $60k collateral, 3 BTC long ($150k) → ≈ $90k
# of the vault's cash is lent out (auto-deleverage keeps only the leveraged
# part). The AMM sells the pool its BTC, so holdings shift BTC → cash; NAV is
# unchanged bar the spread the vault EARNS on the fill.
R7=$(asL createMarginPool '("vlp nav", false)')
PID7=$(echo "$R7" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | tail -1)
asL fundMarginPool "($PID7, $(e8 60000.0) : nat)" >/dev/null
asL openPosition "($PID7, \"BTC-ICPUSD\", variant { buy }, $(e8 3.0) : nat, $(e8 0.05) : nat, null)" >/dev/null
release7
# A second pool ($30k collateral, 1.5 BTC long → ≈ $45k more lent out): closing
# it FIRST, later on, is the partial repayment the lock-release pin needs.
R7B=$(asL createMarginPool '("vlp nav2", false)')
PID7B=$(echo "$R7B" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | tail -1)
asL fundMarginPool "($PID7B, $(e8 30000.0) : nat)" >/dev/null
asL openPosition "($PID7B, \"BTC-ICPUSD\", variant { buy }, $(e8 1.5) : nat, $(e8 0.05) : nat, null)" >/dev/null
release7
QB=$(liq7 $BOB_ID); QA=$(liq7 alice)
L7=$(lpq "$QB" vaultLentOutUsd); H7=$(lpq "$QB" vaultHoldingsUsd); N7=$(lpq "$QB" vaultNavUsd)
if awk -v l="${L7:-0}" 'BEGIN{exit (l >= 5000000000000 ? 0 : 1)}'; then ok "loan book live: \$$(from_e8 "$L7") lent out (holdings \$$(from_e8 "$H7"), NAV \$$(from_e8 "$N7"))"; else nok "loan not issued (precondition)" "$QB"; fi
UTIL7=$(awk -v l="${L7:-0}" -v h="${H7:-0}" 'BEGIN{ printf "%.8f", l/(l+h) }')
if near "$(from_e8 "$(lpq "$QB" lentOutFraction)")" "$UTIL7" 0.001; then ok "lentOutFraction == L / (H + L) = $(awk -v u="$UTIL7" 'BEGIN{printf "%.1f", u*100}')%"; else nok "lentOutFraction" "$(lpq "$QB" lentOutFraction) vs $UTIL7"; fi

# F1 — the cap is the caller's pro-rata share of the HELD basket, net of fee:
# bob's lpBal/supply × H × 0.996, and the shares that covers are lpBal × H / NAV.
V=$(vv); SUP7=$(echo "$V" | field lpSupply)
BOBLP=$(lpq "$QB" lpBalance)
EXP_CAP=$(awk -v b="$BOBLP" -v s="$SUP7" -v h="$H7" 'BEGIN{ printf "%.0f", b/s*h*0.996 }')
EXP_LP=$(awk -v b="$BOBLP" -v h="$H7" -v n="$N7" 'BEGIN{ printf "%.0f", b*h/n }')
if near "$(lpq "$QB" withdrawableNowUsd)" "$EXP_CAP" 0.0001; then ok "F1: bob's instant cap == his share of holdings × 0.996 (\$$(from_e8 "$(lpq "$QB" withdrawableNowUsd)") of \$$(from_e8 "$(lpq "$QB" totalNavUsd)") NAV)"; else nok "F1 cap" "got $(lpq "$QB" withdrawableNowUsd) expected $EXP_CAP"; fi
if near "$(lpq "$QB" withdrawableNowLp)" "$EXP_LP" 0.0001; then ok "F1: max redeemable shares == lpBal × H / NAV ($(from_e8 "$(lpq "$QB" withdrawableNowLp)") of $(from_e8 "$BOBLP") LP)"; else nok "F1 cap in LP" "got $(lpq "$QB" withdrawableNowLp) expected $EXP_LP"; fi
# Over the cap: refused, naming the cap and the reason; nothing burned.
CAPLP=$(lpq "$QB" withdrawableNowLp); CAPUSD=$(lpq "$QB" withdrawableNowUsd)
# r2n TRUNCATES to cents (never rounds up a payout figure): match it exactly.
CAP_TXT=$(awk -v c="$CAPUSD" 'BEGIN{ printf "%d.%02d", int(c/100000000), int(c/1000000)%100 }')
R7F=$(mdx_lp_withdraw $BOB_ID "${BOBLP}")
if echo "$R7F" | grep -q "cancelled" && echo "$R7F" | grep -q "lent out" && echo "$R7F" | grep -q "Withdrawable now: \$${CAP_TXT}"; then
  ok "F1: full-balance request refused, naming the cap (\$${CAP_TXT}) and the reason (lent out)"
else nok "over-cap request not refused with the cap named" "$R7F"; fi
R7G=$(mdx_lp_withdraw $BOB_ID "$((CAPLP + 1))")
if echo "$R7G" | grep -q "exceeds your instant liquidity"; then ok "F1: one base unit past the cap is refused (the cap is exact)"; else nok "cap+1 accepted" "$R7G"; fi
if [ "$(asBob getMyVaultLp '()' | tr -d '_' | grep -oE '[0-9]+' | head -1)" = "$BOBLP" ]; then ok "F1: refused requests burned nothing"; else nok "refusal burned LP" "$(asBob getMyVaultLp '()')"; fi

# THE RACE, STAGED (task 1788746837): the loan book accrues AFTER the quote —
# adminRunLiquidationBatch is the 30 s sweep's body (BorrowEngine.accrueAll on
# every pool in its phase 1; it liquidates nothing on this healthy book, and
# with the timers paused nothing else accrues for us) — so the EXACT quote,
# requested now, is cancelled at settlement naming a cap thousands of base
# units under it (seconds of interest on the ≈ $135k book: Δcap = cap × ΔL /
# NAV). That refusal is what the Earn card's user hit; the card's own figure,
# the quote less the allowance, settles below.
adm adminRunLiquidationBatch '()' >/dev/null 2>&1
R7X=$(mdx_lp_withdraw $BOB_ID "${CAPLP}")
if echo "$R7X" | grep -q "cancelled" && echo "$R7X" | grep -q "exceeds your instant liquidity"; then ok "the race: the EXACT quote, requested after the book accrued, is cancelled at settlement naming a cap under it — why the Earn card under-asks"; else nok "exact-cap request after an accrual was not cancelled (the batch no longer accrues? the cap stopped drifting?)" "$R7X"; fi
QB7x=$(liq7 $BOB_ID); CAPLP_X=$(lpq "$QB7x" withdrawableNowLp)
ASK7=$(underask "$CAPLP")
if [ "${CAPLP_X:-0}" -lt "$CAPLP" ] && [ "${CAPLP_X:-0}" -gt "$ASK7" ]; then ok "the drift is real and small: the cap fell $((CAPLP - CAPLP_X)) base units of $CAPLP on the accrual — inside the allowance's $((CAPLP - ASK7)) (0.01 %)"; else nok "cap drift vs the allowance" "before=$CAPLP after=${CAPLP_X:-?} ask=$ASK7"; fi
if [ "$(asBob getMyVaultLp '()' | tr -d '_' | grep -oE '[0-9]+' | head -1)" = "$BOBLP" ]; then ok "the cancelled exact request burned nothing"; else nok "cancelled request burned LP" "$(asBob getMyVaultLp '()')"; fi

# F1/F2/F3/F5 — bob takes the Earn card's max: the quote less the allowance
# (ASK7 of the CAPLP quoted BEFORE the accrual — the user's figure), settled
# under the helper's mark re-stamp. Paid at NAV × keepBps for the shares
# burned (F3: fee once), in kind (basket value == the asked slice of the quote,
# F5: legs floor by at most one base unit each), and he keeps the rest of his
# shares. The pre-exit observables are re-read AFTER the accrual so "untouched
# by the exit" below means exactly that.
V=$(vv); SUP7=$(echo "$V" | field lpSupply); VPL_B=$(echo "$V" | field valuePerLP)
QB=$(liq7 $BOB_ID); QA=$(liq7 alice); ANAV_B=$(lpq "$QA" totalNavUsd)
L7=$(lpq "$QB" vaultLentOutUsd); H7=$(lpq "$QB" vaultHoldingsUsd); N7=$(lpq "$QB" vaultNavUsd)
CAPLP7=$(lpq "$QB" withdrawableNowLp); CAPUSD7=$(lpq "$QB" withdrawableNowUsd)
R7W=$(mdx_lp_withdraw $BOB_ID "${ASK7}")
PAID=$(bskUsd "$R7W")
# Each leg floors to ONE base unit in the vault's favour; the BTC leg's unit
# (1 sat) is worth $0.0005 at the 50k mark, so the basket may fall short of the
# asked slice by ≤ $0.001 (100_000 base units) — and a settlement re-stamp that
# accrues (1788736589) lifts NAV by seconds of interest, bob's slice of which is
# also inside $0.001: symmetric.
EXP5=$(echo "$CAPUSD7 * $ASK7 / $CAPLP7" | bc)   # the asked slice of the quote (bc: the product passes 2^53)
if echo "$R7W" | grep -q "redeemed =" && awk -v p="$PAID" -v c="$EXP5" 'BEGIN{d = p - c; exit ((d < 0 ? -d : d) <= 100000 ? 0 : 1)}'; then
  ok "F5: bob's Earn-card max exit SETTLED under the re-stamp and paid in kind exactly the asked slice of the quote (\$$(from_e8 "$PAID") for $(from_e8 "$ASK7") of the $(from_e8 "$CAPLP7") LP quoted; legs floor ≤ 1 base unit each)"
else nok "under-asked exit did not settle at the asked slice of the quote" "paid=$PAID expected=$EXP5 quoted=$CAPUSD7/$CAPLP7 :: $R7W"; fi
GROSS=$(awk -v x="$ASK7" -v v="$VPL_B" 'BEGIN{ printf "%.0f", x*v/100000000 }')
if near "$PAID" "$(awk -v g="$GROSS" 'BEGIN{printf "%.0f", g*0.996}')" 0.0001; then ok "F3: payout == burned shares × valuePerLP × 0.996 — redeemed at NAV, fee applied once"; else nok "F3 payout basis" "paid=$PAID gross=$GROSS"; fi
BOBLP2=$(asBob getMyVaultLp '()' | tr -d '_' | grep -oE '[0-9]+' | head -1)
if [ "$BOBLP2" = "$((BOBLP - ASK7))" ]; then ok "F4: bob keeps his loan-backed shares ($(from_e8 "$BOBLP2") LP, not burned for nothing)"; else nok "retained shares" "before=$BOBLP burned=$ASK7 after=$BOBLP2"; fi
# F2 — no value transfer: valuePerLP for those who stay never falls (it rises
# by the retained fee only), alice's NAV is untouched, bob's retained shares
# are worth his pre-exit share of the loan book (+ his slice of the fee), and
# the exit removed exactly his share of cash while the loan book is unchanged.
V2=$(vv); VPL_A=$(echo "$V2" | field valuePerLP)
QB2=$(liq7 $BOB_ID); QA2=$(liq7 alice)
if awk -v a="$VPL_A" -v b="$VPL_B" 'BEGIN{exit (a >= b && a <= b*1.001 ? 0 : 1)}'; then ok "F2: valuePerLP unchanged by the exit bar the retained fee ($(from_e8 "$VPL_B") → $(from_e8 "$VPL_A"))"; else nok "F2 valuePerLP moved" "$VPL_B → $VPL_A"; fi
if awk -v a="$(lpq "$QA2" totalNavUsd)" -v b="$ANAV_B" 'BEGIN{exit (a >= b && a <= b*1.001 ? 0 : 1)}'; then ok "F2: alice's NAV untouched by bob's exit (\$$(from_e8 "$ANAV_B") → \$$(from_e8 "$(lpq "$QA2" totalNavUsd)"))"; else nok "F2 alice's NAV moved" "$ANAV_B → $(lpq "$QA2" totalNavUsd)"; fi
BOB_LOANSHARE=$(awk -v b="$BOBLP" -v s="$SUP7" -v l="$L7" 'BEGIN{ printf "%.0f", b/s*l }')
if near "$(lpq "$QB2" totalNavUsd)" "$BOB_LOANSHARE" 0.002; then ok "F2: bob's retained shares are worth his share of the loan book (\$$(from_e8 "$(lpq "$QB2" totalNavUsd)") ≈ \$$(from_e8 "$BOB_LOANSHARE"))"; else nok "F2 retained NAV" "$(lpq "$QB2" totalNavUsd) vs $BOB_LOANSHARE"; fi
H7B=$(lpq "$QB2" vaultHoldingsUsd); L7B=$(lpq "$QB2" vaultLentOutUsd)
# The loan book is untouched by the exit; interest a settlement re-stamp books
# (1788736589 accrues on every mark update) is not the exit's doing — allow
# ≤ 5 min of 5 % on it (the §8 idiom), never a shrink.
if near "$H7B" "$((H7 - PAID))" 0.0001 && awk -v a="$L7B" -v b="$L7" 'BEGIN{exit (a >= b && a - b <= b * 0.05 * 300 / 31536000 ? 0 : 1)}'; then ok "F2: the exit removed exactly bob's cash (holdings \$$(from_e8 "$H7") → \$$(from_e8 "$H7B")); the loan book is untouched (\$$(from_e8 "$L7") → \$$(from_e8 "$L7B"), accrual only)"; else nok "F2 vault composition" "H ${H7}→${H7B} (paid ${PAID}), L ${L7}→${L7B}"; fi
# F1 (no race): alice's share of the cash is still hers to take — her instant
# cap is UNCHANGED by bob's exit (task 1788475756: it rises only by her slice
# of the fee bob left in the vault; under the stateless cap it FELL, because
# bob's retained shares kept claiming a slice of the remaining cash).
ACAP=$(lpq "$QA2" withdrawableNowUsd); ALP=$(lpq "$QA2" lpBalance); SUP7B=$(vv | field lpSupply)
ACAP0=$(lpq "$QA" withdrawableNowUsd); FEE7=$((GROSS - PAID))
if awk -v a="$ACAP" -v b="$ACAP0" -v f="$FEE7" 'BEGIN{exit (a >= b && a <= b + f + 100000 && a > 0 ? 0 : 1)}'; then ok "F1/F2: alice's cap is unchanged by bob's exit bar her slice of his fee (\$$(from_e8 "$ACAP0") → \$$(from_e8 "$ACAP"), fee \$$(from_e8 "$FEE7")) — no first-come drain"; else nok "F1 alice's cap moved on bob's exit" "before=$ACAP0 after=$ACAP fee=$FEE7"; fi
if [ "$(asA getMyVaultLp '()' | tr -d '_' | grep -oE '[0-9]+' | head -1)" = "$ALP" ] && [ "$((ALP + BOBLP2))" = "$SUP7B" ]; then ok "F5 (I1): Σ LP balances == supply after the partial exit"; else nok "I1" "alice=$ALP bob=$BOBLP2 supply=$SUP7B"; fi
# F1 BY CONSTRUCTION (task 1788475756), under the allowance (1788746837): bob's
# Earn-card max exit LOCKED every share he kept BAR the allowance's residue.
# lockAfterExit locks ceil(x·NAV/H) − x of the retained shares, so with x = cap
# × (1 − a) ≈ a × lpBal shares stay unlocked (the accrual between the quote and
# the exit trims that by Δcap, ≤ 0.1 %), their cap is the residue he left on
# the table — ≈ a × the cap quoted, plus his unlocked slice of his own fee
# (≤ 0.05 %) — and the vault's locked total is exactly his lock (alice holds
# none). The residue is HIS: the next pins take it, and only it.
LKB2=$(lpq "$QB2" lockedLp); CAP2=$(lpq "$QB2" withdrawableNowLp); CAP2USD=$(lpq "$QB2" withdrawableNowUsd)
UNL2=$((BOBLP2 - LKB2)); RES7=$((CAPLP7 - ASK7)); EXP_UNL2=$(echo "$BOBLP * $LP_DRIFT_ALLOWANCE_PPM / 1000000" | bc)
if [ "${CAP2:-0}" -gt 0 ] && near "$UNL2" "$EXP_UNL2" 0.001 && near "${CAP2:-0}" "$RES7" 0.002; then ok "F1 (iteration, under the allowance): after his Earn-card max exit bob keeps ≈ a × lpBal = $(from_e8 "$UNL2") LP unlocked and $(from_e8 "$LKB2") of $(from_e8 "$BOBLP2") locked; his cap is the residue he left on the table ($(from_e8 "$CAP2") ≈ $(from_e8 "$RES7") LP, \$$(from_e8 "$CAP2USD")) — not 0, and not a drain"; else nok "F1 iteration under the allowance: unlocked ≠ a × lpBal or cap ≠ residue" "unlocked=$UNL2 expected≈$EXP_UNL2 cap=${CAP2:-?} residue=$RES7 locked=$LKB2 bal=$BOBLP2"; fi
if [ "$(lpq "$QA2" lockedLp)" = "0" ] && [ "$(lpq "$QA2" vaultLockedLp)" = "$LKB2" ]; then ok "locks: alice holds none; the vault's locked total == bob's lock (the one lock there is)"; else nok "lock totals" "alice locked=$(lpq "$QA2" lockedLp) vault locked=$(lpq "$QA2" vaultLockedLp) bob=$BOBLP2"; fi
# The exact check is untouched by the allowance: one base unit past the
# RESIDUAL cap is refused, naming it (r2n truncates to cents).
CAP2_TXT=$(awk -v c="${CAP2USD:-0}" 'BEGIN{ printf "%d.%02d", int(c/100000000), int(c/1000000)%100 }')
R7I=$(mdx_lp_withdraw $BOB_ID "$((${CAP2:-0} + 1))")
if echo "$R7I" | grep -q "exceeds your instant liquidity" && echo "$R7I" | grep -q "Withdrawable now: \$${CAP2_TXT} "; then ok "F1 (iteration): one base unit past the residual cap is refused, naming it (\$${CAP2_TXT}) — cap + 1 stays exact"; else nok "residue + 1 not refused with the residual cap named" "$R7I"; fi
# The harmonic drain, bounded: five further Earn-card "max exits" by bob (each
# the then-cap less the allowance; a 1-unit probe once the cap reads 0) take at
# most the residue — ≈ a × his cap, then a² × …, then dust the zero-basket
# guard refuses — so across ANY number of exits his cash is one share of
# holdings, to the cent (the stateless cap handed him H·a/S, then
# (H−…)·a'/S', … — ≈ 91% of his NAV in ten rounds).
DRAIN=0
for i in 1 2 3 4 5; do
  CL=$(underask "$(lpq "$(liq7 $BOB_ID)" withdrawableNowLp)"); [ "${CL:-0}" = "0" ] && CL=1
  RR=$(mdx_lp_withdraw $BOB_ID "$CL"); if echo "$RR" | grep -q "redeemed ="; then DRAIN=$((DRAIN + $(bskUsd "$RR"))); fi
done
BOBLP3=$(asBob getMyVaultLp '()' | tr -d '_' | grep -oE '[0-9]+' | head -1)
if [ "$DRAIN" -gt 0 ] && awk -v d="$DRAIN" -v r="${CAP2USD:-0}" 'BEGIN{exit (d <= r * 1.001 + 100000 ? 0 : 1)}' && awk -v p="$PAID" -v d="$DRAIN" -v c="$CAPUSD7" 'BEGIN{exit (p + d <= c + 2000000 ? 0 : 1)}' && [ $((BOBLP2 - BOBLP3)) -le $((${CAP2:-0} * 1001 / 1000 + 1)) ]; then ok "F1 (harmonic drain bounded): five more max exits took only the residue (\$$(from_e8 "$DRAIN") of the \$$(from_e8 "$CAP2USD") left on the table; LP $(from_e8 "$BOBLP2") → $(from_e8 "$BOBLP3")) — across every exit bob's cash is one share of held cash (\$$(from_e8 "$((PAID + DRAIN))") vs the \$$(from_e8 "$CAPUSD7") quoted, within \$0.02)"; else nok "harmonic drain not bounded by the residue" "drained=$DRAIN residue=$CAP2USD paid=$PAID cap=$CAPUSD7 lp $BOBLP2 → $BOBLP3"; fi

# F6 — informed consent: BEFORE depositing, carol reads the vault-level
# figures and knows what fraction of a $20k deposit would be instantly
# withdrawable: (H + V) × 0.996 / (NAV − lockedNAV + V) — only UNLOCKED shares
# share the cash; bob's locked shares carry loan-book value only (task
# 1788475756: vaultLockedNavUsd). After depositing, her quote matches.
QC0=$(liq7 $CAROL_ID)
PRED=$(awk -v h="$(lpq "$QC0" vaultHoldingsUsd)" -v n="$(lpq "$QC0" vaultNavUsd)" -v ln="$(lpq "$QC0" vaultLockedNavUsd)" -v v="$(e8 20000)" 'BEGIN{ printf "%.6f", (h+v)*0.996/(n-ln+v) }')
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null   # fresh stamp for the mint gate
CMINT7=$(mdx_lp_deposit $CAROL_ID "BTC-ICPUSD" "0" "$(e8 20000.0)")
QC1=$(liq7 $CAROL_ID)
ACT=$(awk -v w="$(lpq "$QC1" withdrawableNowUsd)" -v v="$(e8 20000)" 'BEGIN{ printf "%.6f", w/v }')
if [ -n "${CMINT7:-}" ] && near "$ACT" "$PRED" 0.002; then ok "F6: carol's pre-deposit prediction ($(awk -v p="$PRED" 'BEGIN{printf "%.1f", p*100}')% instantly withdrawable) matches her post-deposit quote ($(awk -v a="$ACT" 'BEGIN{printf "%.1f", a*100}')%)"; else nok "F6 prediction ≠ quote" "pred=$PRED actual=$ACT mint=${CMINT7:-none}"; fi
if awk -v a="$ACT" 'BEGIN{exit (a < 0.99 ? 0 : 1)}'; then ok "F6: a deposit into a lending vault is NOT fully instantly withdrawable — disclosed, never a surprise"; else nok "F6 deposit fully withdrawable despite utilisation" "$ACT"; fi

# F4 — retained shares earn like every other share: a 10% BTC mark-up lifts
# bob's NAV by exactly retained × ΔvaluePerLP (one share class), and when the
# pool CLOSES (repaying the loan) his retained shares become redeemable —
# the constraint was timing, not equity.
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 55000.0) : nat)" >/dev/null
V3=$(vv); QB3=$(liq7 $BOB_ID)
# bob's balance is BOBLP3: the bounded drain above took the allowance's residue
# (≈ 8.5 LP of the 15.2k he kept) — under an exact max exit it burned nothing.
if near "$(lpq "$QB3" totalNavUsd)" "$(awk -v b="$BOBLP3" -v v="$(echo "$V3" | field valuePerLP)" 'BEGIN{printf "%.0f", b*v/100000000}')" 0.0001 && awk -v a="$(lpq "$QB3" totalNavUsd)" -v b="$(lpq "$QB2" totalNavUsd)" 'BEGIN{exit (a > b ? 0 : 1)}'; then
  ok "F4: retained shares mark at the common valuePerLP and gained on the move (\$$(from_e8 "$(lpq "$QB2" totalNavUsd)") → \$$(from_e8 "$(lpq "$QB3" totalNavUsd)")) — no second-class shares"
else nok "F4 retained shares priced differently" "$QB3 :: $V3"; fi
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
# A PARTIAL repayment releases locks by the COMMON factor (task 1788475756):
# closing the second pool repays ~ a third of the book, and bob — fully
# locked, so his whole NAV is loan claim — gets cash pro rata to that claim:
# R x NAV_bob / Lx, the same rule every LP's loan claim gets (the per-LP
# truth VaultLock's single index reproduces; tests/VaultLock.test.mo pins it
# to the unit). His lock shrinks but does not vanish.
QB5a=$(liq7 $BOB_ID)
NAVB5=$(lpq "$QB5a" totalNavUsd); H5a=$(lpq "$QB5a" vaultHoldingsUsd); N5a=$(lpq "$QB5a" vaultNavUsd); L5a=$(lpq "$QB5a" vaultLentOutUsd); LK5a=$(lpq "$QB5a" lockedLp)
asL closePosition "($PID7B, \"BTC-ICPUSD\", $(e8 0.05) : nat, null)" >/dev/null
release7
QB5=$(liq7 $BOB_ID)
L5=$(lpq "$QB5" vaultLentOutUsd); R5=$((L5a - L5)); LX5=$((N5a - H5a))
EXP_B5=$(awk -v r="${R5}" -v n="${NAVB5}" -v lx="${LX5}" 'BEGIN{ printf "%.0f", r*n/lx*0.996 }')
if [ "${R5}" -gt 0 ] && [ "${L5}" -gt 0 ] && near "$(lpq "$QB5" withdrawableNowUsd)" "${EXP_B5}" 0.02; then ok "repayment (partial, \$$(from_e8 "${R5}") of \$$(from_e8 "${L5a}")): bob's cap == R x NAV_bob / Lx x 0.996 (\$$(from_e8 "$(lpq "$QB5" withdrawableNowUsd)") ~ \$$(from_e8 "${EXP_B5}")) — cash pro rata to his loan claim"; else nok "partial repayment did not release bob's cap by the common factor" "R=${R5} L=${L5a}→${L5} cap=$(lpq "$QB5" withdrawableNowUsd) expected=${EXP_B5}"; fi
LK5=$(lpq "$QB5" lockedLp)
if [ "${LK5:-0}" -gt 0 ] && [ "${LK5:-0}" -lt "${LK5a:-0}" ] && [ $((LK5 - $(lpq "$QB5" vaultLockedLp))) -le 1 ]; then ok "repayment (partial): bob's lock shrank but did not vanish ($(from_e8 "${LK5a}") → $(from_e8 "$LK5") LP locked; the vault total follows)"; else nok "lock did not shrink by a partial repayment" "locked ${LK5a} → $LK5, vault $(lpq "$QB5" vaultLockedLp)"; fi
# Repay-then-reborrow INSIDE ONE BEAT (task 1788727876): the second pool
# re-opens the SAME size right after its close with no LP touch in between
# (the heartbeat is paused; getMaxInstantWithdraw is a view and persists
# nothing). Under the lazy detection alone the per-token units netted to
# R = 0 between the two touches and bob's cap read $0 — the repayment's
# release was lost until the next repayment. Settled AT the close's
# repayment (reprovisionPool, every loan-book mutation) bob's unlocked
# fraction is fixed by the repayment, and the reborrow only takes cash out of
# every unlocked share uniformly (VaultLock: issuance changes no lock), so
# his cap == the released cap × H_after / H_before-the-reborrow — i.e. R ×
# NAV_bob / Lx × 0.996 scaled by the holdings the issuance lent out again.
CAP5=$(lpq "$QB5" withdrawableNowUsd); H5=$(lpq "$QB5" vaultHoldingsUsd)
asL openPosition "($PID7B, \"BTC-ICPUSD\", variant { buy }, $(e8 1.5) : nat, $(e8 0.05) : nat, null)" >/dev/null
release7
QB6=$(liq7 $BOB_ID)
L6=$(lpq "$QB6" vaultLentOutUsd); H6=$(lpq "$QB6" vaultHoldingsUsd); LK6=$(lpq "$QB6" lockedLp)
EXP_B6=$(awk -v c="${CAP5:-0}" -v h5="${H5:-1}" -v h6="${H6:-0}" 'BEGIN{ printf "%.0f", c*h6/h5 }')
if awk -v a="${L6:-0}" -v b="${L5:-0}" 'BEGIN{exit (a > b*1.4 ? 0 : 1)}'; then ok "reborrow landed: the second pool re-opened its position in the same beat (lent out \$$(from_e8 "$L5") → \$$(from_e8 "$L6"), holdings \$$(from_e8 "$H5") → \$$(from_e8 "$H6"))"; else nok "reborrow did not land (precondition)" "L ${L5}→${L6} :: $QB6"; fi
if [ "${EXP_B6:-0}" -gt 0 ] && near "$(lpq "$QB6" withdrawableNowUsd)" "${EXP_B6}" 0.01; then ok "repay-then-reborrow in one beat: bob's cap == the repayment's release × H_after/H_before (\$$(from_e8 "$(lpq "$QB6" withdrawableNowUsd)") ~ \$$(from_e8 "${EXP_B6}")) — settled AT the repayment, never netted to \$0 by the reborrow"; else nok "repay-then-reborrow netted bob's release away (the lazy detection's blind spot)" "cap=\$$(from_e8 "$(lpq "$QB6" withdrawableNowUsd)") expected=\$$(from_e8 "${EXP_B6}") (released cap \$$(from_e8 "$CAP5"), H ${H5}→${H6})"; fi
if [ "${LK6:-0}" -gt 0 ] && [ $(( LK6 > LK5 ? LK6 - LK5 : LK5 - LK6 )) -le 1 ]; then ok "repay-then-reborrow: the reborrow changed no lock — bob's lock is the post-repayment one ($(from_e8 "$LK5") LP), not the pre-repayment $(from_e8 "$LK5a")"; else nok "reborrow moved bob's lock (or the repayment's shrink was never persisted)" "locked ${LK5a} → ${LK5} → ${LK6}"; fi
# Close the re-opened pool again so the FULL repayment below sees a book of 0.
asL closePosition "($PID7B, \"BTC-ICPUSD\", $(e8 0.05) : nat, null)" >/dev/null
release7
QB5=$(liq7 $BOB_ID)
CAP_BEFORE=$(lpq "$QB5" withdrawableNowLp)
asL closePosition "($PID7, \"BTC-ICPUSD\", $(e8 0.05) : nat, null)" >/dev/null
release7
QB4=$(liq7 $BOB_ID)
if [ "$(lpq "$QB4" lockedLp)" = "0" ] && [ "$(lpq "$QB4" vaultLockedLp)" = "0" ] && [ "$(lpq "$QB4" withdrawableNowLp)" = "$(lpq "$QB4" lpBalance)" ]; then ok "repayment (full): every lock released (bob's and the vault's locked LP == 0), bob's cap == his whole balance"; else nok "full repayment left locks" "locked=$(lpq "$QB4" lockedLp) vault=$(lpq "$QB4" vaultLockedLp) cap=$(lpq "$QB4" withdrawableNowLp) bal=$(lpq "$QB4" lpBalance)"; fi
# The close repays IN FULL — exactly 0 lent out, no dust. deleveragePool used
# to read the debt BEFORE BorrowEngine.repay's own accrual, so the interest
# booked between the close's accrueAll and the fill's settlement message was
# never asked for and stayed on the book (~$0.001) — a vault that had EVER
# lent then never returned to NAV == holdings (task 1788515291).
if [ "$(lpq "$QB4" vaultLentOutUsd)" = "0" ]; then ok "loan repaid on close IN FULL (lent out \$$(from_e8 "$L7") → \$0 exactly: the in-message interest is paid too, no dust residue)"; else nok "close left a loan residue (deleveragePool must accrue before it reads the debt)" "vaultLentOutUsd=$(lpq "$QB4" vaultLentOutUsd) :: $QB4"; fi
if awk -v a="$(lpq "$QB4" withdrawableNowLp)" -v b="$CAP_BEFORE" 'BEGIN{exit (a > b ? 0 : 1)}'; then ok "F4: repayment raised bob's redeemable shares ($(from_e8 "$CAP_BEFORE") → $(from_e8 "$(lpq "$QB4" withdrawableNowLp)") LP)"; else nok "F4 cap did not rise on repayment" "$CAP_BEFORE → $(lpq "$QB4" withdrawableNowLp)"; fi
R7R=$(mdx_lp_withdraw $BOB_ID "$(lpq "$QB4" withdrawableNowLp)")
if echo "$R7R" | grep -q "redeemed =" && awk -v p="$(bskUsd "$R7R")" -v q="$(lpq "$QB4" withdrawableNowUsd)" 'BEGIN{exit (p <= q && q - p <= 100000 ? 0 : 1)}'; then ok "F4: retained shares redeemed after the repayment (\$$(from_e8 "$(bskUsd "$R7R")"))"; else nok "retained shares not redeemable after repayment" "$R7R"; fi

# Carol's exit at EXACTLY zero utilisation: the close repaid the loan in full
# (above), so the loan book is 0, every one of her shares is redeemable (the
# cap == her balance — no "a few base units under" from a dust claim), and
# withdrawing the quote pays exactly NAV × 0.996. (The h888 sweep on the
# LAST exit is §4's full exit.)
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
Q7=$(liq7 $CAROL_ID)
if [ "$(lpq "$Q7" vaultLentOutUsd)" = "0" ] && [ "$(lpq "$Q7" withdrawableNowLp)" = "$(lpq "$Q7" lpBalance)" ]; then ok "zero utilisation after the close: loan book \$0, carol's cap == her full balance ($(from_e8 "$(lpq "$Q7" lpBalance)") LP)"; else nok "loan residue survives the close (cap under balance)" "lent=$(lpq "$Q7" vaultLentOutUsd) cap=$(lpq "$Q7" withdrawableNowLp) bal=$(lpq "$Q7" lpBalance)"; fi
RC=$(mdx_lp_withdraw $CAROL_ID "$(lpq "$Q7" withdrawableNowLp)")
EXP_RC=$(awk -v x="$(lpq "$Q7" withdrawableNowLp)" -v n="$(lpq "$Q7" totalNavUsd)" -v b="$(lpq "$Q7" lpBalance)" 'BEGIN{printf "%.0f", x/b*n*0.996}')
if echo "$RC" | grep -q "redeemed =" && awk -v p="$(bskUsd "$RC")" -v e="$EXP_RC" 'BEGIN{exit (p <= e && e - p <= 100000 ? 0 : 1)}'; then ok "exit at zero utilisation pays NAV × 0.996 exactly (\$$(from_e8 "$(bskUsd "$RC")") for $(from_e8 "$(lpq "$Q7" withdrawableNowLp)") of $(from_e8 "$(lpq "$Q7" lpBalance)") LP)"; else nok "exit ≠ NAV × 0.996" "$RC :: $Q7 :: expected $EXP_RC"; fi
mdx_lp_withdraw $BOB_ID "$(asBob getMyVaultLp '()' | tr -d '_' | grep -oE '[0-9]+' | head -1)" >/dev/null 2>&1
mdx_lp_withdraw alice "$(asA getMyVaultLp '()' | tr -d '_' | grep -oE '[0-9]+' | head -1)" >/dev/null 2>&1
adm resetExchange '()' >/dev/null 2>&1

echo ""
echo "── 8. Per-loan impairment reserve: the loan book net of expected loss (task 1788475754) ──"
# NAV carried every loan at FACE value until the loss was realised, so an LP
# who redeemed while a pool was under water took face value for a loan about to
# be written down and the stayers ate the whole loss. Now every pool with debt
# is provisioned PD × LGD from the liquidator's own health figures
# (VaultMath.expectedLoss: LGD = D − 0.85·C, PD ramps 0 → 1 across [1.15, 1.0),
# 1 below), the gross is netted against the insurance fund's cash (its
# first-loss — no double count) in aggregate, clamped to the loan book, and
# NAV = H + (L − R) − W. Same fixture shape as §7: alice + bob LP, vlp_liq runs
# a 3 BTC long against $60k. Timers stay PAUSED so the 30s liquidation sweep
# never runs: everything below happens BEFORE any liquidation, and the
# provision is refreshed by the mark update itself (setAmmRefPrice).
imp()  { yes | adm getVaultImpairment '()' 2>&1; }
# The pool's own health figures (D up, C down — what the provision reads).
poolD() { asL getMyMarginPools '()' | tr -d '_' | grep -oE 'debtUsd = [0-9]+' | head -1 | grep -oE '[0-9]+'; }
poolC() { asL getMyMarginPools '()' | tr -d '_' | grep -oE 'collateralUsd = [0-9]+' | head -1 | grep -oE '[0-9]+'; }
# VaultMath.expectedLoss in bc (awk doubles lose integer exactness past 2^53,
# and the ceil-mulDiv below multiplies ~1e12 by ~1e7): h floored, recovery
# floored, PD applied as ONE ceil-mulDiv — exact to the base unit.
expLoss() {
  if [ "${1:-0}" = "0" ]; then echo 0; return; fi
  bc <<EOF
scale=0
d=$1
c=$2
h=c*100000000/d
rec=c*85000000/100000000
lgd=d-rec
num=lgd*(115000000-h)
den=15000000
pd=num/den
if (num%den>0) pd=pd+1
r=pd
if (h<100000000) r=lgd
if (rec>=d) r=0
if (h>=115000000) r=0
r
EOF
}
adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat)" >/dev/null 2>&1
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1
adm setAutoFuel '(false)' >/dev/null 2>&1
for t in BTC ETH SOL ICP ICPUSD; do
  for p in "$A" "$BOB_P" "$AMM" "$LIQ_P" "$CAROL_P"; do adm setTestBalance "(principal \"$p\", \"$t\", 0 : nat)" >/dev/null; done
done
adm setTestBalance "(principal \"$A\",     \"BTC\",    $(e8 10.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$A\",     \"ICPUSD\", $(e8 300000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$BOB_P\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$LIQ_P\", \"ICPUSD\", $(e8 60000.0) : nat)"  >/dev/null
mdx_lp_deposit alice "BTC-ICPUSD" "$(e8 10.0)" "$(e8 300000.0)" >/dev/null
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
BOB8=$(mdx_lp_deposit $BOB_ID "BTC-ICPUSD" "0" "$(e8 100000.0)")
# A $2k insurance fund: the first-loss the reserve must be netted against
# (seeded by anonymous — the resetExchange above zeroed the fund's cash).
adm seedInsuranceFund "($(e8 2000.0) : nat)" >/dev/null
I8=$(imp | field insuranceFirstLossUsd)
if near "${I8:-0}" "$(e8 2000)" 0.001; then ok "insurance first-loss in place (\$$(from_e8 "$I8"))"; else nok "insurance fund not seeded (precondition)" "$(imp)"; fi
R8=$(asL createMarginPool '("vlp impair", false)')
PID8=$(echo "$R8" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | tail -1)
asL fundMarginPool "($PID8, $(e8 60000.0) : nat)" >/dev/null
asL openPosition "($PID8, \"BTC-ICPUSD\", variant { buy }, $(e8 3.0) : nat, $(e8 0.05) : nat, null)" >/dev/null
release7
# Healthy book (h ≈ 1.5 at the 50k mark): NO provision — a performing loan is
# carried at face, never taxed.
Q8=$(imp); L8=$(echo "$Q8" | field loanBookUsd)
if awk -v l="${L8:-0}" 'BEGIN{exit (l >= 5000000000000 ? 0 : 1)}' && [ "$(echo "$Q8" | field reserveUsd)" = "0" ] && [ "$(echo "$Q8" | field grossExpectedLossUsd)" = "0" ] && [ "$(echo "$Q8" | field impairedLoans)" = "0" ] && [ "$(echo "$Q8" | field impairedDebtUsd)" = "0" ] && [ "$(echo "$Q8" | field impairedCollateralUsd)" = "0" ]; then
  ok "healthy loan (h ≈ 1.5, \$$(from_e8 "$L8") lent): reserve 0, gross 0, no impaired loans, impaired D/C 0 — performing loans are carried at face"
else nok "healthy loan provisioned, or no loan (precondition)" "$Q8"; fi
D8a=$(poolD); C8a=$(poolC)
if [ "$(expLoss "$D8a" "$C8a")" = "0" ]; then ok "pool health above maintenance (C \$$(from_e8 "$C8a") / D \$$(from_e8 "$D8a")): expectedLoss == 0"; else nok "fixture health not above maintenance" "D=$D8a C=$C8a"; fi
VPL8a=$(vv | field valuePerLP); QB8a=$(liq7 $BOB_ID)
if [ "$(lpq "$QB8a" vaultImpairmentReserveUsd)" = "0" ] && [ "$(lpq "$QB8a" provisionedLossUsd)" = "0" ]; then ok "getMaxInstantWithdraw discloses reserve 0 / provisioned 0 on the healthy book"; else nok "disclosure on healthy book" "$QB8a"; fi

# BTC 50k → 35k: the 3 BTC long's haircut collateral (3 × 35k × 0.9 = $94.5k)
# now sits just above its ≈ $90k debt — h ≈ 1.05, inside the liquidatable band
# — and NOTHING has been liquidated (timers paused). The mark update itself
# refreshes the provision: reserve > 0, equal to the pool's PD × LGD net of
# the $2k fund, and the loan book moves ONLY by the interest the stamp's scan
# accrued (this is BEFORE liquidation). The gross is recomputed from the D/C
# the scan PRICED (impairedDebtUsd / impairedCollateralUsd on the view, task
# 1788733762) — not from a later getMyMarginPools read: that read accrues the
# pool's interest to ITS instant (≈ 14.5k units/s on ≈ $91.5k of ICPUSD debt
# at 5 %), so two reads a couple of seconds apart disagree on D by ~3e4 units
# and on EL by ~2.5e4 — the pre-fix red. The live read still has to agree
# with the priced one up to exactly that accrual: same C (same mark), D_live ≥
# D_priced, and the gap no more than the interest of the host-clock window
# between the stamp's dispatch and the live read's return (task 1788736589:
# the world-driven scan ACCRUES the pool to the scan instant before pricing
# it, so the priced D is the liquidator's own figure at computedNs and only
# the CLI latency of ≈ 3 calls separates the two reads — measured 0.8–1.5 s,
# ≈ 12–22k units; a 500 ms clock-slack term rides on top). Before that fix the
# priced D was the principal as last BOOKED (the fill, ≈ 9 calls earlier) and
# this bound reds by the interest of the whole fill-to-crash stretch; the old
# 5-min bound (≈ 4.4M units) passed both.
CN8=$(echo "$Q8" | field computedNs)   # the release stamp's scan instant — BEFORE the fill landed (the requote's message)
T8S=$(ms)   # the live-vs-priced window opens before the crash stamp is dispatched...
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 35000.0) : nat)" >/dev/null
Q8b=$(imp); G8=$(echo "$Q8b" | field grossExpectedLossUsd); RES8=$(echo "$Q8b" | field reserveUsd); L8b=$(echo "$Q8b" | field loanBookUsd)
CN8b=$(echo "$Q8b" | field computedNs)   # the crash stamp's scan instant: the loans were accrued to exactly this
# (Task 1788733717 first pinned D to the SAME snapshot's loanBookUsd — the
# stored book, BorrowEngine.totalOutstanding — which equals the priced D here
# because the fixture's only loan is QUOTE-denominated; a base-token loan's L
# is priced at the mark and rounded DOWN where D rounds UP, so the published
# pair is the general form. Both agree on this fixture, pinned below.)
PD8=$(echo "$Q8b" | field impairedDebtUsd); PC8=$(echo "$Q8b" | field impairedCollateralUsd); EL8=$(expLoss "${PD8:-0}" "${PC8:-0}")
D8b=$(poolD); T8R=$(ms); C8b=$(poolC)   # ...and closes once the live D is back (C does not accrue)
if awk -v r="${RES8:-0}" 'BEGIN{exit (r > 0 ? 0 : 1)}'; then ok "near-liquidation pool (C \$$(from_e8 "$C8b") / D \$$(from_e8 "$D8b")) is provisioned BEFORE any liquidation: reserve \$$(from_e8 "$RES8")"; else nok "no provision on a near-liquidation loan" "$Q8b :: D=$D8b C=$C8b"; fi
if awk -v h="$C8b" -v d="$D8b" 'BEGIN{exit (h*100000000/d >= 100000000 && h*100000000/d < 115000000 ? 0 : 1)}'; then ok "fixture sits in the liquidatable band (h = $(awk -v h="$C8b" -v d="$D8b" 'BEGIN{printf "%.4f", h/d}') ∈ [1.0, 1.15)) — the ramp, not the under-water floor"; else nok "fixture not in the band (h = $(awk -v h="$C8b" -v d="$D8b" 'BEGIN{printf "%.4f", h/d}'))" "retune the crash mark"; fi
if [ -n "$PD8" ] && [ "$G8" = "$EL8" ]; then ok "gross == VaultMath.expectedLoss(D, C) to the base unit on the D/C the scan priced (\$$(from_e8 "$G8") from D \$$(from_e8 "$PD8") / C \$$(from_e8 "$PC8"); one impaired loan, so the Σ IS the pool)"; else nok "gross ≠ PD × LGD on the priced D/C" "gross=$G8 expected=$EL8 (pricedD=$PD8 pricedC=$PC8 liveD=$D8b liveC=$C8b)"; fi
W8=$(( T8R - T8S )); D8ACC=$(interest_ms "${PD8:-0}" $(( W8 + 500 )) "$APR_ICPUSD")
if [ "$C8b" = "$PC8" ] && [ "${PD8:-0}" -gt 0 ] && [ "${D8b:-0}" -ge "$PD8" ] && [ $(( D8b - PD8 )) -le "$D8ACC" ]; then ok "the pool's own live read agrees with the priced figures up to accrual only: C identical, D_live − D_priced = $(( D8b - PD8 )) units ≥ 0 and ≤ $D8ACC (the 5 % interest of the $W8 ms between the crash stamp's dispatch and the live read's return, + 500 ms of clock slack — the scan priced D accrued to its own instant)"; else nok "live D/C drifted from the priced D/C beyond the scan-to-read accrual (the scan priced an UN-accrued D?)" "pricedD=$PD8 liveD=$D8b gap=$(( ${D8b:-0} - ${PD8:-0} )) bound=$D8ACC over $W8 ms (+500) pricedC=$PC8 liveC=$C8b"; fi
if [ "$PD8" = "$L8b" ]; then ok "…and on this quote-only single-loan book the priced D equals the same snapshot's loanBookUsd to the unit (1788733717's pin, kept as a cross-check)"; else nok "priced D ≠ loanBookUsd on a quote-only single-loan book" "pricedD=$PD8 loanBook=$L8b"; fi
if [ "$(echo "$Q8b" | field impairedLoans)" = "1" ]; then ok "one impaired loan counted"; else nok "impairedLoans" "$Q8b"; fi
EXP_R8=$(awk -v g="$G8" -v i="$I8" 'BEGIN{ r = g - i; if (r < 0) r = 0; printf "%.0f", r }')
if [ "$RES8" = "$EXP_R8" ] && awk -v g="$G8" -v i="$I8" 'BEGIN{exit (g > i ? 0 : 1)}'; then ok "reserve == gross − insurance first-loss (\$$(from_e8 "$G8") − \$$(from_e8 "$I8") = \$$(from_e8 "$RES8")): the fund's cover is netted once, never double-counted"; else nok "reserve ≠ gross − fund" "reserve=$RES8 gross=$G8 fund=$I8"; fi
# No liquidation happened (timers paused): the book did not FALL — a seize
# would repay ≈ $90k of it — it ROSE, by exactly the interest the crash
# stamp's scan accrued since the fill (task 1788736589; the stored book was
# frozen at the fill principal until a scan or sweep accrued it). Bounded on
# the replica's own clocks: the loan landed AFTER the release stamp's scan
# (CN8, the requote's message is later) and was accrued TO the crash stamp's
# scan instant (CN8b), so the rise is ≤ the 5 % interest of L over CN8b − CN8.
L8ACC=$(interest_ns "$L8" $(( CN8b - CN8 )) "$APR_ICPUSD")
if [ "${L8b:-0}" -gt "$L8" ] && [ $(( L8b - L8 )) -le "$L8ACC" ]; then ok "loan book unchanged bar the stamp's accrual (\$$(from_e8 "$L8") → \$$(from_e8 "$L8b"): +$(( L8b - L8 )) units, ≤ $L8ACC = the 5 % interest of the $(( (CN8b - CN8) / 1000000 )) ms from the release scan to the crash scan): no liquidation happened — the mark-down precedes the loss, and the crash stamp's scan ACCRUED the book"; else nok "loan book moved beyond accrual (a liquidation ran?) or did not accrue (the mark update's scan no longer accrues?)" "$L8 → $L8b (bound $L8ACC over $(( CN8b - CN8 )) ns)"; fi
# NAV = H + (L − R) − W, exactly, and valuePerLP fell by R / supply beyond the
# BTC mark-down of the held basket.
QB8b=$(liq7 $BOB_ID); H8b=$(lpq "$QB8b" vaultHoldingsUsd); N8b=$(lpq "$QB8b" vaultNavUsd); W8b=$(pyf)
EXP_N8=$(awk -v h="$H8b" -v l="$L8b" -v r="$RES8" -v w="${W8b:-0}" 'BEGIN{ printf "%.0f", h + l - r - w }')
if [ "$N8b" = "$EXP_N8" ]; then ok "NAV == H + (L − R) − W exactly (\$$(from_e8 "$H8b") + \$$(from_e8 "$L8b") − \$$(from_e8 "$RES8") − \$$(from_e8 "${W8b:-0}") = \$$(from_e8 "$N8b"))"; else nok "NAV ≠ H + L − R − W" "nav=$N8b expected=$EXP_N8 (H=$H8b L=$L8b R=$RES8 W=${W8b:-0})"; fi
V8b=$(vv); SUP8=$(echo "$V8b" | field lpSupply); VPL8b=$(echo "$V8b" | field valuePerLP)
# Fixed.div FLOORS: int(), not %.0f (which rounds), or face reads a unit high.
VPL_FACE=$(awk -v h="$H8b" -v l="$L8b" -v w="${W8b:-0}" -v s="$SUP8" 'BEGIN{ printf "%d", int((h + l - w) * 100000000 / s) }')
if awk -v a="$VPL8b" -v f="$VPL_FACE" -v r="$RES8" -v s="$SUP8" 'BEGIN{ d = f - a; e = r * 100000000 / s; exit (d > 0 && d <= e + 2 && d >= e - 2 ? 0 : 1) }'; then
  ok "valuePerLP marked down by R / supply below face ($(from_e8 "$VPL_FACE") → $(from_e8 "$VPL8b"))"
else nok "valuePerLP not marked down by the reserve" "face=$VPL_FACE actual=$VPL8b R=$RES8 supply=$SUP8"; fi
# Disclosure: bob's share of the reserve is what his NAV is short of face.
BOBLP8=$(lpq "$QB8b" lpBalance)
if near "$(lpq "$QB8b" provisionedLossUsd)" "$(awk -v b="$BOBLP8" -v s="$SUP8" -v r="$RES8" 'BEGIN{printf "%.0f", b/s*r}')" 0.0001 && [ "$(lpq "$QB8b" vaultImpairmentReserveUsd)" = "$RES8" ]; then
  ok "getMaxInstantWithdraw discloses the reserve (\$$(from_e8 "$RES8")) and bob's share of it (\$$(from_e8 "$(lpq "$QB8b" provisionedLossUsd)"))"
else nok "disclosure fields" "$QB8b"; fi

# The exiter does NOT escape the loss: bob's max exit at this NAV pays the
# PROVISIONED value per share (burned × valuePerLP × 0.996), strictly less
# than face by his share of the reserve × 0.996.
CAPLP8=$(lpq "$QB8b" withdrawableNowLp); CAPUSD8=$(lpq "$QB8b" withdrawableNowUsd)
ASK8=$(underask "$CAPLP8")   # the Earn card's figure: the cap less the 0.01 % drift allowance (task 1788746837, §7's note)
R8W=$(mdx_lp_withdraw $BOB_ID "${ASK8}")
# Basket value at the 35k mark (only BTC + cash are held).
PAID8=$(awk -v b="$(echo "$R8W" | field btc)" -v u="$(echo "$R8W" | field icpusd)" 'BEGIN{ printf "%.0f", b*35000 + u }')
PROV_PAY=$(awk -v x="$ASK8" -v v="$VPL8b" 'BEGIN{ printf "%.0f", x*v/100000000*0.996 }')
FACE_PAY=$(awk -v x="$ASK8" -v v="$VPL_FACE" 'BEGIN{ printf "%.0f", x*v/100000000*0.996 }')
EXP8W=$(echo "$CAPUSD8 * $ASK8 / $CAPLP8" | bc)   # the asked slice of the quote (±$0.001: leg floors; seconds of accrual on a re-stamp)
if echo "$R8W" | grep -q "redeemed =" && awk -v p="$PAID8" -v c="$EXP8W" 'BEGIN{d = p - c; exit ((d < 0 ? -d : d) <= 100000 ? 0 : 1)}' && near "$PAID8" "$PROV_PAY" 0.0001; then
  ok "exiter paid the PROVISIONED NAV (\$$(from_e8 "$PAID8") for $(from_e8 "$ASK8") LP — the cap less the allowance, settled under the re-stamp — == burned × valuePerLP × 0.996)"
else nok "exit payout ≠ provisioned NAV × 0.996" "paid=$PAID8 expected=$EXP8W quoted=$CAPUSD8 provisioned=$PROV_PAY :: $R8W"; fi
if awk -v p="$PAID8" -v f="$FACE_PAY" -v x="$ASK8" -v s="$SUP8" -v r="$RES8" 'BEGIN{ short = f - p; ex = x/s*r*0.996; exit (short > 0 && short >= ex*0.999 && short <= ex*1.001 + 100000 ? 0 : 1) }'; then
  ok "…and \$$(from_e8 "$(awk -v f="$FACE_PAY" -v p="$PAID8" 'BEGIN{printf "%.0f", f-p}')") less than face value — the exiter does not escape the expected loss"
else nok "exiter escaped the provision" "paid=$PAID8 face=$FACE_PAY R=$RES8"; fi
# Stayers: alice's NAV is untouched by bob's exit (F2 still holds under the
# reserve — the provision is per share, the exit removes only bob's shares).
QA8=$(liq7 alice); ANAV8_pre=$(awk -v a="$(lpq "$QA8" lpBalance)" -v s="$SUP8" -v n="$N8b" 'BEGIN{printf "%.0f", a/s*n}')
if awk -v a="$(lpq "$QA8" totalNavUsd)" -v b="$ANAV8_pre" 'BEGIN{exit (a >= b && a <= b*1.001 ? 0 : 1)}'; then ok "F2 under the reserve: alice's NAV untouched by bob's exit (\$$(from_e8 "$ANAV8_pre") → \$$(from_e8 "$(lpq "$QA8" totalNavUsd)"))"; else nok "alice's NAV moved on bob's exit" "$ANAV8_pre → $(lpq "$QA8" totalNavUsd)"; fi

# RELEASE on repayment: the pool closes at the SAME 35k mark (3 BTC sell for
# ≈ $105k, repaying the ≈ $90k loan). The provision vanishes with the loan —
# NAV moves only by the spread the vault earned, and no LP was permanently
# taxed. The mark re-stamp after the close is what refreshes the scan (as an
# oracle tick would); the loan book itself is read live. The AMM ladder must
# be re-quoted at the 35k mark first — the close SELLS into it (as release7) —
# and the vault is BTC-heavy after the crash, so the inventory skew posts its
# bid ≈ 6% under the mark: a 5% allowance drops the market sell as "no
# liquidity" (order.nofill), 15% fills it. That discount is the pool's cost
# of repaying, not the vault's — the vault buys BTC below the mark.
release8() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 35000.0) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
release8
R8C=$(asL closePosition "($PID8, \"BTC-ICPUSD\", $(e8 0.15) : nat, null)")
# The staged sell FILLS on the release stamp itself — AFTER that call's own
# full provision scan ran — and the fill's repayment re-provisions the pool
# INCREMENTALLY in the same message (task 1788480502: one getHealth on the
# mutated pool, the aggregate adjusted by the delta), so the very next query
# already reads the released provision. ONE stamp; a second one used to be
# needed to re-scan, and it would mask a regression here.
release8
Q8c=$(imp); L8c=$(echo "$Q8c" | field loanBookUsd)
if awk -v a="${L8c:-0}" -v b="$L8b" 'BEGIN{exit (a < b/2 ? 0 : 1)}'; then ok "loan repaid on close (lent out \$$(from_e8 "$L8b") → \$$(from_e8 "$L8c"))"; else nok "close did not repay (precondition)" "close: $(echo "$R8C" | head -c 300) :: $Q8c"; fi
if [ "$(echo "$Q8c" | field reserveUsd)" = "0" ] && [ "$(echo "$Q8c" | field grossExpectedLossUsd)" = "0" ] && [ "$(echo "$Q8c" | field impairedLoans)" = "0" ] && [ "$(echo "$Q8c" | field impairedDebtUsd)" = "0" ] && [ "$(echo "$Q8c" | field impairedCollateralUsd)" = "0" ]; then ok "provision released on repayment: reserve 0, gross 0, no impaired loans, impaired D/C 0 — the incremental release drops the priced figures with the EL (price unchanged at 35k)"; else nok "provision did not release on repayment" "$Q8c"; fi
QA8c=$(liq7 alice)
if [ "$(lpq "$QA8c" vaultNavUsd)" = "$(awk -v h="$(lpq "$QA8c" vaultHoldingsUsd)" -v l="$(lpq "$QA8c" vaultLentOutUsd)" -v w="$(pyf)" 'BEGIN{printf "%.0f", h + l - w}')" ]; then ok "NAV back to H + L − W with no reserve"; else nok "NAV after release" "$QA8c"; fi
# ── 8b. WRITE-OFF classification for the lock index (task 1788752774) ──
# The lock settle (1788727876) measures a repayment as the shrink of the
# per-token loan-book units, and VaultLock.settle treated EVERY shrink as
# cash arriving for the loan claimants — so absorbBadDebt's UNCOVERED
# residual (the slice the insurance fund could not pay: a pure loss, no cash)
# scaled the locks down and handed a fully locked LP instant cap out of the
# stayers' cash. Now the write-off site nets the uncovered USD out of the
# shrink before the settle: what IS cash keeps scaling the locks — the seize
# (collateral into the basket in kind) and the fund's covered slice — the
# loss moves no lock. Fixture at the 35k mark, same vault: two fresh longs
# (3 BTC that will be written off, 2 BTC that survives so loan value remains
# and the consistency clamp keeps slack), bob's MAX exit locks his remaining
# shares (cap $0), then BTC crashes to 8k and one batch seizes + writes off
# the first pool. bob's cap must equal his slice of the CASH-BACKED shrink
# only: e_bob' = R_cash × λ_bob / Lx_pre where, on the post observables (the
# lib's own view: the loss lands one-share-class, then the cash pro rata to
# the post-loss claim), λ_bob = s_bob × NAV'/S' (he was fully locked: e = 0)
# and Lx_pre = Lx' + R_cash — with R_cash = (L_before − L_after) − ΔuncoveredBadDebtUsd.
# The RED control is the same formula with R_total: ≈ 12 % higher here.
ins8() { yes | adm getInsuranceFund '()' 2>&1; }
adm setTestBalance "(principal \"$LIQ_P\", \"ICPUSD\", $(e8 122000.0) : nat)" >/dev/null
R8b=$(asL createMarginPool '("vlp writeoff", false)'); PID8b=$(echo "$R8b" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | tail -1)
R8c=$(asL createMarginPool '("vlp stayer", false)');   PID8c=$(echo "$R8c" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | tail -1)
asL fundMarginPool "(${PID8b:-0}, $(e8 60000.0) : nat)" >/dev/null
asL fundMarginPool "(${PID8c:-0}, $(e8 62000.0) : nat)" >/dev/null
asL openPosition "(${PID8b:-0}, \"BTC-ICPUSD\", variant { buy }, $(e8 3.0) : nat, $(e8 0.15) : nat, null)" >/dev/null
asL openPosition "(${PID8c:-0}, \"BTC-ICPUSD\", variant { buy }, $(e8 2.0) : nat, $(e8 0.15) : nat, null)" >/dev/null
release8
release8
Q8p=$(liq7 $BOB_ID); L8p=$(lpq "$Q8p" vaultLentOutUsd)
if awk -v l="${L8p:-0}" 'BEGIN{exit (l >= 5000000000000 ? 0 : 1)}'; then ok "8b fixture: two longs live at the 35k mark (\$$(from_e8 "$L8p") lent: a 3 BTC pool to be written off, a 2 BTC pool that survives)"; else nok "8b fixture: the loans did not land (precondition)" "$Q8p"; fi
QB8p=$(liq7 $BOB_ID); CAP8p=$(lpq "$QB8p" withdrawableNowLp); CAP8pUSD=$(lpq "$QB8p" withdrawableNowUsd); BAL8p=$(lpq "$QB8p" lpBalance)
ASK8b=$(underask "$CAP8p")   # the Earn card's max: the cap less the 0.01 % drift allowance (task 1788746837, §7's note)
R8bW=$(mdx_lp_withdraw $BOB_ID "$ASK8b")
QB8q=$(liq7 $BOB_ID); LKq=$(lpq "$QB8q" lockedLp); CAP8qUSD=$(lpq "$QB8q" withdrawableNowUsd); UNL8q=$(( $(lpq "$QB8q" lpBalance) - LKq ))
# Bar the allowance's residue (§7's shape): ≈ a × his balance stays unlocked
# with a cap ≈ a × the one quoted; the rest is locked and loan claim.
if echo "$R8bW" | grep -q "redeemed =" && [ "${LKq:-0}" != "0" ] && near "$UNL8q" "$(echo "${BAL8p:-0} * $LP_DRIFT_ALLOWANCE_PPM / 1000000" | bc)" 0.001 && awk -v c="${CAP8qUSD:-0}" -v r="${CAP8pUSD:-0}" 'BEGIN{exit (c > 0 && c <= r * 0.00011 ? 0 : 1)}'; then ok "8b: bob's Earn-card max exit (the cap less the 0.01 % allowance) locks his remaining $(from_e8 "$LKq") LP bar the allowance's residue ($(from_e8 "$UNL8q") LP unlocked, cap \$$(from_e8 "$CAP8qUSD") of the \$$(from_e8 "$CAP8pUSD") quoted) — his NAV is loan claim bar that residue"; else nok "8b: under-asked max exit did not lock bob bar the residue (precondition)" "$R8bW :: $QB8q"; fi
# The crash: the 3 BTC pool is under water (3 × 8k < its ≈ $45k debt), the 2
# BTC pool stays healthy (2 × 8k × 0.9 ≈ $14.4k against ≈ $10k, h ≈ 1.4).
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 8000.0) : nat)" >/dev/null
QB8r=$(liq7 $BOB_ID); L8r=$(lpq "$QB8r" vaultLentOutUsd); I8r=$(ins8); UBD8r=$(echo "$I8r" | field uncoveredBadDebtUsd); BUF8r=$(echo "$I8r" | field bufferUsd)
NLIQ8=$(asL getMyMarginPools '()' | tr -d '_\n' | tr -s ' ' | grep -o 'isLiquidatable = true' | wc -l | tr -d ' ')
# A mark move alone releases nothing: bob's lock is byte-identical, and his
# cap (it scales with H, which the crash shrank) stays within the residue.
if [ "${NLIQ8:-0}" = "1" ] && [ "$(lpq "$QB8r" lockedLp)" = "${LKq:-x}" ] && awk -v c="$(lpq "$QB8r" withdrawableNowUsd)" -v q="${CAP8qUSD:-0}" 'BEGIN{exit (c <= q ? 0 : 1)}'; then ok "8b: at the 8k mark exactly one pool is liquidatable, the other performs; bob's lock is unchanged by the mark move (a mark move alone releases nothing) and his cap stays within the allowance residue (\$$(from_e8 "$(lpq "$QB8r" withdrawableNowUsd)"))"; else nok "8b: crash precondition" "liquidatable pools=${NLIQ8:-?} lock ${LKq:-?}→$(lpq "$QB8r" lockedLp) bobCap=$(lpq "$QB8r" withdrawableNowUsd) residue=${CAP8qUSD:-?}"; fi
adm adminRunLiquidationBatch '()' >/dev/null 2>&1
QB8s=$(liq7 $BOB_ID); V8s=$(vv); I8s=$(ins8); QA8s=$(liq7 alice)
L8s=$(lpq "$QB8s" vaultLentOutUsd); UBD8s=$(echo "$I8s" | field uncoveredBadDebtUsd)
H8s=$(lpq "$QB8s" vaultHoldingsUsd); N8s=$(lpq "$QB8s" vaultNavUsd); SB8=$(lpq "$QB8s" lpBalance); S8s=$(echo "$V8s" | field lpSupply)
LKs=$(lpq "$QB8s" lockedLp); VLKs=$(lpq "$QB8s" vaultLockedLp); CAP8s=$(lpq "$QB8s" withdrawableNowUsd)
RT8=$(( ${L8r:-0} - ${L8s:-0} )); U8=$(( ${UBD8s:-0} - ${UBD8r:-0} )); RC8=$(( RT8 - U8 ))
if [ "$U8" -gt 0 ] && [ "$RC8" -gt 0 ] && [ "${L8s:-0}" -gt 0 ] && [ "${L8s:-0}" -lt "${L8r:-0}" ]; then ok "8b: the batch wrote off \$$(from_e8 "$U8") UNCOVERED (fund \$$(from_e8 "${BUF8r:-0}") + the penalty covered the rest) of a \$$(from_e8 "$RT8") shrink — \$$(from_e8 "$RC8") of it cash-backed (seize in kind + covered); the 2 BTC loan (\$$(from_e8 "$L8s")) survives"; else nok "8b: no uncovered write-off with a surviving loan (precondition)" "L ${L8r:-?}→${L8s:-?} uncovered ${UBD8r:-?}→${UBD8s:-?} fund ${BUF8r:-?}"; fi
# bc, not awk: the products run past 2^53. Integer bc truncates — fine at 1e12.
cap8exp() { bc <<EOF
scale=0
r=$1
s=${SB8:-0}
n=${N8s:-0}
sup=${S8s:-1}
lx=${N8s:-0}-${H8s:-0}
(r*s*n/sup)/(lx+r)*996/1000
EOF
}
EXP8=$(cap8exp "$RC8"); EXP8old=$(cap8exp "$RT8")
if [ "${VLKs:-0}" -gt 0 ] && [ "$(echo "${VLKs:-0} * ${N8s:-0} * 10 <= ${S8s:-1} * (${N8s:-0} - ${H8s:-0}) * 9" | bc)" = "1" ]; then ok "8b: the surviving loan keeps the consistency clamp slack (Λ·NAV ≤ 0.9·S·Lx after the batch) — the assertion below reads the classification, not the clamp"; else nok "8b: clamp fixture (Λ·NAV vs S·Lx)" "Λ=${VLKs:-?} NAV=${N8s:-?} S=${S8s:-?} H=${H8s:-?}"; fi
if [ "${EXP8:-0}" -gt 0 ] && near "${CAP8s:-0}" "$EXP8" 0.01 && awk -v c="${CAP8s:-0}" -v o="${EXP8old:-0}" 'BEGIN{exit (c < o * 0.97 ? 0 : 1)}'; then ok "8b: after the write-off bob's cap == his slice of the CASH-BACKED shrink only (\$$(from_e8 "$CAP8s") ≈ \$$(from_e8 "$EXP8")); the \$$(from_e8 "$U8") uncovered loss moved no lock — classified as a repayment it would have quoted \$$(from_e8 "$EXP8old")"; else nok "8b: the uncovered write-off scaled bob's lock as if its USD had come back as cash" "cap=\$$(from_e8 "${CAP8s:-0}") expected=\$$(from_e8 "${EXP8:-0}") (repayment classification: \$$(from_e8 "${EXP8old:-0}"); R_total=$RT8 U=$U8 R_cash=$RC8 s=$SB8 NAV=$N8s S=$S8s H=$H8s)"; fi
if [ "${LKs:-0}" -gt 0 ] && [ "${LKs:-0}" -lt "${LKq:-0}" ]; then ok "8b: bob's lock shrank by the cash-backed slice but survives ($(from_e8 "$LKq") → $(from_e8 "$LKs") LP locked)"; else nok "8b: bob's lock after the write-off" "locked ${LKq:-?} → ${LKs:-?}"; fi
if near "$(lpq "$QB8s" totalNavUsd)" "$(echo "${SB8:-0} * ${N8s:-0} / ${S8s:-1}" | bc)" 0.0001; then ok "8b: the loss itself lands one-share-class — bob's NAV == s_bob × NAV'/S' (\$$(from_e8 "$(lpq "$QB8s" totalNavUsd)")): disclosed as the residual in amm-vault-design §5"; else nok "8b: bob's NAV ≠ s × NAV/S" "$QB8s"; fi
if near "$(( $(lpq "$QA8s" withdrawableNowUsd) + ${CAP8s:-0} ))" "$(echo "${H8s:-0} * 996 / 1000" | bc)" 0.001; then ok "8b: Σ caps == H × 0.996 through the write-off (alice's + bob's = \$$(from_e8 "$(( $(lpq "$QA8s" withdrawableNowUsd) + ${CAP8s:-0} ))") of \$$(from_e8 "$H8s") held)"; else nok "8b: Σ caps ≠ H × 0.996" "alice=$(lpq "$QA8s" withdrawableNowUsd) bob=${CAP8s:-?} H=${H8s:-?}"; fi
# HYGIENE: unwind the fixture and clear the fund so nothing global is stranded.
mdx_lp_withdraw $BOB_ID "$(asBob getMyVaultLp '()' | tr -d '_' | grep -oE '[0-9]+' | head -1)" >/dev/null 2>&1
mdx_lp_withdraw alice "$(asA getMyVaultLp '()' | tr -d '_' | grep -oE '[0-9]+' | head -1)" >/dev/null 2>&1
adm resetExchange '()' >/dev/null 2>&1

echo ""
echo "── 9. A closed SHORT returns the loan book to exactly 0 — accrue before sizing + the capped base-residue cash settle (task 1788516128) ──"
# §7's LONG close repays in full because deleveragePool accrues before it reads
# the debt (1788515291). A SHORT had a second gap that fix does not reach:
# closePosition sized the buy-back from base held − base DEBT as of the LAST
# accrual touch (the 30 s sweep — it never accrued itself), and the fill lands
# in a LATER message, so the pool bought exactly the stale size, repaid it, and
# kept the interest booked since as BASE debt it held no base to pay — while
# holding the quote the buy-back did not spend. Observed pre-fix on this very
# fixture: 16 BTC base units ($0.008 at 50k) after a 21 s short — and with
# timers running the residue kept vaultLentOutUsd > 0 forever (the redeem-side
# mark gate armed on every pend), the "dust shorts unclosable" shape recorded
# atop lib/BorrowEngine.mo. Now closePosition accrues before sizing, and the
# interest that books between the call and the settlement message is settled
# from the pool's free quote at the mark, rounded UP against the borrower,
# under BASE_RESIDUE_CASH_SETTLE_CAP_USD ($5) — a real short is never
# cash-settled (the opening fill itself runs deleveragePool against the full
# 3 BTC debt and leaves it in kind: that is the "short live" precondition).
# Timers stay PAUSED so no sweep accrues for us: the seconds of wall-clock
# between the open's fill and the close's call (the accrue-before-sizing half)
# and between the close's call and its releasing restamp (the cash-settle
# half) are what book the interest under test — ≈ 0.76 units/s on 3 BTC at 8 %.
adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat)" >/dev/null 2>&1
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1
adm setAutoFuel '(false)' >/dev/null 2>&1
for t in BTC ETH SOL ICP ICPUSD; do
  for p in "$A" "$BOB_P" "$AMM" "$LIQ_P" "$CAROL_P"; do adm setTestBalance "(principal \"$p\", \"$t\", 0 : nat)" >/dev/null; done
done
adm setTestBalance "(principal \"$A\",     \"BTC\",    $(e8 10.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$A\",     \"ICPUSD\", $(e8 300000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$LIQ_P\", \"ICPUSD\", $(e8 60000.0) : nat)"  >/dev/null
mdx_lp_deposit alice "BTC-ICPUSD" "$(e8 10.0)" "$(e8 300000.0)" >/dev/null
release7
R9=$(asL createMarginPool '("vlp short", false)')
PID9=$(echo "$R9" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | tail -1)
asL fundMarginPool "($PID9, $(e8 60000.0) : nat)" >/dev/null
O9=$(asL openPosition "($PID9, \"BTC-ICPUSD\", variant { sell }, $(e8 3.0) : nat, $(e8 0.05) : nat, null)")
if mdx_ok "$O9"; then ok "short staged: 3 BTC sell against \$60k (2.5×)"; else nok "openPosition(sell) refused (precondition)" "$O9"; fi
release7
Q9=$(liq7 alice); L9=$(lpq "$Q9" vaultLentOutUsd)
# 3 BTC of base debt at the 50k mark = $150k; the opening fill's deleveragePool
# saw a real short far over the cap and left it in kind.
if awk -v l="${L9:-0}" 'BEGIN{exit (l >= 15000000000000 ? 0 : 1)}'; then ok "short live: \$$(from_e8 "$L9") of BTC lent out — a real short is NOT cash-settled by the fill-time deleverage (cap)"; else nok "short not issued / cash-settled (precondition)" "$Q9"; fi
sleep 5   # interest books on the 3 BTC debt between the open's fill and the close's call
C9=$(asL closePosition "($PID9, \"BTC-ICPUSD\", $(e8 0.05) : nat, null)")
if mdx_ok "$C9"; then ok "closePosition staged the buy-back (sized on the ACCRUED debt)"; else nok "closePosition refused" "$C9"; fi
sleep 5   # ...and between the call and the releasing restamp: the settlement-message residue the cash settle covers
release7
Q9b=$(liq7 alice)
if [ "$(lpq "$Q9b" vaultLentOutUsd)" = "0" ]; then ok "loan book back to exactly \$0 after the SHORT close (\$$(from_e8 "$L9") → \$0: call-time interest bought back, in-flight interest cash-settled)"; else nok "short close left a base residue (closePosition must accrue before sizing; deleveragePool must settle the in-flight interest from quote)" "vaultLentOutUsd=$(lpq "$Q9b" vaultLentOutUsd) :: $Q9b"; fi
D9=$(asL getMyMarginPools '()' | tr -d '\n' | tr -s ' ')
# getMyMarginPools prints `"principal" = "<text>"` (quoted keyword, a Text) and
# the pool's health record; its debtUsd reads the same loan book the vault does.
if echo "$D9" | grep -q 'debtUsd = 0 :'; then ok "pool's own health reads debtUsd = 0 (no dust record survives — the unit test pins the entry deletion)"; else nok "pool still carries debt" "$(echo "$D9" | grep -oE 'debtUsd = [0-9_]+')"; fi
POOLP9=$(echo "$D9" | grep -oE '"principal" = "[a-z0-9-]+"' | head -1 | grep -oE '"[a-z0-9-]+"$' | tr -d '"')
B9=$(adm getTestBalance "(principal \"${POOLP9:-aaaaa-aa}\", \"BTC\")" | tr -d '_' | grep -oE '[0-9]+' | head -1)
if [ -n "${POOLP9:-}" ] && [ "${B9:-x}" = "0" ]; then ok "pool holds no BTC after the close — flat, not long the residue (it was settled, not bought)"; else nok "pool left holding BTC after the close" "btc=${B9:-?} pool=${POOLP9:-?}"; fi
if [ "$(lpq "$Q9b" vaultNavUsd)" = "$(awk -v h="$(lpq "$Q9b" vaultHoldingsUsd)" -v w="$(pyf)" 'BEGIN{printf "%.0f", h - w}')" ]; then ok "NAV == holdings − W again: no loan claim left on the book"; else nok "NAV ≠ holdings after the close" "$Q9b"; fi
C9b=$(asL closePosition "($PID9, \"BTC-ICPUSD\", $(e8 0.05) : nat, null)")
if echo "$C9b" | grep -q "No open position"; then ok "a second close finds nothing to close (derived size 0 — the position is genuinely flat)"; else nok "second close should find no position" "$C9b"; fi
# HYGIENE: unwind the fixture so nothing global is stranded.
mdx_lp_withdraw alice "$(asA getMyVaultLp '()' | tr -d '_' | grep -oE '[0-9]+' | head -1)" >/dev/null 2>&1
adm resetExchange '()' >/dev/null 2>&1

echo "── 10. Sealed LP requests: stage now, settle at the first POST-request NAV (task 1788503312) ──"
# Operator decision 2026-09-06 (docs/amm-vault-design.md §5 "Sealed LP
# requests"). The per-pool feed cadence is 60 s by code and equalled the 60 s
# mint grace, so the doors flickered stale — and a grace is only ever a window
# a depositor can mint through against a mark the market has left. Now a
# deposit / withdrawal is STAGED (funds or shares reserved at request time)
# and settles at the first NAV whose basket marks ALL postdate the request:
# the price-postdates-entry rule parked entries release on. Timers stay
# PAUSED, so nothing settles until a re-stamp (setAmmRefPrice stamps the
# release reference like a fetch) and a requote (the releasing pass) — the
# sealed suites' idiom — which is exactly what makes "mark moves AFTER the
# request" stageable: the move IS the postdating mark. Only BTC + cash are
# held, so a request waits on BTC-ICPUSD alone.
mine10()  { yes | icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyStagedLpRequests '()' --query 2>&1 | tr -d '_\n' | tr -s ' '; }   # a query in the did; --query keeps the read ~0.1 s (an update-class read cost 0.3-1.4 s and lost §10(e)'s window)
liq10()   { yes | icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMaxInstantWithdraw '()' 2>&1 | tr -d '_\n' | tr -s ' '; }
resv10()  { yes | icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyReservedBalance "(\"$2\")" 2>&1 | tr -d '_' | grep -oE '[0-9]+' | head -1; }
lpof10()  { yes | icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyVaultLp '()' 2>&1 | tr -d '_' | grep -oE '[0-9]+' | head -1; }
stamp10() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 "$1") : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
# USD value of a redeemed basket at mark $2 (only BTC + cash are held).
bsk10()   { local b u; b=$(echo "$1" | field btc); u=$(echo "$1" | field icpusd); awk -v b="${b:-0}" -v u="${u:-0}" -v px="$2" 'BEGIN{ printf "%.0f", b*px + u }'; }
reqid10() { echo "$1" | tr -d '_\n' | tr -s ' ' | grep -oE 'record \{ id = [0-9]+' | grep -oE '[0-9]+' | head -1; }
adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat)" >/dev/null 2>&1
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1
adm setAutoFuel '(false)' >/dev/null 2>&1
for t in BTC ETH SOL ICP ICPUSD; do
  for p in "$A" "$BOB_P" "$AMM" "$LIQ_P" "$CAROL_P"; do adm setTestBalance "(principal \"$p\", \"$t\", 0 : nat)" >/dev/null; done
done
adm setTestBalance "(principal \"$A\",       \"BTC\",    $(e8 10.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$A\",       \"ICPUSD\", $(e8 300000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$BOB_P\",   \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$CAROL_P\", \"ICPUSD\", $(e8 20000.0) : nat)"  >/dev/null
# Genesis through the controller's IMMEDIATE door (seedAmmPool — alice is a
# controller; the seed scripts' shape, under these paused timers): 10 BTC +
# $300k = 800k LP at 1.0. Deliberately NOT the staged helper here: a staged
# genesis would itself arm BTC-ICPUSD's GEPTOR, and with the timers paused
# nothing fires it, so (a)'s "the request ARMED a GEPTOR (null → set)" pin
# would find it already set.
icp canister call --candid "$MDX_CANDID" --identity alice backend seedAmmPool "(\"BTC-ICPUSD\", $(e8 10.0) : nat, $(e8 300000.0) : nat)" >/dev/null 2>&1
GEP0=$(adm getReleaseInfo '("BTC-ICPUSD")' --query | tr -d '\n' | tr -s ' ')

# (a) A deposit staged BEFORE a price move settles at the POST-move NAV.
S1=$(asBob depositLp "(\"BTC-ICPUSD\", 0 : nat, $(e8 100000.0) : nat)")
ID1=$(reqid10 "$S1")
if mdx_ok "$S1" && [ -n "$ID1" ]; then ok "bob staged a \$100k deposit (#$ID1) — the reply is the REQUEST, not a mint"; else nok "depositLp refused" "$S1"; fi
if echo "$S1" | tr -d '\n' | tr -s ' ' | grep -q 'waitingOn = vec { "BTC-ICPUSD" }'; then ok "it waits on the held basket's market (BTC-ICPUSD) — no mark postdates it yet"; else nok "waitingOn" "$(echo "$S1" | tr -d '\n' | tr -s ' ')"; fi
GEP1=$(adm getReleaseInfo '("BTC-ICPUSD")' --query | tr -d '\n' | tr -s ' ')
if echo "$GEP0" | grep -q 'geptorDeadlineNs = null' && echo "$GEP1" | grep -q 'geptorDeadlineNs = opt'; then ok "the request ARMED a GEPTOR on BTC-ICPUSD (geptorDeadlineNs null → set): settlement is one fetch away, not the 60 s cadence"; else nok "GEPTOR not armed by the request" "before=$GEP0 after=$GEP1"; fi
if [ "$(resv10 $BOB_ID ICPUSD)" = "$(e8 100000.0)" ]; then ok "the \$100k leg is RESERVED at request time (getMyReservedBalance)"; else nok "reservation" "$(resv10 $BOB_ID ICPUSD)"; fi
IM1=$(asBob depositLp "(\"BTC-ICPUSD\", 0 : nat, $(e8 100000.0) : nat)")
if echo "$IM1" | grep -q "already pending"; then ok "a second deposit request is refused naming the pending one (one per owner per kind; the \$100k stays reserved for #$ID1)"; else nok "a second depositLp was accepted beside the pending request" "$IM1"; fi
adm adminRunStagedLp '()' >/dev/null
M1=$(mine10 $BOB_ID)
if echo "$M1" | grep -q 'pending = vec { record' && echo "$M1" | grep -q 'recent = vec {}'; then ok "the pass leaves it PENDING while no mark postdates the request (frozen marks, no settlement)"; else nok "settled without a postdating mark" "$M1"; fi
stamp10 55000.0   # the mark MOVES (+10%) after the request — this stamp is the postdating fetch
M1=$(mine10 $BOB_ID)
MINT1=$(echo "$M1" | grep -oE 'minted = [0-9]+' | grep -oE '[0-9]+' | head -1)
# Post-move NAV = 10 × 55k + 300k = $850k on 800k LP → $100k mints 94,117.65 LP; the pre-move mark would have minted 100,000.
if echo "$M1" | grep -q 'pending = vec {}' && near "$(from_e8 "${MINT1:-0}")" 94117.65 0.001; then ok "settled at the POST-move NAV: minted $(from_e8 "$MINT1") LP for \$100k, not the 100,000 the pre-move mark would have minted (no cheap shares)"; else nok "post-move settlement" "$M1"; fi
if [ "$(lpof10 $BOB_ID)" = "${MINT1:-x}" ]; then ok "bob's LP balance is exactly the settled mint"; else nok "LP balance ≠ mint" "$(lpof10 $BOB_ID) vs ${MINT1:-?}"; fi
if [ "$(resv10 $BOB_ID ICPUSD)" = "0" ]; then ok "reservation released at settlement"; else nok "reservation stuck" "$(resv10 $BOB_ID ICPUSD)"; fi

# (b) Symmetric: a withdrawal staged BEFORE a move DOWN redeems at the post-move NAV.
LPB=$(lpof10 $BOB_ID)
Q_BEFORE=$(liq10 $BOB_ID)
S2=$(asBob withdrawLp "(${LPB:-0} : nat)")
ID2=$(reqid10 "$S2")
if mdx_ok "$S2" && [ -n "$ID2" ]; then ok "bob staged a full withdrawal (#$ID2) of $(from_e8 "$LPB") LP"; else nok "withdrawLp refused" "$S2"; fi
Q_AFTER=$(liq10 $BOB_ID)
if [ -n "$Q_BEFORE" ] && [ "$Q_BEFORE" = "$Q_AFTER" ]; then ok "getMaxInstantWithdraw is byte-identical with a staged withdrawal pending (unmoved until settlement)"; else nok "instant quote moved on staging" "before=$Q_BEFORE after=$Q_AFTER"; fi
S2b=$(asBob withdrawLp "(1 : nat)")
if echo "$S2b" | grep -q "already pending"; then ok "a second withdrawal request is refused naming the pending one (one per owner per kind — the reserved shares cannot be staged twice)"; else nok "duplicate staging accepted" "$S2b"; fi
stamp10 50000.0   # the mark FALLS (−9%) after the request
M2=$(mine10 $BOB_ID)
B2=$(echo "$M2" | grep -oE 'redeemed = record \{[^}]*\}' | head -1)
V2=$(bsk10 "$B2" 50000)
# Post-move NAV = 10 × 50k + 400k = $900k on (800k + mint) LP; bob's shares × NAV/supply × 0.996. At the pre-move 55k mark it would have been NAV $950k.
EXP2=$(awk -v m="${MINT1:-0}" 'BEGIN{ s = 80000000000000 + m; printf "%.0f", m / s * 90000000000000 * 0.996 }')
PRE2=$(awk -v m="${MINT1:-0}" 'BEGIN{ s = 80000000000000 + m; printf "%.0f", m / s * 95000000000000 * 0.996 }')
if echo "$M2" | grep -q 'pending = vec {}' && near "$V2" "$EXP2" 0.002 && awk -v v="$V2" -v p="$PRE2" 'BEGIN{exit (v < p * 0.99 ? 0 : 1)}'; then ok "redeemed at the POST-move NAV: \$$(from_e8 "$V2") at the 50k mark (expected \$$(from_e8 "$EXP2"); the pre-move mark would have paid \$$(from_e8 "$PRE2"))"; else nok "post-move redemption" "got=$V2 exp=$EXP2 pre=$PRE2 :: $M2"; fi
if [ "$(lpof10 $BOB_ID)" = "0" ]; then ok "bob's shares are burned at settlement (balance 0)"; else nok "LP not burned" "$(lpof10 $BOB_ID)"; fi

# (c) A staged round trip at one mark is exactly −fee.
S3=$(asC depositLp "(\"BTC-ICPUSD\", 0 : nat, $(e8 20000.0) : nat)")
stamp10 50000.0
M3=$(mine10 $CAROL_ID)
MINT3=$(echo "$M3" | grep -oE 'minted = [0-9]+' | grep -oE '[0-9]+' | head -1)
LPC=$(lpof10 $CAROL_ID)
S4=$(asC withdrawLp "(${LPC:-0} : nat)")
stamp10 50000.0
M4=$(mine10 $CAROL_ID)
B4=$(echo "$M4" | grep -oE 'redeemed = record \{[^}]*\}' | head -1)
V4=$(bsk10 "$B4" 50000)
if [ -n "${MINT3:-}" ] && [ "${MINT3:-0}" -gt 0 ] && near "$V4" "$(e8 19920.0)" 0.0001; then ok "staged round trip == −fee: \$20,000 in (minted $(from_e8 "$MINT3") LP), \$$(from_e8 "$V4") out in kind at the same mark (\$19,920 = 0.996×)"; else nok "staged round trip" "mint=$MINT3 out=$V4 :: $M3 :: $M4"; fi
RC=$(echo "$M4" | grep -oE 'settledNs = [0-9]+' | wc -l | tr -d ' ')
if [ "$RC" = "2" ]; then ok "carol's outcome list carries both settlements (newest first, capped at 8)"; else nok "outcome list" "$M4"; fi

# (d) The outage backstop: frozen marks → the request stays pending, then the TTL cancels + refunds, fail-closed.
adm setTestBalance "(principal \"$CAROL_P\", \"ICPUSD\", $(e8 20000.0) : nat)" >/dev/null
S5=$(asC depositLp "(\"BTC-ICPUSD\", 0 : nat, $(e8 10000.0) : nat)")
ID5=$(reqid10 "$S5")
adm adminRunStagedLp '()' >/dev/null
M5=$(mine10 $CAROL_ID)
if [ -n "$ID5" ] && echo "$M5" | grep -q 'pending = vec { record { id = '"$ID5"; then ok "with the marks frozen the deposit (#$ID5) stays pending through the pass"; else nok "outage precondition" "$M5"; fi
adm setTestStagedLpExpiry "(${ID5:-0} : nat, 1 : int)" >/dev/null
adm adminRunStagedLp '()' >/dev/null
M5=$(mine10 $CAROL_ID)
if echo "$M5" | grep -q 'pending = vec {}' && echo "$M5" | grep -q 'cancelled = "no fresh marks for BTC-ICPUSD within 300 s'; then ok "TTL backstop: CANCELLED fail-closed, naming the stalled market and the 300 s window"; else nok "TTL cancel" "$M5"; fi
if [ "$(resv10 $CAROL_ID ICPUSD)" = "0" ] && [ "$(adm getTestBalance "(principal \"$CAROL_P\", \"ICPUSD\")" | tr -d '_' | grep -oE '[0-9]+' | head -1)" = "$(e8 20000.0)" ]; then ok "refunded: reservation released, \$20,000 balance intact (the funds never left the wallet)"; else nok "refund" "reserved=$(resv10 $CAROL_ID ICPUSD)"; fi
EV5=$(adm getRecentEvents '(50 : nat)' --query | tr -d '\n' | tr -s ' ')
if echo "$EV5" | grep -q "staged LP deposit #${ID5:-x} cancelled"; then ok "the cancellation is on the public tape (getRecentEvents, category vault)"; else nok "no tape row for the cancellation" "$(echo "$EV5" | head -c 300)"; fi
# ...and the withdrawal side: the shares come back — a fresh request redeems them.
S6=$(asA withdrawLp "($(e8 1000.0) : nat)")
ID6=$(reqid10 "$S6")
adm setTestStagedLpExpiry "(${ID6:-0} : nat, 1 : int)" >/dev/null
adm adminRunStagedLp '()' >/dev/null
M6=$(mine10 alice)
W6=$(mdx_lp_withdraw alice "$(e8 1000.0)")
if echo "$M6" | grep -q 'pending = vec {}' && echo "$M6" | grep -q 'cancelled = "' && echo "$W6" | grep -q "redeemed ="; then ok "an expired staged withdrawal (#$ID6) is cancelled and its 1,000 LP redeem through a fresh request (reservation released)"; else nok "withdrawal TTL / reservation release" "$M6 :: $W6"; fi

# (e) Owner cancel under the staged-order commit rule (task 1788731609).
# cancelStagedLpRequest is committed for the request's first 3 s
# (DEFERRED_COMMIT_NS) and, past the window, while a price fetch DISPATCHED
# after the request is in flight for ANY market it waits on (the H-23
# fetch-bound lock the staged-order cancels read — "stage, watch a faster
# feed, cancel if unfavourable" is the free look the rule closes); otherwise
# it cancels exactly as the TTL backstop does (reservation released,
# #cancelled("cancelled by owner"), the vault tape row). The request view
# carries the same verdict as cancelRefusal (opt text) so the Earn card's
# button follows the rule verbatim. Timers are paused, so no tick or GEPTOR
# fetch runs on its own; the in-flight window is STAGED with devStallSource
# #hold on one source + the admin fetch under an unreachable primary floor
# (test_oracle_time_bases §4's shape: quorum cannot close the fan-out, and
# the admin fetch's dispatch stamp — _fetchInFlight, task 3088525590 — holds
# until its fan-out finalizes). Window physics (tasks 1788745551 +
# 1788748485, measured on the seat replica): under #never the admin path
# closes its fan-out as #drained the moment every self-call has returned
# (~1.5 s — the answering providers' outcall latency), and the OLD #hold
# (a self-message loop parking one self-call's return) did not widen that:
# it starved the local replica's request serving until the hold cap (a
# query issued at +0.75 s answered 15 s later). The CURRENT #hold records
# nothing (as #never) AND makes the admin fetch leave its fan-out to the
# heartbeat's deadline sweep (main.mo devHoldsFanoutOpen): the fan-out — and
# the stamp — stay OPEN for PRICE_FANOUT_DEADLINE_NS (8 s) on a responsive
# replica (query rtt ~0.1 s throughout), the admin call returns at ~+1.5 s
# with a "left OPEN" err, and the sweep closes the fan-out `deadline`. So:
# a 50 ms poll for the OPEN fan-out (~+0.3 s), then the view and the cancel
# SEQUENTIALLY (~+0.5 s and ~+0.9 s of an 8 s window), then a poll for the
# sweep's close. The ⊘ branch is kept for a closed-in-between reading but
# is unreachable on a #dev venue short of a ~7 s stall of the test itself.
# That fetch is for BTC-ICPUSD; the locked request is an ETH-ICPUSD deposit
# (its set is {BTC-ICPUSD, ETH-ICPUSD} — a fetch on ANY waited-on market
# locks it), and with ETH's mark frozen the request can never settle
# whatever the BTC fetch does, so the SECOND cancel is the pin.
cancel10() { yes | icp canister call --candid "$MDX_CANDID" --identity "$1" backend cancelStagedLpRequest "($2 : nat)" 2>&1; }
adm setTestBalance "(principal \"$CAROL_P\", \"ICPUSD\", $(e8 20000.0) : nat)" >/dev/null
S7=$(asC depositLp "(\"BTC-ICPUSD\", 0 : nat, $(e8 10000.0) : nat)")
ID7=$(reqid10 "$S7")
if echo "$S7" | tr -d '\n' | tr -s ' ' | grep -q 'cancelRefusal = opt "Staged LP request is committed for settlement'; then ok "the request view carries cancelRefusal (opt text) naming the commit window at staging time"; else nok "cancelRefusal absent on the fresh request (method/field missing?)" "$(echo "$S7" | tr -d '\n' | tr -s ' ' | head -c 300)"; fi
C7a=$(cancel10 $CAROL_ID "${ID7:-0}")
if echo "$C7a" | grep -q 'committed for settlement' && echo "$C7a" | grep -q 'cancellable in a few seconds'; then ok "cancel inside 3 s is REFUSED: committed (the commit window)"; else nok "cancel inside the commit window not refused" "$C7a"; fi
C7x=$(cancel10 $BOB_ID "${ID7:-0}")
if echo "$C7x" | grep -q 'Not your staged LP request'; then ok "a non-owner cancel reads 'Not your staged LP request' (ownership first — no commit-phase leak)"; else nok "non-owner cancel" "$C7x"; fi
if [ "$(resv10 $CAROL_ID ICPUSD)" = "$(e8 10000.0)" ]; then ok "the refusals moved nothing: the \$10k leg is still reserved"; else nok "reservation moved by a refused cancel" "$(resv10 $CAROL_ID ICPUSD)"; fi
sleep 3.2
M7=$(mine10 $CAROL_ID)
if echo "$M7" | grep -q 'cancelRefusal = null'; then ok "past the window with no fetch in flight the view reads cancelRefusal = null"; else nok "cancelRefusal past the window" "$M7"; fi
C7b=$(cancel10 $CAROL_ID "${ID7:-0}")
M7=$(mine10 $CAROL_ID)
if mdx_ok "$C7b" && echo "$M7" | grep -q 'pending = vec {}' && echo "$M7" | grep -q 'cancelled = "cancelled by owner"'; then ok "cancel after 3 s with timers paused (no fetch in flight) SUCCEEDS: pending empty, outcome #cancelled(\"cancelled by owner\")"; else nok "owner cancel past the window" "$C7b :: $M7"; fi
if [ "$(resv10 $CAROL_ID ICPUSD)" = "0" ] && [ "$(adm getTestBalance "(principal \"$CAROL_P\", \"ICPUSD\")" | tr -d '_' | grep -oE '[0-9]+' | head -1)" = "$(e8 20000.0)" ]; then ok "refunded: reservation released, \$20,000 intact (the funds never left the wallet)"; else nok "refund on owner cancel" "reserved=$(resv10 $CAROL_ID ICPUSD)"; fi
EV7=$(adm getRecentEvents '(50 : nat)' --query | tr -d '\n' | tr -s ' ')
if echo "$EV7" | grep -q "staged LP deposit #${ID7:-x} cancelled — cancelled by owner"; then ok "the owner cancel is on the public tape (getRecentEvents, category vault)"; else nok "no tape row for the owner cancel" "$(echo "$EV7" | head -c 300)"; fi
C7c=$(cancel10 $CAROL_ID "${ID7:-0}")
if echo "$C7c" | grep -q 'not found'; then ok "a second cancel of the same id reads 'not found'"; else nok "double cancel" "$C7c"; fi
# The fetch-bound half of the lock.
stall10()  { adm devStallSource "(\"kraken\", variant { $1 })"; }
fo10()     { adm devGetFanout '("BTC")' --query | tr -d '_\n' | tr -s ' '; }
fonum10()  { printf '%s' "$1" | grep -oE "$2 = [0-9]+" | head -1 | awk '{print $3}'; }
foopen10() { printf '%s' "$1" | grep -oE "open = (true|false)" | head -1 | awk '{print $3}'; }
# The stall and the 99-source floor are venue-global: restore them at the
# end of the section AND on any exit, so a red run cannot strand a held
# source or frozen marks for the suites that share this feed.
s10e_teardown() { stall10 clear >/dev/null 2>&1; adm setTestMinSources '(null)' >/dev/null 2>&1; adm setTestXrcRate '("BTC", null, null)' >/dev/null 2>&1; adm setTestPendingJump '("BTC", null, null)' >/dev/null 2>&1; }
# on_exit, never a bare trap on EXIT: _scratch.sh (via _lib.sh) owns the ONE
# EXIT trap (hygiene's TRAP_HITS pin). A suite-level trap REPLACED the scratch
# cleanup, and the old "trap - EXIT" after the section unhooked it for the rest
# of the run. The explicit call at the section end runs the teardown early; the
# run at suite exit is four idempotent nulls (task 1788740563).
on_exit s10e_teardown
HR=$(stall10 hold)
if [ "$(printf '%s' "$HR" | tr -d '[:space:]')" != "()" ]; then
  echo -e "  ⊘ skipped: §10(e) fetch-bound lock — devStallSource #hold is not on this venue ($(echo "$HR" | tr -d '\n' | head -c 90)); the in-flight window cannot be staged here"
else
  adm setTestMinSources '(opt (99 : nat))' >/dev/null      # primary floor unreachable: quorum cannot close the fan-out
  adm setTestXrcRate '("BTC", null, null)' >/dev/null       # no test anchor for the fallback writer
  adm setTestPendingJump '("BTC", null, null)' >/dev/null
  adm createAmmPool '("ETH-ICPUSD")' >/dev/null 2>&1
  adm setAmmRefPrice "(\"ETH-ICPUSD\", $(e8 3000.0) : nat)" >/dev/null
  S8=$(asC depositLp "(\"ETH-ICPUSD\", 0 : nat, $(e8 10000.0) : nat)")
  ID8=$(reqid10 "$S8")
  if echo "$S8" | tr -d '\n' | tr -s ' ' | grep -q 'waitingOn = vec { "BTC-ICPUSD"; "ETH-ICPUSD" }'; then ok "an ETH-ICPUSD deposit (#$ID8) waits on {BTC-ICPUSD, ETH-ICPUSD}: the held leg AND its own market"; else nok "waiting set" "$(echo "$S8" | tr -d '\n' | tr -s ' ' | head -c 300)"; fi
  sleep 3.2   # past the commit window: whatever locks it below is the fetch's alone
  # Deterministic half first: devPoisonGeptorInFlight plants a GEPTOR arm on
  # BTC-ICPUSD with armedAt = now (> the request's ts, inside the arm's TTL)
  # — exactly what fetchInFlightSince reads for a GEPTOR's fetch — so the
  # view's refusal and the cancel's are pinned with no fan-out race; an age
  # past GEPTOR_INFLIGHT_TTL_NS lapses it (the #52.6 self-heal) and unlocks.
  adm devPoisonGeptorInFlight '("BTC-ICPUSD", 0 : int)' >/dev/null
  M8p=$(mine10 $CAROL_ID)
  C8p=$(cancel10 $CAROL_ID "${ID8:-0}")
  if echo "$M8p" | grep -q 'cancelRefusal = opt "Staged LP deposit is committed for settlement — a price fetch for BTC-ICPUSD dispatched after it was staged is in flight'; then ok "a post-request GEPTOR arm on BTC-ICPUSD (planted) shows on the view as the in-flight refusal naming that market"; else nok "view refusal under a planted arm" "$M8p"; fi
  if echo "$C8p" | grep -q 'a price fetch for BTC-ICPUSD dispatched after it was staged is in flight'; then ok "…and the cancel is REFUSED under it (a GEPTOR's fetch locks exactly as the admin fetch's does)"; else nok "cancel under a planted arm" "$C8p"; fi
  adm devPoisonGeptorInFlight '("BTC-ICPUSD", 120000000000 : int)' >/dev/null   # 120 s old: past the 60 s TTL → lapsed
  M8q=$(mine10 $CAROL_ID)
  if echo "$M8q" | grep -q 'cancelRefusal = null'; then ok "a lapsed arm (older than the guard TTL) no longer locks: cancelRefusal = null"; else nok "lapsed arm still locks" "$M8q"; fi
  # The live half: the admin fetch's own dispatch stamp.
  TMPD10=$(mktemp -d)
  ID0=$(fonum10 "$(fo10)" id); ID0=${ID0:-0}
  S0=$(date +%s)
  adm fetchAndSetRefPrice '("BTC-ICPUSD")' > "$TMPD10/fetch" 2>&1 &
  FPID=$!
  OPEN=0; FV=""; ID1=""; T1=0
  while [ $(( $(date +%s) - S0 )) -lt 6 ]; do
    FV=$(fo10); ID1=$(fonum10 "$FV" id)
    if [ "${ID1:-0}" -gt "$ID0" ] 2>/dev/null && [ "$(foopen10 "$FV")" = "true" ]; then OPEN=1; T1=$(( $(date +%s) - S0 )); break; fi
    kill -0 "$FPID" 2>/dev/null || break
    sleep 0.05   # the fan-out is open from dispatch: catch it early (~+0.3 s)
  done
  # Sequential again (task 1788748485): the window is the SWEEP's 8 s, not
  # the fleet's ~1.5 s — the view (a ~0.1 s query) first, then the cancel
  # (one ~0.3 s update). Both verdicts come from the one stagedLpCancelReason
  # (main.mo — stagedLpView and cancelStagedLpRequest call it with the same
  # inputs), so their order changes nothing about the truth, and a refused
  # cancel mutates nothing the view could see. The fan-out is re-read AFTER
  # both: a fan-out only closes, so "still open now" proves it was open at
  # both reads, and a view without the refusal is a regression only then;
  # otherwise the window closed in between — reported loudly, never as ✗
  # (kept from task 1788745551; unreachable here short of the test itself
  # stalling ~7 s between the OPEN poll and this re-read).
  M8a=$(mine10 $CAROL_ID)
  C8a=$(cancel10 $CAROL_ID "${ID8:-0}")
  FV3=$(fo10)
  if [ "$OPEN" = 1 ]; then ok "a post-request admin fetch for BTC-ICPUSD has an OPEN fan-out left to the deadline sweep (#$ID1, $(fonum10 "$FV" arrived) arrived at +${T1}s) — the window is staged, not hoped for"; else nok "could not stage the in-flight fetch window" "fanout=$FV"; fi
  if echo "$M8a" | grep -q 'cancelRefusal = opt "Staged LP deposit is committed for settlement — a price fetch for BTC-ICPUSD'; then ok "the request view (read inside the window) carries the in-flight refusal naming BTC-ICPUSD"
  elif [ "$(foopen10 "$FV3")" != "true" ]; then echo "  ⊘ skipped: the fan-out closed between the OPEN confirmation and the re-read after the cancel ($(printf '%s' "$FV3" | grep -oE 'reason = "[a-z]+"' | head -1)) — the view's in-flight refusal could not be observed this run"
  else nok "view refusal during the fetch (fan-out still open)" "$M8a"; fi
  if echo "$C8a" | grep -q 'a price fetch for BTC-ICPUSD dispatched after it was staged is in flight'; then ok "cancel is REFUSED while that fetch is in flight, naming the market (the fetch-bound lock, past the 3 s window)"; else nok "cancel not refused on the in-flight fetch" "$C8a :: fanout after=$(printf '%s' "$FV3" | head -c 160)"; fi
  # The admin call itself returned at ~+1.5 s (its fleet's latency) saying the
  # fan-out was left open; ONLY the heartbeat's deadline sweep closes it
  # (quorum needs 99, completion needs the held source) — poll to well past
  # PRICE_FANOUT_DEADLINE_NS (8 s) + a beat. The stall is cleared AFTER the
  # call returned (the hold is read at the call's end; clearing it earlier
  # would let the call drain the fan-out itself, the #never shape).
  wait "$FPID"
  R8=$(cat "$TMPD10/fetch"); rm -rf "$TMPD10"
  if echo "$R8" | grep -q 'left OPEN for the deadline sweep'; then ok "the admin call returned at once (+$(( $(date +%s) - S0 ))s) reporting its fan-out left OPEN for the sweep — no replica spin"; else nok "the admin call did not report the held-open fan-out" "$(echo "$R8" | tr -d '\n' | head -c 160)"; fi
  stall10 clear >/dev/null
  FV2=$(fo10)
  while [ "$(foopen10 "$FV2")" = "true" ] && [ $(( $(date +%s) - S0 )) -lt 16 ]; do sleep 0.5; FV2=$(fo10); done
  if [ "$(foopen10 "$FV2")" = "false" ] && printf '%s' "$FV2" | grep -q 'reason = "deadline"'; then ok "the fan-out closed by the DEADLINE sweep, +$(( $(date +%s) - S0 ))s after dispatch (the guard drops with it)"; else nok "the fan-out was not closed by the deadline sweep" "$(printf '%s' "$FV2" | head -c 200)"; fi
  C8b=$(cancel10 $CAROL_ID "${ID8:-0}")
  M8b=$(mine10 $CAROL_ID)
  if mdx_ok "$C8b" && echo "$M8b" | grep -q 'pending = vec {}' && echo "$M8b" | grep -q 'cancelled = "cancelled by owner"'; then ok "once the fetch finalized the cancel SUCCEEDS and refunds (ETH's mark never postdated the request, so nothing settled)"; else nok "cancel after the fetch finalized" "$C8b :: $M8b :: fetch=$(echo "$R8" | tr -d '\n' | head -c 120)"; fi
  if [ "$(resv10 $CAROL_ID ICPUSD)" = "0" ]; then ok "reservation released after the locked-then-unlocked cancel"; else nok "reservation stuck" "$(resv10 $CAROL_ID ICPUSD)"; fi
  s10e_teardown
fi
# HYGIENE: unwind the fixture so nothing global is stranded.
mdx_lp_withdraw alice "$(asA getMyVaultLp '()' | tr -d '_' | grep -oE '[0-9]+' | head -1)" >/dev/null 2>&1
adm resetExchange '()' >/dev/null 2>&1

echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
