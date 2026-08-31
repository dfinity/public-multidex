#!/bin/bash
# F1 — margin/liquidation oracle-staleness gate (PR #4, security/f1-margin-oracle-staleness).
#
# marginPriceLookup used to hand back a pool's refPrice whenever it was merely
# > 0, with NO age check — so opens, withdrawals, and liquidations could all act
# on a mark the circuit-breaker/feed-degradation had frozen for up to ~5 min.
# The fix adds MARGIN_MAX_REFPRICE_AGE_NS (300s) + marginPriceFresh/userMarksFresh
# and, on a stale mark:
#   1. BLOCKS openPosition                       ("oracle price stale for <TOKEN> …")
#   2. BLOCKS withdrawMarginPool when debtUsd > 0 ("oracle price stale for this pool's collateral …")
#   3. SKIPS an otherwise-liquidatable account in the liquidation batch, and
#      resumes liquidating it once the oracle refreshes.
# Plus the Copilot follow-up: a fresh refPriceUpdatedNs with refPrice == 0 must
# STILL be treated as stale (a fresh timestamp on a zero price is not a mark).
#
# Staleness is simulated deterministically by backdating refPriceUpdatedNs with
# the admin helper setTestRefPriceUpdatedNs — the price VALUE is untouched, only
# its age — so no real oracle outcall or wall-clock sleep is needed. Timers are
# paused so the heartbeat can't refresh the mark or race the liquidation batch.
#
# RUN WITH THE TRADING BOT PAUSED, against a clean local replica:
#     bash scripts/stop_bots_local.sh
#     bash tests/test_margin_staleness.sh
# (calls resetExchange — do NOT run against a seeded/live sim.)

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

MKT="BTC-ICPUSD"
STALE_AGE=400          # seconds past the 300s MARGIN_MAX_REFPRICE_AGE_NS window
PRICE=5000000000000    # $50,000 in 10^8 base units (integer money)
CRASH=1500000000000    # $15,000 — deep enough to put the leveraged long underwater

adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
# e8: whole units → 10^8 base units (balances, sizes; prices are pre-scaled above).
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
# The canister's own clock, read back as a pool's last refPrice stamp.
ref_now() { adm getAmmPool "(\"$1\")" | tr '\n' ' ' | grep -oE "refPriceUpdatedNs = [0-9_]+" | head -1 | grep -oE "[0-9_]+" | tr -d '_'; }
# Age a market's mark past the window WITHOUT touching its price value.
make_stale() { local m="$1" rp; rp=$(ref_now "$m"); adm setTestRefPriceUpdatedNs "(\"$m\", $(( rp - STALE_AGE * 1000000000 )) : int)" >/dev/null; }
# Re-stamp a market's mark to "now" (refreshes the age; keeps whatever price is set).
refresh_mark() { adm setAmmRefPrice "(\"$1\", ${2:-$PRICE}:nat)" >/dev/null; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a <  b ? 0 : 1)}'; }  # a < b ?
ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a >= b ? 0 : 1)}'; }  # a >= b ?

mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
AMM=$(adm getAmmPrincipal "()" | grep -oE '"[^"]+"' | tr -d '"')

# Reset AMM/reserved/deferred state and re-seed the BTC market + fund the vault
# (resetExchange zeroes the vault's inventory, so it must be re-funded each time).
# It does NOT clear margin pools/loans, so each part uses its own identity/pool.
seed() {
  adm setTestTimersPaused '(true)' >/dev/null 2>&1
  adm resetExchange "()" >/dev/null 2>&1
  adm createAmmPool "(\"$MKT\")" >/dev/null 2>&1
  adm setAmmConfig "(\"$MKT\", 30:nat, $(e8 1):nat, 8:nat, 25:nat, 0:nat)" >/dev/null
  adm setAmmRefPrice "(\"$MKT\", $PRICE:nat)" >/dev/null
  adm enableAmm "(\"$MKT\", true)" >/dev/null
  # Vault is the lender (borrows) AND liquidity-of-last-resort (absorbs seized collateral).
  adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 10000000):nat)" >/dev/null
  adm setTestBalance "(principal \"$AMM\", \"BTC\",    $(e8 100):nat)"      >/dev/null
}

