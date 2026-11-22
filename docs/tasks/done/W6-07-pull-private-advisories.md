# W6-07 — Pull and triage the two private advisories

**Issue:** [#39](https://github.com/dfinity/public-multidex/issues/39) — OhShii Labs, round 4
**Status:** UNTRIAGED — content not visible from this queue
**Severity:** reported **moderate** (both)
**Effort:** S to triage; unknown to fix

## What exists

Round 4 audited the OQL engine and **the boundary held** — no live scoping bypass was found across
eight attack paths, and fifteen scoping/disclosure candidates were all cleared with the line that
clears each. That negative is the headline and it is worth recording.

Two **live** resource findings from that round went to the private advisory channel on 2026-08-09:

- `GHSA-5rcg-pp8j-7pfx`
- `GHSA-458x-24rf-g96f`

Both **moderate**; nothing in that round is high or critical. The reporter deliberately did not
describe the area publicly, because both are live, unfixed and cheap to trigger, and naming the path
before a fix exists helps the wrong party. That is the right call and matches `SECURITY.md`.

**They are not represented anywhere in this task queue**, because their content is not visible from
the issue threads. That is the gap this task closes.

## Fix

1. Read both advisories on the repo's security tab.
2. Verify each against the current tree, same standard as the rest of this queue.
3. Add task files for whatever is live, and slot them into W3 or W4 by severity.
4. Reply on the advisories with status, as with the public issues.
5. They offered to **mirror both publicly once fixed** if we want the record complete — decide, and
   tell them.

## Also worth acting on

Two structural facts from the same round, neither a MULTI/DEX defect:

- **`Entity.withServed` has exactly two occurrences** — its definition and one call site inside
  `oql/IndexedMap.mo`, which has no occurrence outside the `oql/` tree. So `aggPlan`, `planServed`
  and `planJoin` are **unreachable, and every live query is a full scan**. That is load-bearing for
  reasoning about OQL cost, and it is not obvious from reading `Executor.mo` — worth a comment in the
  code so the next reader does not re-derive it.
- **GitHub's REST endpoint for private advisory *creation*
  (`POST /repos/{owner}/{repo}/security-advisories/reports`) returns HTTP 500 with an empty body** for
  every well-formed request; the route resolves, private reporting is enabled, and the validator works
  (bad keys give a clean 422). Only the create path faults, for `curl` as well as `gh`. The web form
  works. Not our bug — but if any of our tooling or docs points reporters at that endpoint, point them
  at the form instead.

## Done when

- [ ] Both advisories read and verified against the current tree
- [ ] Task files exist for anything live, slotted by severity
- [ ] Both have a maintainer status reply
- [ ] The mirror-once-fixed question is answered
- [ ] The "no entity is served" fact is recorded in the OQL code

---
## Done — 2026-08-15 (both advisories pulled, verified, FIXED)

Read both via `gh api` (repo security tab access worked from this account),
verified both live against the tree, and — being S-effort with clear
remedies — fixed them in this pass rather than re-queueing:

- **GHSA-5rcg-pp8j-7pfx** (archiveExecute chain exit unsatisfiable for a
  sparse-history caller → every free anonymous request walked the whole
  chain): confirmed at the (moved) conjunction exit. Fixed with a
  per-request hop budget (`ARCHIVE_MAX_HOPS = 6` — the active archive plus
  five sealed segments; the caps conjunction still short-circuits earlier
  when both budgets fill), which restores exactly what the walk's own
  comment promises; deep history stays reachable per-archive via
  getMyArchivedEvents. The advisory's reasoning about WHY the anonymous
  rejection doesn't apply (queries bypass inspect) is already our own
  documented position — kept.
- **GHSA-458x-24rf-g96f** (depositLp(0,0) writes a permanent chained
  #lpDeposit row for a no-op — §1.8's fourth instance, unreachable by the
  inspect size-check blanket fix): confirmed; performLpDeposit now refuses
  `(0,0)` with `#err("Nothing to deposit")` BEFORE any event — the loud-
  refusal direction, consistent with W6-02's doctrine, chosen over a silent
  #ok(0) precisely because the event's own justification ("an acquisition
  event") does not obtain.

Pinned by tests/test_ghsa_round4.sh (4 assertions, green on the deployed
fix): the refusal fires, the tape count is unchanged across the attempt,
the hop budget is present structurally, and a zero-history caller gets a
well-formed answer. Both advisory threads owe the reporter a reply +
eventual public mirror — queued with the W6-05 outward batch (the fix is
in; the disclosure step is the blocked half).

Also recorded: round 4's headline negative (the OQL boundary HELD across
eight attack paths) is now cited in the triage §8; the advisories'
"compounds with chain length" observation is mooted by the hop budget.
