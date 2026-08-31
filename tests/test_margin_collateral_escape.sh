#!/bin/bash
# Security regression — the COLLATERAL-ESCAPE class (2026-06-09 review
# C2/H1/H2) plus the M1 circuit-breaker LP-mint gate.
#
# RECREATED 2026-07-03: the original lock-in test (written with the 06-10 fix)
# didn't survive the whole-wallet→pool-margin migration — its scenarios built
# debt with the removed human `borrowAsset` API. Model 2 made the ORIGINAL
# human-principal escapes structurally impossible (humans can't borrow, so
# their wallets are never collateral); the surface that REMAINS is the pool,
# and this test pins it:
#   §1  An indebted pool's owner cannot withdraw pool collateral past the
#       initial-margin line, even when free (unreserved) cash covers it —
#       the pool-era C2. A margin-safe withdraw still works.
#   §2  Liquidation reaches a pool that keeps a RESTING order open: the order
#       is force-cancelled and the seize proceeds (tryLiquidate →
#       cancelAllUserOrders). The STAGED-order variant (H2 health inflation)
#       is pinned separately in test_liquidation_staged_shield.sh.
#   §3  M1: LP mints are REFUSED while a held leg's price sits in an ACTIVE
#       circuit-breaker pend (frozen refPrice would misprice the mint), do
#       NOT trip on pends of assets the vault doesn't hold, and resume once
#       the pend clears. Withdrawals stay ungated by design — withdrawLp
#       redeems a pro-rata basket in kind (price-neutral).
#   §4  Debt-free humans are unaffected: depositLp / withdrawLp round-trip.
# Timers paused; liquidation driven via adminRunLiquidationBatch.
# ⚠️ Calls resetExchange.

set -u
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
ID=cesc; icp identity new $ID --storage plaintext 2>/dev/null || true
P=$(icp identity principal --identity $ID 2>/dev/null | tail -1)
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
usr() { icp canister call --identity $ID backend "$@" 2>&1; }
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "[0-9]+"; }
release() { adm setAmmRefPrice "(\"$1\", $(e8 "$2") : nat)" >/dev/null; adm requoteAmm "(\"$1\")" >/dev/null; }

# Deterministic run needs the sim dead (it moves prices + fires releases).
# Stop it via the PID-file stopper — NEVER a pattern kill: `pkill -f` cannot
# tell a local simulator from one driving multidex.ai and took the live fleet
# down three times (run_all.sh's stopper comment + scripts/lib/bots.sh).
# run_all.sh already stops the fleet for suite runs; this covers standalone.
STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
if [ -f "$STOPPER" ]; then
  bash "$STOPPER" >/dev/null 2>&1 || true
  sleep 2
else
  echo "⚠ stop_bots_local.sh not found at $STOPPER — the local fleet was NOT stopped."
  echo "  Red results below may be simulator noise rather than regressions."
fi

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat, 0:nat)" >/dev/null 2>&1 || true
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1 || true
# Seed the vault PROPERLY (via seedAmmPool, so vault balances are LP-backed):
# raw setTestBalance on the AMM principal would leave un-backed balances that
# distort §4's LP mint/redeem arithmetic. The seeded vault is also the margin
# LENDER for §1/§2.
SEED=$(icp identity new cesc_seed --storage plaintext >/dev/null 2>&1; icp identity principal --identity cesc_seed 2>/dev/null | tail -1)
adm setTestBalance "(principal \"$SEED\", \"BTC\",    $(e8 100.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 5000000.0) : nat)" >/dev/null
icp canister call --identity cesc_seed backend seedAmmPool "(\"BTC-ICPUSD\", $(e8 100.0) : nat, $(e8 5000000.0) : nat)" >/dev/null 2>&1
adm setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null

echo "── §1 pool-era C2: margin gate on pool withdrawals ──"
# SHORT pool: fund \$10k, short 0.2 BTC → proceeds land as pool CASH (~\$20k
# balance) against a 0.2 BTC (~\$10k) debt. Cash is free (unreserved), so a
# big withdraw passes the free-quote check and must be stopped by the MARGIN
# gate — the pool-era version of "walk collateral out while indebted".
R=$(usr createMarginPool '("esc", false)')
PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
usr fundMarginPool "($PID, $(e8 10000.0) : nat)" >/dev/null
usr openPosition "($PID, \"BTC-ICPUSD\", variant { sell }, $(e8 0.2) : nat, $(e8 0.05) : nat, null)" >/dev/null
release "BTC-ICPUSD" 50000.0
D0=$(fld debtUsd "$(usr getMyMarginPools '()')")
F0=$(fld freeQuote "$(usr getMyMarginPools '()')")
if [ -n "${D0:-}" ] && [ "$D0" != "0" ]; then ok "short open: pool owes \$$(awk -v d="$D0" 'BEGIN{printf "%.0f", d/100000000}') with \$$(awk -v f="$F0" 'BEGIN{printf "%.0f", f/100000000}') free cash"; else nok "short setup" "debt=$D0"; fi
# Free cash covers \$15k, but withdrawing it would leave ~\$5k collateral vs
# ~\$10k debt → far below INITIAL (1.25). The margin gate must refuse.
W1=$(usr withdrawMarginPool "($PID, $(e8 15000.0) : nat)")
if echo "$W1" | grep -q "initial-margin requirement"; then
  ok "escape blocked: \$15k withdraw refused by the MARGIN gate (not the free-cash check)"
