#!/bin/bash
# Sealed-until-GEPTOR model — EVERY order stages off-book and releases only on a
# post-posting GEPTOR, matching crossing users + the fresh AMM; remainder rests.
#
# RUN WITH THE TRADING BOT PAUSED:
#     bash scripts/stop_bots_local.sh
#     bash tests/test_sealed_model.sh
#
# Verifies:
#   1. A limit order is STAGED: not on the public book, but visible to its owner
#      in Open Orders with status #staged, and 0 filled.
#   2. Anti-snipe: a requote with NO fresh fetch does NOT release it.
#   3. Fresh fetch + requote RELEASES it: executes vs the fresh AMM, gone from
#      Open Orders, filled at the AMM price.
#   4. A PASSIVE limit (below market) stages, then on release rests VISIBLY on
#      the public book (it "joins the book").
#   5. User↔user: a staged buy matches another user's resting ask on release.
#   6. Conservation.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

# Integer-money migration: trading/admin methods take Nat BASE UNITS (10^8), and
# getTestBalance / getOrderBook now RETURN base units. e8 converts human→base for
# call args; from_e8 converts base→human so the human-scale assertions stay valid.
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
adm()  { icp canister call --identity anonymous backend "$@" 2>&1; }
# The AMM's inventory lives under its own principal — resolve it LIVE (a
# hardcoded id goes stale on every redeploy and silently zeroes the AMM's
# side of the conservation sums).
AMM=$(adm getAmmPrincipal '()' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
# bal → HUMAN units: pull the base-unit Nat (strip Candid underscores) and /1e8.
bal()  { local n; n=$(adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+"); [ -z "$n" ] && n=0; from_e8 "$n"; }
# Treasury USD (human) — the maker/taker fee skims here on every fill, so the
# ICPUSD conservation set must include it (resetExchange zeroes it at setup).
treas() { local n; n=$(adm getTreasury '()' | tr -d '_' | grep -oE "balanceUsd = [0-9]+" | grep -oE "[0-9]+"); [ -z "$n" ] && n=0; from_e8 "$n"; }
freshrequote() { adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null; adm requoteAmm '("ICP-ICPUSD")' >/dev/null; }
# Count of UA's staged (off-book) orders, and whether the book has a price ≈ arg (human).
ua_staged() { icp canister call --identity amm_uA backend getMyStagedOrderIds '()' 2>&1 | grep -oE "[0-9_]+ : nat" | wc -l | tr -d ' '; }
# Book prices are base-unit Nats now — compare against e8(threshold) with an e8(0.02) band.
book_has_price() { local t; t=$(e8 "$1"); adm getOrderBook '("ICP-ICPUSD")' 2>&1 | tr -d '_' | grep -oE "price = [0-9]+" | grep -oE "[0-9]+" | awk -v t="$t" 'function abs(x){return x<0?-x:x} abs($1-t)<2000000{f=1} END{print (f?"yes":"no")}'; }

S=$(mkid amm_seed); UA=$(mkid amm_uA); UB=$(mkid amm_uB)
seed(){ icp canister call --identity amm_seed backend "$@" 2>&1; }
u()   { icp canister call --identity amm_uA backend "$@" 2>&1; }
v()   { icp canister call --identity amm_uB backend "$@" 2>&1; }
uorders_market() { icp canister call --identity amm_uA backend getMyOrdersOnMarket '("ICP-ICPUSD")' 2>&1; }

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1   # quiesce background timers for a deterministic run
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
# (quoteDepthBase is a base-unit Nat quantity now; spread/levels/spacing/window stay plain nats.)
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 100.0) : nat, 5:nat, 10:nat, 5:nat)" >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$S\", \"ICP\", $(e8 10000.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
seed seedAmmPool "(\"ICP-ICPUSD\", $(e8 10000.0) : nat, $(e8 100000.0) : nat)" >/dev/null
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
for t in ICP ICPUSD; do adm setTestBalance "(principal \"$UA\", \"$t\", $(e8 0.0) : nat)" >/dev/null; adm setTestBalance "(principal \"$UB\", \"$t\", $(e8 0.0) : nat)" >/dev/null; done
adm setTestBalance "(principal \"$UA\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$UB\", \"ICP\", $(e8 100.0) : nat)" >/dev/null

# Closed set = {UA, UB, AMM, seed identity, treasury}: fees skim to the treasury
# and the AMM holds the pool inventory under its own principal.
USD_BASE=$(awk -v a="$(bal "$UA" ICPUSD)" -v b="$(bal "$AMM" ICPUSD)" -v c="$(bal "$UB" ICPUSD)" -v s="$(bal "$S" ICPUSD)" -v t="$(treas)" 'BEGIN{printf "%.4f", a+b+c+s+t}')
ICP_BASE=$(awk -v a="$(bal "$UA" ICP)" -v b="$(bal "$AMM" ICP)" -v c="$(bal "$UB" ICP)" -v s="$(bal "$S" ICP)" 'BEGIN{printf "%.4f", a+b+c+s}')

# ── 1. Limit buy 5 @ 10.3 (crosses AMM) → STAGED off-book ──
# The price must satisfy TWO bounds at once, which is why it is not a round
# number: it has to CROSS the AMM ask (ref 10.0 + 20bps spread ≈ 10.02) so the
# order is marketable and stages, while staying inside the marketable collar
# (MARKETABLE_BAND_BPS = 500 → 10.0 × 1.05 = 10.50, main.mo). This was 11.0,
# i.e. +10%, which the collar has refused since ac59ae8 (2026-07-29) — the
# order never staged and §1–§3 failed on a fixture that predates the band.
echo ""
echo "── 1. Limit buy 5 @ 10.3 → STAGED (off-book, in Open Orders as #staged, 0 filled) ──"
RES=$(u placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 10.3) : nat, $(e8 5.0) : nat)")
ICP_P=$(bal "$UA" ICP); NST=$(ua_staged); ON_BOOK=$(book_has_price 10.3)
if echo "$RES" | grep -q "ok" \
   && awk -v x="$ICP_P" 'BEGIN{exit (x<0.0000001?0:1)}' \
   && [ "$NST" -ge 1 ] && [ "$ON_BOOK" = "no" ]; then
  ok "staged: 0 filled, in owner's staged list ($NST), NOT on public book (no bid @ 10.3)"
