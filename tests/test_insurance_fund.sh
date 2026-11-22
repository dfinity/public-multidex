#!/bin/bash
# Insurance fund / bad-debt resolution — pool era.
# (Rewritten 2026-07: the original built an insolvent whole-wallet user via the
# removed borrowAsset API. Same promise, pool-shaped: a pool so far underwater
# that collateral can't cover debt must be CLOSED — the covered slice drawn
# from the insurance buffer, the excess tallied as uncovered bad debt — never
# left as a perpetually-liquidatable zombie.)
#
# Setup: seed a deliberately SMALL insurance buffer ($3k). A $30k pool longs
# 1 BTC (~$20k debt), then BTC crashes 50k → 12k: collateral value < debt →
# insolvent. The batch must: write the pool's debt off (not zombie it), drain
# the buffer toward 0, and tally uncoveredBadDebtUsd > 0 for the shortfall
# beyond the buffer. ⚠️ Calls resetExchange.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

ID=insf; mdx_identity_new $ID
P=$(icp identity principal --identity $ID 2>/dev/null | tail -1)
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
usr() { icp canister call --candid "$MDX_CANDID" --identity $ID backend "$@" 2>&1; }
release() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "[0-9]+"; }

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat)" >/dev/null 2>&1 || true
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1 || true
AMM=$(adm getAmmPrincipal "()" | grep -oE 'principal "[^"]+"' | head -1 | sed -E 's/principal "(.+)"/\1/')
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 10000000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$AMM\", \"BTC\",    $(e8 100.0) : nat)"      >/dev/null
adm setTestBalance "(principal \"$P\",   \"ICPUSD\", $(e8 100000.0) : nat)"   >/dev/null

echo "── seed a small \$3k insurance buffer ──"
adm seedInsuranceFund "($(e8 3000.0) : nat)" >/dev/null
INS0=$(adm getInsuranceFund '()')
BUF0=$(fld bufferUsd "$INS0"); UBD0=$(fld uncoveredBadDebtUsd "$INS0")
if [ "${BUF0:-0}" = "$(e8 3000)" ]; then ok "buffer seeded (\$3k)"; else nok "seedInsuranceFund" "buf=$BUF0"; fi

echo "── #55: a second seed on an already-seeded pool is a no-op (no double-mint) ──"
# deploy.sh once misread every successful seed as "failed" and invited a
# manual re-run; the canister now refuses to mint a second unbacked pool on
# top of one that already holds value — it logs, and answers the existing
# value. The buffer and the share supply must be exactly what one seed left.
SH0=$(fld totalShares "$INS0")
RESEED=$(adm seedInsuranceFund "($(e8 3000.0) : nat)")
INS_R=$(adm getInsuranceFund '()')
BUF_R=$(fld bufferUsd "$INS_R"); SH_R=$(fld totalShares "$INS_R")
if [ "${BUF_R:-0}" = "$(e8 3000)" ] && [ "${SH_R:-0}" = "${SH0:-x}" ]; then ok "re-seed did not double-mint (buffer still \$3k, shares $SH_R unchanged)"
else nok "re-seed double-minted" "buf=$BUF_R (want $(e8 3000)) shares=$SH_R (want $SH0)"; fi
if echo "$RESEED" | tr -d '_' | grep -qE "\([[:space:]]*$(e8 3000)[[:space:]]*:[[:space:]]*nat[[:space:]]*\)"; then ok "re-seed answers the EXISTING pool value (\$3k), same return shape"
else nok "re-seed return value" "$(echo "$RESEED" | head -1)"; fi
if adm getRecentEvents '(50 : nat)' | grep -q "INSURANCE SEED: skipped"; then ok "the skipped re-seed is on the ring log"
else nok "ring log lacks the INSURANCE SEED: skipped line" "$(adm getRecentEvents '(5 : nat)' | head -3 | tr '\n' ' ')"; fi