else nok "indebted pool let collateral walk out" "$W1"; fi
# A margin-safe withdraw (\$2k → ratio ≈ 1.8) still works — the gate isn't a wall.
W2=$(usr withdrawMarginPool "($PID, $(e8 2000.0) : nat)")
if echo "$W2" | grep -q "ok"; then ok "margin-safe \$2k withdraw allowed (control)"; else nok "healthy withdraw refused" "$W2"; fi

echo "── §2 liquidation reaches a pool with a RESTING order open ──"
# Park a resting limit BUY (far below market → rests after release), then
# crash BTC upward (a SHORT's nightmare) until the pool is liquidatable.
usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 0.01) : nat, $(e8 0.05) : nat, opt ($(e8 40000.0) : nat))" >/dev/null
release "BTC-ICPUSD" 50000.0
NORD0=$(usr getPoolOrders "($PID)" | grep -c "id =")
if [ "${NORD0:-0}" -ge 1 ]; then ok "pool has a resting order pre-liquidation"; else nok "resting order setup" "orders=$NORD0"; fi
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 85000.0) : nat)" >/dev/null   # short deep underwater
LIQ0=$(usr getMyMarginPools "()" | grep -c "isLiquidatable = true")
if [ "$LIQ0" -ge 1 ]; then ok "pool liquidatable after the squeeze"; else nok "expected liquidatable" "$(usr getMyMarginPools '()' | head -c 200)"; fi
adm adminRunLiquidationBatch "()" >/dev/null 2>&1
D2=$(fld debtUsd "$(usr getMyMarginPools '()')")
NORD1=$(usr getPoolOrders "($PID)" | grep -c "id =")
# #45.1: a `<` comparison is fail-OPEN under the `:-0` default (an empty read
# passes as 0 < debt) — require the read to be non-empty.
if [ -n "${D2:-}" ] && awk -v a="${D2:-0}" -v b="$D0" 'BEGIN{exit (a<b?0:1)}'; then
  ok "seize proceeded (debt \$$(awk -v d="$D0" 'BEGIN{printf "%.0f", d/100000000}') → \$$(awk -v d="${D2:-0}" 'BEGIN{printf "%.0f", d/100000000}'))"
else nok "liquidation blocked" "debt $D0 → $D2"; fi
if [ "${NORD1:-0}" -eq 0 ]; then
  ok "resting order force-cancelled ahead of the seize (cancelAllUserOrders)"
else nok "resting order survived a liquidation" "orders=$NORD1"; fi

echo "── §3 M1: LP mint gated during an ACTIVE circuit-breaker pend ──"
adm setTestPendingJump '("BTC", opt (5500000000000 : nat), null)' >/dev/null   # BTC pend: 50k → 55k held for confirmation
DL1=$(usr depositLp "(\"BTC-ICPUSD\", 0 : nat, $(e8 100.0) : nat)")
if echo "$DL1" | grep -q "circuit-breaker confirmation"; then
  ok "mint REFUSED while a HELD leg's price is pending confirmation"
else nok "mint accepted against a frozen refPrice (M1)" "$DL1"; fi
# Precision: a pend on an asset the vault does NOT hold must not block.
adm setTestPendingJump '("BTC", null, null)' >/dev/null
adm setTestPendingJump '("ETH", opt (300000000000 : nat), null)' >/dev/null    # vault holds no ETH
DL2=$(usr depositLp "(\"BTC-ICPUSD\", 0 : nat, $(e8 100.0) : nat)")
if echo "$DL2" | grep -q "ok"; then
  ok "pend on an UNHELD asset doesn't block (held-legs-only gate)"
else nok "over-broad gate: unheld asset pend blocked the mint" "$DL2"; fi
adm setTestPendingJump '("ETH", null, null)' >/dev/null

echo "── §4 debt-free humans unaffected: depositLp / withdrawLp round-trip ──"
LP=$(usr getMyVaultLp "()" | tr -d '_' | grep -oE "[0-9]+" | head -1)
if [ -n "${LP:-}" ] && [ "$LP" != "0" ]; then ok "LP minted for the debt-free depositor"; else nok "deposit should have minted LP" "lp=$LP"; fi
WL=$(usr withdrawLp "($(awk -v l="$LP" 'BEGIN{printf "%.0f", l/2}') : nat)")
if echo "$WL" | grep -q "ok"; then ok "in-kind withdrawLp works (no false-positive debt/price gate)"; else nok "withdrawLp refused a clean user" "$WL"; fi

# Fixture hygiene: the vault LP here is split between two ad-hoc identities
# (cesc_seed's seed stake, cesc's §4 remainder) that _lib.sh's I1
# (Σ alice..eve LP == lpSupply) can never account for. Reset at exit so the
# next test inherits an EMPTY venue (I1 skips on lpSupply == 0) rather than
# ~$10M of unattributable LP — test_margin_heatmap runs directly after this
# file and was the standing victim.
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
