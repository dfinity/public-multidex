# W6-05 — Acknowledge rounds 2–6, and publish the scoring basis

**Issues:** [#40](https://github.com/dfinity/public-multidex/issues/40) closing section ·
[#25](https://github.com/dfinity/public-multidex/issues/25), [#27](https://github.com/dfinity/public-multidex/issues/27) maintainer comments ·
1.60 triage §7.2 closing line
**Status:** OUTSTANDING at 2026-08-14
**Severity:** process
**Effort:** S

## What's outstanding

1. **Round 2 (#23–#28) and rounds 3–6 (#36–#41) have never been triaged on the tracker.** This was
   said plainly on #25 and #27 in the maintainer's own words — *"Round 2 has not been triaged or
   worked… Saying so is more useful to you than silence"* — and it is still true. This task queue is
   the triage; the reporters cannot see it until it is published.
2. **`andreij6` is not scored in `CONTRIBUTORS.md`.** The 1.60 triage's own closing line says so:
   *"Neither wave has been acknowledged on the tracker, and `andreij6` is not yet scored."* Their
   contribution is among the most valuable in the whole set — #17 corrected a remedy that had already
   shipped, #18 predicted the exact half-fix trap that W2-01 confirms, and #21 corrected a
   certification.
3. **`CONTRIBUTORS.md` is not in the public mirror.** Verified: it is tracked here and **404s** on
   `dfinity/public-multidex`. The triage document cites it twice as "the basis for the points", so
   the reporters are being scored against a rubric they cannot read. Their ask is explicit and modest:

   > We are not asking to see a score. We are asking whether the criteria are written down somewhere
   > the people being scored can read them — because at the moment all three teams are inferring them
   > from your replies, and inferring a rubric is exactly the kind of thing this audit keeps finding
   > goes wrong.

## Decisions for you

- **Publish `CONTRIBUTORS.md` to the mirror?** It is a disclosure choice, not a code change. If yes,
  it goes in the same push as the refreshed triage ([W6-01](done/W6-01-refresh-triage-document.md)).
  If no, say so and state where the criteria live instead.
- **How to score the instrument rounds (#36–#41).** They are mostly not live defects; they are
  findings about whether our gates can see. Rounds 3–6 also killed a large fraction of their own
  drafts before filing (round 6: 44 candidates → 3 findings; round 5: 15 rejects including 5
  self-corrections). If the rubric rewards live severity only, it will under-value exactly the
  behaviour worth encouraging.

## Fix

- Post a triage summary on the tracker covering rounds 2–6, linking the task files
- Score `andreij6`; update `CONTRIBUTORS.md` for all three teams
- Answer the rubric-visibility question one way or the other

## Done when

- [ ] Each open issue #23–#28, #36–#41 has a maintainer status comment
- [ ] `andreij6` is scored
- [ ] The rubric question is answered publicly

---
## PREPARED 2026-08-15 — blocked on the two decisions + posting authorization

Everything postable is drafted under [drafts-w6-05/](drafts-w6-05/):

- `ledger-rounds-2-6-DRAFT.md` — the CONTRIBUTORS.md addition: 42 verified
  findings across 12 issues, severities lifted from the per-task verification
  headers (not the claims), modifier policy proposed, andreij6's owed wave-2
  scoring named with the three standout contributions.
- `tracker-comments-DRAFT.md` — one status comment per issue #22–#28,
  #36–#41, each linking the refreshed triage §8 row per item.
- `rubric-answer-DRAFT.md` — the visibility answer ("yes, written down; no,
  you couldn't read it; that is our defect"), with the publish decision
  called out.

**Blocked on (the task's own "Decisions for you"):** (1) publish
CONTRIBUTORS.md to the mirror — a disclosure choice; (2) instrument-round
weighting sign-off; (3) authorization to post on the public tracker and push
the refreshed triage + ledger. None of the three Done-when boxes can be
checked without those. The task stays in the queue as the umbrella for the
outward batch.

---
## Partial completion — 2026-08-15 (criteria published; scoring held)

Per maintainer decisions: (1) criteria-only public, (2) recognition-first /
DFINITY-discretionary bounties (not a program), (3) publish.

DONE:
- Public criteria published to the mirror as CONTRIBUTORS.md
  (commit 585814ef) — rubric only, NO per-finding scores and NO standings.
  Verified live + clean. This resolves #40's exact ask (the triage doc's
  `../CONTRIBUTORS.md` citation now resolves instead of 404ing) and closes
  the "criteria inferred, not readable" gap. Published copy kept at
  drafts-w6-05/CONTRIBUTORS-public-PUBLISHED.md.
- Private CONTRIBUTORS.md framing reconciled to match (recognition-first,
  discretionary; the old "basis for bounty allocation" line is gone). Its
  internal scored ledger is retained.

STILL OPEN (the scoring + outward acknowledgement half):
- The rounds 2–6 + andreij6 points pass is drafted (points-update-DRAFT.md,
  base floor + flagged modifier estimate) but NOT merged into the private
  ledger — needs the per-issue modifier pass ratified before any figure is
  treated as final, since it may inform discretionary recognition.
- Per-issue status comments on the tracker (#23–28, #36–41) and the round-4
  negative-result acknowledgement remain unposted (outward — your call).

---
## Maintainer decisions 2026-08-17 — sequencing set

1. **CONTRIBUTORS.md stays live on the mirror as-is** (criteria-only,
   `585814ef`): now that it is public it stays public; scores and standings
   remain private for now, to avoid controversy.
2. **Scoring becomes commit-grounded**: walk every fix commit that resulted
   from the PR/issue analyses and update the private ledger accordingly
   (instrument rounds included). Evidence pass in flight →
   `drafts-w6-05/commit-evidence-map-DRAFT.md`; figures still need
   maintainer ratification before merging into the ledger.
3. **Per-issue status comments: authorized, but sequenced** — the current
   task queue completes first, then the next push to the public mirror, and
   CONTRIBUTORS.md is updated accordingly in that push; the comments then go
   out re-baselined against what is publicly visible. Nothing outward moves
   before that push.

---
## Completion — 2026-09-03 (task 1786989367)
All Done-when boxes closed: criteria public since 585814ef; per-issue status
comments posted on #23–#28, #36–#41 (2026-09-01) plus the owed wave-1/2 and
#42–#52 comments; rubric answered publicly on #40; round-4 negative result
acknowledged on #39; andreij6 and rounds 2–6 SCORED — the commit-grounded pass
ratified 2026-09-03 (figures in the private ledger only — scores stay private).