# getMyMarginPools returns EVERY pool the caller owns (resetExchange doesn't
# clear margin pools, so re-runs accumulate them). Extract a field from the ONE
# record whose `id` matches — keyed on the pool id, not position — so the test
# is idempotent across repeated runs. `field` is `debtUsd`/`isLiquidatable`/etc.
pool_field() {  # $1 identity, $2 pool-id, $3 field
  icp canister call --identity "$1" backend getMyMarginPools "()" 2>&1 \
    | tr -d '_' \
    | awk -v pid="$2" -v f="$3" '
        { gsub(/;/, "") }
        $1 == "id" && $2 == "=" { cur = $3 }
        cur == pid && $1 == f && $2 == "=" { print $3; exit }'
}
pool_liq() { pool_field "$1" "$2" isLiquidatable; }
new_pool() {  # $1 identity → echoes the new pool id, funded with 30k ICPUSD
  local id="$1" pid
  pid=$(icp canister call --identity "$id" backend createMarginPool '("f1-stale", false)' 2>&1 \
        | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+')
  icp canister call --identity "$id" backend fundMarginPool "($pid, $(e8 30000):nat)" >/dev/null 2>&1
  echo "$pid"
}

U1=$(mkid f1_open); U2=$(mkid f1_wd); U3=$(mkid f1_liq)
for u in f1_open f1_wd f1_liq; do
  P=$(icp identity principal --identity "$u" 2>/dev/null | tail -1)
  adm setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 100000):nat)" >/dev/null
done

# ─────────────────────────────────────────────────────────────────────
# 1. openPosition is blocked on a stale mark (and the refPrice==0 edge)
# ─────────────────────────────────────────────────────────────────────
echo ""; echo "── 1. openPosition gated on oracle freshness ──"
seed
PID=$(new_pool f1_open)
open() { icp canister call --identity f1_open backend openPosition "($PID, \"$1\", variant { buy }, $(e8 1), 5000000, null)" 2>&1; }

make_stale "$MKT"
R=$(open "$MKT")
if echo "$R" | grep -q "oracle price stale"; then ok "stale mark → openPosition rejected: $(echo "$R" | grep -oE 'stale for [A-Z]+')"; else nok "openPosition should reject on stale mark" "$R"; fi

refresh_mark "$MKT"
R=$(open "$MKT")
if echo "$R" | grep -q "variant { ok }"; then ok "fresh mark → openPosition allowed (staleness was the only blocker)"; else nok "openPosition should succeed once the mark is fresh" "$R"; fi

# refPrice == 0 with a FRESH timestamp must still count as stale (Copilot fix):
# a brand-new SOL pool has refPrice 0; stamp it "now" and confirm it's treated
# as stale, NOT as the separate "No price" path (which would mean refPrice>0
# was never required).
adm createAmmPool '("SOL-ICPUSD")' >/dev/null 2>&1
adm setTestRefPriceUpdatedNs "(\"SOL-ICPUSD\", $(ref_now "$MKT") : int)" >/dev/null
R=$(open "SOL-ICPUSD")
if echo "$R" | grep -q "oracle price stale"; then ok "fresh timestamp + refPrice==0 → treated as stale (not a valid mark)"; else nok "refPrice==0 must be stale even with a fresh timestamp" "$R"; fi

# ─────────────────────────────────────────────────────────────────────
# 2. withdrawMarginPool is blocked on a stale mark while the pool has debt
# ─────────────────────────────────────────────────────────────────────
echo ""; echo "── 2. withdrawMarginPool gated when debtUsd > 0 ──"
seed
PID=$(new_pool f1_wd)
# A short borrows the base asset (BTC) from the vault → a BTC-denominated debt
# that exists immediately (no fill needed). userMarksFresh then keys on BTC.
R=$(icp canister call --identity f1_wd backend openPosition "($PID, \"$MKT\", variant { sell }, $(e8 0.1), 5000000, null)" 2>&1)
DEBT=$(pool_field f1_wd "$PID" debtUsd)
if echo "$R" | grep -q "variant { ok }" && [ -n "$DEBT" ] && [ "$DEBT" -gt 0 ]; then ok "short opened → pool carries debt (debtUsd=$DEBT)"; else nok "could not establish a pool with debt" "$R / debt=$DEBT"; fi

