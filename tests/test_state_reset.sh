#!/bin/bash
# Verifies that resetExchange clears EVERY persistent collection.
# Catches the failure mode where someone adds a new top-level state
# field but forgets to add it to resetExchange — which leads to
# orphan data leaking between sessions and "test isolation" being
# silently broken.
#
# Strategy: seed `full` (which exercises every code path that writes
# state — orders, AMM pools, vault LP, oracle aggregates, vault P&L
# history, pending matches via the protection windows on AMM quotes,
# reservedBalances, etc.). Then call resetExchange. Then assert every
# observable is empty / zero.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_state_reset ──"
setup_mode full

# Sanity: full seed populated state. (If this assert fails the test
# is reading a broken seed, not exercising reset.)
PRE_VAULT=$(call getVaultValue '()')
PRE_LP=$(extract_float "lpSupply" "$PRE_VAULT")
assert_gt "seed populated vault" "${PRE_LP:-0}" "0"

# Snapshot some state writes that resetExchange has historically
# missed — these are the regressions we're locking against.
PRE_POOLS=$(call getAmmPools '()' | grep -c "marketId" || true)
PRE_AGG=$(call getLastAggregate '("BTC")' | grep -c "price = " || true)

# Margin-pool registry: create a pool pre-reset so we can assert the registry
# is wiped (2026-07-01 regression: pools survived resets as empty zombies).
# Assert the probe REACHED #ok and keep its id: a discarded reply left the
# "margin pools cleared" check below vacuous whenever the probe was refused
# (H-30 registration gate) or never landed, and the id anchors the H-29
# monotone-id pin at the end.
PRE_POOL=$(call createMarginPool '("reset probe", false)' --identity alice)
assert_ok "pre-reset probe pool created (registry non-empty before the wipe)" "$PRE_POOL"
PRE_POOL_ID=$(extract_first_nat "$PRE_POOL")

# Margin-heat surfaces: make sure the ring holds at least one PRICED column
# before the reset, or the "reset empties the heat ring" section below
# passes vacuously. Seed `full` prices BTC-ICPUSD; the ring only takes a
# column on a heat beat (30s HB_HEAT_NS), so force one via the #dev hook
# and fall back to waiting out a heartbeat on hookless postures.
heat_ring_warm() {
  [ "$(call getMarginHeatmapHistory '("BTC-ICPUSD", 0)' --query | grep -c computedNs)" -ge 1 ]
}
call devTickHeatmaps '()' --identity anonymous > /dev/null 2>&1 || true
wait_for heat_ring_warm 75 5 \
  || _fail "pre-reset: no priced BTC-ICPUSD heat column after 75s (timers dead, or pool unpriced?)"
PRE_HEAT=$(call getMarginHeatmapHistory '("BTC-ICPUSD", 0)' --query | grep -c computedNs)
assert_gt "seed populated the heat ring" "${PRE_HEAT:-0}" "0"
PRE_RISK=$(call getMarginRiskSummary '()' --query)
PRE_RISK_VV=$(extract_nat vaultValueUsd "$PRE_RISK")
assert_gt "seed populated the risk summary (vaultValueUsd > 0)" "${PRE_RISK_VV:-0}" "0"

# Reset.
call resetExchange '()' --identity alice > /dev/null

# ── Every collection must read empty / zero ──────────────────────

# Pools
POOLS=$(call getAmmPools '()')
assert_contains "pools cleared" "$POOLS" "vec {}"

# Vault
VAULT=$(call getVaultValue '()')
LP=$(extract_float "lpSupply" "$VAULT")
TQV=$(extract_float "totalQuoteValue" "$VAULT")
assert_float_close "vaultLPSupply == 0" "0" "${LP:-0}" 0.0001
assert_float_close "totalQuoteValue == 0" "0" "${TQV:-0}" 0.0001

# Oracle aggregates
AGG=$(call getLastAggregate '("BTC")')
assert_contains "BTC aggregate cleared" "$AGG" "(null)"

# Pool value history (legacy ring buffer, vestigial but should clear).
HIST=$(call getPoolValueHistory '("BTC-ICPUSD")')
assert_contains "pool history cleared" "$HIST" "vec {}"

# ── reset empties the heat ring (task 1788490347) ────────────────
# The margin-heat surfaces are derived from the pools/positions the wipe
# just removed, but historically none of them cleared with the world: the
# STABLE heatHistory ring kept up to 4h of pre-wipe columns (the next tick
# computes a mark-0 snapshot and appends nothing, so the ring never turned
# over), the transient snapshot cache kept the last priced column, and the
# risk summary kept the pre-wipe vault value for up to one 30s beat. All
# three must read post-wipe IMMEDIATELY. The ring is the race-free assert;
# the snapshot and summary tolerate a heartbeat landing between the reset
# and the query (a tick against a wiped venue caches a mark-0 snapshot and
# a zero-vault summary — the post-wipe world, never the pre-wipe one).
# Count columns, never substring-match "vec {}": a column with no positions
# prints `buckets = vec {}`, which would pass a contains-check vacuously.
HEAT_HIST_N=$(call getMarginHeatmapHistory '("BTC-ICPUSD", 0)' --query | grep -c computedNs || true)
assert_eq "heat ring cleared by reset (no pre-wipe columns)" "0" "${HEAT_HIST_N:-0}"
HEAT_SNAP=$(call getMarginHeatmap '("BTC-ICPUSD")' --query)
HEAT_MARK=$(extract_nat markPrice "$HEAT_SNAP")
assert_eq "heat snapshot cleared by reset (null, or mark-0 from a post-wipe tick)" "0" "${HEAT_MARK:-0}"
POST_RISK=$(call getMarginRiskSummary '()' --query)
assert_eq "risk summary reset (vaultValueUsd == 0)" "0" "$(extract_nat vaultValueUsd "$POST_RISK")"
assert_eq "risk summary reset (positions == 0)"     "0" "$(extract_nat positions "$POST_RISK")"

