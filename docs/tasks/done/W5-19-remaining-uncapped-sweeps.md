# W5-19 — The remaining uncapped sweeps and full scans

**Issue:** [#19](https://github.com/dfinity/public-multidex/issues/19) — andreij6
(re-derived independently from the 1.60 triage §4.3)
**Status:** F6 prune **FIXED**; the walks themselves **LIVE** at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` LOW–MEDIUM
**Effort:** M (cluster)

## Framing

None of these is a correctness defect and **none traps today** — the reporter says so themselves.
The value of #19 is the *correction*: the 1.60 triage recorded "every other sweep is bounded", and a
sweep listed as already-bounded never gets re-measured. These are scalability and cycle-burn items
with a future-trap ceiling.

**Already fixed — do not redo:** F6's prune. `OrderBook.mo:277-278`'s `removeFromOpenIndexes` now
deletes the emptied `openOrdersByUser` key, with a comment citing the two consumers. Pre-fix dead
keys persist until `adminRebuildIndexes`, so consider a one-time rebuild on the next upgrade.

## Still live

| # | Where | What | Effort |
|---|---|---|---|
| F5 | `main.mo:1567` `sweepStaleUserOrders` | Full walk of `openOrdersByUser`, **no per-call cap** on either loop. `EVICT_MAX_PER_CALL=5` belongs to `evictOverCap`, a different function — the misattribution #19 called out | S |
| F6/F30 | `main.mo:6334`, `:6368` `tickTier` | Uptime sampler full-walks `openOrdersByUser` unsharded (does not even skip empty id-sets); volume-badge sweep full-walks `lifetimeVol` unsharded. Only the join-badge backfill is sharded — the one row #19 conceded | M |
| F12 | `main.mo:10306` `accountCrossSection` | Full-scans `marginPools` per user; no per-owner pool index. Reached from the heartbeat via `tickLeaderboardShard`; the shard bounds only the user dimension while the pool dimension grows inside | M |
| F10 | `Accounts.mo:66` `getUserBalances` | Full-scans `state.balances` with `Text.startsWith`; no seek-to-prefix | S |
| F40 | `main.mo:1083` `aggregateHostilityBps` | Full-scans `counterpartyStats`, uncached, **per market per AMM tick** (2 s cadence) | S |
| F41 | `main.mo:4712` + guards at `:9781`, `:9965` | `poolPositions` full-scanned on the update path and at query sites; no per-pool index | M |

## Fixes

- **F5** — per-call cursor cap, the same shape as the other bounded sweeps
- **F6/F30** — award volume badges at bump time and reduce the sweep to a sharded, idempotent backfill
- **F12** — add `poolIdsByOwner` at the two `ownerPoolCount` choke points
- **F10** — seek to the `"principal#"` prefix and iterate until the prefix breaks (the map is ordered)
- **F40** — compute once per `tickAmm` and reuse across markets
- **F41** — per-pool secondary index on the `posKey` prefix

## An important ceiling the reporter added later

Per their correction on #19: **the per-message instruction ceiling runs the other way for queries.**
The same growth reaches the *query* call sites first, against a limit roughly **eight times lower**
than the update limit. So `getUserBalances`, `accountCrossSection` and the `getMy*` surfaces hit their
wall before the heartbeat hits its own — which inverts the intuitive priority order. Fix the
query-reachable ones first.

## Done when

- [ ] Each listed walk is bounded, indexed or cached
- [ ] Query-reachable paths are measured against the query instruction ceiling, not the update one
- [ ] A one-time `adminRebuildIndexes` decision is made for pre-fix dead keys
- [ ] Instruction counts recorded so "bounded" is a measurement, not a claim

---
## Done — 2026-08-15

All six walks bounded, indexed or cached — query-reachable ones first, per
the reporter's ceiling inversion (noted in the code comments at each site):

- **F10** getUserBalances: entriesFrom seek to the "principal#" prefix,
  break at the prefix end (keys are contiguous — ordered map).
- **F12** poolIdsByOwner (transient, append-only — pools are never deleted
  or transferred; rebuilt at actor init beside rebuildStagedIndexes):
  accountCrossSection walks the user's own pools only (it sat inside
  tickLeaderboardShard as shard_size × total_pools per tick).
- **F41** posKeys "poolId#marketId" are contiguous ("10#*" sorts before
  "100#*" since '#'<'0') → forPoolPositions prefix walk replaces all four
  full scans: reconcilePoolPositions, both isolated-pool guards, and
  getMyPositions (owner index × prefix walk — a QUERY).
- **F40** hostility: computed once per tick `now`, cached; same-now calls
  (every market in a requote pass) reuse it.
- **F5** sweepStaleUserOrders: Shard.step slice of 500 users/tick with its
  own cursor (EVICT_MAX_PER_CALL never applied here — that misattribution
  was the finding).
- **F6/F30** tickTier: empty id-sets skipped in the uptime sampler (lapsed
  owners still decay via the fail-sample loop); volume badges awarded AT
  BUMP TIME in bumpPartyVolume; the tick's lifetimeVol walk is now a
  sharded idempotent backfill for dev-setter paths only.

**Measured, not claimed** (new controller/dev-gated devSweepCostProbe,
Prim.performanceCounter over the live paths — same pattern as
getStagedIndexAudit's audit counters): userBalances 221k instructions,
owner-index positions walk 8.5k, crossSection 124k, hostility 1.5k cold /
282 warm (cache hit). All orders of magnitude under the query ceiling; the
sharded sweeps are O(slice) by construction with slice sizes in the source.

**adminRebuildIndexes decision:** run once on local after this deploy
("indexes rebuilt; aggregates verify clean") — for engine/subnet, run it
once as part of the next deploy there (pre-fix F6-prune dead keys drain).

Verified: mops test 17/17 files; end-to-end margin smoke on #dev (create
pool → fund → staged open → seeded AMM fill → getMyPositions returns the
position through ownedPoolIds + prefix walk with sane VWAP/PnL);
test_volume_credit PASS (badges now land inline — the sweep-era polls just
exit early); deploy hygiene PASS; candid regenerated (gen-did) and deployed.
