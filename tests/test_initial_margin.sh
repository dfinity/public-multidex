#!/bin/bash
# Initial-margin gate — pool era. Risk-INCREASING actions must clear
# INITIAL_HEALTH_RATIO (1.25), not just maintenance (1.15), so a position can't
# be opened straight into near-liquidation territory.
#
# (Rewritten 2026-07: the original drove the removed whole-wallet margin API —
# openMarginAccount/borrowAsset — and its borrow-then-convert hole. Margin is
# pool-based now; openPosition IS the borrow+convert in one step, gated to
# INITIAL at stage time and re-clamped at release. The withdraw-side gate lives
# in test_margin_pools.sh §8.)
#
# ⚠️  Calls resetExchange — do not run against the live sim.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

ID=img; mdx_identity_new $ID
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
adm setTestBalance "(principal \"$P\",   \"ICPUSD\", $(e8 50000.0) : nat)"    >/dev/null

echo "── setup: pool funded with \$10k ──"
R=$(usr createMarginPool '("img pool", false)')
PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
usr fundMarginPool "($PID, $(e8 10000.0) : nat)" >/dev/null
C=$(fld collateralUsd "$(usr getMyMarginPools '()')")
if [ "${C:-0}" = "$(e8 10000)" ]; then ok "pool funded (\$10k collateral)"; else nok "setup" "coll=$C"; fi

echo "── A. Over-leveraged open (≈6×) REJECTED at the initial gate ──"
# 1.2 BTC ≈ $60k notional on $10k margin: borrow ~$50k, projected health far
# below INITIAL (1.25) → must be rejected outright at stage time.
A=$(usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 1.2) : nat, $(e8 0.05) : nat, null)")
if echo "$A" | grep -qiE "initial|margin|health"; then ok "6× open rejected (initial-margin gate)"; else nok "over-leveraged open should be rejected" "$A"; fi
POS0=$(usr getMyPositions "()")
if ! echo "$POS0" | grep -q "BTC-ICPUSD"; then ok "no position created by the rejected open"; else nok "rejected open left a position" "$POS0"; fi

echo "── B. Modest open (≈1.5×) ACCEPTED and fills ──"
B=$(usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 0.3) : nat, $(e8 0.05) : nat, null)")
if mdx_ok "$B"; then ok "1.5× open accepted"; else nok "modest open should pass the gate" "$B"; fi
release
SZ=$(fld size "$(usr getMyPositions '()')")
if [ -n "${SZ:-}" ] && awk -v s="$SZ" 'BEGIN{exit (s>=25000000 && s<=31000000 ? 0 : 1)}'; then
  ok "position opened (size $(from_e8 "${SZ:-0}") BTC)"
else nok "position after release" "size=$SZ"; fi

echo "── C. Risk-increasing SECOND open that would breach → rejected; pool still healthy ──"
C2=$(usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 1.0) : nat, $(e8 0.05) : nat, null)")
if echo "$C2" | grep -qiE "initial|margin|health"; then ok "risk-increasing add-on rejected"; else nok "add-on breaching initial should be rejected" "$C2"; fi
HP=$(usr getMyMarginPools "()")
if echo "$HP" | grep -q "isLiquidatable = false"; then ok "pool remains healthy"; else nok "pool health" "$HP"; fi

echo "── D. Risk-REDUCING close is always allowed, even with debt open ──"
D=$(usr closePosition "($PID, \"BTC-ICPUSD\", $(e8 0.05) : nat, null)")
if mdx_ok "$D"; then ok "close (risk-reducing) accepted"; else nok "close should always be allowed" "$D"; fi
release
POS2=$(usr getMyPositions "()")
if ! echo "$POS2" | grep -q "BTC-ICPUSD"; then ok "position flattened"; else nok "close did not flatten" "$POS2"; fi

