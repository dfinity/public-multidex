#!/bin/bash
# #51.1 (public issue #51 finding 1): the MM quote-freshness shield must NOT
# survive a protocol KILL of the staged intent that armed it. clearMmShield's
# original call sites were all user-initiated cancels; releaseDeferred's kill
# exits (user-expiry, FOK, post-only maker-or-kill, initial-margin #none) and
# processDeferredExpiry's FOK oracle-stall kill dropped the intent without
# dropping the stamps — so an L4 quoter could hold their whole book off the
# users-only fallback through an oracle stall by renewing KILLS instead of
# cancels. Invariant (main.mo, clearMmShield): an intent that never lands must
# not shield anything.
#
# Sections (each: MM rests a BETTER ask, a plain user rests a WORSE ask, the
# kill fires, then a whale's expiring market buy probes the users-only
# fallback — a CLEARED shield means the MM's better ask fills; a leaked shield
# means the plain user's worse ask fills instead):
#   A. user-expiry kill at release      (releaseDeferred, W4-06 gate)
#   B. FOK kill at release              (releaseDeferred, depth short)
#   C. post-only maker-or-kill          (releaseDeferred, book crosses)
#   D. FOK oracle-stall kill            (processDeferredExpiry FOK branch)
#   E. LANDING retains the shield       (control: a landed intent still shields)
# The initial-margin #none kill exit is cleared in code too but is not
# exercisable here: clampToInitialMargin returns #full for any owner without a
# margin account, margin accounts are pool-only, and pool principals never call
# placeLimitInner, so no shield can be armed on that path today (defensive).
# Fixture: enabled AMM pool with numLevels=0 (GEPTOR runs, no AMM quotes) —
# the test_release_priority pattern. Timers paused; releases driven manually.
# ⚠️ Calls resetExchange.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }

mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
MM=$(mkid ms_mm); PLN=$(mkid ms_pln); WHL=$(mkid ms_whl)
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
mm()  { icp canister call --identity ms_mm  backend "$@" 2>&1; }
pln() { icp canister call --identity ms_pln backend "$@" 2>&1; }
whl() { icp canister call --identity ms_whl backend "$@" 2>&1; }
release() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
last_trade_id() { adm getRecentTrades '("BTC-ICPUSD")' | grep -oE "id = [0-9_]+ : nat" | tail -1 | grep -oE "[0-9_]+" | tr -d '_'; }
fills_since()   { icp canister call --identity "$1" backend getMyTradesSinceId "(${2:-0} : nat, 50 : nat)" 2>&1 | tr -d '_'; }
staged_id()     { icp canister call --identity "$1" backend getMyStagedOrderIds '()' 2>&1 | tr -d '_' | grep -oE "[0-9]+" | head -1; }

# Fresh fixture per section: the shield stamps are owner-level with a 30s TTL,
# so each section re-arms and probes well inside one TTL window.
fixture() {
  adm resetExchange "()" >/dev/null 2>&1 || true
  adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
  adm setAmmConfig "(\"BTC-ICPUSD\", 20:nat, 0 : nat, 0:nat, 10:nat, 5:nat)" >/dev/null
  adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
  adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1 || true
  for P in "$MM" "$PLN" "$WHL"; do
    adm setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 1000000.0) : nat)" >/dev/null
    adm setTestBalance "(principal \"$P\", \"BTC\",    $(e8 10.0) : nat)"      >/dev/null
  done
  # Earn L4 (the shielded tier): W = 2×$50k ≥ the $100k bar + qualified uptime.
  adm setTestScorecard "(principal \"$MM\", $(e8 50000) : nat, 0 : nat, 30 : nat, 25 : nat)" >/dev/null
  # The book the probe chooses from: MM's BETTER ask vs the plain user's WORSE
  # ask; both rest. (The MM placement arms a stamp too — irrelevant: the kill
  # under test deletes the owner-level stamp outright, whoever wrote it last.)
  mm  placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 50080) : nat, $(e8 0.2) : nat)" >/dev/null
  pln placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 50120) : nat, $(e8 0.2) : nat)" >/dev/null
  release
}

