# W1-07 — `repointOrderIdentity` reverse-scans a 100k map once per swept order

**Issue:** internal red-team round 2, finding R4
**Status:** VERIFIED LIVE at `d8f4c58` (2026-08-17) — **regression introduced by
[W4-07](done/W4-07-amm-sweep-order-identity.md)**, which landed in the same commit
**Severity:** `#play` MEDIUM, escalating to HIGH once `stagedReleasedAs` saturates / `#production` same
**Effort:** S–M

## Framing

W5-19 enumerated six uncapped walks and bounded all six. This is a **seventh**, and it is worse in
kind than any of them: the others are O(n) once, this is O(n) *inside a per-item loop*. It did not
appear in that audit because it did not exist yet — W4-07 created it hours earlier.

## What's wrong — the cost

`src/backend/main.mo:353-357`:

```motoko
func repointOrderIdentity(oldId : Nat, newId : Nat) {
  if (newId == 0 or newId == oldId) { return };
  for ((k, v) in Map.entries(stagedReleasedAs)) {
    if (v == oldId) { Map.add(stagedReleasedAs, Nat.compare, k, newId) };
  };
  ...
```

The `v == oldId` test gates only the write, not the visit — every entry is walked. Bounds:
`STAGED_LINKS_CAP = 100_000` (`:367`) is the only limit on the map; sole call site is the AMM sweep
(`:2414`); `SWEEP_SCAN_MAX_PER_SIDE = 512` per side (`:2299`, enforced `:2334`/`:2359`) so ≤1024
items.

Three multipliers the finding did not state:

- **It repoints every re-rested item, filled or not.** The `newId == 0` early-out at `:354` is dead
  on this path — for `#limit`, `MatchingEngine.mo:839-848` mints a fresh id whenever
  `remainingQty > 0 or totalFilled > 0`, and the two id-0 sentinels are unreachable because
  `sweepCtx` sets `onPendingFill = func(...) { null }` (`:2391`). A zero-fill requote of 1024
  crossers still pays 1024 full scans.
- **It runs once per pool inside one message.** `ammSweepResting` is called per pool from `tickAmm`
  (`:3578`, pool loop `:3585` → `ammRequote` `:3603`), whose body contains no `await` — so the whole
  pool loop is a single message, dispatched every 2s (`HB_AMM_NS`, `:6473`).
- **The failure mode is self-perpetuating.** An over-budget `tickAmm` traps, the tick rolls back,
  *no* pool requotes, the crossing orders survive, and the next heartbeat traps again. The AMM stays
  offline until the orders expire (30d TTL) or are cancelled — not one missed beat.

Worst case ≈1024 × 100,000 entry visits per pool in one message.

## What's wrong — the map saturates with no attacker

`stagedReleasedAs` has two writers: the staged `#limit` release (`:2956`) and `linkStagedRelease`
called from `repointOrderIdentity` itself (`:358`) — i.e. one entry per swept order every 2s,
self-amplifying. The **only** delete in the file is the cap prune at `:372`; nothing removes a link
when an order is cancelled, filled, or expires, and the map is non-`transient` so it survives
upgrades. `STAGED_CAP_PER_OWNER = 32` is a *concurrent* cap and does not bound lifetime entries.

100k is therefore the steady state, not a theoretical ceiling. That is what moves this from
"cliff nobody reaches" to scheduled work.

## Rejected: the "mutates while iterating" half of the finding

R4 also claims the in-loop `Map.add` corrupts the iteration, citing `runLiquidationBatch` and
`reconcilePoolPositions` as the contrasting safe pattern. **That claim is false here.**

This is `mo:core` 2.5.0 `Map` — a mutable B-tree; `Map.add` returns unit and mutates in place
(`.mops/core@2.5.0/src/Map.mo:422-424`), so the "ignoring the return value is a silent no-op"
reading is also wrong. The in-loop write targets the key **just yielded by the iterator**, so it
always takes the `#keyFound` path (`Map.mo:2174-2181` leaf, `:2217-2225` internal): same array slot,
no shift, no split, no `count` change, and `size` is unchanged because the previous value was
non-null. The iterator holds node refs plus a `kvIndex` and reads the slot at `next()` time — a
same-slot overwrite cannot invalidate it, skip, duplicate, or trap. Termination is safe because
`:354` guarantees `newId != oldId`. `linkStagedRelease`, which *can* split and *does* delete, runs
after the loop.

