# W5-21 — Five `deferredExecs` full scans remain, four of them polled queries

**Issue:** internal red-team round 2, finding R9 — **expanded**: R9 reported one site, there are five
**Status:** VERIFIED LIVE at `d8f4c58` (2026-08-17) — completes
[W1-04](done/W1-04-cancel-all-user-orders-uncapped.md) / [W3-01](done/W3-01-soft-locked-reserved-accumulator.md)
**Severity:** `#play` LOW / `#production` LOW–MEDIUM (cost / DoS amplification)
**Effort:** S

## Framing

W1-04 and W3-01 introduced `deferredIdsByOwner` (`main.mo:1234`, accessor `ownerIdxIds` `:1255`)
precisely to kill "O(global staged), attacker-inflatable" scans (`:1218-1221`). The index was applied
to the liquidation path. **Five reader paths were missed**, four of which are polled queries — and
per W5-19's recorded ceiling inversion, query-reachable paths hit their instruction wall roughly 8×
sooner than update paths, so those come first.

R9's own site is *half*-indexed already — its second half uses the owner-keyed
`OrderBook.getUserOpenOrders` (`:4839`) — which marks it as oversight rather than choice.

## All 12 `Map.entries(deferredExecs)` sites, judged

| line | function | verdict |
|---|---|---|
| 1287 | `softLockedReservedRecomputed` | OK — audit oracle, "never called on a hot path" (`:1286`) |
| 3024 | `processDeferredExpiry` | OK — global expiry sweep, capped at `MAX_EXPIRY_RELEASES_PER_PASS = 256` (`:428`) |
| 3109 | `stagedForMarketSorted` | OK-ish — market-keyed; would need a different index |
| **4836** | **`poolHasLiveOrdersElsewhere`** | **MISS** (reported) — worse caller is `previewOpenPosition`, a polled **query** (`:10631`), not `openPosition` (`:10450`) |
| **9864** | **`cancelAllOrdersFor`** | **MISS** — sibling `cancelAllUserOrders` **does** use the index (`:9039`). Same walk, two ways, same file |
| **10761** | **`getPoolOrders`** | **MISS** — polled query |
| **12822** | **`myOpenOrdersWithStaged`** | **MISS** — backs `getMyOrders`, the hottest polled endpoint |
| **12841** | **`getMyStagedOrderIds`** | **MISS** — polled query |
| 16797 / 16836 / 16852 | `getStagedIndexAudit` | OK — unindexed recompute is its job; controller-gated |
| 16890 | `rebuildStagedIndexes` | OK — init/upgrade, must be exhaustive |

## Correction to the finding

`SHED_HARD_STAGED = 5_000` is **not** a bound on the scan. `recomputeShedFloor` (`:6730`) only sets
`_shedFloor := 2`, which raises the *tier* `inspect` requires (`:8877-8898`); high-tier principals
keep staging above 5,000. The scans are genuinely unbounded above that threshold.

## Fix

The same 3-line substitution at all five sites: `ownerIdxIds(deferredIdsByOwner, p)` then
`Map.get(deferredExecs, id)` per id. `deferredIdsByOwner` stores ids only, so the `marketId` needs
the per-id lookup — but a principal's staged set is capped at `STAGED_CAP_PER_OWNER = 32` (`:801`,
enforced `:2488`), so the indexed form is ≤32 × O(log n) versus today's O(global staged). Same
answer, strictly.

## Done when

- [ ] All five sites use the owner index; the four query-reachable ones done first
- [ ] `cancelAllOrdersFor` and `cancelAllUserOrders` use the same mechanism (they are the same walk)
- [ ] Instruction counts recorded against the **query** ceiling for the four polled paths, per
      W5-19's rule that "bounded" is a measurement and not a claim
- [ ] `getStagedIndexAudit` still passes — it is the oracle that proves the index agrees with the map

---
## Done — 2026-08-17

All five sites read `ownerIdxIds(deferredIdsByOwner, p)` + per-id `Map.get`
(the map stays the source of truth; ≤ `STAGED_CAP_PER_OWNER` = 32 per owner —
pools are not `isInternalPrincipal`, so the cap binds them too), queries
first, comments at each site citing the ceiling inversion:

- **poolHasLiveOrdersElsewhere** (previewOpenPosition's guard — polled query)
- **poolOrdersOf** (getPoolOrders — polled query; core factored out so
  devSweepCostProbe measures the exact walk the public query runs)
- **myOpenOrdersWithStaged** (getMyOrders, the hottest poll) and
  **myStagedOrderIdsOf** (getMyStagedOrderIds) — per-principal index sets
  unioned then sorted ascending, the old scan's visit order, so output is
  byte-identical; each id lives under exactly one owner (the audit's
  invariant), so the union cannot duplicate
- **cancelAllOrdersFor** — same mechanism as sibling cancelAllUserOrders per
  the done-when, including the `deferredSwaps` walk via `swapIdsByOwner`
  (same shape, same function, was the same O(global) term)
- **selfAndOwnedPools** (rider): the marginPools full scan on the same two
  polled paths now reads W5-19's `poolIdsByOwner` (append-only ascending —
  same order, callers' output unchanged)

The 7 surviving `Map.entries(deferredExecs)` sites are exactly this brief's
OK rows (audit oracle, capped expiry sweep, market-keyed sort,
3× getStagedIndexAudit, rebuildStagedIndexes).

**Measured, not claimed** (devSweepCostProbe extended with the four paths
plus stagedGlobal/stagedOwn context; identical deterministic world on both
builds — S = 121 staged across 5 owners, sampled principal owning 0, one
margin pool holding 1 staged entry; values stable across 3 probe calls):

| polled path | before | after | ratio |
|---|---|---|---|
| myOpenOrdersWithStaged (getMyOrders) | 782,858 | 65,472 | 12.0× |
| getMyStagedOrderIds | 218,239 | 20,853 | 10.5× |
| getPoolOrders core | 213,550 | 21,408 | 10.0× |
| poolHasLiveOrdersElsewhere | 227,143 | 14,207 | 16.0× |

Before scales linearly with global S (attacker-inflatable); after scales
with own staged (≤32) + own pools — flat in S, 4-5 orders of magnitude under
the ~5B query ceiling. test_staged_owner_index §5 corroborates: indexed
soft-lock read 11,302 vs recomputed 95,890 at S = 25.

Verified: getStagedIndexAudit consistent through the full lifecycle
(test_staged_owner_index 17/17 — stage/cancel/release/timer-drain);
test_margin_pools 21/0 (the isolated-guard assertions exercise the converted
poolHasLiveOrdersElsewhere: staged entry blocks, guard self-clears);
test_margin_collateral_escape 11/0; test_cross_swap 4/0 (conservation exact);
test_load_shed_exits 13/13; test_liquidation_staged_shield 7/0; mops test
17/17 files; deploy hygiene PASS. NOT run: full run_all.sh (untouched
grounds), frontend build.

Environment note (filed as a follow-up queue task): the exec-a seat venue
refuses ALL in-place upgrades with `RTS error: Memory-incompatible program
upgrade` (IC0503) — including a control upgrade to the byte-identical
running source and an A→B upgrade between consecutive same-toolchain builds
(moc 1.9.0, matching the canister's motoko:compiler stamp). Both measurement
builds went in via `icp deploy backend -m reinstall -y`; the measurement
world rebuilds deterministically from resetExchange, so the numbers are
unaffected.
