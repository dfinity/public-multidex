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
                 .ids/ (the append-only id allocator - never touch, never clean)
tasks/handoff/   one <worktree-basename>.md per seat waiting for a successor
                 session: the boot prompt, on disk, where an app restart
                 cannot reach it (`factory.sh handoff-list`)
tasks/signal/    operator ORDERS to a seat: <worker>.md, plus all.md (the
                 broadcast). Wakes every `watch`, blocks that seat's next
                 `claim` until acknowledged (Operator signals, below)
```

All six are gitignored runtime state. The tracked corpus in `docs/tasks/` is
unaffected and keeps its current conventions exactly. One further piece of
runtime state lives outside `tasks/`: each seat's `<worktree>/.factory-worker`
(gitignored too), the one-line identity pin factory.sh reads instead of
guessing a worker from the cwd's branch - see the TaskConsumer setup.

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
8. Consumer seats never touch a remote target and never push. Concretely
   out of bounds: `scripts/deploy.sh engine|subnet`, `deploy_to_engine.sh`,
   `deploy_to_subnet.sh`, `start_bots_*`/`stop_bots_*` for engine or subnet,
   `topup*.sh` against remote targets, anything that reads
   `scripts/.subnet.conf` or `scripts/.cloud-engine.conf`, and `git push`
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
       feature | hygiene | docs | parked   (advisory - the prioritizer's input)
touches: backend, tests            (see the vocabulary below; "suite" = repo-wide)
docfile: docs/tasks/W4-23-clamp-amm-half-spread.md   (the tracked brief, when one exists)
after: 1785709403, 1785709404      (ids that must archive first)
split_from: 1785709400             (lineage, when split)
lane: operator                     (waiting on the operator - execution OR input)
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

## Priority bands

The prioritizer expresses policy by renaming into bands: new priority =
`BB * 10^8 + (id mod 10^8)` - `factory.sh reprioritize <id> <BB>` computes
this - which preserves FIFO order among tasks in the same band.

| Band | Meaning |
|------|---------|
| 00 | emergency - drop everything (operator-directed, mostly) |
| 01 | security high - live venue / pipeline safety (the W1 shape) |
| 02 | security medium - tape & verifier integrity, #production hardening (W2/W3 shapes) |
| 03 | architecture / doctrine changes that would force rework of tasks landing after them |
| 04 | prerequisites - tasks other queued tasks name in `after:` |
| 05-09 | expedited, prioritizer's discretion |
| 17-21 | the natural zone: untouched creation keys (epoch seconds land here through 2036) = plain FIFO |
| 30 | hygiene, gate/instrument debt, low-severity findings (the W5 shape) |
| 40 | nice-to-have, cosmetic, docs polish |
| 90 | parked - claim only when nothing else remains |

Rationale in one breath: security before features so it is baked in, not
bolted on; the tape and the verifier are REQUIREMENTS under the transparency
doctrine, not features - rank them accordingly; architecture before the work
it would rework; prerequisites before their dependents; everything else FIFO.

Band 90 is not a way to say "never": it delays a claim, it does not refuse
one. Work a consumer must NOT run belongs in the operator lane
(`lane: operator`), a separate axis - a task can be band 01 and operator-lane
at once.

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
   cited (file:line, issue numbers, commit shas).
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
   citing the printed ids.
5. Report the filed ids/titles. Do not set priorities - that is the
   prioritizer's job; your `class:` field is its input. (Genuine
   emergencies: say so to the operator rather than guessing a band.)

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

- **Wake**: `scripts/factory.sh watch 500` blocks until
  queue/claimed/archive/signal change (prints CHANGED) or times out
  (TIMEOUT) - act on either, then re-arm. In a harness with background
  tasks, run `watch 3600` via a background Bash call and you will be
  re-invoked on completion; otherwise call it in the foreground repeatedly.
  Either way each pass costs nothing when idle.
- **Triage**: `factory.sh list`; read (`factory.sh show <id>`) tasks you have
  not seen before (the board is your memory of what you have triaged). Judge
  class and content per the band table - and check `after:` chains: a
  dependent must sort behind its prerequisites (band 04 the prerequisites
  forward rather than parking the dependent, when both matter).
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
  band distinction.
- **Board**: `factory.sh index` regenerates `tasks/factory/index.md` - the
  operator's one-glance view. Refresh it every pass. Its **Seats awaiting
  successor** section lists `tasks/handoff/` - seats that handed off and are
  sitting unmanned. Call any entry older than an hour out in your pass
  summary: a shrinking fleet is invisible otherwise (a CLI seat's
  self-spawn can fail; a desktop chip can die with an app restart). Its
  **Operator signals** section lists unacknowledged orders - each line is a
  seat that CANNOT claim until it acknowledges, so an old entry means a
  stopped or dead seat: call those out too.
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
  will be broken by the next acquirer automatically; mention it. And title
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
     visible - then `factory.sh done <id> done "<what ran, where>"`.
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
checkout, create/enter a worktree first (EnterWorktree, or
`git worktree add .claude/worktrees/<name> -b claude/<name>` from the
primary). Your worker identity is your branch name with `/` flattened to `-`.

**PIN IT ONCE, as your first act on the seat:**

```
cd <your-worktree> && scripts/factory.sh worker-pin
```

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
   own start: no port descriptor within ~90s means wedged - kill both
   halves of YOUR start (captured PIDs, never a pattern), remove your
   worktree's network lock, retry.
5. **Deploy + seed on #dev**: flip `DEPLOY_MODE` to `#dev` in
   `src/backend/main.mo`, run
   `bash scripts/cold_start.sh --mode full --no-simulate`, then RESTORE
   `#play` in the tree immediately (see the posture rhythm below).
   `--no-simulate` is non-negotiable on a seat: sim bots crash the local
   pocket-ic master silently within minutes, and N seats running fleets
   would flatten the machine besides. cold_start's stray-master reaper
   resolves ownership via `icp network status` (worktree-safe by
   construction since W1-06); if it nonetheless kills your OWN master,
   stop and re-verify rather than editing the reaper.
