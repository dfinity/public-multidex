#!/bin/bash
# Regression pins for the August 2026 community audit fixes (docs/issue-triage-2026-08.md).
#
# Each block below FAILED before its fix. They are grouped by the finding they
# hold in place, with the issue reference, so a future reader can tell what the
# assertion is defending rather than guessing from the mechanics.
#
# ⚠️ Calls resetExchange.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }

A=$(mkid audit_a)
B=$(mkid audit_b)
asA() { icp canister call --identity audit_a backend "$@" 2>&1; }
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "\-?[0-9]+"; }

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true

MODE=$(adm getDeployMode "()" | grep -oE '"[a-z]+"' | tr -d '"')
echo "  (posture: ${MODE:-unknown})"

echo "── OhShii #10.6a / #10.6b — dev-only hooks must not be live on #play ──"
if [ "${MODE:-}" = "dev" ]; then
  echo "  (skipped: these assert the #play refusal; this build is #dev, where the hooks are meant to work)"
else
# setTestEmailBinding was gated on IS_PRODUCTION, so it ran on #play, where
# bindVerifiedEmail accepts any string with no Google round-trip — it minted
# anti-Sybil identities, and because binding is first-come with NO rebind method
# anywhere in main.mo, aiming it at a victim permanently blocked their real
# verification.
OUT=$(adm setTestEmailBinding "(principal \"$B\", \"victim@example.com\")")
if echo "$OUT" | grep -qi "dev-only hook"; then ok "setTestEmailBinding traps on #play"
else nok "setTestEmailBinding traps on #play" "got: $(echo "$OUT" | head -1)"; fi

# injectHistoricalTrades had no posture gate at all; the audit's first fix made
# it #dev-only, which broke the #play chart backdrop. Since 2026-08-06 it is
# GENESIS-gated on #play (docs/deployment-modes.md, "The genesis window"):
# accepted until the install's first enableAmm, #err after, one-way — and the
# resetExchange at the top of this file makes the closed-branch assertion
# meaningful: pools were JUST wiped, so only the latch can be refusing.
# The empty batch injects nothing either way, so both probes are side-effect-free.
OUT=$(adm injectHistoricalTrades "(\"BTC-ICPUSD\", vec {})")
EVER=$(adm getAmmEverEnabled "()")
if echo "$EVER" | grep -q "false"; then
  # Virgin install: window open — the empty batch is ACCEPTED (ok = 0)…
  if echo "$OUT" | grep -qE "ok = 0"; then ok "injectHistoricalTrades open pre-genesis on #play (never-enabled install)"
  else nok "injectHistoricalTrades open pre-genesis on #play" "got: $(echo "$OUT" | head -1)"; fi
  # …then pin the one-way transition: first enableAmm closes it for good.
  adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
  adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1 || true
  OUT=$(adm injectHistoricalTrades "(\"BTC-ICPUSD\", vec {})")
  if echo "$OUT" | grep -qi "genesis window closed"; then ok "genesis window closes at the first enableAmm"
  else nok "genesis window closes at the first enableAmm" "got: $(echo "$OUT" | head -1)"; fi
else
  # Live venue: the latch survived the resetExchange above (pools are gone,
  # the refusal can only come from the latch) — season resets do not re-arm.
  if echo "$OUT" | grep -qi "genesis window closed"; then ok "injectHistoricalTrades refuses post-genesis on #play (latch survives resetExchange)"
  else nok "injectHistoricalTrades refuses post-genesis on #play" "got: $(echo "$OUT" | head -1)"; fi
fi
fi

echo "── OhShii #7.3 — createAmmPool must not silently zero a live leg ──"
# createAmmPool putPool'd an emptyPool unconditionally, and emptyPool has
# refPrice = 0 — so one call against a market already holding capital zeroed
# that leg's NAV contribution while vaultPricesStale skipped it (it tested
# balance*price, which is 0 for an unpriced leg, so the guard saw "not held").
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
# Mark the pool with a distinctive, non-default config. AMM.emptyPool would
# reset these to defaults, so their survival is what proves the pool object was
# not replaced. (refPrice would be the more natural marker, but setAmmRefPrice is
# correctly #dev-gated, so a #play test cannot set one.)
adm setAmmConfig "(\"BTC-ICPUSD\", 77:nat, $(e8 1.0) : nat, 9:nat, 33:nat, 0:nat)" >/dev/null 2>&1 || true
SPREAD_BEFORE=$(fld spreadBps "$(adm getAmmPool '("BTC-ICPUSD")')")
OUT=$(adm createAmmPool '("BTC-ICPUSD")')
if echo "$OUT" | grep -qi "already exists"; then ok "createAmmPool refuses to overwrite a live pool"
else nok "createAmmPool refuses to overwrite a live pool" "got: $(echo "$OUT" | head -1)"; fi
SPREAD_AFTER=$(fld spreadBps "$(adm getAmmPool '("BTC-ICPUSD")')")
if [ -n "${SPREAD_BEFORE:-}" ] && [ "${SPREAD_BEFORE:-}" = "${SPREAD_AFTER:-}" ]; then
  ok "the live pool object survived intact (spreadBps=$SPREAD_AFTER)"
