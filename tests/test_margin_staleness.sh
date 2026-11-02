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
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

MKT="BTC-ICPUSD"
STALE_AGE=400          # seconds past the 300s MARGIN_MAX_REFPRICE_AGE_NS window
PRICE=5000000000000    # $50,000 in 10^8 base units (integer money)
CRASH=1500000000000    # $15,000 — deep enough to put the leveraged long underwater

adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
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

AMM=$(adm getAmmPrincipal "()" | grep -oE '"[^"]+"' | tr -d '"')

# Reset AMM/reserved/deferred state and re-seed the BTC market + fund the vault
# (resetExchange zeroes the vault's inventory, so it must be re-funded each time).
# It does NOT clear margin pools/loans, so each part uses its own identity/pool.
seed() {
  adm setTestTimersPaused '(true)' >/dev/null 2>&1
  adm resetExchange "()" >/dev/null 2>&1
  adm createAmmPool "(\"$MKT\")" >/dev/null 2>&1
  adm setAmmConfig "(\"$MKT\", 30:nat, $(e8 1):nat, 8:nat, 25:nat)" >/dev/null
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
  icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyMarginPools "()" 2>&1 \
    | tr -d '_' \
    | awk -v pid="$2" -v f="$3" '
        { gsub(/;/, "") }
        $1 == "id" && $2 == "=" { cur = $3 }
        cur == pid && $1 == f && $2 == "=" { print $3; exit }'
}
pool_liq() { pool_field "$1" "$2" isLiquidatable; }
new_pool() {  # $1 identity → echoes the new pool id, funded with 30k ICPUSD
  local id="$1" pid
  # The id is candid-pretty-printed with digit-group underscores (`ok = 30_115`);
  # strip them BEFORE the digit match or the pool id truncates to `30` and every
  # later openPosition/withdraw/liquidation step reads "Not your pool" against a
  # pool this identity does not own (red 9/10 on any venue past 999 pools —
  # test_h30_unregistered's 6,000-pool seeding runs earlier in run_all).
  pid=$(icp canister call --candid "$MDX_CANDID" --identity "$id" backend createMarginPool '("f1-stale", false)' 2>&1 \
        | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+')
  icp canister call --candid "$MDX_CANDID" --identity "$id" backend fundMarginPool "($pid, $(e8 30000):nat)" >/dev/null 2>&1
  echo "$pid"
}

mdx_identity_new f1_open; U1=$(principal_of f1_open); mdx_identity_new f1_wd; U2=$(principal_of f1_wd); mdx_identity_new f1_liq; U3=$(principal_of f1_liq)
mdx_identity_new f1_basket; mdx_identity_new f1_clamp; mdx_identity_new f1_ask   # H-06 §4 / §5 fixtures
# H-30: createMarginPool requires registration and inspect admits a virgin
# principal to the pre-registration set only. setTestBalance REGISTERS its
# target (AdminOps.mo), so this funding loop is also the fixtures' registration
# step — keep it ahead of every new_pool, and do not replace it with a
# balance-only hook. (resetExchange in seed() does not clear registeredUsers.)
for u in f1_open f1_wd f1_liq f1_basket f1_clamp f1_ask; do
  P=$(icp identity principal --identity "$u" 2>/dev/null | tail -1)
  adm setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 100000):nat)" >/dev/null
done

