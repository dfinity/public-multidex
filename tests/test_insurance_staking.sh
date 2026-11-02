#!/bin/bash
# Insurance-fund STAKING — the user-staked junior tranche, pool era.
# (Rewritten 2026-07: the liquidatees are margin POOLS now — the removed
# whole-wallet borrowAsset API built them directly before.)
#
# Stakers deposit ICPUSD for shares, EARN liquidation penalties (share value
# rises on a SOLVENT liquidation) and ABSORB insolvent bad debt before LPs
# (share value falls on an INSOLVENT one). Walkthrough:
#   stake $10k → solvent pool liquidation → staker value RISES (yield)
#   → insolvent pool liquidation → staker value FALLS (absorption)
#   → unstake all → pro-rata ICPUSD comes back, buffer empties.
# ⚠️ Calls resetExchange.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

mdx_identity_new ins_staker; S=$(principal_of ins_staker)     # the insurance staker
mdx_identity_new ins_liq1; U1=$(principal_of ins_liq1)      # solvent liquidatee (generates yield)
mdx_identity_new ins_liq2; U2=$(principal_of ins_liq2)      # insolvent liquidatee (drains the pool)
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
asS() { icp canister call --candid "$MDX_CANDID" --identity ins_staker backend "$@" 2>&1; }
as1() { icp canister call --candid "$MDX_CANDID" --identity ins_liq1 backend "$@" 2>&1; }
as2() { icp canister call --candid "$MDX_CANDID" --identity ins_liq2 backend "$@" 2>&1; }
release() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "[0-9]+"; }
stakeval() { fld valueUsd "$(asS getMyInsuranceStake '()')"; }
bal() { adm getTestBalance "(principal \"$1\", \"ICPUSD\")" | tr -d '_' | grep -oE "[0-9]+" | head -1; }
# H-35: stakes carry a 10 min UNSTAKE COOLDOWN from the holder's latest stake
# (F42 / D3 (a) — see §5). The round-trip sections below unstake right after
# staking, so they cross the cooldown through the #dev re-stamp hook, the
# same way setTestRefPriceUpdatedNs stands in for oracle age. `|| true`: on a
# pre-H-35 backend the hook does not exist and there is no cooldown to cross.
backdate() { adm setTestInsuranceStakedAt "(principal \"$1\", 1 : int)" >/dev/null 2>&1 || true; }

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat)" >/dev/null 2>&1 || true
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1 || true
AMM=$(adm getAmmPrincipal "()" | grep -oE 'principal "[^"]+"' | head -1 | sed -E 's/principal "(.+)"/\1/')
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 10000000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$AMM\", \"BTC\",    $(e8 100.0) : nat)"      >/dev/null
adm setTestBalance "(principal \"$S\",  \"ICPUSD\", $(e8 50000.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$U1\", \"ICPUSD\", $(e8 100000.0) : nat)"    >/dev/null
adm setTestBalance "(principal \"$U2\", \"ICPUSD\", $(e8 100000.0) : nat)"    >/dev/null

# helper: create+fund a pool and open a 1 BTC long for a given identity fn
open_pool() { # $1 = caller fn name
  local R PID
  R=$($1 createMarginPool '("stk pool", false)')
  PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
  $1 fundMarginPool "($PID, $(e8 30000.0) : nat)" >/dev/null
  $1 openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 1.0) : nat, $(e8 0.05) : nat, null)" >/dev/null
  release
}

echo "── 1. stake \$10k → shares at value 1.0 ──"
ST=$(asS stakeInsurance "($(e8 10000.0) : nat)")
if mdx_ok "$ST"; then ok "staked \$10k"; else nok "stakeInsurance" "$ST"; fi
V0=$(stakeval)
if [ -n "${V0:-}" ] && awk -v v="$V0" 'BEGIN{exit (v>=999000000000 && v<=1000100000000 ? 0 : 1)}'; then
  ok "stake value ≈ \$10k ($(from_e8 "$V0"))"
else nok "initial stake value" "v=$V0"; fi

