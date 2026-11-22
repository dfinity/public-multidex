# W6-06 — Answer the disclosure-channel question

**Issues:** [#36](https://github.com/dfinity/public-multidex/issues/36) "On where we file" ·
[#37](https://github.com/dfinity/public-multidex/issues/37) comment · [#39](https://github.com/dfinity/public-multidex/issues/39)
**Status:** OPEN QUESTION, asked directly, unanswered
**Severity:** process
**Effort:** S — **one reply**

## The question they asked

OhShii asked outright: **"So: where would you like round 4?"** — and offered to move future rounds to
advisories entirely. They are following whatever we say.

They also corrected their own framing unprompted. Round 3 proposed "public issue by default"; in the
follow-up comment they noted that argument omitted two things that cut the other way, **both ours**:

> `SECURITY.md:19`: Please do **not** open public issues or pull requests for security problems

and the maintainer's own line on #25 that the advisory link now works so the next report *"does not
have to be public"*. They said arguing a filing policy while omitting the two lines that contradict
it was the same shape as the prose problems we had flagged at them, and they would rather correct it
than let it stand.

## Their argument for public, which is worth weighing

Not visibility — **cross-team correction**. The single most valuable correction across all three teams
happened because the threads were open: andreij6's #17 showed that raising `PRICE_MIN_SOURCES` to 3
moves the failure rather than fixing it, a remedy both OhShii and Menese had proposed **and that had
already shipped here**. In three separate private channels, all three keep a wrong fix and we carry it.

They explicitly say this does not outrank our stated policy — it is a consideration for us to weigh.

## What they will not do

They are **not** proposing to move or close #36, #37 or the earlier rounds: all three teams now
cross-reference each other by `#issue.item`, #29 indexes theirs, and relocating would break that graph
for everyone. Reasonable.

## Current state

Fifteen advisories are open, all OhShii's, all in `triage`. Round 4 (#39) filed two live resource
findings privately as `GHSA-5rcg-pp8j-7pfx` and `GHSA-458x-24rf-g96f` — see
[W6-07](done/W6-07-pull-private-advisories.md).

## Decide and reply

A defensible answer, and the one I would give: **public by default for findings that are not
exploitable before a fix exists; advisory for anything that is.** That is what they proposed, it
matches how the value has actually been created here, and it needs one edit to `SECURITY.md:19` so
the written policy and the practice agree. If you would rather keep everything private, say so and
they will move — but then `SECURITY.md` should also say what happens to cross-team dedup.

Either way: name the class you never want in the open, so it is not a judgement call for them.

## Done when

- [ ] A reply is posted naming the default channel and the exception class
- [ ] `SECURITY.md:19` matches the answer
- [ ] The fifteen open advisories get a disposition (leave, mirror once fixed, or close)

---
## PREPARED 2026-08-15 — blocked on the policy decision + posting

The reply, the exception class, the SECURITY.md:19 edit, and the
advisory-disposition (leave + mirror-once-fixed) are drafted in
[drafts-w6-05/disclosure-reply-DRAFT.md](drafts-w6-05/disclosure-reply-DRAFT.md),
encoding the recommendation this file argues (public-by-default /
advisory-if-exploitable-pre-fix). All three Done-when boxes require the
maintainer's decision and outward posting — queued with the W6-05 batch.

---
## DECIDED 2026-08-17 (maintainer) — posting still queued

Policy ratified as recommended: **public by default** (explicitly including
cross-team verification value), **advisory if easily exploitable before a
fix exists**. One addition: this is the *pre-production* policy — it will be
revisited when the exchange transitions to `#production`. The reply draft
carries that line now.

Posting order (maintainer-set): the current task queue completes first, then
the next mirror push, then the reply + SECURITY.md:19 edit + per-issue
comments go out re-baselined against what that push made public.

---
## Completion — 2026-09-01 (task 1786989368)

All three Done-when boxes closed:
- Reply posted on #36 (cc #37/#39): public-by-default, advisory only for the
  end-user-exploitable-pre-fix class; #play-era policy, revisited at
  #production. (Posted this sitting; comment URL in the factory archive note.)
- SECURITY.md "Reporting a vulnerability" rewritten to match the ratified
  answer — public default + exception class + mirror-on-fix promise; the
  404-history note, email fallback, and no-live-testing rule preserved.
  Landed on main and synced to the mirror as a follow-up de la Vega commit
  (the batch snapshot f233d18 predated the edit; the task anticipated this).
- The open advisories dispositioned as drafted: leave open, mirror each into
  the public tracker once its fix ships, GHSA id kept. Count at execution:
  22 (the draft's 15 plus 7 filed by rounds 7-15 since 2026-08-15) — the
  disposition applies uniformly.

---
## Ratification — 2026-09-03 (task 1788465053)

The mirror-once-the-fix-ships rule now covers our own documents: a triage
document or task brief carrying a working primitive for the advisory class is
held from the public mirror until its fix ships there (exclusion at snapshot
composition, not redaction). Prompted by GHSA-63hp's timeline record — the
2026-08-07 triage document published the delegation-page primitive 24 days
before its fix. SECURITY.md carries the sentence; the snapshot recipe and the
standing exclusion/inclusion lists are in
[../../public-mirror-procedure.md](../../public-mirror-procedure.md).
