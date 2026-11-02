#!/bin/bash
# Fee split (docs/amm-vault-design.md §5): every settled fee divides between
# the LP vault (LP_FEE_SHARE_BPS = 50%, floored) and the treasury (remainder,
# keeps the dust). test_treasury_fees.sh pins the published constants and the
# ≤-invariants non-destructively; THIS test executes one exactly-known
# user↔user fill and asserts the split to the base unit:
#
#   100 ICP @ $10.00 → gross $1,000; L0 taker 10bp = $1.00; L0 maker 5bp =
#   $0.50; total $1.50 → vault floor(half) = $0.75, treasury = $0.75.
#
# The AMM quotes with numLevels=0 (enabled + priced, no ladder) so the fill is
# purely user↔user — internal principals are fee-exempt and would muddy the
# arithmetic. ⚠️ Calls resetExchange.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

MKT="ICP-ICPUSD"
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }
adm()   { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
maker() { icp canister call --candid "$MDX_CANDID" --identity fs_maker backend "$@" 2>&1; }
taker() { icp canister call --candid "$MDX_CANDID" --identity fs_taker backend "$@" 2>&1; }
fld()   { tr -d '_' | grep -oE "$1 = [0-9]+" | head -1 | grep -oE "[0-9]+"; }
freshrequote() { adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null; adm requoteAmm "(\"$MKT\")" >/dev/null; }

mdx_identity_new fs_maker; M=$(principal_of fs_maker); mdx_identity_new fs_taker; T=$(principal_of fs_taker)

# ── Setup ───────────────────────────────────────────────────────────
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
adm createAmmPool "(\"$MKT\")" >/dev/null 2>&1
adm setAmmConfig "(\"$MKT\", 20:nat, $(e8 10.0):nat, 0:nat, 35:nat)" >/dev/null
adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null
adm enableAmm "(\"$MKT\", true)" >/dev/null
adm setTestBalance "(principal \"$M\", \"ICP\",    $(e8 200.0):nat)" >/dev/null
adm setTestBalance "(principal \"$M\", \"ICPUSD\", 0:nat)"           >/dev/null
adm setTestBalance "(principal \"$T\", \"ICPUSD\", $(e8 5000.0):nat)" >/dev/null
adm setTestBalance "(principal \"$T\", \"ICP\",    0:nat)"            >/dev/null
freshrequote

AMM=$(adm getAmmPrincipal '()' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
V0=$(adm getTestBalance "(principal \"$AMM\", \"ICPUSD\")" | tr -d "_" | grep -oE "[0-9]+" | head -1)
V0=${V0:-0}

# ── One exactly-known fill: maker sells 100 @ 10, taker buys 100 @ 10 ──
echo "── fill: maker SELL 100 ICP @ 10.00 ← taker BUY 100 @ 10.00 ──"
maker placeLimitOrder "(\"$MKT\", variant { sell }, $(e8 10.0):nat, $(e8 100.0):nat)" >/dev/null
freshrequote   # release → rests (no AMM ladder to cross)
taker placeLimitOrder "(\"$MKT\", variant { buy }, $(e8 10.0):nat, $(e8 100.0):nat)" >/dev/null
freshrequote   # release → matches the resting maker at 10.00
TAKER_ICP=$(taker getBalance '("ICP")' | tr -d "_" | grep -oE "[0-9]+" | head -1)
if [ "${TAKER_ICP:-0}" = "$(e8 100.0)" ]; then ok "fill executed (taker holds 100 ICP)"; else nok "fill missing" "taker ICP=${TAKER_ICP:-0}"; fi

# ── Assert the split, to the base unit ───────────────────────────────
TRE=$(adm getTreasury '()')
LIFE=$(echo "$TRE"  | fld "lifetimeFeesUsd")
VLIFE=$(echo "$TRE" | fld "lifetimeVaultFeesUsd")
BAL=$(echo "$TRE"   | fld "balanceUsd")
# gross 1000; taker 10bp = 1.00; maker 5bp = 0.50; total 1.50 → 0.75 / 0.75
if [ "${VLIFE:-0}" = "$(e8 0.75)" ]; then ok "vault credited exactly \$0.75 (half of \$1.50, floored)"; else nok "vault share wrong" "got $(from_e8 "${VLIFE:-0}")"; fi
if [ "${LIFE:-0}" = "$(e8 0.75)" ]; then ok "treasury credited exactly \$0.75 (remainder)"; else nok "treasury share wrong" "got $(from_e8 "${LIFE:-0}")"; fi
if [ "${BAL:-0}" = "${LIFE:-x}" ]; then ok "treasury balance == its lifetime accrual (no fuel spend yet)"; else nok "treasury balance drifted" "bal=$BAL life=$LIFE"; fi

# The vault's ICPUSD balance grew by exactly its share (vault was empty:
# the AMM principal's cash IS the fee credit here).
V1=$(adm getTestBalance "(principal \"$AMM\", \"ICPUSD\")" | tr -d "_" | grep -oE "[0-9]+" | head -1)
GOT=$(( ${V1:-0} - V0 ))
if [ "$GOT" = "$(e8 0.75)" ]; then ok "AMM vault balance grew by exactly the fee share"; else nok "vault balance delta" "$(from_e8 "$GOT")"; fi

# Σ-conservation of the quote token across the closed set {maker, taker,
# vault, treasury}: 5000 (taker's grant) + 0 = final sum.
MU=$(maker getBalance '("ICPUSD")' | tr -d "_" | grep -oE "[0-9]+" | head -1); TU=$(taker getBalance '("ICPUSD")' | tr -d "_" | grep -oE "[0-9]+" | head -1)
SUM=$(( ${MU:-0} + ${TU:-0} + ${V1:-0} + ${BAL:-0} ))
if [ "$SUM" = "$(e8 5000.0)" ]; then ok "ICPUSD conserved across maker+taker+vault+treasury"; else nok "conservation" "Σ=$(from_e8 "$SUM") expected 5000"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
