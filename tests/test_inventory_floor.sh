#!/bin/bash
# Inventory-floor skew (#92): sustained one-sided BUYING cannot drain the AMM's
# base reserve below the floor (= 15% of the configured base target). Two legs:
#
#   A. SKEW RISES — as base falls toward the floor the ask-only barrier skew
#      lifts the best ask hyperbolically (a price-sensitive buyer is deterred
#      long before the reserve is gone).
#   NOTE ON THE DRIVER (2026-07-24): both legs used to buy with a limit far
#   above the mark ($1000 against a $10 mark) to be price-insensitive. The
#   price collar (ac59ae8) now rejects any order that executes immediately
#   more than 5% from the mark, so that buyer cannot exist and BOTH legs
#   silently stopped buying at all — base never moved and the whole test was
#   vacuous. Buys are now inside the collar, and each leg configures the skew
#   so that what it is testing is the thing that binds:
#     · leg A uses a GENTLE barrier (intensity 20bps) so the ask visibly
#       climbs while staying reachable within the collar;
#     · leg B disables the barrier (intensity 0) so the ask stays reachable
#       and the DEPTH CLAMP — the mechanism this leg is about — is what
#       stops the drain. inventoryFloor is independent of skewIntensityBps,
#       so the floor under test is unchanged.
#
#   B. HARD FLOOR — a whale buys at the top of the collar, repeatedly
#      relentlessly; the cumulative ask-depth clamp means the book drains DOWN
#      to the floor and then stops dead. The AMM withdraws its asks at the
#      floor and base never dips below it, no matter how many requotes fire.
#
# RUN WITH THE TRADING BOT PAUSED:
#     bash scripts/stop_bots_local.sh
#     bash tests/test_inventory_floor.sh
#
# Floor math: target=100 ICP, FLOOR_FRACTION=0.15 → floor=15 ICP.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

MKT="ICP-ICPUSD"
FLOOR=15.0   # 0.15 × target(100)

# Integer-money helpers: methods take/return Nat base units (10^8).
# e8: human → base units (call args); from_e8: base units → human (reading money).
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
adm()  { icp canister call --identity anonymous backend "$@" 2>&1; }
# Resolve the AMM principal LIVE — a hardcoded id goes stale on every redeploy.
AMM=$(adm getAmmPrincipal '()' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
u()    { icp canister call --identity flr_whale backend "$@" 2>&1; }
# Balances are Nat base units now — strip underscores, take the nat, → human.
bal()  { local v; v=$(adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+" | head -1); [ -n "$v" ] && from_e8 "$v"; }
freshrequote() { adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null; adm requoteAmm "(\"$MKT\")" >/dev/null; }
amm_icp() { bal "$AMM" ICP; }
# Lowest (best) ask price (human) on the public book, or empty if there are no
# asks. Book prices are Nat base units → take the min e8 price, convert to human.
best_ask() { local v; v=$(adm getOrderBook "(\"$MKT\")" | tr -d '_' | tr '}' '\n' | sed -n '/asks =/,/bids =/p' | grep -oE "price = [0-9]+" | grep -oE "[0-9]+" | sort -g | head -1); [ -n "$v" ] && from_e8 "$v"; }
ask_levels() { adm getOrderBook "(\"$MKT\")" | tr '}' '\n' | sed -n '/asks =/,/bids =/p' | grep -c "price ="; }
ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a >= b ? 0 : 1)}'; }    # a >= b
lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a <  b ? 0 : 1)}'; }    # a <  b

W=$(mkid flr_whale)