echo "── E. #49.1: an opposite-side SHORT must NOT disable the initial-margin clamp ──"
# Regression for public issue #49 finding 1. clampToInitialMargin's de-lever
# escape was a BARE SIGN TEST: for a #buy it returned #full whenever poolNetSize
# < 0 — i.e. whenever the pool held ANY opposite-side (short) exposure — BEFORE
# reaching the headroom/#partial math. So a market-buy of any size skipped the
# initial-margin bound: the pool could re-lever straight through flat into a
# fresh long with no clamp. Fixed: only the quantity up to Int.abs(net) flattens
# exposure and passes free; the re-levering EXCESS faces the normal headroom
# clamp. Discriminator is the CLAMP'S OWN DECISION, read back via
# getMyReleaseRejections (immune to partial-fill/settlement noise): a genuine
# clamp records a rejection whose reason cites the initial-margin requirement and
# whose clampedTo is set. Pre-fix that record is ABSENT (the escape returned
# #full); post-fix it is PRESENT. Setup: a leveraged SOL short (net<0), then a
# buy far past flat that re-levers into a long.
SID=imgs; mdx_identity_new $SID
SPP=$(icp identity principal --identity $SID 2>/dev/null | tail -1)
susr() { icp canister call --candid "$MDX_CANDID" --identity $SID backend "$@" 2>&1; }
srel() { for _ in 1 2 3 4 5 6 7 8; do adm setAmmRefPrice "(\"SOL-ICPUSD\", $(e8 150.0) : nat)" >/dev/null; adm requoteAmm '("SOL-ICPUSD")' >/dev/null; done; }
adm createAmmPool '("SOL-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"SOL-ICPUSD\", $(e8 150.0) : nat)" >/dev/null
adm setAmmConfig "(\"SOL-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat)" >/dev/null 2>&1 || true
adm enableAmm '("SOL-ICPUSD", true)' >/dev/null 2>&1 || true
adm setTestBalance "(principal \"$AMM\", \"SOL\",    $(e8 1000000.0) : nat)"    >/dev/null
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 100000000.0) : nat)"  >/dev/null
adm setTestBalance "(principal \"$SPP\", \"ICPUSD\", $(e8 100000.0) : nat)"     >/dev/null
SR=$(susr createMarginPool '("dust-escape pool", false)')
SPID=$(echo "$SR" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
susr fundMarginPool "($SPID, $(e8 10000.0) : nat)" >/dev/null
SO=$(susr openPosition "($SPID, \"SOL-ICPUSD\", variant { sell }, $(e8 150.0) : nat, $(e8 0.05) : nat, null)")
if mdx_ok "$SO"; then ok "leveraged SOL short staged"; else nok "short should stage" "$SO"; fi
srel
SNET=$(susr getMyPositions '()' | tr -d '_' | grep -oE 'size = -?[0-9]+' | head -1 | grep -oE '\-?[0-9]+')
if [ -n "${SNET:-}" ] && [ "${SNET:-0}" -lt 0 ]; then ok "pool is net SHORT (size $(from_e8 "$SNET") SOL)"; else nok "pool should be net short after release" "size=$SNET"; fi
# Buy far past flat: 250 > 150, so ~150 de-levers (free) and ~100 re-levers long —
# the excess MUST hit the initial-margin clamp.
SB=$(susr openPosition "($SPID, \"SOL-ICPUSD\", variant { buy }, $(e8 250.0) : nat, $(e8 0.05) : nat, null)")
if mdx_ok "$SB"; then ok "re-levering buy staged (250 SOL, past the 150 short)"; else nok "buy should stage" "$SB"; fi
srel
RJ=$(susr getMyReleaseRejections "()")
if echo "$RJ" | grep -q "breach the initial-margin requirement" && echo "$RJ" | grep -q "clampedTo = opt"; then
  ok "de-lever escape did NOT bypass the clamp — excess was reduced at the initial-margin bound"
else
  nok "the re-levering buy was NOT clamped (escape returned #full — #49.1 regression)" "$(echo "$RJ" | tr '\n' ' ' | head -c 400)"
fi

echo "── F. H-05 (F1): a pool's market close is PRICE-BOUNDED at release — a colluding ask at the 25% edge behind an emptied AMM side is never lifted ──"
# Mechanism (docs/tasks/done/H-05-*.md): closePosition stages a #market close
# for |poolNetSize| at mark × (1 ± maxSlippage), up to 25%, and
# releaseDeferred's #3a ladder-edge cap was scoped to SPOT wallets — so the
# pool's close executed at its raw cap against whatever rested there. With
# the AMM's ask side emptied (inventory at the floor WITHDRAWS it), a
# colluding ask at the 25% edge filled a health-1.17 short's buy-back straight
# through the pool's equity: base debt left with the quote gone → the post-
# fill liquidation hook → #insolvent → absorbBadDebt (uncoveredBadDebtUsd
# here — no buffer is seeded). Fixed: pool market orders walk the ladder like
# every other taker (the AMM's deepest quote on that side, or ±2% of mid when
# it is not quoting there); the remainder re-stages for MAX_REDEFER requotes
# and then drops with a record. The close is still ACCEPTED — bounded in
# price, never refused (the control below fills it against a fair quote).
#
# A FRESH market per fixture: the AMM's volatility regime samples every
# REQUOTED mark move (EMA of squared log returns, half-spread up to 50%), so
# the ±71% jumps a BTC fixture would need widen the ladder past a 5% entry
# cap. ETH here (+17% takes health from 1.37 to 1.17); ICP-ICPUSD in §F2.
FID=imgf; mdx_identity_new $FID
FP=$(icp identity principal --identity $FID 2>/dev/null | tail -1)
fusr() { icp canister call --candid "$MDX_CANDID" --identity $FID backend "$@" 2>&1; }
CID=imgc; mdx_identity_new $CID
CP=$(icp identity principal --identity $CID 2>/dev/null | tail -1)
cusr() { icp canister call --candid "$MDX_CANDID" --identity $CID backend "$@" 2>&1; }
frel()  { adm setAmmRefPrice "(\"$1\", $(e8 $2) : nat)" >/dev/null; adm requoteAmm "(\"$1\")" >/dev/null; }
sfld()  { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "\-?[0-9]+"; }   # SIGNED field (equityUsd, size)
fnord() { fusr getPoolOrders "($1 : nat)" | grep -c "id ="; }
takeable() { adm getTakeableDepth "(\"$1\", variant { buy }, $(e8 $2) : nat)" | tr -d '_' | grep -oE "[0-9]+" | head -1; }
FM="ETH-ICPUSD"
adm createAmmPool "(\"$FM\")" >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"$FM\", $(e8 3000.0) : nat)" >/dev/null
adm setAmmConfig "(\"$FM\", 30:nat, $(e8 5.0) : nat, 8:nat, 25:nat)"   # 40 ETH a side: the 9 ETH entry fills in ONE release (a pre-H-05 pool order dropped its remainder after one) >/dev/null 2>&1 || true
adm enableAmm "(\"$FM\", true)" >/dev/null 2>&1 || true
adm setTestBalance "(principal \"$AMM\", \"ETH\",    $(e8 10000.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 100000000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$FP\",  \"ICPUSD\", $(e8 50000.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$CP\",  \"ETH\",    $(e8 100.0) : nat)"       >/dev/null
frel $FM 3000.0
FR=$(fusr createMarginPool '("h05 pool", false)')
FPID=$(echo "$FR" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
fusr fundMarginPool "($FPID, $(e8 10000.0) : nat)" >/dev/null
# 9 ETH short at 3,000 = $27k notional on $10k: health at the BORROW gate = (10k + 27k × 0.9 LTV) / 27k ≈ 1.27
# (clears the 1.25 initial gate); after the sale the pool holds ≈ $36.9k of quote, owes 9 ETH.
SO=$(fusr openPosition "($FPID, \"$FM\", variant { sell }, $(e8 9.0) : nat, $(e8 0.05) : nat, null)")
if mdx_ok "$SO"; then ok "F: 9 ETH short staged on a \$10k pool"; else nok "F: short should stage" "$SO"; fi
frel $FM 3000.0; frel $FM 3000.0; frel $FM 3000.0
FSZ=$(sfld size "$(fusr getMyPositions '()')")
if [ -n "${FSZ:-}" ] && [ "$FSZ" -le "-$(e8 8.9)" ]; then ok "F: pool is net SHORT (size $(from_e8 "$FSZ") ETH)"; else nok "F: pool should be short 9 ETH" "size=$FSZ"; fi
# Mark 3,000 → 3,513: the short owes 9 × 3,513 = $31.6k against ≈ $36.9k of
# quote → health ≈ 1.17 (above maintenance 1.15 — nothing liquidates — and
# below initial 1.25). Then AMM ETH → 0: the requote withdraws the asks.
frel $FM 3513.0
FHR=$(fld healthRatio "$(fusr getMyMarginPools '()')")
if [ -n "${FHR:-}" ] && [ "$FHR" -ge "$(e8 1.15)" ] && [ "$FHR" -le "$(e8 1.25)" ]; then ok "F: pool at health $(from_e8 "$FHR") (1.15 ≤ h ≤ 1.25)"; else nok "F: expected health ≈ 1.17" "healthRatio=$FHR"; fi
adm setTestBalance "(principal \"$AMM\", \"ETH\", 0 : nat)" >/dev/null
frel $FM 3513.0
TK0=$(takeable $FM 4400.0)
if [ "${TK0:-x}" = "0" ]; then ok "F: AMM ask side withdrawn (nothing takeable up to +25%)"; else nok "F: expected an empty ask side" "takeable=$TK0"; fi
# The colluder rests 20 ETH at 4,380 — just inside the close's 25% ceiling
# (3,513 × 1.25 = 4,391.25) and far outside the ±2% band (3,583.26).
CA=$(cusr placeLimitOrder "(\"$FM\", variant { sell }, $(e8 4380.0) : nat, $(e8 20.0) : nat)")
mdx_ok "$CA" || nok "F: colluding ask" "$CA"
frel $FM 3513.0
TK1=$(takeable $FM 4400.0)
if [ -n "${TK1:-}" ] && [ "$TK1" -gt 0 ]; then ok "F: colluding ask rests at 4,380 (takeable within the 25% ceiling: $(from_e8 "$TK1") ETH)"; else nok "F: colluding ask should rest" "takeable=$TK1 place=$CA"; fi
UBD_F0=$(fld uncoveredBadDebtUsd "$(adm getInsuranceFund '()')")
FC=$(fusr closePosition "($FPID, \"$FM\", $(e8 0.25) : nat, null)")
if mdx_ok "$FC"; then ok "F: close(25%) ACCEPTED — closing stays available"; else nok "F: a close must never be refused" "$FC"; fi
# Seven fresh requotes: MAX_REDEFER (5) re-stagings, the drop, one spare.
for _ in 1 2 3 4 5 6 7; do frel $FM 3513.0; done
CF=$(fld filled "$(cusr getMyOrders '()')")
if [ "${CF:-x}" = "0" ]; then ok "F: the colluding ask was NOT lifted (filled 0)"; else nok "F: the pool close lifted the 25%-edge ask (pre-H-05: no ladder-edge cap for pools)" "filled=$CF"; fi
FSZ2=$(sfld size "$(fusr getMyPositions '()')")
if [ -n "${FSZ2:-}" ] && [ "$FSZ2" -le "-$(e8 8.9)" ]; then ok "F: position intact (size $(from_e8 "$FSZ2") ETH) — bounded, not filled through equity"; else nok "F: the short should be untouched" "size=$FSZ2"; fi
FEQ=$(sfld equityUsd "$(fusr getMyMarginPools '()')")
if [ -n "${FEQ:-}" ] && [ "$FEQ" -gt 0 ]; then ok "F: pool equity stays positive (\$$(from_e8 "$FEQ"))"; else nok "F: equity went negative" "equityUsd=$FEQ"; fi
if [ "$(fnord "$FPID")" = "0" ]; then ok "F: the walked close dropped after MAX_REDEFER requotes (no pool order remains)"; else nok "F: expected the close to drop after its walks" "$(fusr getPoolOrders "($FPID : nat)" | head -c 300)"; fi
RJF=$(fusr getMyReleaseRejections '()')
if echo "$RJF" | grep -q "remainder dropped" && echo "$RJF" | grep -q 'slippage cap ($3583'; then ok "F: the drop record names the ±2% cap (\$3,583), not the 25% ceiling"; else nok "F: expected the ladder-edge/±2% drop record" "$(echo "$RJF" | tr '\n' ' ' | head -c 400)"; fi
adm adminRunLiquidationBatch "()" >/dev/null 2>&1
UBD_F1=$(fld uncoveredBadDebtUsd "$(adm getInsuranceFund '()')")
if [ "${UBD_F1:-x}" = "${UBD_F0:-y}" ]; then ok "F: no bad debt socialised by a voluntary close (uncoveredBadDebtUsd unchanged)"; else nok "F: absorbBadDebt reached from a voluntary close" "ubd $UBD_F0 → $UBD_F1"; fi
LQ=$(fusr getMyPoolLiquidations '()')
if ! echo "$LQ" | grep -q "debtRepaidUsd"; then ok "F: no liquidation event on the pool"; else nok "F: the pool was liquidated" "$(echo "$LQ" | head -c 300)"; fi

echo "── F (control). the same close FILLS once a fair quote exists — bounded, never refused ──"
adm setTestBalance "(principal \"$AMM\", \"ETH\", $(e8 10000.0) : nat)" >/dev/null
frel $FM 3513.0
FC2=$(fusr closePosition "($FPID, \"$FM\", $(e8 0.10) : nat, null)")   # 10% cap: the +17% requote widened the ladder ≈ 2.5%
mdx_ok "$FC2" || nok "F control: close" "$FC2"
frel $FM 3513.0; frel $FM 3513.0; frel $FM 3513.0
FD=$(fld debtUsd "$(fusr getMyMarginPools '()')")
if ! fusr getMyPositions '()' | grep -q "$FM" && [ "${FD:-x}" = "0" ]; then ok "F control: flattened against the restored AMM ladder, debt 0"; else nok "F control: the close should fill" "debt=$FD pos=$(fusr getMyPositions '()' | head -c 200)"; fi
FEQ2=$(sfld equityUsd "$(fusr getMyMarginPools '()')")
if [ -n "${FEQ2:-}" ] && [ "$FEQ2" -gt 0 ]; then ok "F control: equity positive after the fair close (\$$(from_e8 "$FEQ2"))"; else nok "F control: equity" "equityUsd=$FEQ2"; fi

echo "── F2. H-05 (F1): the de-lever fill is EQUITY-BOUNDED — a thin pool releases only what its raw equity absorbs at the worst-case price; the rest re-stages ──"
# The belt behind the price cap: at ±2% the bound binds only when equity is
# thinner than the band's loss — a pool already under maintenance (health
# ≈ 1.01; the sweep is paused). The staged close is released by the expiry
# pass (users-only ctx: AMM sidelined, effLimit = mid + 2% = 14.8614) against
# a colluding ask INSIDE the band at 14.85 (+1.9%). The ICP stamp is backdated
# first so the post-fill liquidation hook defers (tryLiquidate refuses a stale
# mark) and the close's OWN outcome is what we read. Pre-fix the whole staged
# size (parkDeferred's cap-price trim of 2,100 → ≈1,696 ICP) filled and left
# raw equity ≈ −$180 (base debt with the quote gone); post-fix only the
# equity-safe quantity fills (≈ $320 / $0.306 per ICP ≈ 1,040), equity stays
# ≥ 0, the held rest re-stages and walks to its drop.
GID=imgg; mdx_identity_new $GID
GP=$(icp identity principal --identity $GID 2>/dev/null | tail -1)
gusr() { icp canister call --candid "$MDX_CANDID" --identity $GID backend "$@" 2>&1; }
HID=imgh; mdx_identity_new $HID
HP=$(icp identity principal --identity $HID 2>/dev/null | tail -1)
husr() { icp canister call --candid "$MDX_CANDID" --identity $HID backend "$@" 2>&1; }
gnord() { gusr getPoolOrders "($1 : nat)" | grep -c "id ="; }
goid()  { gusr getPoolOrders "($1 : nat)" | tr -d '_' | grep -oE "id = [0-9]+" | head -1 | grep -oE "[0-9]+"; }
gpass() {   # release the pool's ONE staged entry through the users-only expiry pass
  local oid; oid=$(goid "$1"); [ -z "${oid:-}" ] && return 1
  adm setTestDeferredExpiry "($oid : nat, 1 : int)" >/dev/null 2>&1
  adm adminRunDeferredExpiry "()" >/dev/null 2>&1
}
GM="ICP-ICPUSD"
adm createAmmPool "(\"$GM\")" >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"$GM\", $(e8 10.0) : nat)" >/dev/null
adm setAmmConfig "(\"$GM\", 30:nat, $(e8 500.0) : nat, 8:nat, 25:nat)"   # 4,000 ICP a side >/dev/null 2>&1 || true
adm enableAmm "(\"$GM\", true)" >/dev/null 2>&1 || true
adm setTestBalance "(principal \"$AMM\", \"ICP\",    $(e8 1000000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$GP\",  \"ICPUSD\", $(e8 50000.0) : nat)"   >/dev/null
adm setTestBalance "(principal \"$HP\",  \"ICP\",    $(e8 20000.0) : nat)"   >/dev/null
frel $GM 10.0
GR=$(gusr createMarginPool '("h05 thin", false)')
GPID=$(echo "$GR" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
gusr fundMarginPool "($GPID, $(e8 10000.0) : nat)" >/dev/null
# 2,100 ICP short at $10 = $21k on $10k → borrow-gate health (10k + 21k × 0.8 LTV) / 21k ≈ 1.28.
GO=$(gusr openPosition "($GPID, \"$GM\", variant { sell }, $(e8 2100.0) : nat, $(e8 0.05) : nat, null)")
mdx_ok "$GO" || nok "F2: short should stage" "$GO"
frel $GM 10.0; frel $GM 10.0; frel $GM 10.0
GSZ=$(sfld size "$(gusr getMyPositions '()')")
if [ -n "${GSZ:-}" ] && [ "$GSZ" -le "-$(e8 2090.0)" ]; then ok "F2: pool is net SHORT (size $(from_e8 "$GSZ") ICP)"; else nok "F2: pool should be short 2,100 ICP" "size=$GSZ"; fi
# Mark $10 → $14.57: debt 2,100 × 14.57 = $30.6k against ≈ $30.9k of quote →
# health ≈ 1.01, raw equity ≈ $320. AMM ICP → 0 withdraws the asks (the
# users-only release below sidelines the whole AMM anyway).
adm setTestBalance "(principal \"$AMM\", \"ICP\", 0 : nat)" >/dev/null
frel $GM 14.57
GEQ0=$(sfld equityUsd "$(gusr getMyMarginPools '()')")
if [ -n "${GEQ0:-}" ] && [ "$GEQ0" -gt 0 ] && [ "$GEQ0" -lt "$(e8 1000)" ]; then ok "F2: raw equity thin and positive (\$$(from_e8 "$GEQ0") on \$30.6k of debt)"; else nok "F2: expected ≈ \$320 of equity" "equityUsd=$GEQ0"; fi
CA2=$(husr placeLimitOrder "(\"$GM\", variant { sell }, $(e8 14.85) : nat, $(e8 5000.0) : nat)")
mdx_ok "$CA2" || nok "F2: colluding ask" "$CA2"
frel $GM 14.57
GC=$(gusr closePosition "($GPID, \"$GM\", $(e8 0.25) : nat, null)")
if mdx_ok "$GC"; then ok "F2: close(25%) accepted on the thin pool"; else nok "F2: close refused" "$GC"; fi
# Task 1788557389: the close's reservation is sized at the MARK, not the 25 %
# cap — 2,100 × 14.57 + fee ≈ $30.6k fits the pool's ≈ $30.9k of free quote,
# so the WHOLE short stages (pre-fix: parkDeferred trimmed it to ≈ 1,696 ICP
# at the cap price 18.21 and the rest was never re-staged — a silent residual
# short). The price cap and the equity bound at RELEASE, not the reservation,
# bound what fills. No un-staged remainder → no "staged N of M" record.
GSQ=$(fld quantity "$(gusr getPoolOrders "($GPID : nat)")")
if [ -n "${GSQ:-}" ] && [ "$GSQ" -ge "$(e8 2099.99)" ]; then ok "F2: the WHOLE 2,100 ICP short staged ($(from_e8 "$GSQ") ICP — reservation sized at the mark, not the cap)"; else nok "F2: expected the whole position to stage (pre-fix: cap-price trim to ≈ 1,696 ICP)" "staged=$GSQ"; fi
if gusr getMyReleaseRejections '()' | grep -q "is NOT staged"; then nok "F2: no un-staged remainder should be recorded when the whole close stages" "$(gusr getMyReleaseRejections '()' | tr '\n' ' ' | head -c 300)"; else ok "F2: no 'Staged N of M … is NOT staged' record (nothing was left un-staged)"; fi
NOW_NS=$(( $(date +%s) * 1000000000 ))
adm setTestRefPriceUpdatedNs "(\"$GM\", $(( NOW_NS - 400000000000 )) : int)" >/dev/null
gpass "$GPID"
GEQ1=$(sfld equityUsd "$(gusr getMyMarginPools '()')")
CF2=$(fld filled "$(husr getMyOrders '()')")
if [ -n "${GEQ1:-}" ] && [ "$GEQ1" -ge 0 ]; then ok "F2: post-fill raw equity ≥ 0 (\$$(from_e8 "$GEQ1"))"; else nok "F2: the close filled through the pool's equity (pre-H-05: price-blind de-lever escape)" "equityUsd=$GEQ1 (pre \$$(from_e8 "${GEQ0:-0}"))"; fi
if [ -n "${CF2:-}" ] && [ "$CF2" -gt 0 ] && [ "$CF2" -lt "$(e8 1500.0)" ]; then ok "F2: only the equity-safe quantity filled ($(from_e8 "$CF2") ICP of the 2,100 short)"; else nok "F2: expected a bounded PARTIAL fill (< 1,500 ICP)" "filled=$CF2"; fi
if [ "$(gnord "$GPID")" = "1" ]; then ok "F2: the held remainder re-staged (one pool order pending)"; else nok "F2: expected the held quantity to re-stage" "orders=$(gnord "$GPID")"; fi
RJG=$(gusr getMyReleaseRejections '()')
if echo "$RJG" | grep -q "would leave the pool with negative equity"; then ok "F2: the release record names the equity bound"; else nok "F2: expected the equity-bound record" "$(echo "$RJG" | tr '\n' ' ' | head -c 400)"; fi
for _ in 1 2 3 4 5 6 7; do gpass "$GPID" || break; done
# Dust tolerance (one cent): a pool parked at equity ≈ 0 bleeds CARRY between
# expiry passes (10% APR on ~$15k of ICP debt ≈ $0.0005 per 10 s) — every
# walk re-reads the ACCRUED equity before it bounds, so no fill ever pushes
# equity below what interest already did. The bound is about the fill.
GEQ2=$(sfld equityUsd "$(gusr getMyMarginPools '()')")
if [ -n "${GEQ2:-}" ] && [ "$GEQ2" -ge -1000000 ]; then ok "F2: equity still ≥ 0 (± a cent of carry) after the walks (\$$(from_e8 "$GEQ2"))"; else nok "F2: a later walk breached equity" "equityUsd=$GEQ2"; fi
if [ "$(gnord "$GPID")" = "0" ]; then ok "F2: the walked remainder dropped (no pool order remains)"; else nok "F2: expected the remainder to drop after MAX_REDEFER walks" "orders=$(gnord "$GPID")"; fi
frel $GM 14.57

echo "── F3. task 1788557389: a close the free quote cannot cover even at the MARK stages what it can and RECORDS the un-staged rest ──"
# The pool §F2 leaves behind: ≈ 1,336 ICP still short at raw equity ≈ 0, so
# its free quote ≈ the debt at 14.57. Mark → 14.80 (+1.6 %): the buy-back
# costs ≈ $19.8k against ≈ $19.5k of free quote, so even the mark-sized
# reservation covers less than the position. The close is still accepted
# (always available), stages the covered part, and the un-staged remainder is
# RECORDED — pre-task the trim was silent (#ok, a residual short, no record).
frel $GM 14.80
GSZ3=$(sfld size "$(gusr getMyPositions '()')")
ASK3=${GSZ3#-}
GC3=$(gusr closePosition "($GPID, \"$GM\", $(e8 0.25) : nat, null)")
mdx_ok "$GC3" || nok "F3: the close should still be accepted" "$GC3"
GSQ3=$(fld quantity "$(gusr getPoolOrders "($GPID : nat)")")
if [ -n "${GSQ3:-}" ] && [ -n "${ASK3:-}" ] && [ "$GSQ3" -gt 0 ] && [ "$GSQ3" -lt "$ASK3" ]; then ok "F3: staged what the free quote covers at the mark ($(from_e8 "$GSQ3") of $(from_e8 "$ASK3") ICP)"; else nok "F3: expected a PARTIAL staging (free quote below the size at the mark)" "staged=$GSQ3 size=$GSZ3"; fi
RJ3=$(gusr getMyReleaseRejections '()')
if echo "$RJ3" | grep -q "is NOT staged"; then ok "F3: the un-staged remainder is RECORDED (getMyReleaseRejections: 'Staged N of M … is NOT staged')"; else nok "F3: expected the un-staged-remainder record (pre-task: silent trim)" "$(echo "$RJ3" | tr '\n' ' ' | tail -c 400)"; fi
GOID3=$(goid "$GPID"); if [ -n "${GOID3:-}" ]; then gusr cancelPoolOrder "($GPID : nat, $GOID3 : nat)" >/dev/null 2>&1 || true; fi
frel $GM 14.57


echo "── G. H-34 / D5 option (d): leverage is borrowed AT THE FILL — a staged or resting entry holds ZERO vault debt ──"
# Operator ruling (tasks/archive/1788467597, 2026-09-05): a leveraged entry
# reserves NOTHING from the vault until it executes. openPosition only CHECKS
# the borrow and stages; the engine's fundForFill hook (poolFundForFill)
# borrows exactly each slice's shortfall at the fill, on fresh marks, and a
# vault that cannot lend at that instant fails the slice CLOSED — nothing
# settles, the remainder is cancelled with ONE notice naming the reason.
# Pre-fix (main 8ae4549's src): openPosition pre-borrowed the whole size at
# the price ceiling at PLACEMENT — the resting bid below carried ≈ $9.8k of
# vault debt and interest from the moment it was staged, the vault's balance
# and vaultLentOutUsd moved at placement, and a dry vault at the fill was
# irrelevant (the money had already left).
GID=imgg; mdx_identity_new $GID
GP=$(icp identity principal --identity $GID 2>/dev/null | tail -1)
gusr() { icp canister call --candid "$MDX_CANDID" --identity $GID backend "$@" 2>&1; }
MID=imgmk; mdx_identity_new $MID
MP=$(icp identity principal --identity $MID 2>/dev/null | tail -1)
musr() { icp canister call --candid "$MDX_CANDID" --identity $MID backend "$@" 2>&1; }
gnord() { gusr getPoolOrders "($1 : nat)" | grep -c "id ="; }
goid()  { gusr getPoolOrders "($1 : nat)" | tr -d '_' | grep -oE "id = [0-9]+" | head -1 | grep -oE "[0-9]+"; }
gbal()  { adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+" | head -1; }
glent() { yes | gusr getMaxInstantWithdraw '()' | tr -d '_' | grep -oE 'vaultLentOutUsd = [0-9]+' | head -1 | grep -oE '[0-9]+$'; }
gdebt() { fld debtUsd "$(gusr getMyMarginPools '()')"; }
# Release a staged USER order through the users-only expiry pass (AMM
# sidelined): the maker's sell must meet the POOL's resting bid, not the
# AMM's better bid — this is the pool-as-MAKER borrow-at-fill path.
users_only_release() {   # users_only_release <identity>
  local sid
  sid=$(icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyStagedOrderIds '()' --query 2>/dev/null | tr -d '_' | grep -oE '[0-9]+' | head -1)
  adm setTestDeferredExpiry "(${sid:-0} : nat, 1 : int)" >/dev/null 2>&1
  adm adminRunDeferredExpiry "()" >/dev/null 2>&1
}
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 10000000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$AMM\", \"BTC\",    $(e8 100.0) : nat)"      >/dev/null
adm setTestBalance "(principal \"$GP\",  \"ICPUSD\", $(e8 50000.0) : nat)"    >/dev/null
adm setTestBalance "(principal \"$MP\",  \"BTC\",    $(e8 10.0) : nat)"       >/dev/null
release
GR=$(gusr createMarginPool '("h34 pool", false)')
GPID=$(echo "$GR" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
gusr fundMarginPool "($GPID, $(e8 10000.0) : nat)" >/dev/null
GV0=$(gbal "$AMM" ICPUSD); GL0=$(glent)
[ -n "${GPID:-}" ] && [ "$(gdebt)" = "0" ] && ok "G: pool $GPID funded \$10k, debt 0; vault \$$(from_e8 "$GV0"), lent out \$$(from_e8 "${GL0:-0}")" || nok "G: pool setup" "id=$GPID debt=$(gdebt)"

echo "── G1. a #limit long 0.4 BTC @ 49,500 (\$19.8k on \$10k) stages and RESTS with ZERO vault debt; the vault and getMaxInstantWithdraw do not move ──"
GO=$(gusr openPosition "($GPID, \"BTC-ICPUSD\", variant { buy }, $(e8 0.4) : nat, $(e8 0.05) : nat, opt ($(e8 49500.0) : nat))")
if mdx_ok "$GO"; then ok "G1: leveraged #limit entry accepted (the borrow is CHECKED, not taken)"; else nok "G1: openPosition #limit" "$GO"; fi
GD1=$(gdebt); GV1=$(gbal "$AMM" ICPUSD); GL1=$(glent)
if [ "${GD1:-x}" = "0" ]; then ok "G1: STAGED entry → pool debt exactly 0 (no placement-time borrow)"; else nok "G1: a staged entry must hold no vault debt" "debtUsd=$GD1"; fi
if [ "${GV1:-0}" = "${GV0:-1}" ]; then ok "G1: vault balance unmoved by the staging (\$$(from_e8 "$GV1"))"; else nok "G1: the vault lent at placement" "V0=$GV0 V1=$GV1"; fi
release   # fresh mark postdates the entry → releases; 49,500 sits under the AMM's asks → RESTS as the pool
GD2=$(gdebt); GV2=$(gbal "$AMM" ICPUSD); GL2=$(glent); GN2=$(gnord "$GPID")
if [ "${GN2:-0}" = "1" ] && [ "${GD2:-x}" = "0" ]; then ok "G1: RESTING entry (1 pool order) → pool debt still exactly 0"; else nok "G1: a resting entry must hold no vault debt" "orders=$GN2 debtUsd=$GD2"; fi
if [ "${GV2:-0}" = "${GV0:-1}" ]; then ok "G1: vault balance unmoved by the resting entry"; else nok "G1: vault moved while the entry rests" "V0=$GV0 V2=$GV2"; fi
# "Unmoved" means NO BORROW HAPPENED, not a byte-equal read (the same frame as
# G3's debt check): vaultLentOutUsd sums the loan book's PRINCIPALS at the
# marks, and the requote inside `release` accrues the loans earlier sections
# leave open (§E's re-levered pool, §F3's ICP short) — a few seconds of carry,
# ≈ 10k units/s here (observed +23,370 / +25,600 over one release, task
# 1793732895). So the STAGED read is exact and the RESTING read may carry
# that interest: 0 ≤ delta < 1_000_000 units (one cent); a placement-time
# borrow would add ≥ $9,800.
GLD=$(( ${GL2:-0} - ${GL0:-0} ))
if [ -n "${GL0:-}" ] && [ "${GL1:-x}" = "$GL0" ] && [ "$GLD" -ge 0 ] && [ "$GLD" -lt 1000000 ]; then ok "G1: getMaxInstantWithdraw.vaultLentOutUsd unmoved by a staged AND a resting entry (\$$(from_e8 "$GL0"); resting read +$GLD units of requote carry on earlier loans, < \$0.01, no borrow)"; else nok "G1: LP instant liquidity must not move for an unfilled entry" "lent: before=$GL0 staged=$GL1 resting=$GL2 (bound: staged exact, resting 0 ≤ delta < 1_000_000)"; fi
# Cancel repays NOTHING (there is nothing): debt 0 → 0, vault untouched.
GOID=$(goid "$GPID")
GX=$(gusr cancelPoolOrder "($GPID : nat, ${GOID:-0} : nat)")
if mdx_ok "$GX" && [ "$(gdebt)" = "0" ] && [ "$(gbal "$AMM" ICPUSD)" = "$GV0" ] && [ "$(gnord "$GPID")" = "0" ]; then ok "G1: cancelling the resting entry — debt 0 → 0, vault untouched, no order left"; else nok "G1: cancel of a debt-free entry" "cancel=$(echo "$GX" | head -c 120) debt=$(gdebt) orders=$(gnord "$GPID")"; fi

echo "── G2. the FILL borrows exactly its quantity: a maker sells 0.4 @ 49,500 into the resting pool bid → debt == cost + maker fee − own quote, to the unit ──"
GO=$(gusr openPosition "($GPID, \"BTC-ICPUSD\", variant { buy }, $(e8 0.4) : nat, $(e8 0.05) : nat, opt ($(e8 49500.0) : nat))")
mdx_ok "$GO" || nok "G2: openPosition #limit" "$GO"
release
[ "$(gnord "$GPID")" = "1" ] && [ "$(gdebt)" = "0" ] && ok "G2: bid rests, debt 0 (fixture)" || nok "G2 fixture: resting bid with zero debt" "orders=$(gnord "$GPID") debt=$(gdebt)"
sleep 3   # a resting period: pre-fix this is where carry accrued on a borrow nobody was using
GA=$(musr placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 49500.0) : nat, $(e8 0.4) : nat)")
mdx_ok "$GA" || nok "G2: maker ask" "$GA"
users_only_release $MID   # AMM sidelined → the ask meets the pool's bid; the pool is the MAKER and borrows at THIS fill
GSZ=$(sfld size "$(gusr getMyPositions '()')")
GD3=$(gdebt); GV3=$(gbal "$AMM" ICPUSD)
# cost 0.4 × 49,500 = $19,800; the pool pays the L0 MAKER fee (5 bps, floored)
# = $9.90; own quote $10,000 → the fill borrows $9,809.90 exactly.
GEXP=$(( $(e8 19800.0) + $(e8 19800.0) * 5 / 10000 - $(e8 10000.0) ))
if [ "${GSZ:-0}" = "$(e8 0.4)" ]; then ok "G2: the resting pool bid FILLED (long 0.4 BTC) — the maker path borrowed at the fill"; else nok "G2: the pool's resting entry should fill against the ask" "size=$GSZ"; fi
if [ -n "${GD3:-}" ] && [ "$GD3" -ge "$GEXP" ] && [ "$GD3" -le $((GEXP + 1000000)) ]; then ok "G2: debt \$$(from_e8 "$GD3") == the fill's shortfall (\$$(from_e8 "$GEXP") = cost + maker fee − own quote) to the unit — nothing borrowed beyond what filled, no carry from the resting period (interest accrues from the FILL)"; else nok "G2: the fill must borrow exactly its own shortfall" "debtUsd=$GD3 expected=$GEXP (pre-fix: a cap-sized placement borrow, trimmed and partly repaid)"; fi
# The vault ALSO receives its 50 % share of both legs' fees (LP_FEE_SHARE_BPS:
# maker 5 bps + taker 10 bps on $19,800 → $29.70, half of it $14.85), so its
# balance moves by exactly (borrow − fee share).
GSHARE=$(( ( $(e8 19800.0) * 5 / 10000 + $(e8 19800.0) * 10 / 10000 ) / 2 ))
if [ "${GV3:-0}" = "$((GV0 - GEXP + GSHARE))" ]; then ok "G2: the vault lent exactly that amount at the fill (\$$(from_e8 "$GV0") → \$$(from_e8 "$GV3"): −\$$(from_e8 "$GEXP") lent + \$$(from_e8 "$GSHARE") LP fee share)"; else nok "G2: vault balance should drop by exactly the fill's borrow net of its fee share" "V0=$GV0 V3=$GV3 exp=$((GV0 - GEXP + GSHARE))"; fi
if [ "$(gnord "$GPID")" = "0" ]; then ok "G2: no pool order remains (fully filled)"; else nok "G2: leftover pool order" "$(gusr getPoolOrders "($GPID : nat)" | head -c 200)"; fi

echo "── G3. vault DRY at the fill → the slice fails CLOSED: no fill, the pool's remainder cancelled, ONE notice naming the vault, state otherwise identical ──"
# A second entry (0.2 BTC @ 49,500): the placement CHECK passes (the vault is
# full and the pool's health has room), it rests — then the vault runs dry
# BEFORE a maker hits it. Pre-fix the money had left the vault at placement
# and the fill went through regardless.
GO=$(gusr openPosition "($GPID, \"BTC-ICPUSD\", variant { buy }, $(e8 0.2) : nat, $(e8 0.05) : nat, opt ($(e8 49500.0) : nat))")
mdx_ok "$GO" || nok "G3: second openPosition #limit" "$GO"
release
[ "$(gnord "$GPID")" = "1" ] && ok "G3: second bid rests (fixture)" || nok "G3 fixture: second resting bid" "orders=$(gnord "$GPID")"
GD4=$(gdebt); GRJ0=$(gusr getMyReleaseRejections '()' | grep -c "vault could not lend" || true)
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", 0 : nat)" >/dev/null   # the vault has nothing to lend: borrow cap 0.5 × 0
GA=$(musr placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 49500.0) : nat, $(e8 0.2) : nat)")
mdx_ok "$GA" || nok "G3: maker ask" "$GA"
users_only_release $MID
GSZ5=$(sfld size "$(gusr getMyPositions '()')")
GD5=$(gdebt); GN5=$(gnord "$GPID")
GRJ1=$(gusr getMyReleaseRejections '()' | grep -c "vault could not lend" || true)
MF=$(musr getMyOrders '()' | tr -d '_' | grep -oE 'filled = [0-9]+' | head -1 | grep -oE '[0-9]+$')
if [ "${GSZ5:-0}" = "$(e8 0.4)" ]; then ok "G3: NOTHING filled — position unchanged at 0.4 BTC (no partial settlement)"; else nok "G3: a dry vault must fail the fill closed" "size=$GSZ5 (pre-fix: 0.6 — the placement borrow paid for it)"; fi
# "Debt unchanged" means NO BORROW HAPPENED — it is not a byte-equal read.
# Both figures come back accrued to their own read clock (myMarginPoolsOf
# accrueAlls before its loan reads, task 1788730982), and the refused slice's
# cancel path (releaseDeferred → cancelPoolRestingOrder → deleveragePool)
# accrues the standing $9,810 loan FIRST (task 1788515291's "accrue before
# you read the debt") even though nothing is repaid — so the pool's debt
# moves by the seconds of 5 % APR carry between the two reads (≈ 1,555
# units/s here; observed +3,2xx over ~2 s of CLI latency). The tolerance
# below IS that interest deleveragePool books on the cancel path: after ≥
# before, and the move stays under one cent (1_000_000 units ≈ 10 min of
# carry) — a real borrow would add ≥ $9,900 (0.2 BTC @ 49,500 − nothing).
GIPS=$(( ${GD4:-0} * 5 / 100 / 31536000 ))   # interest per second at 5 % APR on the before figure
GDD=$(( ${GD5:-0} - ${GD4:-0} ))
if [ -n "${GD5:-}" ] && [ -n "${GD4:-}" ] && [ "$GDD" -ge 0 ] && [ "$GDD" -lt 1000000 ]; then ok "G3: debt unchanged but for accrued carry — \$$(from_e8 "$GD4") → \$$(from_e8 "$GD5") (+$GDD units ≈ $(( GIPS > 0 ? GDD / GIPS : 0 )) s of 5 % APR: the interest deleveragePool books on the cancel path; < \$0.01, no borrow)"; else nok "G3: debt moved on a refused fill by more than the cancel path's interest accrual" "before=$GD4 after=$GD5 delta=$GDD (bound: 0 ≤ delta < 1_000_000 = \$0.01)"; fi
if [ "${GN5:-1}" = "0" ]; then ok "G3: the pool's resting remainder was CANCELLED, not left resting or re-parked"; else nok "G3: the unfundable remainder must be cancelled" "orders=$GN5"; fi
if [ $((GRJ1 - GRJ0)) -eq 1 ]; then ok "G3: exactly ONE notice, naming the vault ('vault could not lend … ' in getMyReleaseRejections)"; else nok "G3: expected exactly one vault-refusal notice" "before=$GRJ0 after=$GRJ1 :: $(gusr getMyReleaseRejections '()' | tr '\n' ' ' | tail -c 400)"; fi
if [ "${MF:-x}" = "0" ]; then ok "G3: the maker's ask is untouched (filled 0 — its counterparty vanished, it rests on)"; else nok "G3: the maker must not have been filled" "filled=$MF"; fi
if [ "$(gbal "$AMM" ICPUSD)" = "0" ]; then ok "G3: vault balance untouched (still 0 — nothing was lent)"; else nok "G3: vault moved" "$(gbal "$AMM" ICPUSD)"; fi
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 10000000.0) : nat)" >/dev/null
musr cancelAllMyOrders '()' >/dev/null 2>&1 || true

echo "── G4. the #market shape: a staged #market entry adds no debt; its fill against the AMM borrows ──"
GO=$(gusr openPosition "($GPID, \"BTC-ICPUSD\", variant { buy }, $(e8 0.2) : nat, $(e8 0.01) : nat, null)")
GD7=$(gdebt)
# (The placement CHECK accrues the standing loan to now — a few units of
# interest dust move; the entry itself adds nothing.)
if mdx_ok "$GO" && [ -n "${GD7:-}" ] && [ "$GD7" -ge "${GD5:-0}" ] && [ "$GD7" -le $(( ${GD5:-0} + 1000000 )) ] && [ "$(gnord "$GPID")" = "1" ]; then ok "G4: a staged #market entry adds NO debt (\$$(from_e8 "$GD5") → \$$(from_e8 "$GD7"), interest dust only; one pool order pending — timers paused, nothing releases it)"; else nok "G4: staged #market entry" "$GO debt: before=$GD5 after=$GD7 orders=$(gnord "$GPID")"; fi
release   # the fresh AMM ladder releases and fills it (4 BTC a side)
GSZ8=$(sfld size "$(gusr getMyPositions '()')"); GD8=$(gdebt)
if [ -n "${GSZ8:-}" ] && [ "$GSZ8" -gt "$(e8 0.4)" ] && [ -n "${GD8:-}" ] && [ "$GD8" -gt "${GD7:-0}" ]; then ok "G4: the fill borrowed — long 0.4 → $(from_e8 "$GSZ8") BTC, debt \$$(from_e8 "$GD7") → \$$(from_e8 "$GD8")"; else nok "G4: the #market fill should borrow at the fill" "size=$GSZ8 debt=${GD7}→${GD8} orders=$(gnord "$GPID")"; fi

echo "── H. task 1793732895: previewOpenPosition judges a LONG by the release clamp — canOpen / maxSizeBase / est. liq say what the fill will be held to ──"
# A fresh pool with $10k of margin, BTC at 50,000 (LTV 0.90). The BORROW gate
# alone (the borrowed quote at LTV 1.0) allows notional 5 × margin = 1.0 BTC;
# the release clamp (clampToInitialMargin — the whole fill scored as borrowed:
# coll + q·0.9·50,000 ≥ 1.25·q·50,000) holds a fresh pool to
# m / (1.25 × 50,000 − 0.9 × 50,000) = 10,000 / 17,500 = 0.57142857 BTC (2.86×),
# BorrowEngine.fillDeltaPerUnit / fillRoom — the closed form both now share.
# Pre-fix the preview answered canOpen = true, "capacity ~1.0 BTC" and an est.
# liq ABOVE the entry for the 1.0-BTC long; the release then cut it to 0.5714
# with an "Order reduced at release" record (the engine, 2026-11-03: 10,000 ICP
# at 5×, ~4,444 released). A LIMIT entry makes the release's worst-case price
# the preview's exactly (no ladder-edge walk), so the two must be EQUAL to the
# base unit — §H5 places the orders and reads the release's own clampedTo.
LID=imgl; mdx_identity_new $LID
LP=$(icp identity principal --identity $LID 2>/dev/null | tail -1)
lusr() { icp canister call --candid "$MDX_CANDID" --identity $LID backend "$@" 2>&1; }
lq()   { icp canister call --candid "$MDX_CANDID" --identity $LID backend "$@" --query 2>&1; }
lnord() { lusr getPoolOrders "($1 : nat)" | grep -c "id ="; }
loid()  { lusr getPoolOrders "($1 : nat)" | tr -d '_' | grep -oE "id = [0-9]+" | head -1 | grep -oE "[0-9]+"; }
lreduced() { lusr getMyReleaseRejections '()' | grep -c "Order reduced at release" || true; }
pfld() { echo "$2" | tr -d '_' | grep -oE "$1 = (opt \\()?[0-9]+" | head -1 | grep -oE "[0-9]+$"; }   # candid prints an option as `opt (N : nat)`
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 10000000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$AMM\", \"BTC\",    $(e8 100.0) : nat)"      >/dev/null
adm setTestBalance "(principal \"$LP\",  \"ICPUSD\", $(e8 50000.0) : nat)"    >/dev/null
release
LR=$(lusr createMarginPool '("preview-clamp pool", false)')
LPID=$(echo "$LR" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
lusr fundMarginPool "($LPID, $(e8 10000.0) : nat)" >/dev/null
LC=$(fld collateralUsd "$(lusr getMyMarginPools '()')")
if [ "${LC:-0}" = "$(e8 10000)" ]; then ok "H: pool $LPID funded (\$10k collateral, no debt)"; else nok "H: pool setup" "coll=$LC"; fi
PX=$(e8 50000.0)
Q_CLAMP=57142857   # 10,000e8 × 1e8 / (1.25 × 50,000e8 − 0.9 × 50,000e8), rounded down — the clamp's exact quantity at the mark
pv()  { lq previewOpenPosition "($1, \"BTC-ICPUSD\", variant { $2 }, $3 : nat, $(e8 0.05) : nat, opt ($PX : nat), $4 : nat)"; }   # pv <poolId|null> <buy|sell> <size e8> <extraQuote e8> — a LIMIT at the mark
pvm() { lq previewOpenPosition "($1, \"BTC-ICPUSD\", variant { $2 }, $3 : nat, $(e8 0.05) : nat, null, 0 : nat)"; }              # the MARKET shape (5 % slippage cap)

echo "── H1. LONG 1.0 BTC (5×) at a 50,000 limit: canOpen = false, the reason names the initial-margin bound, maxSizeBase == the clamp's 0.57142857 BTC ──"
P5=$(pv "opt ($LPID : nat)" buy "$(e8 1.0)" 0)
if echo "$P5" | grep -q "canOpen = false"; then ok "H1: the 5× long is refused by the preview"; else nok "H1: the preview must refuse a 5× long (pre-fix: canOpen = true, capacity ~1.0 BTC)" "$P5"; fi
if echo "$P5" | grep -q "initial-margin bound"; then ok "H1: the reason names the initial-margin bound"; else nok "H1: the reason must name the initial-margin bound" "$P5"; fi
M5=$(pfld maxSizeBase "$P5")
if [ "${M5:-x}" = "$Q_CLAMP" ]; then ok "H1: maxSizeBase == $(from_e8 "$M5") BTC — the clamp's exact release quantity (2.86×), not the borrow gate's 1.0 BTC (5×)"; else nok "H1: maxSizeBase must equal the clamp's quantity" "got=$M5 expected=$Q_CLAMP"; fi
if echo "$P5" | grep -q "estLiqPrice = null"; then ok "H1: no est. liq for a size the release would cut"; else nok "H1: estLiqPrice should be null on a refusal" "$P5"; fi

echo "── H2. LONG 0.4 BTC (2×): canOpen = true, maxSizeBase ≥ size, est. liq BELOW the entry ──"
P2=$(pv "opt ($LPID : nat)" buy "$(e8 0.4)" 0)
if echo "$P2" | grep -q "canOpen = true"; then ok "H2: the 2× long is allowed"; else nok "H2: a 2× long must pass" "$P2"; fi
M2=$(pfld maxSizeBase "$P2"); L2=$(pfld estLiqPrice "$P2")
if [ -n "${M2:-}" ] && [ "$M2" -ge "$(e8 0.4)" ] && [ "$M2" = "$Q_CLAMP" ]; then ok "H2: maxSizeBase $(from_e8 "$M2") BTC ≥ 0.4 — and still the clamp's capacity, not the borrow gate's"; else nok "H2: capacity" "maxSizeBase=$M2"; fi
if [ -n "${L2:-}" ] && [ "$L2" -gt 0 ] && [ "$L2" -lt "$PX" ]; then ok "H2: est. liq \$$(from_e8 "$L2") < the \$50,000 entry — a long liquidates BELOW its entry"; else nok "H2: a long's est. liq must sit below its entry (pre-fix: liq above entry beside canOpen = true)" "estLiqPrice=$L2"; fi

echo "── H3. the UI's 'New pool (auto)' path — poolId = null, extraQuote = \$10k — and the MARKET shape answer the same way ──"
PN=$(pv null buy "$(e8 1.0)" "$(e8 10000.0)"); MN=$(pfld maxSizeBase "$PN")
if echo "$PN" | grep -q "canOpen = false" && [ "${MN:-x}" = "$Q_CLAMP" ]; then ok "H3: hypothetical fresh pool: 5× refused, maxSizeBase == $(from_e8 "$MN") BTC"; else nok "H3: the null-pool preview must match the funded pool's answer" "$PN"; fi
PN2=$(pv null buy "$(e8 0.4)" "$(e8 10000.0)")
if echo "$PN2" | grep -q "canOpen = true"; then ok "H3: …and its 2× long is allowed"; else nok "H3: null-pool 2× long" "$PN2"; fi
# The market shape's worst-case price is the 5 % cap (52,500): tighter, never looser.
PM=$(pvm "opt ($LPID : nat)" buy "$(e8 1.0)"); MM=$(pfld maxSizeBase "$PM")
if echo "$PM" | grep -q "canOpen = false" && [ -n "${MM:-}" ] && [ "$MM" -gt 0 ] && [ "$MM" -le "$Q_CLAMP" ]; then ok "H3: market 5× long refused too; capacity at the 52,500 cap is $(from_e8 "$MM") BTC ≤ the limit answer"; else nok "H3: market-shape preview" "$PM"; fi

echo "── H4. SHORTS unchanged: 3× refused by the borrow gate, 2× allowed with est. liq ABOVE the entry — and the same capacity as the long ──"
S3=$(pv "opt ($LPID : nat)" sell "$(e8 0.6)" 0)
if echo "$S3" | grep -q "canOpen = false" && echo "$S3" | grep -q "initial-margin requirement"; then ok "H4: 3× short refused by borrowCheck ((10k + 0.9 × 30k) / 30k = 1.23 < 1.25)"; else nok "H4: 3× short" "$S3"; fi
MS3=$(pfld maxSizeBase "$S3")
if [ "${MS3:-x}" = "$Q_CLAMP" ]; then ok "H4: the short's capacity is the same 0.57142857 BTC — longs and shorts now read one ceiling"; else nok "H4: short capacity" "maxSizeBase=$MS3"; fi
S2=$(pv "opt ($LPID : nat)" sell "$(e8 0.4)" 0); LS2=$(pfld estLiqPrice "$S2")
if echo "$S2" | grep -q "canOpen = true" && [ -n "${LS2:-}" ] && [ "$LS2" -gt "$PX" ]; then ok "H4: 2× short allowed, est. liq \$$(from_e8 "${LS2:-0}") > the entry"; else nok "H4: 2× short" "$S2"; fi

echo "── H5. the release AGREES: the 5× long is cut to exactly the preview's maxSizeBase (clampedTo); the 2× long the preview accepted is never 'reduced at release' ──"
# Placed at 49,500 (§G1's resting price: under the AMM's asks, so nothing
# fills and the pool stays clean between the two legs). The clamp at that
# limit: 10,000e8 × 1e8 / (1.25 × 49,500e8 − 0.9 × 50,000e8) = 0.59259259 BTC.
PXR=$(e8 49500.0); Q_REST=59259259
P5R=$(lq previewOpenPosition "(opt ($LPID : nat), \"BTC-ICPUSD\", variant { buy }, $(e8 1.0) : nat, $(e8 0.05) : nat, opt ($PXR : nat), 0 : nat)")
M5R=$(pfld maxSizeBase "$P5R")
if echo "$P5R" | grep -q "canOpen = false" && [ "${M5R:-x}" = "$Q_REST" ]; then ok "H5: preview at the 49,500 limit: refused, maxSizeBase $(from_e8 "$M5R") BTC"; else nok "H5: preview at 49,500" "$P5R"; fi
R0=$(lreduced)
O5=$(lusr openPosition "($LPID, \"BTC-ICPUSD\", variant { buy }, $(e8 1.0) : nat, $(e8 0.05) : nat, opt ($PXR : nat))")
if mdx_ok "$O5"; then ok "H5: the 5× limit entry stages (the placement gate is the borrow check, which 5× passes)"; else nok "H5: the 5× entry should stage" "$O5"; fi
release   # a fresh mark postdates the entry → releases; the clamp runs at the limit price; 49,500 sits under the asks → rests
RJH=$(lusr getMyReleaseRejections '()')
CT=$(echo "$RJH" | tr -d '_' | grep -oE 'clampedTo = opt \(?[0-9]+' | tail -1 | grep -oE '[0-9]+$')
if [ "$(lreduced)" -eq $((R0 + 1)) ] && [ "${CT:-x}" = "$M5R" ] && [ "${CT:-x}" = "$Q_REST" ]; then ok "H5: the release cut the 1.0-BTC long to clampedTo = $(from_e8 "$CT") BTC == the preview's maxSizeBase, to the base unit"; else nok "H5: the release's clamp and the preview's maxSizeBase must be the same number" "reduced=$(lreduced) (was $R0) clampedTo=$CT preview=$M5R expected=$Q_REST :: $(echo "$RJH" | tr '\n' ' ' | tail -c 300)"; fi
LOID=$(loid "$LPID"); [ -n "${LOID:-}" ] && lusr cancelPoolOrder "($LPID : nat, $LOID : nat)" >/dev/null 2>&1
if [ "$(lnord "$LPID")" = "0" ]; then ok "H5: the clamped remainder cancelled (clean pool)"; else nok "H5: cleanup" "orders=$(lnord "$LPID")"; fi
R1=$(lreduced)
O2=$(lusr openPosition "($LPID, \"BTC-ICPUSD\", variant { buy }, $(e8 0.4) : nat, $(e8 0.05) : nat, opt ($PXR : nat))")
if mdx_ok "$O2"; then ok "H5: the 2× entry stages"; else nok "H5: the 2× entry should stage" "$O2"; fi
release
if [ "$(lreduced)" -eq "$R1" ] && [ "$(lnord "$LPID")" = "1" ]; then ok "H5: the 2× long the preview accepted released in FULL — no 'Order reduced at release' record, the whole 0.4 BTC rests"; else nok "H5: a size the preview accepted must never be reduced at release" "reduced=$(lreduced) (was $R1) orders=$(lnord "$LPID") :: $(lusr getMyReleaseRejections '()' | tr '\n' ' ' | tail -c 300)"; fi
LOID2=$(loid "$LPID"); [ -n "${LOID2:-}" ] && lusr cancelPoolOrder "($LPID : nat, $LOID2 : nat)" >/dev/null 2>&1

echo "── H6. task 1793733917: SHORTS read the release clamp too — a MARKET short at a 20 % floor is bound by the clamp's post-sale rule (2.22×), at 5 % by the borrow gate (2.86×) ──"
# Two closed forms for a short on a fresh $10k pool, BTC @ 50,000 (LTV 0.90):
#   borrowCheck values the borrowed base at its LTV BEFORE the sale —
#     coll + q·0.9·50,000 ≥ 1.25·q·50,000 → q ≤ 10,000 / 17,500 = 0.57142857 BTC (2.86×, Q_CLAMP);
#   the release clamp (clampToInitialMargin; BorrowEngine.fillDeltaPerUnit's #sell
#   arm, qp − 1.25·oracle) scores the POST-sale world at the floor qp = 50,000·(1 − slip) —
#     coll + q·qp ≥ 1.25·q·50,000 → q ≤ 10,000 / (62,500 − qp):
#     20 % (qp 40,000): 10,000 / 22,500 = 0.44444444 BTC (2.22×); 5 % (qp 47,500): 0.66666666 BTC (3.33×).
# The clamp binds BELOW the borrow gate exactly when 1 − slip < LTV (BTC: past
# 10 % slippage). Pre-fix the preview ran the clamp for #buy only, so the 20 %
# short answered canOpen = true, maxSizeBase 0.57142857 (borrowCheck alone);
# now maxSizeBase = min(borrow room, clamp room) for either side and the
# refusal names "a short".
Q_SHORT20=44444444   # 10,000e8 × 1e8 / (1.25 × 50,000e8 − 40,000e8), rounded down — the clamp's quantity at the 20 % floor
pvs() { lq previewOpenPosition "($1, \"BTC-ICPUSD\", variant { sell }, $2 : nat, $3 : nat, null, $4 : nat)"; }   # pvs <poolId|null> <size e8> <maxSlippage e8> <extraQuote e8> — the MARKET short shape
S20=$(pvs "opt ($LPID : nat)" "$(e8 0.55)" "$(e8 0.20)" 0)
if echo "$S20" | grep -q "canOpen = false"; then ok "H6: the 2.75× market short at 20 % slippage is refused by the preview"; else nok "H6: the preview must refuse a 2.75× short at a 20 % floor (pre-fix: canOpen = true — borrowCheck's 2.86× alone)" "$S20"; fi
if echo "$S20" | grep -q "initial-margin bound for a short"; then ok "H6: the reason names the initial-margin bound for a SHORT"; else nok "H6: the reason must name the initial-margin bound for a short" "$S20"; fi
MS20=$(pfld maxSizeBase "$S20")
if [ "${MS20:-x}" = "$Q_SHORT20" ]; then ok "H6: maxSizeBase == $(from_e8 "$MS20") BTC — the clamp's quantity at the 40,000 floor (2.22×), under the borrow gate's 0.57142857"; else nok "H6: maxSizeBase must be the clamp's quantity at the floor" "got=$MS20 expected=$Q_SHORT20"; fi
if echo "$S20" | grep -q "estLiqPrice = null"; then ok "H6: no est. liq for a size the release would cut"; else nok "H6: estLiqPrice should be null on a refusal" "$S20"; fi
S05=$(pvs "opt ($LPID : nat)" "$(e8 0.55)" "$(e8 0.05)" 0); MS05=$(pfld maxSizeBase "$S05"); LS05=$(pfld estLiqPrice "$S05")
if echo "$S05" | grep -q "canOpen = true" && [ "${MS05:-x}" = "$Q_CLAMP" ]; then ok "H6: the same short at 5 % is allowed — the borrow gate binds at $(from_e8 "$MS05") BTC (the clamp's room at the 47,500 floor is 0.6667)"; else nok "H6: the 5 % short must pass with maxSizeBase == the borrow gate's 0.57142857" "$S05"; fi
if [ -n "${LS05:-}" ] && [ "$LS05" -gt "$PX" ]; then ok "H6: est. liq \$$(from_e8 "$LS05") > the \$50,000 entry — a short liquidates ABOVE"; else nok "H6: a short's est. liq must sit above its entry" "estLiqPrice=$LS05"; fi
SN=$(pvs null "$(e8 0.55)" "$(e8 0.20)" "$(e8 10000.0)"); MSN=$(pfld maxSizeBase "$SN")
if echo "$SN" | grep -q "canOpen = false" && [ "${MSN:-x}" = "$Q_SHORT20" ]; then ok "H6: the 'New pool (auto)' path (poolId = null, extraQuote \$10k) answers the same — refused, maxSizeBase $(from_e8 "$MSN") BTC"; else nok "H6: the null-pool short preview must match the funded pool's answer" "$SN"; fi
S44=$(pvs "opt ($LPID : nat)" "44000000" "$(e8 0.20)" 0)
if echo "$S44" | grep -q "canOpen = true" && [ "$(pfld maxSizeBase "$S44")" = "$Q_SHORT20" ]; then ok "H6: 0.44 BTC at 20 % (just under the clamp's 0.4444) is allowed, capacity unchanged"; else nok "H6: a size under the clamp's quantity must pass at 20 %" "$S44"; fi

echo "── H7. the release AGREES at a common price: with the AMM's bids withdrawn (cash floor), a LIMIT short at the 40,000 floor is cut to exactly the preview's maxSizeBase (clampedTo) ──"
# A MARKET short's release does not run at its raw floor: releaseDeferred's #3a
# ladder-edge cap RAISES a sell's effLimit to the AMM's deepest bid (≈ 2 % under
# the mark here) — §H8 pins that — so the one way to watch the release and the
# preview evaluate the SAME 40,000 is a LIMIT at that price. A sell limit that
# crosses a resting bid is "marketable" and collared to ±5 % of the mark
# (priceBandCheck / MARKETABLE_BAND_BPS), so the bid side must be EMPTY first:
# AMM ICPUSD → 0 engages the cash floor (ammCashFloorEngaged: cash < 5 % of
# holdings) and the requote withdraws the bids. The clamp then runs at
# effLimit = 40,000 exactly, the released 0.4444 BTC rests (nothing to hit),
# and the remainder is cancelled BEFORE the bids come back (the AMM sweep
# would otherwise lift a 40,000 ask).
amm_bids() { adm getAmmPools '()' --query | tr -d '_\n' | perl -ne 'if (/baseToken = "BTC"[^}]*?activeBidIds = vec \{([^}]*)\}/) { my @i = ($1 =~ /\d+/g); print scalar(@i), "\n" } else { print "?\n" }'; }   # live AMM bids on BTC-ICPUSD (getTakeableDepth never counts AMM quotes: they are non-takeable to the immediate paths)
pos_size() { lusr getMyPositions '()' | tr -d '_' | perl -0777 -sne 'for (split /record \{/) { if (/poolId = (\d+) : nat/ and $1 == $id and /size = (-?\d+) : int/) { print "$1\n"; last } }' -- -id="$1"; }   # signed size of THIS pool's position ('' = none)
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", 0 : nat)" >/dev/null
# The requote DIFFS the ladder against the resting quotes (a level whose price
# AND size are unchanged is KEPT, ammApplyQuotes), so the floor alone only
# blocks NEW bids — a level that happens to coincide survives (observed: 2 of
# 8). Nudge the mark by $10 first so every level moves: all resting bids are
# cancelled and none can be re-placed; then back to 50,000 (bid prices snap to
# $1 at this magnitude, so no level lands on an old one; the vol sample of a
# 2 bps move is ≈ 0).
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50010.0) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null
release
TB0=$(amm_bids)
if [ "${TB0:-x}" = "0" ]; then ok "H7: AMM bid side withdrawn (cash floor) — 0 live AMM bids on BTC-ICPUSD"; else nok "H7: expected an empty bid side" "amm_bids=$TB0"; fi
PXF=$(e8 40000.0)
P20L=$(lq previewOpenPosition "(opt ($LPID : nat), \"BTC-ICPUSD\", variant { sell }, $(e8 0.55) : nat, $(e8 0.05) : nat, opt ($PXF : nat), 0 : nat)")
M20L=$(pfld maxSizeBase "$P20L")
if echo "$P20L" | grep -q "canOpen = false" && [ "${M20L:-x}" = "$Q_SHORT20" ]; then ok "H7: preview of the LIMIT short at 40,000: refused, maxSizeBase $(from_e8 "$M20L") BTC (the same 10,000 / 22,500 as the 20 % market floor)"; else nok "H7: preview at the 40,000 limit" "$P20L"; fi
R2=$(lreduced)
O20=$(lusr openPosition "($LPID, \"BTC-ICPUSD\", variant { sell }, $(e8 0.55) : nat, $(e8 0.05) : nat, opt ($PXF : nat))")
if mdx_ok "$O20"; then ok "H7: the 0.55 BTC limit short stages (the placement gate is the borrow check, which 2.75× passes)"; else nok "H7: the short should stage (band: no bid to cross → not marketable)" "$O20"; fi
release   # a fresh mark postdates the entry → releases; the clamp runs at the 40,000 limit; no bids → the released part rests
RJS=$(lusr getMyReleaseRejections '()')
CTS=$(echo "$RJS" | tr -d '_' | grep -oE 'clampedTo = opt \(?[0-9]+' | tail -1 | grep -oE '[0-9]+$')
if [ "$(lreduced)" -eq $((R2 + 1)) ] && [ "${CTS:-x}" = "$M20L" ] && [ "${CTS:-x}" = "$Q_SHORT20" ]; then ok "H7: the release cut the 0.55-BTC short to clampedTo = $(from_e8 "$CTS") BTC == the preview's maxSizeBase, to the base unit"; else nok "H7: the release's clamp and the preview's maxSizeBase must be the same number" "reduced=$(lreduced) (was $R2) clampedTo=$CTS preview=$M20L expected=$Q_SHORT20 :: $(echo "$RJS" | tr '\n' ' ' | tail -c 300)"; fi
SOID=$(loid "$LPID"); [ -n "${SOID:-}" ] && lusr cancelPoolOrder "($LPID : nat, $SOID : nat)" >/dev/null 2>&1
if [ "$(lnord "$LPID")" = "0" ] && [ -z "$(pos_size "$LPID")" ]; then ok "H7: the clamped remainder cancelled, no position (clean pool)"; else nok "H7: cleanup" "orders=$(lnord "$LPID") size=$(pos_size "$LPID")"; fi
# Back ABOVE the floor: $100M of cash (what §E/§F ran with). §G's $10M sat AT
# the 5 % line — the floor measures cash against the AMM's WHOLE holdings and
# §E left it 1,000,000 SOL (≈ $150M) — so at $10M the bids never return and
# §H8's market shorts would find nothing to hit (observed: both re-parked).
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 100000000.0) : nat)" >/dev/null
release
TB1=$(amm_bids)
if [ -n "${TB1:-}" ] && [ "$TB1" -gt 0 ] 2>/dev/null; then ok "H7: AMM bids restored ($TB1 live AMM bids on BTC-ICPUSD)"; else nok "H7: the bid side should be back" "amm_bids=$TB1"; fi

