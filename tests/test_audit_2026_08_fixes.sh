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
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }

mdx_identity_new audit_a; A=$(principal_of audit_a)
mdx_identity_new audit_b; B=$(principal_of audit_b)
asA() { icp canister call --candid "$MDX_CANDID" --identity audit_a backend "$@" 2>&1; }
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
adm setAmmConfig "(\"BTC-ICPUSD\", 77:nat, $(e8 1.0) : nat, 9:nat, 33:nat)" >/dev/null 2>&1 || true
# Both spreadBps reads go through a bounded retry that keeps the RAW reply:
# right after a seed a single getAmmPool query can come back empty (or as an
# `Error` line) once — task 1788525518 saw this pin red "77 → ?" on a pool that
# was never touched, because fld on such a reply yields "" and the equality
# below rendered that as a clobber. A read that fails three times is reported
# AS a read failure, with the reply, never as "the pool was clobbered".
# (perl select = a sub-second pause; macOS has no timeout(1).)
POOL_RAW=""; POOL_SPREAD=""
pool_spread() {  # pool_spread <market> → POOL_SPREAD = spreadBps ("" if unreadable after 3 tries, rc 1), POOL_RAW = the last raw reply
  local _try   # called DIRECTLY, never via $(…): a subshell would drop both globals
  POOL_SPREAD=""
  for _try in 1 2 3; do
    POOL_RAW=$(adm getAmmPool "(\"$1\")")
    POOL_SPREAD=$(fld spreadBps "$POOL_RAW")
    if [ -n "$POOL_SPREAD" ]; then return 0; fi
    perl -e 'select(undef,undef,undef,0.5)'
  done
  return 1
}
pool_spread BTC-ICPUSD; SPREAD_BEFORE="$POOL_SPREAD"; BEFORE_RAW="$POOL_RAW"
OUT=$(adm createAmmPool '("BTC-ICPUSD")')
if echo "$OUT" | grep -qi "already exists"; then ok "createAmmPool refuses to overwrite a live pool"
else nok "createAmmPool refuses to overwrite a live pool" "got: $(echo "$OUT" | head -1)"; fi
pool_spread BTC-ICPUSD; SPREAD_AFTER="$POOL_SPREAD"; AFTER_RAW="$POOL_RAW"
if [ -z "${SPREAD_BEFORE:-}" ]; then
  nok "the live pool object survived intact" "getAmmPool read failed BEFORE createAmmPool (3 tries, no spreadBps) — not a clobber verdict; raw: $(echo "${BEFORE_RAW:-<empty reply>}" | head -1)"
elif [ -z "${SPREAD_AFTER:-}" ]; then
  nok "the live pool object survived intact" "getAmmPool read failed AFTER createAmmPool (3 tries, no spreadBps; before=$SPREAD_BEFORE) — not a clobber verdict; raw: $(echo "${AFTER_RAW:-<empty reply>}" | head -1)"
elif [ -n "${SPREAD_BEFORE:-}" ] && [ "${SPREAD_BEFORE:-}" = "${SPREAD_AFTER:-}" ]; then
  ok "the live pool object survived intact (spreadBps=$SPREAD_AFTER)"
else nok "the live pool object survived intact" "spreadBps went ${SPREAD_BEFORE:-?} → ${SPREAD_AFTER:-?} — the pool was clobbered"; fi

