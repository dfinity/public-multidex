# W2-01 — `verifyChain` never anchors the recomputed tail to the certified `chainHead`

**Issue:** [#18](https://github.com/dfinity/public-multidex/issues/18) Finding 50 — andreij6
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#production` HIGH (this is the auditor-facing endpoint)
**Effort:** S

## What's wrong

The reporter predicted this exactly: *"A maintainer who applies [the #3.2] fix will reasonably
conclude the function is now sound; it will not be."* That is what happened.

The **inbound** gap (#3.2 — `prev` re-seeded per page) **is fixed**: `verifyChain` now seeds `prev`
from the preceding event and reports a failure when the predecessor is unreadable.

The **outbound** anchor is still missing. The loop's only integrity test is
`e.prevHash != ?EventChain.hash(p)` — event N's stored `prevHash` against the recomputed hash of
N−1. The last event's own recomputed hash is assigned to `prev` for a successor that never arrives,
the loop exits, and the function returns `ok = true` **unconditionally**. `chainHead` — the one
value a tamperer cannot forge, because the subnet certified it — is never consulted.

Two consequences:

- corrupting the **newest** stored event is invisible (no successor, so its `prevHash` is never read
  and its own hash is never checked against anything)
- any **consistent rewrite of a tail suffix** is invisible, because every comparison the function
  makes is internal to the rewritten suffix

On a **sealed season archive** there is no further append to advance the head and no successor batch
to expose the discrepancy, so a tail corruption is permanently reported clean by the endpoint the
`SeasonRecord` points auditors at.

## Evidence

- `src/backend/ArchiveCanister.mo:281-328` — `verifyChain`
- `:292-305` — the inbound seed (#3.2, **fixed**)
- `:313` — the sole link comparison
- `:327` — `{ checked; linksChecked = links; ok = true; … }`, no `chainHead` comparison
- `:56` `chainHead`; `:220` advanced on append; `:226` `CertifiedData.set(h)`; `:247` published by `getCertifiedHead`

Reproduction needing no build: read `headSeq` from `getCertifiedHead`, then
`verifyChain(headSeq, 1)` → `{ checked = 1; ok = true; … }` — a success returned by a call that
performed **zero** hash comparisons with a certified head in scope the whole time.

## Fix

Before returning `ok = true`, when the range reached `nextExpected`, compare
`EventChain.hash(prev)` against `chainHead` and fail when they differ.

The browser verifier already does this correctly (`src/frontend/src/ledger.js` compares the
recomputed head against each archive's certified head), so this is porting a rule that already
exists on the other side of the same guarantee.

## Done when

- [x] A full-range call over a tape whose newest event was perturbed returns `ok = false` —
      **proven by composition, not by perturbing a live tape** (see note)
- [x] `verifyChain(headSeq, 1)` no longer returns success on zero comparisons
- [x] A partial range that does **not** reach the tape end still returns `ok = true` legitimately
- [x] `tests/test_archive_chain.sh` asserts the head hash is derivable from the tape, not just `headSeq`
- [x] The function's doc comment is corrected — it currently claims both directions are checked

## Completed 2026-08-15

- The anchor: when the walk reaches `nextExpected`, `EventChain.hash(prev)` is compared against
  `chainHead` and a mismatch returns `ok = false, brokenAt = last seq`; the impossible
  events-walked-but-no-head state refuses rather than vouches; a `limit = 0` walk anchors nothing.
  A range stopping short of the end makes no head claim (`nextSeq` says keep paging). The anchor
  counts as one more `linksChecked`, so **an anchored full-range walk shows
  `linksChecked == checked`** — coverage that is itself auditable.
- **On the perturbation box**: corrupting a stored event needs a write path the archive
  deliberately lacks, and adding a tamper-with-me dev hook to the permanent append-only ledger
  canister was rejected. The proof decomposes instead: (a) new `tests/EventChain.test.mo`
  (17 green) pins hash sensitivity to EVERY field — header, payload, kind tag, prevHash — plus the
  netstring boundary-collision property and chain transitivity; (b) `test_archive_chain.sh` §3 now
  pins, on a SEALED segment (deterministic forever): full range head-anchored
  (`linksChecked = checked = 106`), the reporter's exact repro `verifyChain(headSeq, 1)` making
  2 comparisons (inbound + anchor) instead of zero, and an interior range passing with no head
  claim. Perturbed field ⇒ different hash (a) ⇒ head mismatch ⇒ `ok = false` (b).
- `test_archive_chain_paged.sh`'s fixed-count window now closes strictly BELOW the tape end — a
  walk reaching the end verifies one extra comparison, which would have raced concurrent appends;
  the anchored case lives on the sealed segment instead. Its 10 assertions stay green.
- Doc comment rewritten: internal links + outbound anchor, with the paged-sum identity updated
  (N−1 interior, N when the walk reaches the end) and where each case is pinned.
- Suites: archive chain 21/0, paged 10/0, failover 18/0, replay 15/0 on `#dev`; hygiene green and
  all 16 unit files green after the `#play` restore. Browser verifier (`ledger.js`) already
  anchored — unchanged.

## Notes

Independent of #3.2 in both directions; fixing either alone leaves `verifyChain` returning
`ok = true` over a tape that does not match its own certified head. Distinct from
[W2-02](W2-02-standalone-verifier-hardening.md) #37.1, where the anchor exists and is bypassed.