else nok "the live pool object survived intact" "spreadBps went ${SPREAD_BEFORE:-?} → ${SPREAD_AFTER:-?} — the pool was clobbered"; fi

echo "── OhShii #5.3 — createMarginPool name is bounded ──"
# `name` was stored raw with no length check: 64 pools/identity x unlimited
# identities x a multi-KB name reached the memory wall from a different door
# than setUserPreferences, with no funding or registration required.
LONG=$(head -c 200 < /dev/zero | tr '\0' 'x')
OUT=$(asA createMarginPool "(\"$LONG\", false)")
if echo "$OUT" | grep -qi "too long"; then ok "createMarginPool rejects an over-long name"
else nok "createMarginPool rejects an over-long name" "got: $(echo "$OUT" | head -1)"; fi
OUT=$(asA createMarginPool '("normal pool", false)')
if echo "$OUT" | grep -q "ok"; then ok "a normal pool name is still accepted"
else nok "a normal pool name is still accepted" "got: $(echo "$OUT" | head -1)"; fi

echo "── OhShii #5.1 — setUserPreferences validates before it persists ──"
# requireAuth rejects only the anonymous principal; this was the one write
# endpoint reachable BEFORE any anti-Sybil control, storing an unbounded blob
# per free identity with no eviction and no purge path.
# #52.3: positive control FIRST — the two rejections below are negatives, and
# a broken write path (nothing persists, hook renamed, auth refusing) would
# green them both vacuously. Prove an in-bounds write persists, then re-assert
# it after each rejection: a rejected write must neither persist nor clobber
# the last good preferences. (Bounds: ≤8 markets of ≤32 chars.)
PCTL="pctl-$$"
asA setUserPreferences "(record { recentMarkets = vec { \"$PCTL\" }; lastMarket = null })" >/dev/null 2>&1
OUT=$(asA getUserPreferences "()")
if echo "$OUT" | grep -q "$PCTL"; then ok "positive control: in-bounds preferences persist"
else nok "positive control: in-bounds preferences persist" "got: $(echo "$OUT" | head -1)"; fi
BIG=$(head -c 100 < /dev/zero | tr '\0' 'y')
asA setUserPreferences "(record { recentMarkets = vec { \"$BIG\" }; lastMarket = null })" >/dev/null 2>&1
OUT=$(asA getUserPreferences "()")
if echo "$OUT" | grep -q "$BIG"; then nok "over-long market string is rejected" "the blob persisted"
else ok "over-long market string is rejected"; fi
if echo "$OUT" | grep -q "$PCTL"; then ok "rejection preserved the last good preferences"
else nok "rejection preserved the last good preferences" "positive-control value gone: $(echo "$OUT" | head -1)"; fi
MANY='"a";"b";"c";"d";"e";"f";"g";"h";"i";"j";"k";"l"'
asA setUserPreferences "(record { recentMarkets = vec { $MANY }; lastMarket = null })" >/dev/null 2>&1
OUT=$(asA getUserPreferences "()")
if echo "$OUT" | grep -q '"l"'; then nok "over-long recentMarkets array is rejected" "the array persisted"
else ok "over-long recentMarkets array is rejected"; fi
if echo "$OUT" | grep -q "$PCTL"; then ok "rejection preserved the last good preferences (again)"
else nok "rejection preserved the last good preferences (again)" "positive-control value gone: $(echo "$OUT" | head -1)"; fi

echo "── Menese #12.1 — the liquidation sweep is observable ──"
# runLiquidationBatch was the only uncapped sweep on a fund-safety path. The
# trap was silent because _lastLiqNs was stamped in the heartbeat BEFORE the
# dispatch, so the schedule stamp committed even when the work rolled back.
# The stamp now lands on completion, and dispatch/completion counters make a
# failing sweep visible instead of invisible.
OUT=$(adm getLiquidationSweepHealth "()")
if echo "$OUT" | grep -q "completions"; then ok "getLiquidationSweepHealth is exposed"
else nok "getLiquidationSweepHealth is exposed" "got: $(echo "$OUT" | head -1)"; fi
PENDING=$(fld pending "$OUT")
# #52.7: an ABSENT field must fail, not default to 0 — a renamed/removed
# `pending` would otherwise green this forever (same -n discipline as the
# spreadBps and round-trip-balance pins in this file).
if [ -n "${PENDING:-}" ] && [ "$PENDING" -le 1 ]; then ok "no persistent dispatch/completion gap (pending=$PENDING)"
elif [ -z "${PENDING:-}" ]; then nok "no persistent dispatch/completion gap" "pending field absent from getLiquidationSweepHealth — cannot observe the gap"
else nok "no persistent dispatch/completion gap" "pending=$PENDING — the batch is failing"; fi

