#!/bin/bash
# Progressive AMM pull-back on oracle staleness (#95). As the oracle price ages
# the AMM WIDENS its spread (quotes get expensive) instead of expiring to an
# empty book at a 60s cliff. Verifies:
#   1. within the grace window → quotes stay tight (no widening)
#   2. past grace → best ask climbs monotonically with staleness
#   3. deep staleness → quotes are STILL on the book (never vanish), and a
#      sweep does not remove them (wall-clock GC expiry, not born-expired)
#
# RUN WITH THE TRADING BOT PAUSED:
#     bash scripts/stop_bots_local.sh
#     bash tests/test_amm_staleness.sh
#
# Staleness is simulated by backdating refPriceUpdatedNs (setTestRefPriceUpdatedNs)
# then requoting — no real outcall needed. Pool: mid 10, spread 20bps, no skew
# config (isolates the staleness term). Floor rate 12bps/s, grace 60s.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

# Integer-money: prices/quantities are Nat BASE UNITS (10^8) in call args AND
# in getOrderBook output (`price = N : nat`, underscore-grouped). e8 converts
# human → base for args; best_ask converts base → human so the widening
# thresholds below stay in human scale. Timestamps (refPriceUpdatedNs,
# setTestRefPriceUpdatedNs) are plain ns ints — NOT money.
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

MKT="ICP-ICPUSD"
adm()  { icp canister call --identity anonymous backend "$@" 2>&1; }
# canister's own clock, read back from the pool after a fresh setAmmRefPrice
ref_now() { adm getAmmPool "(\"$MKT\")" | tr '\n' ' ' | grep -oE "refPriceUpdatedNs = [0-9_]+" | head -1 | grep -oE "[0-9_]+" | tr -d '_'; }
asks_section() { adm getOrderBook "(\"$MKT\")" | tr '\n' ' ' | sed -E 's/.*asks = vec \{//; s/bids = vec.*//'; }
best_ask()  { local n; n=$(asks_section | tr -d '_' | grep -oE "price = [0-9]+" | grep -oE "[0-9]+" | sort -n | head -1); [ -n "$n" ] && from_e8 "$n"; }
ask_count() { asks_section | grep -o "price =" | wc -l | tr -d ' '; }
# fresh-stamp the oracle (refPriceUpdatedNs = now), backdate it by `age` seconds, requote
stale_requote() {
  local age=$1 rp
  adm setAmmRefPrice "(\"$MKT\", $(e8 10.0) : nat)" >/dev/null
  rp=$(ref_now)
  adm setTestRefPriceUpdatedNs "(\"$MKT\", $(( rp - age * 1000000000 )) : int)" >/dev/null
  adm requoteAmm "(\"$MKT\")" >/dev/null
}
gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a >  b ? 0 : 1)}'; }
near() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN{exit ((a-b<0?b-a:a-b) <= t ? 0 : 1)}'; }

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
adm createAmmPool "(\"$MKT\")" >/dev/null 2>&1
# (quoteDepthBase is a base-unit Nat quantity; spread/levels/spacing/window stay plain nats.)
adm setAmmConfig "(\"$MKT\", 20:nat, $(e8 5.0) : nat, 5:nat, 15:nat, 5:nat)" >/dev/null
adm setAmmRefPrice "(\"$MKT\", $(e8 10.0) : nat)" >/dev/null
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
SEED=$(mkid amm_stale_seed)
adm setTestBalance "(principal \"$SEED\", \"ICP\", $(e8 1000.0) : nat)"      >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
icp canister call --identity amm_stale_seed backend seedAmmPool "(\"$MKT\", $(e8 1000.0) : nat, $(e8 100000.0) : nat)" >/dev/null 2>&1
adm enableAmm "(\"$MKT\", true)" >/dev/null

# ── 0. Fresh quote baseline ──
stale_requote 0
A0=$(best_ask)
echo ""
echo "── 0. Fresh: best ask = $A0 (≈ mid+spread, tight) ──"
if [ -n "$A0" ] && near "$A0" 10.02 0.05; then ok "fresh best ask $A0 ≈ 10.02"; else nok "fresh ask should be ~10.02" "ask=$A0"; fi

# ── 1. Within grace (30s < 60s) → no widening ──
stale_requote 30
A1=$(best_ask)
echo ""
echo "── 1. 30s stale (within 60s grace) → best ask = $A1 (unchanged) ──"
if near "$A1" "$A0" 0.02; then ok "within grace: ask $A1 ≈ fresh $A0 (no premature widening)"; else nok "should not widen within grace" "fresh=$A0 stale30s=$A1"; fi

# ── 2. 90s stale → widened (≈ +3.6%: 30s past grace × 12bps/s) ──
stale_requote 90
A2=$(best_ask); C2=$(ask_count)
echo ""
echo "── 2. 90s stale → best ask = $A2 (widened), ask levels = $C2 ──"
if gt "$A2" "10.25" && [ "$C2" -gt 0 ]; then ok "90s stale widened ask to $A2 (>10.25), book still has $C2 levels"; else nok "ask should widen well past mid at 90s" "ask=$A2 levels=$C2"; fi

# ── 3. 180s stale → wider still, book NOT empty ──
stale_requote 180
A3=$(best_ask); C3=$(ask_count)
echo ""
echo "── 3. 180s stale → best ask = $A3 (wider), ask levels = $C3 ──"
if gt "$A3" "$A2" && [ "$C3" -gt 0 ]; then ok "180s ask $A3 > 90s ask $A2, and book still quotes ($C3 levels) — no vanish"; else nok "ask should keep widening and stay on book" "ask180=$A3 ask90=$A2 levels=$C3"; fi

# ── 4. Deep-stale quotes survive a sweep (wall-clock GC, not born-expired) ──
adm adminSweepExpiredOrders "()" >/dev/null 2>&1
C4=$(ask_count); A4=$(best_ask)
echo ""
echo "── 4. After sweep at 180s stale → ask levels = $C4 (quotes survive) ──"
if [ "$C4" -gt 0 ] && gt "$A4" "10.25"; then ok "deep-stale quotes survive the sweep ($C4 wide levels @ $A4) — widen, don't vanish"; else nok "stale quotes should widen and persist, not be swept to empty" "levels=$C4 ask=$A4"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