# ─────────────────────────────────────────────────────────────────────
# 1. openPosition is blocked on a stale mark (and the refPrice==0 edge)
# ─────────────────────────────────────────────────────────────────────
echo ""; echo "── 1. openPosition gated on oracle freshness ──"
seed
PID=$(new_pool f1_open)
open() { icp canister call --candid "$MDX_CANDID" --identity f1_open backend openPosition "($PID, \"$1\", variant { buy }, $(e8 1), 5000000, null)" 2>&1; }

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
# A short borrows the base asset (BTC) from the vault at its FILL (H-34 / D5
# (d): nothing is borrowed at placement) → release it through a fresh stamp +
# requote so the BTC-denominated debt exists. userMarksFresh then keys on BTC.
R=$(icp canister call --candid "$MDX_CANDID" --identity f1_wd backend openPosition "($PID, \"$MKT\", variant { sell }, $(e8 0.1), 5000000, null)" 2>&1)
refresh_mark "$MKT"; adm requoteAmm "(\"$MKT\")" >/dev/null 2>&1
DEBT=$(pool_field f1_wd "$PID" debtUsd)
if echo "$R" | grep -q "variant { ok }" && [ -n "$DEBT" ] && [ "$DEBT" -gt 0 ]; then ok "short opened → pool carries debt (debtUsd=$DEBT)"; else nok "could not establish a pool with debt" "$R / debt=$DEBT"; fi

make_stale "$MKT"
R=$(icp canister call --candid "$MDX_CANDID" --identity f1_wd backend withdrawMarginPool "($PID, $(e8 100):nat)" 2>&1)
if echo "$R" | grep -q "oracle price stale"; then ok "stale mark + debt → withdraw rejected"; else nok "withdraw should reject on stale mark while in debt" "$R"; fi

refresh_mark "$MKT"
R=$(icp canister call --candid "$MDX_CANDID" --identity f1_wd backend withdrawMarginPool "($PID, $(e8 100):nat)" 2>&1)
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
icp canister call --candid "$MDX_CANDID" --identity f1_liq backend openPosition "($PID, \"$MKT\", variant { buy }, $(e8 1), 5000000, null)" >/dev/null 2>&1
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

# ─────────────────────────────────────────────────────────────────────
# 4. H-06 (F23): openPosition needs the WHOLE collateral basket fresh —
#    a stale mark on a token the pool merely OWES (not the traded one)
#    refuses the open until that feed refreshes
# ─────────────────────────────────────────────────────────────────────
# Pre-H-06 openPosition checked marginPriceFresh(baseToken) only, while the
# borrow gate valued every collateral/loan token through the age-blind
# marginPriceLookup: with ETH frozen, a BTC open was sized off a stale ETH
# debt. withdrawMarginPool and the liquidator already used the basket-wide
# userMarksFresh; the open is now held to the same bar, and the refusal
# names the stale token (the trader knows which feed to wait for).
echo ""; echo "── 4. H-06: openPosition refused while ANY basket mark is stale ──"
seed
ETH="ETH-ICPUSD"; ETHP=$(e8 3000)
adm createAmmPool "(\"$ETH\")" >/dev/null 2>&1
adm setAmmConfig "(\"$ETH\", 30:nat, $(e8 10):nat, 8:nat, 25:nat)" >/dev/null
adm setAmmRefPrice "(\"$ETH\", $ETHP:nat)" >/dev/null
adm enableAmm "(\"$ETH\", true)" >/dev/null
adm setTestBalance "(principal \"$AMM\", \"ETH\", $(e8 1000):nat)" >/dev/null
PID=$(new_pool f1_basket)
bopen() {  # $1 market, $2 side, $3 size (whole units)
  icp canister call --candid "$MDX_CANDID" --identity f1_basket backend openPosition "($PID, \"$1\", variant { $2 }, $(e8 "$3"), 5000000, null)" 2>&1
}
# An ETH short borrows ETH from the vault at its FILL (H-34): release it
# through a fresh stamp + requote so the ETH-denominated LOAN exists — the
# pool's basket then touches the ETH mark.
R=$(bopen "$ETH" sell 1)
refresh_mark "$ETH" "$ETHP"; adm requoteAmm "(\"$ETH\")" >/dev/null 2>&1
DEBT=$(pool_field f1_basket "$PID" debtUsd)
if echo "$R" | grep -q "variant { ok }" && [ -n "$DEBT" ] && [ "$DEBT" -gt 0 ]; then ok "§4: ETH short staged → pool owes ETH (debtUsd=$DEBT)"; else nok "§4: could not establish an ETH-denominated debt" "$R / debt=$DEBT"; fi
# Freeze ETH only; BTC (the market being traded) stays fresh. 0.6 BTC at the
# 5 % cap needs ≈ $31.5k of quote on a $30k pool → the open must BORROW.
make_stale "$ETH"
R=$(bopen "$MKT" buy 0.6)
if echo "$R" | grep -q "oracle price stale for ETH"; then ok "§4: stale ETH (owed) + fresh BTC → BTC open REFUSED naming ETH: $(echo "$R" | grep -oE 'stale for [A-Z]+[^—]*' | head -1)"; else nok "§4: a BTC open must refuse while the pool's ETH debt mark is stale (pre-H-06: only the traded token was checked)" "$R"; fi
# Refresh ETH: the same open goes through (the basket was the only blocker).
refresh_mark "$ETH" "$ETHP"
R=$(bopen "$MKT" buy 0.6)
if echo "$R" | grep -q "variant { ok }"; then ok "§4: ETH refreshed → the same BTC open is accepted"; else nok "§4: the open should pass once every basket mark is fresh" "$R"; fi