else nok "order should be staged off-book + visible to owner" "icp=$ICP_P staged=$NST bid@10.3?=$ON_BOOK"; fi

# ── 2. Anti-snipe: requote WITHOUT a fresh fetch → NOT released ──
echo ""
echo "── 2. Requote WITHOUT a fresh fetch → NOT released ──"
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
ICP_NS=$(bal "$UA" ICP)
if awk -v x="$ICP_NS" 'BEGIN{exit (x<0.0000001?0:1)}'; then ok "anti-snipe: still staged (postdates last fetch)"; else nok "should not release pre-fetch" "icp=$ICP_NS"; fi

# ── 3. Fresh fetch + requote → RELEASED at the AMM price ──
echo ""
echo "── 3. Fresh fetch + requote → RELEASED, filled at AMM price, gone from Open Orders ──"
freshrequote
ICP1=$(bal "$UA" ICP); USD1=$(bal "$UA" ICPUSD); OO3=$(uorders_market)
if awk -v i="$ICP1" 'BEGIN{exit (i>4.99?0:1)}' && ! echo "$OO3" | grep -q "staged"; then
  AVG=$(awk -v s="$USD1" -v i="$ICP1" 'BEGIN{printf "%.4f", (100000-s)/i}')
  # Bound sits BELOW the 10.3 limit on purpose: the point of the assertion is
  # that the fill took the AMM's ask (≈10.02 + fee), not the buyer's limit. A
  # bound at or above the limit would pass no matter what price it filled at.
  if awk -v a="$AVG" 'BEGIN{exit (a < 10.25 ? 0 : 1)}'; then ok "released + filled $ICP1 ICP at avg $AVG (< 10.25, i.e. the AMM ask not the 10.3 limit), no longer staged"; else nok "filled at wrong price" "avg=$AVG"; fi
