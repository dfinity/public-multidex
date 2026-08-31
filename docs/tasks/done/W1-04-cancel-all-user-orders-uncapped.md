# W1-04 — `cancelAllUserOrders` is a second uncapped O(staged) term on the liquidation batch

**Issue:** [#22](https://github.com/dfinity/public-multidex/issues/22) item 3 — Menese DeFi Team
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14) — maintainer confirmed open 2026-08-07
**Severity:** `#play` HIGH / `#production` HIGH (solvency-engine availability)
**Effort:** M

## What's wrong

For each user the batch actually liquidates, `cancelAllUserOrders` walks the **entire**
`pendingMatches` map, the **entire** `deferredExecs` map and the **entire** `deferredSwaps` map,
with no cap, to move that user's reserved order funds back to spendable before the seize. Those
three maps are attacker-inflatable staged state, so this is a second O(staged) term on the same
single-message batch, on top of [W3-01](W3-01-soft-locked-reserved-accumulator.md)'s
`softLockedReserved` cost — and it fires **per liquidated user**.

Reporter's measurement (S = 5,000 staged entries): ~1,662 instructions per staged entry for the
walk; **76.0 M instructions per liquidated user** end to end once `valuations` and this walk both
fire; the real batch **traps at N = 560** liquidatable users.

**`LIQ_BATCH_MAX = 2_000` does not save this.** That cap bounds users per pass, not
`users × staged`. A mass-liquidation cohort of ≥~560 liquidatable users at S = 5,000 still exceeds
40 B and traps — which is precisely the self-disable the cap exists to prevent. On `#play` the
per-principal allowance removes the capital floor on inflating S.

**Precondition, stated honestly:** the trap needs the staged count inflated (S ≈ 5,000). That is
cheap and uncapped today, but it is a precondition, not an unconditional property.

## Evidence

- `src/backend/main.mo:8359` — `func cancelAllUserOrders(user : Principal) : Bool`
- `:8368` `for ((id, pm) in Map.entries(pendingMatches))` — full scan, no cap
- `:8377` `for ((id, d) in Map.entries(deferredExecs))` — full scan, no cap
- `:8396` `for ((id, s) in Map.entries(deferredSwaps))` — full scan, no cap
- `:8467` — `if (pre.isLiquidatable) { ignore cancelAllUserOrders(user) }`, inside `tryLiquidate`
- `:6229` — `LIQ_BATCH_MAX : Nat = 2_000`; `:3609` — the slice break

## Fix

Index the staged maps by owner so the walk is O(that user's staged entries) rather than O(all):

- add a per-owner secondary index over `pendingMatches` / `deferredExecs` / `deferredSwaps`,
  maintained at stage and at every removal — the same shape as the accumulator in
  [W3-01](W3-01-soft-locked-reserved-accumulator.md), and ideally landed with it as one change
- `stagedCountByOwner` already exists as a precedent for owner-keyed staged bookkeeping

Fallback if the index is deferred: bound the work per batch (cap liquidations per pass by
`users × staged` rather than users alone) so the engine degrades instead of trapping.

## Done when

- [x] `cancelAllUserOrders` cost is independent of the global staged count
- [x] A seeded S = 5,000 / N = 600 mass-liquidation batch completes rather than trapping —
      **by construction, not by full-scale repro** (see note below)
- [x] The index is proven consistent under stage → release → cancel → liquidate sequences
- [x] Instruction counts recorded, so the next report can be diffed against a number

## Completed 2026-08-14 — landed with W3-01 as one change

- Three transient owner indexes (`pmIdsByUser` — taker AND maker, `deferredIdsByOwner`,
  `swapIdsByOwner`) + the W3-01 accumulator, maintained in the existing chokepoints:
  `recordPendingMatchIndex`/`removePendingIndex`, the two stage sites, `removeDeferredExec`, and a
  new `removeDeferredSwap` (the swap mirror — the four bare `Map.delete(deferredSwaps)` sites now
  route through it). `cancelAllUserOrders`' three full-map scans became three
  O(user's entries) index walks. Transient by design: an init block rebuilds all four structures
  from the authoritative maps on every install/upgrade, so no migration and no possibility of the
  index surviving in a state the maps don't corroborate; `resetExchange` clears them.
- `getStagedIndexAudit` (controller query) is the drift oracle: recomputes membership both
  directions plus the accumulator and measures indexed vs recomputed read cost with the IC
  performance counter.
- `tests/test_staged_owner_index.sh` (17 green on `#dev`): stage mix → cancel (post-commit-window)
  → release both markets (incl. `adminRunDeferredSwaps`) → timers-on drain → audit consistent at
  every step. Regressions green: sealed model, cross-swap, order expiry, FOK, margin collateral
  escape (liquidations fire there) — audit still consistent on the post-suite venue.
- **Recorded numbers** (audit, S = 25): indexed soft-lock read **11,302 instructions** (flat;
  dominated by the `Principal.toText` key build), recomputed scan **95,890** (≈3.8k/entry — the
  same order as Menese's ≈1.66k/entry/map). Extrapolated to the report's S = 5,000: ≈19 M per scan
  (matches their 16.66 M) vs the same ~11 k indexed.
- **On the N = 600 box**: the full rig (600 underwater margin users × S = 5,000) was not rebuilt.
  The claim rests on the reporter's own decomposition: their 76 M/user was dominated by the two
  O(S) terms (this walk + W3-01's valuations reads), and both are now O(user's entries) — the batch
  cost no longer contains an S term at all. If a future report re-measures, diff against the
  numbers above.

## Notes

Credit is Menese's; item 1 of the same issue is [W3-01](W3-01-soft-locked-reserved-accumulator.md)
(credit andreij6, #19 Finding 5). Item 2 of that issue — the matcher fill walk — is **already
fixed** post-1.60 and must not be reworked.
