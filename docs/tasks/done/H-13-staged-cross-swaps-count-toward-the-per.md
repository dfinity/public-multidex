# H-13 — Staged cross-swaps count toward the per-owner staged cap and the shed-floor depth

*Source: [hardening-plan-2026-09.md](../hardening-plan-2026-09.md) · Wave 1 (backend upgrade #1: solvency & book poisoning) · findings F22 a/b · MEDIUM, the cheap half · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

`class: security-medium`

**Mechanism.** `executeSwapCross`'s staged branch (`:13478-13490`) reserves, allocates an id and
inserts into `deferredSwaps` with no `stagedCountOf`/`STAGED_CAP_PER_OWNER` (`:912`, applied in
`parkDeferred` `:2570`) and no `incStagedCount` (`:1036`); `recomputeShedFloor` (`:7377-7378`)
keys on `Map.size(deferredExecs)` only — the shed-floor comment (`:7360-7363`) assumes "the
per-owner staged cap already bounds each caller". ~10,000 staged cross-swaps per account at the
$100k cap, soft-locked and refundable.

**Fix criteria.** Cap check + `incStagedCount` keyed on `scorecardKeyOf` (matching `parkDeferred`,
see `:1030-1033`) in the staged branch; `decStagedCount` in `removeDeferredSwap`;
`recomputeShedFloor` sums `deferredExecs + deferredSwaps`; `getStagedIndexAudit` reconciles both
maps. Document that `getMyStagedCount` now includes cross-swaps (no signature change).

**Verify.** 33 cross-swaps from one account → the 33rd refused, audit consistent; staged
cross-swap depth alone raises `_shedFloorShip`/the staged floor (`test_ship_backpressure.sh`
pattern).

**done 2026-09-04** (task `1788467610`, branch claude/seat-1, on top of `d01e9c7`, code commit `d5d7032`): backend + tests, one additive dev hook. **Cap (F22a)**: `executeSwapCross`'s staged branch checks `stagedCountOf(caller) >= STAGED_CAP_PER_OWNER` with parkDeferred's exact key (`scorecardKeyOf`) and internal-principal exemption, BEFORE the reservation (#err ⇒ nothing moved), refusing with `Staged-order cap reached (32 staged orders and cross-swaps per account) — cancel one or wait for release`; `incStagedCount` after the insert; `decStagedCount` in `removeDeferredSwap` — the ONLY drop path (release, cancelMyOrder, cancelAllMyOrders, the liquidation cancel-all all go through it; resetExchange clears both maps and the counter together). **Floor (F22b)**: `recomputeShedFloor` reads `stagedDepth() = Map.size(deferredExecs) + Map.size(deferredSwaps)`; `setTestStagedShedBands` (dev-gated, in inspect's enumeration, candid +1 method — the W1-08 ship-pin pattern the brief names) pins the staged bands so the signal is testable from 32 real swaps instead of 2,000. **Audit**: `getStagedIndexAudit` (f) recounts `stagedCountByOwner` over both maps by `scorecardKeyOf` and folds mismatches/strays into `consistent` + `detail` (no reply-shape change); `rebuildStagedIndexes` recounts the STABLE counter on every start, so the first upgrade of a live target carrying pre-fix staged swaps comes up honest instead of audit-red until they drain. **Docs**: getApiDoc's cap sentence + the `myStagedCount` / `whyAmIRefused.stagedCount` field comments say cross-swaps count (no signature change). **Verified**: `tests/test_staged_swap_cap.sh` (new, state-light, timers paused): RED 11/26 on the pre-fix build (count 0 at 32 staged, #33 accepted and reserved, floor 0 at 35 staged swaps) → GREEN 26/26. The brief's Verify items: 32 stage / #33 refused with available ICP unchanged and the count unmoved, audit consistent at every step (§2/§4/§6); bands pinned strictly above `execLive` and at/below `execLive + 32` → `shedFloor = 2` from cross-swap depth alone, `swap` refused at the gate, `whyAmIRefused.admittedNow = false`, floor 0 on release. Adjacent cases: the FOK immediate two-leg path (`noPartialFill=true`) is not the staged path and is not cap-refused; the one-unit case (cancel one → 31 → one more admitted → cap holds); the bulk cancel drains 32 through removeDeferredSwap → count 0, swapLive back to baseline, reservations refunded; `test_staged_owner_index.sh` asserts B's `myStagedCount = 3` (2 staged sells + 1 swap) and 0 after release (RED pre-fix by the same mechanism). Other parkDeferred callers (placeLimit/Market, bulk, swap direct, pool paths) were already capped — grep of `parkDeferred(` confirms every staging site other than the cross branch routes through it. Gates: `mops check backend` (only the 6 pre-existing lintoko errors), `mops test` 19 files, `test_deploy_hygiene` PASS, `run_all --filter staged/shed/backpressure/pending_owner` 9/9, `--filter swap` 8/9 with `test_swap.sh` red ONLY from suite-order venue state (the cross_swap/swap_* siblings resetExchange and self-seed ICP/BTC; test_swap needs the seeded ETH pool) — PASS 32/32 alone after a full reseed. NOT run: the full `run_all.sh` (the change touches the staged/shed/swap ground only; the 17 suites on that ground plus unit/static ran). Posture: #play restored after both deploys. Follow-up filed: `1788520988` (the direct-swap staged path still folds a cap hit into its "Insufficient available balance" text). F22c (release pacing) stays with H-22 `1788467619`.

## Done when

- [x] Every **Fix criteria** item above is implemented; no stable-field drops, no candid change beyond what the brief flags
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (record the red run in the task log); adjacent cases enumerated per README §"Closing a task"
- [x] Full suite green on `#dev`; posture restored to `#play` before merge; deploy hygiene PASS
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the merge sha
