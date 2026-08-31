#!/bin/bash
# GHSA-97xp / #52.1 / #51 — the order caps bind on the margin & swap-limit paths.
#
# ⚠️  DO NOT RUN AGAINST THE LIVE SIM: this calls resetExchange and wipes the
#     seeded sim state. Run it in a clean replica, or after stopping the sim.
#
# Pre-fix, openPosition/closePosition staged orders as the POOL principal with
# 0/3 order-flow guards (no level cap, no min notional, no user cap — the pool
# is name-exempt from evictOverCap), and swap(#limitOrder) had no user cap.
# Verifies, with the dev-hook caps lowered (setTestLevelCap / setTestOrderCap):
#   1. a LIMIT openPosition at a FULL price level is REJECTED ("Price level
#      full") — the headline red/green: pre-fix the N+1th placement succeeded;
#   2. previewOpenPosition mirrors the refusal; the next tick stays free;
#   3. close semantics: a LIMIT close at the full level is rejected, but a
#      MARKET close always works (deleveraging is never blocked — market
#      orders never rest at a level, so the cap cannot apply);
#   4. min notional binds on openPosition (dust positions are refused);
#   5. the open-order cap is BENEFICIAL-OWNER keyed: pool-owned resting orders
#      count against their owner (whyAmIRefused / getAccessPolicy report it),
#      and swap-limit + margin limit placements REJECT at the cap while
#      placeLimitOrder keeps its evict-oldest contract;
#   6. (§8, 2026-08-20 scope decision) the dead-man switch sweeps the ARMED
#      principal's spot-wallet orders only — pool-owned resting orders
#      SURVIVE the fire (extend-all rejected; see tickDeadman).
set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

# Integer-money: methods take/return Nat base units (10^8).
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }

ID=capm; icp identity new $ID --storage plaintext 2>/dev/null || true
P=$(icp identity principal --identity $ID 2>/dev/null | tail -1)

adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
usr() { icp canister call --identity $ID backend "$@" 2>&1; }
# release a market's staged (sealed) orders: advance the ref price then requote.
release() { adm setAmmRefPrice "(\"$1\", $(e8 "$2") : nat)" >/dev/null; adm requoteAmm "(\"$1\")" >/dev/null; }
# extract the first integer of a named base-unit field (underscore-stripped)
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
adm setTestBalance "(principal \"$P\",   \"ICPUSD\", $(e8 500000.0) : nat)"   >/dev/null

# Margin-path level cap lowered to 4 so the level fills in 4 placements.
LC=$(adm setTestLevelCap '(opt (4 : nat))')
if echo "$LC" | grep -qi "reject\|error"; then nok "setTestLevelCap (dev hook present?)" "$LC"; else ok "level cap lowered to 4 (margin paths, dev hook)"; fi

echo "── 1. Pool + a small market SHORT (for the close-path checks) ──"
R=$(usr createMarginPool '("cap probe", false)')
PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
if [ -n "${PID:-}" ]; then ok "pool created (id=$PID)"; else nok "createMarginPool" "$R"; fi
usr fundMarginPool "(${PID:-0}, $(e8 200000.0) : nat)" >/dev/null
S=$(usr openPosition "(${PID:-0}, \"BTC-ICPUSD\", variant { sell }, $(e8 0.05) : nat, $(e8 0.05) : nat, null)")
if echo "$S" | grep -q "ok"; then ok "market short staged"; else nok "short open" "$S"; fi
release "BTC-ICPUSD" 50000.0
POS=$(usr getMyPositions "()")
if echo "$POS" | tr -d '_' | grep -q "size = -"; then ok "short position live"; else nok "short position" "$POS"; fi

echo "── 2. Fill the (buy, \$40000) level to the cap via LIMIT opens ──"
placed=0
for i in 1 2 3 4; do
  O=$(usr openPosition "(${PID:-0}, \"BTC-ICPUSD\", variant { buy }, $(e8 0.05) : nat, $(e8 0.05) : nat, opt ($(e8 40000.0) : nat))")
  if echo "$O" | grep -q "ok"; then placed=$((placed+1)); else nok "limit open #$i" "$O"; fi
  release "BTC-ICPUSD" 50000.0   # 40k buy doesn't cross — rests on the book
done
if [ "$placed" = "4" ]; then ok "4 limit entries staged"; fi
RESTING=$(usr getPoolOrders "(${PID:-0})" | tr -d '_' | grep -cE "price = 4000000000000 : nat")
if [ "${RESTING:-0}" = "4" ]; then ok "4 orders rest at the level"; else nok "expected 4 resting at \$40000" "got ${RESTING:-0}"; fi

