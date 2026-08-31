#!/bin/bash
# W4-18 — volume credit reaches the scorecard on EVERY settlement path.
#
# Pre-fix exactly one path credited; AMM-sweep fills, both cross-swap legs
# and pending-finalize filled makers for nothing. The credit now lives
# inside updateStatsAfterTrades — the hook every settling path already
# calls — so a maker filled BY THE SWEEP earns volume like anyone else.
# Observable: the $10k-lifetime-volume badge (lifetimeVol has no direct
# query; badges are its public read).
#
#   §1 direct fill: taker AND maker both cross the $10k badge bar
#   §2 sweep fill: a maker whose resting order the AMM SWEEP takes (no
#      taker-path involvement at all) crosses the bar too — pre-fix this
#      maker earned nothing
#
# Needs #dev. ⚠️ resetExchange for a clean scorecard.

set -u
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
A=$(mkid vc_a); B=$(mkid vc_b); M=$(mkid vc_m)

STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
SEED=$(mkid vc_seed)
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 300.0) : nat, 5:nat, 10:nat, 5:nat)" >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICP\", $(e8 20000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 300000.0) : nat)" >/dev/null
icp canister call --identity vc_seed backend seedAmmPool "(\"ICP-ICPUSD\", $(e8 20000.0) : nat, $(e8 200000.0) : nat)" >/dev/null 2>&1
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null

hasbadge() { adm getUserBadges "(principal \"$1\")" --query | grep -c "MULTI/DEX Player"; }

echo "── §1 direct fill credits BOTH parties ──"
adm setTestBalance "(principal \"$B\", \"ICP\", $(e8 2000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$A\", \"ICPUSD\", $(e8 45000.0) : nat)" >/dev/null
# B rests a passive ask at 10.5 (non-crossing); A lifts it with a staged buy.
icp canister call --identity vc_b backend placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 10.40) : nat, $(e8 1100.0) : nat)" >/dev/null 2>&1
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null; adm requoteAmm '("ICP-ICPUSD")' >/dev/null   # release → rests
icp canister call --identity vc_a backend placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 10.45) : nat, $(e8 2700.0) : nat)" >/dev/null 2>&1
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null; adm requoteAmm '("ICP-ICPUSD")' >/dev/null   # release → crosses B
# Badges award on the (heartbeat-cadenced) volume pass — resume timers and
# poll one tier tick.
adm setTestTimersPaused '(false)' >/dev/null 2>&1
AB=0; BB=0
for _ in $(seq 1 30); do
  AB=$(hasbadge "$A"); BB=$(hasbadge "$B")
  [ "${AB:-0}" -ge 1 ] && [ "${BB:-0}" -ge 1 ] && break
  sleep 3
done
[ "${AB:-0}" -ge 1 ] && ok "taker credited (badge at \$10k)" || nok "taker uncredited" "badges: $(adm getUserBadges "(principal \"$A\")" --query | head -c 120)"
[ "${BB:-0}" -ge 1 ] && ok "maker credited (badge at \$10k)" || nok "maker uncredited" "badges: $(adm getUserBadges "(principal \"$B\")" --query | head -c 120)"
adm setTestTimersPaused '(true)' >/dev/null 2>&1

echo "── §2 an AMM-sweep fill credits the swept maker ──"
adm setTestBalance "(principal \"$M\", \"ICPUSD\", $(e8 30000.0) : nat)" >/dev/null
# M rests a passive bid at 9.60 (below the AMM band), then the mark FALLS so
# the AMM's fresh asks land under M's bid → the GEPTOR sweep fills M vs the
# AMM. M never takes; only the sweep path settles this.
icp canister call --identity vc_m backend placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 9.60) : nat, $(e8 1100.0) : nat)" >/dev/null 2>&1
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null; adm requoteAmm '("ICP-ICPUSD")' >/dev/null   # release → rests at 9.60
R=$(adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 9.40) : nat)")   # mark drops 6% — M's bid is now rich vs the AMM ask
adm requoteAmm '("ICP-ICPUSD")' >/dev/null                     # requote + sweep takes M's bid
adm setTestTimersPaused '(false)' >/dev/null 2>&1
MB=0
for _ in $(seq 1 30); do
  MB=$(hasbadge "$M"); [ "${MB:-0}" -ge 1 ] && break
  sleep 3
