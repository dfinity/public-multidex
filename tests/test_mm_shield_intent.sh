#!/bin/bash
# H-24 (F2, D1 option (a)) — the L4 quote-freshness shield exists only while a
# GENUINE repricing intent is in flight, and shielded depth earns neither
# display weight nor uptime.
#
# Pre-fix, placeLimitInner stamped mmQuoteStamp/mmOwnerStamp on ANY staged L4
# limit and a landed intent kept its shield by design, so a $10 dust limit far
# from the mid — always landing, one staging per <30 s — renewed the owner's
# shield forever; getTakeableDepth walked with no exclusions and sampleUptime
# credited shielded quotes, so the phantom book also sustained the L4 that
# shielded it. Now (main.mo isRepricingIntent / landMmShield):
#   · the stamp is written only for an intent whose notional is ≥ 20% of the
#     owner's RESTING notional on that market AND whose price is within 2% of
#     the mark (MM_SHIELD_MIN_NOTIONAL_BPS / MM_SHIELD_PROX_BPS);
#   · it lapses the moment THAT intent lands (a newer in-flight intent's stamp
#     survives an older one's landing);
#   · getTakeableDepth excludes shielded (and expired) makers;
#   · sampleUptime skips a market on which the owner's quotes are shielded.
#
# Sections (§1-§5 use test_mm_shield_kill_exits.sh's users-only probe: a
# whale's expiring market buy releases through the oracle-stall fallback —
# a CLEARED shield means the MM's better ask fills, a HELD shield means the
# plain user's worse ask fills instead; the stamp WRITE and CLEAR rules under
# test are shared by the fresh and the stale predicate):
#   §1 dust intent (0.001 BTC ≈ $50, 0.5% of the $10k resting book) → no shield
#   §2 far-from-mid intent (+3%, notional 100%)                       → no shield
#   §3 commensurate near-mid intent IN FLIGHT                          → shielded (control)
#   §4 that intent LANDS                                               → shield lapses
#      (reverses test_mm_shield_kill_exits.sh's old §E per D1)
#   §5 a NEWER in-flight intent survives an older one's landing         → shielded
#   §6 getTakeableDepth: a shielded ask counts ZERO while the intent is in
#      flight past the mark's dispatch, and counts again once it lands
#   §7 uptime: a funded two-sided L4 book within ±1% FAILS the sample while
#      shielded, PASSES once the intent lands
# Fixture: enabled AMM pool with numLevels=0 (GEPTOR runs, no AMM quotes) —
# the test_release_priority pattern. Timers paused; releases driven manually.
# Needs #dev. ⚠️ Calls resetExchange (reset again at exit).

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }

if [ "$(venue_posture)" != "dev" ]; then skip_posture "test_mm_shield_intent" "setTestScorecard / devTickTier / adminRunDeferredExpiry (#dev hooks)"; fi

mdx_identity_new si_mm; MM=$(principal_of si_mm); mdx_identity_new si_pln; PLN=$(principal_of si_pln); mdx_identity_new si_whl; WHL=$(principal_of si_whl)
adm() { echo y | icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
mm()  { echo y | icp canister call --candid "$MDX_CANDID" --identity si_mm  backend "$@" 2>&1; }
pln() { echo y | icp canister call --candid "$MDX_CANDID" --identity si_pln backend "$@" 2>&1; }
whl() { echo y | icp canister call --candid "$MDX_CANDID" --identity si_whl backend "$@" 2>&1; }
# One release pass: re-stamp the mark (dispatch = now, so every staged entry is
# due) and requote (sweep + processDeferred).
restamp()  { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null; }
release()  { restamp; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
last_trade_id() { adm getRecentTrades '("BTC-ICPUSD")' | grep -oE "id = [0-9_]+ : nat" | tail -1 | grep -oE "[0-9_]+" | tr -d '_'; }
fills_since()   { echo y | icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyTradesSinceId "(${2:-0} : nat, 50 : nat)" 2>&1 | tr -d '_'; }
staged_ids()    { echo y | icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyStagedOrderIds '()' 2>&1 | tr -d '_' | grep -oE "[0-9]+" | tr '\n' ' '; }
staged_count()  { staged_ids "$1" | wc -w | tr -d ' '; }
open_count()    { echo y | icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyOrders '()' --query 2>&1 | tr -d '_\n' | grep -o 'id = [0-9]' | wc -l | tr -d ' '; }
depth_buy()     { adm getTakeableDepth "(\"BTC-ICPUSD\", variant { buy }, $(e8 60000.0) : nat)" --query | tr -d '_' | grep -oE '[0-9]+' | head -1; }

# Fresh fixture per section: the MM (L4) rests a BETTER ask (0.2 @ 50080 —
# $10,016 of resting depth, the "book" a repricing intent is measured against),
# a plain user rests a WORSE ask (0.2 @ 50120). Both land through one release.
# The MM's own placement stamps nothing: nothing of theirs is resting yet.
fixture() {
  adm resetExchange "()" >/dev/null 2>&1 || true
  adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
  adm setAmmConfig "(\"BTC-ICPUSD\", 20:nat, 0 : nat, 0:nat, 10:nat)" >/dev/null
  restamp
  adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1 || true
  for P in "$MM" "$PLN" "$WHL"; do
    adm setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 1000000.0) : nat)" >/dev/null
    adm setTestBalance "(principal \"$P\", \"BTC\",    $(e8 10.0) : nat)"      >/dev/null
  done
  # Earn L4 (the shielded tier): W = 2×$50k ≥ the $100k bar + qualified uptime (25/30).
  adm setTestScorecard "(principal \"$MM\", $(e8 50000) : nat, 0 : nat, 30 : nat, 25 : nat)" >/dev/null
  mm  placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 50080) : nat, $(e8 0.2) : nat)" >/dev/null
  pln placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 50120) : nat, $(e8 0.2) : nat)" >/dev/null
  release
}

