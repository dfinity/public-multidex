#!/bin/bash
# Cross-market liquidation NETTING — pool era.
# (Rewritten 2026-07: the liquidatees are cross margin POOLS now; the removed
# whole-wallet borrowAsset API hand-built them before. The netting engine
# itself is unchanged: the batch pairs liquidatable SELLERS of a base token
# against liquidatable BUYERS at the oracle mid — settleNettedPair's exact
# arithmetic is unit-pinned in Liquidator.test.mo; this proves the BATCH
# actually classifies and pairs real pools.)
#
# Scenario (the realistic cascade): both pools go underwater because a THIRD
# asset (SOL) crashes, while their BTC exposures point OPPOSITE ways:
#   Pool A: long 0.5 BTC + long 150 SOL, owes ICPUSD → liquidation SELLS BTC
#   Pool B: short 0.5 BTC + long 250 SOL, owes BTC   → liquidation BUYS  BTC
# After the crash both are liquidatable simultaneously → the batch nets their
# BTC legs internally: getNettedVolumeUsd grows and both healths improve.
# ⚠️ Calls resetExchange.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
PA=$(mkid net_long)
PB=$(mkid net_short)
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
asA() { icp canister call --identity net_long  backend "$@" 2>&1; }
asB() { icp canister call --identity net_short backend "$@" 2>&1; }
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "[0-9]+"; }
release() { adm setAmmRefPrice "(\"$1\", $(e8 "$2") : nat)" >/dev/null; adm requoteAmm "(\"$1\")" >/dev/null; }
netted() { adm getNettedVolumeUsd '()' | tr -d '_' | grep -oE "[0-9]+" | head -1; }

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
for m in BTC-ICPUSD SOL-ICPUSD; do adm createAmmPool "(\"$m\")" >/dev/null 2>&1; done
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAmmRefPrice "(\"SOL-ICPUSD\", $(e8 180.0) : nat)"   >/dev/null
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat, 0:nat)"   >/dev/null 2>&1 || true
adm setAmmConfig "(\"SOL-ICPUSD\", 30:nat, $(e8 150.0) : nat, 8:nat, 25:nat, 0:nat)" >/dev/null 2>&1 || true
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1 || true
adm enableAmm '("SOL-ICPUSD", true)' >/dev/null 2>&1 || true
AMM=$(adm getAmmPrincipal "()" | grep -oE 'principal "[^"]+"' | head -1 | sed -E 's/principal "(.+)"/\1/')
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 10000000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$AMM\", \"BTC\",    $(e8 100.0) : nat)"      >/dev/null
adm setTestBalance "(principal \"$AMM\", \"SOL\",    $(e8 10000.0) : nat)"    >/dev/null
adm setTestBalance "(principal \"$PA\", \"ICPUSD\", $(e8 100000.0) : nat)"    >/dev/null
adm setTestBalance "(principal \"$PB\", \"ICPUSD\", $(e8 100000.0) : nat)"    >/dev/null