echo "── setup: \$30k pool, 1 BTC long — then a catastrophic crash to 12k ──"
R=$(usr createMarginPool '("insf pool", false)')
PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
usr fundMarginPool "($PID, $(e8 30000.0) : nat)" >/dev/null
usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 1.0) : nat, $(e8 0.05) : nat, null)" >/dev/null
release
D0=$(fld debtUsd "$(usr getMyMarginPools '()')")
[ -n "${D0:-}" ] && [ "$D0" != "0" ] && ok "long open, debt \$$(from_e8 "$D0")" || nok "setup" "debt=$D0"

adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 12000.0) : nat)" >/dev/null
HP=$(usr getMyMarginPools "()")
if echo "$HP" | grep -q "isLiquidatable = true"; then ok "pool deeply underwater (insolvent territory)"; else nok "should be liquidatable at 12k" "$HP"; fi

echo "── batch: insolvent pool CLOSED — buffer drained, shortfall tallied ──"
# Debt snapshot right before the batch (ICPUSD debt is BTC-price-independent;
# only sub-cent interest accrues between this read and the batch).
D_PRE=$(fld debtUsd "$(usr getMyMarginPools '()')")
adm adminRunLiquidationBatch "()" >/dev/null 2>&1
INS1=$(adm getInsuranceFund '()')
BUF1=$(fld bufferUsd "$INS1"); UBD1=$(fld uncoveredBadDebtUsd "$INS1")
D1=$(fld debtUsd "$(usr getMyMarginPools '()')")

# The debt is written OFF (cleared to at most $1 of dust), not left as a zombie.
if [ -n "${D1:-}" ] && awk -v d="$D1" 'BEGIN{exit (d < 100000000 ? 0 : 1)}'; then
  ok "insolvent debt written off (\$$(from_e8 "$D0") → \$$(from_e8 "$D1"))"
else nok "insolvent pool should be closed, not a zombie" "debt after=$D1"; fi

# The buffer absorbed first…
if awk -v a="${BUF1:-0}" -v b="${BUF0:-0}" 'BEGIN{exit (a<b?0:1)}'; then
  ok "insurance buffer absorbed the covered slice (\$$(from_e8 "${BUF0:-0}") → \$$(from_e8 "${BUF1:-0}"))"
else nok "buffer should drain on insolvency" "before=$BUF0 after=$BUF1"; fi

# …and the excess became realised uncovered bad debt.
if awk -v a="${UBD1:-0}" -v b="${UBD0:-0}" 'BEGIN{exit (a>b?0:1)}'; then
  ok "uncovered bad debt tallied beyond the buffer (+\$$(from_e8 $(( ${UBD1:-0} - ${UBD0:-0} ))))"
else nok "shortfall beyond the buffer should be tallied" "before=$UBD0 after=$UBD1"; fi

echo "── #48.2: the seized penalty ACCRUES to the fund on the insolvent arm ──"
# A seizing pass that ends #insolvent still charged the 5% penalty (the vault
# kept repaid+penalty worth of the seized BTC), and main.mo must accrue it to
# the fund BEFORE absorbing the shortfall (accrue-then-absorb, as documented).
# Sum across the pool's liquidation events (normally exactly one here).
sumfld() { echo "$2" | tr -d '_' | grep -oE "$1 = [0-9]+" | grep -oE "[0-9]+$" | awk '{s+=$1} END{printf "%.0f", s+0}'; }
EV=$(usr getMyPoolLiquidations '()')
PEN=$(sumfld penaltyUsd "$EV"); REP=$(sumfld debtRepaidUsd "$EV")
PY1=$(fld pendingYieldUsd "$INS1")

# The insolvent close carried a real, non-zero penalty.
if [ -n "${PEN:-}" ] && [ "${PEN:-0}" != "0" ]; then
  ok "insolvent close charged a real penalty (\$$(from_e8 "$PEN"))"