# The users-only (oracle-stall) probe — see test_mm_shield_kill_exits.sh.
probe() {
  BASE=$(last_trade_id)
  whl placeMarketOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 0.2) : nat, $(e8 0.05) : nat, false)" >/dev/null
  WSID=$(staged_ids si_whl | awk '{print $1}')
  adm setTestDeferredExpiry "(${WSID:-0} : nat, 1 : int)" >/dev/null 2>&1
  adm adminRunDeferredExpiry "()" >/dev/null 2>&1
  MMF=$(fills_since si_mm  "${BASE:-0}")
  PLF=$(fills_since si_pln "${BASE:-0}")
}
probe_expect_cleared() {
  probe
  if echo "$MMF" | grep -q "price = $(e8 50080) : nat" && ! echo "$PLF" | grep -q "trade = record"; then
    ok "$1: NO shield — fallback took the MM's better ask @50080"
  else nok "$1: shield present — MM ask skipped" "mmFills=$(echo "$MMF" | grep -c 'trade = record') plnFills=$(echo "$PLF" | grep -c 'trade = record')"; fi
}
probe_expect_shielded() {
  probe
  if echo "$PLF" | grep -q "price = $(e8 50120) : nat" && ! echo "$MMF" | grep -q "trade = record"; then
    ok "$1: shield HELD — fallback skipped the MM's book, took the worse ask @50120"
  else nok "$1: expected the plain ask (50120) to fill, not the MM's" "mmFills=$(echo "$MMF" | grep -c 'trade = record') plnFills=$(echo "$PLF" | grep -c 'trade = record')"; fi
}

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true

echo "── §1 a DUST intent earns no shield ──"
fixture
# 0.001 BTC @ 50090 ≈ $50 — 0.5% of the MM's $10,016 resting book (bar: 20%).
mm placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 50090) : nat, $(e8 0.001) : nat)" >/dev/null
[ "$(staged_count si_mm)" = "1" ] && ok "§1: dust intent is staged (in flight)" || nok "§1: dust intent not staged" "$(staged_ids si_mm)"
probe_expect_cleared "§1 dust intent in flight"

echo "── §2 a FAR-FROM-MID intent earns no shield ──"
fixture
# 0.2 BTC @ 51500 — the full book's notional, but +3.0% off the $50,000 mark (bar: 2%).
mm placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 51500) : nat, $(e8 0.2) : nat)" >/dev/null
[ "$(staged_count si_mm)" = "1" ] && ok "§2: far intent is staged (in flight)" || nok "§2: far intent not staged" "$(staged_ids si_mm)"
probe_expect_cleared "§2 far-from-mid intent in flight"

echo "── §3 control: a COMMENSURATE near-mid intent in flight shields ──"
fixture
# BUY 0.1 @ 49600 — $4,960 ≈ 49.5% of the resting book, 0.8% off the mark; a
# bid, so its eventual landing adds no ask the probe could take.
mm placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 49600) : nat, $(e8 0.1) : nat)" >/dev/null
[ "$(staged_count si_mm)" = "1" ] && ok "§3: commensurate intent is staged (in flight)" || nok "§3: intent not staged" "$(staged_ids si_mm)"
probe_expect_shielded "§3 commensurate intent in flight"

echo "── §4 the intent LANDS → the shield lapses (D1 reverses the old §E) ──"
fixture
mm placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 49600) : nat, $(e8 0.1) : nat)" >/dev/null
release
if [ "$(staged_count si_mm)" = "0" ] && [ "$(open_count si_mm)" = "2" ]; then ok "§4: the intent landed (rests; nothing staged)"
else nok "§4: intent did not land" "staged=$(staged_ids si_mm) open=$(open_count si_mm)"; fi
probe_expect_cleared "§4 landed intent"