echo "── OhShii #5.3 — createMarginPool name is bounded ──"
# `name` was stored raw with no length check: 64 pools/identity x unlimited
# identities x a multi-KB name reached the memory wall from a different door
# than setUserPreferences, with no funding or registration required.
LONG=$(head -c 200 < /dev/zero | tr '\0' 'x')
# H-30: createMarginPool sits behind requireRegistered, and inspect admits an
# unregistered principal to the pre-registration set only — a virgin audit_a
# would be refused at the GATE and the name bound would never be exercised
# (both pins came back `canister_inspect_message explicitly refused`). Register
# A first so the body's "too long" bound, not inspect, is what refuses; the
# zero balance keeps "no funding" true. setTestBalance registers (AdminOps) on
# every non-production posture — the #dev faucet would trap on #play.
adm setTestBalance "(principal \"$A\", \"ICPUSD\", 0 : nat)" >/dev/null 2>&1
OUT=$(asA createMarginPool "(\"$LONG\", false)")
if echo "$OUT" | grep -qi "too long"; then ok "createMarginPool rejects an over-long name"
else nok "createMarginPool rejects an over-long name" "got: $(echo "$OUT" | head -1)"; fi
OUT=$(asA createMarginPool '("normal pool", false)')
if mdx_ok "$OUT"; then ok "a normal pool name is still accepted"
else nok "a normal pool name is still accepted" "got: $(echo "$OUT" | head -1)"; fi
# H-19 (F44): the name is the one player-authored free-text field on the OQL
# surface, and a controller's CSV export of it lands in a spreadsheet that
# evaluates a cell starting `=`, `+`, `-` or `@` as a formula. createMarginPool
# refuses those leading characters and any control character (tab, CR, LF, …)
# anywhere in the name — MarginPools.nameRefusal, after the length bound.
# Unit shapes: tests/MarginPools.test.mo; the CSV-side belt: frontend_security §K.
for BAD in '=HYPERLINK(\"http://evil\",\"click\")' '+1' '-swing' '@SUM(A1)'; do
  OUT=$(asA createMarginPool "(\"$BAD\", false)")
  if echo "$OUT" | grep -q "cannot start with"; then ok "H-19: createMarginPool refuses a name starting '${BAD:0:1}'"
  else nok "H-19: createMarginPool refuses a name starting '${BAD:0:1}'" "got: $(echo "$OUT" | head -1)"; fi
done
# a control character inside the name (candid text escape \t / \n)
for BAD in 'tab\tname' 'nl\nname' '\t=1+1'; do
  OUT=$(asA createMarginPool "(\"$BAD\", false)")
  if echo "$OUT" | grep -q "control characters"; then ok "H-19: createMarginPool refuses a name carrying '$BAD'"
  else nok "H-19: createMarginPool refuses a name carrying '$BAD'" "got: $(echo "$OUT" | head -1)"; fi
done
# adjacent: only the LEADING position is a formula trigger — an internal '='
# or '-' is benign (BTC-swing, a=b), as is a name that merely CONTAINS the
# four characters after its first one; non-ASCII letters stay allowed.
for GOOD in 'BTC-swing' 'a=b' 'x+y@z' 'Écurie 池'; do
  OUT=$(asA createMarginPool "(\"$GOOD\", false)")
  if mdx_ok "$OUT"; then ok "H-19: a benign name '$GOOD' is still accepted"
  else nok "H-19: a benign name '$GOOD' is still accepted" "got: $(echo "$OUT" | head -1)"; fi
done

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
  # H-35: the fresh stake is locked for 10 min — cross the cooldown with the
  # #dev re-stamp hook so this stays a redeem-expression pin, not a lock pin.
  adm setTestInsuranceStakedAt "(principal \"$A\", 1 : int)" >/dev/null 2>&1 || true
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

