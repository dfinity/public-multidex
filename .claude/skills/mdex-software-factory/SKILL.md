---
name: mdex-software-factory
description: Operate the MULTI/DEX software factory - a filesystem task queue at tasks/queue with atomic claims, priority-by-rename, operator signal files, and session roles, where every consumer seat is a CLI executor session in its own git worktree with its own isolated local venue, plus a dedicated operator seat for operator-directed work. Ingest when told "you are a TaskConsumer / TaskPrioritizer / TaskProducer / the OperatorTasks console", when booting or taking over a factory seat, and whenever filing follow-up work into the queue.
metadata:
  title: The software factory
  category: Operations
---

# Skill: the MULTI/DEX software factory

Several Claude sessions work one shared task queue continuously: **TaskConsumers**
(typically 3-5, each a CLI executor session in its own git worktree with its
OWN local venue - the worker doctrine below) claim and execute tasks; **one
TaskPrioritizer** reorders the queue and keeps the board; **TaskProducers**
(ad hoc) turn instructions, audits, and community issues into tasks; and one
standing **operator seat** hosts operator-directed work. The operator
(Dominic) boots sessions and is the escalation path. There is no message bus
and no coordinator process: the queue directory IS the coordination, and every
mutation is an atomic same-filesystem rename, so races have exactly one winner
and losers retry. The operator's control channel to a running seat is a
FILE too - `tasks/signal/` (Operator signals, below) - not a chat message.

Three things make this factory different from a generic one, and they are all
load-bearing:

1. **This machine hosts live systems.** Long-lived bot fleets drive the LIVE
   subnet at multidex.ai and the cloud engine, and the primary checkout's
   :8000 local network is the operator's standing demo venue. Seat isolation
   (own worktree, own `ICP_HOME`, own OS-assigned port) and the
   `mdex-process-safety` skill are how the factory coexists with all of that.
2. **Nothing is ever pushed.** Merges land on the primary checkout's `main`
   LOCALLY. Pushing to origin or the public mirror is the operator's act, on
   explicit instruction only, sequenced by the outward-batch policy - the
   factory has no push step anywhere.
3. **Task production stays as it is today.** `docs/tasks/` (tracked) remains
   the authored task corpus - W-style briefs, `done/`, the README queue table.
   The factory adds a RUNTIME queue (`tasks/`, gitignored) that carries
   execution state: claims, priorities, dependencies, the board.