echo "── 2. SOLVENT liquidation → penalty accrues → stake value RISES ──"
open_pool as1
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 25000.0) : nat)" >/dev/null   # under maintenance (liq px ≈ 25.9k), still solvent
adm adminRunLiquidationBatch "()" >/dev/null 2>&1
V1=$(stakeval)
if awk -v a="${V1:-0}" -v b="${V0:-0}" 'BEGIN{exit (a>b?0:1)}'; then
  ok "yield: stake value rose ($(from_e8 "$V0") → $(from_e8 "$V1"))"
else nok "solvent liquidation should lift stake value (penalty → stakers)" "before=$V0 after=$V1"; fi

# #48.1: the quote must use the redeem expression, not the plain V/S share
# value. Here V>S (the penalty accrued value without minting shares), so the
# naive s×shareValue — the OLD valueUsd formula — must STRICTLY exceed the
# symmetric-offset redeem value the query now reports. (~1e12-scale values fit
# a double with room to spare; the gap here is ~1e6 base units.)
SHY=$(fld shares "$(asS getMyInsuranceStake '()')")
SVY=$(fld shareValueUsd "$(adm getInsuranceFund '()')")
if awk -v s="${SHY:-0}" -v sv="${SVY:-0}" -v q="${V1:-0}" 'BEGIN{exit (s*sv/100000000 > q ? 0 : 1)}'; then
  ok "quote is the redeem expression: naive s×V/S exceeds valueUsd at V>S (#48.1)"
else nok "valueUsd should sit BELOW the naive s×shareValue at V>S (#48.1)" "s=${SHY:-} sv=${SVY:-} quote=${V1:-}"; fi

# #48.1 sibling (1787200508): the account summary must fold the SAME redeem
# quote into netAccountValueUsd. The staker holds only wallet ICPUSD plus the
# stake (no pools, no debt, no vault LP), so net − freeWallet isolates the
# insurance term — at V>S the old s×V/S mark strictly exceeded the redeem value.
QI=$(stakeval)
SUM=$(asS getMyAccountSummary '()')
NAVQ=$(fld netAccountValueUsd "$SUM"); FREEW=$(fld freeWalletValueUsd "$SUM")
INSTERM=$(( ${NAVQ:-0} - ${FREEW:-0} ))
if [ -n "${QI:-}" ] && [ "$INSTERM" = "$QI" ]; then
  ok "account summary's insurance term == redeem quote at V>S (#48.1 sibling)"
else nok "netAccountValueUsd must fold in insuranceRedeemValue, not s×V/S" "term=$INSTERM quote=${QI:-}"; fi

echo "── 2b. #48.1: at V>S the quote equals an immediate full unstake, exactly ──"
# The money case: value above supply, clamp inactive, payout NONZERO. Quote the
# full holding, unstake it all, and demand base-unit equality — then re-stake
# the payout so sections 3-4 still run against a live stake.
QY=$(stakeval)
BA=$(adm getTestBalance "(principal \"$S\", \"ICPUSD\")" | tr -d '_' | grep -oE "[0-9]+" | head -1)
SHA=$(fld shares "$(asS getMyInsuranceStake '()')")
backdate "$S"   # H-35: cross the cooldown; the quote == payout pin is about the redeem expression
UNY=$(asS unstakeInsurance "(${SHA:-0} : nat)")
BB=$(adm getTestBalance "(principal \"$S\", \"ICPUSD\")" | tr -d '_' | grep -oE "[0-9]+" | head -1)
GY=$(( ${BB:-0} - ${BA:-0} ))
if mdx_ok "$UNY" && [ -n "${QY:-}" ] && [ "$GY" != "0" ] && [ "$GY" = "$QY" ]; then
  ok "quote == immediate unstake payout, nonzero (\$$(from_e8 "$GY")) (#48.1)"
else nok "valueUsd must equal the actual unstake payout at V>S (#48.1)" "quote=${QY:-} paid=$GY ($UNY)"; fi
RS=$(asS stakeInsurance "($GY : nat)")
if mdx_ok "$RS"; then ok "re-staked the payout"; else nok "re-stake after the round trip" "$RS"; fi
V1=$(stakeval)   # re-baseline for section 3 (entry value differs by rounding dust)