# ─────────────────────────────────────────────────────────────────────
# 5. H-06 (F23): a staged open whose mark goes stale BEFORE release is
#    clamped #none (killed with a record, pre-borrow repaid), not #full
# ─────────────────────────────────────────────────────────────────────
# clampToInitialMargin returned #full on a null/zero oracle and scored a
# present-but-stale mark as fresh, so a leveraged entry staged on a fresh
# mark filled at release on a frozen one. The release goes through the
# users-only expiry pass (setTestDeferredExpiry + adminRunDeferredExpiry:
# the AMM is sidelined, effLimit = mid ± 2 %) against a resting user ask
# inside that band, with the BTC stamp backdated after staging. Pre-fix the
# ask is lifted and the pool holds a leveraged long on a stale mark;
# post-fix nothing fills, the pool holds no debt (H-34: none was taken at
# placement, none at the refused release) and the release record names the
# stale feed. The de-lever pass-through is H-05's
# (test_initial_margin §F2 releases a CLOSE on a backdated stamp).
echo ""; echo "── 5. H-06: the release clamp fails CLOSED on a stale mark (re-levering fill) ──"
seed
ASKP=$(principal_of f1_ask)
adm setTestBalance "(principal \"$ASKP\", \"BTC\", $(e8 10):nat)" >/dev/null
# A user ask at +1 % (inside the users-only ±2 % band): staged, then released
# by a fresh stamp + requote so it RESTS before the pool's entry is staged.
R=$(icp canister call --candid "$MDX_CANDID" --identity f1_ask backend placeLimitOrder "(\"$MKT\", variant { sell }, $(e8 50500):nat, $(e8 1):nat)" 2>&1)
refresh_mark "$MKT"; adm requoteAmm "(\"$MKT\")" >/dev/null 2>&1
ask_filled() { icp canister call --candid "$MDX_CANDID" --identity f1_ask backend getMyOrders '()' 2>&1 | tr -d '_' | grep -oE 'filled = [0-9]+' | head -1 | grep -oE '[0-9]+'; }
if mdx_ok "$R" && [ "$(ask_filled)" = "0" ]; then ok "§5: a 1 BTC user ask rests at \$50,500 (unfilled)"; else nok "§5: could not rest the user ask" "$(echo "$R" | tr '\n' ' ' | head -c 200) / filled=$(ask_filled)"; fi
PID=$(new_pool f1_clamp)
copen() { icp canister call --candid "$MDX_CANDID" --identity f1_clamp backend openPosition "($PID, \"$MKT\", variant { buy }, $(e8 1), 5000000, null)" 2>&1; }
pool_orders() { icp canister call --candid "$MDX_CANDID" --identity f1_clamp backend getPoolOrders "($PID : nat)" 2>&1 | grep -c "id ="; }
pool_oid()    { icp canister call --candid "$MDX_CANDID" --identity f1_clamp backend getPoolOrders "($PID : nat)" 2>&1 | tr -d '_' | grep -oE "id = [0-9]+" | head -1 | grep -oE "[0-9]+"; }
# 1 BTC at the 5 % cap ($52.5k) on a $30k pool → the fill WOULD borrow ≈
# $22.5k (H-34: the placement only checks it — debt stays 0); the entry is
# STAGED (timers paused: no GEPTOR releases it).
R=$(copen)
DEBT_STAGED=$(pool_field f1_clamp "$PID" debtUsd)
if echo "$R" | grep -q "variant { ok }" && [ "${DEBT_STAGED:-x}" = "0" ] && [ "$(pool_orders)" = "1" ]; then ok "§5: leveraged long staged on a fresh mark (H-34: debtUsd 0 while staged, one pool order pending)"; else nok "§5: could not stage the leveraged entry with zero debt" "$R / debt=$DEBT_STAGED orders=$(pool_orders)"; fi
# The mark goes stale AFTER staging, BEFORE release.
make_stale "$MKT"
OID=$(pool_oid)
adm setTestDeferredExpiry "(${OID:-0} : nat, 1 : int)" >/dev/null 2>&1
adm adminRunDeferredExpiry "()" >/dev/null 2>&1
DEBT_AFTER=$(pool_field f1_clamp "$PID" debtUsd)
AF=$(ask_filled)
if [ "${AF:-x}" = "0" ]; then ok "§5: stale mark at release → NOTHING filled (the ask is untouched)"; else nok "§5: the staged entry filled on a stale mark (pre-H-06: clamp returned #full)" "ask filled=$AF"; fi
if [ "$(pool_orders)" = "0" ]; then ok "§5: the entry was killed at release (no pool order remains)"; else nok "§5: expected the entry killed, not re-staged" "orders=$(pool_orders)"; fi
# H-34: a killed entry leaves exactly the debt it held — none.
if [ "${DEBT_AFTER:-x}" = "0" ]; then ok "§5: no debt after the kill (debtUsd $DEBT_STAGED → $DEBT_AFTER — nothing was ever borrowed)"; else nok "§5: a killed entry must leave no debt" "debt staged=$DEBT_STAGED after=$DEBT_AFTER"; fi
RJ=$(icp canister call --candid "$MDX_CANDID" --identity f1_clamp backend getMyReleaseRejections '()' 2>&1)
if echo "$RJ" | grep -q "oracle price stale for BTC"; then ok "§5: the release record names the stale feed"; else nok "§5: expected a release record naming 'oracle price stale for BTC'" "$(echo "$RJ" | tr '\n' ' ' | head -c 300)"; fi
# Control: the same entry on a FRESH mark releases and fills (the clamp
# passes a margin-safe re-levering fill when it can value it) — through the
# ordinary requote release, against the AMM ladder.
pos_size() { icp canister call --candid "$MDX_CANDID" --identity f1_clamp backend getMyPositions '()' 2>&1 | tr -d '_+' | grep -oE 'size = -?[0-9]+' | head -1 | grep -oE -- '-?[0-9]+'; }
refresh_mark "$MKT"
R=$(copen)
refresh_mark "$MKT"; adm requoteAmm "(\"$MKT\")" >/dev/null 2>&1
PS2=$(pos_size)
if echo "$R" | grep -q "variant { ok }" && [ -n "${PS2:-}" ] && [ "$PS2" -gt 0 ] && [ "$(pool_orders)" = "0" ]; then ok "§5 control: fresh mark → the entry releases and fills (pool long $PS2 base units)"; else nok "§5 control: a fresh-mark entry should fill at release" "$R / size=${PS2:-none} orders=$(pool_orders)"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
