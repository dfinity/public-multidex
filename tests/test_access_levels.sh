#!/bin/bash
# Progressive access & fee levels (docs/progressive-incentives-design.md) —
# the EARNED replacement for operator-granted tiers:
#   • getAccessPolicy publishes the whole schedule: level, fees, scaled bars,
#     scorecard, badges; default level is L0 (rank 0, base 5/10 bps fees)
#   • on a young exchange the bars scale to the 1% floor ($200/$2k/$20k/$100k)
#   • setTestScorecard is controller-only (there is NO production grant)
#   • levels are earned from weighted volume W = 2·maker + taker; L4 also
#     needs sampled quote uptime; each change is event-logged
#   • fees follow the level: an L4 maker pays 0, its taker leg 6 bps
#   • REAL trades attribute maker/taker off the trade record and feed the
#     exchange-wide window volume
#   • badges: lifetime milestones (First Fill, Player); the join badge lands
#     via creditAndRegister or the tick sweep
#   • the per-owner staged cap (32) + cancel-frees-slot stay enforced
# ⚠️ Calls resetExchange.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_access_levels ──"
setup_mode matching   # markets exist; alice/bob funded; no AMM

icp identity new lvlu --storage plaintext 2>/dev/null || true
LU=$(principal_of lvlu)
call setTestBalance "(principal \"$LU\", \"ICPUSD\", $(e8 10000000) : nat)" --identity alice > /dev/null

# (1) default policy view: L0 + the 1%-floored bars of a young exchange
POL=$(call getAccessPolicy '()' --identity lvlu --query)
assert_contains "default level is 0"    "$POL" "myLevel = 0"
assert_contains "default rank 0"        "$POL" "myRank = 0"
assert_contains "L0 maker fee 5.0 bps"  "$POL" "myMakerFeeTenthBps = 50"
assert_contains "L0 taker fee 10.0 bps" "$POL" "myTakerFeeTenthBps = 100"
assert_contains "staged cap published"  "$POL" "stagedCapPerOwner = 32"
assert_contains "shed floor open"       "$POL" "shedFloor = 0"
assert_contains "scale at the 1% floor" "$POL" "scaleBps = 100"
BARS=$(echo "$POL" | tr -d '_\n' | grep -oE "levelThresholdsUsd = vec \{[^}]*\}")
assert_contains "L1 bar scaled to \$200"  "$BARS" "20000000000"
assert_contains "L4 bar scaled to \$100k" "$BARS" "10000000000000"

# (2) the scorecard hook is controller-only — levels cannot be granted
ROGUE=$(call setTestScorecard "(principal \"$LU\", $(e8 50000) : nat, 0 : nat, 0 : nat, 0 : nat)" --identity lvlu)
assert_contains "non-controller setTestScorecard rejected" "$ROGUE" "not a canister controller"

# (3) EARNED level: W = 2×$1.5k + $0.5k = $3.5k ≥ the $2k L2 bar
call setTestScorecard "(principal \"$LU\", $(e8 1500) : nat, $(e8 500) : nat, 0 : nat, 0 : nat)" --identity alice > /dev/null
POL2=$(call getAccessPolicy '()' --identity lvlu --query)
assert_contains "level earned: L2"      "$POL2" "myLevel = 2"
assert_contains "rank now 1"            "$POL2" "myRank = 1"
assert_contains "L2 maker fee 3.5 bps"  "$POL2" "myMakerFeeTenthBps = 35"
assert_contains "weighted volume shown" "$(echo "$POL2" | tr -d '_')" "myWeightedVolUsd = $(e8 3500)"

# (4) L4 needs uptime, not just volume: W = $100k without samples stays L3…
call setTestScorecard "(principal \"$LU\", $(e8 50000) : nat, 0 : nat, 0 : nat, 0 : nat)" --identity alice > /dev/null
POL3=$(call getAccessPolicy '()' --identity lvlu --query)
assert_contains "volume alone caps at L3" "$POL3" "myLevel = 3"
# …and with a qualified uptime scorecard (25/30 ≥ 50% over ≥20) reaches L4.
call setTestScorecard "(principal \"$LU\", $(e8 50000) : nat, 0 : nat, 30 : nat, 25 : nat)" --identity alice > /dev/null
POL4=$(call getAccessPolicy '()' --identity lvlu --query)
assert_contains "uptime unlocks L4"     "$POL4" "myLevel = 4"
assert_contains "rank now 2"            "$POL4" "myRank = 2"
assert_contains "L4 maker fee is ZERO"  "$POL4" "myMakerFeeTenthBps = 0"
assert_contains "L4 taker fee 6.0 bps"  "$POL4" "myTakerFeeTenthBps = 60"