echo "── 3. INSOLVENT liquidation → pool absorbs → stake value FALLS ──"
release   # restore 50k so the next pool can open
open_pool as2
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 12000.0) : nat)" >/dev/null   # collateral < debt → insolvent
adm adminRunLiquidationBatch "()" >/dev/null 2>&1
V2=$(stakeval)
if awk -v a="${V2:-0}" -v b="${V1:-0}" 'BEGIN{exit (a<b?0:1)}'; then
  ok "absorption: stake value fell ($(from_e8 "$V1") → $(from_e8 "$V2"))"
else nok "insolvency should drain the junior tranche" "before=$V1 after=$V2"; fi

echo "── 4. unstake all → pro-rata remainder returns ──"
SH=$(fld shares "$(asS getMyInsuranceStake '()')")
BAL0=$(fld '' "$(adm getTestBalance "(principal \"$S\", \"ICPUSD\")")")
BAL0=$(adm getTestBalance "(principal \"$S\", \"ICPUSD\")" | tr -d '_' | grep -oE "[0-9]+" | head -1)
QUOTE=$(stakeval)   # #48.1: quote taken immediately before the unstake
backdate "$S"       # H-35: the §2b re-stake restarted the cooldown clock
UN=$(asS unstakeInsurance "(${SH:-0} : nat)")
if mdx_ok "$UN"; then ok "unstaked ${SH:-0} shares"; else nok "unstakeInsurance" "$UN"; fi
BAL1=$(adm getTestBalance "(principal \"$S\", \"ICPUSD\")" | tr -d '_' | grep -oE "[0-9]+" | head -1)
GOT=$(( ${BAL1:-0} - ${BAL0:-0} ))
# The redemption ≈ the last observed stake value (± dust rounding toward the pool).
if awk -v g="$GOT" -v v="${V2:-0}" 'BEGIN{d=g-v; if(d<0)d=-d; exit (d <= 100000 ? 0 : 1)}'; then
  ok "pro-rata redemption ≈ stake value (\$$(from_e8 "$GOT"))"
else nok "redemption mismatch" "got=$GOT expected≈$V2"; fi
# #48.1: the quote IS the payout — valueUsd read just before the unstake must
# EXACTLY equal what unstakeInsurance credited (same insuranceRedeemValue path,
# timers paused, nothing moved the pool in between).
if [ -n "${QUOTE:-}" ] && [ "${GOT:-x}" = "$QUOTE" ]; then
  ok "quote == payout exactly (\$$(from_e8 "$GOT")) (#48.1)"
else nok "getMyInsuranceStake().valueUsd must equal the unstake payout (#48.1)" "quote=${QUOTE:-} paid=${GOT:-}"; fi
SH2=$(fld shares "$(asS getMyInsuranceStake '()')")
if [ "${SH2:-x}" = "0" ]; then ok "no shares left"; else nok "shares should be zero" "left=$SH2"; fi

echo "── 5. H-35 (F42, D3 (a)): the unstake COOLDOWN closes the sweep-timing skim ──"
# The unstake comment in main.mo names the play and #48.1 closed only its
# virtual-offset half: the liquidation sweep runs every HB_LIQ_NS = 30 s and
# its next victims are readable (getLiquidationSweepHealth /
# getMarginRiskSummary), so a stake entered one message BEFORE a solvent
# liquidation and exited one message AFTER it skimmed A/(V+A) of the penalty
# from the long-term stakers who carry the bad-debt risk. Now a holding is not
# redeemable until INSURANCE_UNSTAKE_COOLDOWN_NS (10 min) after the holder's
# LATEST stake; getMyInsuranceStake().unlockAtNs quotes the instant and the
# refusal names the same one. S is the long-term staker (its stamp backdated —
# the #dev hook stands in for the ten minutes); N is the sniper.
mdx_identity_new ins_sniper; N=$(principal_of ins_sniper)
mdx_identity_new ins_liq3;   U3=$(principal_of ins_liq3)
asN() { icp canister call --candid "$MDX_CANDID" --identity ins_sniper backend "$@" 2>&1; }
as3() { icp canister call --candid "$MDX_CANDID" --identity ins_liq3 backend "$@" 2>&1; }
adm setTestBalance "(principal \"$N\",  \"ICPUSD\", $(e8 50000.0) : nat)"  >/dev/null
adm setTestBalance "(principal \"$U3\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
release   # back to 50k so the next pool can open
RS=$(asS stakeInsurance "($(e8 10000.0) : nat)")
if mdx_ok "$RS"; then ok "long-term staker S re-staked \$10k (fixture)"; else nok "S re-stake (fixture)" "$RS"; fi
backdate "$S"
# Adjacent (no holding): nothing to lock → unlockAtNs = 0, and the hook must
# not manufacture a stamp for a principal that holds no shares.
adm setTestInsuranceStakedAt "(principal \"$N\", 1 : int)" >/dev/null 2>&1 || true
UL0=$(fld unlockAtNs "$(asN getMyInsuranceStake '()')")
if [ "${UL0:-x}" = "0" ]; then ok "no holding → unlockAtNs = 0 (and the re-stamp hook ignores a non-holder)"
else nok "unlockAtNs must be 0 for a principal with no stake" "got=${UL0:-<missing field>}"; fi
NOW_NS=$(( $(date +%s) * 1000000000 ))
NS=$(asN stakeInsurance "($(e8 10000.0) : nat)")
if mdx_ok "$NS"; then ok "sniper N staked \$10k one message before the sweep"; else nok "N stake (fixture)" "$NS"; fi
NB0=$(bal "$N"); SHN0=$(fld shares "$(asN getMyInsuranceStake '()')")
UL1=$(fld unlockAtNs "$(asN getMyInsuranceStake '()')")
# 10 min after the stake — judged against the HOST clock with ±60 s for the
# replica/host skew, so the assertion is about the cooldown, not a clock.
if [ -n "${UL1:-}" ] && awk -v u="$UL1" -v n="$NOW_NS" 'BEGIN{d=(u-n)/1e9; exit (d>=540 && d<=660 ? 0 : 1)}'; then
  ok "unlockAtNs quotes stake + 10 min ($(awk -v u="$UL1" -v n="$NOW_NS" 'BEGIN{printf "%.0f", (u-n)/1e9}') s from now)"
else nok "unlockAtNs must be ≈ stake time + 10 min (> HB_LIQ_NS = 30 s)" "unlockAtNs=${UL1:-<missing field>} now=$NOW_NS"; fi
# The predictable solvent liquidation lands while N is inside the window.
open_pool as3
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 25000.0) : nat)" >/dev/null
adm adminRunLiquidationBatch "()" >/dev/null 2>&1
VN=$(fld valueUsd "$(asN getMyInsuranceStake '()')")
if awk -v v="${VN:-0}" 'BEGIN{exit (v > 1000000000000 ? 0 : 1)}'; then
  ok "penalty accrued to N's shares too (distribution semantics unchanged: \$$(from_e8 "$VN"))"