# ...and the sweep is PACED, not merely observed. Counters alone left the
# failure visible but unbounded: with _lastLiqNs stamped only on completion, a
# trapping batch froze the stamp, so the dispatch predicate stayed true and
# re-fired every heartbeat instead of every 30s — an unthrottled retry of a
# message guaranteed to trap, billing for the instructions it burned each time.
# The streak paces retries geometrically and clears itself on the first
# completed pass.
if echo "$OUT" | grep -q "failStreak"; then ok "failure streak is exposed"
else nok "failure streak is exposed" "got: $(echo "$OUT" | head -1)"; fi
STREAK=$(fld failStreak "$OUT")
if [ "${STREAK:-0}" -eq 0 ]; then ok "healthy sweep carries no failure streak (failStreak=0)"
else nok "healthy sweep carries no failure streak" "failStreak=$STREAK — passes are failing"; fi
# A healthy engine must sit at the base cadence: any backoff on a working sweep
# would silently slow liquidations.
BACKOFF=$(fld backoffNs "$OUT")
if [ "${BACKOFF:-0}" -eq 30000000000 ]; then ok "healthy sweep runs at the 30s base cadence"
else nok "healthy sweep runs at the 30s base cadence" "backoffNs=$BACKOFF (expected 30000000000)"; fi
# The operator reset is reachable and is a pure pacing reset — it must not
# disturb the completion stamp that the health signal is built on.
BEFORE_COMPLETED=$(fld lastCompletedNs "$OUT")
adm adminResetLiquidationBreaker "()" >/dev/null 2>&1
OUT2=$(adm getLiquidationSweepHealth "()")
if [ "$(fld failStreak "$OUT2")" = "0" ] && [ "$(fld lastCompletedNs "$OUT2")" = "$BEFORE_COMPLETED" ]; then
  ok "adminResetLiquidationBreaker clears pacing without touching the health stamp"
else
  nok "adminResetLiquidationBreaker clears pacing without touching the health stamp" \
      "streak=$(fld failStreak "$OUT2") lastCompleted=$(fld lastCompletedNs "$OUT2") (was $BEFORE_COMPLETED)"
fi

echo "── Menese #3.1 + OhShii #7.2 — the insurance round trip is not profitable ──"
# stakeInsurance minted WITH a virtual offset while unstakeInsurance redeemed at
# the RAW ratio, so redeem(mint(A)) > A whenever share value exceeded 1.0 — the
# normal state, since penalties accrue without minting. Measured at +104,165
# base units on a $10k stake at share value 1.0333. The mint denominator also
# omitted insuranceOwedUsd, a receivable already earned by existing stakers.
adm setTestBalance "(principal \"$A\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null 2>&1
adm seedInsuranceFund "($(e8 30000.0) : nat)" >/dev/null 2>&1 || true
# getTestBalance is controller-scoped, so it reads cleanly from `adm` without
# depending on the caller-facing inspect gate.
bal() { adm getTestBalance "(principal \"$A\", \"ICPUSD\")" | tr -d '_' | grep -oE "[0-9]+" | head -1; }
BEFORE=$(bal)
STAKE=$(e8 10000.0)
OUT=$(asA stakeInsurance "($STAKE : nat)")
SHARES=$(echo "$OUT" | tr -d '_' | grep -oE "ok = [0-9]+" | grep -oE "[0-9]+")
if [ -n "${SHARES:-}" ]; then
  # #51.3: the redeem leg must REPORT success before the balance comparison
  # means anything — a refused unstake leaves AFTER = BEFORE − STAKE, which
  # trivially satisfies AFTER ≤ BEFORE and greened the round-trip pin with
  # the round trip never completed.
  UOUT=$(asA unstakeInsurance "($SHARES : nat)")
  if echo "$UOUT" | grep -q "ok ="; then ok "unstakeInsurance redeemed the staked shares"
  else nok "unstakeInsurance redeemed the staked shares" "got: $(echo "$UOUT" | head -1)"; fi
  AFTER=$(bal)
  if [ -n "${BEFORE:-}" ] && [ -n "${AFTER:-}" ]; then
    if [ "$AFTER" -le "$BEFORE" ]; then
      ok "stake→unstake round trip does not mint value (before=$BEFORE after=$AFTER)"
    else
      nok "stake→unstake round trip does not mint value" "gained $((AFTER-BEFORE)) base units from nothing"
    fi
  else nok "round-trip balances readable" "before=${BEFORE:-?} after=${AFTER:-?}"; fi
else
  # #51.3: this used to be a silent skip, so a stakeInsurance that stopped
  # minting (renamed, refused, or broken) greened the whole finding forever.
  nok "stake→unstake round trip does not mint value" "stakeInsurance did not mint — $(echo "$OUT" | head -1)"
fi

echo
echo "──────────────────────────────────────────"
echo -e "  ${GREEN}$pass passed${NC}, $([ $fail -gt 0 ] && echo -e "${RED}$fail failed${NC}" || echo "0 failed")"
[ $fail -eq 0 ] || exit 1