# (5) level changes are event-logged (transparency invariant)
EVT=$(call getRecentEvents '(80 : nat)' --identity alice 2>/dev/null | grep -c "fee level" || true)
assert_gt "level changes appear in the event log" "${EVT:-0}" "0"

# (6) badges from lifetime counters: First Fill (any volume) + Player (≥$10k
# lifetime — the two scorecard injections above sum past it)
# Anchored to the vec's own closing brace (#51.8): the old greedy `.*`
# capture ran to the end of the flattened response, so the thresholds tail
# supplied the "N : nat" needles and an EMPTY badge vec still passed. The
# entries are nested records, so the anchor must be brace-BALANCED — a flat
# [^}]* stops at the first record's brace and truncates the set.
BDG=$(echo "$POL4" | tr -d '\n' | awk '{
  i = index($0, "myBadges = vec {"); if (i == 0) exit
  s = substr($0, i); d = 0
  for (j = 1; j <= length(s); j++) {
    c = substr(s, j, 1)
    if (c == "{") d++
    if (c == "}") { d--; if (d == 0) { print substr(s, 1, j); exit } }
  }
}')
assert_contains "First Fill badge (id 2) earned"       "$BDG" "2 : nat"
assert_contains "MULTI/DEX Player badge (id 3) earned" "$BDG" "3 : nat"

# (6b) the details behind the ids are public API: getBadgeCatalog names every
# badge + its machine-readable criteria; getUserBadges resolves ANY account's
# earned ids to names (recognition is public — the leaderboard shows counts)
CAT=$(call getBadgeCatalog '()' --identity alice --query | tr -d '\n_')
assert_contains "catalog names the join badge"       "$CAT" "DeFi 2.0 User"
assert_contains "catalog names Market Pillar"        "$CAT" "Market Pillar"
assert_contains "catalog carries volume criteria"    "$CAT" "lifetimeVolumeUsd"
assert_contains "catalog: Player bar is \$10k"       "$CAT" "lifetimeVolumeUsd = 1000000000000"
assert_contains "catalog carries the uptime gate"    "$CAT" "minUptimePct = 50"
UBDG=$(call getUserBadges "(principal \"$LU\")" --identity alice --query | tr -d '\n')
assert_contains "getUserBadges: First Fill by name"  "$UBDG" "First Fill"
assert_contains "getUserBadges: Player by name"      "$UBDG" "MULTI/DEX Player"
assert_contains "getUserBadges carries awardedNs"    "$UBDG" "awardedNs"