else nok "the solvent liquidation should have lifted N's holding (fixture)" "value=${VN:-}"; fi
# THE SKIM: one message after the sweep, N tries to leave with the yield.
UN5=$(asN unstakeInsurance "(${SHN0:-0} : nat)")
if echo "$UN5" | grep -q "locked until ${UL1:-NEVER}"; then
  ok "unstake within one heartbeat of the sweep REFUSED, naming the quoted unlock instant (H-35)"
else nok "the sniper exited inside the cooldown — the F42 skim" "$(echo "$UN5" | head -c 200)"; fi
NB1=$(bal "$N"); SHN1=$(fld shares "$(asN getMyInsuranceStake '()')")
if [ $(( ${NB1:-0} - ${NB0:-0} )) -le 0 ] && [ "${SHN1:-x}" = "${SHN0:-y}" ]; then
  ok "sniper's payout ≤ stake: nothing left the pool (Δ wallet = $(( ${NB1:-0} - ${NB0:-0} )), shares unchanged)"
else nok "the refused unstake must move nothing" "Δ=$(( ${NB1:-0} - ${NB0:-0} )) shares ${SHN0:-}→${SHN1:-}"; fi
# Adjacent: a TOP-UP restarts the clock for the WHOLE holding (D3's rule).
backdate "$N"
ULB=$(fld unlockAtNs "$(asN getMyInsuranceStake '()')")
TU=$(asN stakeInsurance "($(e8 100.0) : nat)")
ULT=$(fld unlockAtNs "$(asN getMyInsuranceStake '()')")
if mdx_ok "$TU" && [ -n "${ULB:-}" ] && [ -n "${ULT:-}" ] && awk -v b="$ULB" -v t="$ULT" -v n="$NOW_NS" 'BEGIN{exit (b < n && t > n ? 0 : 1)}'; then
  ok "a \$100 top-up re-locks the whole holding (unlockAtNs $ULB → $ULT)"