make_stale "$MKT"
R=$(icp canister call --identity f1_wd backend withdrawMarginPool "($PID, $(e8 100):nat)" 2>&1)
if echo "$R" | grep -q "oracle price stale"; then ok "stale mark + debt → withdraw rejected"; else nok "withdraw should reject on stale mark while in debt" "$R"; fi

refresh_mark "$MKT"
R=$(icp canister call --identity f1_wd backend withdrawMarginPool "($PID, $(e8 100):nat)" 2>&1)
if echo "$R" | grep -q "variant { ok }"; then ok "fresh mark → withdraw allowed (health permitting)"; else nok "withdraw should succeed once the mark is fresh" "$R"; fi

# ─────────────────────────────────────────────────────────────────────
# 3. Liquidation batch SKIPS a liquidatable account while its mark is stale,
#    and resumes once the mark is refreshed
# ─────────────────────────────────────────────────────────────────────
echo ""; echo "── 3. liquidation batch skips on stale, resumes on refresh ──"
seed
PID=$(new_pool f1_liq)
# Build a real leveraged long: borrow the shortfall, then release the staged buy
# (postdate + requote) so the pool actually holds ~1 BTC of collateral vs its debt.
icp canister call --identity f1_liq backend openPosition "($PID, \"$MKT\", variant { buy }, $(e8 1), 5000000, null)" >/dev/null 2>&1
refresh_mark "$MKT"; adm requoteAmm "(\"$MKT\")" >/dev/null 2>&1
DEBT0=$(pool_field f1_liq "$PID" debtUsd)
if [ -n "$DEBT0" ] && [ "$DEBT0" -gt 0 ]; then ok "leveraged long established (debtUsd=$DEBT0)"; else nok "long did not fill / no debt" "debt=$DEBT0"; fi

# Crash BTC so the position is underwater — but keep the mark FRESH for now.
refresh_mark "$MKT" "$CRASH"
if [ "$(pool_liq f1_liq "$PID")" = "true" ]; then ok "crash → account is liquidatable"; else nok "account should be liquidatable after the crash" "liq=$(pool_liq f1_liq "$PID")"; fi

# Age the (crashed) mark past the window and run the batch: it must SKIP.
make_stale "$MKT"
DEBT_BEFORE=$(pool_field f1_liq "$PID" debtUsd)
for i in 1 2 3; do adm adminRunLiquidationBatch "()" >/dev/null 2>&1; done
DEBT_STALE=$(pool_field f1_liq "$PID" debtUsd)
# Debt is not reduced (it may tick UP a hair from interest accrual) and the
# account is still liquidatable → the batch declined to act on the stale mark.
if ge "$DEBT_STALE" "$(awk -v d="$DEBT_BEFORE" 'BEGIN{printf "%.0f", d*0.999}')" && [ "$(pool_liq f1_liq "$PID")" = "true" ]; then
  ok "stale mark → liquidation SKIPPED (debt $DEBT_BEFORE → $DEBT_STALE, still liquidatable)"
else
  nok "liquidation must not act on a stale mark" "before=$DEBT_BEFORE stale=$DEBT_STALE liq=$(pool_liq f1_liq "$PID")"
fi

# Refresh the mark (same crashed price, fresh timestamp) and run again: it liquidates.
refresh_mark "$MKT" "$CRASH"
for i in 1 2 3; do adm adminRunLiquidationBatch "()" >/dev/null 2>&1; done
DEBT_FRESH=$(pool_field f1_liq "$PID" debtUsd)
if lt "$DEBT_FRESH" "$(awk -v d="$DEBT_STALE" 'BEGIN{printf "%.0f", d*0.5}')"; then
  ok "refreshed mark → liquidation RESUMES (debt $DEBT_STALE → $DEBT_FRESH)"
else
  nok "liquidation should resume once the mark is fresh" "stale=$DEBT_STALE fresh=$DEBT_FRESH"
fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