# ── Setup: a fresh pool with skew/floor enabled (target=100, intensity=200) ──
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1     # deterministic: no heartbeat interference
adm createAmmPool "(\"$MKT\")" >/dev/null 2>&1
# spread 20bps · depth 10/level · 8 levels · spacing 15bps · window 5s
# (setAmmConfig: only quoteDepthBase — the 2nd arg — is a base-unit Nat → e8.)
adm setAmmConfig "(\"$MKT\", 20:nat, $(e8 10.0):nat, 8:nat, 15:nat, 5:nat)" >/dev/null
adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null
adm setTestBalance "(principal \"$AMM\", \"ICP\", $(e8 100.0):nat)"       >/dev/null
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 300000.0):nat)" >/dev/null
icp canister call --identity flr_whale backend whoami >/dev/null 2>&1
adm setTestBalance "(principal \"$W\", \"ICPUSD\", $(e8 50000000.0):nat)" >/dev/null
adm setTestBalance "(principal \"$W\", \"ICP\", $(e8 0.0):nat)"           >/dev/null
# target=100 (the seeded base), intensity=200bps → floor = 15 ICP
# (setAmmSkewConfig: inventoryTargetBase — the 2nd arg — is a base-unit Nat → e8;
#  skewIntensityBps stays as bps.)
adm setAmmSkewConfig "(\"$MKT\", $(e8 100.0):nat, 200:nat)" >/dev/null
adm enableAmm "(\"$MKT\", true)" >/dev/null
freshrequote

USD_BASE=$(awk -v a="$(bal "$W" ICPUSD)" -v b="$(bal "$AMM" ICPUSD)" 'BEGIN{printf "%.2f", a+b}')
ICP_BASE=$(awk -v a="$(bal "$W" ICP)"    -v b="$(bal "$AMM" ICP)"    'BEGIN{printf "%.2f", a+b}')
MIN_BASE=$(amm_icp)   # track the lowest AMM base seen across the whole run

echo ""
echo "── 0. Baseline: AMM holds 100 ICP, floor = 15 ICP ──"
B0=$(amm_icp); A0=$(best_ask)
if awk -v x="$B0" 'BEGIN{exit (x>99.0 && x<101.0 ? 0 : 1)}' && [ -n "$A0" ]; then
  ok "AMM seeded with $B0 ICP, best ask = $A0"
else nok "expected AMM base ≈100 with asks quoted" "base=$B0 bestAsk=$A0"; fi

# ── A. Skew rises as base falls (price-sensitive deterrent) ──
echo ""
echo "── A. Ask-side skew rises hyperbolically as base is drawn toward the floor ──"
# Gentle barrier (20bps): steep enough that the ask visibly climbs as base
# falls, shallow enough that the asks stay inside the 5% collar and remain
# buyable — with the production 200bps the second buy could not reach them.
adm setAmmSkewConfig "(\"$MKT\", $(e8 100.0):nat, 30:nat)" >/dev/null
# Warm up: volRegime decays toward zero while the ref is pinned, and the
# half-spread carries volWideningBps — so a baseline taken on the first
# requote is measured against a wider spread than the later samples and can
# mask the barrier's rise. Settle it first, then take A0.
freshrequote; freshrequote; freshrequote
A0=$(best_ask)
# Buys at the top of the collar that fully fill (qty < available), leaving no
# resting remainder, so the book's asks reflect the AMM's fresh quotes.
u placeLimitOrder "(\"$MKT\", variant { buy }, $(e8 10.5):nat, $(e8 60.0):nat)" >/dev/null  # 100 → ~40
freshrequote
B1=$(amm_icp); A1=$(best_ask); lt "$B1" "$MIN_BASE" && MIN_BASE=$B1
u placeLimitOrder "(\"$MKT\", variant { buy }, $(e8 10.5):nat, $(e8 18.0):nat)" >/dev/null  # ~40 → ~22
freshrequote
B2=$(amm_icp); A2=$(best_ask); lt "$B2" "$MIN_BASE" && MIN_BASE=$B2
echo "   base 100→${B1}→${B2} ; best ask ${A0}→${A1}→${A2}"
if [ -n "$A1" ] && [ -n "$A2" ] && lt "$B1" "100.0" && lt "$B2" "$B1" \
   && awk -v a0="$A0" -v a1="$A1" -v a2="$A2" 'BEGIN{exit (a1>a0 && a2>a1 ? 0 : 1)}'; then
  ok "best ask climbed $A0 → $A1 → $A2 as base fell 100 → $B1 → $B2 (barrier skew engaged)"