# Vault history: the AMM's 2s tick may have already inserted ONE
# fresh snapshot between resetExchange and our query. So we don't
# assert empty — instead we assert that any entries present reflect
# the post-reset world (lpSupply = 0). If the ring buffer were truly
# carrying pre-reset data, lpSupply on those entries would be non-
# zero from the prior session.
VHIST=$(call getVaultValueHistory '()')
NONZERO=$(echo "$VHIST" | grep -c "lpSupply = [^0]" || true)
assert_eq "no vault-history entries with non-zero lpSupply (i.e. no pre-reset leak)" "0" "$NONZERO"

# Per-user LP balances
ALICE_LP=$(call getMyVaultLp '()' --identity alice | grep -oE "[0-9.eE+-]+" | head -1)
assert_float_close "alice LP cleared" "0" "${ALICE_LP:-0}" 0.0001

# Reserved balances cleared (for the AMM principal — full mode would
# have created some via protected-quote pending matches).
AMM_PRI=$(call getAmmPrincipal '()' | grep -oE 'principal "[^"]+"' | head -1 | sed 's/principal "//; s/"//')
# The fossil pendingMatches map was swept by the sixth one-shot migration
# (task 1788744109); getStagedIndexAudit (controller — alice) keeps pmLive in
# the Candid as a constant 0 (getMyPendingMatches, the public reader, was
# removed at apiVersion 6.0.0).
PEND=$(call getStagedIndexAudit '()' --query --identity alice | tr -d '_' | grep -oE 'pmLive = [0-9]+' | grep -oE '[0-9]+$' | head -1)
assert_eq "no pending matches after reset (pmLive)" "0" "${PEND:-?}"

# Order book on every market is empty.
for m in BTC-ICPUSD ETH-ICPUSD SOL-ICPUSD ICP-ICPUSD; do
  BOOK=$(call getOrderBook "(\"$m\")")
  ASKS=$(echo "$BOOK" | awk '/asks = vec {/,/}/' | grep -c "price =" || true)
  BIDS=$(echo "$BOOK" | awk '/bids = vec {/,/}/' | grep -c "price =" || true)
  assert_eq "$m asks cleared" "0" "$ASKS"
  assert_eq "$m bids cleared" "0" "$BIDS"
done

# AMM principal balances zeroed (the recently-added behavior).
# getTestBalance is scoped to self-or-controller — read as anonymous (the
# local controller) or a leaked balance would still read 0 and pass vacuously.
for t in BTC ETH SOL ICP ICPUSD; do
  BAL=$(call getTestBalance "(principal \"$AMM_PRI\", \"$t\")" --identity anonymous \
        | tr -d '_' | grep -oE "[0-9.eE+-]+" | head -1)
  assert_float_close "AMM principal $t balance zeroed" "0" "${BAL:-0}" 0.0001
done

# Treasury zeroed: resetExchange must clear BOTH the treasury balance and the
# lifetimeTreasuryFees counter (added with the maker/taker fee scheme — exactly
# the "new state field, stale reset" regression this test exists to catch).
TRE=$(call getTreasury '()')
assert_eq "treasury balance zeroed by reset"        "0" "$(extract_nat balanceUsd "$TRE")"
assert_eq "treasury lifetime fees zeroed by reset"  "0" "$(extract_nat lifetimeFeesUsd "$TRE")"

# Margin-pool registry wiped: the pre-reset probe pool must be gone. Pool IDS
# do NOT restart: H-29 (F45, task 1788467626) deliberately keeps nextPoolId
# across BOTH wipe arms — poolPrincipal is a pure function of the id and every
# archive segment indexes ledger rows by that principal forever, so a recycled
# id would hand a new owner the prior season's rows (hygiene §6ac pins that
# the wipe lacks the counter reset; test_season_pool_principals pins the
# resetSeason arm — this is the resetExchange arm). The pre-H-29 pin here,
# `assert_contains … "ok = 1"`, kept passing after the fix only on venues
# whose next id happened to START with a 1 (`ok = 12047` contains `ok = 1`
# once underscores are stripped) and went red on every other (seat-2 saw
# `ok = 6062`) — a substring pin on a number is never a pin. The caller stays
# registered across the wipe (registeredUsers and wallets are KEPT by design;
# the registry, positions and pool balances go), so the post-reset create
# must reach #ok as the same identity, not merely "contain ok".
MP=$(call getMyMarginPools '()' --identity alice)
assert_contains "margin pools cleared by reset" "$MP" "vec {}"
NEWPOOL=$(call createMarginPool '("post-reset probe", false)' --identity alice)
assert_ok "post-reset createMarginPool reaches #ok (alice stays registered across the wipe)" "$NEWPOOL"
NEW_POOL_ID=$(extract_first_nat "$NEWPOOL")
assert_gt "pool ids are monotone across resetExchange (H-29: never recycled, never restart at 1)" "${NEW_POOL_ID:-0}" "${PRE_POOL_ID:-0}"

finish_test "test_state_reset"