# Probe the users-only (oracle-stall) fallback: the whale stages a market buy,
# its staging window is backdated, and the expiry pass releases it against user
# liquidity only. Which ask fills reveals the shield state.
#   probe_expect_cleared "label"  → MM's better ask (50080) must fill
#   probe_expect_shielded "label" → plain's worse ask (50120) must fill
probe() {
  BASE=$(last_trade_id)
  whl placeMarketOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 0.2) : nat, $(e8 0.05) : nat, false)" >/dev/null
  WSID=$(staged_id ms_whl)
  adm setTestDeferredExpiry "(${WSID:-0} : nat, 1 : int)" >/dev/null 2>&1
  adm adminRunDeferredExpiry "()" >/dev/null 2>&1
  MMF=$(fills_since ms_mm  "${BASE:-0}")
  PLF=$(fills_since ms_pln "${BASE:-0}")
}
probe_expect_cleared() {
  probe
  if echo "$MMF" | grep -q "price = $(e8 50080) : nat" && ! echo "$PLF" | grep -q "trade = record"; then
    ok "$1: shield CLEARED — fallback took the MM's better ask @50080"
  else nok "$1: shield leaked — MM ask skipped" "mmFills=$(echo "$MMF" | grep -c 'trade = record') plnFills=$(echo "$PLF" | grep -c 'trade = record')"; fi
}
probe_expect_shielded() {
  probe
  if echo "$PLF" | grep -q "price = $(e8 50120) : nat" && ! echo "$MMF" | grep -q "trade = record"; then
    ok "$1: shield HELD — fallback skipped the MM's book, took the worse ask @50120"
  else nok "$1: expected the plain ask (50120) to fill, not the MM's" "mmFills=$(echo "$MMF" | grep -c 'trade = record') plnFills=$(echo "$PLF" | grep -c 'trade = record')"; fi
}

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true

echo "── A. user-expiry kill at release clears the shield ──"
fixture
# Killer intent: non-crossing buy with a 2s good-till; by release time it has
# lapsed → the W4-06 kill fires (record + return), which must clear the stamps.
# (GTD 2s + sleep 4 is the proven test_w4_correctness_batch §4 pattern.)
mm placeLimitOrderExp "(\"BTC-ICPUSD\", variant { buy }, $(e8 49000) : nat, $(e8 0.05) : nat, opt (2 : nat))" >/dev/null
sleep 4
release
if [ -z "$(staged_id ms_mm)" ]; then ok "A: the expired intent was killed at release (nothing staged)"
else nok "A: killer intent still staged" "$(staged_id ms_mm)"; fi
probe_expect_cleared "A"

echo "── B. FOK kill at release clears the shield ──"
fixture
# Killer intent: FOK market buy far beyond takeable depth (book holds 0.4) →
# the all-or-nothing gate kills it at release.
mm placeMarketOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 5.0) : nat, $(e8 0.05) : nat, true)" >/dev/null
release
if [ -z "$(staged_id ms_mm)" ]; then ok "B: the FOK intent was killed at release (nothing staged)"
else nok "B: killer intent still staged" "$(staged_id ms_mm)"; fi
probe_expect_cleared "B"

echo "── C. post-only maker-or-kill clears the shield ──"
fixture
# Killer intent: post-only buy at 50120 — funded takeable depth crosses the
# limit at release → maker-or-kill fires.
mm placeLimitOrderPO "(\"BTC-ICPUSD\", variant { buy }, $(e8 50120) : nat, $(e8 0.05) : nat, null)" >/dev/null
release
if [ -z "$(staged_id ms_mm)" ]; then ok "C: the post-only intent was killed at release (nothing staged)"
else nok "C: killer intent still staged" "$(staged_id ms_mm)"; fi
probe_expect_cleared "C"

echo "── D. FOK oracle-stall (expiry-path) kill clears the shield ──"
fixture
# Killer intent: FOK market buy, never released — its staging window is
# backdated and the expiry pass takes the FOK branch (kill + refund, no fill).
mm placeMarketOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 5.0) : nat, $(e8 0.05) : nat, true)" >/dev/null
KSID=$(staged_id ms_mm)
adm setTestDeferredExpiry "(${KSID:-0} : nat, 1 : int)" >/dev/null 2>&1
adm adminRunDeferredExpiry "()" >/dev/null 2>&1
if [ -z "$(staged_id ms_mm)" ]; then ok "D: the stalled FOK intent was killed by the expiry pass"
else nok "D: killer intent still staged" "$(staged_id ms_mm)"; fi
probe_expect_cleared "D"

echo "── E. control: a LANDED intent keeps its shield ──"
fixture
# Fresh intent that lands cleanly (non-crossing sell rests on the book): the
# stamp is the repricing intent that just landed — the fallback must still
# skip the MM's book and fill the plain user's worse ask.
mm placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 50090) : nat, $(e8 0.05) : nat)" >/dev/null
release
probe_expect_shielded "E"

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