else nok "should release + fill after fresh fetch" "icp=$ICP1 stagedLeft?[$(echo "$OO3" | grep -c staged)]"; fi

# ── 4. Passive limit (below market) stages, then rests VISIBLY on release ──
echo ""
echo "── 4. Passive buy 3 @ 9.0 → stages, then on release RESTS visibly on the book ──"
u placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 9.0) : nat, $(e8 3.0) : nat)" >/dev/null
STAGED_BEFORE=$(book_has_price 9.0)   # must be "no" — still staged, not on book
freshrequote
# After release: 9.0 doesn't cross (AMM ask > 9.0), so it rests at 9.0 → now visible.
ON_BOOK_AFTER=$(book_has_price 9.0)
if [ "$STAGED_BEFORE" = "no" ] && [ "$ON_BOOK_AFTER" = "yes" ]; then ok "passive order off-book while staged, then RESTS visibly at 9.0 after its GEPTOR"; else nok "passive order should stage then rest visibly at 9.0" "beforeBookHas9=$STAGED_BEFORE afterBookHas9=$ON_BOOK_AFTER"; fi

# ── 5. User↔user on release: staged buy matches a resting user ask ──
echo ""
echo "── 5. User↔user: staged buy matches another user's resting ask (inside the spread) ──"
# UB posts an ask at 10.00 (inside AMM spread ~9.98/10.02) → stages → release → rests at 10.00.
v placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 10.00) : nat, $(e8 4.0) : nat)" >/dev/null
freshrequote
UA_ICP0=$(bal "$UA" ICP)
# UA buys 4 @ 10.00 → stages → release → matches UB's ask at 10.00 (better than AMM ask 10.02).
u placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 10.00) : nat, $(e8 4.0) : nat)" >/dev/null
freshrequote
UA_ICP1=$(bal "$UA" ICP)
if awk -v a="$UA_ICP0" -v b="$UA_ICP1" 'BEGIN{exit (b-a > 3.9 ? 0 : 1)}'; then ok "staged buy matched the resting user ask on release (+~4 ICP to UA)"; else nok "user↔user match on release failed" "delta=$(awk -v a="$UA_ICP0" -v b="$UA_ICP1" 'BEGIN{print b-a}')"; fi

# ── 6. Conservation ──
echo ""
echo "── 6. Conservation (UA + UB + AMM totals unchanged) ──"
USD_NOW=$(awk -v a="$(bal "$UA" ICPUSD)" -v b="$(bal "$AMM" ICPUSD)" -v c="$(bal "$UB" ICPUSD)" -v s="$(bal "$S" ICPUSD)" -v t="$(treas)" 'BEGIN{printf "%.4f", a+b+c+s+t}')
ICP_NOW=$(awk -v a="$(bal "$UA" ICP)" -v b="$(bal "$AMM" ICP)" -v c="$(bal "$UB" ICP)" -v s="$(bal "$S" ICP)" 'BEGIN{printf "%.4f", a+b+c+s}')
if awk -v a="$USD_NOW" -v b="$USD_BASE" 'BEGIN{exit (((a-b<0?b-a:a-b)) < 0.02 ? 0 : 1)}' \
   && awk -v a="$ICP_NOW" -v b="$ICP_BASE" 'BEGIN{exit (((a-b<0?b-a:a-b)) < 0.02 ? 0 : 1)}'; then
  ok "ICPUSD conserved (${USD_NOW}≈$USD_BASE), ICP conserved (${ICP_NOW}≈$ICP_BASE)"
else nok "value leak" "USD $USD_NOW vs $USD_BASE ; ICP $ICP_NOW vs $ICP_BASE"; fi

echo ""
adm setTestTimersPaused '(false)' >/dev/null 2>&1   # resume background timers
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
