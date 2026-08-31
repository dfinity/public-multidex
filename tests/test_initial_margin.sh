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
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

ID=img; icp identity new $ID --storage plaintext 2>/dev/null || true
P=$(icp identity principal --identity $ID 2>/dev/null | tail -1)
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
usr() { icp canister call --identity $ID backend "$@" 2>&1; }
release() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "[0-9]+"; }

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat, 0:nat)" >/dev/null 2>&1 || true
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
if echo "$B" | grep -q "ok"; then ok "1.5× open accepted"; else nok "modest open should pass the gate" "$B"; fi
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
if echo "$D" | grep -q "ok"; then ok "close (risk-reducing) accepted"; else nok "close should always be allowed" "$D"; fi
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
SID=imgs; icp identity new $SID --storage plaintext 2>/dev/null || true
SPP=$(icp identity principal --identity $SID 2>/dev/null | tail -1)
susr() { icp canister call --identity $SID backend "$@" 2>&1; }
srel() { for _ in 1 2 3 4 5 6 7 8; do adm setAmmRefPrice "(\"SOL-ICPUSD\", $(e8 150.0) : nat)" >/dev/null; adm requoteAmm '("SOL-ICPUSD")' >/dev/null; done; }
adm createAmmPool '("SOL-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"SOL-ICPUSD\", $(e8 150.0) : nat)" >/dev/null
adm setAmmConfig "(\"SOL-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat, 0:nat)" >/dev/null 2>&1 || true
adm enableAmm '("SOL-ICPUSD", true)' >/dev/null 2>&1 || true
adm setTestBalance "(principal \"$AMM\", \"SOL\",    $(e8 1000000.0) : nat)"    >/dev/null
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 100000000.0) : nat)"  >/dev/null
adm setTestBalance "(principal \"$SPP\", \"ICPUSD\", $(e8 100000.0) : nat)"     >/dev/null
SR=$(susr createMarginPool '("dust-escape pool", false)')
SPID=$(echo "$SR" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
susr fundMarginPool "($SPID, $(e8 10000.0) : nat)" >/dev/null
SO=$(susr openPosition "($SPID, \"SOL-ICPUSD\", variant { sell }, $(e8 150.0) : nat, $(e8 0.05) : nat, null)")
if echo "$SO" | grep -q "ok"; then ok "leveraged SOL short staged"; else nok "short should stage" "$SO"; fi
srel
SNET=$(susr getMyPositions '()' | tr -d '_' | grep -oE 'size = -?[0-9]+' | head -1 | grep -oE '\-?[0-9]+')
if [ -n "${SNET:-}" ] && [ "${SNET:-0}" -lt 0 ]; then ok "pool is net SHORT (size $(from_e8 "$SNET") SOL)"; else nok "pool should be net short after release" "size=$SNET"; fi
# Buy far past flat: 250 > 150, so ~150 de-levers (free) and ~100 re-levers long —
# the excess MUST hit the initial-margin clamp.
SB=$(susr openPosition "($SPID, \"SOL-ICPUSD\", variant { buy }, $(e8 250.0) : nat, $(e8 0.05) : nat, null)")
if echo "$SB" | grep -q "ok"; then ok "re-levering buy staged (250 SOL, past the 150 short)"; else nok "buy should stage" "$SB"; fi
srel
RJ=$(susr getMyReleaseRejections "()")
if echo "$RJ" | grep -q "breach the initial-margin requirement" && echo "$RJ" | grep -q "clampedTo = opt"; then
  ok "de-lever escape did NOT bypass the clamp — excess was reduced at the initial-margin bound"
else
  nok "the re-levering buy was NOT clamped (escape returned #full — #49.1 regression)" "$(echo "$RJ" | tr '\n' ' ' | head -c 400)"
fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