echo "── pool A (cross): long 0.5 BTC + long 150 SOL on \$30k ──"
RA=$(asA createMarginPool '("net A", false)')
PIDA=$(echo "$RA" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
asA fundMarginPool "($PIDA, $(e8 30000.0) : nat)" >/dev/null
asA openPosition "($PIDA, \"BTC-ICPUSD\", variant { buy }, $(e8 0.5) : nat, $(e8 0.05) : nat, null)" >/dev/null
release "BTC-ICPUSD" 50000.0
asA openPosition "($PIDA, \"SOL-ICPUSD\", variant { buy }, $(e8 150.0) : nat, $(e8 0.05) : nat, null)" >/dev/null
release "SOL-ICPUSD" 180.0
DA0=$(fld debtUsd "$(asA getMyMarginPools '()')")
[ -n "${DA0:-}" ] && [ "$DA0" != "0" ] && ok "A open (owes \$$(from_e8 "$DA0") ICPUSD)" || nok "A setup" "debt=$DA0"

echo "── pool B (cross): SHORT 0.5 BTC + long 250 SOL on \$30k ──"
RB=$(asB createMarginPool '("net B", false)')
PIDB=$(echo "$RB" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
asB fundMarginPool "($PIDB, $(e8 30000.0) : nat)" >/dev/null
asB openPosition "($PIDB, \"BTC-ICPUSD\", variant { sell }, $(e8 0.5) : nat, $(e8 0.05) : nat, null)" >/dev/null
release "BTC-ICPUSD" 50000.0
asB openPosition "($PIDB, \"SOL-ICPUSD\", variant { buy }, $(e8 250.0) : nat, $(e8 0.05) : nat, null)" >/dev/null
release "SOL-ICPUSD" 180.0
DB0=$(fld debtUsd "$(asB getMyMarginPools '()')")
[ -n "${DB0:-}" ] && [ "$DB0" != "0" ] && ok "B open (owes \$$(from_e8 "$DB0") incl. the borrowed BTC)" || nok "B setup" "debt=$DB0"

echo "── crash SOL 180 → 20: BOTH pools sink; BTC flows point opposite ──"
# (Was 180 → 30, which left pool A at health ≈ 1.19 — above the 1.15
# maintenance bar with the current LTV constants — so A never liquidated and
# the netting leg had nothing to net. 20 puts BOTH pools under.)
adm setAmmRefPrice "(\"SOL-ICPUSD\", $(e8 20.0) : nat)" >/dev/null
HA=$(asA getMyMarginPools "()"); HB=$(asB getMyMarginPools "()")
LA=$(echo "$HA" | grep -c "isLiquidatable = true"); LB=$(echo "$HB" | grep -c "isLiquidatable = true")
if [ "$LA" -ge 1 ] && [ "$LB" -ge 1 ]; then ok "both pools liquidatable simultaneously"; else nok "both must be liquidatable (A=$LA B=$LB)" "tune the crash/leverage"; fi

echo "── batch: opposing BTC legs net internally at the oracle mid ──"
NV0=$(netted)
adm adminRunLiquidationBatch "()" >/dev/null 2>&1
NV1=$(netted)
if awk -v a="${NV1:-0}" -v b="${NV0:-0}" 'BEGIN{exit (a>b?0:1)}'; then
  ok "netting fired: nettedVolumeUsd +\$$(from_e8 $(( ${NV1:-0} - ${NV0:-0} )))"
else nok "expected internal netting (seller A × buyer B on BTC)" "before=$NV0 after=$NV1"; fi

DA1=$(fld debtUsd "$(asA getMyMarginPools '()')")
DB1=$(fld debtUsd "$(asB getMyMarginPools '()')")
# #45.1: a `<` comparison is fail-OPEN under the `:-0` default (an empty read
# passes as 0 < debt) — require the reads to be non-empty, like the `>` sibling
# above is fail-closed by construction.
if [ -n "${DA1:-}" ] && [ -n "${DB1:-}" ] && awk -v a="${DA1:-0}" -v b="$DA0" 'BEGIN{exit (a<b?0:1)}' && awk -v a="${DB1:-0}" -v b="$DB0" 'BEGIN{exit (a<b?0:1)}'; then
  ok "both debts reduced (A \$$(from_e8 "$DA0")→\$$(from_e8 "${DA1:-0}") · B \$$(from_e8 "$DB0")→\$$(from_e8 "${DB1:-0}"))"
else nok "both sides should deleverage through the net" "A:${DA0}→$DA1 B:${DB0}→$DB1"; fi
# (${var}→ braces: macOS bash 3.2 under a UTF-8 locale swallows the multibyte
# glyph into the variable name and `set -u` kills the script.)

echo "── netted slices are BOOKED: realized PnL attributed, not a silent size shrink ──"
# The netted flatten now flows through bookPoolSide at the oracle mid, so each
# pool's position accounting must show it: non-zero realizedPnl on the (partly)
# closed BTC position, or a closed episode carrying it. Before the fix, netting
# only moved balances/debts — the reconcile pass shrank `size` with NO PnL
# attribution anywhere. (SOL crashed 180→30 while both entered near 180, and
# BTC netted at the entry price, so *some* leg's realized PnL must be ≠ 0.)
A_ACCT="$(asA getMyPositions '()' | tr -d '_') $(asA getMyPositionEpisodes '()' | tr -d '_')"
B_ACCT="$(asB getMyPositions '()' | tr -d '_') $(asB getMyPositionEpisodes '()' | tr -d '_')"
A_PNL=$(echo "$A_ACCT" | grep -oE 'realizedPnl = [+-]?[0-9]+' | grep -oE '[+-]?[0-9]+' | awk '$1 != 0 {print; exit}')
B_PNL=$(echo "$B_ACCT" | grep -oE 'realizedPnl = [+-]?[0-9]+' | grep -oE '[+-]?[0-9]+' | awk '$1 != 0 {print; exit}')
if [ -n "${A_PNL:-}" ]; then ok "A's netted slice booked realized PnL ($A_PNL)"; else nok "A: no realized PnL booked for the netted slice" "$(echo "$A_ACCT" | head -c 300)"; fi
if [ -n "${B_PNL:-}" ]; then ok "B's netted slice booked realized PnL ($B_PNL)"; else nok "B: no realized PnL booked for the netted slice" "$(echo "$B_ACCT" | head -c 300)"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