6. **Trust, then verify the controllers**: cold_start's "✓ alice promoted"
   line can lie (the settings update is `||`-swallowed). Before running
   anything, confirm
   `icp canister status backend --identity anonymous | grep Controllers`
   lists `2vxsx-fae`. If not:
   `icp canister settings update backend --add-controller 2vxsx-fae --force --identity alice`.

**The posture rhythm** - the venue runs `#dev`, the tree stays `#play`: the
integration suite requires `#dev`-gated hooks (`setAmmRefPrice` and friends
trap on `#play` by design), so every DEPLOY to your venue happens with the
flip in place - flip `#play -> #dev`, `bash scripts/deploy.sh local` (or the
cold_start above), restore `#play` in the tree the moment the deploy
finishes. Never let the flip sit in the tree between deploys: a lingering
flip turns `git merge main` into a conflict magnet on main.mo and a slip
away from committing `#dev` - which the merge gate would refuse, at the cost
of a redo. A wall of red on suites whose fixtures fail at setup is the
posture signature: check
`echo y | icp canister call backend getDeployMode '()' --query --identity anonymous`
before blaming your change.

**Never stop your replica while you idle.** `icp network stop`/`start` does
NOT resume state - a restart comes up freshly seeded with no canisters, and
the only restore is a full cold_start + reseed (minutes). The cheap idle is
the replica you never stopped. Stop it only when RETIRING the seat (wind-up)
or when the operator asks for machine headroom - and budget the re-bring-up.

