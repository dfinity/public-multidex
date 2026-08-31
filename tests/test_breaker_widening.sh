#!/bin/bash
# Breaker widening (docs/amm-vault-design.md §3): while the price-jump circuit
# breaker holds a PENDING candidate, the AMM must widen its half-spread by the
# full proposed gap IMMEDIATELY — a frozen mark with tight quotes is a free
# option during real gap moves (staleness widening alone waits out its 60s
# grace, because a pend does not advance refPriceUpdatedNs). Also locks in:
#
#   • the LP-deposit gate refuses to mint while a held leg has a pend,
#   • a direct (dev) price set CLEARS the pend and quotes snap back to normal
#     (the regression that once left tests quoting ±28% around a live-feed
#     pend that survived resetExchange).
#
# Uses the dev-only setTestPendingJump hook; needs a #dev backend.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

MKT="ICP-ICPUSD"
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
adm()  { icp canister call --identity anonymous backend "$@" 2>&1; }
u()    { icp canister call --identity bw_lp backend "$@" 2>&1; }

best() {  # best <asks|bids> → human price of the top level ("" if none)
  local side="$1" v
  if [ "$side" = "asks" ]; then
    v=$(adm getOrderBookDepth "(\"$MKT\", opt 3)" | tr -d '_' | awk '/asks = vec {/,/bids =/' | grep -oE "price = [0-9]+" | head -1 | grep -oE "[0-9]+")
  else
    v=$(adm getOrderBookDepth "(\"$MKT\", opt 3)" | tr -d '_' | awk '/bids = vec {/,/spread =|}$/' | grep -oE "price = [0-9]+" | head -1 | grep -oE "[0-9]+")
  fi
  [ -n "$v" ] && from_e8 "$v"
}
lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a <  b ? 0 : 1)}'; }
gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a >  b ? 0 : 1)}'; }

LP=$(mkid bw_lp)

# ── Setup: quoted pool at mark $10 ─────────────────────────────────
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
adm createAmmPool "(\"$MKT\")" >/dev/null 2>&1
adm setAmmConfig "(\"$MKT\", 20:nat, $(e8 50.0):nat, 3:nat, 15:nat, 5:nat)" >/dev/null
adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null
AMM=$(adm getAmmPrincipal '()' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
adm setTestBalance "(principal \"$AMM\", \"ICP\", $(e8 1000.0):nat)" >/dev/null
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 20000.0):nat)" >/dev/null
adm setTestBalance "(principal \"$LP\", \"ICP\", $(e8 500.0):nat)" >/dev/null
adm setTestBalance "(principal \"$LP\", \"ICPUSD\", $(e8 50000.0):nat)" >/dev/null
adm enableAmm "(\"$MKT\", true)" >/dev/null
adm requoteAmm "(\"$MKT\")" >/dev/null

A0=$(best asks); B0=$(best bids)
echo "── baseline: ask=$A0 bid=$B0 (mark 10.00, half-spread 20bp) ──"
if [ -n "$A0" ] && lt "$A0" "10.1" && gt "${B0:-0}" "9.9"; then
  ok "baseline quotes tight around the mark ($B0 / $A0)"
else nok "baseline should quote ±20bp" "ask=$A0 bid=$B0"; fi

# ── 1. Pend a +10% jump → both sides widen by ≥ the gap ────────────
echo ""
echo "── 1. pending +10% jump → ladder spans the proposed gap immediately ──"
adm setTestPendingJump "(\"ICP\", opt ($(e8 11.0):nat), null)" >/dev/null
adm requoteAmm "(\"$MKT\")" >/dev/null
A1=$(best asks); B1=$(best bids)
echo "   widened: ask=${A1:-none} bid=${B1:-none}"
# Half-spread ≥ gap (1000bp) + base 20bp → ask ≥ 11.0, bid ≤ 9.0 (about the
# proposed price on the up side; symmetric down — we don't know the direction).
if [ -n "${A1:-}" ] && gt "$A1" "10.9"; then ok "ask widened past the pending price (≥ ~11.0)"; else nok "ask should span the gap" "ask=${A1:-none}"; fi
if [ -n "${B1:-}" ] && lt "$B1" "9.1"; then ok "bid widened symmetrically (≤ ~9.0)"; else nok "bid should widen too" "bid=${B1:-none}"; fi

# Event log records the engage edge.
EV=$(adm getRecentEvents '(10)' | grep -c "jump pending confirmation" || true)
if [ "${EV:-0}" -ge 1 ]; then ok "widening engage logged to the event log"; else nok "expected a 'jump pending' event" "none found"; fi

# ── 2. LP deposits refuse to mint against a pending mark ───────────
echo ""
echo "── 2. LP deposit gate: minting refused while the held leg has a pend ──"
# The vault must HOLD the pending leg for the gate to apply: deposit once
# BEFORE the pend cleared it... the pend is active now, so seed attempt with
# ICP must refuse. (Vault already holds ICP via the AMM principal balances.)
DEP=$(u depositLp "(\"$MKT\", $(e8 10.0):nat, $(e8 1000.0):nat)")
if echo "$DEP" | grep -q "circuit-breaker"; then ok "deposit refused while jump pending"; else nok "deposit should be gated on the pend" "$(echo "$DEP" | head -1)"; fi

# ── 3. Direct price set clears the pend; quotes snap back ──────────
echo ""
echo "── 3. dev price set supersedes the pend → quotes back to ±20bp ──"
adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null
adm requoteAmm "(\"$MKT\")" >/dev/null
A2=$(best asks); B2=$(best bids)
echo "   restored: ask=$A2 bid=$B2"
if [ -n "${A2:-}" ] && lt "$A2" "10.1" && gt "${B2:-0}" "9.9"; then
  ok "quotes snapped back to the tight ladder ($B2 / $A2)"
else nok "pend should clear on a direct set" "ask=${A2:-none} bid=${B2:-none}"; fi
DEP2=$(u depositLp "(\"$MKT\", $(e8 10.0):nat, $(e8 1000.0):nat)")
if echo "$DEP2" | grep -q "ok"; then ok "deposit mints again after the pend clears"; else nok "deposit should succeed now" "$(echo "$DEP2" | head -1)"; fi

adm setTestPendingJump "(\"ICP\", null, null)" >/dev/null 2>&1 || true
adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