echo "── §5 a NEWER in-flight intent survives an older one's landing ──"
fixture
mm placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 49600) : nat, $(e8 0.1) : nat)" >/dev/null   # I1 — due at the next pass
restamp                                                                                                    # dispatch: I1 is due, anything staged after is not
mm placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 49650) : nat, $(e8 0.1) : nat)" >/dev/null   # I2 — staged AFTER the dispatch: stays in flight
adm requoteAmm '("BTC-ICPUSD")' >/dev/null                                                                # I1 lands, I2 stays staged
if [ "$(staged_count si_mm)" = "1" ] && [ "$(open_count si_mm)" = "3" ]; then ok "§5: I1 landed, I2 still in flight (getMyOrders lists the staged I2 too: 2 resting + 1 staged)"
else nok "§5: expected I1 landed + I2 staged" "staged=$(staged_ids si_mm) open=$(open_count si_mm)"; fi
probe_expect_shielded "§5 newer intent in flight after the older landed"

echo "── §6 getTakeableDepth: shielded depth is not takeable depth ──"
fixture
D0=$(depth_buy)
if [ "${D0:-0}" = "$(e8 0.4)" ]; then ok "§6: baseline — both asks takeable (0.4 BTC)"
else nok "§6: baseline depth" "got ${D0:-?} want $(e8 0.4)"; fi
# The fixture's release stamped the mark's dispatch; an intent staged NOW
# postdates it → isMMShieldedFresh holds for the MM's book on this market.
mm placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 49600) : nat, $(e8 0.1) : nat)" >/dev/null
D1=$(depth_buy)
if [ "${D1:-0}" = "$(e8 0.2)" ]; then ok "§6: with the MM's intent in flight only the plain ask counts (0.2 BTC)"
else nok "§6: shielded depth still counted as takeable" "got ${D1:-?} want $(e8 0.2)"; fi
release   # the intent lands → shield lapses
D2=$(depth_buy)
if [ "${D2:-0}" = "$(e8 0.4)" ]; then ok "§6: once the intent lands both asks count again (0.4 BTC)"
else nok "§6: depth after landing" "got ${D2:-?} want $(e8 0.4)"; fi

echo "── §7 uptime: a shielded two-sided book earns no sample ──"
fixture
# A funded two-sided L4 book within ±1% of the mark: bid 0.2 @ 49900 ($9,980),
# ask 0.2 @ 50080 ($10,016) — passes every H-14 rule when unshielded.
mm placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 49900) : nat, $(e8 0.2) : nat)" >/dev/null
release
pol()     { mm getAccessPolicy '()' --query | tr -d '_\n' | tr -s ' '; }
samples() { echo "$1" | grep -oE 'myUptimeSamples = [0-9]+' | grep -oE '[0-9]+$'; }
pct()     { echo "$1" | grep -oE 'myUptimePct = (opt \(|null)[0-9]*' | grep -oE '[0-9]+$|null'; }
# One sample on a pinned 30/25 counter: PASS → 26/31 = 83%, FAIL → 25/31 = 80%.
sample_pct() {
  adm setTestScorecard "(principal \"$MM\", $(e8 50000) : nat, 0 : nat, 30 : nat, 25 : nat)" >/dev/null
  adm devTickTier '()' >/dev/null
  local pl; pl=$(pol); echo "$(samples "$pl") $(pct "$pl")"
}
read -r S0 P0 <<<"$(sample_pct)"
if [ "${S0:-x}" = "31" ] && [ "${P0:-x}" = "83" ]; then ok "§7: baseline — unshielded two-sided book PASSES the sample (26/31 = 83%)"
else nok "§7: baseline sample" "samples=${S0:-?} pct=${P0:-?} (want 31 / 83)"; fi
mm placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 49600) : nat, $(e8 0.1) : nat)" >/dev/null   # commensurate intent in flight
read -r S1 P1 <<<"$(sample_pct)"
if [ "${S1:-x}" = "31" ] && [ "${P1:-x}" = "80" ]; then ok "§7: shielded book FAILS the sample (25/31 = 80%) — no uptime for a phantom book"
else nok "§7: shielded book still sampled as uptime" "samples=${S1:-?} pct=${P1:-?} (want 31 / 80)"; fi
release   # the intent lands
read -r S2 P2 <<<"$(sample_pct)"
if [ "${S2:-x}" = "31" ] && [ "${P2:-x}" = "83" ]; then ok "§7: once the intent lands the book PASSES again (83%)"
else nok "§7: sample after landing" "samples=${S2:-?} pct=${P2:-?} (want 31 / 83)"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