**Loop** - and every cycle STARTS by re-reading this skill from the PRIMARY
checkout (`<primary>/.claude/skills/mdex-software-factory/SKILL.md`;
primary = `git worktree list --porcelain | sed -n 's/^worktree //p' | head -1`).
The protocol evolves while sessions run; your boot-time copy and your
worktree's checked-out copy both go stale, and the primary's copy is
authoritative. One Read per task is cheap; obeying a superseded protocol is
not.

Every cycle also verifies the model. Consumer seats run on **Fable 5**, and
the platform sometimes flips a session (fast mode, usage fallback). Check
your CURRENT system prompt's environment section - it names the model
actually powering you now; trust it over anything earlier in the
conversation. A session cannot flip itself back, so if it does not say
Fable 5, make the first line of your next message:

```
!!! MODEL - running on <model>, flip me to Fable 5 !!!
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
   claim (to keep merge conflicts rare; if everything overlaps it takes the
   head anyway) - moves it to `tasks/claimed/<you>/` and prints the path.
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
   below). On idle: `factory.sh watch` (background it on this harness) and
   claim again on wake - a signal wakes that watch too. If you instead wake
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
   the remainder.
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
   c. `scripts/factory.sh merge-lock acquire <your-branch>` (blocks up to
      4 min; if it dies on the POSTURE LAW, restore the committed defaults
      on your branch and re-acquire; if it dies on contention, retry
      later - someone is merging).
   d. Preflight the primary:
      `PRIMARY=$(git worktree list --porcelain | sed -n 's/^worktree //p' | head -1)`;
      no `$PRIMARY/.git/index.lock` (a GUI git client - wait or ask the
      operator), and `git -C "$PRIMARY" rev-parse -q --verify MERGE_HEAD`
      must fail (a half-finished merge means STOP: release the lock and
      escalate to the operator).
   e. `git merge-base --is-ancestor main <branch>` - if not, main moved
      since (a): release the lock, go back to (a).
   f. `git -C "$PRIMARY" merge --no-ff -m "merge: <summary> from <branch>" <branch>`
      - conflict-free by construction after (e). If it still refuses
      (dirty overlapping files in the primary), abort any partial merge,
      release the lock, and archive with a "MERGE PENDING - operator" note
      instead of blocking forever.
   g. **No push. Ever.** Merges land locally; origin and the public mirror
      move only by the operator's hand under the outward-batch policy
      (law 8). There is nothing for you to do here - this step exists so
      nobody re-adds one.
   h. `scripts/factory.sh merge-lock release <your-branch>`.
7. **Archive**: `factory.sh done <id> done "merged <sha>"` (the bookkeeping
   law checks the brief moved). Then loop to 1.

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
  resolves the seat's identity from `.factory-worker` no matter where its
  shell cwd drifts - upstream's 2026-08-19 wrong-worker claim came from
  exactly such a drift. Per task it accrues one banner and one report - it
  stays clean for hundreds of cycles, and the handoff becomes a rarity
  instead of a rhythm.
- After step 2 it spawns a SUBAGENT (Agent tool, model pinned to Fable 5,
  run in background so the seat stays responsive to the operator): prompt =
  the claimed task file path, the worktree path AND its `ICP_HOME`
  (`<worktree>/.icp-home` - the agent must export it in every shell it
  runs, law 10's identity pinning included), and "read
  .claude/skills/mdex-software-factory/SKILL.md from the primary checkout,
  execute this task per TaskConsumer steps 3-6 (split/execute/verify/
  integrate, merge lock and posture law included; no push - law 8); do not
  claim or archive; return a structured report: outcome (integrated <sha> |
  blocked-on-operator <question> | split <ids> | failed <why>), what was
  verified and not, the corpus bookkeeping performed (brief ->
  docs/tasks/done/ + README row, or 'no docfile'), and GROUND NOTES for
  the next agent on this ground - key files, structures, and gotchas
  discovered (two to five lines, written to be reused)."
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
  waits for the notification.

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
   inheritance.
3. Succession, by seat type:
   - **A CLI seat (the standard) self-spawns.** The claude CLI is installed
     (`~/.local/bin/claude`), so after writing the handoff file (step 4)
     and posting the banner (step 5) the seat runs
     `scripts/factory.sh spawn-successor <worktree-basename>` as its FINAL
     act: it opens a new Terminal window running
     `claude --model claude-fable-5 --name 'multidex-executor-<seat>'
     '<boot prompt>'` in the seat's worktree, with the prompt read from the
     handoff file and the project prefix derived per the worker doctrine
     (`FACTORY_PROJECT`, else the primary checkout basename minus
     `-ng`/`-main`; non-executor boot prompts get
     `multidex-worker-<seat>`). Zero-residue window: the spawned command
     ends `; exit 0` (the shell exits cleanly even though the handoff
     self-kill ends claude by signal) and the window gets the operator's
     "Factory" Terminal settings set when it exists, so a seat that later
     retires closes its own window (one-time profile setup: Operator
     guide; without the profile the spawn proceeds and its banner names
     the manual step). Guardrails: only ONCE per handoff - the
     handoff file is the token (`spawn-successor` refuses when it is
     missing: handoff first, spawn second), so spawn only for the file YOU
     just wrote. The spawn does NOT clear the handoff file - the
     successor's `handoff-clear` is the ack, so a failed spawn leaves the
     seat visible on `handoff-list` and the operator boots it by hand as
     before (the same degrade applies when osascript/Terminal automation
     is unavailable: the command prints the exact boot line to run
     manually). Then EXIT your own claude process so the seat's
     defunctness is unambiguous - one last Bash call that kills the
     nearest `claude` ancestor of the shell after the spawn returns:

     ```bash
     scripts/factory.sh spawn-successor <worktree-basename> && \
     p=$$; while [ "$p" -gt 1 ]; do \
       case "$(ps -o comm= -p "$p")" in *claude*) kill "$p"; break ;; esac; \
       p="$(ps -o ppid= -p "$p" | tr -d ' ')"; \
     done
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
   cd <absolute worktree path> && claude
   ```

   then the prompt under a `## Boot prompt` heading - the marker
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
   untracked `.icp-home/`, `.factory-worker`, and `node_modules` noise is
   expected. Anything else tracked and dirty: STOP and ask the operator
   instead of proceeding.