`scripts/factory.sh` is the ONLY way to touch the queue. It works from the
primary checkout or any worktree (it resolves the queue root to the PRIMARY
checkout's `tasks/` either way - `git worktree list` puts the primary first).
Run `scripts/factory.sh help` for the command table;
`scripts/factory-selftest.sh` exercises it against a throwaway queue.

## The queue on disk

```
tasks/queue/     pending tasks, one md file each:  PPPPPPPPPP-IIIIIIIIII.md
tasks/claimed/<worker>/   in-flight tasks, one subdir per consumer
tasks/archive/   terminal tasks: <id>.md  (status stamped inside)
tasks/factory/   coordination surface: index.md (the board), merge.lock/,
                 .ids/ (the append-only id allocator - never touch, never clean),
                 fleet-roster (the seats the fleet doctor REMEMBERS - written
                 by worker-pin, adopted by the doctor, dropped only by
                 seat-retire - except a row for the OPERATOR principal, stale
                 by construction, which the doctor's own pass drops instead of
                 reading it ORPHANED: roster_drop_operator_row, task
                 1793621537) + fleet-orphaned (the first pass that saw a
                 roster seat's worktree missing - the forensic anchor),
                 spawn-pending/<seat> (a boot Terminal has queued but not yet
                 run), signal-shown/<worker>.all|.own (the order text a
                 refused claim printed - what the seat's ack acknowledges)
tasks/handoff/   one <worktree-basename>.md per seat waiting for a successor
                 session: the boot prompt, on disk, where an app restart
                 cannot reach it (`factory.sh handoff-list`); prioritizer.md
                 is the prioritizer's own boot token (`prioritizer-boot`)
tasks/signal/    operator ORDERS to a seat: <worker>.md, plus all.md (the
                 broadcast) and all.acked/<worker> (the broadcast's per-seat
                 ack ledger). Wakes every `watch`, blocks that seat's next
                 `claim` until acknowledged (Operator signals, below)
```

All six are gitignored runtime state. The tracked corpus in `docs/tasks/` is
unaffected and keeps its current conventions exactly. Further runtime state
lives outside `tasks/`, all gitignored too: each seat's
`<worktree>/.factory-worker`, the one-line identity pin factory.sh reads
instead of guessing a worker from the cwd's branch - see the TaskConsumer
setup; its `.factory-heartbeat`, stamped by every factory.sh command run
inside the tree (what the fleet doctor reads); and its `.worktree-keep`, the
belt against the desktop app's worktree GC. And the seats themselves live
under `<primary>/.factory/seats/<seat>` - the SEAT ROOT (`factory.sh
seat-root`), deliberately OUTSIDE the Claude desktop app's own worktree pool
`.claude/worktrees/`, whose 30-minute GC removes idle untracked trees there -
see "Where a seat lives" under the TaskConsumer setup. (The standing operator
seat at `.claude/worktrees/operator` is the one deliberate exception - "The
operator seat", below.)

**Naming.** `P` (10 digits) is the priority key; `I` (10 digits) is the
immutable id. Both start as the UTC epoch seconds of creation, so an untouched
queue lists in FIFO order and `ls tasks/queue` IS the execution order
(ascending). The prioritizer renames ONLY the P half. The id is the task's
identity forever - in `after:` dependencies, in archive filenames, in board
notes - and the allocator guarantees it is never minted twice.

**Lifecycle.** `queue/ -> claimed/<worker>/ -> archive/` - claim and archive
are `mv`s performed by factory.sh; there are no other states. A task in
`queue/` is claimable by definition; if it must not run yet, that is expressed
by `after:` dependencies or a `90`-band parking, not by side agreements.

**The two layers.** A queue task either inlines its whole brief (small,
self-contained work), or names a tracked brief with `docfile:
docs/tasks/<file>.md` plus a one-paragraph gist. The brief rides git, so every
worktree sees it and law 6 (self-containedness) is satisfied transitively.
Closing a `docfile:` task INCLUDES the corpus bookkeeping, on your branch so
it rides your merge: move the brief to `docs/tasks/done/` with the
`**done <date>**: ...` completion note in the current style, and strike its
row in `docs/tasks/README.md` (`~~[W..]~~ ... — **done <date>**: ...`).
`factory.sh done` refuses to archive while the brief still sits at its
original path - the **bookkeeping law**, mechanical so forgetting is
impossible. Each seat edits only its OWN task's README row; rows are one line
each precisely so parallel strikes merge clean.

**The operator lane.** `lane: operator` in a task's front matter means the
task is WAITING ON THE OPERATOR and no consumer seat may claim it. It holds
two shapes of work: operator-EXECUTED tasks (engine/subnet rollouts, pushes,
anything needing human-held auth - law 8), which the operator resolves with
`done`; and operator-INPUT tasks (a decision, credential, or clarification a
consumer needs), which pass THROUGH the lane - the answer is embedded in the
task file and it is released back to the consumer queue (the OperatorTasks
role below). `factory.sh claim` skips lane tasks entirely, including as a
last-resort fallback, so a seat gets an itemized `EMPTY` rather than forbidden
work; `factory.sh claim --operator` claims only them. `list --operator` /
`list --consumer` filter, and the board gives them their own section - being
SEEN at rollout time is the point of the lane, not being worked. This is a
different axis from priority: band 90 only DELAYS a claim, and on a contended
queue "nothing else remains" arrives routinely; a task no consumer may run
must be unclaimable, not merely parked.

### The laws (every role)

1. Only `factory.sh` mutates queue state. Never `mv`/`rm`/Write task files by
   hand, and never operate on a worktree's own `tasks/` copy.
2. The id half of a filename never changes. Only the prioritizer renames the
   priority half, only via `reprioritize`, only for QUEUED tasks.
3. A claimed task belongs to its worker: nobody else edits or moves it. The
   prioritizer flags stale claims on the board but never requeues them itself -
   that is the operator's call (or the owning session's, via `requeue`).
4. The prioritizer never edits task content, never claims, and never touches
   git history or refs (no commits, merges, checkouts). Its only git contact
   is the janitor's read-only liveness look at a stale claim's worktree.
5. Nobody DEVELOPS in the primary checkout. It hosts four things only: the
   runtime queue, the canonical `:8000` local venue (the operator's - see
   "The operator seat"), the untracked rollout config
   (`scripts/.subnet.conf`, `scripts/.cloud-engine.conf`, the API-key files),
   and merges performed under the merge lock. Consumers' only writes there
   are through `factory.sh` and that final merge; operator-directed
   development happens on the operator seat, not in the primary.
6. Every task is self-contained: a session with no memory of the conversation
   that produced it can act on it (a `docfile:` brief counts - it is tracked
   in every worktree). If it is not, it is not a task yet.
7. Follow-up work any session discovers is filed as a queue task - never a
   suggested-task chip, never a note in some doc.
8. Consumer seats never touch a remote target and never push - with ONE
   carve-out: the `merge-land` door's push of main to ORIGIN after a landing
   (the operator's standing directive of 2026-08-20: origin is the private
   repo and mirrors main continuously, "there is no point holding off
   ever"; the public mirror stays the operator's explicit act). Concretely
   out of bounds: `scripts/deploy.sh engine|subnet`, `deploy_to_engine.sh`,
   `deploy_to_subnet.sh`, `start_bots_*`/`stop_bots_*` for engine or subnet,
   `topup*.sh` against remote targets, anything that reads
   `scripts/.subnet.conf` or `scripts/.cloud-engine.conf`, and any `git push`
   other than that door's
   to ANY remote (origin and the public mirror are operator acts under the
   outward-batch policy). Live verification happens on the seat's OWN local
   venue. Remote rollout is a different trajectory with its own human-held
   auth - `icp` reauth is a web flow that WEDGES in a non-interactive
   session (piped output swallows its URL and the command parks forever),
   so a consumer that tries either blocks for hours or, worse, an expired
   delegation fakes success. When a task's remote part matters: do the
   local part, note the remote part as DEFERRED in the completion note, and
   file a follow-up task carrying `lane: operator`. Sole exception: the
   task text itself explicitly makes a remote deploy the deliverable - and
   such a task is operator-lane by construction.
9. Nobody edits a QUEUED task file in place - not even its producer. To
   change task content, own it first: consumers edit only their claimed
   files; the operator takes a specific task with
   `claim --operator --id <id>`, edits, and requeues. An in-place Write
   racing a claim recreates the moved file as a ghost duplicate of a task
   someone else now owns.
10. **`mdex-process-safety` is binding in every role.** No pattern kills
    (`pkill -f` took down the live subnet fleet three times), no `pgrep`-based
    waits (they match the waiting shell itself), kill only PIDs you captured
    or via the repo's `stop_bots_*` machinery, never leave an
    `icp network status` poll unattended without a kill-after watchdog, and
    EVERY `icp` invocation carries `--identity <name>` - never
    `icp identity default`, whose global state other sessions and connectors
    mutate mid-run. Read that skill before your first process or `icp`
    operation; it is short and it is the machine's #1 hazard list.
11. **The posture law.** A branch merges into main only on the committed
    defaults: `src/backend/main.mo` AND `src/bridge/main.mo` resolve to
    `#play` (read by `mdx_posture_of`, the one comment-aware reader), and
    `icp.yaml` carries no `port: 0` line. `factory.sh merge-lock acquire
    <branch>` enforces it mechanically. The seat-local `#dev` flip and the
    port-0 gateway edit are legitimate WORKING-TREE state (that is how a
    seat's venue runs); the law is what lets them exist without ever
    reaching main.

## Task file format

```markdown
---
producer: <who filed it: branch, "dominic", "audit-2026-08-17", ...>
class: security-high | security-medium | architecture | prerequisite |
       feature | hygiene | cosmetic | docs | parked   (advisory - the
       prioritizer's input; hygiene / cosmetic / parked also set the FILING band)
touches: backend, tests            (see the vocabulary below; "suite" = repo-wide)
docfile: docs/tasks/W4-23-clamp-amm-half-spread.md   (the tracked brief, when one exists)
after: 1785709403, 1785709404      (ids that must archive first)
split_from: 1785709400             (lineage, when split)
lane: operator                     (waiting on the operator - execution OR input)
band: 30                           (optional - the FILING band over the class
                                   default: hygiene 30, cosmetic 40, parked 90,
                                   else natural; `new --band NN` wins; the
                                   prioritizer may move it)
---
# <imperative title - what will have happened when this is done>

Goal, context, and exact pointers: paths, file:line, the shape of the change,
and HOW TO VERIFY (which suites, which gates, what to look at). Out-of-scope
notes if the edges are temptingly fuzzy. With a docfile: a one-paragraph gist
plus anything the brief lacks (the brief carries the details).

## Factory log        <- appended by factory.sh; never write this yourself
```

Only the `# title` line is mandatory (factory.sh refuses drafts without one);
`class` and `touches` should almost always be present, `docfile` whenever a
tracked brief exists, `after` whenever order matters, and `lane: operator`
whenever law 8 puts the work out of a consumer's reach. Fields are greppable
plain lines - keep them single-line, comma lists.

**`touches:` vocabulary** (the affinity and overlap currency - use these,
not ad hoc strings): `backend` (src/backend), `bridge` (src/bridge), `arb`
(src/arb), `archive` (ArchiveCanister + archive design), `frontend`
(src/frontend), `verifier` (scripts/verify_ledger.mjs + its fixtures),
`deploy` (scripts/), `tests` (tests/), `docs` (docs/), `candid`, and `suite`
for repo-wide waves.

`touches:` names the CODE SURFACES a task changes, not file paths, and both
halves of `claim` read it: the overlap defer (a queued task sharing a token
with another seat's active claim waits) and affinity. Repo-wide tokens never
gate a claim - `docs` and `README` by the engine's default
(`FACTORY_OVERLAP_IGNORE`, default `docs README`): nearly every task adds a
docs page and a shared docs tree is not where merge conflicts happen, so one
claim naming `docs` must not defer the whole prioritized head. List `docs`
alone only when the task is docs-only; a task that also changes code names
the code. A docs-only task KEEPS its tokens (the skip applies beside a code
token only, 2026-10-03): two docs-only tasks still defer each other, and one
waits behind a code claim that names `docs`. (`tests` is NOT in the default
ignore set, so it gates overlap here like any code token even though nearly
every task names it; widening the set to `docs README tests` is the
operator's call, exported in the seats' environment - the pre-engine
factory.sh's "tests carries no overlap signal" no longer holds by itself.)
When EVERYTHING eligible overlaps, `claim` falls back in GRADED order (task
1792508144): the first task whose only overlap is the suite rule - a
suite-wide claim over it, or its own `suite` token behind any claim - before
the first sharing a concrete token with another seat's claim; a DIRECT
collision is the last resort, never the plain head. The claim says which it
took on stderr - `factory: overlap fallback: suite-only (behind <seat>'s
<id>)` or `factory: overlap fallback: DIRECT - shares '<token>' with
<seat>'s <id>` - and appends the same words to the task's Factory log stamp
(`- claimed by <worker> at <instant> - overlap fallback: ...`), which the
board renders as **DIRECT-OVERLAP** on the active-claims row. (Before
2026-10-20 one soft slot held the plain head, so a suite-wide claim - hours,
for a repo-wide wave - collapsed the gate: every task overlapped, and the
head handed out was the one sharing two concrete tokens with another seat's
claim while two tasks free of every token sat behind it.) Band precedence
beats the soft defer (task 1792540242): a suite-wide task in a STRICTLY
higher band than every free candidate is claimed over them even while other
seats hold claims - `suite` is the task's nature, not information about a
collision, and the prioritizer's band is the ruling - with the claim saying
so (`factory: overlap fallback: suite-only (band 03 outranks the free band
30; behind <seat>'s <id>)`, the same words on the stamp); equal bands keep
the free task. A DIRECT candidate gains it ONLY from an expedited band
(00-09; task 1792553976): a task there sharing a concrete token with a
live claim, in a STRICTLY higher (lower-numbered) band than the pick in
hand - the free head, the affinity pick, the suite-precedence pick, or the
suite-only fallback when nothing is free - is the claim, and it says so:
`factory: overlap fallback: DIRECT - shares '<token>' with <seat>'s <id>
(band 05 outranks the free band 30)` (the same words on the stamp; still a
DIRECT stamp, so the board still marks the row **DIRECT-OVERLAP**) - the
expedite lever is the ruling, the rebase is the cost, the stamp keeps the
collision visible. Equal bands keep the pick in hand, and the band ORDER
rules inside the zone too: a band-05 fix still waits behind free band-03
work (band it 00-02 to go ahead of that); from band 10 up a concrete
collision stays the last resort. (On 2026-10-21 upstream's band-05 fix for
a red gate sat deferred behind free band-30 work while four promotions held
the very gate script each would meet at its last verify step.)

## Priority bands

The prioritizer expresses policy by renaming into bands: new priority =
`BB * 10^8 + (id mod 10^8)` - `factory.sh reprioritize <id> <BB>` computes
this - which preserves FIFO order among tasks in the same band.

| Band | Meaning |
|------|---------|
| 00 | emergency - drop everything (operator-directed, mostly) - claimed even over a concrete token collision with a live claim (the expedited DIRECT precedence, task 1792553976) |
| 01 | security high - live venue / pipeline safety (the W1 shape) |
| 02 | security medium - tape & verifier integrity, #production hardening (W2/W3 shapes) |
| 03 | architecture / doctrine changes that would force rework of tasks landing after them |
| 04 | prerequisites - tasks other queued tasks name in `after:` |
| 05-09 | expedited, prioritizer's discretion - like the whole 00-09 zone, claimed over FREE lower-band work even when it shares a token with a live claim (a rebase is the cost; from band 10 up the collision defers) |
| 17-21 | the natural zone: untouched creation keys (epoch seconds land here through 2036) = plain FIFO - where `new` files every class but hygiene / cosmetic / parked (task 1792609968) |
| 30 | hygiene, gate/instrument debt, low-severity findings (the W5 shape) - `class: hygiene` FILES here by default (task 1792609968) |
| 40 | nice-to-have, cosmetic, docs polish - `class: cosmetic` FILES here by default |
| 90 | parked - claim only when nothing else remains - `class: parked` FILES here by default |

Rationale in one breath: security before features so it is baked in, not
bolted on; the tape and the verifier are REQUIREMENTS under the transparency
doctrine, not features - rank them accordingly; architecture before the work
it would rework; prerequisites before their dependents; everything else FIFO.

Band 90 is not a way to say "never": it delays a claim, it does not refuse
one. Work a consumer must NOT run belongs in the operator lane
(`lane: operator`), a separate axis - a task can be band 01 and operator-lane
at once.

**The filing band (task 1792609968, 2026-10-21).** `factory.sh new` bands a
filing by its `class:` line: hygiene -> 30, cosmetic -> 40, parked -> 90;
every other class (feature, security-*, architecture, prerequisite, docs,
...) and a draft with no class file at the natural band as before. Only the
DEMOTING defaults are automatic - every promotion stays the prioritizer's
judgment (a producer's self-declared `security-high` must not jump the queue
unreviewed). A `band: NN` front-matter line or `new --band NN` (the flag
wins) overrides the default - the producer's explicit call, normally the
prioritizer's or the operator's lever when filing directly. The prioritizer
reviews every filing and may move it (`reprioritize`): this is the FILING
default, never a ruling. stdout stays the queue path; a banded filing adds
one stderr line, `factory: new: filed at band NN (<why>) - the prioritizer
reviews every filing and may move it`. Why: the prioritizer's pass is
event-driven, so a hygiene task filed at the natural band was the queue HEAD
for the seconds-to-minutes until the pass ran - upstream, on 2026-10-21, a
seat claimed one 41 s after it was filed, ahead of 27 banded hygiene tasks,
and ~45 hygiene filings were rebanded by hand that day.

Bands 00-09 are also the claim loop's EXPEDITED zone (task 1792553976): a
task there that shares a concrete token with a live claim is still claimed
over free work in a strictly lower band - stamped `DIRECT - shares '<token>'
with <seat>'s <id> (band NN outranks the free band MM)` - where a task from
band 10 up defers until nothing else is free. The band ORDER rules inside
the zone (03 outranks 05), so a fix that must go ahead of free band-03 work
is banded 00-02.

## Role: TaskProducer

1. Collect the work: the operator's instruction, an audit round, community
   issues, or existing findings. One task per independently completable item.
2. Dedupe first: `scripts/factory.sh list`, the board
   (`tasks/factory/index.md`), a grep of `tasks/archive/`, AND the corpus -
   `docs/tasks/README.md`'s queue table plus `docs/tasks/done/`. Extend or
   skip rather than duplicate; the "Already resolved - do not redo" table in
   the README exists because reporters re-report fixed things.
3. Author to the current corpus standard. Substantial work gets a W-style
   brief in `docs/tasks/` exactly as today (verified against the working
   tree by symbol lookup, citations, the how-to-verify section, pushback
   recorded where a reporter is wrong) and a THIN queue task pointing at it
   via `docfile:`. Small self-contained items inline everything in the queue
   task. Either way the self-containedness bar is law 6, and sources are
   cited (file:line, issue numbers, commit shas). `touches:` names the code
   surfaces the task changes (the vocabulary above); `docs` alone never
   gates a claim and belongs there only when the task is docs-only.
4. `scripts/factory.sh new <draft>` - it allocates the id and prints the
   queue path. Draft in your scratchpad; the draft file stays where it was,
   inert. (New briefs in `docs/tasks/` are ordinary tracked edits - commit
   them through the normal branch flow, not by writing into the primary.)
   **File in dependency order**: an `after:` id must be one `new` has
   ALREADY printed (every filing prints its id) - never a guessed or
   predicted one. `new` refuses a draft whose `after:` names an id that
   was never minted, because a nonexistent gate gates nothing: `claim`
   treats unknown ids as satisfied (live-ids-only, deliberately - in the
   open-saas factory five guessed-id gates once let four "sequential"
   tasks run concurrently). File prerequisites first, then the dependents
   citing the printed ids. A follow-up that builds on code a task YOU hold
   has not yet merged carries `after: <your task id>`: `new` WARNS on stderr
   when the draft cites a claim you hold and its `after:` does not name it,
   and never adds the line silently - a bug found in passing is often
   independent of the parent (task 1792508238).
5. Report the filed ids/titles (`new` prints the queue path; a banded
   filing adds one stderr line naming the band). Do not set priorities -
   that is the prioritizer's job; your `class:` field is its input, and
   since task 1792609968 it is also the FILING band: `class: hygiene` files
   at 30, `cosmetic` at 40, `parked` at 90, every other class at the natural
   band (the demoting defaults only). The prioritizer reviews every filing
   and may move it. `band: NN` / `new --band NN` are the explicit override -
   the prioritizer's or the operator's lever when filing directly, not a
   producer's guess. (Genuine emergencies: say so to the operator rather
   than guessing a band.)

Set `lane: operator` on anything a consumer seat is forbidden to execute -
engine/subnet rollouts, pushes, anything needing human-held auth or a
decision only Dominic can make. That is a statement of fact about the work,
not a priority call, so it IS yours to set. Leaving it off does not merely
mis-sort the task: seats will claim it, discover they must not act, and
requeue it, indefinitely.

**Seeding the queue from the corpus:** the standing instruction "work the
docs/tasks queue" translates to one thin `docfile:` task per open row of
`docs/tasks/README.md`, skipping rows marked IN FLIGHT in another session,
with `after:` wiring where a brief names an ordering. Do this once at factory
boot and again whenever a new triage round lands in the corpus.

## Role: TaskPrioritizer (exactly one session)

Loop forever: **wake -> triage -> reorder -> board -> janitor -> re-arm** -
and keep this skill fresh MECHANICALLY, not by feel: every pass, stat the
primary copy
(`stat -f %m <primary>/.claude/skills/mdex-software-factory/SKILL.md` - one
token-free shell call, foldable into the same Bash call as your watch);
RE-READ the file whenever that mtime moved past your last read, and in any
case at least once an hour. The mtime gate means a protocol change reaches
you within one pass; the hourly floor exists because even an unchanged skill
needs occasional re-reading - summarization quietly erodes the copy in your
context.

**Booted by `scripts/factory.sh prioritizer-boot`** (the standard boot since
task 1792506027 - the fleet doctor's respawn uses the same door, so this is
how a revived prioritizer arrives)? **Your FIRST act is `scripts/factory.sh
handoff-clear prioritizer`.** The command wrote your boot prompt to the
token `tasks/handoff/prioritizer.md`, and while that file stands
`handoff-list` and the board's **Seats awaiting successor** list
`prioritizer` as unmanned; clearing it is your ack, exactly as a seat's
successor clears its own handoff file (it also spends a spawn-pending
stamp). Then the loop.

- **Wake**: `scripts/factory.sh watch 3300` in the FOREGROUND, with the Bash
  tool's timeout set to 3600000 ms, blocks until queue/claimed/archive/signal
  change (prints CHANGED) or 55 min pass (TIMEOUT) - act on either, then
  re-arm. A filed task, a claim, an archive move or a signal wakes you within
  10 s either way; the timer is only the belt, and the hourly janitor items
  below ride its TIMEOUT wake. **Every wake is a full-context model turn** -
  at `watch 500` (upstream's 2026-09-07..24 setting) the idle fleet made ~50
  no-op API calls an hour, each re-reading a few hundred thousand cached
  tokens, for zero work - so the idle floor is an HOUR, never minutes, and
  the wake-and-re-arm is ONE Bash call (`watch 3300 2>&1 | tail -3; stat
  ...`) with no probes or narration between wakes. The hour needs the boot
  environment (`factory.sh boot-env` raises the harness's Bash cap to
  3600000 ms - `prioritizer-boot` applies it); a session booted without it
  is clamped to the old cadence by `watch` itself, which says so on stderr -
  respawn it on the boot line. Never a background `watch` as the last act of
  a turn: a lost completion parks you (executor mode, the 2026-09-03 sweep).
- **Triage**: `factory.sh list`; read (`factory.sh show <id>`) tasks you have
  not seen before (the board is your memory of what you have triaged). Judge
  class and content per the band table (a `class: hygiene` / `cosmetic` /
  `parked` filing already sits at 30 / 40 / 90 - `new` bands by class since
  task 1792609968; review it there, move it only when wrong) - and check
  `after:` chains: a dependent must sort behind its prerequisites (band 04
  the prerequisites forward rather than parking the dependent, when both
  matter).
- **Reorder**: `factory.sh reprioritize <id> <band>`. If it errors, the task
  was claimed mid-rename - that is fine, drop it. Do not churn: rename only
  when the current position is actually wrong.
- **Rank bands, not tasks - keep the head band BROAD.** A band is a statement
  that its members are equally important, and that interchangeability is what
  consumer affinity (`claim --affinity`) converts into warm-context
  throughput: a seat may take any same-band task it knows the ground for,
  never anything past the band. A head band holding one task disables
  affinity exactly where most claims happen. So when you promote several
  tasks of comparable urgency, put them in the SAME band (within-band FIFO is
  preserved by the formula); split finer only when one genuinely must precede
  another - and a true must-precede is usually an `after:` dependency, not a
  band distinction. And banding a suite-wide wave ABOVE the natural zone is
  what makes it run on a busy fleet: a `suite` task overlaps every active
  claim by its nature, so the claim defers it while any same-or-lower-band
  task is free, and only a strictly higher band (03 for an operator-ruled
  wave) outranks that defer (task 1792540242) - left in the natural zone it
  waits for an empty fleet that never comes. The same lever covers a
  CONCRETE collision from the expedited zone (task 1792553976): a band 00-09
  task sharing a token with a live claim - a red-gate fix beside the tasks
  holding that gate's script - is claimed over free lower-band work, stamped
  DIRECT-OVERLAP with the band words, so it no longer needs an empty fleet
  either. Band it ABOVE the free work it must beat (the band order rules
  inside the zone: 05 still waits behind free 03 - 00-02 goes ahead of it),
  and name the collision in your pass summary as you would any DIRECT claim.
- **Board**: `factory.sh index` regenerates `tasks/factory/index.md` - the
  operator's one-glance view. Refresh it every pass. Its **Seats awaiting
  successor** section lists `tasks/handoff/` - seats that handed off and are
  sitting unmanned. Call any entry older than an hour out in your pass
  summary: a shrinking fleet is invisible otherwise (a CLI seat's
  self-spawn can fail; a desktop chip can die with an app restart). Its
  **Operator signals** section lists unacknowledged orders - each line is a
  seat that CANNOT claim until it acknowledges, so an old entry means a
  stopped or dead seat: call those out too. Direct-overlap claims (task
  1792508144): a claim whose Factory log stamp reads `overlap fallback:
  DIRECT - shares '<token>' with <seat>'s <id>` - with a trailing `(band NN
  outranks the free band MM)` when the expedited precedence took the
  collision on purpose (task 1792553976; the same row, the same duty) - the
  board marks its row **DIRECT-OVERLAP** - is editing a surface another live
  claim names: a merge-conflict risk, not a fault. Name both claims and the
  shared token in your pass summary (the later merger resolves the conflict;
  a seat that knows it collides merges small and early) and never requeue
  either (law 3).
- **Janitor**: the index marks claims idle >4h as STALE. Investigate liveness
  read-only (is the worktree still there? recent commits?
  `git -C <worktree> log --oneline main..`), REPORT on the board via your
  pass summary, but do not requeue (law 3). ONE exception the operator has
  standing approval to act on, and which you should therefore state plainly
  rather than merely flag: a claim whose seat has been silent for HOURS
  **and** whose worktree hosts no live session (no recent writes, no
  successor Terminal, no handoff file being worked) is requeue-eligible even
  mid-band - an app quit kills desktop sessions MID-TURN and such claims
  strand their tasks for many hours. Say which claims qualify and why; the
  requeue itself is still the operator's call, and its note must say what
  partial work sits on the seat's branch so the next claimant does not redo
  it. Also `factory.sh merge-lock status`: a wedged lock older than 30 min
  will be broken by the next acquirer automatically; mention it.
  Fleet liveness: once a pass, `scripts/factory.sh fleet-doctor` (read-only
  in its default report mode) and put every STALLED / UNMANNED / ORPHANED /
  LOGGED-OUT line in your pass summary - a seat silent 65 min (the doctor's
  default bar; the idle watch sleeps 55) with claimable work is dead, not
  idle; the operator revives it (or the launchd job does, once respawn is
  opted in). An ORPHANED line (a roster seat whose worktree is GONE; the
  summary reads `FLEET-DEGRADED n missing of N`) is never self-healed:
  relay it verbatim - it names the first pass that saw the tree missing and
  the remedy pair (`seat-recreate` / `seat-retire`, both operator commands)
  - so a shrinking fleet is on the board the pass it happens, not days
  later (upstream's seat-7 and seat-14 vanished unnoticed in September 2026
  while the summary kept reading FLEET-OK). A `FLEET-LOGGED-OUT` summary
  means the CLI login expired for every seat at once - one login heals the
  fleet (executor mode, "CLI login expiry"); say so first in the summary,
  nothing else moves until then. Replica footprints:
  `scripts/replica-doctor.sh --rss-all` is the machine-wide sweep for the
  board - you observe and report, never stop one (the seats retire their
  own through `replica-recycle`). And title
  hygiene: retitle any fleet session whose title has drifted from this
  skill's conventions (a consumer still wearing a boot auto-title, a
  spare never cross-titled) - you may rename every session except your
  own (cross-titling, in the warm-spare pool section), and this sweep
  is what keeps the resume fan-out's title match honest.
- **Resume fan-out**: when the operator reports a harness restart, nudge
  every fleet session (titles matching `MULTI/DEX worker — *`, plus the
  legacy `MULTI/DEX — worker started *` until the fleet rolls over) via
  the session-management tools (list_sessions + send_message, where the
  harness offers them): "Harness restarted - re-read the skill and follow
  its restart checklist, then continue." Report any session you could not
  reach so the operator nudges it by hand; then resume your own loop.
  (CLI executor seats survive app restarts and usually need no nudge -
  their dead watchers re-invoke them; the fan-out is the safety net.)
- You never edit task files, never claim, never merge, never touch git
  beyond the janitor's read-only look (law 4).

## Role: OperatorTasks (the operator's console; run with the operator present)

One session, on demand, on the OPERATOR SEAT or in the primary checkout
(`--operator` claims are allowed from both). It turns the operator lane into
an interactive inbox: what is waiting on the operator, answered in
conversation, resolved in the queue. It ends when the inbox is clear - a
standing session adds nothing, since every resolution needs the operator
anyway.

1. **Inbox**: `scripts/factory.sh list --operator`, then `show <id>` each.
   Present a numbered digest - per task: what it is, the EXACT question or
   action needed, and what it unblocks (grep the queue for `after:` citing
   its id; more dependents = present it earlier).
2. **Discuss**: the operator answers, decides, or performs auth steps in
   chat. Push back on ambiguity: once embedded, the answer must meet the
   self-containedness bar (law 6) - the eventual consumer has no access to
   this conversation.
3. **Resolve, per shape**:
   - INPUT task (needs an answer): `factory.sh claim --operator --id <id>`,
     then edit the file you now own - replace `## Needs from operator` with
     `## Operator answer (<date>)` recording the decision verbatim, and
     DELETE the `lane: operator` line. `factory.sh requeue <id> [band]`
     returns it to the consumer queue with the answer riding in the file.
   - EXECUTION task (engine/subnet rollout, a push): keep the lane; execute
     it here and now with the operator present for auth - from the PRIMARY
     checkout on merged main, foregrounded so the `icp` reauth URL is
     visible, and DECLARED as the operator's direct round (`FACTORY_DIRECT=1
     scripts/deploy.sh engine|subnet ...`, or `export FACTORY_WORKER=operator`
     - or `claude-operator`, the operator seat's own spelling; the two are
     one principal to every guard, "The operator seat" - for the session:
     the no-identity belt, Operator guide, reads an undeclared primary
     commit as a drifted executor while seats are pinned) - then
     `factory.sh done <id> done "<what ran, where>"`.
   - Obsolete / answered elsewhere: `claim --operator --id <id>` then
     `done <id> superseded "why"`.
4. Law 9 always: never edit a queued file in place - claim-edit-requeue is
   the only safe edit. Never touch consumer ordering beyond the requeue
   band hint; the prioritizer owns the queue order. New work the discussion
   surfaces is filed via the producer procedure, not bolted onto existing
   tasks.

## Role: TaskConsumer

**The worker doctrine (adopted 2026-08-20 from the open-saas factory's
2026-08-19 operator decision): workers are CLI sessions running EXECUTOR
MODE - always.** Boot workers with
the claude CLI in a Terminal (never as desktop-app sessions - the desktop is
the OPERATOR's surface), and always in executor mode (below; no longer a
variant). Why: CLI seats survive desktop-app restarts (upstream lost its
whole fleet twice to app restarts killing desktop workers mid-turn), the
whole lifecycle is scriptable (boot loop, spawn-successor, signal files - no
chips, no clicks, no message-delivery uncertainty), and executor seats stay
clean for hundreds of cycles. Session names carry the PROJECT PREFIX:
`<prefix>-executor-<seat>` (non-executor boots: `<prefix>-worker-<seat>`),
where `<prefix>` is `FACTORY_PROJECT` if set, else the primary checkout's
directory basename with any `-ng`/`-main` suffix dropped - here `multidex`
-> `multidex`, so `multidex-executor-<seat>`. Derived, never hardcoded, so
forks inherit correct names for free; several projects run this factory
pattern on one machine (open-saas among them), and the prefix is what keeps
`claude --resume` pickers and process listings unambiguous.
`spawn-successor` mints it automatically; operator hand-boots pass the same
`--name` shape. Existing sessions are never force-renamed - they converge at
their next handoff. Chips and message-activated warm spares are desktop-era
mechanisms: RETIRED for workers (the sections below remain for the
operator's desktop surfaces and the transition).

**Setup once**: work in your own git worktree on a `claude/<name>` branch -
never in the primary checkout (law 5). If you were started in the primary
checkout, create a worktree first - UNDER THE SEAT ROOT:

```
git worktree add "$(scripts/factory.sh seat-root <name>)" -b claude/<name> main
```

(the harness's EnterWorktree mints under the desktop app's pool root
instead - the legacy location below - so use the command; keep the
`"$(...)"` quoting, the path is used verbatim and a path with a space in it
must survive). Your worker identity is your branch name with `/` flattened
to `-`.

**Where a seat lives: `<primary>/.factory/seats/<seat>` - the seat root**
(`factory.sh seat-root [seat]` prints it; gitignored, created on demand;
task 1789581979, 2026-09-16). NOT `.claude/worktrees/`: that directory is
the Claude DESKTOP APP's own worktree pool root, and the app's WorktreePool
runs an "untracked-dir GC" over it every 30 minutes
(`~/Library/Logs/Claude/main.log`, grep `untracked-dir GC`) that `git
worktree remove --force`s any subdirectory no app session made once it is
past a minimum age, a registered worktree, clean and quiet - logged as
`[reapUntrackedWorktreeDir] Removed untracked worktree dir <path>`. That is
what took upstream's seat-7 (2026-09-06, 09-12) and seat-14 (09-08, 09-13):
a CLI seat is untracked by construction, and an idle seat is exactly clean +
quiet. The verdict order, read from the app bundle
(`reapUntrackedWorktreeDir`, `Claude.app/Contents/Resources/app.asar`):
`keep-sentinel` (a `.worktree-keep` file at the worktree root), `locked`
(`git worktree lock`), `recently-active` (the newest mtime of the worktree
DIRECTORY itself, its `.git` pointer file, and the git admin dir's `index`
+ `HEAD` within 24 h - a file written INSIDE the tree, `.factory-heartbeat`
included, moves none of those, so an idle loop "touching a marker" is NOT
a belt), `foreign-parent` (the parent dir is not the pool root),
`not-clean`, then removal. Hence:

- NEW seats and `seat-recreate` mint under the seat root: the GC never
  enumerates it (its scan roots are the app's own pool dirs) and would
  answer `foreign-parent` if it did - safe by construction, not by luck.
- EXISTING seats stay where they are until their next natural retirement.
  A live seat is NEVER moved under a running venue (the network state dir,
  the locks and the port-0 `icp.yaml` edit are path-bound) - not by the
  operator, not by itself. A seat under `.claude/worktrees/` is a LEGACY
  location the app may GC when idle: `fleet-doctor` tags its line
  `legacy-location`, `worker-pin` says so on stderr, and its `seat-recreate`
  (after the tree is gone) rebuilds it under the seat root - same branch,
  same pin.
- The BELT for a legacy seat until then: `worker-pin`, `handoff-clear` and
  EVERY `fleet-doctor` pass drop `.worktree-keep` (gitignored) into each
  pinned seat, which the GC honours BEFORE any age or clean check - no
  idle-loop touching, no compliance needed; the doctor's 15-minute cadence
  converges a running fleet on its own. To be sure right now:
  `scripts/factory.sh worker-pin` once more from the seat.
- A PINNED worktree IS a seat, wherever it lives: the doctor adopts it on
  its next pass and the operator's respawn job boots a session into it
  within 15 minutes (upstream, 2026-09-16: a throwaway `gc-probe` seat
  pinned for a drill was booted by the job and claimed a real task two
  minutes before the probe was retired). Exercise factory.sh against a
  throwaway tree under `FACTORY_TASKS_ROOT` (the selftest's way), or retire
  a real-roster probe within minutes of pinning it - never leave one
  standing. (The one pinned tree the doctor passes over is the operator
  seat's - pin `operator` or `claude-operator`, or basename `operator` -
  by its overlay skip; "The operator seat", below.)

**PIN IT ONCE, as your first act on the seat:**

```
cd <your-worktree> && scripts/factory.sh worker-pin
```

**If that first command refuses `DUPLICATE-SESSION: <pid> already runs
this seat - exit now`, you are the EXTRA boot: exit this claude process
now - never claim, never edit, never `FACTORY_FORCE` past it.** A spawn
whose Terminal AppleEvent timed out is not dead: Terminal queues the event
and may run it hours later, beside the session that meanwhile took the seat
(upstream, 2026-09-16: fifteen timed-out doctor passes booted NINE sessions
onto one seat within seconds; they claimed under one identity and two
executors edited the same worktree at once - task 1789588684). `worker-pin`
and `claim` therefore refuse while ANOTHER live process carries this
session's `--name` and is OLDER than yours (your own process tree is exempt,
and a predecessor still exiting after its own spawn is re-checked after a
5 s grace, so a normal succession never trips it). The older session keeps
the seat; the refusal names its pid. Say one line (`DUPLICATE-SESSION -
exiting`) and end the process the way the succession step does (kill your
nearest `claude` ancestor) - nothing else: the seat is manned, its handoff
file is that session's to clear.

That writes `<worktree-root>/.factory-worker` (one line, the flattened
branch; gitignored runtime state). Every later `claim`/`requeue`/`done` run
from ANYWHERE inside that tree - executor subagents included, since they run
inside it by construction - then resolves the seat's own name instead of
deriving one from whatever branch the cwd happens to sit on. Derivation from
the cwd is what mints wrong-worker claims (upstream: twice in one hour on
2026-08-04; again on 2026-08-19 from a drifted executor subagent), each
costing a requeue + re-claim bounce, and leaving the board and
`tasks/claimed/` lying about who holds what in between. Belt and braces for
commands that may run OUTSIDE your worktree (harness-BACKGROUNDED ones
inherit the harness's DEFAULT cwd, which can be another seat entirely):
pass the worker explicitly (`factory.sh claim <worker>`) or export
`FACTORY_WORKER=<worker>` on the command. Precedence is explicit arg >
`FACTORY_WORKER` > the `.factory-worker` pin > cwd branch; claim prints the
effective worker on stderr (`factory: worker: <name>`) - check it in every
claim's output - and WARNS whenever the pin and the name actually used
disagree, which is drift caught in the act. `factory.sh worker` prints what
the current directory resolves to and why. (requeue/done locate your claimed
file by id across all workers, so they are cwd-proof; with a pin present they
also warn if the claim you are closing belongs to another seat.)
If your harness offers session titling (`set_session_title`), title this
session `MULTI/DEX worker — <seat> — <UTC datetime>` where `<seat>` is your
worktree's basename (`seat-1`, `seat-2`, ...; legacy adjective-named
worktrees use that basename) and the timestamp is
`date -u '+%Y-%m-%d %H:%M'`. Seat-first titles make the operator's session
list scannable by seat, and successive sessions on one seat share a prefix -
honest start times tell them apart. Handoff successors overwrite any staged
chip title this way too. Some harnesses REFUSE to rename the calling
session (Claude Desktop does): when self-titling errors, read your own id
from `$CLAUDE_CODE_HOST_SESSION_ID` and have another fleet session apply
the exact title for you - the cross-titling procedure, in "The warm-spare
pool" below. Never block on a title: keep working and let the fleet
converge on it. (CLI seats booted with `--name` already list unambiguously;
the title is the desktop-facing half.)

### Seat venue - bring-up (once per seat)

Your worktree runs its OWN local venue, fully isolated from the primary's
:8000 venue, from other seats, and from the machine's global icp identity
store. The recipe, in order, from the worktree root:

1. **Isolated icp store**: `export ICP_HOME="$PWD/.icp-home"` - and export
   it in EVERY shell that runs `icp` or any script (children inherit it;
   a call without it acts on the GLOBAL store, whose ~300 identities also
   risk the CMC mint-cap abort at network start). Create the identities the
   suites use: `icp identity new alice --storage plaintext` (and `bob`,
   `charlie` when a task's suites need them). The fresh store contains only
   `anonymous`, which locally IS a controller - that is expected.
2. **Own gateway port**: in the worktree's `icp.yaml`, give the local
   network `gateway: { port: 0 }` (the OS picks a free port). This edit
   stays UNCOMMITTED for the seat's whole life - commit by explicit paths
   (never `git add .` / `-a`), and the posture law refuses the merge if it
   ever reaches a commit. Never point at `:8000`: that port is
   machine-global, first-come, and is normally the primary's live venue.
   The signature "Error: the local network for this project is not running"
   while `curl 127.0.0.1:8000/api/v2/status` succeeds means :8000 is
   SOMEONE ELSE'S gateway and your own master is dead or never started -
   never "fix" strays there.
3. **Build prerequisites**: `mops install`, then
   `mops generate candid backend` - `src/backend/backend.did` is a
   gitignored intermediate, absent in a fresh worktree, and `icp deploy`
   fails its Candid compatibility check without it.
4. **Start the network**: overlapping `icp network start`s wedge on a loaded
   machine, so before your FIRST start (or any start after a stop) check
   `pgrep -f "icp network start"` and wait for in-flight starts to clear
   (healthy starts take ~20s) - this is the ONE machine-wide wait in the
   whole protocol. Then `icp network start --background` and watchdog your
   own start - but tell QUEUED from WEDGED first: a start whose native icp
   is alive with NO launcher yet while another seat's `icp deploy` holds
   icp-cli's global locks is QUEUED, not wedged - it waits the deploy out,
   and the ~90s wedge clock runs only once the launcher exists or the locks
   are free (task 1790977573; upstream killed one seat's healthy start
   seven times that way on 2026-10-02). Only then does no port descriptor
   within ~90s mean wedged - kill both
   halves of YOUR start (captured PIDs, never a pattern), remove your
   worktree's network lock, retry. Diagnose with the start doctor before
   touching anything: `bash scripts/replica-doctor.sh --start-wedge $PWD`
   (read-only, no icp calls) prints `HEALTHY`, `STARTING (<n>s)`, `WEDGED
   (launcher parked, port file unread)` with the PIDs to kill, or `NO
   LAUNCHER` (your start's process group died with a timed-out harness
   call - relaunch with `nohup icp network start --background > <log>
   2>&1 &` in a SHORT call and check `icp network status` in a separate
   one). `WEDGED` twice in a row is NOT a transient (2026-09-05: five
   identical wedges on one seat) - stop retrying and escalate to the
   operator (HUMAN NEEDED); signature, recipe and root cause in
   `docs/seat-venue-bring-up.md`.
5. **Deploy + seed on #dev**: flip `DEPLOY_MODE` to `#dev` in BOTH
   `src/backend/main.mo` AND `src/bridge/main.mo` - by PATTERN, never by
   line number: `perl -pi -e 's/^(\s*transient let DEPLOY_MODE : DeployMode = )#play;/$1#dev;/' src/backend/main.mo src/bridge/main.mo`
   - run `bash scripts/cold_start.sh --mode full --no-simulate`, then
   RESTORE `#play` in BOTH files immediately (see the posture rhythm
   below). The Bridge carries its own literal and its dev hooks gate on
   it; a one-file flip is not refused, but cold_start prints a loud
   `✗ BRIDGE POSTURE LAG` note and the Bridge dev-hook suite sections skip.
   `--no-simulate` is non-negotiable on a seat: sim bots crash the local
   pocket-ic master silently within minutes, and N seats running fleets
   would flatten the machine besides. cold_start's stray-master reaper
   resolves ownership via `icp network status` (worktree-safe by
   construction since W1-06); if it nonetheless kills your OWN master,
   stop and re-verify rather than editing the reaper.
   The canonical **#play bring-up is runnable on a seat too** (since task
   1788479256): with the tree at `#play` (play mode REFUSES a `#dev`
   tree), `bash scripts/deploy.sh local --seed --no-simulate` runs
   cold_start in play mode, which forwards the explicit `--no-simulate`
   to play_start.sh as `MDX_NO_SIMULATE=1` - the seeded AMM vault,
   insurance fund, maker ladder and arb come up, any recorded local fleet
   is stopped, and NO fleet is started (play_start warns "fleet NOT
   started"; confirm `.run/bots-local.pid` is absent). Use it when a task
   must verify play_start's gates. It REINSTALLS backend + bridge and
   leaves the venue on `#play`, so afterwards reseed under the flip
   (`--mode full --no-simulate`, as above) to return it to `#dev` for the
   suites.
6. **Trust, then verify the controllers**: cold_start's "✓ alice promoted"
   line can lie (the settings update is `||`-swallowed). Before running
   anything, confirm
   `icp canister status backend --identity anonymous | grep Controllers`
   lists `2vxsx-fae`. If not:
   `icp canister settings update backend --add-controller 2vxsx-fae --force --identity alice`.

**The posture rhythm** - the venue runs `#dev`, the tree stays `#play`: the
integration suite requires `#dev`-gated hooks (`setAmmRefPrice` and friends
trap on `#play` by design), so every DEPLOY to your venue happens with the
flip in place - flip `#play -> #dev` in BOTH `src/backend/main.mo` AND
`src/bridge/main.mo` (the Bridge carries its OWN `DEPLOY_MODE` literal;
`devTestStrandAdmission` / `devTestHoldAdmission` gate on it), by the
pattern in step 5, `bash scripts/deploy.sh local` (or the cold_start
above), restore `#play` in BOTH files the moment the deploy finishes. A
one-file flip (DEX `#dev`, Bridge `#play`) is legal under W3-09 - the
Bridge may be LESS permissive than the DEX, never more - so it is not
refused, but `cold_start` / `deploy.sh local` print a loud `✗ BRIDGE
POSTURE LAG` note (from the tree before the build, from the live
`getDeployMode` answers in the banner) and `test_bridge_deposit_claim`
§14-15, `test_bridge_write_ahead` §1-2, `test_season_wipe_fence` §1-2 skip
on that venue. Never let the flip sit in the tree between deploys: a
lingering flip turns `git merge main` into a conflict magnet on main.mo and
a slip away from committing `#dev` - which the merge gate would refuse (it
reads both files), at the cost of a redo. A wall of red on suites whose
fixtures fail at setup is the posture signature: check
`echo y | icp canister call backend getDeployMode '()' --query --identity anonymous`
(and the same on `bridge`) before blaming your change.

**Never stop your replica while you idle.** `icp network stop`/`start` does
NOT resume state - a restart comes up freshly seeded with no canisters, and
the only restore is a full cold_start + reseed (minutes). The cheap idle is
the replica you never stopped. Stop it only when RETIRING the seat (wind-up)
or when the operator asks for machine headroom - and budget the re-bring-up.
The stop is ALWAYS `scripts/factory.sh replica-recycle` from the worktree
(the allowlisted door - it rides the `scripts/factory.sh *` row, resolves
the worktree from your seat pin, refuses the primary with no override, runs
the sanctioned `icp network stop` under a kill-after watchdog, then kills
ONLY the pocket-ic/launcher processes lsof-attributed to YOUR network state
dir when the launcher is already dead - the ZOMBIE shape the raw stop leaves
behind: launcher dead, tree alive, status answering - removes the
per-worktree network lock and a descriptor nobody serves, and prints
RECYCLED | RECYCLED-ZOMBIE | NOTHING-RUNNING; `--dry-run` shows the
attribution first). Never the raw `icp network stop` from a seat: an
auto-mode seat is DENIED it by the harness classifier (upstream's seat-2 sat
through fourteen executor restarts on one dead replica that way,
2026-09-01/02), and the raw stop even reports "stopped successfully" on the
zombie while the orphan main lives on.

**...but RECYCLE it when it grows fat (the replica recycle budget; ported
2026-09-01 from open-saas 2594cf507).** Seat replicas ratchet upward with
deploy/seed/suite churn - upstream's fleet quietly grew five 4-10GB replicas
at once (2026-08-28), and this machine hosts live fleets besides. The
budget: process-tree footprint (resident+compressed) over
`REPLICA_RSS_BUDGET_GB` (default 3GB), or oldest main past
`REPLICA_MAX_AGE_HOURS` (default 48h - the AGE BELT, so a metric gap can
never disable recycling). Check any time with
`bash scripts/replica-doctor.sh --rss <your-worktree>` (read-only ps/lsof/top
attribution by state-dir - the `.icp/cache/networks` path plus the seat's
`.icp-home` launcher path; NO icp calls, so it can never wedge; exit 3 =
recycle; `--rss-all` sweeps the whole machine for the prioritizer's board).
The budget is SELF-ENFORCING: `factory.sh claim` runs the same attribution
against the claiming seat's own worktree and REFUSES with `RECYCLE-REQUIRED
(<footprint>MB, age <age>): scripts/factory.sh replica-recycle from
<worktree>, then re-claim` while the replica is over budget or past the
belt - the signal-gate shape
(FACTORY_FORCE=1 overrides; operator claims exempt; fail-open by
construction, so a broken measurement - no doctor, an unattributable
worktree, a doctor error - passes the claim with a logged skip note and
never blocks the fleet). Recycling a seat venue is the FULL re-bring-up:
`scripts/factory.sh replica-recycle` from the worktree root (ICP_HOME
exported - the door above; never a raw `icp network stop`), then
cold_start per the posture rhythm - budget the minutes, and prefer recycling
at a task boundary you chose over the refusal choosing one for you. Checking
your own footprint before going idle remains the polite path: a seat that
recycles on its own schedule never sees the refusal.

**Loop** - and every cycle STARTS by re-reading this skill from the PRIMARY
checkout (`<primary>/.claude/skills/mdex-software-factory/SKILL.md`;
primary = `git worktree list --porcelain | sed -n 's/^worktree //p' | head -1`).
The protocol evolves while sessions run; your boot-time copy and your
worktree's checked-out copy both go stale, and the primary's copy is
authoritative. One Read per task is cheap; obeying a superseded protocol is
not.

Every cycle also verifies the model. Consumer seats run on **Fable 5.1**, and
the platform sometimes flips a session (fast mode, usage fallback). Check
your CURRENT system prompt's environment section - it names the model
actually powering you now; trust it over anything earlier in the
conversation. A session cannot flip itself back, so if it does not say
Fable 5.1, make the first line of your next message:

```
!!! MODEL - running on <model>, flip me to Fable 5.1 !!!
```

then continue working normally - never block or park over model drift, and
repeat the banner once per claim cycle while it persists (the flip back is
the operator's, via the app's model picker).

1. **Claim**: `scripts/factory.sh claim <your-worker> --affinity <a,b,c>` -
   always name your worker (or export `FACTORY_WORKER`); a backgrounded
   claim without it, from a seat that never ran `worker-pin`, derives the
   worker from the harness cwd's branch and can mint another seat's
   identity (see Setup). The affinity list is the `touches:` of your last
   task or two - your warm context. Affinity reorders WITHIN the head
   priority band only: among equal-priority work you get the task you
   already know the ground for (and same-area work serializes onto one seat
   instead of ping-ponging), but higher-priority work can never be skipped
   past. Omit `--affinity` on a fresh seat. Beyond that, claim picks the
   best eligible task - skipping tasks whose `after:` ids are still live,
   soft-skipping tasks whose `touches:` overlap another session's active
   claim (to keep merge conflicts rare; repo-wide tokens - `docs`, `README`
   - never count as overlap beside a code token, while a docs-only task's
   tokens all count; `tests` counts unless the operator widens
   `FACTORY_OVERLAP_IGNORE`; if everything overlaps it falls back in GRADED
   order - the first task overlapping only through the suite rule before
   the first sharing a concrete token with another seat's claim, never the
   plain head - and says which on stderr: `factory: overlap fallback:
   suite-only (behind <seat>'s <id>)` or `factory: overlap fallback: DIRECT
   - shares '<token>' with <seat>'s <id>`, the same words on the claim's
   Factory log stamp. A suite-wide task in a STRICTLY higher band than
   every free candidate is claimed over them even while other seats hold
   claims - band precedence beats the soft defer (task 1792540242) - and
   its fallback line reads `suite-only (band NN outranks the free band MM;
   behind <seat>'s <id>)`; equal bands keep the free task. An EXPEDITED
   (band 00-09) task sharing a concrete token with a live claim outranks a
   pick in a strictly lower band the same way (task 1792553976) - `factory:
   overlap fallback: DIRECT - shares '<token>' with <seat>'s <id> (band 05
   outranks the free band 30)`, the same words on the stamp - the rebase is
   the price of the expedite; from band 10 up the collision defers as
   before. Carry a DIRECT line into your CLAIMED banner and merge small and
   early: another live seat is editing that surface, and the second to
   merge resolves the conflict) - moves it to `tasks/claimed/<you>/` and
   prints the path.
   Announce it immediately (the `=== CLAIMED TASK ===` banner below) before
   starting work. `EMPTY` means idle - and it arrives itemized: `EMPTY
   (queue N: X dep-gated, Y operator-lane, Z overlap-deferred)`, or `EMPTY
   (queue 0)` when `queue/` is literally empty. RELAY the breakdown in your
   idle report - "idle: 16 dep-gated (behind 1785898191), 4 operator-lane"
   tells the operator the truth, and naming the gating prerequisite beats
   the bare count. Say "queue is empty" ONLY on a literal `EMPTY (queue 0)`.
   A claim that REFUSES with `an operator signal is waiting for '<you>'` is
   not an error either: the operator has given you an order, printed right
   there in the refusal - carry it out, acknowledge it with
   `factory.sh signal-clear <you>`, then claim again (Operator signals,
   below). A claim refusing with `RECYCLE-REQUIRED (<footprint>MB, age
   <age>)` is the replica recycle budget enforcing itself structurally
   (see "...but RECYCLE it when it grows fat", above): `scripts/factory.sh
   replica-recycle` from your worktree root (the allowlisted door; never
   the raw `icp network stop`), re-bring-up per the posture rhythm, then
   claim again - never FACTORY_FORCE past it outside a genuine emergency.
   On idle: `factory.sh watch 3300` in the FOREGROUND with the Bash tool's
   timeout at 3600000 ms, repeated, and claim again on wake - a new task, a
   peer's claim or archive move, and a signal all wake that watch within
   10 s (CHANGED); TIMEOUT after 55 min is only the belt. **Every wake is a
   full-context model turn**, so the idle floor is an HOUR: at `watch 500`
   (upstream, 2026-09-07..24) four idle seats and the prioritizer made ~50
   no-op API calls an hour, each re-reading a few hundred thousand cached
   tokens - the fleet's largest spend, for no work. ONE watch-then-claim
   per wake, in ONE Bash call (`watch 3300 2>&1 | tail -3; claim ...`), no
   probes or narration between wakes: anything worth checking hourly
   (drift, seat health, your replica's footprint) rides the same wake. The
   hour needs the boot environment (`factory.sh boot-env`, which
   spawn-successor's `boot-exec` applies: `BASH_MAX_TIMEOUT_MS=3600000`);
   on a session booted without it `watch` clamps itself to the old cadence
   (540 s) and says so on stderr - report it, the operator respawns you on
   the boot line. Never make one background `watch` the last act of a turn:
   **a seat that has not written activity for 65 min while claimable work
   is queued is DEAD, not idle** (fleet-doctor's default bar since the
   hourly watch: a live seat wakes on the CHANGED within seconds and its
   claim stamps the heartbeat) - upstream, on 2026-09-03, every seat and
   the prioritizer sat parked 8+ hours with claimable work because a
   background watch completion (TIMEOUT, CHANGED, or the harness's 30-min
   `[killed]` sweep) never re-invoked them. A foreground watch keeps your
   turn alive (each call under the Bash cap - an hour on a factory-booted
   seat, 10 min elsewhere); background one only when you must stay
   responsive, knowing a lost completion parks you until `fleet-doctor`
   (executor mode, below) names you STALLED. Every factory.sh command run
   inside your worktree stamps `.factory-heartbeat` for it - no extra step
   (`factory.sh heartbeat` is the explicit form for a cycle that runs no
   other factory command). If you instead wake
   to a "background task stopped - no completion record" notice for your
   watcher, the HARNESS RESTARTED: that notice is your resume signal, not
   an anomaly - announce "restart detected - resuming", follow the restart
   seat checklist (Operator guide), and never end your turn having only
   narrated the dead task. And KEEP your replica running while you idle
   (above).
2. **Sync, then sanity-check.** First `git merge main` into your branch:
   other seats land work continuously, and an `after:` dependency being
   archived only promises the prerequisite's code is on MAIN - a lagging
   branch can be missing exactly what your task depends on. (Clean tree
   first: the posture rhythm means no lingering main.mo flip.) If the task
   needs the live venue, redeploy your venue per the posture rhythm. Then
   sanity-check the task against current reality: cited files/lines still
   exist? Already fixed by someone else? The corpus README's "Already
   resolved - do not redo" table? If stale:
   `factory.sh done <id> superseded "why"` and claim again.
3. **Split when splitting beats doing**: work discovered to be multi-session
   sized, separable, or blocked on a missing prerequisite becomes NEW tasks
   (producer procedure: draft + `new`, with `after:`/`split_from:` wiring),
   then `factory.sh done <id> split "-> <new ids>"`. When mid-task work is
   partially done and coherent, integrate what stands (below), then split
   the remainder. A follow-up that builds on code your CLAIMED task has not
   yet merged carries `after: <your task id>` (its claimer would otherwise
   fail its own step-2 sanity check against main and bounce it): `new`
   warns when the draft cites your in-flight claim and the line is missing,
   and never adds it for you - a bug found in passing is often independent
   of the parent (task 1792508238).
4. **Execute** in your worktree. The execution rules that are multidex
   physics, not style:
   - Deploys go to your worktree's OWN venue only (law 8). `ICP_HOME`
     exported, `--identity` on every `icp` call (law 10) - `tests/_lib.sh`
     and `scripts/seed.sh` already enforce the pin at the helper layer;
     match them in ad hoc calls.
   - The harness shell cwd is treacherous: after ANY foreground Bash call
     is timeout-moved to the background, the NEXT call's working directory
     RESETS to the session's default cwd - which can be a DIFFERENT
     worktree. Prefix EVERY deploy/icp/mops/test invocation with an
     explicit absolute `cd <your-worktree> && ...`, and re-check `pwd`
     before trusting any relative path after a backgrounding event (a
     stray relative deploy once seeded a whole venue into the wrong
     worktree).
   - Deploys against your RUNNING replica contend with nothing of other
     seats': never wait for machine-wide quiet, never poll for other
     sessions' deploys, never build wedge detectors - deploy immediately.
     The one start-line exception is bring-up step 4.
   - Mid-task discoveries you will not do now: file them (law 7). Doctrine
     questions (posture, transparency, disclosure) are operator-INPUT
     tasks - park into the lane rather than deciding unilaterally.
   - Never edit a running script in place (a live fleet's bash re-parses
     mid-run); atomic-rename or stop-first. Restore accidentally clobbered
     files from copies, never `git checkout` over uncommitted work.
   - Commit at verified checkpoints, by explicit paths (the seat's
     uncommitted icp.yaml port edit must never ride along).
5. **Verify** what the task's "how to verify" says, plus the narrowest
   honest gate set for what you touched:
   - **Unit** (no venue): `mops test` for the Motoko suites in
     `tests/*.test.mo`.
   - **Static** (no venue): `bash tests/test_deploy_hygiene.sh` and the
     other source-reading suites - run hygiene whenever you touched
     scripts/, deploy paths, or anything a hygiene section pins.
   - **Integration** (your #dev venue): the specific `tests/test_*.sh` the
     task names, or `bash tests/run_all.sh [--filter X]` - from the
     worktree, `ICP_HOME` exported. Suite physics: it is NOT idempotent
     across runs (`test_state_reset` wipes the venue near the end), and a
     FAILING run can strand global state that reds OTHER suites - so
     reseed (`cold_start --mode full --no-simulate`, posture rhythm)
     between full runs and before re-diagnosing a surprising red. Cheap
     wipe check first:
     `echo y | icp canister call backend getAmmPools '()' --query --identity anonymous`
     returning `(vec {})` means you are reading noise, reseed. On a
     freshly seeded seat venue, feed/anchor-leaning suites (the archive
     trio, oracle fallback, sealed-model) red for venue-freshness reasons
     before code reasons - reseed and re-run before diagnosing.
   - What you ran - and did not - goes in the completion note.
6. **Integrate** (the merge protocol, exactly):
   a. Commit everything on your branch (explicit paths; tree otherwise
      clean - the icp.yaml port edit stays uncommitted); `git merge main`
      INTO your branch, resolve, re-run gates if the merge was nontrivial.
   b. Do the corpus bookkeeping for a `docfile:` task NOW if not already
      done (brief -> `docs/tasks/done/` with the completion note, README
      row struck) and commit it on your branch so it rides the merge.
   c. `scripts/factory.sh merge-lock acquire <your-branch> --task <id>`
      (blocks up to 4 min; if it dies on the POSTURE LAW, restore the
      committed defaults on your branch and re-acquire; if it dies with
      "held by", retry later - someone is merging). `--task` is the CLAIM
      BELT (2026-10-03): the acquire refuses - before it waits, and again
      once it holds the lock - unless your task is still in
      `tasks/claimed/<you>/`. A refusal naming `back in the QUEUE` means
      your claim was requeued under you while you worked (the operator, or
      a requeue from the console): STOP - do not merge, record it in your
      report, and claim again. Nothing else between execute and this step
      reads the claim, and `done` (step 7) runs after main already holds
      the merge (upstream, an executor merged a requeued claim exactly so
      on 2026-09-29).
      **(d)-(h) are ONE door since task 1792601027 (2026-10-21):**
      `scripts/factory.sh merge-land <branch> -m "merge: <summary> from <branch>" [--task <id>]`
      (`-F <file>` for a long message), run from YOUR worktree with <branch>
      checked out. It refuses outside a lock held for exactly <branch>,
      refuses when the primary resolves to the worktree it runs in (the
      self-merge shape, under (f)), refuses "nothing to merge" when the
      branch has no commits beyond main, runs the lint of (d), prints
      main's sha before and after the merge and PROVES the landing ((f)'s
      assertion), and on EVERY refusal after the lock check releases the
      lock and lands nothing - a refused landing is re-acquire, fix, run it
      again. Its last stdout line is `merged <sha>`, the archive note of
      step 7. `--task` re-runs (c)'s claim belt right before the merge.
      The door's push leg is the standing ORIGIN sync (law 8's one
      carve-out, the 2026-08-20 directive): `pushed origin main` is the
      expected line; `PUSH FAILED: ...` never blocks the landing (rc stays
      0) - note it in your .done so the operator pushes by hand. The public
      mirror is never touched here. The lettered steps below are what the door does, kept so its
      output reads; compose them by hand only when the door itself is what
      you are fixing - then with `PRIMARY` spelled out as the absolute path,
      never a variable you did not just print.
   d. Preflight the primary:
      `PRIMARY=$(git worktree list --porcelain | sed -n 's/^worktree //p' | head -1)`;
      no `$PRIMARY/.git/index.lock` (a GUI git client - wait or ask the
      operator), and `git -C "$PRIMARY" rev-parse -q --verify MERGE_HEAD`
      must fail (a half-finished merge means STOP: release the lock and
      escalate to the operator). Then run `scripts/lint-ratchet.sh` from
      YOUR worktree - the merge gate (type-check, `mops test`, candid
      compatibility), the ONE mechanical backstop that rides even when step
      5's gate choice was narrow. A FAIL means release the lock and fix on
      your branch before merging; the rare deliberate skip is
      `LINT_RATCHET=0`, recorded in your report.
   e. `git merge-base --is-ancestor main <branch>` - if not, main moved
      since (a): release the lock, go back to (a).
   f. `git -C "$PRIMARY" merge --no-ff -m "merge: <summary> from <branch>" <branch>`
      - conflict-free by construction after (e). THEN PROVE IT LANDED (task
      1792601027): `git -C "$PRIMARY" rev-parse main`, read BEFORE the merge
      and again after it, MUST have moved, and `git -C "$PRIMARY" merge-base
      --is-ancestor <branch> main` MUST hold - `Already up to date.` with
      exit 0 is a FAILURE at this step, never a success ((c)'s acquire
      already warns when the branch has no commits beyond main, so a
      legitimately empty merge never reaches (f)). Upstream, on 2026-10-21,
      exactly that answer passed for a landing: the lock was released, and
      only a manual `rev-parse main` showed the branch tip was not on main -
      `done <id> done "merged <sha>"` would have archived work that lived
      only on the seat branch. The self-merge shape, so the next seat
      recognises it: `git -C ""` leaves the cwd unchanged (git(1)), so a
      transiently empty `$PRIMARY` runs the merge inside your OWN worktree,
      where <branch> IS HEAD - and git truthfully answers "Already up to
      date." If the merge still refuses (dirty overlapping files in the
      primary), abort any partial merge, release the lock, and archive with
      a "MERGE PENDING - operator" note instead of blocking forever.
   g. **No push. Ever.** Merges land locally; origin and the public mirror
      move only by the operator's hand under the outward-batch policy
      (law 8). There is nothing for you to do here - this step exists so
      nobody re-adds one, and so that the door's upstream push leg is
      recognised as foreign the moment it shows.
   h. `scripts/factory.sh merge-lock release <your-branch>` (the door does
      it; by hand, every exit path releases).
7. **Archive**: `factory.sh done <id> done "merged <sha>"` - the sha from
   `merge-land`'s last line (the bookkeeping law checks the brief moved).
   Then, BEFORE the next claim, the replica budget check (the recycle
   paragraph above): `scripts/replica-doctor.sh --rss .` from your
   worktree; exit 3 -> `scripts/factory.sh replica-recycle` NOW and
   re-bring-up at this boundary you chose, not at the one the claim
   refusal picks. Then loop to 1.

Any fresh session can take over a consumer seat at any time - all state is on
disk. If your context has grown long and muddy, prefer finishing the current
task cleanly over degrading through another claim - then HAND OFF (below): a
fresh session inherits your worktree, deps, running venue, and branch, so the
context reset costs minutes, not the tens of minutes a full seat bring-up
costs. Reserve the wind-up (full teardown) for actually retiring the seat.
Never end your turn mid-claim without either archiving, requeueing
(`factory.sh requeue <id>`), or telling the operator why you stopped.

### Executor mode: the seat that does not go muddy (THE standard worker mode)

A session cannot reset its own context, so the alternative is to stop
accumulating one: the seat stays a THIN PROTOCOL SHELL and each task
executes in a fresh-context subagent. Boot prompt: *"...You are a
TaskConsumer in executor mode..."* - everything else per this skill.

- The seat itself does steps 1-2 (claim + banner + sync) and step 7
  (archive), and handles all operator signaling. Its `worker-pin` (Setup)
  covers the subagent too: an agent working inside the seat's worktree
  resolves the seat's identity from `.factory-worker` wherever inside the
  tree its shell cwd drifts - upstream's 2026-08-19 wrong-worker claim came
  from exactly such a drift - and the `executor-env` line (below) carries
  it when the cwd drifts OUT of the tree. Per task it accrues one banner
  and one report - it
  stays clean for hundreds of cycles, and the handoff becomes a rarity
  instead of a rhythm.
- After step 2 it spawns a SUBAGENT (Agent tool, model pinned to Fable 5.1,
  run in background so the seat stays responsive to the operator): prompt =
  the claimed task file path, the worktree path AND its `ICP_HOME`
  (`<worktree>/.icp-home` - the agent must export it in every shell it
  runs, law 10's identity pinning included), the Bash-prefix rule headed by
  the `scripts/factory.sh executor-env` line (the bullet below - MANDATORY:
  "Prefix EVERY Bash call with `export FACTORY_WORKER=<pin>
  FACTORY_SEAT_ROOT=<worktree> ICP_HOME=<worktree>/.icp-home; cd
  "$FACTORY_SEAT_ROOT" && ...` and re-check pwd after any backgrounded
  call"), and "read
  .claude/skills/mdex-software-factory/SKILL.md from the primary checkout,
  execute this task per TaskConsumer steps 3-6 (split/execute/verify/
  integrate: `merge-lock acquire <branch> --task <id>`, then
  `scripts/factory.sh merge-land <branch> -m "merge: <summary> from
  <branch>"` for 6d-6h - the preflight, `lint-ratchet.sh`, the --no-ff
  merge with the proof that main moved, the release; never the hand chain;
  posture law included; no push - law 8); do not
  claim or archive; return a structured report: outcome (integrated <sha> |
  blocked-on-operator <question> | split <ids> | failed <why>), what was
  verified and not, the corpus bookkeeping performed (brief ->
  docs/tasks/done/ + README row, or 'no docfile'), and GROUND NOTES for
  the next agent on this ground - key files, structures, and gotchas
  discovered (two to five lines, written to be reused)."
- **Mechanical law-5 guards back the pwd mandate - they do not replace it**
  (ported 2026-09-01 from open-saas a6e6e6e44, after executor cd-drifts
  there committed work directly onto the primary's main). Three tripwires
  key on CONSUMER SEAT identity (`FACTORY_WORKER` or a `.factory-worker`
  pin; fail-open when absent, so operator and direct rounds are
  untouched): the pre-commit hook (`.githooks/pre-commit`, active via
  `core.hooksPath = .githooks`) refuses a seat-identified commit on the
  primary's main and prints the remedy; `factory_primary_guard`
  (scripts/factory_guard.sh, sourced by deploy.sh and cold_start.sh) dies
  when a seat targets a REMOTE deploy (law 8) or runs a venue script
  against the PRIMARY checkout (law 5); and `merge-lock acquire` WARNS
  when the branch being merged has no commits beyond main (the
  direct-to-main signature; `merge-land` REFUSES it).
  **The no-identity belt** (task 1791133471; 2026-10-04, upstream's seat-9
  executor cd'd into the primary with NO FACTORY_WORKER and committed
  1dc9df2fa onto main - every identity-keyed guard stayed silent): the hook
  (its guard C, re-synced here 2026-10-31) ALSO refuses a commit on the
  primary's main when the process carries NO seat identity WHILE A FACTORY
  IS RUNNING - any CONSUMER seat's `.factory-worker` pin under
  `.factory/seats/*/`, the legacy `.claude/worktrees/*/`, or a linked
  worktree (the operator seat's `operator` / `claude-operator` pin is no
  running factory to either belt - task 1793617711). The operator's own
  primary work declares itself: `FACTORY_DIRECT=1` (the direct-round marker
  - `FACTORY_DIRECT=1 git commit ...` for a direct round on main, a release
  tag or a hotfix; the same prefix on a primary `scripts/deploy.sh` run -
  `FACTORY_DIRECT=1 bash scripts/deploy.sh <target>` - is the declaration
  `scripts/factory_guard.sh` reads TODAY: its `factory_primary_guard`
  carries the belt too (re-synced 2026-10-31) and, with NO identity,
  REFUSES a REMOTE deploy (`deploy.sh cloud|engine|subnet`) from the
  primary while any consumer seat is pinned under `.factory/seats/*/`,
  `.claude/worktrees/*/` or any linked worktree (`git worktree list`, the
  hook's own list - task 1793617711) - "REFUSED - a REMOTE deploy from the
  primary with NO seat identity while a factory is running" - and leaves a
  LOCAL deploy or `cold_start.sh` run untouched, the primary's :8000 venue
  being the operator's by design) or `FACTORY_WORKER=operator` (or
  `claude-operator` - the operator seat's pin; one principal to the hook,
  the guard and factory.sh, "The operator seat"); `FACTORY_FORCE=1` stays
  the blanket override.
  Fail-open remains ONLY when no CONSUMER seat is pinned anywhere (a
  checkout with no factory; the operator seat's pin alone does not count -
  task 1793617711). The merge protocol is untouched: `git -C
  <primary> merge --no-ff` runs the pre-merge-commit hook, never
  pre-commit, and none is shipped. Environments the guards cannot see (a
  shell with no FACTORY_WORKER and a cwd outside any pinned tree, in a
  checkout with no pins) still exist, so the absolute-cd / pwd-check
  discipline in step 4 remains mandatory belt - and the executor-env rule
  below is what makes the subagent's shell carry the identity in the first
  place.
- **The executor prompt carries the seat identity - `factory.sh
  executor-env` is the line** (task 1791133471). The Agent tool does not
  inherit the seat's exports, and the `.factory-worker` pin only resolves
  from a cwd INSIDE the worktree - so a subagent whose cd target drifts to
  the primary is identity-less there, and every guard keys on identity.
  From the seat's worktree run

  ```
  scripts/factory.sh executor-env
  ```

  (prints `FACTORY_WORKER=<pin> FACTORY_SEAT_ROOT=<worktree>` from the pin
  - never the cwd branch, never a drifted FACTORY_WORKER) and put it at the
  HEAD of the executor prompt's Bash-prefix rule, which the prompt states
  as a MANDATORY rule for every Bash call:

  ```
  Prefix EVERY Bash call with `export FACTORY_WORKER=<pin> FACTORY_SEAT_ROOT=<worktree> ICP_HOME=<worktree>/.icp-home;
  cd "$FACTORY_SEAT_ROOT" && ...` and re-check pwd after any backgrounded call.
  ```

  (`ICP_HOME` rides the same export here - law 10's isolated store; quote
  `"$FACTORY_SEAT_ROOT"` so a worktree path with a space in it survives.)
  With it, a drifted executor is REFUSED by the hook and the guard instead
  of passing as the operator; without it the no-identity belt catches the
  commit only while some seat is pinned. The seat re-mints the line after a
  `worker-pin` (handoff, seat-recreate); the pin is the source of truth, so
  it never changes mid-seat.
- **Arm the liveness watchdog alongside every spawn** (one backgrounded
  Bash call): `cd <worktree> && scripts/factory.sh executor-watch`. It
  resolves the LIVE activity dirs itself (the /private/tmp session dirs
  AND the ~/.claude/projects store - on CLI seats only the former is
  live) AND the seat worktree itself, and takes the newest write across
  all of them - liveness is WRITES, not process existence. The worktree
  counts because on this harness build the agent's transcript symlink
  resolves to a `subagents/agent-<id>.jsonl` that never exists, so an
  agent mid-edit is visible ONLY through the files it writes into the tree
  (`.git/`, `.icp/`, `.icp-home/`, `node_modules/`, `dist/`, `.mops/` are
  pruned - the replica's own state churn is not an agent). Idle past ~25
  min across every source it prints `EXECUTOR-STALE` and
  EXITS, so the background-completion notification re-invokes the waiting
  seat. THIS harness's wrinkle: the 30-min-grid reaper
  (docs/factory-watch-reaper.md) usually kills the backgrounded watchdog
  itself first - that kill notice ("background task stopped - no
  completion record") is the SAME wake signal: judge from disk exactly as
  for a STALE print, then re-arm a fresh watchdog if the executor is
  still working. On a NORMAL completion, stop the watchdog (TaskStop) or
  dismiss its late firing as noise.
- **On EXECUTOR-STALE (or the watchdog's own kill notice), judge from
  DISK, never from memory.** The activity tail (the STALE line's own
  "newest write ... from: <source>" first, then the newest file under the
  watched dirs) and the worktree's git state (`git -C <worktree> log
  --oneline main..` + `git status`) are the truth; the seat's
  recollection of what the executor "was probably doing" is not. After a
  fleet-doctor `--respawn` kill, the FIRST thing to read is the doctor
  row's own `newest write <instant> from: <source>` in
  `~/Library/Logs/multidex-fleet-doctor.log` (task 1792601787) - it is what
  the doctor saw when it judged the seat, before any activity tail. Two
  verdicts:
  - **Alive but slow** (activity written recently relative to the
    threshold - a long build, deploy, or suite run in flight): re-arm
    the watchdog and keep waiting. BUT this verdict requires the
    executor's long-running CHILD to still be in flight: a task output
    file carrying the child's exit marker ("EXIT: 0", "COLD START OK"
    and the like) with nothing from the agent since is NOT
    alive-but-slow - see the parked-waiter rule below.
  - **Dead** (no writes since before the threshold, no activity at all,
    or the child's exit marker present with agent silence since): treat
    the completion notification as LOST and run **executor loss
    recovery** - verify what EXISTS in the worktree FIRST, then act on
    what you find: work COMPLETE (committed, gates recorded as run,
    merge-ready) -> perform the archive/merge steps yourself, never
    respawn over it; work PARTIAL -> respawn a fresh agent against the
    surviving claim, its prompt naming what is already committed; work
    ABSENT -> respawn clean.
- **The parked-waiter double-loss: avoid end-of-turn background waiters;
  a parked agent is DEAD on the first firing.** (Upstream lost 60-90 min
  twice in one day to executors that backgrounded a long command, ended
  their turn "waiter armed", and were never resumed by the completion
  notification - and a SendMessage nudge lands only at the agent's next
  tool round, which for a parked agent never comes.) Executors: prefer
  chunked FOREGROUND calls under the Bash cap for long commands (an hour
  on a factory-booted seat - `factory.sh boot-env` - 10 min elsewhere;
  re-invoked to poll or continue) - the
  agent's own turn continues and survives; background a long command
  only when you must stay responsive, knowing the seat's watchdog is
  then the only safety net. The seat: when the child's exit marker is on
  disk and the agent has been silent since, go straight to loss recovery
  (TaskStop the zombie first) - never nudge-and-wait.
- **The fleet doctor - liveness from OUTSIDE the sessions (task
  1788456904).** Every watchdog above is armed BY the seat, and a parked
  seat arms nothing: upstream, on 2026-09-03, ten seats and the
  prioritizer sat alive (S+, ~0% cpu) for 8+ hours with two claimable
  tasks queued, each parked on a `watch` completion that never re-invoked
  it (the harness's 30-min memory-pressure reap - docs/factory-watch-reaper.md
  is this machine's own capture - marking every seat's backgrounded watch
  `[killed]` until one completion was lost). So: every factory.sh command
  run inside a pinned worktree stamps `<worktree>/.factory-heartbeat`
  (structural, no compliance needed; `factory.sh heartbeat` is the
  explicit form), and `scripts/factory.sh fleet-doctor` - an
  OPERATOR-INSTALLED launchd job from the primary every 15 min
  (`fleet-doctor --launchd-plist` prints it; Operator guide) - reads the
  heartbeat, the git index, the harness activity dirs and the tree
  (node_modules/.icp/.git pruned) per seat - and every seat row's NOTE
  field ends with WHICH source made the newest write and when: `newest
  write <ISO instant> from: <source>`, source = `heartbeat` | `git index` |
  `harness activity dir <path>` | `tree (a file newer than the threshold
  edge - the walk is a yes/no)` - executor-watch's EXECUTOR-STALE shape,
  appended INSIDE the note after its other words, never a new
  tab-separated column: the row layout
  `<verdict>\t<seat>\t<worker>\tidle <n>m\tpid <p>\tclaim <id>\t<note>`
  and every printed word are a compat surface (the selftest's prefix
  assertions, the console's checks); before it the doctor's log could not
  say what made a seat ACTIVE or STALLED (task 1792601787). Verdicts:
  ACTIVE / STALLED (live process, silent >65 min - the default since the
  hourly idle watch, `FACTORY_FLEET_STALE_MIN` - AND a held claim or a
  claimable queue task: dead, not idle) / QUIET (silent, nothing
  claimable) / LOGGED-OUT (next bullet) / UNMANNED (no process; one with a
  live spawn-pending stamp reads "spawn pending since <instant>, Terminal
  AppleEvents timing out" and is NEVER respawned until the stamp expires
  or its process appears), plus the prioritizer by its board's age (bar 65
  min; an UNMANNED row's note reads `boot: scripts/factory.sh
  prioritizer-boot`) - and ORPHANED for a seat on the FLEET ROSTER
  (`tasks/factory/fleet-roster`: written by `worker-pin`, adopted by the
  doctor for any pinned worktree it enumerates, dropped ONLY by
  `seat-retire` - except a row for the OPERATOR principal, stale by
  construction (no writer mints one and `seat-retire` refuses that seat),
  which the pass itself drops instead of reading it ORPHANED:
  `roster_drop_operator_row`, task 1793621537) whose worktree is gone
  (task 1788956135). The doctor used
  to ENUMERATE pinned worktrees, so a deleted tree simply dropped out of
  the count: upstream's seat-7 and seat-14 vanished under LIVE processes,
  the fleet went 10 -> 6, and every pass read `FLEET-OK seats 6`. Now the
  summary reads `FLEET-DEGRADED n missing of N` (never FLEET-OK while a
  seat is missing), and the ORPHANED line carries the forensics: the FIRST
  pass that saw it missing (`tasks/factory/fleet-orphaned` - the anchor
  never moves), whether a dead-husk process still carries the seat's
  session name (a CLI session whose cwd was deleted can never claim
  again), the branch's ahead/behind main, the `git worktree list` prunable
  state + whether `.git/worktrees/<seat>` still exists (present = an `rm
  -rf`, absent = `git worktree remove`/`prune` ran - the desktop app's GC
  shape), and the seat's parent dir's mtime, which brackets the deletion.
  An orphan is NEVER respawned (no tree to boot into), even under
  `--respawn`: the operator runs `factory.sh seat-recreate <seat>` (refuses
  while the tree exists; kills the husk, drops that path's stale admin
  entry only, fast-forwards `claude/<seat>` to main when 0 ahead - else
  keeps it and says so - `git worktree add` UNDER THE SEAT ROOT
  (`.factory/seats/<seat>`: a legacy `.claude/worktrees` roster row is
  relocated, its tree being gone), `worker-pin`, a takeover handoff
  "recreated after its worktree vanished", `spawn-successor`, prints the
  roster; with no `scripts/bootstrap.sh` in this repo its deps step is
  skipped, so the successor runs bring-up steps 1-6 itself) or `factory.sh
  seat-retire <seat>` (the ONLY sanctioned way to drop a seat - wind-up).
  Every pass also re-drops `.worktree-keep` into each pinned seat (the GC
  belt) and tags a seat still under `.claude/worktrees/` `legacy-location`.
  REPORT-ONLY by default. `--respawn` (or `FACTORY_FLEET_RESPAWN=1` in the
  job) is the operator's opt-in - upstream flipped it on 2026-09-11 after
  an 8-day report-only burn-in with zero false verdicts, and that burn-in
  is the bar here too: it writes a takeover handoff (with the
  COMPLETE/PARTIAL/ABSENT triage note when a claim is held), kills only
  the process carrying the seat's session name (TERM then KILL), and
  `spawn-successor`s the seat into its own worktree (`--dry-run` shows the
  plan); since task 1792506027 the same pass revives an UNMANNED or
  STALLED prioritizer through `prioritizer-boot` under the name guard (the
  parked pid killed by pid, the stamp `spawn-pending/prioritizer` holding
  respawns), so no fleet revive keeps a hand step.
- **CLI login expiry (task 1792504454; upstream's 17.5-hour dead fleet of
  2026-10-19 20:08Z -> 10-20 13:49Z).** SYMPTOM: every seat's next turn
  ends with the CLI's own message `Login expired · Please run /login` (the
  last conversation entry of its transcript under
  `~/.claude/projects/<dashed worktree path>/*.jsonl`; the process then
  sits alive at its prompt), the prioritizer dies the same way (its board
  goes stale), and the queue fills while every seat looks manned. CAUSE:
  the seat CLI's credentials - the macOS Keychain item "Claude
  Code-credentials", shared by every CLI process of the user - expired.
  The DESKTOP APP's login does NOT count: it is a separate Keychain item
  that never carries over to the CLI, so an operator who is signed in to
  the app can still have a logged-out fleet. THE ONE-LOGIN REMEDY: `claude
  auth login` as the seat user, or `/login` inside any one seat window -
  one login covers every seat and the prioritizer. The doctor names it:
  every pass first runs `claude auth status` (`cli login:` header line);
  logged out = the loud `FLEET-LOGGED-OUT` line with the remedy, the stamp
  `tasks/factory/fleet-logged-out` the board's "CLI login" line reads, a
  macOS notification (first sighting, then hourly), the per-seat verdict
  `LOGGED-OUT` (a live pid whose transcript ends on that message; the
  prioritizer row too - held, then replaced through `prioritizer-boot`
  exactly like a seat), the summary `FLEET-LOGGED-OUT n logged out ...` -
  and EVERY respawn held (a successor booted logged out dies on its first
  turn: upstream's 12:59Z and 13:44Z passes of 2026-10-20 each revived 8
  seats that way). THE REPLACE-AFTER-LOGIN RULE: a parked logged-out
  session never re-reads the Keychain (nobody sends it a next turn), so
  once `auth status` reads logged in again the `--respawn` pass REPLACES
  each parked `LOGGED-OUT` seat - takeover handoff naming the reason, kill
  by pid (TERM then KILL), `spawn-successor` - and keeps every seat whose
  transcript moved past the login (the hand recovery: `/login` in one seat
  window, then `kill -TERM <pid>` + `factory.sh spawn-successor <seat>` for
  each of the others). Report-only mode prints that hand remedy on the row
  instead. Selftest-covered (`scripts/factory-selftest.sh`: the stub
  `claude`, a transcript fixture).
- **The FSEvents wedge - the doctor can heal it, but only once the operator
  installs the root half (task 1791198753).** Every doctor pass probes
  FSEvents delivery on both volumes (the primary's + /private/tmp,
  `scripts/lib-fsevents.sh`); DEAD-on-BOTH is the wedge that parks every
  fresh `icp network start` (the `WEDGED (launcher parked, port file
  unread)` verdict of bring-up step 4 and `docs/seat-venue-bring-up.md`).
  The unattended restart of fseventsd needs root, and seats never run sudo
  (`Bash(sudo *)` stays denied): it arms ONLY after the operator's one-time
  `sudo` install of a root-owned wrapper plus ONE NOPASSWD sudoers line
  (Operator guide, "FSEvents remedy") - `sudo -n -l <wrapper>` answering 0
  is the only thing that arms it. Until then every site (the doctor,
  replica-doctor's verdict) prints the paste line for the operator, as
  today - do not assume it is installed; the doctor's `fsevents restarts:`
  header line says what it did. One attempt per run; a second DEAD is
  HUMAN NEEDED (a reboot).
- **The 30-minute `[killed]` sweep is the harness's MEMORY-PRESSURE REAP
  (task 1788458457; docs/factory-watch-reaper.md is this machine's own
  capture).** It SIGTERMs a session's backgrounded shell tasks when macOS
  raises memory pressure - only sessions idle 30 min, not mid-turn, with
  no agent running: exactly a PARKED seat and the prioritizer; a seat with
  a live executor is exempt. REMEDY: every factory session boots with
  `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1`, one word of the boot
  environment (`factory.sh boot-env`) - `spawn-successor`'s and
  `prioritizer-boot`'s boot lines apply the whole environment through
  `boot-exec`, hand-boots of a producer or the console (Operator guide)
  prefix `$(scripts/factory.sh boot-env)`; the env is read at session
  start, so a fleet booted without it keeps the reap until its next
  respawn. A reaped watch leaves an obituary above the marker
  (`factory.sh watch: killed by SIGTERM at <instant> (pid N, ppid M
  alive)`), so a bare `[killed]` with NO obituary means SIGKILL - something
  else entirely.
- **The seat is a memory broker (the report-injection warm start).** Keep
  each agent's final report. When affinity hands you a task touching the
  same ground as a recent report, PREPEND the latest one or two relevant
  reports to the new agent's prompt, fenced and labeled: "Warm-start
  context from the previous task(s) on this ground - historical, so verify
  against current code (other seats merge continuously; your sync step is
  still mandatory)." A few hundred curated tokens replace tens of
  thousands of re-derivation, and only VALIDATED warmth travels - reports
  describe what actually merged, not what a stale context remembers.
  Bounds: at most two reports, none older than ~10 cycles; when in doubt
  spawn cold - a misleading warm start costs more than a cold read.
  (Agents on any seat can pull the same warmth from disk: the completion
  notes in `docs/tasks/done/` and recent `tasks/archive/` entries for the
  same ground.)
- The agent reads the CURRENT skill fresh every task (staleness solved by
  construction) and is disposable: its context mud dies with it. The
  seat's venue is the agent's venue - deploys and suites run against it
  per the posture rhythm, exactly as steps 4-5 say.
- On the completion notification, the seat acts on the outcome: integrated
  -> `factory.sh done` + report; blocked-on-operator -> HUMAN NEEDED
  banner + park into the operator lane (the agent cannot talk to the
  operator - anything interactive comes back as blocked, which is the
  protocol anyway); split -> announce the new ids; failed -> judge: retry
  with a fresh agent, requeue, or escalate.
- Operator interjections mid-task: tell the seat; it relays into the
  running agent via SendMessage. The seat never invents agent results - it
  waits for the notification. A SendMessage is a relay, not a brake
  (upstream, 2026-09-29, claude 2.1.285 with agent teams on -
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`): an in-process TEAMMATE reads
  its inbox only when its turn ends - one executor told to hold made 106
  more tool calls, merged, and read the message 36 minutes later. A
  background agent that is not a teammate is promised delivery at its next
  tool round, which this skill has not tested either way. To STOP a busy
  executor, TaskStop it and run executor loss recovery; a message cannot
  be counted on to arrive in time.

### The warm-spare pool (desktop-era; RETIRED for workers)

CLI seats spawn their own successors (`spawn-successor`, in the handoff
below) and need no spare. This section remains for the transition and for
the operator's DESKTOP surfaces - do not boot new spares for worker
succession.

Sessions cannot create sessions, but a message can WAKE one: the harness's
session tools (`list_sessions` / `send_message` / `get_session`) deliver a
message into another session as a user turn. So the operator pre-pays the
clicks: boot a few spare sessions in bulk, and a retiring seat activates one
by message - no chip, no operator present.

**Cross-titling (when self-titling is refused).** Some harnesses (Claude
Desktop among them) refuse `set_session_title` on the session that calls
it, and their `list_sessions` omits the caller - every "title yourself"
step in this skill fails there, for every session, silently. So each
titling step means: try self-titling; when refused, read your own id
from `$CLAUDE_CODE_HOST_SESSION_ID` (format `local_<uuid>` - the id the
session tools recognize; the similarly named `CLAUDE_CODE_SESSION_ID` is
a DIFFERENT id they do not know) and have another session apply the
title. Natural owners: a retiring seat titles the spare it just
activated (it is already messaging it and knows the target title);
sibling spares title each other at boot; anyone else sends a one-line
favor to any idle spare - `NOT AN ACTIVATION - favor: retitle session
<your id> to "<exact title>", then return to idle` - and keeps working
rather than waiting on the reply. Renaming OTHER sessions works
everywhere; only the self-rename is refused. And keep every title
STRING byte-exact as this skill writes it: activation matching, the
resume fan-out, and the operator's glance all depend on literal titles.

**WarmSpare boot** (operator, in the primary checkout): *"Read
.claude/skills/mdex-software-factory/SKILL.md. You are a WarmSpare. Prepare
and wait."* The spare re-titles itself `MULTI/DEX — spare (idle)`, confirms
readiness in one line, and ENDS ITS TURN - no watch loop, no polling; it
sleeps until messaged. On a refusing harness, converge by cross-titling
(above): retitle any sibling spare still wearing its boot auto-title
("WarmSpare preparation"), send one idle spare the favor message for
your own title, and end your turn even if no sibling has titled you
yet - the activation flow's step-1 fallback still finds you. Spares
must be ordinary interactive sessions
(scheduled/remote sessions can neither send nor receive these messages),
and the operator should KEEP THEIR TABS OPEN: delivery to an idle session
is proven, but a closed window may queue the turn until next focused - the
activation timeout ladder below covers that case, at the cost of burning
the 2-minute wait.

**Activation** (a retiring DESKTOP seat, during handoff):

1. `list_sessions`, pick a session titled `MULTI/DEX — spare (idle)`.
   Sessions still auto-titled "WarmSpare preparation" sitting in the
   primary checkout are spares whose retitle has not landed - treat
   them as pool members too.
2. `send_message` to it: `ACTIVATE: take over the seat at <worktree path>;
   branch <branch>; venue <running port N, posture #dev | stopped>;
   ICP_HOME <worktree>/.icp-home; mode <normal | executor>. Re-read the
   skill from the primary checkout, retitle yourself, and work the queue
   continuously.`
3. The spare, on its FIRST activation: `send_message` back `TAKEN
   <worktree>`, retitle to the standard worker title (self-titling
   refused? proceed - the retiring seat titles you, step 4),
   cd/EnterWorktree to the seat, re-export `ICP_HOME`, run
   `scripts/factory.sh worker-pin`, sync main, enter the loop. On any
   LATER activation (two retirees picked it): `send_message` back
   `REFUSED - already assigned`, change nothing.
4. The retiring seat waits for the reply (it arrives as a message into this
   session): `TAKEN` - succession done; on a refusing harness, now apply
   the successor's worker title yourself (you picked its id off
   `list_sessions`; it cannot self-title). `REFUSED` or ~2 min of
   silence - try the next spare; pool empty - fall back to the successor
   chip (handoff step 3), and say "SPARE POOL EMPTY" in your final message.
5. Either way the retiring seat retitles itself `MULTI/DEX — retired
   <UTC datetime>` (never mistakable for a spare or worker) and reports
   spares remaining. Self-titling refused? Send the favor message
   (cross-titling, above) - your id plus that exact retired title - to
   your activated successor or any idle spare.

### Handing off a seat (context reset; infrastructure kept)

A session cannot reset its own context - only a fresh session gets a clean
one. The handoff makes that cheap by keeping everything expensive: the
worktree, installed deps, the running venue with its seeded state, and the
branch (same branch = same worker identity, so `tasks/claimed/` continuity is
preserved). Runs when the operator says **"hand off"**, or by yourself when
you retire on the context-hygiene rule above and the seat's infrastructure is
healthy.

1. Settle your claim exactly as for a wind-up: finish through integrate +
   archive, or (operator said "hand off now") requeue with a parked note.
2. Do NOT stop the venue and do NOT touch the worktree - they are the
   inheritance. Never move or re-root it either: a legacy-located seat
   reaches the seat root only through `seat-recreate` after it has retired.
3. Succession, by seat type:
   - **A CLI seat (the standard) self-spawns.** The claude CLI is installed
     (`~/.local/bin/claude`), so after writing the handoff file (step 4)
     and posting the banner (step 5) the seat runs
     `scripts/factory.sh spawn-successor <worktree-basename>` as its FINAL
     act: it opens a new Terminal window running
     `claude --model claude-fable-5-1 --name 'multidex-executor-<seat>'
     '<boot prompt>'` in the seat's worktree, with the prompt read from the
     handoff file and the project prefix derived per the worker doctrine
     (`FACTORY_PROJECT`, else the primary checkout basename minus
     `-ng`/`-main`; non-executor boot prompts get
     `multidex-worker-<seat>`). The window never types that command
     inline: the typed line is only `cd <worktree> && scripts/factory.sh
     boot-exec <seat> --model <m> --name <n>; exit 0` - a few hundred
     bytes, under the tty's 1024-byte startup input limit (a ~1.2 KB inline
     `do script` line got chunked mid-prompt on 3 of 9 spawns on
     2026-09-03, stranding the shell at a continuation prompt no re-drive
     can finish) - and `boot-exec`, INSIDE the window, applies the boot
     environment (`factory.sh boot-env`: the reap opt-out, transcript
     persistence, the one-hour Bash cap, max effort, the desktop markers
     scrubbed - Operator guide), reads the prompt from the handoff file and
     execs claude; on a failure the window holds the error 10 min before
     its `; exit 0` closes it. Zero-residue window: the spawned command
     ends `; exit 0` (the shell exits cleanly even though the handoff
     self-kill ends claude by signal) and the window gets the operator's
     "Factory" Terminal settings set when it exists, so a seat that later
     retires closes its own window (one-time profile setup: Operator
     guide; without the profile the spawn proceeds and its banner names
     the manual step). Guardrails: only ONCE per handoff - the
     handoff file is the token (`spawn-successor` refuses when it is
     missing: handoff first, spawn second), so spawn only for the file YOU
     just wrote. The spawn also VERIFIES (ported from open-saas
     c436e0c08): it refuses when a live process already carries the
     successor's session name (a duplicate seat - the retiring seat's own
     process is excluded), and after opening the window it polls for the
     named process, re-driving the SAME window when the command sat
     un-executed at the prompt (rapid successive spawns do that);
     "spawned" is only reported once the process actually exists.
     The spawn does NOT clear the handoff file - the
     successor's `handoff-clear` is the ack, so a failed spawn leaves the
     seat visible on `handoff-list` and the operator boots it by hand as
     before (the same degrade applies when osascript/Terminal automation
     is unavailable: the command prints the exact boot line to run
     manually). THE THIRD OUTCOME (task 1789588684): `spawn PENDING
     (AppleEvent timed out - Terminal may still run it)`, exit code 3.
     Terminal did not answer the `do script` in time but has QUEUED it -
     the successor may boot minutes or hours later. The spawn wrote
     `tasks/factory/spawn-pending/<seat>` (holds every further spawn, the
     doctor's included, for `FACTORY_SPAWN_PENDING_TTL` = 6 h or until the
     process appears), and NOBODY boots by hand while it stands. You exit
     all the same (below): a predecessor that lingers would trip the
     successor's DUPLICATE-SESSION gate when the queued boot finally runs.
     Then EXIT your own claude process so the seat's
     defunctness is unambiguous - one last Bash call that kills the
     nearest `claude` ancestor of the shell after the spawn returns
     spawned (0) or PENDING (3); any other failure leaves you alive to
     report it:

     ```bash
     scripts/factory.sh spawn-successor <worktree-basename>; rc=$?; \
     if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then \
       p=$$; while [ "$p" -gt 1 ]; do \
         case "$(ps -o comm= -p "$p")" in *claude*) kill "$p"; break ;; esac; \
         p="$(ps -o ppid= -p "$p" | tr -d ' ')"; \
       done; \
     fi
     ```

     (If the kill somehow misses, the spawn already succeeded - say so and
     stop responding; the operator closes the leftover process. This
     targeted single-PID kill of your OWN ancestor is law-10-compatible:
     no patterns, a PID you resolved yourself.)
   - **A desktop seat (legacy)**: FIRST try the warm-spare pool (above) -
     on `TAKEN`, skip steps 4-5 (the seat is manned; a handoff file would
     read as "still unmanned" and get a second session booted onto it) and
     close out per the activation flow instead. Only when the pool is
     empty or the session tools are absent, stage the successor CHIP (one
     operator click), if your harness has `spawn_task`: title
     `MULTI/DEX worker — <seat> — <UTC datetime>` (the successor corrects
     the timestamp when it titles itself at setup, cross-titling
     included), `cwd` = the absolute worktree path, prompt = the boot line
     from the banner below. This is the ONE sanctioned chip in this repo:
     law 7 bans chips for follow-up WORK (which goes to the queue); a
     successor seat is fleet plumbing, not work. No chip tool: the banner
     alone is the fallback.
4. **Write the boot prompt to `tasks/handoff/<worktree-basename>.md`**
   (plain runtime state next to the queue dirs - write it directly, it is
   not a task file). Chips do NOT survive an app restart; the file is the
   copy a restart cannot reach - and for a CLI seat it is ALSO what
   `spawn-successor` reads. Put the one-line boot instruction first:

   ```
   cd <absolute worktree path> && claude --model claude-fable-5-1 --name 'multidex-executor-<seat>'
   ```

   (ONE line - spawn-successor parses it; the line is for a human
   hand-boot, who pastes the prompt after it and prefixes the claude
   command with `$(scripts/factory.sh boot-env)` - spawn-successor's boot
   line applies the boot environment through `boot-exec`, so keep the
   file's line in this exact `cd <path> && claude` shape, which is also how
   spawn-successor resolves the worktree), then the prompt under a `## Boot
   prompt` heading - the marker
   `spawn-successor` extracts the prompt by (legacy files without it parse
   too: everything after the cd-boot line; the prompt is flattened to one
   line for the spawn, so write it as prose). `factory.sh handoff-list`
   prints what is pending with its age, and the board carries the same
   list under **Seats awaiting successor** - so an unmanned seat is
   visible on the operator's one-glance view instead of only in a chip
   that may no longer exist.
5. Post this banner as a final message, then stop - do not claim again
   (a CLI seat then runs the spawn-and-exit from step 3 as its true last
   act):

```
=== HANDOFF - boot a fresh session onto this seat ===
Worktree: <absolute worktree path>
Branch:   <claude/your-branch>
Venue:    running, port <from icp network status with the seat's ICP_HOME>  (posture #dev)
Successor: CLI seat - successor Terminal self-spawned via factory.sh
spawn-successor  (or: chip staged - one click boots it; or: no automation -
boot by hand)
Handoff file: tasks/handoff/<worktree-basename>.md  (survives an app restart)
Boot with: "Read .claude/skills/mdex-software-factory/SKILL.md. You are a
TaskConsumer in executor mode taking over the seat at <worktree path>. Work
the queue continuously."
```

The successor verifies it is in that worktree, **clears the handoff file as
its FIRST act** (`scripts/factory.sh handoff-clear <worktree-basename>`, run
FROM the worktree - a stale file reads as "this seat is still unmanned" and
would have the operator boot a second session onto it; clearing its own
seat's file also refreshes `.factory-worker`, so the successor inherits the
identity pin along with the worktree), re-exports `ICP_HOME`, syncs main,
and enters the normal loop. Its first claim can pass no affinity (its
context is clean; the seat's history lives in the archive and git, not in
the session). The operator deletes the old session (a self-spawned CLI
handoff needs no cleanup - the retiring process killed itself, and with the
"Factory" Terminal profile in place its window closes itself too; without
the profile, the leftover window at a dead prompt is yours to close).

### Winding up a seat

Runs when the operator says **"wind up"** (finish your current task through
integrate + archive first, then wind up) or **"wind up now"** (do not finish:
`factory.sh requeue <id> "parked: seat wound up"` and wind up immediately) -
and by yourself only when retiring with UNHEALTHY infrastructure (a broken
worktree or venue); a healthy self-retirement hands off instead.

1. Verify you are settled: nothing of yours remains under `tasks/claimed/`,
   and your merged work is on main. In your worktree, `git status` must show
   no MODIFIED tracked files EXCEPT the icp.yaml port edit (revert it now) -
   untracked `.icp-home/`, `.factory-worker`, `.factory-heartbeat`,
   `.worktree-keep` and `node_modules` noise is expected. Anything else
   tracked and dirty: STOP and ask the operator instead of proceeding.
2. **Stop your venue BEFORE the worktree goes**: `scripts/factory.sh
   replica-recycle` from the worktree root with the seat's `ICP_HOME`
   exported (the allowlisted door - project-scoped, kills only your master
   and, when the launcher is already dead, only the pocket-ic processes
   lsof-attributed to your state dir; never pkill, never the raw `icp
   network stop`). Removing the worktree first ORPHANS the network launcher
   (ppid 1) plus a stale port descriptor in
   `~/Library/Caches/org.dfinity.icp-cli/port-descriptors/`, and later
   starts then refuse with "port in use by the project at '<deleted
   path>'". If that has already happened:
   `pgrep -f '[i]cp-cli-network-launcher'`, find the ONE whose `--state-dir`
   is under the deleted worktree, `kill` that numeric PID, then rm the
   matching `<port>.json` + `<port>.lock` descriptor pair - every other
   launcher on the machine belongs to another project; leave them.
3. Report each step's outcome in a final message and stop - do not claim
   again. The archived task files and the merge history are the record
   that survives.
4. The OPERATOR (from the primary) then runs `scripts/factory.sh
   seat-retire <seat>` - since task 1788956135 the ONLY sanctioned way to
   drop a seat: it kills the seat's named process, REFUSES while any other
   live process has its cwd inside the tree (lsof - never remove a
   directory a session stands in), recycles the replica, `git worktree
   remove --force`s the tree and its git admin entry, deletes the merged
   branch (`git branch -d` - an unmerged branch is KEPT and said so;
   `--keep-branch` always keeps), drops the handoff file and the roster
   row, and appends a line to the fleet-doctor log (`--dry-run` shows the
   plan). A seat never removes its own worktree, and nobody runs a bare
   `git worktree remove` on a seat: a tree removed outside `seat-retire`
   stays on the roster and reads ORPHANED / FLEET-DEGRADED on every doctor
   pass until it is recreated or retired. Deleting the session is the
   operator's half too (a CLI seat: close its Terminal).

### Operator signals (orders arriving AT a seat)

The operator's control channel to a seat is a FILE, not a chat message:
`tasks/signal/<worker>.md`, or `tasks/signal/all.md` for every seat at once.
It is written with `factory.sh signal <worker|all> "<order>"` (a file path
works too, for a long one; a second signal APPENDS, so a standing order is
never overwritten).

For a seat this means three things:

1. **A signal wakes you.** `factory.sh watch` includes `tasks/signal/` in its
   change signature, so an order ends an hour-long poll immediately - no
   queue-touch hack, no waiting for unrelated traffic.
2. **A signal blocks your next claim.** `factory.sh claim` REFUSES while a
   signal addresses your worker (or `all` that you have not yet acked),
   printing the order itself in the
   refusal. The addressee is the worker that claim RESOLVES (arg >
   `FACTORY_WORKER` > the `.factory-worker` pin > cwd branch), so a pinned
   seat is also a reliably addressable one. You cannot start new work before
   processing it - which is exactly the failure this replaced.
   (`FACTORY_FORCE=1` overrides; use it only when the order itself says to.)
3. **`signal-clear <your-worker>` is your acknowledgement - for a broadcast
   too.** Do what the order says FIRST, then `factory.sh signal-clear
   <your-worker>` and continue. For your own `<worker>.md` that deletes the
   file. For the broadcast (`all.md` - ONE file addressing every seat) the
   same command records YOUR ack in the ledger `tasks/signal/all.acked/
   <worker>` and leaves the file standing: it stops blocking you and keeps
   blocking every seat that has not acked yet (upstream, deleting it on the
   first ack released ten seats before they had read the order,
   2026-09-02). When both a per-seat order and a broadcast address you, the
   first `signal-clear` deletes your file and reminds you the broadcast
   still awaits its own ack: carry it out and `signal-clear <your-worker>`
   again. Never clear a signal you have not carried out, never `rm` it by
   hand (law 1), and never `signal-clear all` as a seat - that is the
   OPERATOR's hard delete of the broadcast and its whole ledger. A re-sent
   `signal all` RESETS the ledger: a changed order re-blocks every seat,
   the ones that acked the old text included, so read it again. Since
   2026-10-03 (upstream PR #17) an ack is of the TEXT you were shown: the
   refused claim keeps a copy of each order it printed
   (`tasks/factory/signal-shown/<you>.all|.own`), your `signal-clear <you>`
   acks the broadcast it showed and deletes only the part of your own file
   it showed - an order appended after that stands, and your next claim
   prints it - and an ack marker names the broadcast's cksum, so a
   broadcast re-sent between your refusal and your ack is never acked
   unread. Scripted callers (the console, an app) say what they read:
   `signal-clear <worker> --if '<crc> <size>'` (cksum of the order as read)
   acks or clears only while that text stands. The operator withdrawing a
   seat's order between its refusal and its ack uses `--if` too - a plain
   `signal-clear <seat>` in that span acts as the seat's ack of what it was
   shown. `factory.sh signal-list` and the board's **Operator signals**
   section show what is still unacknowledged - each per-seat line is a
   seat that cannot claim, and the broadcast line carries its ledger
   (`all  12m  acked 3: claude-seat-2 claude-seat-3 ...`). A broadcast ack
   does NOT wake the other seats' parked watches (nothing for them to react
   to); a broadcast landing or being re-sent does.

Cross-session messages remain a HUMAN channel, ADVISORY only: read them, but
they are not the control plane. Upstream (open-saas, 2026-08-19) a five-seat
hand-off by message failed three ways in one hour - messages parked unread
behind hour-long watches; on wake the queue notification and the message
competed and seats acted on fresh queue state first (one claimed new work
despite a do-not-claim order); and three of five seats improvised their own
reading of the order. An order that matters arrives as a signal file.

### Signaling the operator

The operator scans several consumer seats at a glance; these banners are the
contract. Each is the FIRST line of a chat message - never buried
mid-paragraph, nothing above it.

On every claim, before starting work:

```
=== CLAIMED TASK <id> ===
Path:  tasks/claimed/<worker>/<filename>.md
About: <one or two sentences: what will change, where, and how it will be verified>
```

The moment you need a human - a credential, a permission, a decision only the
operator can make:

```
!!! HUMAN NEEDED - <short reason> !!!
Blocked on: <the exact command, question, or approval required>
Meanwhile:  <idling, or the unblocked parts you are continuing>
```

Do not wait silently, and do not wait forever: if no human responds within
about 30 minutes and the task can park safely, integrate or stash what is
coherent, then park - and park into the RIGHT place. When the block is
operator INPUT (a decision, credential, or clarification), first edit your
claimed file (you own it): add `lane: operator` to the front matter and a
`## Needs from operator` section stating the exact question and what
unblocks; THEN `factory.sh requeue <id> "parked: needs operator"`. It lands
in the operator's inbox (the OperatorTasks console) instead of bouncing seat
to seat. A park for any other reason (transient environment, pending split)
carries no lane line and returns to the general queue. Announce the parking,
claim the next task. A parked task beats a seat blocked for hours - and law 8
exists precisely because remote auth is the classic way to get stuck.

## The operator seat (operator-directed work)

One STANDING worktree + venue, reserved for work the operator directs
interactively - the sessions Dominic opens to build, investigate, or verify
something outside the queue's flow:

- **Where**: `.claude/worktrees/operator`, branch `claude/operator`, built
  with the same seat bring-up recipe (own `ICP_HOME`, port-0 venue, #dev
  posture rhythm). It is a seat like any other to git and to the merge
  protocol. It stays at that path (a live seat is never moved under a
  running venue) although `.claude/worktrees/` is the desktop app's GC'd
  pool: it is an app-made desktop worktree, which the untracked-dir GC
  passes over, a standing desktop session keeps it recently-active, and
  `.worktree-keep` at its root is the keep-sentinel belt - dropped BY HAND
  (the operator's interim shield of 2026-10-31, task 1793461559) or by
  `worker-pin` run here (task 1793616271): the fleet doctor's walk skips
  this tree before its sentinel drop, so nothing else re-drops it. Should
  the GC ever take it, rebuild it by hand from `claude/operator` (never
  `seat-recreate`, which mints consumer seats under the seat root) and
  re-pin it (`worker-pin`, or the hand-written line below). Consumer seats
  mint under the seat root (`factory.sh seat-root`), never here.
- **Identity - ONE operator principal, two spellings.** The seat IS
  pinned: `.claude/worktrees/operator/.factory-worker` reads
  `claude-operator` (the flattened branch), written BY HAND - `printf
  'claude-operator\n' > .factory-worker` at the worktree root, one line,
  nothing else - so that `claim`/`requeue`/`done` run anywhere inside the
  tree, `factory.sh worker`, and `factory.sh executor-env` (which refuses
  to mint an identity line from an unpinned tree) all resolve
  `claude-operator` for the session and for the subagents it spawns -
  "pinned so its claims resolve", the engine's own words at the fleet
  doctor's overlay skip. `export FACTORY_WORKER=operator` (or
  `=claude-operator`) for a session is the same declaration. Everywhere
  the engine compares identities the two spellings are one principal:
  `.githooks/pre-commit` (guards B and C), `scripts/factory_guard.sh`
  (`factory_seat_identity` / `factory_primary_guard`), the fleet doctor's
  overlay skip, and - through `same_principal()` (scripts/factory.sh,
  "MULTI/DEX overlay: operator == claude-operator", task 1793613786) - the
  two law-3 belts, `warn_owner_mismatch` (`done` / `requeue`) and
  `merge_lock_claim_check` (`merge-lock acquire --task`, `merge-land
  --task`). `claim --operator` stamps the literal `operator` and files
  under `tasks/claimed/operator/` regardless of how the seat resolves
  (1793613786 kept the stamp and taught the belts instead), so an
  operator-claimed task is closed and merged from this seat under either
  spelling with no law-3 noise; a foreign claim still warns and is still
  refused.
  **Never adopted as a consumer seat, never respawned** - and what
  guarantees it is the fleet doctor's OVERLAY SKIP on the pin, not the
  absence of a pin: the pinned-worktree walk passes over any tree whose
  pin reads `operator` or `claude-operator` (or whose basename is
  `operator`) before any verdict, roster adoption, sentinel drop or
  respawn (scripts/factory.sh, "the OPERATOR seat is pinned
  (claude-operator)"), so the seat has no doctor row and stays off
  `tasks/factory/fleet-roster`. **`worker-pin` is ALLOWED here** (task
  1793616271): `roster_register` - which `cmd_worker_pin` and
  `handoff-clear`'s pin refresh both call - skips the roster row and the
  `factory-seat` tripwire for the operator principal by the SAME predicate
  as the doctor's walk (`operator_seat`: pin `operator` or
  `claude-operator`, or basename `operator`) and says `operator seat: not
  a roster seat (MULTI/DEX overlay)` on stderr, so the command writes the
  pin and `.worktree-keep` only. Why that skip had to exist: the doctor's
  ORPHANED pass reads the roster for every seat its walk did not mark seen
  - the skip fires before the marking - so a roster row for this tree read
  `ORPHANED operator ...` with the summary `FLEET-DEGRADED 1 missing of N`
  on EVERY pass, and - until task 1793621537, below - nothing but
  `seat-retire` dropped a row - a command the
  ENGINE REFUSES on this seat (task 1793617638): `cmd_seat_retire`, finding
  no roster row, resolves the tree from `git worktree list` by basename -
  exactly this seat's off-roster shape - and once worker and branch have
  resolved refuses the operator principal by the same `operator_seat`
  predicate, `seat-retire refused: '<seat>' is the OPERATOR seat (pin
  <pin>) - it is wound up by hand, never by this command (MULTI/DEX
  overlay)`, with no `FACTORY_FORCE` override and `--dry-run` refusing the
  same way (before 1793617638 only this sentence and the live-cwd check -
  absent after a handoff, an app restart or a reboot - stood between
  `seat-retire operator` and the removal). `handoff-clear operator` run here
  goes through the same door. A roster row this principal nonetheless holds
  (a pre-1793616271 `factory.sh`, a hand edit, a restored roster backup) is
  STALE BY CONSTRUCTION and the fleet doctor's own pass drops it (task
  1793621537, `roster_drop_operator_row` - `roster_remove`'s second caller,
  by the same `operator_seat` predicate): `roster: dropped stale
  operator-principal row <seat> (MULTI/DEX overlay)` on stderr plus a
  fleet-log record, never an `ORPHANED` verdict, never counted missing,
  never a `fleet-orphaned` anchor; `--dry-run` says `would drop` and leaves
  it - no hand edit of `tasks/factory/fleet-roster` is ever needed. The
  hand-written pin stays a valid shape; after a move or a rebuild
  `worker-pin` is the simpler one (it drops the sentinel too).
- **What runs there**: operator-directed development; the OperatorTasks
  console; pre-rollout verification (exercise merged main against a fresh
  venue before the operator ships it anywhere).
- **What does NOT run there**: the actual remote rollouts. Those run from
  the PRIMARY checkout on merged main with the operator present - the
  untracked rollout config and API-key files live only there, and the `icp`
  web-auth must be foregrounded where the operator can complete it.
- **Why it exists**: it keeps operator-directed work from colliding with
  the consumer fleet (no shared branch, no shared venue) and keeps the
  primary checkout clean for its four jobs (law 5). Interactive sessions
  claim nothing unless asked; when operator-directed work turns out to be
  queue-shaped, file it (producer procedure) instead of doing it inline.
- **Lifecycle**: standing - hand it off to refresh context (its successor
  clears the handoff file with `handoff-clear operator` like any seat: the
  pin refresh takes the operator skip, the Identity bullet - task
  1793616271), wind it up only deliberately, BY HAND - `seat-retire`
  refuses this seat (the Identity bullet). Its work merges
  through the same lock, gates included.
  Unlike worker seats it MAY be a desktop session - it exists for
  interactive work with the operator, and the desktop is the operator's
  surface.

The PRIMARY checkout's own venue (the `:8000` one, `cold_start.sh` default
`#play` via `play_start.sh` - seeded AMM + insurance + bots) stays what it
is today: the operator's canonical local demo venue. Factory seats never
point at it, never reap it, never "fix" it.

## Failure playbook

- **Claim raced / reprioritize raced**: normal; the command already retried
  or told you nothing changed. Re-list and continue.
- **Claim refused on an operator signal**: not a failure - the refusal
  prints the order. Carry it out, `factory.sh signal-clear <you>`, claim
  again.
- **Stale claim** (session died mid-task): operator (only) inspects the
  worktree, salvages commits worth keeping, then `factory.sh requeue <id>`.
- **Executor died silently** (reaper-killed on the 30-min grid, a sleep,
  an app restart - anything that kills a subagent mid-turn kills its
  completion notification with it, and a seat that only waits waits
  forever): the liveness watchdog (executor mode) is the antidote -
  `executor-watch` fires EXECUTOR-STALE within ~25 idle minutes (or its
  own reaper-kill notice wakes the seat sooner; both are the same
  signal), and the seat judges recovery from disk. A watch or watchdog
  ending `[killed]` on the 30-minute grid fleet-wide is the harness's
  memory-pressure reap: read the obituary line above the marker (SIGTERM +
  instant + ppid alive = the reap; none = SIGKILL, something else), check
  the seat's boot line carries the boot environment (`factory.sh boot-env`;
  `CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1` is one of its words - a
  fleet booted without it keeps reaping until respawned), and treat each
  kill as a routine re-arm signal meanwhile. Outside the sessions,
  `scripts/factory.sh fleet-doctor` (the operator's launchd job) names a
  parked seat STALLED within 65 min and, with `--respawn`, replaces it.
- **Executor parked on a background waiter** (its backgrounded command
  finished - exit marker in the task output - but the completion
  notification never resumed the agent; it shows "running" with zero
  tool calls since): DEAD on the FIRST watchdog firing, not
  alive-but-slow - TaskStop the zombie and run executor loss recovery.
  Never nudge-and-wait: a message lands only at the agent's next tool
  round, which for a parked agent never comes. The same holds for a BUSY
  executor with agent teams on: a teammate's inbox is read when its turn
  ends (upstream, one ran 106 tool calls past a hold order and merged,
  2026-09-29) - TaskStop is the stop, a message is not.
- **Merge lock wedged**: >30 min old is broken automatically by the next
  acquirer; younger, wait or `factory.sh merge-lock release <owner>` if you
  KNOW the owner is dead (`merge-lock status` names it).
- **Merge-lock acquire refused on the posture law**: your branch carries a
  `#dev` flip or the port-0 icp.yaml edit in a COMMIT. Restore the
  committed defaults on the branch (revert the offending hunk), commit,
  re-acquire. `FACTORY_FORCE=1` exists for the exceptional legitimate
  posture-touching task - say so out loud when you use it.
- **Primary checkout mid-merge or index.lock**: stop, escalate to the
  operator; never `rm` git lock files while a GUI client may be open
  (`merge-land` refuses on both, releasing the lock).
- **`merge-land` refused or FAILED**: read the line - the lock is free or
  held for another branch (step 6c first), the primary resolved to YOUR
  worktree (the self-merge shape), "nothing to merge" (your commits may
  already be on main - `git log --oneline -3 main`; law 5), main moved
  (step 6a again), `lint-ratchet.sh` FAILED, the claim belt found your task
  back in the queue, or main did NOT move after the merge. Every refusal
  after the lock check released the lock and landed nothing: fix,
  re-acquire, run the door again - never `done` without its `merged <sha>`
  line.
- **Claim refused `RECYCLE-REQUIRED`, or a replica zombie** (`icp network
  status` answers and the gateway serves, but the launcher is dead -
  descriptor + pocket-ic children alive - and deploys fail): run
  `scripts/factory.sh replica-recycle` from your worktree - the allowlisted
  door; it acts on the calling seat's own worktree only (pin-resolved; the
  primary is refused with no override), runs the sanctioned stop under a
  kill-after watchdog, then kills ONLY the pocket-ic/launcher processes
  lsof-attributed to that worktree's network state dir, removes the
  per-worktree network lock and a descriptor nobody serves, and prints
  RECYCLED | RECYCLED-ZOMBIE | NOTHING-RUNNING (`--dry-run` shows the
  attribution first). Then the full re-bring-up (posture rhythm). Upstream
  proved both shapes on 2026-09-02 (task 1788330585): on the zombie the raw
  `icp network stop` even reports "stopped successfully" while the orphan
  main lives on - only the attributed fall-through clears it. Never wait
  for the operator to stop it by hand, and never pkill.
- **Seat worktree vanished - `ORPHANED` on the doctor, `FLEET-DEGRADED n
  missing of N`** (the seat's tree is gone while the roster still lists
  it; a CLI session may survive as a dead husk whose cwd no longer exists -
  it can never claim again). The usual actor is the Claude desktop app's
  WorktreePool "untracked-dir GC" over ITS pool root `.claude/worktrees/`
  ("Where a seat lives", TaskConsumer setup; `grep 'untracked-dir GC'
  ~/Library/Logs/Claude/main.log`). Read the doctor's line first - it
  carries the first pass that saw the tree missing, the branch's
  ahead/behind, and whether `.git/worktrees/<seat>` survived (present =
  `rm -rf`; absent = `git worktree remove`/`prune` - the GC's shape) plus
  the parent dir's mtime bracketing the deletion. Then the operator picks:
  `scripts/factory.sh seat-recreate <seat>` to rebuild it (husk killed,
  branch fast-forwarded when 0 ahead, worktree UNDER THE SEAT ROOT
  `.factory/seats/<seat>` - a legacy roster path is relocated, the tree
  being gone - + pin + takeover handoff + spawn; the successor runs the
  bring-up recipe) or `scripts/factory.sh seat-retire <seat>` to drop it
  from the roster. Never a hand `git worktree remove` / `prune` / `rm -rf`
  on a seat: the roster is what makes the shrinkage visible, and a blanket
  `git worktree prune` erases the admin-dir evidence of every other orphan.
  `seat-retire` refuses any tree a live process stands in. A seat still
  under `.claude/worktrees/` is belted by `.worktree-keep` (dropped by
  `worker-pin` and every doctor pass) until its own retirement moves it.
- **AppleEvent timed out on a spawn - `spawn PENDING` / the doctor's
  `UNMANNED (spawn pending since <instant>, Terminal AppleEvents timing
  out ...)`** (`osascript` answered `AppleEvent timed out. (-1712)` to the
  boot `do script`): Terminal is not answering, but the event may still
  execute - it sits in Terminal's queue and runs when Terminal unwedges,
  minutes or hours later (upstream, 2026-09-16: a four-hour queue flushed
  nine boots onto one seat at once; task 1789588684). Never boot by hand
  until the pending stamp `tasks/factory/spawn-pending/<seat>` clears (6 h,
  `FACTORY_SPAWN_PENDING_TTL`, or the moment the process appears) or
  `pgrep -f -- '--name <sname>'` shows one process for the seat - the
  prioritizer's stamp is keyed `prioritizer` and follows the same rule
  (its door is `prioritizer-boot`, task 1792506027). The doctor reports
  the seat and respawns nothing meanwhile; `handoff-clear` and a live
  process both spend the stamp. What to fix is Terminal itself: a modal
  sheet or dialog in front of it, a hung tab, or an Automation permission
  prompt (System Settings > Privacy & Security > Automation) waiting for a
  click. If the seat MUST come up sooner and you have confirmed no process
  carries the name, `FACTORY_FORCE=1 scripts/factory.sh spawn-successor
  <seat>` (`... prioritizer-boot` for the prioritizer) overrides the stamp
  - and the seat-side DUPLICATE-SESSION gate (TaskConsumer setup) ends
  whichever boot arrives second.
- **`FLEET-LOGGED-OUT` on the doctor / every seat ends its turn on `Login
  expired · Please run /login`**: the CLI's Keychain credentials expired
  for every CLI process at once (the desktop app's login is a different
  item and does not count). ONE login heals the fleet - `claude auth login`
  as the seat user or `/login` in any one seat window - then the doctor's
  next `--respawn` pass replaces each parked `LOGGED-OUT` seat (or by hand:
  `kill -TERM <pid>` + `factory.sh spawn-successor <seat>` per parked seat,
  `prioritizer-boot` for the prioritizer); every respawn is held until the
  login reads good (executor mode, "CLI login expiry").
- **Seat venue dead** (calls error "not running" while :8000 answers): your
  master died - that :8000 gateway is someone else's (never touch it).
  Re-run bring-up steps 4-6; state is gone, so reseed.
- **Every icp command hangs machine-wide**: a wedged parked probe holds
  icp-cli's global flock. Find YOUR stuck probe's PID and kill it (never a
  pattern); if none is yours, report to the operator - another session owns
  it. This is why unattended status polls must carry kill-after watchdogs
  (law 10).
- **spawn-successor failed** (no osascript grant, CLI missing): the handoff
  file is still pending, so the seat shows on `handoff-list` and the board -
  the operator boots it by hand with the printed boot line. Nothing is lost.
  (`spawn PENDING`, exit 3, is NOT this case - see the AppleEvent entry:
  nobody boots by hand while the stamp stands.)
- **Duplicate tasks discovered**: consumer archives one as
  `superseded "dup of <id>"`.
- **Task too vague to act on**: `done <id> abandoned "fails law 6: <why>"`
  and file a producer-quality replacement if you can; otherwise it returns
  to the producer via the board.

## Operator guide

Boot prompts (one session each; consumers each get their own worktree):

- Consumer (3-5x; CLI Terminal, executor mode - never a desktop session,
  per the worker doctrine): from the seat's worktree run
  `$(scripts/factory.sh boot-env) claude --model claude-fable-5-1 --name
  'multidex-executor-<seat>' "Read
  .claude/skills/mdex-software-factory/SKILL.md. You are a TaskConsumer in
  executor mode taking over the seat at <worktree path>. Work the queue
  continuously."` - the prefix is the boot environment (the paragraph after
  this list; `spawn-successor` applies it itself through `boot-exec`), and
  the `--name` shape is the same one `spawn-successor` mints (prefix =
  `FACTORY_PROJECT`, else the primary checkout basename minus
  `-ng`/`-main`, here `multidex`), so hand-booted and self-spawned seats
  list identically. A NEW seat's worktree is minted under the seat root,
  never under `.claude/worktrees/` (the desktop app's GC'd pool): `git
  worktree add "$(scripts/factory.sh seat-root <seat>)" -b claude/<seat>
  main`, then the bring-up recipe inside it - or `scripts/factory.sh
  seat-recreate <seat> --no-spawn`, which mints and pins the seat and
  writes a hand-boot handoff file for it (its deps step is skipped here:
  no `scripts/bootstrap.sh`; the seat runs bring-up steps 1-6 itself).
- Prioritizer (exactly 1): `scripts/factory.sh prioritizer-boot` from the
  primary (task 1792506027) - the SAME spawn path a seat's succession
  takes: session name `multidex-prioritizer`, the pre-spawn guard by name
  (a live one refuses with its pid; `FACTORY_FORCE=1` overrides), the boot
  environment applied by `boot-exec` inside the window, a titled Factory
  window, the `spawn PENDING` third outcome (exit 3) with the stamp
  `tasks/factory/spawn-pending/prioritizer`. The prompt (*"Read
  .claude/skills/mdex-software-factory/SKILL.md. You are the
  TaskPrioritizer. ... Run continuously."*) lives in the token the command
  writes just before the spawn, `tasks/handoff/prioritizer.md`, which the
  booted prioritizer clears as its first act (`handoff-clear
  prioritizer`); the typed line carries neither the prompt nor the
  environment. `FACTORY_SPAWN_DRYRUN=1` prints the plan. The fleet doctor's
  respawn mode calls the same door for an UNMANNED or STALLED prioritizer
  (below), so a fleet revive keeps no hand step for it - and no
  operator-local boot script is needed. Only a DESKTOP-session prioritizer
  (your choice, below) still takes the prompt by hand: *"Read
  .claude/skills/mdex-software-factory/SKILL.md. You are the
  TaskPrioritizer. Run continuously."*
- Producer (ad hoc): *"Read .claude/skills/mdex-software-factory/SKILL.md.
  You are a TaskProducer. File tasks for: `<instruction / audit / corpus
  rows>`."*
- OperatorTasks (on demand, with you at the keyboard): *"Read
  .claude/skills/mdex-software-factory/SKILL.md. You are the OperatorTasks
  console. Show me my inbox."*
- Operator seat (standing): *"Read
  .claude/skills/mdex-software-factory/SKILL.md. You hold the operator seat
  at .claude/worktrees/operator - bring it up if needed and stand by for
  directed work."*
- WarmSpare (desktop-era, transition only - CLI seats self-spawn): *"Read
  .claude/skills/mdex-software-factory/SKILL.md. You are a WarmSpare.
  Prepare and wait."*

**The boot environment** (`factory.sh boot-env`, 2026-09-24): every factory
session boots with ONE word list in front of its `claude` command -
`spawn-successor`'s and `prioritizer-boot`'s boot lines apply it through
`factory.sh boot-exec` (the typed line must stay under the tty's 1024-byte
startup input limit - a line typed by `do script` while the window's shell
is still starting is split there - so the environment and the prompt are
read INSIDE the window from the handoff file, and the line stays a few
hundred bytes); a hand boot writes `$(scripts/factory.sh boot-env)` before
`claude`. It SCRUBS the markers a Terminal window inherits from whichever
process launched Terminal.app (upstream, 2026-09-07: a desktop session's
osascript did, so every window opened since carried that session's
`CLAUDE_CODE_CHILD_SESSION=1` - transcript saving OFF, the CLI's footer says
so, no seat auditable or resumable - plus its session id, messaging socket
and `DISABLE_MICROCOMPACT=1`) and SETS what a seat needs:
`CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1` (the reap opt-out, task
1788458457), `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1` (transcripts),
`BASH_MAX_TIMEOUT_MS=3600000` (the hourly idle watch),
`BASH_DEFAULT_TIMEOUT_MS=600000` (a 10-min Bash default),
`CLAUDE_CODE_EFFORT_LEVEL=max` (the variable the CLI READS - until
2026-10-03 the list set `CLAUDE_EFFORT=max`, which is only what the CLI
reports to hooks and Bash, so booted seats ran at the user's settings level;
upstream PR #17), `DISABLE_AUTOUPDATER=1` (no self-update mid-seat). The
variables are read at session start: a session booted without it keeps every
inherited marker until its next respawn (`watch` clamps itself to 540 s
there and says why). Relaunching Terminal.app from the Dock, once every
window is closed, clears the inherited set at its source; the scrub makes
boots correct either way.

**Your own work on the primary's main declares itself: `FACTORY_DIRECT=1`**
(task 1791133471). While any CONSUMER seat is pinned (a factory is running;
the operator seat's pin does not count - task 1793617711), the primary's
pre-commit hook (`.githooks/pre-commit`, guard C) refuses an identity-free
commit on main - that is exactly what a drifted executor subagent looks
like (upstream's 1dc9df2fa, 2026-10-04). So a direct round
(a docs or corpus commit on main, a release tag, a hotfix) commits as
`FACTORY_DIRECT=1 git commit ...`, and your own primary deploys and
rollouts run as `FACTORY_DIRECT=1 scripts/deploy.sh ...` (or export
`FACTORY_WORKER=operator` - or `claude-operator`, the operator seat's own
spelling, one principal to every guard ("The operator seat") - for the
session: the declared operator identity passes the hook and the guard
alike). `scripts/factory_guard.sh` reads `FACTORY_DIRECT=1` TODAY - its
`factory_primary_guard` carries the same belt (re-synced 2026-10-31):
with no identity it REFUSES a REMOTE deploy (`deploy.sh
cloud|engine|subnet`) from the primary while any consumer seat is pinned
- "REFUSED - a REMOTE deploy from the primary with NO seat identity while
a factory is running" - and leaves a LOCAL deploy or `cold_start.sh` run
untouched (the :8000 venue is yours).
Seat merges (`git -C <primary> merge --no-ff`, the `merge-land` door) need
nothing: git-merge never runs pre-commit. With no CONSUMER seat pinned
anywhere the guards fail open as before (the operator seat's pin alone does
not count). The refusal text names the marker and the remedy;
`FACTORY_FORCE=1` remains the blanket override.

Only consumers are workers under the doctrine: the prioritizer, producers,
the OperatorTasks console and the operator seat are operator-surface
sessions (desktop or CLI, your choice; no executor mode: these roles have no
seat to execute on). The prioritizer's CLI boot is `prioritizer-boot`
(above) - the project-prefixed `--name`, the boot environment and the window
title come with it (an idle prioritizer's backgrounded `watch` was the
reap's other standing victim, so the environment matters). A CLI boot of a
producer or the console is a hand boot: give it a project-prefixed `--name`
such as `multidex-producer` for listing hygiene and the same
`$(scripts/factory.sh boot-env)` prefix the consumer boot carries.

Consumer seats announce every claim with a `=== CLAIMED TASK <id> ===`
banner, any blockage with `!!! HUMAN NEEDED !!!`, and model drift with
`!!! MODEL !!!` (a seat flipped off Fable 5.1 keeps working but asks - once per
claim cycle - to be flipped back via the model picker). All alarms start
`!!!`, so scan seats for that. Seats never touch remote targets and never
push (law 8), so an unattended factory cannot wedge itself on remote auth -
and nothing leaves this machine without your hand.

**Giving a seat an order: signal it, do not (only) message it.**
`scripts/factory.sh signal <worker|all> "<order>"` writes
`tasks/signal/<name>.md`; it wakes every parked `watch` at once and REFUSES
that seat's next `claim` (printing the order) until the seat acknowledges it
with `signal-clear`. Use it for anything the fleet must actually obey - stop
claiming, hand off, drop everything and do X - and use `all` for a broadcast.
`signal-list` (or the board's **Operator signals** section) shows which
orders are still unacknowledged; each per-seat line is a seat that cannot
claim, so a forgotten signal is a stopped seat. A broadcast is acknowledged
PER SEAT: each seat's `signal-clear <its-worker>` lands in the ledger
`tasks/signal/all.acked/`, the broadcast line lists who has acked (`all
12m  acked 3: claude-seat-2 ...`), and the file keeps blocking the rest
until you delete it - `signal-clear all` is YOUR hard delete of the file and
the ledger, once every seat that matters has acked (or the order is moot). A
re-sent `signal all` appends the text AND resets the ledger, so a changed
order re-blocks every seat. Withdrawing a seat's order between its refused
claim and its ack: `signal-clear <seat> --if '<crc> <size>'` (the cksum of
the text as read) - a plain `signal-clear <seat>` in that span acts as the
seat's ack of what it was shown. Chat messages to a session remain
fine for conversation, but upstream they parked unread behind hour-long
watches and lost races against fresh queue state - they are advisory, the
file is the control plane. (A broadcast blocks the operator's own
`claim --operator` too until the operator's worker has acked it -
`signal-clear <operator-worker>` - or `FACTORY_FORCE=1` is the way through.)

The board is `tasks/factory/index.md` (regenerate anytime with
`scripts/factory.sh index`). Its **Operator lane** section is your queue:
work no seat will ever pick up - rollouts, pushes, decisions. Take one with
`scripts/factory.sh claim --operator` (allowed from the primary and the
operator seat) and archive it with `done` like any other; run the
OperatorTasks console when the lane has accumulated. Scale by adding/stopping
consumer sessions - nothing else changes. To REFRESH a seat's context, say
**"hand off"** (or "hand off now"): it settles its claim, keeps its worktree
and venue, and replaces itself - a CLI seat spawns its own successor
Terminal via `factory.sh spawn-successor` and exits its claude process
itself (you only clean up if the spawn failed, which `handoff-list` still
shows); a legacy desktop seat tries the warm-spare pool, then a chip.
The boot prompt is ALWAYS also written to `tasks/handoff/<worktree>.md`, so
if the app restarts before a successor exists, the pending seats are still
listed: `scripts/factory.sh handoff-list`, or the board's **Seats awaiting
successor** section. Boot each, and the successor clears its own file.

**Zero-residue succession windows (one-time Terminal setup).**
`spawn-successor` appends `; exit 0` to the command it runs, so the spawned
window's shell exits cleanly the moment claude exits (even when the handoff
self-kill ends claude by signal, 137/143), and applies a Terminal settings
set named **"Factory"** to the window it creates. With that profile in
place, a retiring seat's window closes itself instead of piling up at a dead
prompt - one window per succession otherwise. The one-time setup: Terminal >
Settings > Profiles, duplicate any profile, name it `Factory`, and under
Shell set "When the shell exits" to **Close the window**. Only spawned
windows get the profile; your own windows keep default behavior. If the
`Factory` settings set does not exist the spawn still proceeds and its
success banner names this manual step - the windows just linger for you to
close. The prioritizer's window is titled and profiled the same way by
`prioritizer-boot` (task 1792506027 - it IS the spawn path). Hand-booted
windows (a producer, the console) are not titled by the factory: title them
yourself with Shell > Edit Title. (Alternative, an optional future lane -
noted, not implemented: a tmux-managed fleet has no windows to leak at all -
one detached session per seat, `tmux ls` as the roster.)

**Fleet doctor (one-time install).** `scripts/factory.sh fleet-doctor
--launchd-plist > ~/Library/LaunchAgents/multidex.factory-fleet-doctor.plist
&& launchctl load -w ~/Library/LaunchAgents/multidex.factory-fleet-doctor.plist`
runs the stall check from the primary every 15 min, logging to
`~/Library/Logs/multidex-fleet-doctor.log` - report-only until you opt in:
once a day of log shows no false STALLED lines, add
`FACTORY_FLEET_RESPAWN=1` to the plist's EnvironmentVariables and reload
(upstream's burn-in was eight days, 2026-09-03 to 09-11), and from then on a
parked seat is revived within 15 min with nobody present. Respawn mode
covers the PRIORITIZER too (task 1792506027), under the name guard: an
UNMANNED prioritizer (no `multidex-prioritizer` process) or a STALLED one
(board not regenerated past the 65-min bar with claimable work queued) has
its parked pid killed by pid (TERM then KILL) and `scripts/factory.sh
prioritizer-boot` run in the same pass - `--dry-run` prints `would: ...
prioritizer-boot` - and its own spawn-pending stamp
(`tasks/factory/spawn-pending/prioritizer`) holds respawns exactly like a
seat's; the report-only UNMANNED row's note reads `boot: scripts/factory.sh
prioritizer-boot`. One respawn outcome is neither revived nor failed:
**`spawn PENDING (AppleEvent timed out - Terminal may still run it)`** -
Terminal has QUEUED the boot and executes it when it unwedges (upstream,
2026-09-16: fifteen timed-out passes over four hours flushed as NINE
sessions on one seat; task 1789588684). The spawn writes
`tasks/factory/spawn-pending/<seat>` and every later pass prints the seat as
`UNMANNED ... spawn pending since <instant>, Terminal AppleEvents timing out
- check Terminal: a modal, a hung tab, or Automation permission` and does
NOT respawn it - until the stamp expires (`FACTORY_SPAWN_PENDING_TTL`,
default 6 h) or the seat's process appears. The remedy is Terminal, not
another boot (the failure playbook's AppleEvent entry). `scripts/factory.sh
fleet-doctor` by hand any time is the one-glance fleet check. Its last line
is one of `FLEET-OK seats N` / `FLEET-STALLED n stalled, m unmanned of N
seats` / `FLEET-DEGRADED n missing of N seats` / `FLEET-LOGGED-OUT n logged
out, ...` (the CLI login expired - one login heals every seat, see "CLI
login expiry" in executor mode; every respawn is held until then) - the
third means a seat on the roster (`factory.sh seat-roster`;
`tasks/factory/fleet-roster`, populated by every `worker-pin` and adopted
from the pinned worktrees on the doctor's passes, so a running fleet needs
no seat action) has LOST its worktree, and stays degraded until you run
`factory.sh seat-recreate <seat>` (rebuild: husk killed, branch
fast-forwarded when 0 ahead, worktree under the SEAT ROOT
`.factory/seats/<seat>` + pin + takeover handoff + spawn - `--no-spawn` to
boot by hand; a legacy `.claude/worktrees/` roster row comes back under the
seat root, same branch, same pin, and the banner says `was <old path>`) or
`factory.sh seat-retire <seat>` (drop). Both are operator commands run from
the primary; the doctor never does either on its own. Seats still at the
legacy location are tagged `legacy-location` on every doctor line and carry
the `.worktree-keep` belt; they migrate only through their own retirement,
never while live. After a `--respawn` kill, the doctor row's own `newest
write <instant> from: <source>` in the log is what it saw when it judged
the seat - read it before any activity tail.

**FSEvents remedy (one-time install, with your password - task
1791198753; NOT installed here as of 2026-10-31).** The fleet doctor,
`replica-doctor.sh` and the venue scripts probe FSEvents delivery through
`scripts/lib-fsevents.sh`; the wedge that parks every fresh `icp network
start` (the `WEDGED (launcher parked, port file unread)` verdict of
bring-up step 4) has only a root remedy - restarting fseventsd - and seats
never run sudo. The unattended, REPORTED restart arms only after your
one-time `sudo` install of the root half: a root-owned wrapper under
`/usr/local/sbin/` plus ONE NOPASSWD line under `/etc/sudoers.d/`
(upstream's `sudo scripts/ops/install-fsevents-remedy.sh`, idempotent,
`--print` shows the plan without root, `--uninstall` is the opt-out; the
installer and the wrapper are not yet in this repo - porting them is an
operator task). Until it has run, every site reports "NOT permitted" and
prints the paste line for you, as today - the skill promises nothing more.
Once armed, every restart it performs is reported: the site's `FSEVENTS
RESTARTED unattended` line, a ledger under `~/Library/Logs/`, the
fleet-doctor log + its `fsevents restarts:` header, the board's "FSEvents
restarts" line, and a macOS notification; one attempt per run, a second
DEAD is a reboot.

To RETIRE a seat, say **"wind up"** (finishes its current task, then stops
its venue through `replica-recycle`, reports, stops) or **"wind up now"**
(requeues the current claim instead of finishing); then run
`scripts/factory.sh seat-retire <seat>` from the primary - the ONLY
sanctioned removal: it kills the seat's named process, refuses while any
OTHER live process has its cwd inside the tree (lsof), recycles the
replica, removes the worktree and its git admin entry, deletes the merged
branch (an unmerged one is kept), drops the handoff file and the roster
row, and logs to the fleet-doctor log (`--dry-run` shows the plan). Seats
that self-retire on the context-hygiene rule hand off by default and wind up
only when their infrastructure is unhealthy. To drain the whole factory:
`factory.sh signal all "stop claiming and wind up"`, then `seat-retire`
each; `factory.sh list` empty + `claimed/` empty + `seat-roster` NONE =
drained. Emergency stop of one seat (died, no wind-up): requeue its claim
after salvaging the worktree, then `seat-retire` it.

### After a harness restart (app upgrade, machine reboot)

Everything durable survives: the queue, claims, the board, worktrees,
branches - and on an APP restart, the seat venues too (`icp network start
--background` daemonizes them out of the app's process tree; never restart
one for tidiness - a venue restart means a wiped seat venue and a full
reseed). Both locks self-heal (age break on the merge lock). Pending
operator signals survive as well (`factory.sh signal-list`) - an order given
before the restart still blocks its seat's next claim, which is the point.
CLI worker seats survive an app restart entirely - that is half of why the
worker doctrine exists. What does NOT survive: desktop sessions' in-flight
turns (killed mid-tool-call), every background watcher, in-flight executor
agents (the claim survives on disk - respawn one, losing only work since
the agent's last commit), and every staged successor CHIP - sessions are
conversations, not daemons, so after a restart the desktop half of the
factory is DORMANT until something speaks to each session. Nothing
corrupts; it pauses. (Planned relaunch? The one 30-second kindness
beforehand: `scripts/factory.sh merge-lock status` - if held, let that
merge finish.)

**The dead-watcher notice IS the resume signal (zero-touch resume).** On
relaunch the harness re-invokes each session with a notice like
"Background task stopped - no completion record was found" for its killed
watcher. Seats: that notice is NOT an anomaly to investigate or narrate -
it is the restart telling you to resume. Announce "restart detected -
resuming", then follow the seat checklist below, and never end your turn
having only described the dead task. With this rule, a healthy fleet
resumes itself and the message paths below are only for sessions the
notice never reached.

The chips are the one loss with a lasting cost, because a desktop seat whose
successor chip evaporated is simply gone from the fleet with nothing on
screen to say so. `scripts/factory.sh handoff-list` (or the board's **Seats
awaiting successor** section) is the durable record: boot one session per
line, in that worktree, with the prompt the file carries. Check it after
every restart, alongside `factory.sh list` and the claim ages - a seat killed
MID-TURN leaves a claim nobody is working, which the janitor guidance covers.
A machine reboot (or an expired CLI login) takes the prioritizer down with
the seats: `scripts/factory.sh prioritizer-boot` from the primary brings it
back - or the fleet doctor's next respawn pass does, within 15 min (task
1792506027; the doctor's UNMANNED row names the door). CLI seats a reboot
took down come back the same way: `scripts/factory.sh fleet-doctor
--respawn` (it writes each takeover handoff itself), or `spawn-successor
<seat>` per seat once its handoff file exists.

One-touch resume: message the TaskPrioritizer -
**"The harness restarted - resume the factory."** It re-reads the skill,
re-arms its watch, and fans the nudge out to every `MULTI/DEX worker — *`
session (plus the legacy `MULTI/DEX — worker started *` titles; its Resume
fan-out duty), reporting any it could not reach for you to message by hand.
Warm spares need nothing - idle is their job; they wake on activation as
always.

Seat checklist on waking from a restart (seats: follow this when nudged):
re-read the skill; re-export `ICP_HOME`; if you hold a claim, reconcile from
disk - the task file, `git status`, and your Factory log stamps are the
truth; an interrupted deploy re-runs idempotently (posture rhythm); an
executor agent that died mid-task: respawn one against the surviving claim;
a merge interrupted mid-flight: check `factory.sh merge-lock status` and
MERGE_HEAD in the primary (a dead run's locks self-heal) - then continue the
task. No claim: re-arm your watch and claim as normal.

After a machine REBOOT (not just an app restart) the seat venues are gone
and pocket-ic state does not persist: each seat's next live-suite need is a
fresh bring-up (steps 4-6 of the recipe; the start-stampede rule serializes
the fleet's starts one at a time, deploys then run in parallel). Budget for
that, or wind seats down before planned reboots.