else nok "penaltyUsd should be non-zero on a seizing insolvent close" "$EV"; fi

# Vault is cash-rich here, so the accrual settled to fund cash instantly —
# nothing may sit in arrears (which would also be invisible to absorbBadDebt).
if [ "${PY1:-0}" = "0" ]; then ok "penalty settled in cash (no pending arrears)"
else nok "pendingYieldUsd should be 0 (vault cash-rich)" "py=$PY1"; fi

# The shortfall dwarfs the buffer, so the buffer must fully drain — a partial
# drain would break the exact ledger below.
if [ "${BUF1:-1}" = "0" ]; then ok "buffer fully drained by the shortfall"
else nok "buffer should drain to 0 (residual >> buffer)" "buf=$BUF1"; fi

# Exact ledger: residual = debt_at_batch − repaid; the fund absorbed
# BUF0 + PEN (seed plus the freshly-accrued penalty) before the overflow hit
# LPs, so UBD_delta = residual − BUF0 − PEN. Before the #48.2 fix the accrual
# was skipped and UBD_delta came out exactly PEN larger. ±$2 for the interest
# that accrues between the D_PRE read and the batch.
EXP=$(awk -v d="${D_PRE:-0}" -v r="${REP:-0}" -v b="${BUF0:-0}" -v p="${PEN:-0}" 'BEGIN{printf "%.0f", d-r-b-p}')
ACT=$(( ${UBD1:-0} - ${UBD0:-0} ))
if awk -v a="$ACT" -v e="$EXP" 'BEGIN{d=a-e; if(d<0)d=-d; exit (d <= 200000000 ? 0 : 1)}'; then
  ok "uncovered = residual − buffer − penalty (\$$(from_e8 "$ACT") ≈ \$$(from_e8 "$EXP")) — penalty credited before absorb"
else nok "penalty not credited to the fund before absorb (accrue-then-absorb broken)" "UBD_delta=$ACT expected=$EXP (D_PRE=$D_PRE REP=$REP BUF0=$BUF0 PEN=$PEN)"; fi