2. **Stop your venue BEFORE removing the worktree**: `icp network stop` from
   the worktree root with the seat's `ICP_HOME` exported (project-scoped -
   kills only your master; never pkill). Removing the worktree first
   ORPHANS the network launcher (ppid 1) plus a stale port descriptor in
   `~/Library/Caches/org.dfinity.icp-cli/port-descriptors/`, and later
   starts then refuse with "port in use by the project at '<deleted
   path>'". If that has already happened:
   `pgrep -f '[i]cp-cli-network-launcher'`, find the ONE whose `--state-dir`
   is under the deleted worktree, `kill` that numeric PID, then rm the
   matching `<port>.json` + `<port>.lock` descriptor pair - every other
   launcher on the machine belongs to another project; leave them.
3. `cd` to the PRIMARY checkout (you cannot remove the worktree you stand
   in), then `git worktree remove --force <your-worktree-path>`; `rm -rf`
   any leftover directory; `git worktree prune`.
4. `git branch -d claude/<your-branch>` - lowercase `-d` is the safety: it
   refuses if your branch is somehow unmerged (then STOP and say so).
5. Report each step's outcome in a final message and stop - do not claim
   again. Deleting the session is the operator's half; the archived task
   files and the merge history are the record that survives.

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
   signal addresses your worker (or `all`), printing the order itself in the
   refusal. The addressee is the worker that claim RESOLVES (arg >
   `FACTORY_WORKER` > the `.factory-worker` pin > cwd branch), so a pinned
   seat is also a reliably addressable one. You cannot start new work before
   processing it - which is exactly the failure this replaced.
   (`FACTORY_FORCE=1` overrides; use it only when the order itself says to.)