It is a **latent fragility** — one edit away from unsafe (a different key, or a delete inside the
loop, would restructure) — so it earns a comment, not a fix.

## Fix

Add a reverse index maintained inside `linkStagedRelease`:

```motoko
stagedReleasedFrom : Map<Nat /*orderId*/, List<Nat> /*stagedIds*/>
```

and replace the scan at `:355-357` with a lookup of the handful of keys actually pointing at
`oldId` — O(#links-to-oldId), typically 0 or 1.

**This preserves the invariant W4-07 chose deliberately.** That task's note records "chains stay
one-hop" as the design intent, and the three resolution sites (`:9809`, `:10034`, `:12769`) each do
a single `Map.get`. R4's suggested alternative — a resolver that follows the chain a few hops —
gives that up. The reverse index keeps it exactly.

**One-line stopgap** if relief is wanted before the index lands: drop `STAGED_LINKS_CAP` (`:367`)
from `100_000` to ~`2_000`. Cuts the worst case 50× for a one-token change; costs only depth of
handle-resolution history.

## Done when

- [x] The reverse scan is gone; repointing is O(links to `oldId`) — `stagedReleasedFrom`
      (transient, rebuilt in the W1-04 init block; `revAppend`/`revDrop` keep it an exact mirror)
- [x] One-hop chains preserved — the three `Map.get` resolution sites untouched
- [x] Cap lowered **and** eviction is mirror-exact: `STAGED_LINKS_CAP` 100k → 20k (retention
      window, not a scan bound — comment says so); per-order handle chains capped at 32, and
      every eviction (either cap) deletes forward *and* reverse sides together
- [x] The dead `newId == 0` branch is **deleted**; the comment documents why the id-0 sentinels
      are unreachable from the only call site (null `onPendingFill`, fresh-id mint on any rest)
- [x] Iterator-safety recorded: the scan no longer exists; the cap prune takes a FRESH
      `entries()` iterator per pass and the comment pins "never iterate a map being mutated"
- [x] Instruction cost recorded at a saturated map — `devSweepCostProbe` seeds the map to cap +
      one max-length chain in-query (state discards) and measures the repoint alone:
      **`repointSaturated = 987_386` instructions at `repointLinksAtProbe = 20_000` with the full
      32-handle chain** (scratch #dev venue, 2026-08-17). That is the per-order worst case and it
      no longer scales with map size — the typical 0–1-handle repoint is a few Map ops (~tens of
      k). Old form at the old cap: ~100k entry visits × every swept order, unbounded by anything
      per-order. Worst-case whole-sweep extrapolation (1024 items × max chains) ≈ 1.0B — and
      reaching it needs 32 consecutive zero-fill re-rests of ALL 1024 orders, which the per-order
      handle cap is exactly there to bound

---
## Status 2026-08-17 (later) — CLOSED, live-verified on a scratch worktree venue

Verified per the worktree pattern (fresh ICP_HOME, gateway.port 0, gen-did in
the worktree — the memory's `mops generate candid` step is what the first
cold_start failure was): cold_start `--mode full --no-simulate` green in 106s,
then `test_staged_owner_index.sh` **PASS, 17 assertions** — every
`audit consistent` now also proves the forward/reverse mirror
(`linkFwdUnmirrored`/`linkRevStray` fold into `consistent`) over live staged
traffic including the §3/§4 GEPTOR releases. Probe number above. This run is
also the first successful worktree cold_start e2e since the W1-06 reaper fix.

---
## (superseded) Status 2026-08-17 — implemented; live verification pending a replica window

Landed (this working tree): reverse index + O(handles) repoint + mirror-exact
eviction + audit counters (`getStagedIndexAudit` gains `linkFwdUnmirrored`/
`linkRevStray` folded into `consistent`, plus `releasedLinks`/
`releasedFromEntries` sizes) + probe measurement. Every `assert_consistent`
in `test_staged_owner_index.sh` now also verifies the mirror, no test edit
needed.

Static gates green: gen-did clean, lint-ratchet PASS (M0155 still 0 — the
one new Nat subtraction is explicitly annotated), candid backward-compatible
with origin/main (mops subtype check), deploy-hygiene 175 ✓.

Remaining before done: on a #dev venue (local replica currently owned by the
live fleet + a sibling session — do not disturb): run
`test_staged_owner_index.sh` (audit zeros over §1–5), drive one AMM sweep
repoint live, and record `repointSaturated` here per W5-19's
measured-not-claimed rule.