# (7) REAL trades: maker/taker attribution off the trade record + exchange
# window volume. AMM-seeded market, maker rests, taker crosses on release.
icp identity new lvl_mkr --storage plaintext 2>/dev/null || true
icp identity new lvl_tkr --storage plaintext 2>/dev/null || true
KM=$(principal_of lvl_mkr); KT=$(principal_of lvl_tkr); AL=$(principal_of alice)
call setTestBalance "(principal \"$KM\", \"ICP\", $(e8 10000) : nat)" --identity alice > /dev/null
call setTestBalance "(principal \"$KT\", \"ICPUSD\", $(e8 10000) : nat)" --identity alice > /dev/null
# Vault seeder is ALICE so the I1 invariant (which sums the seed identities'
# LP) still balances after this test leaves a live vault behind.
call setTestBalance "(principal \"$AL\", \"ICP\", $(e8 10000) : nat)" --identity alice > /dev/null
call setTestBalance "(principal \"$AL\", \"ICPUSD\", $(e8 30000) : nat)" --identity alice > /dev/null
call createAmmPool '("ICP-ICPUSD")' --identity alice > /dev/null 2>&1   # matching mode has no AMM pools
call setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 3) : nat)" --identity alice > /dev/null
call seedAmmPool "(\"ICP-ICPUSD\", $(e8 10000) : nat, $(e8 30000) : nat)" --identity alice > /dev/null
call enableAmm '("ICP-ICPUSD", true)' --identity alice > /dev/null
fresh() { call setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 3) : nat)" --identity alice > /dev/null; call requoteAmm '("ICP-ICPUSD")' --identity alice > /dev/null; }
fresh
call placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 3) : nat, $(e8 400) : nat)" --identity lvl_mkr > /dev/null
fresh   # maker's ask releases and rests
call placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 3) : nat, $(e8 400) : nat)" --identity lvl_tkr > /dev/null
fresh   # taker's buy releases and crosses it
sleep 1
MPOL=$(call getAccessPolicy '()' --identity lvl_mkr --query | tr -d '_')
TPOL=$(call getAccessPolicy '()' --identity lvl_tkr --query | tr -d '_')
assert_contains "maker credited MAKER volume (\$1,200)" "$MPOL" "myMakerVolUsd = $(e8 1200)"
assert_contains "maker got no taker volume"             "$MPOL" "myTakerVolUsd = 0"
assert_contains "taker credited TAKER volume (\$1,200)" "$TPOL" "myTakerVolUsd = $(e8 1200)"
EXV=$(echo "$TPOL" | grep -oE "exchangeVolUsd = [0-9]+" | grep -oE "[0-9]+" | head -1)
assert_gt "exchange window volume accrued" "${EXV:-0}" "0"

# (8) staged-order cap: 32 staged orders fine, the 33rd refused.
# Timers PAUSED across §8–§9: on a live-oracle venue the release machinery is
# freshness-driven — a staged order releases the moment a requote lands a
# price that postdates its entry (the GEPTOR re-stamps ~1-2s), so a count
# read moments after a place/cancel can come up one short of what the action
# accounts for (the 31-expected/30-read flake, 2026-08-20). Every release
# path is a timer dispatch: processDeferred fires at the end of a requote
# (tickAmm and the finaliser-dispatched processGeptorDue — its ONLY dispatch
# site), and processDeferredExpiry/processDeferredSwaps (the oracle-stall
# fallback — the likely releaser here, BTC-ICPUSD having no AMM pool in
# matching mode) run directly in finaliseExpiredPending. tickAmm and the
# finaliser both early-return under _timersPaused, and tickPriceRefresh only
# stamps, never requotes — so under the pause a stamp, even one landing from
# an already-in-flight fetch, releases nothing. Between pause and restore the
# staged set therefore moves ONLY by this suite's own place/cancel calls.
# No trap needed for the restore: assertions accumulate (_fail never exits),
# so line-of-control always reaches the resume below, and run_all.sh's
# inter-suite hygiene (2026-08-15) force-unpauses before every suite anyway.
call setTestTimersPaused '(true)' > /dev/null
for i in $(seq 1 32); do
  call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 $((60000 + i))) : nat, $(e8 0.001) : nat)" --identity lvlu > /dev/null
done
POL5=$(call getAccessPolicy '()' --identity lvlu --query)
assert_contains "staged count at the cap" "$POL5" "myStagedCount = 32"
OVER=$(call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 60050) : nat, $(e8 0.001) : nat)" --identity lvlu)
assert_contains "33rd staged order refused" "$OVER" "err"

# (9) cancel frees a slot — counter in lockstep with the queue
OID=$(call getMyStagedOrderIds '()' --identity lvlu | tr -d '_' | grep -oE "[0-9]+" | head -1)
call cancelMyOrder "(${OID:-0} : nat)" --identity lvlu > /dev/null
POL6=$(call getAccessPolicy '()' --identity lvlu --query)
assert_contains "cancel decremented the staged count" "$POL6" "myStagedCount = 31"
AGAIN=$(call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 60051) : nat, $(e8 0.001) : nat)" --identity lvlu)
assert_contains "slot freed — placement accepted again" "$AGAIN" "ok"
call setTestTimersPaused '(false)' > /dev/null   # resume venue dynamics

finish_test "test_access_levels"