echo "── H-05 (F1): absorbBadDebt is NEVER reached from a VOLUNTARY close ──"
# A pool at health 1.17 shorts 0.2 BTC; the AMM's ask side is emptied
# (inventory at the floor withdraws it) and a colluder rests an ask at the
# close's 25% edge. Pre-fix the pool's #market close — exempt from the #3a
# ladder-edge cap and price-blind in its de-lever escape — lifted it, spent
# past the collateral and left base debt the post-fill liquidation hook wrote
# off through absorbBadDebt: the fund paid for a close nobody was forced
# into. Post-fix the close is bounded to ±2% of mid (the AMM quotes nothing
# on that side), walks MAX_REDEFER requotes and drops; the position, the
# equity and BOTH fund counters are untouched by the close and by a
# liquidation batch run after it. (tests/test_initial_margin.sh §F/§F2 pin
# the mechanism; this is the fund-side promise.)
V=insf2; mdx_identity_new $V
VP=$(icp identity principal --identity $V 2>/dev/null | tail -1)
vusr() { icp canister call --candid "$MDX_CANDID" --identity $V backend "$@" 2>&1; }
C=insfc; mdx_identity_new $C
CP=$(icp identity principal --identity $C 2>/dev/null | tail -1)
cusr() { icp canister call --candid "$MDX_CANDID" --identity $C backend "$@" 2>&1; }
frel() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 $1) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
sfld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "\-?[0-9]+"; }
adm setTestBalance "(principal \"$AMM\", \"BTC\",    $(e8 100.0) : nat)"      >/dev/null
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 10000000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$VP\",  \"ICPUSD\", $(e8 50000.0) : nat)"    >/dev/null
adm setTestBalance "(principal \"$CP\",  \"BTC\",    $(e8 5.0) : nat)"        >/dev/null
frel 50000.0
VR=$(vusr createMarginPool '("h05 fund", false)')
VPID=$(echo "$VR" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
vusr fundMarginPool "($VPID, $(e8 10000.0) : nat)" >/dev/null
VO=$(vusr openPosition "($VPID, \"BTC-ICPUSD\", variant { sell }, $(e8 0.2) : nat, $(e8 0.05) : nat, null)")
mdx_ok "$VO" || nok "H-05: short should stage" "$VO"
frel 50000.0; frel 50000.0
VSZ=$(sfld size "$(vusr getMyPositions '()')")
if [ -n "${VSZ:-}" ] && [ "$VSZ" -le "-$(e8 0.19)" ]; then ok "H-05: pool short 0.2 BTC"; else nok "H-05: pool should be short" "size=$VSZ"; fi
frel 85500.0
adm setTestBalance "(principal \"$AMM\", \"BTC\", 0 : nat)" >/dev/null
frel 85500.0
CA=$(cusr placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 106800.0) : nat, $(e8 1.0) : nat)")
mdx_ok "$CA" || nok "H-05: colluding ask" "$CA"
frel 85500.0
INS_H0=$(adm getInsuranceFund '()')
BUF_H0=$(fld bufferUsd "$INS_H0"); UBD_H0=$(fld uncoveredBadDebtUsd "$INS_H0")
VHR=$(fld healthRatio "$(vusr getMyMarginPools '()')")
if [ -n "${VHR:-}" ] && [ "$VHR" -ge "$(e8 1.15)" ]; then ok "H-05: pool at health $(from_e8 "$VHR") before the close (not liquidatable)"; else nok "H-05: fixture health" "healthRatio=$VHR"; fi
VC=$(vusr closePosition "($VPID, \"BTC-ICPUSD\", $(e8 0.25) : nat, null)")
if mdx_ok "$VC"; then ok "H-05: close(25%) accepted"; else nok "H-05: close refused" "$VC"; fi
for _ in 1 2 3 4 5 6 7; do frel 85500.0; done
adm adminRunLiquidationBatch "()" >/dev/null 2>&1
INS_H1=$(adm getInsuranceFund '()')
BUF_H1=$(fld bufferUsd "$INS_H1"); UBD_H1=$(fld uncoveredBadDebtUsd "$INS_H1")
if [ "${UBD_H1:-x}" = "${UBD_H0:-y}" ] && [ "${BUF_H1:-x}" = "${BUF_H0:-y}" ]; then ok "H-05: fund untouched by the voluntary close + a batch (buffer \$$(from_e8 "${BUF_H1:-0}"), uncovered \$$(from_e8 "${UBD_H1:-0}"))"
else nok "H-05: absorbBadDebt reached from a voluntary close" "buffer $BUF_H0 → $BUF_H1, uncovered $UBD_H0 → $UBD_H1"; fi
VSZ2=$(sfld size "$(vusr getMyPositions '()')")
VEQ=$(sfld equityUsd "$(vusr getMyMarginPools '()')")
if [ -n "${VSZ2:-}" ] && [ "$VSZ2" -le "-$(e8 0.19)" ] && [ -n "${VEQ:-}" ] && [ "$VEQ" -gt 0 ]; then ok "H-05: position intact (size $(from_e8 "$VSZ2")), equity \$$(from_e8 "$VEQ") > 0"; else nok "H-05: the close filled through equity" "size=$VSZ2 equity=$VEQ"; fi
CF=$(fld filled "$(cusr getMyOrders '()')")
if [ "${CF:-x}" = "0" ]; then ok "H-05: the 25%-edge ask was not lifted"; else nok "H-05: colluding ask lifted" "filled=$CF"; fi
if ! vusr getMyPoolLiquidations '()' | grep -q "debtRepaidUsd"; then ok "H-05: no liquidation event on the pool"; else nok "H-05: pool liquidated" "$(vusr getMyPoolLiquidations '()' | head -c 300)"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