echo "── H-17 (F29-backend) — a repeat seedInsuranceFund on a LIVE #play install is refused ──"
# seedInsuranceFund is an UNBACKED mint (no caller debit). #55 made a repeat
# on a pool that already holds value a silent skip (answers the existing
# value) — which deploy.sh's nat gate reads as "seeded", so a re-run of the
# genesis seed on a live venue (H-02's probe failing open) LOOKED like a
# success. H-17 binds the repeat to the same genesis window as
# injectHistoricalTrades: on #play, once a market has been enabled on this
# install (_ammEverEnabled — the latch above; it survived the resetExchange
# at the top of this file, and this file's own enableAmm closes it on a
# virgin install), a seed into a pool that already holds value is REFUSED
# loudly. The signature is a bare Nat, so the refusal is a trap carrying
# "genesis window closed" (THE RULE at requireDevHook: refuse in whichever
# way the signature allows). An EMPTY pool may still be (re)filled — the
# canonical bring-up seeds insurance AFTER the first enableAmm and every
# season reset zeroes the pool — so the seed a few lines up (a wiped pool)
# minted on #play too, and the repeat here is the pinned refusal. On #dev the
# #55 skip stays (the suites re-seed across wipes; test_insurance_fund.sh
# pins that branch), so the property asserted in BOTH postures is the one
# that matters: buffer and share supply are exactly what one seed left.
INS_H17=$(adm getInsuranceFund '()')
BUF_H17=$(fld bufferUsd "$INS_H17"); SH_H17=$(fld totalShares "$INS_H17")
EVER_H17=$(adm getAmmEverEnabled "()")
OUT=$(adm seedInsuranceFund "($(e8 30000.0) : nat)")
INS_H17B=$(adm getInsuranceFund '()')
BUF_H17B=$(fld bufferUsd "$INS_H17B"); SH_H17B=$(fld totalShares "$INS_H17B")
if [ -z "${BUF_H17:-}" ] || [ "${BUF_H17:-0}" -eq 0 ]; then
  nok "H-17 fixture: the insurance pool holds value before the repeat seed" "bufferUsd=${BUF_H17:-?} (the \$30k seed above did not land — $(echo "$INS_H17" | head -1))"
elif [ "${MODE:-}" = "play" ]; then
  if ! echo "$EVER_H17" | grep -q "true"; then
    nok "H-17 fixture: the genesis latch is closed on this #play install" "getAmmEverEnabled = $EVER_H17"
  fi
  if echo "$OUT" | grep -qi "genesis window closed"; then ok "repeat seedInsuranceFund refuses post-genesis on #play (trap names the genesis window)"
  else nok "repeat seedInsuranceFund refuses post-genesis on #play" "got: $(echo "$OUT" | tr -d '\n' | head -c 160)"; fi
  if echo "$OUT" | grep -qi "stakeInsurance"; then ok "the refusal names the BACKED top-up path (stakeInsurance)"
  else nok "the refusal names the BACKED top-up path" "got: $(echo "$OUT" | tr -d '\n' | head -c 160)"; fi
  if echo "$OUT" | tr -d '_' | grep -qE "^\([[:space:]]*[0-9]+[[:space:]]*:[[:space:]]*nat[[:space:]]*\)"; then
    nok "the repeat seed is not a silent success on #play" "answered a bare nat (the #55 skip shape) instead of refusing: $(echo "$OUT" | head -1)"
  else ok "the repeat seed is not a silent success on #play (no bare-nat answer for deploy.sh's gate to misread)"; fi
else
  # #dev: the #55 skip — answers the EXISTING value, same return shape.
  if echo "$OUT" | tr -d '_' | grep -qE "\([[:space:]]*${BUF_H17}[[:space:]]*:[[:space:]]*nat[[:space:]]*\)"; then ok "repeat seedInsuranceFund on #dev keeps the #55 skip (answers the existing \$$((BUF_H17/100000000)) pool value)"
  else nok "repeat seedInsuranceFund on #dev keeps the #55 skip" "got: $(echo "$OUT" | tr -d '\n' | head -c 160) (want ($BUF_H17 : nat))"; fi
fi
if [ "${BUF_H17B:-x}" = "${BUF_H17:-y}" ] && [ "${SH_H17B:-x}" = "${SH_H17:-y}" ]; then ok "the repeat seed minted nothing (buffer $BUF_H17 and shares $SH_H17 unchanged)"
else nok "the repeat seed minted nothing" "buffer $BUF_H17 → ${BUF_H17B:-?}, shares $SH_H17 → ${SH_H17B:-?}"; fi

echo
echo "──────────────────────────────────────────"
echo -e "  ${GREEN}$pass passed${NC}, $([ $fail -gt 0 ] && echo -e "${RED}$fail failed${NC}" || echo "0 failed")"
[ $fail -eq 0 ] || exit 1