else nok "a top-up must restart the cooldown for the whole holding" "before=${ULB:-} after=${ULT:-} ($TU)"; fi
UN5b=$(asN unstakeInsurance "(1 : nat)")
if echo "$UN5b" | grep -q "locked until ${ULT:-NEVER}"; then ok "…and the re-locked holding is refused again, naming the new instant"
else nok "the topped-up holding should be locked" "$(echo "$UN5b" | head -c 200)"; fi
# Adjacent: PAST the cooldown a PARTIAL redemption pays and does not re-lock
# (only a stake writes the stamp), then the FULL exit deletes the stamp with
# the holding — unlockAtNs back to 0, the stamp map a subset of the shares map.
backdate "$N"
ULP=$(fld unlockAtNs "$(asN getMyInsuranceStake '()')")
SHN2=$(fld shares "$(asN getMyInsuranceStake '()')")
HALF=$(( ${SHN2:-0} / 2 ))
PU=$(asN unstakeInsurance "($HALF : nat)")
ULQ=$(fld unlockAtNs "$(asN getMyInsuranceStake '()')")
if mdx_ok "$PU" && [ -n "${ULP:-}" ] && [ "${ULQ:-x}" = "$ULP" ]; then
  ok "past the cooldown a partial unstake pays (\$$(from_e8 "$(echo "$PU" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+')")) and leaves the stamp alone"
else nok "partial unstake after the cooldown must pay and must not re-lock" "unlock ${ULP:-}→${ULQ:-} ($PU)"; fi
REST=$(fld shares "$(asN getMyInsuranceStake '()')")
FU=$(asN unstakeInsurance "(${REST:-0} : nat)")
SHN3=$(fld shares "$(asN getMyInsuranceStake '()')"); UL3=$(fld unlockAtNs "$(asN getMyInsuranceStake '()')")
if mdx_ok "$FU" && [ "${SHN3:-x}" = "0" ] && [ "${UL3:-x}" = "0" ]; then
  ok "full exit clears the holding AND its stamp (shares 0, unlockAtNs 0)"
else nok "a full exit must delete the cooldown stamp with the holding" "shares=${SHN3:-} unlockAtNs=${UL3:-} ($FU)"; fi
# The long-term staker is untouched by all of it: still redeemable at the quote.
QS=$(stakeval); SHS=$(fld shares "$(asS getMyInsuranceStake '()')"); SB0=$(bal "$S")
US=$(asS unstakeInsurance "(${SHS:-0} : nat)"); SB1=$(bal "$S")
if mdx_ok "$US" && [ -n "${QS:-}" ] && [ "$(( ${SB1:-0} - ${SB0:-0} ))" = "$QS" ]; then
  ok "long-term staker S (past its cooldown) redeems exactly the quote (\$$(from_e8 "$QS")) — quote == payout holds through the gate"
else nok "S's redemption must equal its quote" "quote=${QS:-} paid=$(( ${SB1:-0} - ${SB0:-0} )) ($US)"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