else nok "ask should rise as base falls toward the floor" "asks $A0/$A1/$A2 base $B1/$B2"; fi

# ── B. Hard floor under relentless price-insensitive buying ──
echo ""
echo "── B. Whale buys at the top of the collar, repeatedly → drains to the floor, never past ──"
# Barrier OFF for this leg: with it on, the ask price runs out of the collar
# long before the floor and PRICE stops the drain, which is leg A's subject.
# Here the depth clamp must be the only thing that stops it, so the asks are
# kept reachable. The floor itself is unchanged (inventoryFloor ignores the
# skew intensity).
adm setAmmSkewConfig "(\"$MKT\", $(e8 100.0):nat, 0:nat)" >/dev/null
freshrequote
breached=""
final_base=""
for i in 1 2 3 4 5 6 7 8; do
  # Marketable at the top of the collar, sized far beyond what the AMM can
  # sell, so only the cumulative ask-depth clamp — not price, not size — can
  # stop it. Unfilled size just rests.
  u placeLimitOrder "(\"$MKT\", variant { buy }, $(e8 10.5):nat, $(e8 200.0):nat)" >/dev/null
  freshrequote
  b=$(amm_icp)
  final_base=$b
  lt "$b" "$MIN_BASE" && MIN_BASE=$b
  # Floor invariant: never below the floor (allow a tiny epsilon).
  if lt "$b" "$(awk -v f="$FLOOR" 'BEGIN{print f-0.05}')"; then breached="yes (cycle $i: $b)"; fi
done
echo "   after 8 whale buys: AMM base = $final_base ICP (floor = $FLOOR) ; min seen = $MIN_BASE"

if [ -z "$breached" ]; then
  ok "floor held every cycle — AMM base never dipped below $FLOOR (min seen $MIN_BASE)"
else nok "floor BREACHED by sustained buying" "$breached"; fi

# Settled at (not merely above) the floor: the clamp is the binding constraint.
if ge "$final_base" "$(awk -v f="$FLOOR" 'BEGIN{print f-0.05}')" \
   && lt "$final_base" "$(awk -v f="$FLOOR" 'BEGIN{print f+1.0}')"; then
  ok "base settled at the floor (${final_base} ≈ ${FLOOR}) — drained down to it, stopped dead"
else nok "base should converge to the floor under relentless buying" "base=$final_base floor=$FLOOR"; fi

# At the floor the AMM withdraws its asks (sellable = 0 → no ask quotes).
AL=$(ask_levels)
if [ "$AL" -eq 0 ]; then
  ok "AMM withdrew ask-side liquidity at the floor (0 ask levels) — won't sell the reserve"
else nok "AMM should quote no asks at the floor" "askLevels=$AL"; fi

# ── C. Conservation ──
echo ""
echo "── C. Conservation (whale + AMM totals unchanged) ──"
USD_NOW=$(awk -v a="$(bal "$W" ICPUSD)" -v b="$(bal "$AMM" ICPUSD)" 'BEGIN{printf "%.2f", a+b}')
ICP_NOW=$(awk -v a="$(bal "$W" ICP)"    -v b="$(bal "$AMM" ICP)"    'BEGIN{printf "%.2f", a+b}')
if awk -v a="$USD_NOW" -v b="$USD_BASE" 'BEGIN{exit ((a-b<0?b-a:a-b) < 1.0 ? 0 : 1)}' \
   && awk -v a="$ICP_NOW" -v b="$ICP_BASE" 'BEGIN{exit ((a-b<0?b-a:a-b) < 0.05 ? 0 : 1)}'; then
  ok "ICPUSD conserved (${USD_NOW}≈$USD_BASE), ICP conserved (${ICP_NOW}≈$ICP_BASE)"
else nok "value leak" "USD $USD_NOW vs $USD_BASE ; ICP $ICP_NOW vs $ICP_BASE"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1   # resume background timers
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