echo "── 3. HEADLINE: the 5th limit open at the full level is REJECTED ──"
O5=$(usr openPosition "(${PID:-0}, \"BTC-ICPUSD\", variant { buy }, $(e8 0.05) : nat, $(e8 0.05) : nat, opt ($(e8 40000.0) : nat))")
if echo "$O5" | grep -q "Price level full"; then
  ok "openPosition at a full level → 'Price level full' (GHSA-97xp closed)"
else nok "level cap must bind on the margin path (pre-fix: this succeeded)" "$O5"; fi

echo "── 4. previewOpenPosition mirrors the refusal; the next tick is free ──"
PV=$(usr previewOpenPosition "(opt (${PID:-0} : nat), \"BTC-ICPUSD\", variant { buy }, $(e8 0.05) : nat, $(e8 0.05) : nat, opt ($(e8 40000.0) : nat), 0 : nat)")
if echo "$PV" | grep -q "Price level full" && echo "$PV" | grep -q "canOpen = false"; then
  ok "preview mirrors 'Price level full'"
else nok "preview should mirror the level-cap refusal" "$PV"; fi
OT=$(usr openPosition "(${PID:-0}, \"BTC-ICPUSD\", variant { buy }, $(e8 0.05) : nat, $(e8 0.05) : nat, opt ($(e8 39999.0) : nat))")
if echo "$OT" | grep -q "ok"; then ok "one tick away stays free (\$39999 accepted)"; else nok "adjacent tick should be free" "$OT"; fi

echo "── 5. Close semantics: limit close at the full level rejected, market close always works ──"
CL=$(usr closePosition "(${PID:-0}, \"BTC-ICPUSD\", $(e8 0.05) : nat, opt ($(e8 40000.0) : nat))")
if echo "$CL" | grep -q "Price level full"; then
  ok "LIMIT close (take-profit buy) at the full level → rejected"
else nok "limit close should hit the level cap" "$CL"; fi
CM=$(usr closePosition "(${PID:-0}, \"BTC-ICPUSD\", $(e8 0.05) : nat, null)")
if echo "$CM" | grep -q "ok"; then
  ok "MARKET close accepted — deleveraging never blocked by the caps"
else nok "market close must always be available" "$CM"; fi
release "BTC-ICPUSD" 50000.0
POS2=$(usr getMyPositions "()")
if echo "$POS2" | tr -d '_' | grep -q "size = -"; then nok "short should be flat after market close" "$POS2"; else ok "short flattened"; fi

echo "── 6. Min notional binds on openPosition (dust position refused) ──"
DUST=$(usr openPosition "(${PID:-0}, \"BTC-ICPUSD\", variant { buy }, $(e8 0.0001) : nat, $(e8 0.05) : nat, null)")
if echo "$DUST" | grep -qi "minimum"; then ok "\$5 open refused (min notional)"; else nok "dust open should be refused" "$DUST"; fi

echo "── 7. Open-order cap: beneficial-owner keyed, REJECT on swap/margin, evict kept on placeLimit ──"
adm setTestOrderCap '(opt (3 : nat))' >/dev/null
WR=$(usr whyAmIRefused "()")
CNT=$(fld openOrderCount "$WR")
if [ -n "${CNT:-}" ] && [ "${CNT:-0}" -ge 4 ]; then
  ok "whyAmIRefused.openOrderCount counts pool orders (got $CNT; raw-principal count was 0)"
else nok "openOrderCount should resolve to the beneficial owner" "$WR"; fi
AP=$(usr getAccessPolicy "()")
MC=$(fld myOpenOrderCount "$AP")
if [ -n "${MC:-}" ] && [ "${MC:-0}" -ge 4 ]; then
  ok "getAccessPolicy.myOpenOrderCount counts pool orders (got $MC)"
else nok "myOpenOrderCount should resolve to the beneficial owner" "$AP"; fi
OC=$(usr openPosition "(${PID:-0}, \"BTC-ICPUSD\", variant { buy }, $(e8 0.05) : nat, $(e8 0.05) : nat, opt ($(e8 41000.0) : nat))")
if echo "$OC" | grep -q "Open-order cap"; then
  ok "margin limit open at the owner cap → rejected (not evicted)"