echo "── H8. MARKET shorts placed: the 5 % short the preview accepted fills in FULL with no reduction record; the 20 % short the preview refused is never cut BELOW its maxSizeBase — the release's floor is the ladder's deepest bid, so it fills in full too ──"
# Fresh pools so each leg starts from $10k with no debt. The second half pins
# the physics §H7 works around: on a quoting venue a market sell's effLimit is
# max(floor, the AMM's deepest bid) — ≈ 49,050 here (15 bps half-spread +
# 7 × 25 bps), far above the 45,000 (1 − LTV) crossover — so the clamp's room
# (10,000 / 13,450 ≈ 0.74 BTC) clears 0.55 and the release fills what the
# preview refused (8 levels × 0.5 BTC of bids absorb it). The preview at
# the raw floor is the release's FLOOR (it never over-promises), not its
# ceiling; whether it should walk the ladder itself is a follow-up task.
LR2=$(lusr createMarginPool '("short 5pct pool", false)')
LPID2=$(echo "$LR2" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
lusr fundMarginPool "($LPID2, $(e8 10000.0) : nat)" >/dev/null
S05B=$(pvs "opt ($LPID2 : nat)" "$(e8 0.55)" "$(e8 0.05)" 0)
if echo "$S05B" | grep -q "canOpen = true"; then ok "H8: fresh pool $LPID2 — the 5 % short previews canOpen = true"; else nok "H8: 5 % preview on the fresh pool" "$S05B"; fi
R3=$(lreduced)
O05=$(lusr openPosition "($LPID2, \"BTC-ICPUSD\", variant { sell }, $(e8 0.55) : nat, $(e8 0.05) : nat, null)")
if mdx_ok "$O05"; then ok "H8: the 5 % market short stages"; else nok "H8: the 5 % short should stage" "$O05"; fi
release
PS05=$(pos_size "$LPID2")
if [ "${PS05:-x}" = "-$(e8 0.55)" ] && [ "$(lreduced)" -eq "$R3" ]; then ok "H8: the 5 % short filled in FULL (short $(from_e8 "$PS05") BTC) — no 'Order reduced at release' record, exactly as the preview said"; else nok "H8: a size the preview accepted must fill without a reduction record" "size=$PS05 reduced=$(lreduced) (was $R3) orders=$(lnord "$LPID2")"; fi
LR3=$(lusr createMarginPool '("short 20pct pool", false)')
LPID3=$(echo "$LR3" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
lusr fundMarginPool "($LPID3, $(e8 10000.0) : nat)" >/dev/null
S20B=$(pvs "opt ($LPID3 : nat)" "$(e8 0.55)" "$(e8 0.20)" 0); M20B=$(pfld maxSizeBase "$S20B")
if echo "$S20B" | grep -q "canOpen = false" && [ "${M20B:-x}" = "$Q_SHORT20" ]; then ok "H8: fresh pool $LPID3 — the 20 % short previews canOpen = false, maxSizeBase $(from_e8 "$M20B") BTC"; else nok "H8: 20 % preview on the fresh pool" "$S20B"; fi
R4=$(lreduced)
O20M=$(lusr openPosition "($LPID3, \"BTC-ICPUSD\", variant { sell }, $(e8 0.55) : nat, $(e8 0.20) : nat, null)")
if mdx_ok "$O20M"; then ok "H8: the 20 % market short still STAGES — placement gates on the borrow check (2.75× < 2.86×); the preview is advisory"; else nok "H8: the 20 % short should stage" "$O20M"; fi
release
PS20=$(pos_size "$LPID3")
RJ20=$(lusr getMyReleaseRejections '()' | tr -d '_')
CT20=$(echo "$RJ20" | grep -oE 'clampedTo = opt \(?[0-9]+' | tail -1 | grep -oE '[0-9]+$')
NEW20=$(( $(lreduced) - R4 ))
if [ "$NEW20" -eq 0 ] || { [ -n "${CT20:-}" ] && [ "$CT20" -ge "$Q_SHORT20" ]; }; then ok "H8: the release never cut the 20 % short BELOW the preview's maxSizeBase ($NEW20 new reduction records; last clampedTo=${CT20:-none}) — the preview never over-promises"; else nok "H8: the release cut below the preview's capacity — the preview over-promised" "clampedTo=$CT20 preview=$Q_SHORT20"; fi
if [ "${PS20:-x}" = "-$(e8 0.55)" ] && [ "$NEW20" -eq 0 ]; then ok "H8: …and it filled in FULL (short $(from_e8 "$PS20") BTC, no reduction record): the release's floor was the ladder's deepest bid, above the 45,000 crossover — the preview at the raw 40,000 floor under-promised by design (its floor, not its ceiling)"; else nok "H8: expected the 20 % market short to fill in full against the quoting ladder (effLimit = the deepest bid, not the raw floor)" "size=$PS20 new_reduced=$NEW20 orders=$(lnord "$LPID3") :: $(echo "$RJ20" | tr '\n' ' ' | tail -c 300)"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
