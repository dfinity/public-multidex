# W4-07 — `ammSweepResting` re-rests under a fresh id, dropping the release link and the user's expiry

**Issue:** [#14](https://github.com/dfinity/public-multidex/issues/14) Finding 4 — andreij6
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` MEDIUM / `#production` MEDIUM
**Effort:** M

## What's wrong

The AMM sweep cancels a crossing order and re-submits the remainder as a fresh `#limit` order under
a **new id**, without `linkStagedRelease` and without carrying the user's `orderExpiry`.

Three consequences:

1. **Cancel and status by placement id break.** The id the user holds resolves to the *cancelled*
   order. (Compounds with [W4-05](W4-05-cancel-my-order-staged-release.md), which is the missing
   resolver on the other side.)
2. **Time-in-force is silently dropped.** A GTD order becomes effectively GTC — up to the 30-day
   default — because the new placement carries no expiry.
3. **A phantom `#cancelled` record** is written to the archive on every requote, so the public tape
   shows cancellations the user never issued.

The correct pattern is already in the tree: `releaseDeferred`'s `#limit` case carries `orderExpiry`
**and** calls `linkStagedRelease`.

## Evidence

- `src/backend/main.mo:2155-2276` — `ammSweepResting`; no `linkStagedRelease`, no `orderExpiry` anywhere in it
- `:2255-2256` — cancels `it.id`, re-submits via `executeLimitOrderProtected` under a fresh id
- `:2775-2776`, `:2781` — `releaseDeferred`'s correct handling to mirror

## Fix

Mirror `releaseDeferred`: carry `orderExpiry[it.id]` onto the new id and re-point any
`stagedReleasedAs` entry so the user's original handle still resolves.

Better if feasible: **match in place** without minting a new id, which removes the phantom
`#cancelled` record as well. Weigh against the order-book invariants that made a fresh placement the
easy choice.

## Done when

- [x] A swept order keeps its expiry
- [x] The user's original id still cancels and still reports status after a sweep
- [x] No `#cancelled` archive record is emitted for a pure requote (or its meaning is documented)
- [x] A test sweeps a GTD order and asserts the expiry survives

## Completed 2026-08-15 (W4 batch 1, landed with W4-05)

New `repointOrderIdentity(oldId, newId)` (beside `linkStagedRelease`): re-points every release
link whose value was the old id (chains stay one-hop), links the old id itself, and carries
`orderExpiry` onto the new id. The AMM sweep calls it on the re-rested order. The cancel+re-submit
shape stays; the archive's `#cancelled` row on a pure requote now has its meaning documented at
the call site ("re-rested by the venue") — the match-in-place alternative was weighed and deferred
per the task's own caution about book invariants.