3. **Deleting the file is your acknowledgement.** Do what the order says
   FIRST, then `factory.sh signal-clear <worker|all>` and continue. Never
   clear a signal you have not carried out, and never `rm` it by hand
   (law 1). `factory.sh signal-list` and the board's **Operator signals**
   section show what is still unacknowledged - each line is a seat that
   cannot claim.

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
  protocol.
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
- **Lifecycle**: standing - hand it off to refresh context, wind it up only
  deliberately. Its work merges through the same lock, gates included.
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
- **Merge lock wedged**: >30 min old is broken automatically by the next
  acquirer; younger, wait or `factory.sh merge-lock release <owner>` if you
  KNOW the owner is dead (`merge-lock status` names it).
- **Merge-lock acquire refused on the posture law**: your branch carries a
  `#dev` flip or the port-0 icp.yaml edit in a COMMIT. Restore the
  committed defaults on the branch (revert the offending hunk), commit,
  re-acquire. `FACTORY_FORCE=1` exists for the exceptional legitimate
  posture-touching task - say so out loud when you use it.
- **Primary checkout mid-merge or index.lock**: stop, escalate to the
  operator; never `rm` git lock files while a GUI client may be open.
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
- **Duplicate tasks discovered**: consumer archives one as
  `superseded "dup of <id>"`.
- **Task too vague to act on**: `done <id> abandoned "fails law 6: <why>"`
  and file a producer-quality replacement if you can; otherwise it returns
  to the producer via the board.

## Operator guide

Boot prompts (one session each; consumers each get their own worktree):

- Consumer (3-5x; CLI Terminal, executor mode - never a desktop session,
  per the worker doctrine): from the seat's worktree run
  `claude --model claude-fable-5 --name 'multidex-executor-<seat>' "Read
  .claude/skills/mdex-software-factory/SKILL.md. You are a TaskConsumer in
  executor mode taking over the seat at <worktree path>. Work the queue
  continuously."` - the `--name` shape is the same one `spawn-successor`
  mints (prefix = `FACTORY_PROJECT`, else the primary checkout basename
  minus `-ng`/`-main`, here `multidex`), so hand-booted and self-spawned
  seats list identically.
- Prioritizer (exactly 1): *"Read .claude/skills/mdex-software-factory/SKILL.md.
  You are the TaskPrioritizer. Run continuously."*
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

Consumer seats announce every claim with a `=== CLAIMED TASK <id> ===`
banner, any blockage with `!!! HUMAN NEEDED !!!`, and model drift with
`!!! MODEL !!!` (a seat flipped off Fable 5 keeps working but asks - once per
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
orders are still unacknowledged; each such line is a seat that cannot claim,
so a forgotten signal is a stopped seat. Chat messages to a session remain
fine for conversation, but upstream they parked unread behind hour-long
watches and lost races against fresh queue state - they are advisory, the
file is the control plane. (A broadcast blocks the operator's own
`claim --operator` too; `FACTORY_FORCE=1` is the way through.)

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
close. (Alternative, an optional future lane - noted, not implemented: a
tmux-managed fleet has no windows to leak at all - one detached session per
seat, `tmux ls` as the roster.)

To RETIRE a seat, say **"wind up"** (finishes its current task, then stops
its venue, removes its worktree, deletes its merged branch, reports, stops)
or **"wind up now"** (requeues the current claim instead of finishing);
afterwards just delete the session (a CLI seat: close its Terminal). Seats
that self-retire on the context-hygiene rule hand off by default and wind up
only when their infrastructure is unhealthy. To drain the whole factory:
`factory.sh signal all "stop claiming and wind up"`, then confirm
`factory.sh list` empty + `claimed/` empty = drained. Emergency stop of one
seat (died, no wind-up): requeue its claim after salvaging the worktree.

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