else nok "margin path should reject at the owner cap" "$OC"; fi
SW=$(usr swap "(record { fromToken = \"ICPUSD\"; toToken = \"BTC\"; amount = $(e8 5000.0) : nat; mode = variant { limitOrder = record { limitPrice = $(e8 41000.0) : nat } }; noPartialFill = false })")
if echo "$SW" | grep -q "Open-order cap"; then
  ok "swap #limitOrder at the owner cap → rejected"
else nok "swap-limit should reject at the owner cap" "$SW"; fi
PL=$(usr placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 41000.0) : nat, $(e8 0.05) : nat)")
if echo "$PL" | grep -q "ok"; then
  ok "placeLimitOrder unchanged (evict-oldest contract; pool orders don't block the wallet path)"
else nok "placeLimit behavior must be unchanged" "$PL"; fi

echo "── 8. Dead-man scope pin (2026-08-20): pool-owned orders SURVIVE the switch ──"
# Ratified decision (GHSA-97xp follow-up, task 1787196310): tickDeadman fires
# cancelAllOrdersFor for the ARMED principal only — pool-owned resting orders
# (limit entries/exits, owned by the POOL principal) are position machinery
# and deliberately survive; sweeping a dead owner's pool EXITs would strip the
# risk-reducer off an open leveraged position (extend-all REJECTED — do not
# reopen; the designed upgrade path is at the tickDeadman comment). Timers
# stay PAUSED here: the deadman dispatch sits ABOVE the pause gate (#47.1),
# so the fire is deterministic while every other sweep is quiesced.
adm setTestOrderCap '(null)' >/dev/null   # real cap back before the wallet-order fixture
release "BTC-ICPUSD" 50000.0    # rest §7's wallet order (a 41000 buy does not cross 50000)
# Non-vacuity: BOTH order kinds must demonstrably exist before the fire. The
# wallet order is identified by OWNER — release re-mints book order ids, so
# the placement id does not survive; the RAW principal owning an open order
# is exactly what the sweep keys on.
MY=$(usr getMyOrders '()' --query | tr -d '_\n' | tr -s ' ')
OWNID=$(echo "$MY" | grep -oE "id = [0-9]+ : nat; status = variant \{ open \}; owner = principal \"$P\"" | grep -oE '[0-9]+' | head -1)
if [ -n "${OWNID:-}" ]; then
  ok "own wallet order resting before the fire (id=$OWNID, owner=self)"
else nok "own wallet order missing before the fire — fixture vacuous" "$MY"; fi
PB=$(usr getPoolOrders "(${PID:-0})" --query | tr -d '_' | grep -cE "^ *id = [0-9]+")
if [ "${PB:-0}" -ge 1 ]; then
  ok "pool holds $PB resting order(s) before the fire"
else nok "no pool-owned resting orders before the fire — fixture vacuous" "$(usr getPoolOrders "(${PID:-0})" --query)"; fi
ARM=$(usr cancelAllAfter '(opt (5 : nat))')
if echo "$ARM" | grep -q "ok"; then ok "deadman armed (5s window)"; else nok "arm failed" "$ARM"; fi
sleep 9   # past the 5s window, with slack for the beat + isolated sweep (§4 recipe, test_heartbeat_isolation)
FIRED=$(usr getMyCancelAllAfter '()' --query | tr -d '\n' | tr -s ' ')
if echo "$FIRED" | grep -q "(null)"; then ok "switch fired (disarmed by the sweep)"; else nok "switch did not fire" "$FIRED"; fi
MY2=$(usr getMyOrders '()' --query | tr -d '_\n' | tr -s ' ')
if echo "$MY2" | grep -q "owner = principal \"$P\""; then
  nok "own wallet order must be cancelled by the fire" "$MY2"
else ok "own wallet order swept — the switch really fired on this principal"; fi
PA=$(usr getPoolOrders "(${PID:-0})" --query | tr -d '_' | grep -cE "^ *id = [0-9]+")
if [ "${PA:-0}" = "${PB:-0}" ] && [ "${PA:-0}" -ge 1 ]; then
  ok "pool orders SURVIVE the fire ($PA of $PB still resting — scope pinned)"
else nok "pool orders must survive the dead-man fire (before=$PB after=$PA)" "$(usr getPoolOrders "(${PID:-0})" --query)"; fi

# cleanup: restore the real caps + timers
adm setTestOrderCap '(null)' >/dev/null
adm setTestLevelCap '(null)' >/dev/null
adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