done
if [ "${MB:-0}" -ge 1 ]; then
  ok "swept maker credited (badge at \$10k) — pre-fix this maker earned NOTHING"
else nok "sweep fill still uncredited (the finding)" "badges: $(adm getUserBadges "(principal \"$M\")" --query | head -c 200)"; fi
# W4-22 / W6-12 rule 2: the badge above is ROLE-AGNOSTIC (lifetimeVol) and
# passed for months while swept makers were mis-binned as takers — assert
# the SPECIFIC series the fix moves: the swept fill must land in MAKER
# volume (engine stamps the re-homed order's pre-reserved id; attribution
# keys off a non-zero id).
MVOL=$(icp canister call --identity vc_m backend getAccessPolicy '()' --query 2>/dev/null | tr -d '_\n' | tr -s ' ' | grep -oE 'myMakerVolUsd = [0-9]+' | grep -oE '[0-9]+$')
if [ "${MVOL:-0}" -gt 0 ]; then
  ok "swept fill landed in MAKER volume (myMakerVolUsd=$MVOL) — the role, not just the volume"
else nok "swept maker still binned as taker (the R2 role bug)" "myMakerVolUsd=${MVOL:-unreadable}"; fi

echo "── §3 the swept maker pays the MAKER rate (W4-22: 'never pays taker') ──"
# Asserted on §2's OWN sweep fill (vc_m): the aggressor-leg fee under
# aggressorIsMaker is the SAME engine site for a plain limit and a rested
# post-only — the PO flag is consumed at release and adds nothing once the
# order rests, so this fee bound IS the :10119 "never pays taker" promise
# for the swept path. (A PO-specific end-to-end choreography kept tripping
# venue physics — jump breaker, vol-EWMA clamp, pend widening, GEPTOR
# staging, spread geometry — and lives as its own fixture now:
# tests/test_po_sweep_fee.sh, which documents how each trap is dodged.)
ROW=$(icp canister call --identity vc_m backend getMyTradesSinceId '(0 : nat, 5 : nat)' --query 2>/dev/null | tr -d '_\n' | tr -s ' ')
FEE=$(echo "$ROW" | grep -oE 'buyer = [0-9]+' | head -1 | grep -oE '[0-9]+$')
QTY=$(echo "$ROW" | grep -oE 'quantity = [0-9]+' | head -1 | grep -oE '[0-9]+$')
PRC=$(echo "$ROW" | grep -oE 'price = [0-9]+' | head -1 | grep -oE '[0-9]+$')
if [ -n "$FEE" ] && [ -n "$QTY" ] && [ -n "$PRC" ]; then
  V=$(awk -v q="$QTY" -v p="$PRC" 'BEGIN{ printf "%.0f", q*p/100000000 }')
  TAKER=$(awk -v v="$V" 'BEGIN{ printf "%.0f", v*100/100000 }')   # L0 taker = 10.0 bps
  MAXOK=$(awk -v v="$V" 'BEGIN{ printf "%.0f", v*60/100000 }')    # 6 bps: above L0 maker (5) + rounding, well under taker
  if [ "$FEE" -le "$MAXOK" ]; then
    ok "swept maker paid the MAKER rate (fee=$FEE on \$-value $V; taker would be $TAKER) — the :10119 promise holds on this path"
  else nok "swept maker paid TAKER (the published-contract violation)" "fee=$FEE vs taker-rate $TAKER"; fi
else nok "sweep fill not found for the fee assertion" "$(echo "$ROW" | head -c 160)"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_volume_credit ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_volume_credit ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
