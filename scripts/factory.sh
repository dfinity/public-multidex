#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# factory.sh - the software-factory task queue.
#
# One md file per task under <primary-checkout>/tasks/queue, named
# PPPPPPPPPP-IIIIIIIIII.md (priority key - immutable id, both 10-digit
# zero-padded integers; both start as the UTC epoch seconds of creation).
# Sorting by filename IS the queue order. The prioritizer renames ONLY the
# priority half; the id half never changes and is the task's identity
# everywhere (dependencies, archive, logs).
#
# Every mutation is a same-filesystem mv/ln, so claims and reorders are
# atomic: a race has exactly one winner and the loser retries. This script
# is the ONLY way sessions touch the queue - protocol details live in
# .claude/skills/mdex-software-factory/SKILL.md.
#
# A task with "lane: operator" in its front matter is in the OPERATOR LANE:
# work law 8 forbids consumer seats to run. `claim` never hands one out;
# `claim --operator` claims only those. See is_operator_lane() below.
#
# tasks/signal/<worker>.md (and all.md) is the OPERATOR's control channel to a
# seat: it wakes every `watch` and blocks that seat's next `claim` until the
# seat acknowledges it with `signal-clear`. See the signals section below.
#
# `claim` also enforces SKILL.md's step-7 replica budget structurally: a
# consumer claim refuses (RECYCLE-REQUIRED) while the claiming seat's own
# replica is over budget or past the age belt - fail-open on any broken
# measurement. See the recycle-gate section below. The remedy it names,
# `replica-recycle`, is the ALLOWLISTED door for the replica stop an
# auto-mode seat is denied as a raw `icp network stop` - see its section.
#
# Works from the primary checkout or any git worktree of it (the queue root
# resolves to the PRIMARY checkout's tasks/ either way). FACTORY_TASKS_ROOT
# overrides the root - scripts/factory-selftest.sh uses it to exercise this
# script against a throwaway queue.
#
# HOSTED MODE (Open Factories, docs/architecture/open-software-
# factories.md section 10): when <primary>/.factory-remote/config.json exists
# (FACTORY_REMOTE_DIR overrides the directory - never create the real one by
# accident: it flips every seat on the machine at once), the QUEUE commands
# (new list show claim done requeue reprioritize index signal signal-list
# signal-clear watch amend) are dispatched to tools/factory-client (Node,
# signed by the machine's ed25519 runner key) and the directory queue is not
# consulted. A task's FILES (task 1791312774): `new --attach <file>` stages
# them on the canister, `claim` / `claim --operator --id` download a claimed
# task's files sha256-checked beside the mirror (<P>-<I>.attachments/ + an
# "## Attachments" section), `amend <id> [text] --attach <file>` adds files
# to the seat's claim; local mode copies `new --attach` files under
# tasks/attachments/<id>/ with the same section. The FILING band (task
# 1792609968): `new` bands by class (hygiene 30, cosmetic 40, parked 90,
# else the natural band) with `band: NN` / `--band NN` as the override - in
# local mode the filename, in hosted mode the canister's own submit (task
# 1792613259: task_submit_checked stores the same key and honours a band:
# line), so --band passes through to the client, which writes it as the
# draft's band: line and prints the same stderr line.
# Everything machine-local - worker-pin, worker, executor-env, handoff-*,
# spawn-successor, prioritizer-boot (refused on a hosted checkout: the
# canister runs that pass), replica-recycle, executor-watch, heartbeat,
# fleet-doctor, seat-*, drill-worktree-prune, merge-lock, merge-land,
# the committed tasks/<branch>.done markers - is untouched in both modes, and
# the seat-side gates (the worker resolution + its stderr line, the signal
# gate, the primary refusal, the recycle gate, the heartbeat stamp) still run
# in bash AROUND the client call. See the hosted section below.
#
# FACTORY_WORKER pins the claim identity when the cwd's branch is not the
# seat's: harness-BACKGROUNDED invocations inherit the harness default cwd,
# whose branch can name a DIFFERENT seat (two wrong-worker claims landed that
# way inside one hour on 2026-08-04). An explicit [worker] arg still wins.
# requeue/done locate claimed tasks BY ID across all workers, so they carry
# no identity and are safe from any cwd.
#
# <worktree-root>/.factory-worker is the DURABLE form of that pin: a seat
# writes it ONCE at boot (`factory.sh worker-pin`) and every later invocation
# from anywhere inside that worktree - executor subagents included, since they
# run inside it by construction - resolves the same identity without consulting
# the branch. Resolution order is: explicit [worker] arg > --operator >
# FACTORY_WORKER > .factory-worker (searched up from $PWD to the worktree root)
# > the cwd branch. Absent the file, behaviour is exactly as before. When the
# pin and the cwd-derived name DISAGREE, claim says so on stderr - that
# disagreement IS the drift the pin exists to catch (2026-08-05 and again
# 2026-08-19: a subagent claim landed under another seat's identity, so the
# board and tasks/claimed lied about who held what).
# ---------------------------------------------------------------------------
set -euo pipefail
export LC_ALL=C
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"   # scripts/ of the checkout running this file
# The FSEvents probe + the unattended remedy + its ledger (pure functions; the
# fleet doctor probes both volumes each pass and the board reads the ledger).
# shellcheck source=lib-fsevents.sh
source "$SELF_DIR/lib-fsevents.sh"
# The fleet's pinned worker model (the skill: consumer seats run Fable 5.1).
# ONE constant: every boot line below reads FACTORY_CLAUDE_MODEL falling back
# to it, and Open Factories' Overview setup box bakes the SAME line at build
# time (services/open-software-factories/vite.config.ts greps this file), so
# a model pin moves in one place (task 1791137169). Keep the shape
# NAME="value" on its own line.
FACTORY_CLAUDE_MODEL_DEFAULT="claude-fable-5-1"

die()  { echo "factory: ERROR: $*" >&2; exit 1; }
info() { echo "factory: $*" >&2; }

# A hand-boot line names its worktree as one shell word (2026-09-30): a path
# was written bare, so under a folder with a space the line an operator pastes
# (`cd <path> && claude ...`) split at the space and its cd failed, and a name
# holding ; $( or a backtick ran as a command. shq prints a path as it is when
# it holds only [A-Za-z0-9_./@%+=:,-], else single-quoted; unshq reads either
# back, so a line a seat wrote bare still parses as it did.
shq() {
  case "$1" in
    ''|*[!A-Za-z0-9_./@%+=:,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}
unshq() {
  local w="$1" q="'"
  case "$w" in
    "$q"*"$q") w="${w#$q}"; w="${w%$q}"; w="$(printf '%s' "$w" | sed "s/'\\\\''/'/g")" ;;
  esac
  printf '%s' "$w"
}

# --- root resolution --------------------------------------------------------

resolve_root() {
  PRIMARY=""
  if [ -n "${FACTORY_TASKS_ROOT:-}" ]; then
    TASKS="$FACTORY_TASKS_ROOT"
  else
    PRIMARY="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || true)"
    [ -n "$PRIMARY" ] || die "not inside the suite repo and FACTORY_TASKS_ROOT is unset"
    TASKS="$PRIMARY/tasks"
  fi
  QUEUE="$TASKS/queue"; CLAIMED="$TASKS/claimed"; ARCHIVE="$TASKS/archive"; FACTORY="$TASKS/factory"
  IDS="$FACTORY/.ids"   # append-only id allocator: one dir per id ever minted
  # Pending seat handoffs: one file per worktree awaiting a successor session.
  # The boot prompt lives here, where an app restart cannot reach it (six
  # desktop seats' successor chips evaporated on 2026-08-05 and the operator
  # came back to a drained fleet); since the 2026-08-19 worker doctrine the
  # file is also the spawn TOKEN that spawn-successor reads.
  HANDOFF="$TASKS/handoff"
  # Operator ORDERS to a seat: one file per addressee (see the signals section).
  SIGNAL="$TASKS/signal"
  # Spawn-pending stamps (task 1789588684): one file per seat whose boot
  # `do script` TIMED OUT at the AppleEvent reply - Terminal may still run
  # the queued event hours later, so the stamp holds every respawn until it
  # expires or the seat's process appears (the spawn section below).
  # Runtime state under tasks/factory/ (gitignored).
  SPAWN_PENDING="$FACTORY/spawn-pending"
  mkdir -p "$QUEUE" "$CLAIMED" "$ARCHIVE" "$FACTORY" "$IDS" "$HANDOFF" "$SIGNAL" "$SPAWN_PENDING"
}

# --- small helpers ----------------------------------------------------------

now_s()   { date -u +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
pad()     { printf '%010d' "$((10#$1))"; }   # 10# so leading zeros are not octal
# The band table's arithmetic (SKILL.md "Priority bands"): a 1-2 digit band
# BB and an id -> the 10-digit priority key BB * 10^8 + (id mod 10^8), which
# keeps FIFO order inside a band. ONE definition for requeue / reprioritize
# and, since task 1792609968, new's filing band.
is_band()  { case "${1:-}" in [0-9]|[0-9][0-9]) return 0 ;; *) return 1 ;; esac; }
band_key() { pad "$((10#$1 * 100000000 + 10#$(pad "$2") % 100000000))"; }
sha256_of() {  # sha256 hex of a file (shasum on a stock mac, sha256sum elsewhere)
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}

# PIPEFAIL + head: every `producer | head -N` here ends in `|| true`. head
# exits after N lines; a producer with a write still pending takes SIGPIPE,
# the pipeline's status becomes 141 under pipefail, and set -e aborts the
# command SILENTLY (task 1788467120: `index` died that way 1 run in ~25 on an
# 1800-file archive, leaving the board stale and .index.<pid> litter behind).
# The race depends on stdio write chunking, so it only shows once the
# producer's output outgrows one buffer - harden every instance, not just the
# one that fired. Where the whole listing is needed, read it into the shell
# first and count in a loop (cmd_index) - no pipe, no race at all.
title_of() { sed -n 's/^# \(.*\)$/\1/p' "$1" 2>/dev/null | head -1 || true; }
# Frontmatter-ish field: first "key: value" line in the first 40 lines.
field_of() { sed -n '1,40p' "$1" 2>/dev/null | sed -n "s/^$2:[[:space:]]*//p" | head -1 || true; }

id_of()   { local b; b="$(basename "$1" .md)"; echo "${b#*-}"; }
prio_of() { local b; b="$(basename "$1" .md)"; echo "${b%%-*}"; }

log_stamp() {  # log_stamp <file> <line>
  grep -q '^## Factory log' "$1" 2>/dev/null || printf '\n## Factory log\n' >> "$1"
  printf -- '- %s\n' "$2" >> "$1"
}

# Any live (queued or claimed) task with id $1?
id_live() {
  local p m; p="$(pad "$1")"
  for m in "$QUEUE"/*-"$p".md "$CLAIMED"/*/*-"$p".md; do
    [ -e "$m" ] && return 0
  done
  return 1
}

deps_met() {  # every id in the task's "after:" list is gone from queue+claimed
  local dep
  for dep in $(field_of "$1" after | tr -cs '0-9' ' '); do
    id_live "$dep" && return 1
  done
  return 0
}

# The OPERATOR LANE. Work that law 8 forbids a consumer to execute (engine and
# other non-local deploys, which need human-held auth) carries "lane: operator"
# and is never handed to a consumer seat. Parking such a task in band 90 only
# DELAYS a claim - with a contended queue "nothing else remains" arrives
# routinely, and the seat then reads the task, discovers it must not act, and
# requeues, burning a whole cycle. Three seats bounced one such task in six
# minutes on 2026-08-03. The lane refuses instead of delaying.
is_operator_lane() { [ "$(field_of "$1" lane)" = "operator" ]; }

touches_of()     { field_of "$1" touches | tr ',' ' '; }

# Repo-wide tokens never DEFER a claim (seen 2026-09-28 in a factory where
# most queued tasks listed `docs`, each adding its own page): one active
# claim naming `docs` overlap-deferred the band 02 and band 05 tasks at the
# head on that token alone, and the seat took a natural-zone task. The
# overlap gate exists to keep merge conflicts rare, and a shared docs tree
# is not where they happen.
# FACTORY_OVERLAP_IGNORE (space or comma list; default "docs README"; set it
# EMPTY to gate on every token again) names the tokens the defer side skips.
# Affinity (touches_match) still counts them as warm context, and `suite`
# keeps its meaning on both sides. The skip applies BESIDE a code token only:
# a task made of ignored tokens alone (docs-only) gates on every one of them
# (overlaps, below) - two docs-only tasks edit the same tree.
overlap_ignored() {  # is token $1 one of the repo-wide tokens the defer side skips?
  local t
  for t in $(printf '%s' "${FACTORY_OVERLAP_IGNORE-docs README}" | tr ',' ' '); do
    [ "$1" = "$t" ] && return 0
  done
  return 1
}

# overlaps <task>: does the task's touches list overlap any active claim's?
# ("suite" = everything.) The verdict is GRADED (task 1792508144): on 0 the
# globals say WHICH overlap - OVERLAP_KIND=direct (a concrete token shared
# with another seat's claim; OVERLAP_TOKEN names it) or OVERLAP_KIND=suite
# (the only overlap is the suite rule: a suite-wide task behind any claim, or
# a suite-wide claim over us) - and OVERLAP_WITH names that claim as
# "<worker>'s <id>". A direct match outranks the suite grade when both apply,
# so every claim is scanned before a suite verdict is returned. The claim
# loop keeps one soft slot per grade and falls back suite-only FIRST, direct
# LAST: on 2026-10-20 one seat's suite-wide wave made every queued task an
# overlap, the single soft slot held the plain priority head, and that head
# was the task sharing two concrete tokens with another seat's claim while
# two tasks free of every token sat behind it.
OVERLAP_KIND=""; OVERLAP_TOKEN=""; OVERLAP_WITH=""
claim_label() { echo "$(basename "$(dirname "$1")")'s $(id_of "$1")"; }   # <worker>'s <id> of a claimed path
overlaps() {
  local mine theirs a b c code=false suite_with=""
  OVERLAP_KIND=""; OVERLAP_TOKEN=""; OVERLAP_WITH=""
  mine="$(touches_of "$1")"
  # A repo-wide token is skipped only BESIDE a code token (2026-10-03): a
  # docs-only task's tokens are its whole surface, so they all count - two
  # docs-only tasks still defer each other, and one waits behind a code claim
  # that names docs (the same standards page is where those two would meet).
  for a in $mine; do overlap_ignored "$a" || { code=true; break; }; done
  for c in "$CLAIMED"/*/*.md; do
    [ -e "$c" ] || continue
    theirs="$(touches_of "$c")"
    case "$theirs" in *[!\ ]*) : ;; *) continue ;; esac   # a claim naming nothing overlaps nothing
    for a in $mine; do
      [ "$code" = true ] && overlap_ignored "$a" && continue   # docs/README beside code: shared by all, fought over by none
      for b in $theirs; do
        [ "$a" = "$b" ] || continue
        OVERLAP_KIND=direct; OVERLAP_TOKEN="$a"; OVERLAP_WITH="$(claim_label "$c")"
        return 0
      done
    done
    # The suite rule, both sides: a suite-wide task waits behind ANY claim, a
    # suite-wide claim holds every task. Noted, not returned - a direct match
    # on a later claim still outranks it.
    if [ -z "$suite_with" ]; then
      case " $mine $theirs " in *" suite "*) suite_with="$(claim_label "$c")" ;; esac
    fi
  done
  [ -n "$suite_with" ] || return 1                     # no active claims, or none that touch us
  OVERLAP_KIND=suite; OVERLAP_WITH="$suite_with"
  return 0
}

touches_match() {  # does $1's touches list intersect the space-list $2?
  local a b
  for a in $(touches_of "$1"); do
    for b in $2; do [ "$a" = "$b" ] && return 0; done
  done
  return 1
}

find_claimed() {  # sets FOUND to the single claimed file with id $1
  local p m n=0; p="$(pad "$1")"; FOUND=""
  for m in "$CLAIMED"/*/*-"$p".md; do FOUND="$m"; n=$((n+1)); done
  [ "$n" -eq 1 ] || die "expected exactly one claimed task with id $1, found $n"
}

# The help law, mechanically (task 1786918240): a service-touching task may
# archive as done only when the closing worker's tasks/<worker>.done carries a
# help declaration - a line matching /help:/i, i.e. "help: <entries changed>"
# or "help: no user-facing change". Purely textual: the gate makes SILENCE
# impossible, it never judges the words (SKILL.md, the Execute step's help
# law - the pre-2026-08 help drift happened exactly because compliance was
# honor-system). Operator-lane tasks are exempt: engine rollouts re-deploy
# code whose consumer task already declared. FACTORY_FORCE=1 overrides with
# a warning, mirroring the other escape hatches.
# --- MULTI/DEX overlay: the BOOKKEEPING LAW gate (docfile_gate) ----------
# overrides with a warning.
docfile_gate() {  # $1 = the claimed task file; dies on an unmoved brief
  local f="$1" top p list unmoved=""
  if is_operator_lane "$f"; then return 0; fi
  list="$(field_of "$f" docfile | tr ',' ' ')"
  [ -n "$list" ] || return 0
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$top" ] || [ ! -d "$top/docs/tasks" ]; then
    info "warning: bookkeeping gate skipped - cwd resolves no checkout with docs/tasks"
    return 0
  fi
  for p in $list; do
    if [ -e "$top/$p" ]; then
      unmoved="$unmoved $p"
    elif [ ! -e "$top/docs/tasks/done/$(basename "$p")" ]; then
      info "warning: $p is gone but docs/tasks/done/$(basename "$p") is absent - deleted rather than moved?"
    fi
  done
  [ -z "$unmoved" ] && return 0
  if [ "${FACTORY_FORCE:-}" = "1" ]; then
    echo "factory: warning: bookkeeping gate overridden (FACTORY_FORCE=1) - still at original path:$unmoved" >&2
    return 0
  fi
  die "done refused: the task's docs/tasks brief(s) still sit at their original path:$unmoved - move each to docs/tasks/done/ with its completion note and strike its README row on your branch, merge, then archive (the bookkeeping law, .claude/skills/mdex-software-factory/SKILL.md; FACTORY_FORCE=1 overrides)"
}

help_gate() {  # $1 = the claimed task file; dies on a silent service close
  local f="$1" worker donefile t svc=0
  if is_operator_lane "$f"; then return 0; fi
  for t in $(touches_of "$f"); do
    case "$t" in open-*|services/*|suite) svc=1 ;; esac
  done
  [ "$svc" -eq 1 ] || return 0
  worker="$(basename "$(dirname "$f")")"
  donefile="$TASKS/$worker.done"
  if [ -e "$donefile" ] && grep -qi 'help:' "$donefile"; then return 0; fi
  # Declarations are audited across BOTH globs: live seats write flat
  # tasks/<worker>.done, retired branches' markers live folded under
  # tasks/sessions-done/ (the retired-marker fold, SKILL.md).
  if [ -e "$TASKS/sessions-done/$worker.done" ] && grep -qi 'help:' "$TASKS/sessions-done/$worker.done"; then return 0; fi
  if [ "${FACTORY_FORCE:-}" = "1" ]; then
    echo "factory: warning: help-declaration gate overridden (FACTORY_FORCE=1) - $donefile carries no 'help:' line" >&2
    return 0
  fi
  die "done refused: this task touches a service but $donefile carries no help declaration - add 'help: <entries changed>' or 'help: no user-facing change' to the round's .done (the help law, .claude/skills/mdex-software-factory/SKILL.md; FACTORY_FORCE=1 overrides)"
}

# --- worker identity (the seat pin) -----------------------------------------
# A seat's identity used to be DERIVED per command from the cwd's git branch.
# That is exactly wrong for executor subagents and harness-backgrounded shells,
# whose cwd drifts to another worktree and mints another seat's name (2026-08-05,
# recurred 2026-08-19). So a seat PINS its identity once at boot into
# <worktree-root>/.factory-worker; every command run anywhere inside that tree
# reads it back. The file is gitignored runtime state, one line, plain text.

PIN_FILE=".factory-worker"

find_worker_pin() {  # print the nearest .factory-worker at/above $PWD (bounded by the worktree root)
  local d top
  d="$(pwd -P 2>/dev/null || pwd)"
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  while : ; do
    if [ -f "$d/$PIN_FILE" ]; then printf '%s\n' "$d/$PIN_FILE"; return 0; fi
    if [ -n "$top" ] && [ "$d" = "$top" ]; then return 1; fi
    if [ "$d" = "/" ] || [ -z "$d" ]; then return 1; fi
    d="$(dirname "$d")"
  done
}

# Sets PIN_NAME / PIN_PATH (empty when there is no usable pin). NOT a printing
# helper on purpose: `x="$(f)"` would run it in a subshell and lose PIN_PATH.
PIN_NAME=""
PIN_PATH=""
resolve_pin() {
  local f v
  PIN_NAME=""; PIN_PATH=""
  f="$(find_worker_pin || true)"
  [ -n "$f" ] || return 0
  v="$(head -1 "$f" 2>/dev/null | tr -d '[:space:]')"
  case "$v" in
    '') return 0 ;;
    */*|*..*) info "warning: ignoring unusable worker pin '$v' in $f"; return 0 ;;
  esac
  PIN_NAME="$v"; PIN_PATH="$f"
}

branch_worker() { git branch --show-current 2>/dev/null | tr '/' '-' | tr -d '[:space:]'; }

# Non-fatal ownership check for requeue/done: a claimed task belongs to its
# worker (law 3). These commands find their task BY ID across all workers on
# purpose - the operator legitimately acts on any claim - so this only says so.
warn_owner_mismatch() {  # $1 = the claimed task file
  local owner
  resolve_pin
  [ -n "$PIN_NAME" ] || return 0
  owner="$(basename "$(dirname "$1")")"
  if [ "$owner" != "$PIN_NAME" ]; then
    info "warning: this task is claimed by '$owner' but this seat is pinned as '$PIN_NAME' ($PIN_PATH) - law 3: a claimed task belongs to its worker"
  fi
  return 0
}

# --- operator signals -------------------------------------------------------
# tasks/signal/<worker>.md (plus tasks/signal/all.md, the broadcast) carries the
# operator's ORDERS to a seat. Cross-session messages are a HUMAN channel, not a
# control plane: on 2026-08-19 a five-seat hand-off by message failed three ways
# inside an hour - messages parked unread behind hour-long `watch` polls; on wake
# the notification and the message competed and seats acted on fresh queue state
# first (one claimed new work despite a do-not-claim order); and three of five
# improvised. Signals ride the filesystem the seats already poll instead:
# watch_sig() covers signal/, so an order wakes every long poll at once, and
# claim REFUSES while one addresses the claiming worker - a seat cannot take new
# work before its order is processed, which fixes the ordering race by
# construction. For a per-seat order, deleting the file (signal-clear <worker>)
# IS the acknowledgement. The broadcast (all.md) is ONE file for every seat, so
# deleting it would ack it for seats that have not read it yet (the first seat
# to ack a 2026-09-02 broadcast could only release all ten or claim through
# FACTORY_FORCE): a seat acks a broadcast with the SAME `signal-clear <worker>`,
# which records a marker in the ACK LEDGER tasks/signal/all.acked/<worker>
# (one file per acked worker, bash-3.2-safe, no array tricks), and all.md
# blocks a worker until its marker names the text standing now. The marker
# holds the GENERATION it acknowledged (signal_gen: all.md's cksum and size),
# so an ack is an ack of one text: a seat that acked the old order while a
# re-sent broadcast was landing is blocked again by the new one, never
# pre-acked (2026-09-29). A marker without a generation (written before this
# rule) acks no text, so a broadcast standing across the change is acked once
# more. A re-sent `signal all` RESETS the ledger (a changed order must be
# re-read); `signal-clear all` is the operator's hard delete of the file AND
# the ledger. `signal`, `signal-clear all` and the per-seat clear hold
# tasks/signal/.lock (signal_lock); remote-import's move-aside does not.
#
# An ack is of the text that was READ, not of whatever stands when the ack
# runs (2026-09-30): the claim gate keeps a copy of each order its refusal
# printed (signal_seen), and a seat's `signal-clear <worker>` acks the
# broadcast it was shown and deletes only the order of its own it was shown.
# An order that landed after the refusal (a re-sent broadcast, a second order
# appended to the seat's file) still stands and refuses the next claim, which
# prints it. The operator and the app say what they read instead:
# `signal-clear <worker> --if '<crc> <size>'` (what cksum printed for the
# order read) acks or clears only while that text stands.

signal_gen() { { cksum < "$SIGNAL/all.md"; } 2>/dev/null || true; }   # the standing broadcast's generation ("" when none)

signal_acked() {  # has worker $1 acked the standing broadcast - the text standing NOW?
  local g
  [ -f "$SIGNAL/all.acked/$1" ] || return 1
  g="$(signal_gen)"
  [ -n "$g" ] && [ "$(cat "$SIGNAL/all.acked/$1" 2>/dev/null)" = "$g" ]
}

# The writers' lock. `signal` composes the new file from the one standing and
# moves it into place, so two writers at once each composed from the same old
# file and one append was lost; `signal-clear all` racing a send could see its
# delete undone by the send's mv. Both, and the per-seat clear, hold
# tasks/signal/.lock (mkdir, then the holder's pid). A lock whose pid is gone
# is broken; a lock with no pid yet is dated by its directory, never as 0,
# and broken once it is over a minute old; a lock that vanished is retried.
# The ack is not a writer: it names its generation instead.
# A hold of the writers' lock is one GENERATION of its directory (its inode and
# birth time). Breaking a stale lock with a bare mv-then-rm would let two
# writers that both found the holder gone both win: the second one's mv would
# carry off the lock the first had just made, and one order would be lost. A
# break (and the holder's own unlock) removes only the generation it read,
# checked and taken under the kernel's lock on the lock directory itself
# (lockf(1) -n, which never creates it: held for the check, the rename and the
# removal, and dropped by the kernel when lockf exits or dies). 0: taken; any
# other code: not taken.
#
# THE one generation-checked lock-directory remover, shared by this writers'
# lock, the merge lock (merge_lock_take) and remote-poll's one-poller lock
# (poll_lock_acquire); lib.sh lock_take is the deploy spine's copy, because
# replica-doctor cannot source this file. lockdir_gen prints a directory's
# generation ("" when there is none; every mkdir makes a new one), and
# lockdir_take removes the directory only while it is still the generation
# named. Answers 0 when taken; 1 when the path is not, or no longer, the
# generation named; 69 when there was nothing to open; any other code is
# lockf's own (75: not locked within 30 s, 73: the directory could not be
# opened). lockf(1) is macOS's (/usr/bin; -k and -n checked on 26.3) - the
# scripts are macOS-only already (stat -f) - and without it every break would
# spin and every release would leave the lock standing, so its absence is a
# named death rather than a silent one.
lockdir_gen() { stat -f '%i.%B' "$1" 2>/dev/null || true; }
lockdir_take() {  # lockdir_take <lockdir> <generation>
  command -v lockf >/dev/null 2>&1 || die "lockf(1) not found on PATH - the lock directories' breaks and releases run under it (macOS ships it in /usr/bin)"
  lockf -k -n -s -t 30 "$1" /bin/sh -c '
    [ -n "$2" ] && [ "$(stat -f "%i.%B" "$1" 2>/dev/null)" = "$2" ] || exit 1
    mv "$1" "$1.taken.$$" || exit 1
    rm -rf "$1.taken.$$" || true
    exit 0
  ' lockdir-take "$1" "$2"
}
SIGNAL_LOCK="" SIGNAL_LOCK_GEN=""
signal_lock_gen() { lockdir_gen "$1"; }
signal_lock_take() { lockdir_take "$1" "$2"; }
signal_unlock() {
  [ -z "$SIGNAL_LOCK" ] || signal_lock_take "$SIGNAL_LOCK" "$SIGNAL_LOCK_GEN" || true
  SIGNAL_LOCK="" SIGNAL_LOCK_GEN=""
}

signal_lock() {
  local lock="$SIGNAL/.lock" pid since gen n=0
  mkdir -p "$SIGNAL"
  until mkdir "$lock" 2>/dev/null; do
    # Every pass counts, a retry too: a lock that cannot be made (a tasks root
    # this user cannot write) gives up by name instead of spinning.
    n=$((n+1))
    [ "$n" -le 300 ] || die "cannot take $lock (holder pid ${pid:-not written}) for over 30s - retry; if no factory.sh signal is running, remove it"
    gen="$(signal_lock_gen "$lock")"   # the hold this pass judges, read before its pid and its date
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    case "$pid" in
      ''|*[!0-9]*)
        since="$(stat -f %m "$lock" 2>/dev/null || true)"
        case "$since" in
          ''|*[!0-9]*) [ -e "$lock" ] || continue ;;   # gone before it could be dated: retry
          *)
            if [ $(( $(now_s) - since )) -gt 60 ]; then
              signal_lock_take "$lock" "$gen" && info "broke a stale signal lock (no pid for over a minute)"
              continue
            fi ;;
        esac ;;
      *)
        if ! ps -p "$pid" -o pid= >/dev/null 2>&1; then
          signal_lock_take "$lock" "$gen" && info "broke a stale signal lock (pid $pid is gone)"
          continue
        fi ;;
    esac
    sleep 0.1
  done
  SIGNAL_LOCK="$lock"
  SIGNAL_LOCK_GEN="$(signal_lock_gen "$lock")"
  trap signal_unlock EXIT
  echo "$$" > "$lock/pid"
}

# What the claim gate showed a worker: a copy of each order its refusal
# printed, taken just before the print, under tasks/factory/signal-shown/
# (<worker>.all for the broadcast, <worker>.own for its own file). A copy is
# taken before the print, never after, so a text that lands in between is
# shown again rather than acked unread. A worker never shown a broadcast, or
# never shown an order of its own, keeps the old ack of what stands for it.
# A copy lasts until the ack it allows: the signal-clear that acks the
# broadcast shown, or deletes the whole order shown, removes it, so outside
# the span from a refusal to its ack a plain signal-clear acks what stands,
# as before.
signal_seen() {
  local d="$FACTORY/signal-shown" f all="" own=""
  mkdir -p "$d"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$f" = "$SIGNAL/all.md" ]; then all="$f"; else own="$f"; fi
  done <<EOF
$2
EOF
  [ -z "$all" ] || signal_keep_copy "$all" "$d/$1.all"
  [ -z "$own" ] || signal_keep_copy "$own" "$d/$1.own"
  return 0
}
signal_keep_copy() {  # signal_keep_copy <order file> <copy>: the copy of what is shown, or none
  if cp "$1" "$2.$$" 2>/dev/null; then mv "$2.$$" "$2"; else rm -f "$2" "$2.$$"; fi
}

signal_pending() {  # print the signal files addressing worker $1, broadcast first
  local f
  if [ -e "$SIGNAL/all.md" ] && ! signal_acked "$1"; then printf '%s\n' "$SIGNAL/all.md"; fi
  f="$SIGNAL/$1.md"
  [ -e "$f" ] && printf '%s\n' "$f"
  return 0
}

signal_gate() {  # $1 = worker; refuses the claim while an unacknowledged order stands
  local pending f
  pending="$(signal_pending "$1")"
  [ -n "$pending" ] || return 0
  [ "${FACTORY_FORCE:-}" = "1" ] || signal_seen "$1" "$pending"   # what this refusal shows, copied before it prints
  if [ "${FACTORY_FORCE:-}" = "1" ]; then
    echo "factory: warning: operator-signal gate overridden (FACTORY_FORCE=1) - unread: $(printf '%s' "$pending" | tr '\n' ' ')" >&2
    return 0
  fi
  {
    echo "factory: ERROR: claim refused: an operator signal is waiting for '$1' - do what it says FIRST, then acknowledge it (factory.sh signal-clear <name>) and claim again (FACTORY_FORCE=1 overrides)"
    # One path per line, never word-split: a tasks root under a folder with
    # spaces must still print the order the seat is refused for.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      echo "  --- $f"
      sed 's/^/  /' "$f"
    done <<EOF
$pending
EOF
  } >&2
  exit 1
}

# --- the recycle gate (structural step-7) ------------------------------------
# SKILL.md TaskConsumer step 7 - the replica budget/age check at every claim
# boundary - was honor-system, and honor failed: seats whose shell context
# predated the rule ack'd the recycle broadcast, crossed claim boundary after
# claim boundary, and grew 4-10GB replicas (five veteran seats at once,
# 2026-08-28). Like the signal gate, compliance is now STRUCTURAL: a consumer
# claim REFUSES while the claiming seat's own replica is over the footprint
# budget (REPLICA_RSS_BUDGET_GB, default 3GB) or past the age belt
# (REPLICA_MAX_AGE_HOURS, default 48h). The measurement is ONE read-only
# replica-doctor --rss pass (ps/lsof/top attribution by state-dir, the
# caller's worktree only; no icp calls, so it cannot wedge), and the gate is
# FAIL-OPEN BY CONSTRUCTION: every non-verdict outcome - no attributable
# worktree, no doctor script, a doctor error, unparseable output - PASSES the
# claim with a logged skip note. A broken measurement must never block the
# fleet's claims; only the doctor's explicit exit-3 recycle verdict refuses.
# FACTORY_FORCE=1 skips the gate (emergencies), same as the other gates.
#
# TEST SEAM (test-only): FACTORY_TEST_REPLICA_MB / FACTORY_TEST_REPLICA_AGE_H
# fake the measured footprint (MB) / oldest-main age (hours) so the refusal
# arm is exercisable without growing a real 3GB replica. factory-selftest.sh
# pins MB=0 globally for deterministic claims and drives the arms per case.
# A non-numeric seam value counts as a broken measurement: pass, with a note.

recycle_refuse() {  # $1 = footprint MB label, $2 = age label, $3 = worktree
  echo "factory: ERROR: claim refused: RECYCLE-REQUIRED (${1}MB, age ${2}): scripts/factory.sh replica-recycle from ${3}, then re-claim (the step-7 replica budget, enforced at the claim boundary; the raw icp network stop is denied to auto-mode seats - replica-recycle is the allowlisted door; FACTORY_FORCE=1 overrides)" >&2
  exit 1
}

recycle_gate() {  # $1 = resolved worker; consumer claims only
  local worker="$1" top="" gate_top="" budget maxage mb age_h out rc doctor
  budget="${REPLICA_RSS_BUDGET_GB:-3}"
  maxage="${REPLICA_MAX_AGE_HOURS:-48}"
  case "$budget" in ''|*[!0-9]*) info "recycle gate skipped (bad REPLICA_RSS_BUDGET_GB '$budget')"; return 0 ;; esac
  case "$maxage" in ''|*[!0-9]*) info "recycle gate skipped (bad REPLICA_MAX_AGE_HOURS '$maxage')"; return 0 ;; esac
  if [ "${FACTORY_FORCE:-}" = "1" ]; then
    info "recycle gate skipped (FACTORY_FORCE=1)"
    return 0
  fi
  # Attribution target: the seat's OWN worktree - the pin's home when the pin
  # names the claiming worker, else the cwd worktree when its branch derives
  # that worker. A drifted cwd (a backgrounded shell parked in another seat's
  # tree) matches neither: skip rather than measure - and possibly refuse
  # over - someone else's replica. resolve_pin already ran in cmd_claim.
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$PIN_NAME" ] && [ "$PIN_NAME" = "$worker" ] && [ -n "$PIN_PATH" ]; then
    gate_top="$(dirname "$PIN_PATH")"
  elif [ -n "$top" ] && [ "$(branch_worker)" = "$worker" ]; then
    gate_top="$top"
  fi
  # The test seam replaces measurement entirely (see the seam note above).
  if [ -n "${FACTORY_TEST_REPLICA_MB:-}${FACTORY_TEST_REPLICA_AGE_H:-}" ]; then
    mb="${FACTORY_TEST_REPLICA_MB:-0}"; age_h="${FACTORY_TEST_REPLICA_AGE_H:-0}"
    case "$mb$age_h" in *[!0-9]*) info "recycle gate skipped (non-numeric FACTORY_TEST_REPLICA_* seam)"; return 0 ;; esac
    if [ "$mb" -gt $(( budget * 1024 )) ] || { [ "$maxage" -gt 0 ] && [ "$age_h" -ge "$maxage" ]; }; then
      recycle_refuse "$mb" "${age_h}h" "${gate_top:-${top:-<your-worktree>}}"
    fi
    return 0
  fi
  if [ -z "$gate_top" ]; then
    info "recycle gate skipped (cannot attribute a worktree to '$worker' from $(pwd -P 2>/dev/null || pwd))"
    return 0
  fi
  doctor="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/replica-doctor.sh"
  if [ ! -x "$doctor" ]; then
    info "recycle gate skipped (no executable replica-doctor.sh next to factory.sh)"
    return 0
  fi
  rc=0
  out="$("$doctor" --rss "$gate_top" 2>/dev/null)" || rc=$?
  case "$rc" in
    0) return 0 ;;   # under budget and under age - or no replica at all
    3) : ;;          # the doctor's explicit recycle verdict
    *) info "recycle gate skipped (replica-doctor --rss exited $rc - a broken measurement never blocks a claim)"; return 0 ;;
  esac
  mb="$(printf '%s\n' "$out" | sed -n 's/.*TOTAL: \([0-9][0-9]*\) MB.*/\1/p' | head -1 || true)"
  age_h="$(printf '%s\n' "$out" | sed -n -e 's/.*is \([0-9][0-9]*\)h old.*/\1/p' -e 's/.*oldest main \([0-9][0-9]*\)h.*/\1/p' | head -1 || true)"
  if [ -n "$age_h" ]; then age_h="${age_h}h"; else age_h="?"; fi
  recycle_refuse "${mb:-?}" "$age_h" "$gate_top"
}

# --- replica-recycle (the allowlisted replica stop) --------------------------
# The doctrine REQUIRES a seat to stop its own replica - the RECYCLE-REQUIRED
# claim refusal above and TaskConsumer step 7 both send it there - yet an
# auto-mode seat is DENIED the raw `icp network stop`: the harness classifier
# refuses destructive-class commands unattended (a network stop is data loss
# by nature), and the allowlist deliberately leaves that class to it. seat-2
# sat through fourteen executor restarts on one dead replica (2026-09-01/02)
# because of exactly that gap. `factory.sh replica-recycle` is the door: it
# lives under `scripts/factory.sh *`, so it rides the existing allowlist row
# without widening `icp network stop` for everything, and it is SAFE to
# allowlist because it can only ever act on the CALLING SEAT'S OWN worktree:
#   - the worktree is the seat pin's home (.factory-worker at/above the cwd,
#     bounded by the git toplevel) - or the git toplevel when FACTORY_WORKER
#     names the seat and no pin exists; no identity at all = refused, and a
#     pin that disagrees with FACTORY_WORKER = refused (that IS cwd drift);
#   - the PRIMARY checkout is refused unconditionally (its replica is the
#     operator's; no FACTORY_FORCE arm here - law 5);
#   - every process it touches is ATTRIBUTED to that worktree the way
#     replica-doctor --rss attributes: a pocket-ic main (`pocket-ic --ttl`)
#     or icp-cli-network-launcher whose open fds (or its parent's) sit under
#     <worktree>/.icp/cache/networks/, or whose cwd IS the worktree (the
#     launcher is spawned there with a RELATIVE --state-dir, and under the
#     FSEvents tmp-symlink workaround the fd paths leave the tree). Never a
#     name match, never a port match, never a global pkill.
# Sequence: (1) attribute; (2) `ICP_PROJECT_ROOT=. icp network stop` from the
# worktree root under a kill-after watchdog (the command takes no --identity:
# it signs nothing; the watchdog kills only OUR probe's process tree, never
# icp-cli's machine-global flocks); (3) whatever attributed process survives
# - the ZOMBIE shape: launcher dead, descriptor + pocket-ic tree alive,
# `icp network status` still answering while nothing deploys - is killed
# children-first (TERM, then KILL); (4) the per-worktree network lock is
# removed, and a descriptor.json that outlived every attributed process is
# removed too (a stale descriptor makes `icp network status` report a dead
# gateway and deploy-all die at preflight instead of starting fresh); (5) a
# one-line verdict. Stopping is retirement (icp-cli 1.2 never resumes
# managed-network state): the next deploy-all --changed detects the fresh
# instance and escalates itself to a seeding deploy. --dry-run reports the
# attribution and the plan without touching anything.

rr_cwd_of() {  # $1 = pid; echoes the process's cwd ("" when unreadable)
  lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true
}

rr_owner_of() {  # $1 = pid; echoes the owning project root by the doctor's fd rule ("" = unattributable)
  local pid="$1" ppid="" p=""
  ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  p="$( { lsof -p "$pid" 2>/dev/null; [ -n "$ppid" ] && [ "$ppid" != "1" ] && [ "$ppid" != "0" ] && lsof -p "$ppid" 2>/dev/null; } \
        | grep -oE '/[^ ]*/\.icp/cache/networks/' | head -1 || true)"
  [ -n "$p" ] && printf '%s' "${p%/.icp/cache/networks/}"
  return 0
}

rr_is_ours() {  # rr_is_ours <pid> <worktree-physical>; true when the process is attributed to that worktree
  local pid="$1" wt="$2" owner="" cwd=""
  owner="$(rr_owner_of "$pid")"
  if [ -n "$owner" ]; then
    owner="$(cd "$owner" 2>/dev/null && pwd -P || printf '%s' "$owner")"
    [ "$owner" = "$wt" ] && return 0
    return 1   # attributed elsewhere: never ours, whatever the cwd says
  fi
  cwd="$(rr_cwd_of "$pid")"
  [ -n "$cwd" ] && [ "$cwd" = "$wt" ] && return 0
  return 1
}

rr_is_launcher() {  # $1 = pid; true when argv[0] IS the icp-cli network launcher binary (a seat whose boot prompt rides argv and merely MENTIONS the name is not one - task 1791286191)
  local argv0
  argv0="$(ps -o comm= -p "$1" 2>/dev/null || true)"   # the executable path whole (it sits under "Application Support" - a space)
  case "$argv0" in *icp-cli-network-launcher|icp-cli-network-launcher) return 0 ;; esac
  return 1
}

rr_attributed() {  # rr_attributed <worktree-physical>; prints "main <pid>" / "launcher <pid>" lines
  local wt="$1" pid
  for pid in $(pgrep -f 'pocket-ic --ttl' 2>/dev/null || true); do
    rr_is_ours "$pid" "$wt" && echo "main $pid"
  done
  for pid in $(pgrep -f 'icp-cli-network-launcher' 2>/dev/null || true); do
    rr_is_launcher "$pid" || continue
    rr_is_ours "$pid" "$wt" && echo "launcher $pid"
  done
  return 0
}

rr_tree() {  # all pids in the tree rooted at $1, children first (leaves before roots)
  local pid="$1" kid
  for kid in $(pgrep -P "$pid" 2>/dev/null || true); do rr_tree "$kid"; done
  printf '%s\n' "$pid"
}

rr_kill_tree() {  # rr_kill_tree <root-pid> <TERM|KILL>
  local p
  for p in $(rr_tree "$1"); do kill -s "$2" "$p" 2>/dev/null || true; done
}

rr_alive() { local st; st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"; case "$st" in ''|Z*) return 1 ;; esac; return 0; }

rr_icp_timed() {  # rr_icp_timed <worktree> <seconds> <label> <icp args...>; runs under a kill-after watchdog; 124 = timed out
  local wt="$1" secs="$2" label="$3" out pid waited=0 rc=0
  shift 3
  out="$(mktemp "${TMPDIR:-/tmp}/factory-rr.XXXXXX")"
  ( cd "$wt" && ICP_PROJECT_ROOT=. icp "$@" ) >"$out" 2>&1 &
  pid=$!
  while rr_alive "$pid"; do
    if [ "$waited" -ge "$secs" ]; then
      info "$label: no answer after ${secs}s - killing OUR OWN probe tree (pid $pid); icp-cli's global locks are never touched"
      rr_kill_tree "$pid" TERM; sleep 1; rr_kill_tree "$pid" KILL
      rc=124
      break
    fi
    sleep 1; waited=$((waited + 1))
  done
  if [ "$rc" -ne 124 ]; then wait "$pid" 2>/dev/null && rc=0 || rc=$?; else wait "$pid" 2>/dev/null || true; fi
  if [ -s "$out" ]; then sed 's/^/    | /' "$out" >&2; fi
  rm -f "$out"
  return "$rc"
}

cmd_replica_recycle() {
  local dry=false worker="" src="" top="" wt="" primary="" pin_top="" rows="" kind pid n_main=0 n_launch=0
  local net="" rc=0 stop_word="" left="" targets="" n=0 killed=0 lock_word="absent" desc_word="absent" port="" verdict=""
  case "${1:-}" in
    --dry-run) dry=true ;;
    '') : ;;
    *) die "usage: factory.sh replica-recycle [--dry-run]" ;;
  esac
  # -- identity + worktree resolution (the seat's own tree, nothing else) ----
  resolve_pin
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$PIN_NAME" ]; then
    pin_top="$(cd "$(dirname "$PIN_PATH")" && pwd -P)"
    if [ -n "${FACTORY_WORKER:-}" ] && [ "$FACTORY_WORKER" != "$PIN_NAME" ]; then
      die "replica-recycle refused: FACTORY_WORKER '$FACTORY_WORKER' disagrees with the seat pin '$PIN_NAME' ($PIN_PATH) - that disagreement is cwd drift; cd to YOUR worktree and rerun"
    fi
    worker="$PIN_NAME"; src="pin $PIN_PATH"; wt="$pin_top"
  elif [ -n "${FACTORY_WORKER:-}" ]; then
    [ -n "$top" ] || die "replica-recycle refused: not inside a git worktree (FACTORY_WORKER='$FACTORY_WORKER' but no toplevel from $(pwd -P 2>/dev/null || pwd))"
    worker="$FACTORY_WORKER"; src="FACTORY_WORKER (no .factory-worker pin)"; wt="$(cd "$top" && pwd -P)"
  else
    die "replica-recycle refused: no seat identity - no .factory-worker pin at/above $(pwd -P 2>/dev/null || pwd) and FACTORY_WORKER is unset. This door recycles a SEAT's own worktree replica only: pin the seat first (factory.sh worker-pin) or export FACTORY_WORKER=<seat>"
  fi
  primary="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || true)"
  [ -n "$primary" ] && primary="$(cd "$primary" 2>/dev/null && pwd -P || printf '%s' "$primary")"
  if [ -z "$primary" ] || [ "$wt" = "$primary" ]; then
    die "replica-recycle refused: $wt is the PRIMARY checkout - its replica is the operator's (law 5). This door acts on a consumer seat's OWN worktree only; there is no override"
  fi
  net="$wt/.icp/cache/networks/local"
  info "replica-recycle: seat '$worker' ($src) -> worktree $wt"
  # -- (1) attribution ---------------------------------------------------------
  rows="$(rr_attributed "$wt")"
  while read -r kind pid; do
    [ -n "$kind" ] || continue
    case "$kind" in main) n_main=$((n_main + 1)) ;; launcher) n_launch=$((n_launch + 1)) ;; esac
    info "  attributed $kind pid $pid ($(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ') old, $(rr_tree "$pid" | wc -l | tr -d ' ') procs in its tree)"
  done <<EOF
$rows
EOF
  port="$(sed -n 's/^[[:space:]]*"port":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$net/descriptor.json" 2>/dev/null | head -1 || true)"
  [ -f "$net/descriptor.json" ] && info "  descriptor: $net/descriptor.json (gateway port ${port:-?})"
  [ -f "$net/lock" ] && info "  network lock: $net/lock"
  if [ "$n_main" -eq 0 ] && [ "$n_launch" -eq 0 ]; then
    info "  no pocket-ic main or launcher is attributed to this worktree (launcher dead AND main dead = nothing to kill)"
  elif [ "$n_launch" -eq 0 ]; then
    info "  ZOMBIE: no launcher for this worktree, but $n_main pocket-ic main(s) alive - icp network status answers, nothing deploys"
  fi
  if [ "$dry" = true ]; then
    echo "DRY-RUN $wt (mains $n_main, launchers $n_launch, descriptor $([ -f "$net/descriptor.json" ] && echo present || echo absent), lock $([ -f "$net/lock" ] && echo present || echo absent)) - nothing touched"
    return 0
  fi
  # -- (2) the sanctioned stop, watchdogged ------------------------------------
  if [ "$n_main" -gt 0 ] || [ "$n_launch" -gt 0 ] || [ -f "$net/descriptor.json" ]; then
    # The root icp.yaml is GENERATED from icp.template.yaml (task 1790242692);
    # a merge that deleted the formerly tracked file leaves the seat without
    # it until its next bootstrap/deploy - `icp network stop` needs it.
    if [ ! -f "$wt/icp.yaml" ] && [ -f "$wt/icp.template.yaml" ] && [ -f "$wt/scripts/materialize-icp-yaml.mjs" ]; then
      ( cd "$wt" && node scripts/materialize-icp-yaml.mjs --template icp.template.yaml --out icp.yaml >/dev/null 2>&1 ) || true
    fi
    info "  running: (cd $wt && ICP_PROJECT_ROOT=. icp network stop)  [kill-after ${FACTORY_RECYCLE_STOP_SECS:-180}s]"
    rc=0
    rr_icp_timed "$wt" "${FACTORY_RECYCLE_STOP_SECS:-180}" "icp network stop" network stop || rc=$?
    case "$rc" in
      0) stop_word="stop ok" ;;
      124) stop_word="stop TIMED OUT (probe killed)" ;;
      *) stop_word="stop exited $rc" ;;
    esac
    info "  $stop_word"
  else
    stop_word="stop skipped (no process, no descriptor)"
  fi
  # -- (3) zombie cleanup: only what is still attributed to THIS worktree -----
  left="$(rr_attributed "$wt")"
  if [ -n "$left" ]; then
    info "  survivors after the stop - killing ONLY processes attributed to $wt (children first, TERM then KILL):"
    targets=""   # the exact pid set we signal: the attributed roots' trees, snapshotted before TERM
    while read -r kind pid; do
      [ -n "$kind" ] || continue
      targets="$targets $(rr_tree "$pid" | tr '\n' ' ')"
      info "    $kind pid $pid: TERM tree ($(rr_tree "$pid" | tr '\n' ' '))"
      rr_kill_tree "$pid" TERM
    done <<EOF
$left
EOF
    n=0
    while [ "$n" -lt 15 ]; do
      left=""
      for pid in $targets; do rr_alive "$pid" && left="$left $pid"; done
      [ -z "$left" ] && break
      sleep 1; n=$((n + 1))
    done
    if [ -n "$left" ]; then
      info "    still alive after ${n}s:$left - KILL"
      for pid in $left; do kill -9 "$pid" 2>/dev/null || true; done
      sleep 1
    fi
    killed=1
  fi
  left="$(rr_attributed "$wt")"
  [ -z "$left" ] || die "replica-recycle: processes attributed to $wt survived TERM and KILL: $(printf '%s' "$left" | tr '\n' ';') - diagnose with ./scripts/replica-doctor.sh"
  # -- (4) bookkeeping: the per-worktree lock, and a descriptor nobody serves -
  if [ -f "$net/lock" ]; then rm -f "$net/lock" && lock_word="removed"; fi
  if [ -f "$net/descriptor.json" ]; then
    rm -f "$net/descriptor.json" && desc_word="removed (stale: it outlived every attributed process)"
  else
    desc_word="gone (clean stop)"
  fi
  # -- (5) verdict -------------------------------------------------------------
  if [ "$n_main" -eq 0 ] && [ "$n_launch" -eq 0 ] && [ "$stop_word" = "stop skipped (no process, no descriptor)" ]; then
    verdict="NOTHING-RUNNING"
  elif [ "$killed" -eq 1 ]; then
    verdict="RECYCLED-ZOMBIE"
  else
    verdict="RECYCLED"
  fi
  echo "$verdict $wt (had mains $n_main, launchers $n_launch${port:+, gateway port $port}; $stop_word; killed $([ "$killed" -eq 1 ] && echo yes || echo none); lock $lock_word; descriptor $desc_word). Stopping is retirement: the next deploy-all --changed here escalates itself to a seeding deploy."
}

# --- hosted mode (Open Factories) ----------------------------------
# The dispatch rule (design 10.1): <primary>/.factory-remote/config.json
# present = hosted. The client (tools/factory-client/bin/factory-client.mjs;
# FACTORY_CLIENT overrides the path - the selftest substitutes a recorder)
# prints the SAME stdout shapes local mode prints (the EMPTY wording, the
# claimed-file path, PPPPPPPPPP-IIIIIIIIII.md listing lines), so a seat sees
# one contract in both modes. The claim path is real: the client mirrors the
# claimed task into tasks/claimed/<worker>/ (the executor reads that file)
# and done moves the mirror to tasks/archive/ (grep-dedupe keeps working).

remote_dir() {  # the hosted-mode store; empty when neither the primary nor the override resolves
  if [ -n "${FACTORY_REMOTE_DIR:-}" ]; then printf '%s' "$FACTORY_REMOTE_DIR"; return 0; fi
  [ -n "${PRIMARY:-}" ] || return 0
  printf '%s/.factory-remote' "$PRIMARY"
}

hosted_mode() {  # true when this checkout is paired to a hosted factory
  local d; d="$(remote_dir)"
  [ -n "$d" ] && [ -f "$d/config.json" ]
}

client() {  # client <args...>: run the factory client with the store + primary pinned
  local c d
  c="${FACTORY_CLIENT:-$SELF_DIR/../tools/factory-client/bin/factory-client.mjs}"
  [ -f "$c" ] || die "hosted mode: the factory client is missing at $c (tools/factory-client)"
  d="$(remote_dir)"
  case "$c" in
    *.mjs|*.js) FACTORY_REMOTE_DIR="$d" FACTORY_PRIMARY="$(fleet_primary)" FACTORY_SCRIPTS_DIR="$SELF_DIR" node "$c" "$@" ;;
    *)          FACTORY_REMOTE_DIR="$d" FACTORY_PRIMARY="$(fleet_primary)" FACTORY_SCRIPTS_DIR="$SELF_DIR" "$c" "$@" ;;
  esac
}

# The client must be COMMITTED, not merely present (task 1791136652): a seat
# worktree is a fresh checkout of the branch, so an untracked client in the
# primary is a client NO seat has - every queue command there dies "the
# factory client is missing". The iig-ai extraction (2026-10-03) lost the
# entrypoint to a build-output rule `bin/` in its .gitignore for a day; the
# primary worked off the untracked copy and the first seat was born without
# it. This repository tracks the file itself (`git ls-files
# tools/factory-client/bin`), so here the check is a no-op guarding the
# next extraction. From the PRIMARY: `git ls-files --error-unmatch` over the
# entrypoint, every lib/*.mjs, package.json (+ package-lock.json when one
# exists on disk), `git check-ignore -v` naming the rule for each miss.
# Prints one line per missing / untracked path, `client: tracked` when all
# are; rc 0 tracked, 1 not, 2 no primary to ask (the caller decides).
CLIENT_REL="tools/factory-client"
client_tracked_check() {  # client_tracked_check [primary]
  local prim="${1:-}" p paths="" rc=0 ign note=""
  [ -n "$prim" ] || prim="$(fleet_primary)"
  [ -n "$prim" ] || { echo "client: UNKNOWN (cannot resolve the primary checkout to ask git)"; return 2; }
  paths="$CLIENT_REL/bin/factory-client.mjs"
  for p in "$prim/$CLIENT_REL"/lib/*.mjs; do [ -f "$p" ] && paths="$paths ${p#"$prim"/}"; done
  paths="$paths $CLIENT_REL/package.json"
  [ -f "$prim/$CLIENT_REL/package-lock.json" ] && paths="$paths $CLIENT_REL/package-lock.json"
  for p in $paths; do
    if git -C "$prim" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
      # tracked wins over an ignore rule - but a re-copy into another repo
      # (git add after cp) would drop it: worth one note, never a failure
      ign="$(git -C "$prim" check-ignore -v --no-index -- "$p" 2>/dev/null | head -1 | cut -f1 || true)"
      [ -z "$ign" ] || note="$note${note:+; }$p matches $ign"
      continue
    fi
    rc=1
    if [ ! -e "$prim/$p" ]; then echo "client: MISSING $p (not on disk under $prim)"; continue; fi
    # check-ignore -v prints "<source>:<line>:<pattern><TAB><path>"
    ign="$(git -C "$prim" check-ignore -v -- "$p" 2>/dev/null | head -1 | cut -f1 || true)"
    if [ -n "$ign" ]; then
      echo "client: UNTRACKED $p (ignored by $ign)"
    else
      echo "client: UNTRACKED $p (not ignored - never git-added)"
    fi
  done
  if [ "$rc" -eq 0 ]; then
    echo "client: tracked"
    [ -z "$note" ] || echo "client: note: tracked but matched by an ignore rule - a cp + git add into another repo would drop it: $note"
  fi
  return "$rc"
}

hosted_factory_id() {  # the paired factory id from config.json (no jq on a stock mac)
  sed -n 's/^[[:space:]]*"factoryId":[[:space:]]*"\([^"]*\)".*/\1/p' "$(remote_dir)/config.json" 2>/dev/null | head -1 || true
}

hosted_url() {
  sed -n 's/^[[:space:]]*"url":[[:space:]]*"\([^"]*\)".*/\1/p' "$(remote_dir)/config.json" 2>/dev/null | head -1 || true
}

hosted_seat_worker() {  # the seat identity for done/requeue/new: FACTORY_WORKER > pin > cwd branch
  local w
  resolve_pin
  w="${FACTORY_WORKER:-}"
  [ -n "$w" ] || w="$PIN_NAME"
  [ -n "$w" ] || w="$(branch_worker || true)"   # a seat dir outside any git tree (the selftest's) must not abort under pipefail
  printf '%s' "$w"
}

hosted_claim() {  # the seat-side half of a hosted claim: identity, gates, then the client
  local worker="" want_op=0 affinity="" top derived op_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --operator) want_op=1 ;;
      --affinity) shift; affinity="$(printf '%s' "${1:-}" | tr ',' ' ')" ;;
      --id) shift; op_id="${1:-}" ;;
      -*) die "unknown claim option '$1'" ;;
      *) worker="$1" ;;
    esac
    shift
  done
  if [ "$want_op" -eq 1 ]; then
    # The Operator SESSION's door (design 10.3): "run task <id>" from the lane
    # holder -> a targeted take under this machine's runner (seat "operator").
    # An untargeted --operator claim stays the browser's Needs-a-human page.
    if [ -n "$op_id" ]; then
      mkdir -p "$CLAIMED/operator"
      client task-take "$op_id" --tasks-root "$TASKS"
      return $?
    fi
    die "hosted mode: claim --operator without --id is the console's job - the operator INBOX is the factory's Needs-a-human page in the browser (task_take / task_answer); the Operator session runs one task with claim --operator --id <id>"
  fi
  # Identity: EXACTLY the local rule (arg > FACTORY_WORKER > pin > cwd branch),
  # the same stderr line, the same drift warnings.
  resolve_pin
  if [ -z "$worker" ]; then worker="${FACTORY_WORKER:-}"; fi
  if [ -z "$worker" ] && [ -n "$PIN_NAME" ]; then worker="$PIN_NAME"; fi
  if [ -z "$worker" ]; then worker="$(branch_worker || true)"; fi
  [ -n "$worker" ] || die "cannot derive a worker name; pass one: factory.sh claim <worker>"
  if [ -n "$PIN_NAME" ] && [ "$PIN_NAME" != "$worker" ]; then
    info "warning: claiming as '$worker' but this worktree is pinned as '$PIN_NAME' ($PIN_PATH)"
  fi
  if [ -n "$PIN_NAME" ] && [ "$PIN_NAME" = "$worker" ]; then
    derived="$(branch_worker || true)"
    if [ -n "$derived" ] && [ "$derived" != "$PIN_NAME" ]; then
      info "seat pin overrode the cwd branch ('$derived' -> '$PIN_NAME'); cwd: $(pwd -P)"
    fi
  fi
  info "worker: $worker"
  # Local orders (tasks/signal) stay a belt; the hosted signal gate is the
  # canister's - task_claim refuses while an order addresses the seat and the
  # client prints that refusal verbatim (the order text rides the message).
  signal_gate "$worker"
  if [ -n "$PRIMARY" ] && [ "${FACTORY_FORCE:-}" != "1" ]; then
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ "$top" = "$PRIMARY" ] && die "claim refused from the primary checkout - consumers work in worktrees (FACTORY_FORCE=1 overrides)"
  fi
  recycle_gate "$worker"
  duplicate_session_gate "$(claim_seat_name)"
  mkdir -p "$CLAIMED/$worker"
  if [ -n "$affinity" ]; then
    client claim "$worker" --affinity "$affinity" --tasks-root "$TASKS"
  else
    client claim "$worker" --tasks-root "$TASKS"
  fi
}

hosted_done() {  # archive: the seat's tasks/<worker>.done rides as the report (mirrored to task.report)
  local id="${1:-}" status="${2:-}" note="${3:-}" worker report="" f
  [ -n "$id" ] && [ -n "$status" ] || die "usage: factory.sh done <id> <done|abandoned|split|superseded> [note]"
  case "$status" in done|abandoned|split|superseded) : ;; *) die "bad status '$status'" ;; esac
  worker="$(hosted_seat_worker)"
  for f in "$TASKS/$worker.done" "$TASKS/sessions-done/$worker.done"; do
    if [ -f "$f" ]; then report="$f"; break; fi
  done
  if [ -z "$report" ] && [ -n "$worker" ]; then
    info "no tasks/$worker.done marker found - the report rides empty (a service-touching done then refuses under the help law)"
  fi
  if [ "${FACTORY_FORCE:-}" = "1" ]; then
    client done "$id" "$status" "$note" ${report:+--report "$report"} --force --seat "${worker:-runner}" --tasks-root "$TASKS"
  else
    client done "$id" "$status" "$note" ${report:+--report "$report"} --seat "${worker:-runner}" --tasks-root "$TASKS"
  fi
}

hosted_watch() {  # the client polls queue_version + signal_version; the obituary trap stays bash's
  local max="${1:-500}"
  watch_arm_obituary watch
  client watch "$max" &
  WATCH_CHILD=$!
  wait "$WATCH_CHILD"
}

cmd_hosted() {  # cmd_hosted <queue-command> [args...]
  local cmd="$1" producer; shift
  case "$cmd" in
    new)
      [ -n "${1:-}" ] && [ -f "${1:-}" ] || die "usage: factory.sh new <draft.md> (draft file must exist)"
      [ -n "$(title_of "$1")" ] || die "draft has no '# <title>' line"
      producer="$(hosted_seat_worker)"
      new_cite_warn "$1" "$producer"   # the in-flight-claim cite warning (task 1792508238): bash's, before the call
      # Extra flags pass through: --override "<reason>" files a non-clear
      # verdict for a split whose parent this seat holds (design 7.3);
      # --attach <file> (repeatable, task 1791312774) stages the file as the
      # runner and it rides the filing (2 MB per file, 5 files / 8 MB per task);
      # --band NN (task 1792613259, the hosted twin of the local filing band)
      # is the client's: it writes the flag as the draft's band: line (the
      # flag wins over one the draft carries) and the canister files at that
      # key - hygiene / cosmetic / parked land at 30 / 40 / 90 with no flag at
      # all - and prints the same "filed at band NN" stderr line; a bad value
      # refuses in the client before any call, with the local door's words.
      client new "$1" --producer "${producer:-seat}" "${@:2}"
      ;;
    amend)
      # The seat appends to the body of ITS claim and/or adds files to it
      # (task_amend's trailing attachments): factory.sh amend <id> [text]
      # [--attach <file>]... - the claim mirror under tasks/claimed/ is
      # refreshed (new files land beside the task file).
      [ -n "${1:-}" ] || die "usage: factory.sh amend <id> [text|file|-] [--attach <file>]..."
      client amend "$@" --seat "$(hosted_seat_worker)" --tasks-root "$TASKS"
      ;;
    list)
      case "${1:-}" in ''|--operator|--consumer) : ;; *) die "usage: factory.sh list [--operator|--consumer]" ;; esac
      client list "$@"
      ;;
    show)
      [ -n "${1:-}" ] || die "usage: factory.sh show <id>"
      client show "$1"
      ;;
    claim)        hosted_claim "$@" ;;
    done)         hosted_done "$@" ;;
    requeue)
      [ -n "${1:-}" ] || die "usage: factory.sh requeue <id> [band] [note]"
      client requeue "$@" --seat "$(hosted_seat_worker)" --tasks-root "$TASKS"
      ;;
    reprioritize)
      [ -n "${1:-}" ] && [ -n "${2:-}" ] || die "usage: factory.sh reprioritize <id> <band(2 digits)|key(10 digits)>"
      client reprioritize "$1" "$2"
      ;;
    index)        client index --write "$FACTORY/index.md" ;;
    signal)
      [ -n "${1:-}" ] && [ -n "${2:-}" ] || die "usage: factory.sh signal <worker|all> <text|file.md>"
      client signal "$(basename "$1" .md)" "$2"
      ;;
    signal-list)  client signal-list ;;
    signal-clear)
      [ -n "${1:-}" ] || die "usage: factory.sh signal-clear <worker|all>"
      client signal-clear "$(basename "$1" .md)"
      ;;
    watch)        hosted_watch "$@" ;;
    *) die "hosted dispatch has no arm for '$cmd'" ;;
  esac
}

cmd_remote_pair() {  # remote-pair <osf-url> <OSFR-code> [--label L] [--force]: this checkout becomes a hosted runner
  local url="" code="" label="" f
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) shift; label="${1:-}" ;;
      # --force == FACTORY_FORCE=1: re-pair while paired (a REVOKED runner
      # re-pairs with the existing key as a new R-n; the client prints the
      # principal it reuses - rotate the key with remote-unpair first).
      --force) export FACTORY_FORCE=1 ;;
      -*) die "unknown remote-pair option '$1'" ;;
      *) if [ -z "$url" ]; then url="$1"; elif [ -z "$code" ]; then code="$1"; else die "remote-pair: unexpected argument '$1'"; fi ;;
    esac
    shift
  done
  [ -n "$url" ] && [ -n "$code" ] || die "usage: factory.sh remote-pair <osf-url> OSFR-XXXX-XXXX-XXXX [--label <machine-name>]"
  [ -n "$(remote_dir)" ] || die "remote-pair: cannot resolve the primary checkout (run it inside the suite repo, or set FACTORY_REMOTE_DIR)"
  if hosted_mode && [ "${FACTORY_FORCE:-}" != "1" ]; then
    die "already paired: $(hosted_factory_id) @ $(hosted_url) ($(remote_dir)/config.json) - FACTORY_FORCE=1 factory.sh remote-unpair first"
  fi
  [ -n "$label" ] || label="$(hostname -s 2>/dev/null || echo factory-machine)"
  # The client must be committed BEFORE this checkout becomes a runner: the
  # key is minted and the code redeemed by the client itself, so refusing
  # here costs nothing (no network call, no key, no config) - task 1791136652.
  local tracked_rc=0 tracked_out
  tracked_out="$(client_tracked_check 2>&1)" || tracked_rc=$?
  case "$tracked_rc" in
    0) : ;;
    2) info "remote-pair: $tracked_out - skipping the committed-client check" ;;
    *) printf '%s\n' "$tracked_out" >&2
       die "remote-pair: the factory client is not committed - a seat worktree would have no client (every queue command there dies 'hosted mode: the factory client is missing'); commit it first - fix the .gitignore rule named above, git add $CLIENT_REL, commit - then re-run" ;;
  esac
  client pair "$url" "$code" --label "$label" || die "remote-pair failed (see above) - nothing switched"
  f="$(remote_dir)"
  chmod 700 "$f" 2>/dev/null || true
  echo "hosted mode: $(hosted_factory_id) @ $(hosted_url)"
  info "every factory.sh queue command in this checkout (and its worktrees) now goes to the hosted factory; install the poller: factory.sh remote-poll --launchd-plist"
}

cmd_remote_status() {
  if ! hosted_mode; then
    echo "mode: local"
    echo "store: $(remote_dir)/config.json (absent)"
    return 0
  fi
  # the committed-client line before the client's own status: when the
  # client is what is missing, this line is the diagnosis a seat gets
  client_tracked_check 2>/dev/null || true
  client status
}

cmd_remote_unpair() {  # deletes config + runner key: back to the local directory queue
  hosted_mode || { echo "not paired (mode: local)"; return 0; }
  [ "${FACTORY_FORCE:-}" = "1" ] || die "remote-unpair deletes the runner key and switches every seat on this machine back to the LOCAL queue: FACTORY_FORCE=1 factory.sh remote-unpair (then revoke the runner on the factory's Runners tab)"
  client unpair
  echo "mode: local"
  if [ -e "$IDS/FROZEN" ]; then
    info "note: the local id allocator stays FROZEN ($IDS/FROZEN - $(cat "$IDS/FROZEN" 2>/dev/null || true)); local 'new' keeps refusing until the marker is removed - remote-export the hosted queue FIRST if this is a rollback"
  fi
}

# --- the 16.1 migration: remote-import / remote-export ----------------------
# A LOCAL directory factory moves into the paired hosted factory with IDS
# PRESERVED (canister side: task_import_begin / task_import / task_import_commit
# behind the runner gate, atomic per batch, idempotent by id - an identical
# record is `unchanged`, a different body IMPORT-CONFLICT; the allocator
# continues above the highest imported id). remote-export is the reverse -
# the hosted queue written back into the directory layout (queue/ claimed/
# archive/ signal/ + reports/) - the cutover's exit and a backup. Both run
# from the PRIMARY only, in hosted mode, never while a merge is in flight.
# After a successful non-dry import the local allocator is FROZEN
# (tasks/factory/.ids/FROZEN - local `new` refuses past it) and the run is
# logged to tasks/factory/imported-<date>.log. Nothing local is ever deleted:
# the cutover task decides when the local queue retires.

migrate_gates() {  # migrate_gates <command>: hosted, the primary, no merge in flight
  local cmd="$1" top prim
  hosted_mode || die "$cmd: not paired (mode: local) - pair this checkout first: factory.sh remote-pair <osf-url> OSFR-... --label <machine>"
  prim="$(fleet_primary)"
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$top" ] && [ -n "$prim" ] && [ -d "$prim" ]; then
    [ "$(cd "$top" && pwd -P)" = "$(cd "$prim" && pwd -P)" ] || die "$cmd runs from the PRIMARY checkout only ($prim) - never from a worktree ($top)"
  fi
  if [ -d "$FACTORY/merge.lock" ]; then
    die "$cmd refused: the merge lock is held by $(cat "$FACTORY/merge.lock/owner" 2>/dev/null || echo unknown) - wait for that merge to finish (factory.sh merge-lock status)"
  fi
}

cmd_remote_import() {  # remote-import [--dry-run] [--include-archive] [--include-claims]
  local dry=0 flags="" outf rc=0 stamp logf aside moved f
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; flags="$flags --dry-run" ;;
      --include-archive|--include-claims) flags="$flags $1" ;;
      *) die "usage: factory.sh remote-import [--dry-run] [--include-archive] [--include-claims]" ;;
    esac
    shift
  done
  migrate_gates remote-import
  outf="$FACTORY/.import.$$"
  # shellcheck disable=SC2086
  if client import --tasks-root "$TASKS" $flags > "$outf" 2>&1; then rc=0; else rc=$?; fi
  cat "$outf"
  if [ "$rc" -ne 0 ]; then rm -f "$outf"; die "remote-import failed (exit $rc) - nothing was frozen; see the lines above"; fi
  if [ "$dry" -eq 1 ]; then rm -f "$outf"; return 0; fi
  stamp="$(now_iso)"
  logf="$FACTORY/imported-$(date -u +%Y-%m-%d).log"
  {
    echo "== remote-import $stamp: $(hosted_factory_id) @ $(hosted_url) (runner $(sed -n 's/^[[:space:]]*"runnerId":[[:space:]]*"\([^"]*\)".*/\1/p' "$(remote_dir)/config.json" 2>/dev/null | head -1 || true)) flags:${flags:- none}"
    cat "$outf"
  } >> "$logf"
  rm -f "$outf"
  # The imported orders leave the LOCAL belt: from now on a hosted claim's
  # signal gate is the factory's (task_claim refuses while the imported
  # order stands), and a local all.md left in place would keep refusing
  # every seat past the cutover with an order nobody can clear (the hosted
  # signal-clear never touches the file). Moved aside, never deleted.
  aside="$SIGNAL/.imported-$(date -u +%Y%m%d-%H%M%S)"
  moved=0
  for f in "$SIGNAL"/*.md; do
    [ -e "$f" ] || continue
    mkdir -p "$aside"; mv "$f" "$aside/"; moved=$((moved+1))
  done
  if [ -d "$SIGNAL/all.acked" ]; then mkdir -p "$aside"; mv "$SIGNAL/all.acked" "$aside/all.acked"; fi
  if [ "$moved" -gt 0 ]; then info "$moved imported signal file(s) moved aside to $aside (the hosted signal gate is authoritative now; the files are kept)"; fi
  mkdir -p "$IDS"
  if [ ! -e "$IDS/FROZEN" ]; then
    echo "frozen by remote-import at $stamp - hosted factory $(hosted_factory_id) @ $(hosted_url)" > "$IDS/FROZEN"
    info "local id allocator FROZEN ($IDS/FROZEN): every later id is the hosted factory's; local 'new' refuses from now on"
  fi
  info "logged to $logf; the local files were left in place (the cutover decides when the local queue retires)"
}

cmd_remote_export() {  # remote-export [--out <dir>]: the hosted factory back into the directory layout
  local dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) shift; dir="${1:-}" ;;
      *) die "usage: factory.sh remote-export [--out <dir>]" ;;
    esac
    shift
  done
  migrate_gates remote-export
  [ -n "$dir" ] || dir="$FACTORY/export-$(date -u +%Y%m%d-%H%M%S)"
  case "$dir" in /*) : ;; *) dir="$(pwd -P)/$dir" ;; esac
  if [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    die "remote-export: $dir exists and is not empty - name a fresh directory (--out), never the live tasks/ tree"
  fi
  case "$(cd "$(dirname "$dir")" 2>/dev/null && pwd -P)/$(basename "$dir")" in
    "$QUEUE"|"$CLAIMED"|"$ARCHIVE"|"$SIGNAL"|"$TASKS") die "remote-export: refusing to write into the live tasks/ tree ($dir) - export to a fresh directory" ;;
  esac
  client export --out "$dir"
}

# --- the poller (design 10.2): one launchd job ------------------------------
# Every OSF_POLL_SECS (60): (1) telemetry -> runner_heartbeat, (2) the ground
# write-back (doc-changes: the producer's approved doc changes applied as
# authored commits on main under the merge lock - design 8.1, task
# 1789046639) then the ground map (ground-sync: upload on main-sha change
# through sha256-verified chunked sessions, atomic swap; ground-serve: the
# pull-through tickets - task 1789051647), (3) the lanes - the Operator and
# Supervisor headless sessions, one driver subprocess per lane, run
# CONCURRENTLY (never one session for both; design 10.3, task 1789039767),
# (4) alerts. Each step is fail-soft and logged; a single-instance mkdir
# lock refuses a second poller. --once runs one pass and exits (the verify +
# hand checks); --launchd-plist prints the KeepAlive agent.

poll_lock_acquire() {  # mkdir-claim like lock_acquire in lib.sh; stale = owner pid gone
  # The break is generation-checked (lockdir_take) and an unstamped lock gets
  # lib.sh's 15 s grace (2026-10-03, a reviewer's note on open-saas PR #17): the bare
  # mv-then-rm here let a second poller that arrived between the first one's
  # mkdir and its pid write break a LIVE lock, and in some orderings both ran.
  local lock="$1" owner gen now age
  while ! mkdir "$lock" 2>/dev/null; do
    gen="$(lockdir_gen "$lock")"   # the hold this pass judges, read before its pid
    owner="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -z "$owner" ]; then
      now="$(now_s)"
      age=$(( now - $(stat -f %m "$lock" 2>/dev/null || echo "$now") ))
      if [ "$age" -gt 15 ]; then
        lockdir_take "$lock" "$gen" && info "remote-poll: broke a stale poll lock (unstamped for ${age}s)"
        continue
      fi
      [ -d "$lock" ] || continue   # vanished between the mkdir and the read: retry
      sleep 1; continue            # a poller between its mkdir and its pid write: the grace
    fi
    if ! ps -p "$owner" -o pid= >/dev/null 2>&1; then
      lockdir_take "$lock" "$gen" && info "remote-poll: broke a stale poll lock (owner $owner is gone)"
      continue
    fi
    die "remote-poll: another poller is running (pid $owner) - one instance per machine"
  done
  echo "$$" > "$lock/pid"
}

poll_lane_line() {  # poll_lane_line <lane> <rc> <outfile>: the log line for one lane driver
  local lane="$1" rc="$2" f="$3" last
  last="$(grep -v '^factory-client:' "$f" 2>/dev/null | tail -1)"
  [ -n "$last" ] || last="$(tail -1 "$f" 2>/dev/null)"
  if [ "$rc" -eq 0 ]; then
    echo "  lane $last"
  else
    echo "  lane $lane: FAILED (exit $rc): $last"
    case "$last" in *RUNNER-REVOKED*) echo "  ALERT: this machine's runner is REVOKED on the factory - the lanes cannot answer; re-pair" ;; esac
  fi
  # the driver's own progress lines (retries, fresh boots) ride the log too
  grep '^factory-client:' "$f" 2>/dev/null | sed 's/^factory-client: /    /' || true
}

POLL_PRIMARY=""
poll_pass() {  # one pass; prints its lines (launchd redirects stdout into the log)
  local out rc d
  d="$(remote_dir)"
  echo "osf-poll $(now_iso) pass ($(hosted_factory_id) @ $(hosted_url))"
  # (0) the committed-client check: logged when it fails, never blocking
  # the pass (the primary works off its untracked copy; the seats do not)
  if ! out="$(client_tracked_check "$POLL_PRIMARY" 2>/dev/null)"; then
    printf '%s\n' "$out" | grep -v '^client: tracked$' | sed 's/^/  /' || true
    echo "  ALERT: the factory client is not committed - seats minted from this checkout have no client; commit $CLIENT_REL"
  fi
  # (1) telemetry
  if out="$(client heartbeat --collect --primary "$POLL_PRIMARY" 2>&1)"; then
    echo "  telemetry: $out"
  else
    rc=$?
    echo "  telemetry: FAILED (exit $rc): $(printf '%s' "$out" | tail -1)"
    case "$out" in *RUNNER-REVOKED*) echo "  ALERT: this machine's runner is REVOKED on the factory - seats will stop claiming; re-pair (remote-unpair, then remote-pair with a fresh code)" ;; esac
    case "$out" in *"factory archived"*|*"is archived"*) echo "  ALERT: the paired factory is ARCHIVED - unpair or pair to another factory" ;; esac
  fi
  # (2) the ground write-back FIRST (design 8.1, task 1789046639): the
  # producer's approved doc changes become authored commits on main under
  # the merge lock (held = skipped this pass), so the ground sync right
  # after uploads a map that already carries them.
  if out="$(client doc-changes --primary "$POLL_PRIMARY" 2>&1)"; then echo "  docs: $out"; else echo "  docs: FAILED (exit $?): $(printf '%s' "$out" | tail -1)"; fi
  # then the ground map
  if out="$(client ground-sync --primary "$POLL_PRIMARY" 2>&1)"; then echo "  ground: $out"; else echo "  ground: FAILED (exit $?): $(printf '%s' "$out" | tail -1)"; fi
  if out="$(client ground-serve --primary "$POLL_PRIMARY" 2>&1)"; then echo "  ground: $out"; else echo "  ground-serve: FAILED (exit $?): $(printf '%s' "$out" | tail -1)"; fi
  # (3) the lanes: two concurrent drivers, one per lane (each is one turn per
  # pending message, oldest first; a failure is posted to the lane, never
  # swallowed). Output per lane lands in $d/lane.<lane>.out for the log line.
  client lane-run operator --primary "$POLL_PRIMARY" > "$d/lane.operator.out" 2>&1 &
  local p_op=$!
  client lane-run supervisor --primary "$POLL_PRIMARY" > "$d/lane.supervisor.out" 2>&1 &
  local p_sv=$!
  local rc_op=0 rc_sv=0
  wait "$p_op" || rc_op=$?
  wait "$p_sv" || rc_sv=$?
  poll_lane_line operator "$rc_op" "$d/lane.operator.out"
  poll_lane_line supervisor "$rc_sv" "$d/lane.supervisor.out"
  now_iso > "$d/poll.last"
}

poll_launchd_plist() {  # the operator-installed KeepAlive agent
  local primary="$1" prefix="$2" label logf secs
  label="$prefix.osf-poll"
  logf="$HOME/Library/Logs/$prefix-osf-poll.log"
  secs="${OSF_POLL_SECS:-60}"
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$primary/scripts/factory.sh</string>
    <string>remote-poll</string>
  </array>
  <key>WorkingDirectory</key><string>$primary</string>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$logf</string>
  <key>StandardErrorPath</key><string>$logf</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
    <key>OSF_POLL_SECS</key><string>$secs</string>
    <key>CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP</key><string>1</string>
  </dict>
</dict>
</plist>
PLIST
  {
    echo "factory: install (operator step): factory.sh remote-poll --launchd-plist > ~/Library/LaunchAgents/$label.plist && launchctl load -w ~/Library/LaunchAgents/$label.plist"
    echo "factory: the job polls every ${secs}s (OSF_POLL_SECS) while paired; log: $logf; CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1 rides in its env for the two headless lane sessions it drives (claude -p --resume per lane; OSF_TURN_MAX_MIN caps a turn at 30 min)"
  } >&2
}

cmd_remote_poll() {
  local once=false lock d secs
  while [ $# -gt 0 ]; do
    case "$1" in
      --once) once=true ;;
      --launchd-plist) poll_launchd_plist "$(fleet_primary)" "$(project_prefix)"; return 0 ;;
      *) die "usage: factory.sh remote-poll [--once] [--launchd-plist]" ;;
    esac
    shift
  done
  hosted_mode || die "remote-poll: not paired (mode: local) - factory.sh remote-pair first"
  # The poller is NOT a seat: its doc-change commits land on main in the
  # primary, where the pre-commit hook refuses any seat-identified commit.
  [ -z "${FACTORY_WORKER:-}" ] || die "remote-poll: FACTORY_WORKER is set ('$FACTORY_WORKER') - the poller carries no seat identity (its doc-change commits on main would trip the law-5 pre-commit hook); unset it in the poller's environment"
  POLL_PRIMARY="$(fleet_primary)"
  [ -n "$POLL_PRIMARY" ] || die "remote-poll: cannot resolve the primary checkout (run it inside the suite repo)"
  d="$(remote_dir)"
  lock="$d/poll.lock"
  secs="${OSF_POLL_SECS:-60}"
  case "$secs" in ''|*[!0-9]*) die "OSF_POLL_SECS must be a whole number of seconds" ;; esac
  poll_lock_acquire "$lock"
  trap 'rm -rf "'"$lock"'"' EXIT INT TERM
  while : ; do
    poll_pass || true
    [ "$once" = true ] && break
    sleep "$secs"
  done
}

# --- commands ---------------------------------------------------------------

cmd_root() { echo "$TASKS"; }

cmd_worker_pin() {  # write <worktree-root>/.factory-worker (the seat's boot step)
  local name="${1:-}" top f cur
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] || die "worker-pin must run inside a git worktree (it writes <worktree-root>/$PIN_FILE)"
  [ -n "$name" ] || name="$(branch_worker)"
  [ -n "$name" ] || die "cannot derive a worker name (detached HEAD?); pass one: factory.sh worker-pin <worker>"
  case "$name" in */*|*..*) die "worker name '$name' is unusable as a directory name" ;; esac
  if [ -n "$PRIMARY" ] && [ "$top" = "$PRIMARY" ] && [ "${FACTORY_FORCE:-}" != "1" ]; then
    die "refusing to pin a worker in the PRIMARY checkout - consumers work in worktrees, law 5 (FACTORY_FORCE=1 overrides)"
  fi
  # The seat's first act is where an EXTRA boot (a spawn whose AppleEvent
  # timed out and ran later, beside the session that already runs the seat)
  # must end: DUPLICATE-SESSION refuses and the boot prompt's first command
  # fails - the session exits instead of claiming (task 1789588684).
  duplicate_session_gate "$(basename "$top")"
  f="$top/$PIN_FILE"
  if [ -f "$f" ]; then
    cur="$(head -1 "$f" 2>/dev/null | tr -d '[:space:]')"
    [ "$cur" = "$name" ] || info "repinning seat identity: was '$cur'"
  fi
  printf '%s\n' "$name" > "$f"
  # The seat is now KNOWN: register it on the fleet roster (the doctor's
  # memory of which seats exist - a vanished worktree reads ORPHANED instead
  # of silently dropping out of the count) and stamp the git admin dir
  # tripwire. See the roster section.
  roster_register "$top" "$name"
  # The desktop app's keep sentinel: its untracked-dir GC keeps a worktree
  # carrying .worktree-keep before any age/clean check (the seat-root
  # section). Dropped everywhere; it is the BELT for a seat still under the
  # legacy .claude/worktrees pool root.
  seat_keep_sentinel "$top"
  if seat_legacy_located "$top"; then
    info "legacy location: $top sits in the desktop app's worktree pool root ($LEGACY_SEAT_ROOT_REL) - the app's 30-min GC removes idle untracked trees there; $KEEP_SENTINEL dropped as the belt. New seats mint under $(seat_root 2>/dev/null || echo "<primary>/$SEAT_ROOT_REL") (factory.sh seat-root); this seat moves there at its next seat-recreate/retirement, never while live"
  fi
  echo "$f"
}

cmd_worker() {  # print the identity this cwd resolves to, and where it came from
  local derived
  resolve_pin
  derived="$(branch_worker)"
  if [ -n "${FACTORY_WORKER:-}" ]; then
    printf '%s\t(FACTORY_WORKER)\n' "${FACTORY_WORKER}"
  elif [ -n "$PIN_NAME" ]; then
    printf '%s\t(pin %s)\n' "$PIN_NAME" "$PIN_PATH"
  elif [ -n "$derived" ]; then
    printf '%s\t(cwd branch)\n' "$derived"
  else
    printf 'UNRESOLVED\t(no pin, no branch - pass a worker explicitly)\n'
  fi
  if [ -n "$PIN_NAME" ] && [ -n "$derived" ] && [ "$PIN_NAME" != "$derived" ]; then
    info "note: cwd branch derives '$derived' but the seat pin says '$PIN_NAME'"
  fi
}

# `executor-env [seat]` prints the ONE line a seat pastes at the head of its
# executor subagent's Bash-prefix rule (task 1791133471): the Agent tool does
# not inherit the seat's exports and the .factory-worker pin lives in the seat
# worktree the subagent's cd target may leave - on 2026-10-04 an executor with
# neither cd'd into the PRIMARY and committed 1dc9df2fa straight onto main past
# every law-5 guard, because all of them key on the identity this line carries.
# The pin is the source (never the cwd branch, never FACTORY_WORKER - a
# drifted export is what the line must correct), FACTORY_SEAT_ROOT the
# worktree the pin sits in, so the prompt's rule reads
#   export FACTORY_WORKER=<pin> FACTORY_SEAT_ROOT=<worktree>; cd "$FACTORY_SEAT_ROOT" && ...
cmd_executor_env() {  # executor-env [seat]: print FACTORY_WORKER=<pin> FACTORY_SEAT_ROOT=<worktree> for the executor prompt
  local seat="${1:-}" path pin v
  [ $# -le 1 ] || die "usage: factory.sh executor-env [seat]"
  case "$seat" in -*) die "usage: factory.sh executor-env [seat]" ;; esac
  if [ -n "$seat" ]; then
    seat="$(basename "$seat")"
    case "$seat" in .|..|'') die "executor-env: '$1' is not a seat name" ;; esac
    path="$(seat_root)/$seat"
    [ -f "$path/$PIN_FILE" ] || path="$(fleet_primary)/$LEGACY_SEAT_ROOT_REL/$seat"
    [ -f "$path/$PIN_FILE" ] || die "executor-env: seat '$seat' has no $PIN_FILE pin under $(seat_root) or $(fleet_primary)/$LEGACY_SEAT_ROOT_REL - a seat pins itself with 'factory.sh worker-pin' from its worktree"
    pin="$path/$PIN_FILE"
  else
    pin="$(find_worker_pin || true)"
    [ -n "$pin" ] || die "executor-env: no $PIN_FILE pin at/above $(pwd -P 2>/dev/null || pwd) - run it from inside a PINNED seat worktree (or name the seat: factory.sh executor-env <seat>); the primary has no pin by design, so from there this line cannot be minted"
    path="$(dirname "$pin")"
  fi
  v="$(head -1 "$pin" 2>/dev/null | tr -d '[:space:]')"
  case "$v" in ''|*/*|*..*) die "executor-env: unusable worker pin '$v' in $pin" ;; esac
  path="$(cd "$path" 2>/dev/null && pwd -P || printf '%s' "$path")"
  if [ -z "$seat" ] && [ -n "${FACTORY_WORKER:-}" ] && [ "$FACTORY_WORKER" != "$v" ]; then
    info "note: FACTORY_WORKER is '$FACTORY_WORKER' in this shell but the seat pin says '$v' - the pin wins (that is the drift this line corrects)"
  fi
  printf 'FACTORY_WORKER=%s FACTORY_SEAT_ROOT=%s\n' "$v" "$path"
}

# A follow-up that cites the filer's OWN in-flight claim (task 1792508238):
# on 2026-10-20 four drafts across three seats named the filing seat's
# still-CLAIMED parent ("task <id> follow-up" in the producer line or the
# body) with no after: naming it. Each built on code that reaches main only
# when the parent merges, so the seat that claimed one first failed its own
# step-2 sanity check (cited files missing on main) and bounced it - a full
# claim cycle wasted. The producer rule already says "file prerequisites
# first, cite the printed ids"; a seat's own held claim is the prerequisite
# it forgets. So new WARNS - once per held claim the draft cites (a plain
# grep on the 10-digit id over the whole draft) and its after: line does not
# name - and ONLY warns: the line is never added silently (a pre-existing
# bug found by a verify is often independent of the parent) and the filing
# is never refused; stdout and the exit code are untouched. The identity is
# new's producer one (FACTORY_WORKER > the .factory-worker pin > the cwd
# branch - hosted_seat_worker, the merge-lock belt's rule too); a caller
# holding nothing under tasks/claimed/<worker>/ is untouched. The hosted
# wrapper runs the same check before the client call (the draft is local
# text, and the claim mirrors live under the same tasks/claimed/).
new_cite_warn() {  # new_cite_warn <draft> <worker>: stderr only, never fails
  local draft="$1" worker="${2:-}" after f id
  [ -n "$worker" ] && [ -d "$CLAIMED/$worker" ] || return 0
  after=" $(field_of "$draft" after | tr -cs '0-9' ' ') "
  for f in "$CLAIMED/$worker"/*.md; do
    [ -f "$f" ] || continue
    id="$(id_of "$f")"
    case "$after" in *" $id "*) continue ;; esac
    grep -q -- "$id" "$draft" 2>/dev/null || continue
    info "new: this draft cites your in-flight claim $id but its after: does not name it - if the work needs that task's merge on main, re-file with 'after: $id' (a follow-up that stands on its own needs nothing)"
  done
  return 0
}

cmd_new() {
  local draft="" stage id tries=0 target dep bad="" known m attach="" f n_att=0 sz total=0 base adir rel band_flag="" band="" band_why="" band_fm="" cls="" prio
  # --attach <file> (repeatable, task 1791312774): the task's FILES. Local
  # mode copies them to tasks/attachments/<id>/<basename> (the repo's own
  # queue - a logo belongs in the repo anyway) and appends the same
  # "## Attachments" section the hosted claim mirror carries; claim leaves
  # them where they are (the path is already tasks-root-relative). The
  # canister's caps apply here too: 2 MB per file, 5 files / 8 MB per task.
  # --band NN (task 1792609968): the FILING band, over the draft's band:
  # line and the class default (resolved below, after the draft checks).
  while [ $# -gt 0 ]; do
    case "$1" in
      --attach) shift; [ -n "${1:-}" ] || die "--attach needs a file"; attach="$attach${attach:+
}$1" ;;
      --band) shift; is_band "${1:-}" || die "--band needs a 1-2 digit band (00-99), got '${1:-}'"; band_flag="$1" ;;
      -*) die "unknown new option '$1' (local mode takes --attach <file> and --band NN; --override is hosted mode's)" ;;
      *) [ -z "$draft" ] || die "usage: factory.sh new <draft.md> [--attach <file>]... [--band NN]"; draft="$1" ;;
    esac
    shift
  done
  [ -n "$draft" ] && [ -f "$draft" ] || die "usage: factory.sh new <draft.md> (draft file must exist)"
  [ -n "$(title_of "$draft")" ] || die "draft has no '# <title>' line"
  # The FILING band (task 1792609968). Every filing used to land at the
  # natural band (the key = the id) whatever its class:, and the
  # prioritizer's reband to 30 came on its NEXT pass - event-driven, but a
  # consumer freed in the window between the filing and that pass saw the
  # new file as the HEAD of the natural band and claimed it over every
  # banded task (2026-10-21: a hygiene filing claimed 41 s after it was
  # filed, ahead of 27 band-30 tasks the prioritizer had ordered; ~45
  # hygiene filings rebanded by hand that day). So the class decides the
  # filing band: hygiene -> 30, cosmetic -> 40, parked -> 90 - the DEMOTING
  # defaults only; every other class (feature, bug, architecture, ops,
  # security-*, prerequisite, verification, ...) and no class at all file
  # at the natural band as before, and every promotion stays the
  # prioritizer's judgment. A 'band: NN' front-matter line or --band NN
  # (the flag wins) overrides the default - the producer's explicit call;
  # reprioritize still moves anything afterwards (this is only the FILING
  # default). stdout stays the queue path alone (callers test -f on it); a
  # banded filing adds ONE stderr line naming the band and why. The class
  # match is case-insensitive on the field's first word ("Hygiene (lint
  # debt)" and "hygiene, cosmetic" both read hygiene). Hosted mode has no
  # arm for this: cmd_hosted says so (task_submit_checked carries no
  # priority; the canister's pass bands by class after the filing).
  band_fm="$(field_of "$draft" band)"
  [ -z "$band_fm" ] || is_band "$band_fm" || die "band: must be a 1-2 digit band (00-99), got 'band: $band_fm'"
  if [ -n "$band_flag" ]; then
    band="$band_flag"; band_why="--band $(printf '%02d' "$((10#$band_flag))")"
    [ -z "$band_fm" ] || band_why="$band_why, over the draft's band: $band_fm"
  elif [ -n "$band_fm" ]; then
    band="$band_fm"; band_why="band: $band_fm on the draft"
  else
    cls="$(field_of "$draft" class | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-].*//')"
    case "$cls" in
      hygiene)  band=30 ;;
      cosmetic) band=40 ;;
      parked)   band=90 ;;
    esac
    [ -z "$band" ] || band_why="class: $cls"
  fi
  if [ -n "$attach" ]; then
    while IFS= read -r f; do
      [ -f "$f" ] || die "--attach $f: no such file"
      sz="$(wc -c < "$f" | tr -d ' ')"
      [ "$sz" -gt 0 ] || die "--attach $f: an attachment is 1 byte .. 2 MB (empty file)"
      [ "$sz" -le 2000000 ] || die "--attach $f: $sz bytes - over the 2 MB per-file cap"
      n_att=$((n_att+1)); total=$((total+sz))
    done <<EOF_ATT
$attach
EOF_ATT
    [ "$n_att" -le 5 ] || die "--attach: a task carries at most 5 files ($n_att picked)"
    [ "$total" -le 8000000 ] || die "--attach: the picked files total $total bytes - over the 8 MB per-task cap"
  fi
  # The frozen allocator (design 16.1): remote-import moved this queue into a
  # hosted factory and every later id is the canister's - a local mint here
  # would collide with the hosted range the moment the two met again.
  if [ -e "$IDS/FROZEN" ]; then
    die "this factory is hosted; run in the primary with .factory-remote present (the local id allocator was frozen by remote-import: $(cat "$IDS/FROZEN" 2>/dev/null || true); factory.sh remote-status shows the pairing - rollback = remote-export, then remove tasks/factory/.ids/FROZEN)"
  fi
  # after:-reference validation (task 1786983440): a filing whose after:
  # names an id that was never minted gates NOTHING - claim's live-ids-only
  # rule (correct, unchanged) treats an unknown id as satisfied, so one
  # guessed id silently un-gates a strictly ordered chain (the 2026-08-17
  # wave incident: four "sequential" tasks claimed concurrently within a
  # minute). Refuse the filing instead - the producer knows the real
  # intent; new cannot guess it. Existence = the append-only allocator
  # (every id ever minted, O(1)) with the queue/claimed/archive file scan
  # as a belt for foreign state. nullglob is on (main), so unmatched
  # archive-variant globs VANISH - test each candidate with -e, never pass
  # a glob to an external (an empty ls succeeds and defeats the check).
  for dep in $(field_of "$draft" after | tr -cs '0-9' ' '); do
    known=0
    if [ -d "$IDS/$(pad "$dep")" ] || id_live "$dep" || [ -e "$ARCHIVE/$(pad "$dep").md" ]; then
      known=1
    fi
    if [ "$known" -eq 0 ]; then
      for m in "$ARCHIVE/$(pad "$dep")".*.md; do
        if [ -e "$m" ]; then known=1; fi
      done
    fi
    if [ "$known" -eq 0 ]; then bad="$bad $dep"; fi
  done
  if [ -n "$bad" ]; then
    die "after: references unknown task id(s):$bad - file prerequisites FIRST, in dependency order, and use the ids new prints (a guessed id gates nothing: claim treats unknown ids as satisfied)"
  fi
  # The in-flight-claim cite warning (above): validated draft, before the mint.
  new_cite_warn "$draft" "$(hosted_seat_worker)"
  # Mint a globally-unique id: mkdir in the allocator is the atomic arbiter,
  # and allocator entries are NEVER removed, so an id can never be reused even
  # after its task is claimed or archived (ids are identity forever).
  id="$(now_s)"
  while ! mkdir "$IDS/$(pad "$id")" 2>/dev/null; do
    id=$((id+1)); tries=$((tries+1))
    [ "$tries" -lt 600 ] || die "could not allocate an id after 600 tries"
  done
  stage="$FACTORY/.stage.$$"
  cp "$draft" "$stage"
  if [ -n "$attach" ]; then
    adir="$TASKS/attachments/$(pad "$id")"
    mkdir -p "$adir"
    {
      printf '\n## Attachments\n\n'
      while IFS= read -r f; do
        base="$(basename "$f")"
        cp "$f" "$adir/$base" || die "cannot copy $f to $adir"
        rel="attachments/$(pad "$id")/$base"
        printf -- '- %s (%s bytes, sha256 %s, uploaded by %s)\n' "$rel" "$(wc -c < "$f" | tr -d ' ')" "$(sha256_of "$f")" "${FACTORY_WORKER:-$(branch_worker 2>/dev/null || echo local)}"
      done <<EOF_ATT
$attach
EOF_ATT
    } >> "$stage"
  fi
  if [ -n "$band" ]; then prio="$(band_key "$band" "$id")"; else prio="$(pad "$id")"; fi
  target="$QUEUE/$prio-$(pad "$id").md"
  ln "$stage" "$target" || { rm -f "$stage"; die "cannot create $target"; }
  rm -f "$stage"
  [ -z "$band" ] || info "new: filed at band $(printf '%02d' "$((10#$band))") ($band_why) - the prioritizer reviews every filing and may move it"
  echo "$target"
}

cmd_list() {
  local f only="${1:-}" tag
  case "$only" in ''|--operator|--consumer) : ;; *) die "usage: factory.sh list [--operator|--consumer]" ;; esac
  for f in "$QUEUE"/*.md; do
    tag=""
    if is_operator_lane "$f"; then
      if [ "$only" = "--consumer" ]; then continue; fi
      tag="[operator] "
    else
      if [ "$only" = "--operator" ]; then continue; fi
    fi
    printf '%s  %s%s\n' "$(basename "$f")" "$tag" "$(title_of "$f")"
  done
}

cmd_show() {
  local p="${1:-}" m
  [ -n "$p" ] || die "usage: factory.sh show <id>"
  p="$(pad "$p")"
  for m in "$QUEUE"/*-"$p".md "$CLAIMED"/*/*-"$p".md "$ARCHIVE/$p".md "$ARCHIVE/$p".*.md; do
    [ -e "$m" ] && { echo "=== $m"; cat "$m"; return 0; }
  done
  die "no task with id $1 in queue, claimed, or archive"
}

cmd_claim() {
  local worker="" want_op=0 want_id="" affinity="" top attempt=0 chosen f dest
  local soft_suite soft_direct suite_why direct_why fallback
  local soft_suite_band suite_behind free_band
  local soft_direct_band direct_behind direct_token pick_band
  local head head_band b aff p
  local n_seen n_lane n_dep n_over lane_label
  while [ $# -gt 0 ]; do
    case "$1" in
      --operator) want_op=1 ;;
      --affinity) shift; affinity="$(printf '%s' "${1:-}" | tr ',' ' ')" ;;
      --id) shift; want_id="${1:-}" ;;
      -*) die "unknown claim option '$1'" ;;
      *) worker="$1" ;;
    esac
    shift
  done
  if [ -n "$want_id" ]; then
    [ "$want_op" -eq 1 ] || die "claim --id is operator-only (a seat taking a specific task would subvert the queue order)"
    case "$want_id" in *[!0-9]*) die "claim --id expects a numeric task id" ;; esac
  fi
  if [ -z "$worker" ] && [ "$want_op" -eq 1 ]; then worker="operator"; fi
  # Identity resolution: explicit arg > --operator > FACTORY_WORKER >
  # .factory-worker (the seat pin, searched up from $PWD) > cwd branch. The env
  # var and the pin both exist because backgrounded seat commands and executor
  # subagents run with a drifted cwd - a different worktree, whose branch mints
  # a WRONG worker and the claim then needs a requeue + re-claim bounce. The
  # pin is the durable half: written once at boot, it needs nothing passed.
  local derived
  resolve_pin
  if [ -z "$worker" ]; then worker="${FACTORY_WORKER:-}"; fi
  if [ -z "$worker" ] && [ -n "$PIN_NAME" ]; then worker="$PIN_NAME"; fi
  if [ -z "$worker" ]; then
    worker="$(branch_worker)"
  fi
  [ -n "$worker" ] || die "cannot derive a worker name; pass one: factory.sh claim <worker>"
  # The pin disagreeing with anything is the drift signal it exists to raise.
  if [ -n "$PIN_NAME" ] && [ "$want_op" -eq 0 ] && [ "$PIN_NAME" != "$worker" ]; then
    info "warning: claiming as '$worker' but this worktree is pinned as '$PIN_NAME' ($PIN_PATH)"
  fi
  if [ -n "$PIN_NAME" ] && [ "$PIN_NAME" = "$worker" ]; then
    derived="$(branch_worker)"
    if [ -n "$derived" ] && [ "$derived" != "$PIN_NAME" ]; then
      info "seat pin overrode the cwd branch ('$derived' -> '$PIN_NAME'); cwd: $(pwd -P)"
    fi
  fi
  info "worker: $worker"
  # Orders before work - for EVERY claim shape (a broadcast means every seat,
  # the operator's own tweezers included; FACTORY_FORCE=1 is the way through).
  signal_gate "$worker"
  # The primary checkout is off limits to CONSUMERS (law 5). --operator is the
  # operator's own lane and the primary is exactly where they work.
  if [ -n "$PRIMARY" ] && [ "$want_op" -eq 0 ] && [ "${FACTORY_FORCE:-}" != "1" ]; then
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ "$top" = "$PRIMARY" ] && die "claim refused from the primary checkout - consumers work in worktrees (FACTORY_FORCE=1 overrides)"
  fi
  # The recycle gate (structural step-7, above): a consumer claim refuses
  # while the claiming seat's own replica is over budget or past the age
  # belt. Operator claims are exempt - the primary is the operator's surface.
  if [ "$want_op" -eq 0 ]; then recycle_gate "$worker"; fi
  # The duplicate-session belt (task 1789588684): an extra boot of this
  # seat never claims under the shared identity - it exits.
  if [ "$want_op" -eq 0 ]; then duplicate_session_gate "$(claim_seat_name)"; fi
  mkdir -p "$CLAIMED/$worker"
  # Targeted claim: the operator's tweezers for a SPECIFIC queued task -
  # the safe-edit primitive (claim, edit the file you now own, requeue).
  # Deliberately skips lane/deps/overlap gates: the operator knows.
  if [ -n "$want_id" ]; then
    p="$(pad "$want_id")"
    chosen=""
    for f in "$QUEUE"/*-"$p".md; do chosen="$f"; done
    [ -n "$chosen" ] || die "no QUEUED task with id $want_id (claimed or archived tasks cannot be taken)"
    dest="$CLAIMED/$worker/$(basename "$chosen")"
    mv "$chosen" "$dest" 2>/dev/null || die "task $want_id moved mid-take; re-list and retry"
    log_stamp "$dest" "claimed by $worker at $(now_iso) (targeted)"
    echo "$dest"
    return 0
  fi
  while [ "$attempt" -lt 25 ]; do
    attempt=$((attempt+1))
    soft_suite=""; soft_direct=""; suite_why=""; direct_why=""; fallback=""
    soft_suite_band=""; suite_behind=""; free_band=""
    soft_direct_band=""; direct_behind=""; direct_token=""; pick_band=""
    chosen=""; head=""; head_band=""; aff=0
    n_seen=0; n_lane=0; n_dep=0; n_over=0
    for f in "$QUEUE"/*.md; do
      [ -e "$f" ] || continue
      n_seen=$((n_seen+1))
      # Operator-lane tasks are invisible to a consumer claim, and a plain
      # --operator claim sees ONLY them. Never a soft fallback either way: a
      # forbidden task must not be handed out just because nothing else is
      # free, which is precisely how band-90 parking failed.
      if [ "$want_op" -eq 1 ]; then
        is_operator_lane "$f" || { n_lane=$((n_lane+1)); continue; }
      elif is_operator_lane "$f"; then
        n_lane=$((n_lane+1)); continue
      fi
      deps_met "$f" || { n_dep=$((n_dep+1)); continue; }
      if overlaps "$f"; then
        # One soft slot per overlap GRADE, each the first such task in
        # priority order (task 1792508144): suite-only - the task overlaps
        # only through the suite rule - and direct - it shares a concrete
        # token with another seat's claim. Both count as overlap-deferred.
        # Both slots also remember their BAND and the claim they sit
        # behind: band precedence (after the scan) may make either the
        # claim - the suite slot from any band, the DIRECT slot from an
        # expedited one (task 1792553976). The scan runs in priority order,
        # so the first task recorded per grade IS that grade's highest-band
        # one (with affinity the scan still covers everything above the
        # head band before it breaks).
        if [ "$OVERLAP_KIND" = suite ]; then
          [ -n "$soft_suite" ] || { soft_suite="$f"; suite_why="suite-only (behind $OVERLAP_WITH)"; suite_behind="$OVERLAP_WITH"; soft_suite_band="$(prio_of "$f" | cut -c1-2)"; }
        else
          [ -n "$soft_direct" ] || { soft_direct="$f"; direct_token="$OVERLAP_TOKEN"; direct_behind="$OVERLAP_WITH"; direct_why="DIRECT - shares '$direct_token' with $direct_behind"; soft_direct_band="$(prio_of "$f" | cut -c1-2)"; }
        fi
        n_over=$((n_over+1))
        continue
      fi
      [ -z "$affinity" ] && { chosen="$f"; break; }
      # Affinity: prefer a task whose touches intersect the caller's warm
      # context, but ONLY within the head task's priority band - equal-rank
      # work may be reordered toward relevant context, higher-priority work
      # may never be skipped past.
      b="$(prio_of "$f" | cut -c1-2)"
      if [ -z "$head" ]; then
        head="$f"; head_band="$b"
      elif [ "$b" != "$head_band" ]; then
        break                             # left the head band: no match found
      fi
      if touches_match "$f" "$affinity"; then chosen="$f"; aff=1; break; fi
    done
    [ -n "$chosen" ] || chosen="$head"   # affinity found nothing: plain head
    # BAND PRECEDENCE beats the suite rule's soft defer (task 1792540242). A
    # task whose touches say `suite` overlaps every active claim by its
    # NATURE - the token means "every app", not "a file another seat is
    # editing" - so for it the gate carries no information, and on a busy
    # fleet (eight seats, each holding a claim) the soft slot was consulted
    # only when NOTHING was free: on 2026-10-21 the operator-ruled band-03
    # wave sat at the queue head for hours while every freed seat took
    # band-30 hygiene, the band the prioritizer gave it inverted by the gate.
    # The band is the ruling: a suite-only soft candidate in a STRICTLY
    # higher band (lower-numbered) than the task about to be chosen IS the
    # claim, and the fallback words say why. Equal bands keep today's rule
    # (the free task wins - the defer still protects same-rank work); a
    # DIRECT soft candidate gains precedence only from an EXPEDITED band
    # (the block after the suite-only fallback below, task 1792553976 - from
    # band 10 up a concrete file collision stays the last resort); affinity
    # is untouched - it reorders within the head band, and a suite task
    # outranking that band simply replaces the pick (never stamped as
    # affinity).
    if [ -n "$chosen" ] && [ -n "$soft_suite" ]; then
      free_band="$(prio_of "$chosen" | cut -c1-2)"
      case "$soft_suite_band$free_band" in
        [0-9][0-9][0-9][0-9])
          if [ "$((10#$soft_suite_band))" -lt "$((10#$free_band))" ]; then
            chosen="$soft_suite"; aff=0
            fallback="suite-only (band $soft_suite_band outranks the free band $free_band; behind $suite_behind)"
          fi ;;
      esac
    fi
    # Everything eligible overlaps: fall back in GRADED order - suite-only
    # first (the overlap is a suite-wide claim's blanket, or our own suite
    # token, not a file another seat is editing), a DIRECT collision last and
    # never the plain head. Before task 1792508144 one soft slot held the
    # priority head, and under an active suite-wide claim (hours, for a
    # 21-app wave) that head was whatever came first.
    if [ -z "$chosen" ] && [ -n "$soft_suite" ]; then chosen="$soft_suite"; fallback="$suite_why"; fi
    # EXPEDITED precedence over the DIRECT soft defer (task 1792553976). The
    # DIRECT rule is right for ORDINARY work: two seats on one token is a
    # rebase for the second to land, and the defer avoids it for free. The
    # expedited bands (00-09) exist so the prioritizer / operator can put a
    # task AHEAD of ordinary work - a red gate, a production-facing bug -
    # and there a rebase on a shared driver file is the cheaper cost by
    # far: on 2026-10-21 the band-05 fix for the red story-smoke gate shared
    # scripts/story-smoke with four live band-30 story promotions whose last
    # verify step was that very gate, and sat deferred behind every free
    # task for as long as any of the four lived. The band is the ruling
    # here too: a DIRECT soft candidate in an expedited band STRICTLY
    # higher (lower-numbered) than the band of the pick in hand - the free
    # head, the affinity pick, the suite-precedence pick above, or the
    # suite-only fallback just made when nothing was free - IS the claim,
    # aff=0, and the stamp says why, so a reader sees the collision was
    # taken on purpose (the board still marks the row DIRECT-OVERLAP: the
    # words start as every DIRECT stamp does). Equal bands keep the pick in
    # hand (the defer still protects same-rank work), and the band ORDER
    # rules inside the zone too - band 03 outranks band 05, so a fix that
    # must go ahead of free band-03 work is banded 00-02, never argued past
    # the order; from band 10 up a DIRECT candidate never gains precedence.
    # The clause names the band displaced as "the free band" in the suite
    # stamp's grammar, even when that pick was itself a precedence or
    # suite-only fallback pick.
    if [ -n "$chosen" ] && [ -n "$soft_direct" ]; then
      pick_band="$(prio_of "$chosen" | cut -c1-2)"
      case "$soft_direct_band$pick_band" in
        [0-9][0-9][0-9][0-9])
          if [ "$((10#$soft_direct_band))" -le 9 ] && [ "$((10#$soft_direct_band))" -lt "$((10#$pick_band))" ]; then
            chosen="$soft_direct"; aff=0
            fallback="$direct_why (band $soft_direct_band outranks the free band $pick_band)"
          fi ;;
      esac
    fi
    if [ -z "$chosen" ] && [ -n "$soft_direct" ]; then chosen="$soft_direct"; fallback="$direct_why"; fi
    if [ -z "$chosen" ]; then
      # Itemized EMPTY: a queue full of tasks this claim may not take (dep-
      # gated, other lane) must not read as "queue is empty" in a seat's idle
      # report. First token stays exactly EMPTY - callers string-match on it.
      # (EMPTY is only reached after a FULL scan - every early break sets
      # chosen or head first - so the counts always cover the whole queue.)
      if [ "$n_seen" -eq 0 ]; then
        echo "EMPTY (queue 0)"
      else
        lane_label="operator-lane"
        [ "$want_op" -eq 1 ] && lane_label="consumer-lane"
        echo "EMPTY (queue $n_seen: $n_dep dep-gated, $n_lane $lane_label, $n_over overlap-deferred)"
      fi
      return 0
    fi
    dest="$CLAIMED/$worker/$(basename "$chosen")"
    if mv "$chosen" "$dest" 2>/dev/null; then
      if [ "$aff" -eq 1 ]; then
        log_stamp "$dest" "claimed by $worker at $(now_iso) (affinity)"
      elif [ -n "$fallback" ]; then
        # Say which fallback the claim took - on stderr for the seat's
        # CLAIMED banner, and on the stamp so the board carries it: a seat
        # that knows it collides merges small and early, and a DIRECT stamp
        # is the prioritizer's merge-conflict flag.
        info "overlap fallback: $fallback"
        log_stamp "$dest" "claimed by $worker at $(now_iso) - overlap fallback: $fallback"
      else
        log_stamp "$dest" "claimed by $worker at $(now_iso)"
      fi
      echo "$dest"
      return 0
    fi
  done
  die "claim raced 25 times in a row; try again"
}

cmd_done() {
  local id="${1:-}" status="${2:-}" note="${3:-}" dest
  [ -n "$id" ] && [ -n "$status" ] || die "usage: factory.sh done <id> <done|abandoned|split|superseded> [note]"
  case "$status" in done|abandoned|split|superseded) : ;; *) die "bad status '$status'" ;; esac
  find_claimed "$id"
  warn_owner_mismatch "$FOUND"
  if [ "$status" = "done" ]; then help_gate "$FOUND"; fi
  if [ "$status" = "done" ]; then docfile_gate "$FOUND"; fi   # MULTI/DEX bookkeeping law
  dest="$ARCHIVE/$(pad "$id").md"
  [ -e "$dest" ] && dest="$ARCHIVE/$(pad "$id").$(now_s).md"
  log_stamp "$FOUND" "archived status=$status at $(now_iso)${note:+ - $note}"
  mv "$FOUND" "$dest"
  rmdir "$(dirname "$FOUND")" 2>/dev/null || true   # drop the worker dir when it empties
  echo "$dest"
}

cmd_requeue() {
  local id="${1:-}" band="${2:-}" note="${3:-}" prio target
  [ -n "$id" ] || die "usage: factory.sh requeue <id> [band] [note]"
  case "$band" in
    ''|[0-9]|[0-9][0-9]) : ;;            # empty, or a 1-2 digit band
    *) note="$band"; band="" ;;          # second arg was actually the note
  esac
  find_claimed "$id"
  warn_owner_mismatch "$FOUND"
  if [ -n "$band" ]; then
    prio="$(band_key "$band" "$id")"
  else
    prio="$(prio_of "$FOUND")"
  fi
  target="$QUEUE/$prio-$(pad "$id").md"
  log_stamp "$FOUND" "requeued at $(now_iso)${note:+ - $note}"
  mv "$FOUND" "$target"
  rmdir "$(dirname "$FOUND")" 2>/dev/null || true
  echo "$target"
}

cmd_reprioritize() {
  local id="${1:-}" key="${2:-}" p old="" m prio target
  [ -n "$id" ] && [ -n "$key" ] || die "usage: factory.sh reprioritize <id> <band(2 digits)|key(10 digits)>"
  p="$(pad "$id")"
  for m in "$QUEUE"/*-"$p".md; do old="$m"; done
  [ -n "$old" ] || die "no QUEUED task with id $id (claimed or archived tasks cannot be reprioritized)"
  case "${#key}" in
    1|2) prio="$(band_key "$key" "$p")" ;;
    10)  prio="$(pad "$key")" ;;
    *)   die "key must be a 1-2 digit band or a 10-digit priority key" ;;
  esac
  target="$QUEUE/$prio-$p.md"
  [ "$target" = "$old" ] && { echo "$old"; return 0; }
  mv "$old" "$target" 2>/dev/null || die "task $id moved mid-rename (claimed?); no change made"
  echo "$target"
}

# --- seat handoffs ----------------------------------------------------------
# tasks/handoff/<worktree-basename>.md holds a retiring seat's successor boot
# prompt. It is PLAIN runtime state, not queue state: a seat writes its own
# file directly (the content is a multi-line prompt, not a shell argument) and
# the successor clears it on boot. No atomic-rename semantics are needed - one
# writer, one reader, and a leftover file is a visible "seat still unmanned",
# which is exactly the signal that went missing when chips evaporated.

file_age_line() {  # file_age_line <file> <now-epoch> -> "<basename>\t<age>" (handoffs, signals)
  local f="$1" now="$2" age h m mt
  # A file cleared between the caller's glob and this stat reads as age 0
  # rather than aborting the render (set -e on a failed stat inside $(( )) is
  # the second silent-board abort shape task 1788467120 caught on disk).
  mt="$(stat -f %m "$f" 2>/dev/null || echo "$now")"
  age=$(( (now - mt) / 60 ))
  h=$(( age / 60 )); m=$(( age % 60 ))
  if [ "$h" -gt 0 ]; then printf '%s\t%dh%02dm' "$(basename "$f" .md)" "$h" "$m"
  else printf '%s\t%dm' "$(basename "$f" .md)" "$m"; fi
}

cmd_handoff_list() {
  local f now n=0
  now="$(now_s)"
  for f in "$HANDOFF"/*.md; do
    n=$((n+1))
    printf '%s\n' "$(file_age_line "$f" "$now")"
  done
  [ "$n" -gt 0 ] || echo "NONE"
}

cmd_handoff_clear() {
  local name="${1:-}" f top w
  [ -n "$name" ] || die "usage: factory.sh handoff-clear <worktree-basename>"
  name="$(basename "$name" .md)"
  f="$HANDOFF/$name.md"
  [ -f "$f" ] || die "no pending handoff for '$name' (factory.sh handoff-list)"
  rm -f "$f"
  # The successor's ack spends a spawn-pending stamp too: the boot arrived.
  [ -f "$(spawn_pending_file "$name")" ] && { spawn_pending_clear "$name"; info "spawn-pending stamp for $name cleared (the successor booted)"; }
  echo "cleared $name"
  # A successor inherits the seat, so it inherits the seat's identity: refresh
  # the pin from the branch it is standing on (same branch = same worker, so
  # this is normally a no-op that simply guarantees the file exists). Only when
  # the cleared handoff IS this worktree's - clearing someone else's pending
  # file (or doing it from the primary) must never rewrite anyone's pin.
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$top" ] && [ "$top" != "${PRIMARY:-}" ] && [ "$(basename "$top")" = "$name" ]; then
    w="$(branch_worker)"
    if [ -n "$w" ]; then
      case "$w" in */*|*..*) : ;; *) printf '%s\n' "$w" > "$top/$PIN_FILE"; roster_register "$top" "$w"; seat_keep_sentinel "$top"; info "seat pinned as '$w' ($top/$PIN_FILE)" ;; esac
    fi
  fi
}

# --- successor spawning (CLI seats) -----------------------------------------
# Workers are CLI seats (the 2026-08-19 worker doctrine; successor chips are
# desktop-legacy), so a retiring seat spawns its own successor Terminal
# (claude CLI at ~/.local/bin/claude):
# `spawn-successor <worktree-basename>` reads the
# pending tasks/handoff/<basename>.md - the handoff file is the TOKEN, so
# handoff first, spawn second, and a missing file is a refusal - extracts the
# boot prompt and the worktree path, and opens a new macOS Terminal window
# running the pinned-model claude CLI with that prompt. The handoff file is
# NOT cleared here: the successor's own handoff-clear is the ack, so a spawn
# that dies still leaves the seat visible on handoff-list (recoverable by
# hand). Session names carry the PROJECT PREFIX (task 1787175232) - several
# projects run this factory pattern on one machine, so bare seat names are
# ambiguous in cross-project listings: the spawned session is named
# '<prefix>-executor-<worktree-basename>' (or '<prefix>-worker-<seat>' when
# the boot prompt is not executor-mode). The prefix is DERIVED, never
# hardcoded: FACTORY_PROJECT env if set, else the primary checkout's
# directory basename with any -ng/-main suffix dropped (open-saas-ng ->
# open-saas), so forks inherit correct names for free.
# Zero-residue windows (task 1787177577): the spawned command ends "; exit 0"
# so the window's shell exits cleanly the moment claude exits - even when the
# handoff self-kill ends claude with a signal exit code (137/143) - and the
# operator's "Factory" Terminal settings set (the profile with "When the shell
# exits: Close the window") is applied to the window, so a retired seat's
# window closes itself. No such settings set means the spawn proceeds without
# it and the success banner names the one-time manual setup. Only spawned
# windows get the profile - the operator's own windows keep default behavior.
# TAB TITLE (task 1789581980): the same post-live program also sets the tab's
# CUSTOM title to the session name (<prefix>-executor-<seat>), so a fleet
# window is findable by its seat name again instead of Terminal's default
# title (active process + shell command: "caffeinate <| claude --model ...").
# The title is set whether or not the Factory settings set exists, so a
# retiring seat's dead-prompt window still says which seat it was; the
# Factory profile's Window/Tab title components decide what ELSE Terminal
# appends (operator guide: uncheck active process name / arguments / shell
# command name / dimensions there so the custom title stands alone).
# THE ORDER MATTERS (task 1788301542, the 2026-09-02 fleet cycle): the profile
# is applied ONLY AFTER the post-spawn verify has seen the successor's process
# live - never in the same program as `do script`. Changing a window's
# settings set while its shell is still starting up swallowed the queued boot
# command in 7 of 10 fleet-cycle spawns (typed at the prompt, never run, and
# a manual Return did not recover them), while every bare `do script` boot
# the operator console ran over two days (15+ windows) executed first try.
# So the boot program is now the bare `do script` (no `activate` either - a
# succession must not steal the operator's focus) and the settings set rides
# a SECOND osascript once the process exists.
# SPAWN VERIFICATION (task 1788278149, the 2026-09-01 fleet-reboot postmortem):
# Terminal's `do script` under rapid successive spawns can leave the command
# TYPED at the prompt but NOT EXECUTED (2 of 5 reboot windows sat that way,
# invisible to everything but eyeballs), and repeated respawns just stack more
# un-run windows. So cmd_spawn_successor now brackets the osascript with a
# process check on both sides:
#   - PRE-SPAWN GUARD: refuse when a process already carries the session name
#     (`--name <sname>` in its argv, pgrep -f). Prevents duplicate sessions
#     AND the promptless-imposter class; the caller's OWN session tree is
#     excluded (a retiring seat legitimately carries the same name while it
#     spawns its successor). FACTORY_FORCE=1 overrides.
#   - POST-SPAWN VERIFY: poll for the named process (~10s budget,
#     FACTORY_SPAWN_VERIFY_SECS); if absent, RE-DRIVE THE SAME WINDOW
#     (`do script "" in window id <wid>` re-submits a command pending at the
#     prompt - never a new window, so a retry can never boot two sessions),
#     up to FACTORY_SPAWN_REDRIVES (default 2) times. "spawned" is only
#     reported once the process exists; on final failure the error names the
#     window id (press Return there) and the manual boot line.
# SPAWN PENDING (task 1789588684, the 2026-09-16 respawn storm): a `do
# script` whose AppleEvent REPLY times out (-1712, "AppleEvent timed out")
# has NOT failed - Terminal queues the event and may execute it hours later
# (15 timed-out doctor passes booted NINE sessions onto one seat at once
# when Terminal unwedged). So a timeout is a third outcome, neither spawned
# nor failed:
#   - the spawn writes tasks/factory/spawn-pending/<seat> (instant + session
#     name), polls the verify budget once (the event may run right away),
#     and otherwise prints `spawn PENDING (AppleEvent timed out - Terminal
#     may still run it)` and exits 3 - never the "boot by hand" text, which
#     invites a second boot;
#   - the PRE-SPAWN GUARD refuses while the stamp is younger than
#     FACTORY_SPAWN_PENDING_TTL (default 6h - the observed queue held its
#     events for 4h; plain seconds or Nh/Nm/Ns) unless the seat's named
#     process exists (the stamp is cleared and the normal duplicate refusal
#     applies) or FACTORY_FORCE=1; fleet-doctor reports the seat as
#     UNMANNED (spawn pending since ...) and does not respawn it;
#   - the belt at the SEAT: worker-pin and claim refuse DUPLICATE-SESSION
#     when another live process carries this session's name and is OLDER
#     (duplicate_session_gate below) - the extra boot exits instead of
#     claiming under a shared identity.
# FACTORY_OSASCRIPT_BIN overrides the osascript binary (the selftest's fake
# prints the -1712 line and exits 1).
#
# FACTORY_SPAWN_DRYRUN=1 prints the session name and both osascript programs
# (the boot program and the post-live profile + tab-title program) instead of running
# them (selftest + eyeballing; the pre-spawn guard still applies - a dry run
# against a live duplicate refuses like the real thing);
# FACTORY_CLAUDE_BIN / FACTORY_CLAUDE_MODEL override the binary and model for
# testing - the fleet default stays pinned.

sq() {  # single-quote $1 for a /bin/bash command line
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

aq() {  # escape $1 for an AppleScript double-quoted string literal
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

project_prefix() {  # CLI session-name prefix: FACTORY_PROJECT if set, else the
  # primary checkout's directory basename with any -ng/-main suffix dropped.
  local p base
  if [ -n "${FACTORY_PROJECT:-}" ]; then printf '%s' "$FACTORY_PROJECT"; return 0; fi
  p="${PRIMARY:-}"
  if [ -z "$p" ]; then p="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || true)"; fi
  if [ -z "$p" ]; then p="$(cd "$TASKS/.." 2>/dev/null && pwd || true)"; fi  # FACTORY_TASKS_ROOT mode, outside any repo
  base="$(basename "$p")"
  base="${base%-ng}"
  base="${base%-main}"
  printf '%s' "$base"
}

# --- the seat boot environment (2026-09-24) ---------------------------------
# ONE source for every factory session boot: spawn-successor's and
# prioritizer-boot's shell lines (both through boot-exec, below) and the
# hand-boot recipe for a producer or the console (`$(scripts/factory.sh
# boot-env) claude ...`, SKILL.md Operator guide). Two halves.
#  SCRUB: a Terminal window inherits the environment of the process that
#  LAUNCHED Terminal.app. On 2026-09-07 that was a desktop session's osascript
#  (the OperatorTasks console), so every window opened since - both projects'
#  fleets, 13 seats - carried that session's markers: CLAUDE_CODE_CHILD_SESSION=1
#  (transcript saving OFF - no seat could be audited or resumed; the CLI footer
#  says so), its session id and messaging socket, DISABLE_MICROCOMPACT=1 (tool
#  results never trimmed: contexts grew to the window), the desktop's SDK and
#  auth-refresh switches. None of it is a standalone CLI seat's; `env -u`
#  clears each one whatever the window carries.
#  SET: the background-reap opt-out (task 1788458457), transcript persistence,
#  a ONE-HOUR Bash cap so the idle watch sleeps an hour (`watch 3300`) instead
#  of polling every 500 s - every poll is a full-context model turn, and at
#  500 s the idle fleet made ~50 no-op API calls an hour from 09-07 to 09-24 -
#  a 10-min DEFAULT so a watch called without a timeout degrades to the old
#  cadence and never to a 2-min loop, max effort (the fleet standard the
#  desktop sessions run at) as CLAUDE_CODE_EFFORT_LEVEL=max - the INPUT the
#  CLI applies ("apply_flag_settings: CLAUDE_CODE_EFFORT_LEVEL overrides effort
#  for this session"); the CLAUDE_EFFORT=max set here until 2026-10-03 was the
#  CLI's OUTPUT (what it reports to hooks and Bash), never read, so booted seats
#  ran at the user's settings level (a reviewer's note on open-saas PR #17, checked against
#  the 2.1.257 binary) - and no self-update mid-seat (a seat picks up a CLI
#  update at its next spawn).
BOOT_ENV_SCRUB="CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_HOST_SESSION_ID CLAUDE_PID CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_ENTRYPOINT CLAUDECODE CLAUDE_CODE_EAGER_FLUSH CLAUDE_CODE_EMIT_TOOL_USE_SUMMARIES CLAUDE_CODE_REPORT_FINDINGS CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH CLAUDE_AGENT_SDK_VERSION CLAUDE_CODE_OAUTH_SCOPES CLAUDE_CODE_DISABLE_TERMINAL_TITLE CLAUDE_CODE_ENABLE_ASK_USER_QUESTION_TOOL CLAUDE_CODE_DISABLE_CRON CLAUDE_PREVIEW_CLASSIFIER_FLOOR DISABLE_MICROCOMPACT"
BOOT_ENV_SET="CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1 CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 BASH_MAX_TIMEOUT_MS=3600000 BASH_DEFAULT_TIMEOUT_MS=600000 CLAUDE_CODE_EFFORT_LEVEL=max DISABLE_AUTOUPDATER=1"
boot_env_prefix() {  # the `env -u ... K=V ...` word list a boot line puts before the claude command
  local v out="env"
  for v in $BOOT_ENV_SCRUB; do out="$out -u $v"; done
  printf '%s %s' "$out" "$BOOT_ENV_SET"
}
cmd_boot_env() { printf '%s\n' "$(boot_env_prefix)"; }

handoff_prompt() {  # $1 = handoff file: its boot prompt, flattened to one line
  # Everything after the "## Boot prompt" marker (the convention since
  # spawn-successor exists); legacy files carry the prompt after the cd-boot
  # line instead. Markdown fences are noise either way. One line because the
  # prompt is ONE claude argument (prompts are prose; collapsed whitespace
  # reads the same).
  local prompt
  prompt="$(awk '/^## Boot prompt/{found=1; next} found' "$1" | sed '/^```/d')"
  if [ -z "$(printf '%s' "$prompt" | tr -d '[:space:]')" ]; then
    prompt="$(awk 'found && $0 !~ /^```/ {print} /^cd .* && claude/{found=1}' "$1")"
  fi
  printf '%s' "$prompt" | tr '\n' ' ' | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//'
}

boot_exec_die() {  # the window closes on exit (the '; exit 0' suffix + the Factory profile): hold the error where it can be read
  # FACTORY_BOOT_EXEC_HOLD_S overrides the 10-min hold (the selftest sets 0).
  echo "factory: boot-exec: $*" >&2
  echo "factory: boot-exec: this window holds the error for 10 min, then closes" >&2
  sleep "${FACTORY_BOOT_EXEC_HOLD_S:-600}"
  exit 1
}

cmd_boot_exec() {  # boot-exec <seat|prioritizer> --model <m> --name <n>: the boot line target of spawn-successor and prioritizer-boot
  # Runs INSIDE the new Terminal window: applies the boot environment (the
  # scrub + the sets above), reads the boot prompt from the token
  # tasks/handoff/<seat>.md (a seat's handoff file; prioritizer-boot writes
  # tasks/handoff/prioritizer.md) and execs claude - so the TYPED line
  # carries neither (the tty splits typed input at 1024 bytes while a new
  # window's shell starts up).
  local seat="${1:-}" model="" sname="" f prompt cbin v kv again
  [ -n "$seat" ] || boot_exec_die "usage: factory.sh boot-exec <seat|prioritizer> --model <model> --name <session-name>"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --model) shift; model="${1:-}" ;;
      --name)  shift; sname="${1:-}" ;;
      *) boot_exec_die "unknown argument '$1'" ;;
    esac
    shift
  done
  [ -n "$model" ] && [ -n "$sname" ] || boot_exec_die "--model and --name are required"
  f="$HANDOFF/$seat.md"
  if [ "$seat" = prioritizer ]; then again="factory.sh prioritizer-boot (it rewrites the token)"; else again="factory.sh spawn-successor $seat"; fi
  [ -f "$f" ] || boot_exec_die "no handoff file $f - the boot prompt lives there until the booted session's handoff-clear; write it and spawn again ($again)"
  prompt="$(handoff_prompt "$f")"
  [ -n "$(printf '%s' "$prompt" | tr -d '[:space:]')" ] || boot_exec_die "no boot prompt in $f (add a '## Boot prompt' section)"
  cbin="${FACTORY_CLAUDE_BIN:-$HOME/.local/bin/claude}"
  [ -x "$cbin" ] || boot_exec_die "claude CLI not executable at $cbin (FACTORY_CLAUDE_BIN overrides)"
  for v in $BOOT_ENV_SCRUB; do unset "$v"; done
  for kv in $BOOT_ENV_SET; do export "$kv"; done
  exec "$cbin" --model "$model" --name "$sname" "$prompt"
}

spawn_live_pids() {  # $1 = session name; prints pids whose argv carries
  # "--name $1" (word-bounded), EXCLUDING the caller's own session tree - the
  # retiring seat's claude process carries the very name it is spawning, and
  # so may workers that process forked, so both the caller's ancestor chain
  # and any matched ancestor's descendants are carved out. Other seats (also
  # descendants of Terminal/launchd, but never of a MATCHED ancestor) remain
  # visible. Fail-open: no pgrep / no ps output = no pids printed.
  local sname="$1" pat pids self_anc matched_anc a p q skip
  pat="[-]-name $(printf '%s' "$sname" | sed 's/[][\\.*^$()+?{}|]/\\&/g')( |$)"
  pids="$(pgrep -f "$pat" 2>/dev/null | tr '\n' ' ' || true)"
  [ -n "${pids% }" ] || return 0
  self_anc=""; a=$$
  while [ "${a:-0}" -gt 1 ] 2>/dev/null; do
    self_anc="$self_anc $a "
    a="$(ps -o ppid= -p "$a" 2>/dev/null | tr -d ' ' || true)"
    [ -n "$a" ] || break
  done
  matched_anc=""
  for a in $self_anc; do
    case " $pids" in *" $a "*) matched_anc="$matched_anc $a " ;; esac
  done
  for p in $pids; do
    case "$self_anc" in *" $p "*) continue ;; esac
    if [ -n "$matched_anc" ]; then
      skip=""; q="$p"
      while [ "${q:-0}" -gt 1 ] 2>/dev/null; do
        q="$(ps -o ppid= -p "$q" 2>/dev/null | tr -d ' ' || true)"
        [ -n "$q" ] || break
        case "$matched_anc" in *" $q "*) skip=1; break ;; esac
      done
      [ -n "$skip" ] && continue
    fi
    printf '%s\n' "$p"
  done
  return 0
}

# --- spawn-pending stamps + the duplicate-session gate (task 1789588684) ---

spawn_pending_ttl_s() {  # FACTORY_SPAWN_PENDING_TTL as seconds: N | Nh | Nm | Ns (default 6h)
  local v="${FACTORY_SPAWN_PENDING_TTL:-6h}" n
  case "$v" in
    *h) n="${v%h}"; case "$n" in ''|*[!0-9]*) n=6 ;; esac; printf '%s' "$((10#$n * 3600))" ;;
    *m) n="${v%m}"; case "$n" in ''|*[!0-9]*) n=360 ;; esac; printf '%s' "$((10#$n * 60))" ;;
    *s) n="${v%s}"; case "$n" in ''|*[!0-9]*) n=21600 ;; esac; printf '%s' "$((10#$n))" ;;
    *)  case "$v" in ''|*[!0-9]*) printf '%s' 21600 ;; *) printf '%s' "$((10#$v))" ;; esac ;;
  esac
}

spawn_pending_file() { printf '%s/%s' "$SPAWN_PENDING" "$1"; }   # $1 = seat

spawn_pending_since() {  # $1 = seat: prints the stamp's instant when a stamp
  # exists and is younger than the TTL; prints nothing when absent or
  # expired (an expired stamp is inert - the next spawn overwrites it).
  # Read-only: fleet-doctor --dry-run calls it too.
  local f iso ep
  f="$(spawn_pending_file "$1")"
  [ -f "$f" ] || return 0
  iso="$(sed -n 's/^since: //p' "$f" | head -1 || true)"
  ep="$(sed -n 's/^epoch: //p' "$f" | head -1 || true)"
  case "$ep" in ''|*[!0-9]*) return 0 ;; esac
  [ $(( $(now_s) - ep )) -lt "$(spawn_pending_ttl_s)" ] || return 0
  printf '%s' "${iso:-?}"
}

spawn_pending_write() {  # $1 = seat, $2 = session name
  printf 'since: %s\nepoch: %s\nsession: %s\n' "$(now_iso)" "$(now_s)" "$2" > "$(spawn_pending_file "$1")"
}

spawn_pending_clear() { rm -f "$(spawn_pending_file "$1")"; }   # $1 = seat

proc_age_s() {  # $1 = pid: seconds since the process started (ps etime), 0 when unknown
  local e d=0 h=0 m=0 s=0
  e="$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ' || true)"
  [ -n "$e" ] || { printf 0; return 0; }
  case "$e" in *-*) d="${e%%-*}"; e="${e#*-}" ;; esac
  set -- $(printf '%s' "$e" | tr ':' ' ')
  case $# in
    3) h="$1"; m="$2"; s="$3" ;;
    2) m="$1"; s="$2" ;;
    *) s="${1:-0}" ;;
  esac
  case "$d$h$m$s" in *[!0-9]*) printf 0; return 0 ;; esac
  printf '%s' $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

self_session_name() {  # the --name of the claude process this shell runs under, if any
  # Only a claude ancestor counts (the mirror hazard name_pids names: a
  # harness `bash -c` whose command text merely mentions --name is our own
  # plumbing, never a session).
  local a args
  for a in $(self_ancestors); do
    case "$(ps -o comm= -p "$a" 2>/dev/null || true)" in *claude*) : ;; *) continue ;; esac
    args="$(ps -o args= -p "$a" 2>/dev/null || true)"
    case "$args" in
      *" --name "*)
        # The FIRST --name word: claude's flags precede the boot prompt,
        # whose prose may mention the flag.
        printf '%s\n' "$args" | awk '{ for (i = 1; i < NF; i++) if ($i == "--name") { print $(i + 1); exit } }' || true
        return 0 ;;
    esac
  done
  return 0
}

claim_seat_name() {  # the seat a claim runs in: the pin's worktree, else the git toplevel (empty = fail-open)
  local top
  if [ -n "${PIN_PATH:-}" ]; then basename "$(dirname "$PIN_PATH")"; return 0; fi
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] && basename "$top"
  return 0
}

duplicate_session_gate() {  # $1 = seat (worktree basename) - the belt at
  # the seat against the respawn storm: refuse (DUPLICATE-SESSION) when
  # ANOTHER live process carries this session's name and is OLDER than the
  # caller's own session. The name is the caller's own --name when its shell
  # runs under a named claude process, else the seat's executor/worker name
  # under the project prefix (a hand-run pin). spawn_live_pids already carves
  # the caller's own tree out; the age rule keeps the FIRST boot and makes
  # every later one exit - a retiring predecessor (older, mid-exit after its
  # own spawn returned) is re-checked after FACTORY_DUP_GRACE_S (default 5s)
  # so a seat in normal succession never trips it. Fail-open when nothing
  # resolves; FACTORY_FORCE=1 overrides. Read-only attribution: never kills.
  local seat="$1" sname own_age oldest oldest_age p age grace others prefix
  [ "${FACTORY_FORCE:-}" = "1" ] && return 0
  # FACTORY_SESSION_NAME pins the caller's name (the selftest's seam: a
  # test run INSIDE a named seat would otherwise gate on that seat's name).
  sname="${FACTORY_SESSION_NAME:-$(self_session_name)}"
  own_age=0
  if [ -n "$sname" ]; then
    for p in $(self_ancestors); do
      case "$(ps -o comm= -p "$p" 2>/dev/null || true)" in *claude*) : ;; *) continue ;; esac
      case "$(ps -o args= -p "$p" 2>/dev/null || true)" in *" --name $sname "*|*" --name $sname") own_age="$(proc_age_s "$p")"; break ;; esac
    done
  else
    [ -n "$seat" ] || return 0
    prefix="$(project_prefix)"
    sname="$prefix-executor-$seat"
    [ -n "$(spawn_live_pids "$sname")" ] || sname="$prefix-worker-$seat"
  fi
  grace="${FACTORY_DUP_GRACE_S:-5}"
  case "$grace" in ''|*[!0-9]*) grace=5 ;; esac
  while :; do
    oldest=""; oldest_age=-1
    others="$(spawn_live_pids "$sname" | tr '\n' ' ')"
    for p in $others; do
      age="$(proc_age_s "$p")"
      [ "$age" -gt "$own_age" ] || continue
      if [ "$age" -gt "$oldest_age" ]; then oldest="$p"; oldest_age="$age"; fi
    done
    [ -n "$oldest" ] || return 0
    [ "$grace" -gt 0 ] || break
    sleep "$grace"; grace=0
  done
  die "DUPLICATE-SESSION: $oldest already runs this seat - exit now (a live process carrying --name $sname started ${oldest_age}s ago, this session ${own_age}s ago: this is the EXTRA boot of a spawn that timed out and ran later; never claim, never edit - exit the claude process; FACTORY_FORCE=1 overrides)"
}

spawn_profile_program() {  # $1 = Terminal window id, $2 = session name. The
  # post-live cosmetic step (task 1788301542): apply the operator's "Factory"
  # settings set (the profile with "When the shell exits: Close the window")
  # so the retired seat's window closes itself, THEN set the tab's custom
  # title to the session name (task 1789581980) so the window is findable by
  # seat name - title after profile, so the settings-set switch can never
  # clobber it, and set regardless of the profile's existence, so a
  # dead-prompt window is still identifiable. Runs ONLY once the successor's
  # process is verified live - never while the window's shell starts up,
  # which is what swallowed the boot command. Returns
  # "profile: Factory|none|failed title: set|failed" (none = no such settings
  # set, the one-time manual setup; failed = window gone / automation
  # refused).
  printf 'tell application "Terminal"
  set profWord to "none"
  if (exists settings set "Factory") then
    try
      set current settings of selected tab of window id %s to settings set "Factory"
      set profWord to "Factory"
    on error
      set profWord to "failed"
    end try
  end if
  set titleWord to "failed"
  try
    set custom title of selected tab of window id %s to "%s"
    set titleWord to "set"
  end try
  return "profile: " & profWord & " title: " & titleWord
end tell' "$1" "$1" "$(aq "$2")"
}

# --- the shared Terminal-boot pieces (spawn-successor + prioritizer-boot) --
# Two sessions boot through osascript: a SEAT's successor (spawn-successor,
# keyed on its worktree + handoff token) and, since task 1792506027, the
# PRIORITIZER (prioritizer-boot, keyed on the primary + its own token
# tasks/handoff/prioritizer.md). Everything that is not the key is shared
# here - the guards, the pending stamp, the boot program, the verify +
# re-drive, the post-live profile + title, the banner and the exit codes -
# so the two boots behave identically and a fix lands once.

spawn_guards() {  # $1 = stamp key (a seat's worktree basename, or "prioritizer"), $2 = session name
  # The two guards every Terminal boot runs BEFORE anything else - the dry
  # run included: a dry run against a live duplicate refuses like the real
  # thing. FACTORY_FORCE=1 overrides both.
  # PRE-SPAWN GUARD (task 1788278149): a live process already carrying this
  # session name means the session is ALREADY manned - spawning again would
  # boot a duplicate (the 2026-09-01 reboot also minted a promptless imposter
  # this way). The caller's own session tree is excluded by spawn_live_pids,
  # so a retiring seat spawning its like-named successor passes.
  # SPAWN-PENDING GUARD (task 1789588684): an earlier boot's AppleEvent timed
  # out and Terminal may still run it - a second `do script` would boot a
  # second session. Refuse until the stamp expires or the process appears.
  local key="$1" sname="$2" live pend
  live="$(spawn_live_pids "$sname" | tr '\n' ' ')"; live="${live% }"
  if [ -n "$live" ]; then
    # The session is manned - a pending boot, if any, has arrived: the stamp
    # is spent, and the normal duplicate refusal applies.
    [ -f "$(spawn_pending_file "$key")" ] && { spawn_pending_clear "$key"; info "spawn-pending stamp for $key cleared - '$sname' is live (pid $live)"; }
    [ -z "${FACTORY_FORCE:-}" ] && die "a session named '$sname' is already live (pid $live) - refusing to boot a duplicate; if that process is a stray, kill it (or FACTORY_FORCE=1 to override)"
  fi
  pend="$(spawn_pending_since "$key")"
  if [ -n "$pend" ] && [ -z "${FACTORY_FORCE:-}" ]; then
    die "spawn PENDING for $key since $pend ('$sname': an earlier boot's AppleEvent timed out and Terminal may still run it) - no second boot until $(spawn_pending_file "$key") expires (FACTORY_SPAWN_PENDING_TTL, default 6h) or the process appears; check Terminal: a modal, a hung tab, or Automation permission (FACTORY_FORCE=1 overrides)"
  fi
  return 0
}

spawn_boot_program() {  # $1 = the shell command the new window runs; prints the boot AppleScript
  # The boot program is the BARE `do script` - the shape the operator console
  # booted 15+ windows with, first try every time (task 1788301542) - plus a
  # read of the new window's id, which the post-spawn verify re-drives when
  # the command was typed but never run. NOTHING else touches the window
  # while its shell starts up: applying the settings set in this program
  # (the pre-1788301542 shape) left 7 of 10 fleet-cycle boots sitting
  # un-executed at the prompt. No `activate` either: `do script` launches
  # Terminal when needed, and a succession must not steal the operator's
  # focus. The program returns "wid:<window id>" (-1 when unresolvable).
  printf 'tell application "Terminal"
  set newTab to do script "%s"
  set wid to -1
  try
    set wid to id of (first window whose selected tab is newTab)
  on error
    try
      set wid to id of front window
    end try
  end try
  return "wid:" & wid
end tell' "$(aq "$1")"
}

spawn_dryrun_print() {  # $1 = session name, $2 = token file, $3 = boot prompt, $4 = shell command
  # FACTORY_SPAWN_DRYRUN=1: the name, where boot-exec reads the prompt + the
  # prompt, the typed boot line with its byte count (the prompt and the
  # environment must NOT be on it), the boot program and the post-live
  # program - printed instead of run (selftest + eyeballing).
  printf 'DRYRUN session name: %s\n' "$1"
  printf 'DRYRUN boot prompt (boot-exec reads it from %s inside the new window): %s\n' "$2" "$3"
  printf 'DRYRUN boot line (%s bytes, limit 1000): %s\n' "${#4}" "$4"
  printf 'DRYRUN osascript program:\n%s\n' "$(spawn_boot_program "$4")"
  printf 'DRYRUN post-live profile program (profile + tab title; runs only once the process is live):\n%s\n' "$(spawn_profile_program '<wid>' "$1")"
}

spawn_terminal_session() {  # $1 = stamp key, $2 = session name, $3 = shell command, $4 = banner subject, $5 = pending-report tail
  # The LIVE half every Terminal boot shares: run the boot program, turn an
  # AppleEvent timeout into SPAWN PENDING (stamp keyed $1), verify the named
  # process (re-driving the SAME window), then the post-live profile + tab
  # title, then the banner "spawned <subject> - session '<name>' live (pid N,
  # window id W, profile: ..., title: ...)". Returns 0 (live) or 3 (PENDING:
  # stamp written, no process yet - never the hand-boot line, which invites
  # a second boot); dies on a hard failure naming the window id and the
  # hand-boot line.
  local key="$1" sname="$2" shcmd="$3" subject="$4" tail="$5"
  local cbin osa script res wid verify_secs redrives attempt i lp pending prof ttl
  cbin="${FACTORY_CLAUDE_BIN:-$HOME/.local/bin/claude}"
  osa="${FACTORY_OSASCRIPT_BIN:-osascript}"
  [ -x "$cbin" ] || die "claude CLI not found at $cbin (FACTORY_CLAUDE_BIN overrides) - boot by hand: $shcmd"
  command -v "$osa" >/dev/null 2>&1 || die "osascript unavailable (not macOS / no Terminal automation) - boot by hand: $shcmd"
  script="$(spawn_boot_program "$shcmd")"
  verify_secs="${FACTORY_SPAWN_VERIFY_SECS:-10}"
  pending=0
  if ! res="$("$osa" -e "$script" 2>&1)"; then
    case "$res" in
      *-1712*|*"timed out"*|*"Timed out"*)
        # SPAWN PENDING: the reply timed out, the event may still execute -
        # stamp the key, poll the verify budget once (Terminal may run it
        # right away), and never print the hand-boot line.
        spawn_pending_write "$key" "$sname"
        pending=1
        info "Terminal AppleEvent timed out on the boot of '$sname' ($(printf '%s' "$res" | tr '\n' ' ')) - spawn PENDING: stamp $(spawn_pending_file "$key") written; polling ${verify_secs}s in case Terminal runs it now"
        ;;
      *) die "Terminal automation failed ($(printf '%s' "$res" | tr '\n' ' '); check System Settings > Privacy > Automation) - boot by hand: $shcmd" ;;
    esac
  fi
  wid="$(printf '%s' "$res" | sed -n 's/.*wid:\(-\{0,1\}[0-9][0-9]*\).*/\1/p')"
  [ -n "$wid" ] || wid=-1
  # POST-SPAWN VERIFY (task 1788278149): `do script` under rapid successive
  # spawns can leave the command TYPED at the prompt but NOT EXECUTED. Only
  # report "spawned" once the named process actually exists; if it does not
  # appear within the budget, re-drive the SAME window (`do script "" in
  # window id` re-submits the pending command - never a new window, so a
  # retry can never boot two sessions for one key), then check again.
  redrives="${FACTORY_SPAWN_REDRIVES:-2}"
  attempt=0; lp=""
  while :; do
    i=0
    while [ "$i" -lt "$verify_secs" ]; do
      lp="$(spawn_live_pids "$sname" | head -1 || true)"
      [ -n "$lp" ] && break
      sleep 1
      i=$((i+1))
    done
    [ -n "$lp" ] && break
    attempt=$((attempt+1))
    if [ "$attempt" -gt "$redrives" ] || [ "$wid" -lt 0 ]; then break; fi
    info "no '$sname' process after ${verify_secs}s - re-driving Terminal window id $wid ($attempt/$redrives: an empty 'do script' re-submits a command left pending at the prompt)"
    "$osa" -e "tell application \"Terminal\" to do script \"\" in window id $wid" >/dev/null 2>&1 \
      || info "re-drive of window id $wid failed (window closed?)"
  done
  if [ -z "$lp" ] && [ "$pending" = 1 ]; then
    echo "spawn PENDING (AppleEvent timed out - Terminal may still run it) for $key: no '$sname' process yet; stamp $(spawn_pending_file "$key") holds every respawn for FACTORY_SPAWN_PENDING_TTL (default 6h) or until the process appears - check Terminal: a modal, a hung tab, or Automation permission; never a hand boot while the stamp stands${tail:+ ($tail)}"
    return 3
  fi
  [ -n "$lp" ] || die "Terminal window opened (window id $wid) but no '$sname' process appeared - the command may be sitting UN-EXECUTED at the prompt: press Return in Terminal window id $wid, or boot by hand: $shcmd"
  if [ "$pending" = 1 ]; then
    spawn_pending_clear "$key"
    info "the timed-out AppleEvent ran after all - '$sname' is live (pid $lp); stamp cleared (window id unknown: no profile or tab title applied)"
    echo "spawned $subject - session '$sname' live (pid $lp, after a timed-out AppleEvent; window id unknown, profile: skipped, title: skipped)"
    return 0
  fi
  # PROFILE + TAB TITLE, post-live (tasks 1788301542 / 1789581980): the
  # process exists, so the boot command has run and nothing queued at the
  # prompt can be swallowed any more - only now apply the "Factory" settings
  # set and title the tab with the session name. Cosmetic: a failure here
  # never fails the spawn.
  prof="failed"; ttl="failed"
  if [ "$wid" -ge 0 ]; then
    res="$("$osa" -e "$(spawn_profile_program "$wid" "$sname")" 2>/dev/null || true)"
    prof="$(printf '%s' "$res" | sed -n 's/.*profile: *\([A-Za-z]*\).*/\1/p')"
    ttl="$(printf '%s' "$res" | sed -n 's/.*title: *\([A-Za-z]*\).*/\1/p')"
    [ -n "$prof" ] || prof="failed"
    [ -n "$ttl" ] || ttl="failed"
  fi
  case "$prof" in
    Factory) ;;
    none)
      info "no 'Factory' Terminal settings set - the window will sit at a dead prompt after the session exits."
      info "one-time setup: Terminal > Settings > Profiles > duplicate a profile, name it Factory, set 'When the shell exits' to 'Close the window'."
      ;;
    *)
      info "could not apply the 'Factory' settings set to Terminal window id $wid ($prof) - the window will sit at a dead prompt after the session exits."
      ;;
  esac
  [ "$ttl" = "set" ] || info "could not set the tab title of Terminal window id $wid to '$sname' ($ttl) - the window keeps Terminal's default title; find it by its command line."
  echo "spawned $subject - session '$sname' live (pid $lp, window id $wid, profile: $prof, title: $ttl)"
}

cmd_spawn_successor() {
  local name="${1:-}" f wt prompt cmodel shcmd prefix sname self
  [ -n "$name" ] || die "usage: factory.sh spawn-successor <worktree-basename>"
  name="$(basename "$name" .md)"
  f="$HANDOFF/$name.md"
  [ -f "$f" ] || die "no pending handoff for '$name' - write tasks/handoff/$name.md first (handoff, then spawn; factory.sh handoff-list)"
  # Worktree path: the "cd <path> && claude" boot line the handoff convention
  # carries; fall back to matching the basename against git worktree list.
  wt="$(unshq "$(sed -n 's/^cd \(.*\) && claude.*$/\1/p' "$f" | head -1 || true)")"
  if [ -z "$wt" ]; then
    wt="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | grep "/$name\$" | head -1 || true)"
  fi
  [ -n "$wt" ] || die "cannot resolve the worktree path for '$name' (no 'cd <path> && claude' line in $f and no matching worktree)"
  [ -d "$wt" ] || die "worktree '$wt' does not exist"
  # Boot prompt (handoff_prompt: the "## Boot prompt" section, legacy files
  # the text after the cd-boot line). Resolved here for the session-name rule
  # and the dry run; the LIVE boot reads it again from the same file inside
  # the new window (boot-exec) - the typed line carries neither the prompt
  # nor the environment.
  prompt="$(handoff_prompt "$f")"
  [ -n "$(printf '%s' "$prompt" | tr -d '[:space:]')" ] || die "no boot prompt found in $f (add a '## Boot prompt' section)"
  cmodel="${FACTORY_CLAUDE_MODEL:-$FACTORY_CLAUDE_MODEL_DEFAULT}"   # the fleet rule: consumer seats run Fable 5.1
  # Project-prefixed session name (task 1787175232): executor boots (the
  # standard worker mode - the boot prompt says "executor") get
  # <prefix>-executor-<seat>; anything else gets <prefix>-worker-<seat>.
  prefix="$(project_prefix)"
  case "$prompt" in
    *[Ee]xecutor*) sname="$prefix-executor-$name" ;;
    *)             sname="$prefix-worker-$name" ;;
  esac
  # The pre-spawn duplicate guard + the spawn-pending guard (shared above).
  spawn_guards "$name" "$sname"
  # "; exit 0" ends the window's shell cleanly the moment claude exits, even
  # when the handoff self-kill ends claude by signal (137/143) - paired with
  # the "Factory" settings set applied ONCE THE PROCESS IS LIVE (below), the
  # retired seat's window closes itself.
  # CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1 (task 1788458457): the
  # harness reaps a backgrounded shell task (the seat's watch / executor-watch)
  # on every macOS memory-pressure notification once the session has had no
  # user interaction for 30 min and is not mid-turn - the fleet-wide "[killed]"
  # sweep on a 30-min grid (xnu re-sends the WARN notification on a 30-min
  # resting timer) that parked every seat on 2026-09-03. Unattended seats are
  # ALWAYS 30 min past their last interaction, so the opt-out is part of the
  # boot; hand-boots carry it too (SKILL.md, executor mode). Since 2026-09-24
  # it is one word of the whole boot ENVIRONMENT (boot_env_prefix, with the
  # spawn helpers): the desktop-marker scrub, transcript persistence, the
  # one-hour Bash cap behind the hourly idle watch. The typed line does NOT
  # spell it out: `do script` types the line while the new window's shell is
  # still starting, before its line editor takes raw mode, and the tty splits
  # typed input at MAX_CANON (1024 bytes) there - the first such line, 1545
  # bytes with the environment inline, landed its tail at the next prompt as
  # garbage (seat-9, 2026-09-24). So the line calls THIS script's boot-exec,
  # which applies the environment and reads the prompt from the handoff file
  # inside the window, and stays a few hundred bytes whatever the prompt.
  self="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)/$(basename "$0")"
  shcmd="cd $(sq "$wt") && $(sq "$self") boot-exec $(sq "$name") --model $(sq "$cmodel") --name $(sq "$sname"); exit 0"
  [ "${#shcmd}" -le 1000 ] || die "boot line is ${#shcmd} bytes (limit 1000: the tty splits typed input at 1024 bytes while the window's shell starts) - shorten the seat name or the worktree path"
  if [ -n "${FACTORY_SPAWN_DRYRUN:-}" ]; then
    spawn_dryrun_print "$sname" "$f" "$prompt" "$shcmd"
    return 0
  fi
  spawn_terminal_session "$name" "$sname" "$shcmd" "successor Terminal for $name ($wt)" "a retiring seat exits all the same: the handoff file is the token"
}

# --- prioritizer-boot: the TaskPrioritizer through the spawn path ---------
# (task 1792506027, operator decision 2026-10-20) The prioritizer was the ONE
# fleet session the doctor could not boot: spawn-successor is keyed on a seat
# WORKTREE plus its handoff token, and the prioritizer has neither - it runs
# in the PRIMARY with no token - so every fleet revive (the 2026-09-07
# reboot, the 09-24 boot-environment restart, the 10-20 login-expiry
# recovery) kept one hand step, and the operator kept a private boot script
# whose prompt drifted. `prioritizer-boot` is spawn-successor's shape with
# the primary as the "worktree" and tasks/handoff/prioritizer.md as the
# token, WRITTEN HERE just before the spawn (a seat's token is written by the
# retiring seat or the doctor): session name <prefix>-prioritizer (what
# name_pids and the doctor look for), the same pre-spawn guard by name
# (FACTORY_FORCE=1 overrides), the same spawn-pending stamp keyed
# "prioritizer", the same bare `do script` + verify + re-drive, the same
# post-live profile + title, the same banner and exit codes (3 = PENDING).
# The typed line is
#   cd <primary> && <self> boot-exec prioritizer --model <m> --name <sname>; exit 0
# - neither the prompt nor the environment rides it (the 1024-byte tty
# split, above); boot-exec reads the prompt from the token inside the
# window. The booted prioritizer consumes the token the way a seat consumes
# its own - `handoff-clear prioritizer` as its first act (the prompt says
# so, and so does the skill's role text) - so handoff-list and the board
# show `prioritizer` only while a boot is in flight. LOCAL mode only: a
# HOSTED checkout has no prioritizer session (the canister runs the pass;
# the doctor prints the HOSTED row) and the boot is refused with that reason.
# TEST SEAMS ride the typed line when set: FACTORY_TASKS_ROOT (the booted
# session then works a throwaway queue - a scratch prioritizer that read the
# REAL queue would start reordering it) and FACTORY_PROJECT (the booted
# session derives the same prefix its window was named with). A new window
# inherits Terminal.app's environment, never the spawner's, so the typed
# line is the only channel; both are short and the 1000-byte check applies.
# No arguments: the dry run is FACTORY_SPAWN_DRYRUN=1, the override
# FACTORY_FORCE=1, the model FACTORY_CLAUDE_MODEL (default: the fleet pin).

PRIORITIZER_BOOT_PROMPT="Read .claude/skills/mdex-software-factory/SKILL.md. You are the TaskPrioritizer. You were booted by scripts/factory.sh prioritizer-boot: as your first act run scripts/factory.sh handoff-clear prioritizer (your boot token). Run continuously."

cmd_prioritizer_boot() {
  local primary prefix sname cmodel self seams="" shcmd f
  [ $# -eq 0 ] || die "usage: factory.sh prioritizer-boot (no arguments; FACTORY_SPAWN_DRYRUN=1 prints the plan, FACTORY_FORCE=1 overrides the live/pending guards)"
  if hosted_mode; then
    die "prioritizer-boot: this checkout is HOSTED (factory.sh remote-status) - the prioritizer is the canister's own pass, there is no session to boot on this machine (fleet-doctor prints its HOSTED row; SKILL.md 'Role changes in hosted mode')"
  fi
  primary="$(fleet_primary)"
  [ -n "$primary" ] || die "prioritizer-boot: cannot resolve the primary checkout (run it from inside the suite repo)"
  primary="$(cd "$primary" 2>/dev/null && pwd -P || printf '%s' "$primary")"
  prefix="$(project_prefix)"
  sname="$prefix-prioritizer"
  cmodel="${FACTORY_CLAUDE_MODEL:-$FACTORY_CLAUDE_MODEL_DEFAULT}"
  # The pre-spawn duplicate guard + the spawn-pending guard (shared above),
  # keyed "prioritizer": a live <prefix>-prioritizer refuses the boot.
  spawn_guards prioritizer "$sname"
  f="$HANDOFF/prioritizer.md"
  self="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)/$(basename "$0")"
  [ -z "${FACTORY_TASKS_ROOT:-}" ] || seams="FACTORY_TASKS_ROOT=$(sq "$FACTORY_TASKS_ROOT") "
  [ -z "${FACTORY_PROJECT:-}" ] || seams="${seams}FACTORY_PROJECT=$(sq "$FACTORY_PROJECT") "
  shcmd="cd $(sq "$primary") && ${seams}$(sq "$self") boot-exec prioritizer --model $(sq "$cmodel") --name $(sq "$sname"); exit 0"
  [ "${#shcmd}" -le 1000 ] || die "boot line is ${#shcmd} bytes (limit 1000: the tty splits typed input at 1024 bytes while the window's shell starts) - shorten the primary's path or the project prefix"
  if [ -n "${FACTORY_SPAWN_DRYRUN:-}" ]; then
    spawn_dryrun_print "$sname" "$f" "$PRIORITIZER_BOOT_PROMPT" "$shcmd"
    return 0
  fi
  # THE TOKEN, in the seat-token shape (the hand-boot line first, the prompt
  # under "## Boot prompt" - handoff_prompt reads it, handoff-list and the
  # board list it), rewritten on every boot: its content is deterministic,
  # and a standing copy means the last booted prioritizer never cleared it.
  {
    echo "cd $(shq "$primary") && claude --model $cmodel --name '$sname'"
    echo "# the prioritizer's boot token (factory.sh prioritizer-boot writes it, the booted prioritizer clears it: handoff-clear prioritizer)"
    echo
    echo "## Boot prompt"
    echo "$PRIORITIZER_BOOT_PROMPT"
  } > "$f"
  info "wrote boot token $f (the booted prioritizer clears it: factory.sh handoff-clear prioritizer)"
  spawn_terminal_session prioritizer "$sname" "$shcmd" "prioritizer Terminal in $primary" "the boot token $f stays on handoff-list meanwhile"
}

# --- executor liveness watchdog ---------------------------------------------
# A seat waiting on an executor subagent waits on a NOTIFICATION - and a killed
# subagent (machine sleep, a harness/app restart, a killed terminal) never
# sends one. On 2026-08-20 the machine slept overnight, every in-flight
# executor died mid-turn, and five seats obeyed "wait for the notification"
# for 10+ hours - one of them sitting on a finished, merge-ready branch.
# `executor-watch [path]` is the antidote the skill's executor mode arms
# alongside every spawn: a backgrounded probe that watches the executor's
# LIVE ACTIVITY and EXITS - printing EXECUTOR-STALE - once nothing has been
# written for the stale threshold, so the background-completion notification
# re-invokes the seat and it judges recovery from disk. Liveness is WRITES,
# not process existence: a live executor produces observable writes
# continuously, and mtime needs no ps heuristics.
#
# WHERE activity lands depends on the harness (diagnosed 2026-08-25, session
# e721be77, after four consecutive false STALE firings on one CLI seat):
#   - CLI-harness seats: $HOME/.claude/projects/<flattened-worktree> holds
#     only per-agent spawn/stop stubs (subagents/agent-<id>.meta.json) and
#     DANGLING symlink targets - live activity streams into
#     /private/tmp/claude-<uid>/<flattened-worktree>/<session-id>/tasks/
#     (backgrounded-command output files).
#   - Desktop-harness sessions: transcripts stream into the
#     ~/.claude/projects store itself.
# So the watchdog resolves BOTH candidate dirs itself from the worktree root
# (git toplevel of the cwd; <flattened> = the absolute path with / and .
# folded to -) and takes the newest write across the whole set. An explicit
# <path> argument is ADDED to the set, never a replacement - an old-recipe
# invocation pointed at the stub dir can no longer false-STALE while the
# /private/tmp session dir is active. Defaults: poll every 600s, stale after
# 1500s (the skill's ~10/~25 min). No file anywhere in the set counts as
# idle since the watchdog started - a just-spawned agent produces writes
# within seconds, so a set that never receives any IS a dead (or
# mis-pointed) executor, surfaced after the same grace window.
#
# THE THIRD SOURCE (task 1789684290, diagnosed 2026-09-18 on seat-9): both
# harness dirs assume the executor's writes land there - true while it runs
# BACKGROUNDED commands (their output files stream into the session's
# tasks/), false during a long stretch of foreground Edit/Write/Read tool
# calls: an in-process subagent's transcript is flushed only when it stops,
# and foreground tool output never touches tasks/. A 32-minute foreground
# editing wave (five files written one minute before the check) fired a
# false STALE. So the watchdog also takes the WORKTREE'S OWN EDITS: the
# newest mtime among `git ls-files -m -o --exclude-standard` (modified +
# untracked files, .gitignore honoured - .icp/cache replica ticks,
# node_modules, .mops never count) plus the git admin `index` (a commit or
# a merge is activity). Cheap (git does the walk in ~50ms on the suite),
# precise (only the executor's edits move it), and the verdict line names
# WHICH source produced the newest write so the next false verdict is
# diagnosable from the line alone. Passing the worktree as [path] was never
# a substitute: newest_mtime walks EVERYTHING under a dir, replica state
# included. FACTORY_WATCH_ROOT overrides the worktree root (the selftest
# pins it to a throwaway repo / a non-repo dir, which disables the source).
#
# THE FOURTH SOURCE (task 1792595837, diagnosed 2026-10-21 on seat-7): a
# fleet run the executor tees in the FOREGROUND (`deploy-all.sh ... 2>&1 |
# tee -a <live log>`, the executor prompt's own liveness rule) reaches lib.sh
# suite_output_guard - stdout is a PIPE, so it prints ONE announce line and
# `exec >>`s every further write into <root>/.icp/cache/<label>.<YYYYmmdd-
# HHMMSS>.<pid>.log; the pipe (and so the live log) receives NOTHING for the
# rest of the wave. A reproduction runs BEFORE the fix, so the worktree had
# no edits either, and nothing backgrounded wrote to tasks/: every source
# above sat idle for the whole 28-minute --seed --fresh wave while the run
# was alive (the suite lock held, "Suite is up", exit 0) - a false STALE on
# any wave longer than the threshold. The guard's detached log is exactly
# where that run's liveness lives, so the watchdog also takes the newest
# mtime among the guard's per-run logs at the TOP of <root>/.icp/cache
# (guard_log_newest: the guard's naming only - label, date-time, pid - never
# networks/ or any subdirectory, so replica ticks still never count; a
# pinned deploy-all writes its log to the ORIGIN's .icp/cache, lib.sh
# SUITE_LOG_ROOT, which IS this root). The verdict names the file.
#
# INVARIANT: the loop body prints NOTHING until the verdict. The watchdog's
# own stdout/stderr lands in the seat session's tasks/ output file - inside
# the watched set - so a per-poll print would keep the set alive forever
# (self-observation). The single arming line below is one write at start,
# equivalent to the grace window.

newest_mtime() {  # newest mtime under $1 (file, or dir searched recursively); empty when nothing exists
  local p="$1"
  if [ -f "$p" ]; then stat -f %m "$p" 2>/dev/null || true; return 0; fi
  if [ -d "$p" ]; then find "$p" -type f -exec stat -f %m {} + 2>/dev/null | sort -n | tail -1 || true; fi
  return 0
}

executor_activity_dirs() {  # candidate live-activity dirs for worktree root $1, one per line
  local root="$1" flat tmpbase
  # FACTORY_ACTIVITY_DIRS (colon-separated) overrides resolution entirely -
  # the selftest pins it to a throwaway dir so timing cases stay
  # deterministic inside a live seat's worktree.
  if [ -n "${FACTORY_ACTIVITY_DIRS:-}" ]; then
    printf '%s\n' "$FACTORY_ACTIVITY_DIRS" | tr ':' '\n'
    return 0
  fi
  flat="$(printf '%s' "$root" | sed 's#[/.]#-#g')"
  tmpbase="/private/tmp/claude-$(id -u)"        # macOS harness layout
  [ -d "$tmpbase" ] || tmpbase="/tmp/claude-$(id -u)"
  echo "$tmpbase/$flat"
  echo "$HOME/.claude/projects/$flat"
}

newest_mtime_set() {  # "<epoch>\t<path>" of the newest mtime across a newline-separated path set on stdin - the path that won (a tie keeps the first); empty when nothing exists. One caller: fleet_last_write, which names the winning harness activity dir (task 1792601787)
  local p m best="" bestp=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    m="$(newest_mtime "$p")"
    [ -n "$m" ] || continue
    if [ -z "$best" ] || [ "$m" -gt "$best" ]; then best="$m"; bestp="$p"; fi
  done
  [ -n "$best" ] && printf '%s\t%s' "$best" "$bestp"
  return 0
}

git_index_path() {  # the git admin index of worktree $1 (under rev-parse --git-dir: a LINKED worktree's lives in the primary's .git/worktrees/<name>, never at <root>/.git/index); empty when not a repo
  local wt="$1" gitdir
  gitdir="$(git -C "$wt" rev-parse --git-dir 2>/dev/null || true)"
  [ -n "$gitdir" ] || return 0
  case "$gitdir" in /*) : ;; *) gitdir="$wt/$gitdir" ;; esac
  printf '%s' "$gitdir/index"
}

worktree_edit_mtime() {  # newest mtime among worktree $1's modified + untracked (non-ignored) files and its git index; empty when not a repo or nothing exists
  local root="$1" f m best="" idx
  idx="$(git_index_path "$root")"
  [ -n "$idx" ] || return 0
  m="$(newest_mtime "$idx")"; [ -n "$m" ] && best="$m"
  # -z + a NUL-safe loop: paths may carry spaces or newlines (bash 3.2 has
  # no mapfile -d). A deleted tracked file is listed by -m and has no mtime.
  while IFS= read -r -d '' f; do
    m="$(stat -f %m "$root/$f" 2>/dev/null || true)"
    [ -n "$m" ] || continue
    if [ -z "$best" ] || [ "$m" -gt "$best" ]; then best="$m"; fi
  done < <(git -C "$root" ls-files -m -o --exclude-standard -z 2>/dev/null || true)
  printf '%s' "$best"
}

guard_log_newest() {  # guard_log_newest <root>: "<epoch>\t<file>" of the newest lib.sh suite_output_guard per-run log at the TOP of <root>/.icp/cache (<label>.<YYYYmmdd-HHMMSS>.<pid>.log - a tee'd deploy-all's detached output; never networks/ or any subdirectory); empty when none exists
  local root="$1" f m best="" bestf=""
  for f in "$root"/.icp/cache/*.[0-9]*-[0-9]*.[0-9]*.log; do
    [ -f "$f" ] || continue      # the literal pattern when nothing matches (nullglob is main()'s, not every caller's)
    m="$(stat -f %m "$f" 2>/dev/null || true)"
    [ -n "$m" ] || continue
    if [ -z "$best" ] || [ "$m" -gt "$best" ]; then best="$m"; bestf="$f"; fi
  done
  [ -n "$best" ] && printf '%s\t%s' "$best" "$bestf"
  return 0
}

executor_newest() {  # executor_newest <root> <<< paths: "<epoch>\t<source>" of the newest write across the harness dirs on stdin plus the worktree's own edits plus suite_output_guard's per-run logs at the top of <root>/.icp/cache; empty when nothing exists anywhere
  local root="$1" p m best="" src="" g
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    m="$(newest_mtime "$p")"
    [ -n "$m" ] || continue
    if [ -z "$best" ] || [ "$m" -gt "$best" ]; then best="$m"; src="$p"; fi
  done
  m="$(worktree_edit_mtime "$root")"
  if [ -n "$m" ] && { [ -z "$best" ] || [ "$m" -gt "$best" ]; }; then best="$m"; src="worktree edits under $root (modified/untracked files + git index)"; fi
  g="$(guard_log_newest "$root")"
  m="${g%%	*}"
  if [ -n "$m" ] && { [ -z "$best" ] || [ "$m" -gt "$best" ]; }; then best="$m"; src="suite_output_guard logs under $root/.icp/cache (${g#*	}: a tee'd deploy-all's detached per-run output - tail -f it)"; fi
  [ -n "$best" ] && printf '%s\t%s' "$best" "$src"
  return 0
}

cmd_executor_watch() {
  local path="${1:-auto}" stale="${2:-1500}" poll="${3:-600}" start m now idle root paths label src wsrc gsrc
  case "$stale$poll" in ''|*[!0-9]*) die "stale/poll must be integer seconds" ;; esac
  [ "$poll" -ge 1 ] || poll=1
  root="${FACTORY_WATCH_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  paths="$(executor_activity_dirs "$root")"
  if [ "$path" != "auto" ]; then
    case "$paths" in
      "$path"|"$path"$'\n'*|*$'\n'"$path"|*$'\n'"$path"$'\n'*) : ;;  # already a candidate
      *) paths="$path"$'\n'"$paths" ;;
    esac
  fi
  if [ -n "$(git_index_path "$root")" ]; then wsrc="worktree edits under $root (modified/untracked files + git index)"; else wsrc="(no worktree edits source: $root is not a git worktree)"; fi
  gsrc="suite_output_guard logs under $root/.icp/cache (<label>.<YYYYmmdd-HHMMSS>.<pid>.log at the top level only - a tee'd deploy-all's detached per-run output; networks/ never)"
  label="$(printf '%s\n' "$paths" | tr '\n' ' ')$wsrc + $gsrc"
  start="$(now_s)"
  watch_arm_obituary executor-watch
  info "executor-watch: watching newest write across: $label (stale after ${stale}s, polling every ${poll}s)"
  while :; do
    sleep "$poll" & wait $! || true   # under `wait` so a trapped signal lands now
    now="$(now_s)"
    m="$(executor_newest "$root" <<EOF
$paths
EOF
)"
    src="${m#*	}"; m="${m%%	*}"
    if [ -z "$m" ]; then
      idle=$((now - start))
      [ "$idle" -gt "$stale" ] || continue
      echo "EXECUTOR-STALE no file ever appeared under any of: $label ($((idle / 60))m, threshold $((stale / 60))m) - the executor is dead or every path is wrong; judge from disk per the skill's executor loss recovery"
      return 0
    fi
    idle=$((now - m))
    if [ "$idle" -gt "$stale" ]; then
      echo "EXECUTOR-STALE idle $((idle / 60))m across all of: $label (threshold $((stale / 60))m; newest write $(date -u -r "$m" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "epoch $m") from: $src) - no completion notification and no writes: judge from disk (activity tail + worktree git state) per the skill's executor loss recovery; a child exit marker with agent silence since = DEAD, respawn (do not nudge)"
      return 0
    fi
  done
}

# --- the seat heartbeat + fleet doctor (the stall self-heal) -----------------
# THE FLEET-WIDE SILENT PARK (2026-09-03, the third in four days): every seat
# and the prioritizer sat alive as processes (S+, ~0% cpu) for 8+ hours with
# claimable work in the queue, and nothing resumed them. A seat's liveness
# loop was ONE background completion notification: it armed `factory.sh
# watch`, ended its turn, and when the completion (TIMEOUT, CHANGED, or the
# harness's "[killed]" marker - the activity streams show a fleet-wide sweep
# killing every seat's backgrounded watch every 30 minutes at :11:57/:41:57Z)
# failed to re-invoke the session, the seat was parked for good - the
# parked-waiter class the skill documents for executors, observed for whole
# seats. executor-watch cannot help: it is armed BY the seat, and a parked
# seat arms nothing. So liveness moves OUTSIDE the sessions:
#   - HEARTBEAT: every factory.sh command run from inside a pinned worktree
#     touches <worktree>/.factory-heartbeat (heartbeat_touch, from main) - a
#     structural "the model just ran a command" mark that costs a seat
#     nothing and needs no skill compliance. `factory.sh heartbeat` is the
#     explicit form for a cycle that runs no other factory command.
#   - FLEET-DOCTOR: `factory.sh fleet-doctor` (run from the primary by
#     launchd every 15 min - `--launchd-plist` prints the job) walks every
#     pinned worktree, takes the newest write across the heartbeat, the git
#     index, the harness activity dirs (executor_activity_dirs), lib.sh
#     suite_output_guard's per-run logs at the TOP of <seat>/.icp/cache
#     (guard_log_newest - a tee'd deploy-all's detached output, the ONE write
#     of a whole fleet wave; task 1792598009) and the
#     worktree tree itself (node_modules/.icp/.git pruned - replica ticks
#     lie), checks for a live process carrying the seat's session name, and
#     prints one verdict per seat: ACTIVE (a write inside the window),
#     STALLED (live process, silent past the threshold, AND work it could be
#     doing: its own claim or a claimable queue task - "a seat that has not
#     written for 30 min while the queue is non-empty is DEAD, not idle"),
#     QUIET (silent, but nothing claimable - indistinguishable from a healthy
#     idle seat until work arrives), UNMANNED (no process at all), and since
#     task 1792504454 LOGGED-OUT (a live process whose own transcript ends on
#     the CLI's login-expired message - the CLI login section below: the
#     `claude auth status` pre-check, FLEET-LOGGED-OUT holding every respawn,
#     the replace-after-login rule). The
#     prioritizer gets the same treatment by its board's mtime (its watch
#     legitimately sleeps up to an hour, so its threshold is >= 65 min).
#   - RESPAWN is OPT-IN (--respawn or FACTORY_FLEET_RESPAWN=1; report-only
#     by default - the operator has not recorded standing approval for
#     unattended kills): a STALLED seat gets a takeover handoff file written
#     for it (with the COMPLETE/PARTIAL/ABSENT triage note when it holds a
#     claim), its parked process is killed (TERM, then KILL - ONLY the pids
#     whose argv carries the seat's session name), and spawn-successor boots
#     the successor into the same worktree; an UNMANNED seat is spawned
#     without a kill (a pending handoff file of its own is honored as-is).
#     --dry-run prints the plan and touches nothing. The prioritizer is
#     never respawned (no worktree, no handoff token): its line carries the
#     boot command for the operator.

HEARTBEAT_FILE=".factory-heartbeat"

heartbeat_touch() {  # mark the pinned worktree at/above $PWD as "a factory command just ran here"
  resolve_pin
  [ -n "$PIN_PATH" ] || return 0
  touch "$(dirname "$PIN_PATH")/$HEARTBEAT_FILE" 2>/dev/null || true
}

cmd_heartbeat() {
  resolve_pin
  [ -n "$PIN_PATH" ] || die "heartbeat: no .factory-worker pin at/above $(pwd -P 2>/dev/null || pwd) - a heartbeat belongs to a pinned seat worktree (factory.sh worker-pin)"
  touch "$(dirname "$PIN_PATH")/$HEARTBEAT_FILE" || die "cannot touch $(dirname "$PIN_PATH")/$HEARTBEAT_FILE"
  echo "$(dirname "$PIN_PATH")/$HEARTBEAT_FILE"
}

fleet_primary() {  # the primary checkout, even under FACTORY_TASKS_ROOT (the selftest's fake repo)
  if [ -n "${PRIMARY:-}" ]; then printf '%s' "$PRIMARY"; return 0; fi
  git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || true
}

self_ancestors() {  # the caller's own process chain, space-separated (" p1 p2 ... ")
  local a out=""
  a=$$
  while [ "${a:-0}" -gt 1 ] 2>/dev/null; do
    out="$out $a "
    a="$(ps -o ppid= -p "$a" 2>/dev/null | tr -d ' ' || true)"
    [ -n "$a" ] || break
  done
  printf '%s' "$out"
}

name_pids() {  # pids whose argv carries "--name $1" (word-bounded)
  # -a: BSD pgrep silently EXCLUDES its own ancestors by default, so a doctor
  # run from inside a seat's session would report that very seat UNMANNED
  # (seen on the first live run, 2026-09-03). The awk keeps only the pid
  # column, so the GNU meaning of -a (print the command line too) degrades
  # harmlessly. THE MIRROR HAZARD: with ancestors included, a shell whose
  # own command line merely MENTIONS the name (a harness `bash -c` running a
  # script that quotes it - the selftest's first run) matches too, and the
  # respawn path then killed the doctor's own shell (exit 144). So an
  # ancestor of ours counts only when it IS a claude process (the calling
  # seat itself); any other ancestor is our own plumbing, never a seat.
  local pat p anc out=""
  pat="[-]-name $(printf '%s' "$1" | sed 's/[][\\.*^$()+?{}|]/\\&/g')( |$)"
  anc="$(self_ancestors)"
  for p in $(pgrep -a -f "$pat" 2>/dev/null | awk '{print $1}' || true); do
    case "$anc" in *" $p "*)
      case "$(ps -o comm= -p "$p" 2>/dev/null)" in *claude*) : ;; *) continue ;; esac ;;
    esac
    out="$out $p"
  done
  printf '%s' "${out# }"
}

fleet_claimable() {  # count queue tasks a consumer could claim right now (consumer lane, deps met)
  local f n=0
  if hosted_mode; then   # the hosted queue: the client counts the same set (fail-soft: 0)
    n="$(client list --consumer --claimable --count 2>/dev/null || true)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
    return 0
  fi
  for f in "$QUEUE"/*.md; do
    [ -e "$f" ] || continue
    is_operator_lane "$f" && continue
    deps_met "$f" || continue
    n=$((n+1))
  done
  printf '%s' "$n"
}

fleet_last_write() {  # fleet_last_write <worktree> <ref-file>: "<epoch>\t<source>" - the newest activity write for a seat AND which source made it (executor_newest's shape, task 1792601787); empty when no source exists
  # The cheap signals first (heartbeat, the worktree's git index, the harness
  # activity dirs, lib.sh suite_output_guard's per-run logs at the top of
  # .icp/cache - a tee'd deploy-all's detached output, executor-watch's
  # fourth source); the tree walk last and only as a yes/no against the
  # threshold reference - `find -newer ref -print -quit` returns at the first
  # fresh file, so an active tree costs one stat and only a silent tree is
  # walked in full (node_modules, .icp and .git pruned: replica ticks and
  # dependency installs are not the model writing).
  # THE SOURCE rides the return (task 1792601787): the five are named
  # `heartbeat`, `git index`, `harness activity dir <path>`, `guard log
  # <file>` and `tree (a file newer than the threshold edge - the walk is a
  # yes/no)`; a tie keeps the EARLIER source in this order. cmd_fleet_doctor
  # splits the field the way cmd_executor_watch does and prints it INSIDE
  # the row's note, so a false ACTIVE or STALLED is diagnosable from the
  # fleet-doctor log alone - on 2026-10-21 a seat in a tee'd wave read
  # ACTIVE "idle 0m" off the guard log with nothing saying so.
  local wt="$1" ref="$2" best="" src="" m idx g
  m="$(newest_mtime "$wt/$HEARTBEAT_FILE")"; if [ -n "$m" ]; then best="$m"; src="heartbeat"; fi
  idx="$(git_index_path "$wt")"
  if [ -n "$idx" ]; then
    m="$(newest_mtime "$idx")"
    if [ -n "$m" ] && { [ -z "$best" ] || [ "$m" -gt "$best" ]; }; then best="$m"; src="git index"; fi
  fi
  g="$(executor_activity_dirs "$wt" | newest_mtime_set)"; m="${g%%$'\t'*}"
  if [ -n "$m" ] && { [ -z "$best" ] || [ "$m" -gt "$best" ]; }; then best="$m"; src="harness activity dir ${g#*$'\t'}"; fi
  # suite_output_guard's per-run logs at the TOP of <wt>/.icp/cache (task
  # 1792598009; guard_log_newest - the guard's naming only, top level only, so
  # networks/ and every subdirectory still never count): a tee'd deploy-all
  # wave writes nothing else for its whole run, and the pruned .icp walk
  # below never sees them - a seat in a wave longer than the bar read STALLED,
  # and --respawn killed its live fleet run from under it.
  g="$(guard_log_newest "$wt")"; m="${g%%$'\t'*}"
  if [ -n "$m" ] && { [ -z "$best" ] || [ "$m" -gt "$best" ]; }; then best="$m"; src="guard log ${g#*$'\t'}"; fi
  if [ -n "$(find "$wt" -path '*/node_modules' -prune -o -path '*/.icp' -prune -o -path '*/.git' -prune -o -type f -newer "$ref" -print -quit 2>/dev/null)" ]; then
    m="$(stat -f %m "$ref" 2>/dev/null || true)"   # "inside the window" is all the walk says; report the threshold edge
    m=$((m + 1))
    if [ -z "$best" ] || [ "$m" -gt "$best" ]; then best="$m"; src="tree (a file newer than the threshold edge - the walk is a yes/no)"; fi
  fi
  [ -n "$best" ] && printf '%s\t%s' "$best" "$src"
  return 0
}

fleet_write_handoff() {  # fleet_write_handoff <seat> <worktree> <session-name> <worker> <claim-id-or-empty> <idle-min> [reason: ""|login]
  local seat="$1" wt="$2" sname="$3" worker="$4" claim="$5" idle="$6" reason="${7:-}" f triage="" why
  f="$HANDOFF/$seat.md"
  [ -f "$f" ] && return 0   # the seat's own handoff token stands; never overwrite it
  # The reason the successor reads: silence (the stall self-heal) or, since
  # task 1792504454, the login replacement - a session parked on an expired
  # CLI login never re-reads the Keychain, so once the login is back the
  # doctor kills it and boots this successor (the CLI login section).
  if [ "$reason" = "login" ]; then
    why="fleet-doctor REPLACED this seat: its session was parked on an expired CLI login (its last transcript entry was the CLI's 'Login expired - Please run /login' message; a parked session never re-reads the Keychain) and the login has since been restored"
  else
    why="fleet-doctor revived this seat after ${idle}m of silence"
  fi
  if [ -n "$claim" ]; then
    triage="You INHERIT claim $claim (tasks/claimed/$worker/, see factory.sh show $claim): $why, so judge that claim from DISK first - git -C $wt log --oneline main.., git status, and the activity tail - COMPLETE (committed, gates run, .done written) means integrate + archive; PARTIAL means verify what exists and finish it; ABSENT means start it clean. Never re-run a task over a merge-ready branch."
  elif [ "$reason" = "login" ]; then
    triage="$why (no claim was held: plain takeover)."
  else
    triage="$why with claimable work in the queue (no claim was held: plain takeover)."
  fi
  {
    echo "cd $(shq "$wt") && claude --model ${FACTORY_CLAUDE_MODEL:-$FACTORY_CLAUDE_MODEL_DEFAULT} --name '$sname'"
    echo
    echo "## Boot prompt"
    echo "Read .claude/skills/mdex-software-factory/SKILL.md. You are a TaskConsumer in executor mode taking over the seat at $wt. $triage Work the queue continuously."
  } > "$f"
  info "wrote takeover handoff $f"
}

fleet_kill_pids() {  # TERM, wait up to 8s, then KILL - the named seat process(es) only, never our own chain
  local p n=0 left="" anc
  anc="$(self_ancestors)"
  for p in "$@"; do case "$anc" in *" $p "*) die "fleet-doctor: refusing to kill pid $p - it is this doctor's own ancestor (run the doctor from the primary, not from the seat being revived)" ;; esac; done
  for p in "$@"; do kill -TERM "$p" 2>/dev/null || true; done
  while [ "$n" -lt 8 ]; do
    left=""; for p in "$@"; do rr_alive "$p" && left="$left $p"; done
    [ -z "$left" ] && return 0
    sleep 1; n=$((n+1))
  done
  for p in $left; do kill -KILL "$p" 2>/dev/null || true; done
  sleep 1
  return 0
}

fleet_launchd_plist() {  # the operator-installed job: fleet-doctor from the primary every 15 min
  local primary="$1" prefix="$2" label logf
  label="$prefix.factory-fleet-doctor"          # separate lines: one `local a=.. b=$a` expands $a BEFORE assigning
  logf="$HOME/Library/Logs/$prefix-fleet-doctor.log"
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$primary/scripts/factory.sh</string>
    <string>fleet-doctor</string>
  </array>
  <key>WorkingDirectory</key><string>$primary</string>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$logf</string>
  <key>StandardErrorPath</key><string>$logf</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
</dict>
</plist>
PLIST
  {
    echo "factory: install (operator step): factory.sh fleet-doctor --launchd-plist > ~/Library/LaunchAgents/$label.plist && launchctl load -w ~/Library/LaunchAgents/$label.plist"
    echo "factory: report-only by default; to opt in to unattended respawns add <key>FACTORY_FLEET_RESPAWN</key><string>1</string> to EnvironmentVariables (the skill records the approval). Log: $logf"
  } >&2
}

# --- where a seat lives: the seat root (task 1789581979) ---------------------
# THE WIPER, IDENTIFIED (2026-09-16, ~/Library/Logs/Claude/main.log): the
# Claude DESKTOP APP's WorktreePool runs an "untracked-dir GC" every 30 min
# over <repo>/.claude/worktrees/ - its OWN worktree pool root - and removes
# any subdirectory no app session made, once it is past a minimum age (the
# sightings cycle ~daily), a registered git worktree, clean (git status
# --porcelain empty), and quiet: "recently-active" is the newest mtime of
# the worktree DIRECTORY itself, its .git pointer file, and the git admin
# dir's index + HEAD within 24 h (read from the app bundle's
# reapUntrackedWorktreeDir; a file touched INSIDE the tree does not count).
# The removal is `git worktree remove --force`, logged as
# "[reapUntrackedWorktreeDir] Removed untracked worktree dir <path>". A CLI
# factory seat is untracked by construction and an idle seat is clean +
# quiet + registered - exactly the removal shape (seat-14 on 2026-09-08 and
# 09-13, seat-7 on 09-06 and 09-12); busy seats survive only by never
# being quiet long enough. Two keep reasons the GC honours BEFORE the age /
# clean checks: a `.worktree-keep` file at the worktree root (its logged
# verdict is keep-sentinel) and a `git worktree lock`. So:
#   - NEW seats live under <primary>/.factory/seats/<seat> - the SEAT ROOT
#     (`factory.sh seat-root [seat]` prints it, gitignored) - which the GC
#     never enumerates (its scan roots are the app's own pool dirs) and
#     would refuse anyway ("foreign-parent": the parent must be the pool
#     root). seat-recreate mints there; the skill's Setup line does too.
#   - EXISTING seats stay where they are until their next natural
#     retirement - a live seat is never moved under a running replica. A
#     seat under .claude/worktrees/ is a LEGACY location the app may GC
#     when idle; the fleet-doctor line says "legacy-location" for it.
#   - The BELT for a legacy-located seat: worker-pin, handoff-clear's pin
#     refresh and every fleet-doctor pass drop `.worktree-keep` into each
#     pinned seat (seat_keep_sentinel; gitignored, so the tree stays
#     clean), which the GC answers with keep-sentinel before it ever looks
#     at age or cleanliness. The .factory-heartbeat stamp is NOT a belt: it
#     is a file inside the tree and never moves the mtimes the GC reads.
SEAT_ROOT_REL=".factory/seats"
LEGACY_SEAT_ROOT_REL=".claude/worktrees"
KEEP_SENTINEL=".worktree-keep"

seat_root() {  # the seat root, physical: <primary>/.factory/seats ("" when no primary resolves)
  local p; p="$(fleet_primary)"
  [ -n "$p" ] || return 1
  p="$(cd "$p" 2>/dev/null && pwd -P || printf '%s' "$p")"
  printf '%s/%s' "$p" "$SEAT_ROOT_REL"
}

seat_legacy_located() {  # seat_legacy_located <worktree>: true when the tree sits in the desktop app's pool root
  case "$(dirname "${1%/}")" in */$LEGACY_SEAT_ROOT_REL) return 0 ;; esac
  return 1
}

seat_keep_sentinel() {  # seat_keep_sentinel <worktree>: drop the desktop app's keep sentinel (idempotent, never fails)
  [ -d "$1" ] || return 0
  [ -e "$1/$KEEP_SENTINEL" ] || : > "$1/$KEEP_SENTINEL" 2>/dev/null || true
  return 0
}

cmd_seat_root() {  # seat-root [seat]: print the seat root (created on demand), or the path a seat lives at
  local root seat="${1:-}"
  [ $# -le 1 ] || die "usage: factory.sh seat-root [seat]"
  case "$seat" in -*) die "usage: factory.sh seat-root [seat]" ;; esac
  root="$(seat_root)" || die "seat-root: cannot resolve the primary checkout (run it inside the suite repo)"
  mkdir -p "$root" 2>/dev/null || die "seat-root: cannot create $root"
  if [ -n "$seat" ]; then
    seat="$(basename "$seat")"
    case "$seat" in .|..|'') die "seat-root: '$1' is not a seat name" ;; esac
    printf '%s/%s\n' "$root" "$seat"
  else
    printf '%s\n' "$root"
  fi
}

# --- the fleet roster: seats the doctor REMEMBERS (task 1788956135) ---------
# THE VANISHING WORKTREE (seat-7 on 2026-09-06, seat-14 on 2026-09-08): a
# seat's worktree was DELETED under a LIVE process - no transcript shows the
# removal, no script under scripts/ removes seat worktrees - and the fleet
# silently shrank 10 -> 6, because the doctor ENUMERATED pinned worktrees: a
# missing one simply dropped out and the summary read "FLEET-OK seats 6".
# seat-14's CLI process (cwd pointing at the removed directory) stayed alive
# as a dead husk that can never claim again. (The remover was identified on
# 2026-09-16 - the seat-root section above.) So the doctor now REMEMBERS:
#   - tasks/factory/fleet-roster: one seat per line,
#     "<seat>\t<worktree>\t<worker>\t<branch>\t<registered-iso>", written by
#     worker-pin (every seat's boot step, and handoff-clear's pin refresh),
#     ADOPTED by fleet-doctor for any pinned worktree it enumerates that is
#     not on it yet (so a running fleet converges on the doctor's first pass
#     with no seat action - adoption only ever ADDS a seat whose worktree
#     exists), and dropped ONLY by `seat-retire`. A roster seat whose
#     worktree is missing reads ORPHANED and the summary line reads
#     FLEET-DEGRADED n missing of N - never FLEET-OK.
#   - tasks/factory/fleet-orphaned: "<seat>\t<first-missing-iso>" - the FIRST
#     pass that saw the worktree missing, the forensic anchor (with the
#     seat's parent dir's mtime, which brackets the deletion, and whether
#     the git admin dir .git/worktrees/<seat> still exists: present = an
#     `rm -rf`, absent = `git worktree remove`/`prune` - the desktop app's
#     GC leaves the latter shape).
#   - the TRIPWIRE: worker-pin also writes the seat name into
#     <primary>/.git/worktrees/<seat>/factory-seat, so a prunable admin dir
#     names its seat even after the tree is gone.
#   - `seat-recreate <seat>` rebuilds a vanished seat (refuses when the
#     worktree exists): kills the dead-husk process, drops the stale git
#     admin entry for THAT path only, fast-forwards claude/<seat> to main when
#     it is 0 ahead (else keeps the branch as is and says so), git worktree
#     add UNDER THE SEAT ROOT (a legacy .claude/worktrees row is relocated:
#     the tree is gone, so nothing moves under a replica), ./scripts/bootstrap.sh in the tree (deps + the keys symlinks;
#     FACTORY_RECREATE_BOOTSTRAP=0 skips), worker-pin, a takeover handoff
#     ("recreated after its worktree vanished"), spawn-successor (--no-spawn
#     leaves the handoff for a hand boot), then prints the roster.
#   - `seat-retire <seat>` is the ONLY sanctioned way to drop a seat:
#     replica-recycle in the tree, kill the named process, refuse while any
#     OTHER live process has its cwd inside the tree (lsof - never remove a
#     directory a live session stands in: the legacy seat-5 tree was two
#     operator Desktop sessions' cwd), git worktree remove, the branch
#     (git branch -d - kept when unmerged), the handoff file, the roster row,
#     and a line appended to the fleet-doctor log. Never runs against the
#     primary, never from inside the seat being retired.
# Both commands are OPERATOR commands (run from the primary console); the
# doctor never recreates or retires on its own, even under --respawn.

ROSTER_FILE="fleet-roster"
ORPHANED_FILE="fleet-orphaned"

roster_path()   { printf '%s/%s' "$FACTORY" "$ROSTER_FILE"; }
orphaned_path() { printf '%s/%s' "$FACTORY" "$ORPHANED_FILE"; }

roster_register() {  # roster_register <worktree-top> <worker> [branch]: add or refresh the seat's row + the admin tripwire
  local top="$1" worker="$2" branch="${3:-}" seat gitdir rf tmp
  top="$(cd "$top" 2>/dev/null && pwd -P || printf '%s' "$top")"
  seat="$(basename "$top")"
  # Only a LINKED worktree is a seat the doctor can enumerate (it walks
  # `git worktree list` of the primary); a standalone checkout pinned by
  # hand would sit on the roster as a permanent orphan, so it is not listed.
  gitdir="$(git -C "$top" rev-parse --git-dir 2>/dev/null || true)"
  case "$gitdir" in /*) : ;; ?*) gitdir="$top/$gitdir" ;; esac
  [ -n "$gitdir" ] && [ -d "$gitdir" ] && [ "$gitdir" != "$top/.git" ] || return 0
  [ -n "$branch" ] || branch="$(git -C "$top" branch --show-current 2>/dev/null || true)"
  rf="$(roster_path)"
  tmp="$rf.$$"
  { [ -f "$rf" ] && grep -v "^$seat	" "$rf" || true
    printf '%s\t%s\t%s\t%s\t%s\n' "$seat" "$top" "$worker" "${branch:-?}" "$(now_iso)"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$rf" 2>/dev/null || rm -f "$tmp"
  orphaned_forget "$seat"
  # The tripwire: the admin dir names its seat even after the tree is gone.
  printf '%s\n' "$seat" > "$gitdir/factory-seat" 2>/dev/null || true
}

roster_remove() {  # drop <seat>'s row (seat-retire only)
  local seat="$1" rf tmp
  rf="$(roster_path)"
  [ -f "$rf" ] || return 0
  tmp="$rf.$$"
  { grep -v "^$seat	" "$rf" || true; } > "$tmp" && mv -f "$tmp" "$rf" || rm -f "$tmp"
  orphaned_forget "$seat"
}

roster_row() {  # roster_row <seat> -> the row, or nothing
  local rf; rf="$(roster_path)"
  [ -f "$rf" ] && grep "^$1	" "$rf" | head -1 || true
}

roster_seats() {  # every seat on the roster, one per line
  local rf; rf="$(roster_path)"
  [ -f "$rf" ] && cut -f1 "$rf" || true
}

orphaned_mark() {  # orphaned_mark <seat> -> the first-missing instant (records now on first sight)
  local seat="$1" of first
  of="$(orphaned_path)"
  first="$([ -f "$of" ] && grep "^$seat	" "$of" | head -1 | cut -f2 || true)"
  if [ -z "$first" ]; then
    first="$(now_iso)"
    printf '%s\t%s\n' "$seat" "$first" >> "$of"
  fi
  printf '%s' "$first"
}

orphaned_forget() {  # the seat is back (recreated / re-pinned) or gone for good (retired)
  local seat="$1" of tmp
  of="$(orphaned_path)"
  [ -f "$of" ] || return 0
  tmp="$of.$$"
  { grep -v "^$seat	" "$of" || true; } > "$tmp" && mv -f "$tmp" "$of" || rm -f "$tmp"
}

path_key() {  # a comparable form of a path that may no longer exist: git records the path AS GIVEN at
  # `worktree add`, the roster records the PHYSICAL one (pwd -P) - on macOS /var, /tmp and /etc are
  # symlinks into /private, so the two differ for a temp tree (the selftest's) while a missing dir
  # cannot be resolved any more. Stripping the /private prefix makes both sides agree.
  local p="${1%/}"
  case "$p" in /private/*) p="${p#/private}" ;; esac
  printf '%s' "$p"
}

wt_prunable() {  # wt_prunable <primary> <path>: "yes" when git worktree list marks the entry prunable, "no" when listed and sound, "unlisted"
  local primary="$1" key line in=false res="unlisted"
  key="$(path_key "$2")"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        if [ "$(path_key "${line#worktree }")" = "$key" ]; then in=true; res="no"; else [ "$in" = true ] && break; in=false; fi ;;
      prunable*) [ "$in" = true ] && res="yes" ;;
    esac
  done <<EOF
$(git -C "$primary" worktree list --porcelain 2>/dev/null || true)
EOF
  printf '%s' "$res"
}

wt_admin_dir() {  # wt_admin_dir <primary> <path>: the .git/worktrees/<x> admin dir whose gitdir points into <path>, or nothing
  local primary="$1" key d g
  key="$(path_key "$2")/.git"
  for d in "$primary"/.git/worktrees/*; do
    [ -f "$d/gitdir" ] || continue
    g="$(head -1 "$d/gitdir" 2>/dev/null | tr -d '\r\n')"   # the line end only: a path may hold spaces
    if [ "$(path_key "$g")" = "$key" ]; then printf '%s' "$d"; return 0; fi
  done
  return 0
}

live_cwd_pids() {  # live_cwd_pids <path>: "pid(comm)" for every live process whose cwd is AT or UNDER <path> - the never-remove-a-live-cwd rule
  local path="$1" out="" pid="" cmd="" line n
  while IFS= read -r line; do
    case "$line" in
      p*) pid="${line#p}"; cmd="" ;;
      c*) cmd="${line#c}" ;;
      n*) n="${line#n}"
          if [ "$n" = "$path" ] || [ "${n#"$path"/}" != "$n" ]; then out="$out $pid($cmd)"; fi ;;
    esac
  done <<EOF
$(lsof -a -d cwd -Fpcn 2>/dev/null || true)
EOF
  printf '%s' "${out# }"
}

fleet_log_path() { printf '%s' "${FACTORY_FLEET_LOG:-$HOME/Library/Logs/$(project_prefix)-fleet-doctor.log}"; }
fleet_log_append() {  # a line into the operator's fleet-doctor log (seat-retire / seat-recreate are not launchd-run)
  local f; f="$(fleet_log_path)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  printf '%s\n' "$*" >> "$f" 2>/dev/null || true
}
fleet_log_line() {  # a line to stdout AND the log - once: under launchd stdout IS the log file
  local f; f="$(fleet_log_path)"
  printf '%s\n' "$*"
  if [ -e "$f" ] && [ /dev/fd/1 -ef "$f" ]; then return 0; fi
  fleet_log_append "$*"
}

# --- the fleet doctor's FSEvents check (task 1791198753) ----------------------
# The wedge the whole fleet stalls on: fseventsd stops delivering machine-wide
# and every fresh `icp network start` parks forever (recurred 2026-08-04,
# 09-04, 09-30). Each pass probes both volumes (the primary's + /private/tmp,
# lib-fsevents.sh fsevents_probe - ~1-3s each when alive, ~18s each when dead)
# and on DEAD-on-BOTH runs the unattended remedy, fsevents_remedy_run (the
# root-owned wrapper under the operator-installed NOPASSWD rule; not installed
# = the paste line). Reporting, all channels: the FSEVENTS line (stdout = the
# launchd log), fleet_log_line into the fleet-doctor log when run by hand, the
# ledger fsevents_ledger_append writes, the `fsevents restarts:` header the
# console's inbox check reads, and a best-effort macOS notification
# (FACTORY_OSASCRIPT_BIN overrides osascript - the selftest's fake). Skipped
# off Darwin, under SUITE_FSEVENTS_PROBE=0, and under --dry-run (a restart is
# a change; the header still prints from the ledger).
fleet_fsevents_say() { echo "fleet-doctor: $*"; }
fleet_fsevents_check() {  # fleet_fsevents_check <primary> <dry:true|false>
  local primary="$1" dry="$2" rc_a=0 rc_b=0 log_a log_b rrc=0 osa
  [ "$(uname)" = "Darwin" ] || return 0
  [ "${SUITE_FSEVENTS_PROBE:-1}" = "0" ] && return 0
  [ "$dry" = true ] && return 0
  FSEVENTS_WARN=fleet_fsevents_say
  fsevents_probe "$primary" && rc_a=0 || rc_a=$?
  log_a="$FSEVENTS_PROBE_ATTEMPTS"
  fsevents_probe /private/tmp && rc_b=0 || rc_b=$?
  log_b="$FSEVENTS_PROBE_ATTEMPTS"
  if [ "$rc_a" -ne 1 ] || [ "$rc_b" -ne 1 ]; then
    if [ "$rc_a" = 1 ]; then echo "fsevents: DEAD on the primary's volume ($log_a), /private/tmp alive - a start there takes the tmp-symlink workaround"; else echo "fsevents: alive (primary $log_a; /private/tmp $log_b)"; fi
    return 0
  fi
  fleet_log_line "fleet-doctor $(now_iso) FSEVENTS DEAD on both volumes (primary: $log_a; /private/tmp: $log_b) - no replica can start"
  fsevents_remedy_run fleet-doctor "$primary" || rrc=$?
  fleet_log_line "fleet-doctor $(now_iso) $FSEVENTS_REMEDY_REPORT"
  if [ "$rrc" -eq 0 ]; then
    osa="${FACTORY_OSASCRIPT_BIN:-osascript}"
    "$osa" -e "display notification \"fseventsd restarted ($FSEVENTS_REMEDY_OLD -> $FSEVENTS_REMEDY_NEW)\" with title \"Open SaaS fleet doctor\"" >/dev/null 2>&1 || true
  elif [ "$rrc" -eq 1 ]; then
    fleet_log_line "fleet-doctor $(now_iso) fsevents remedy by hand: $(fsevents_remedy_line)"
  fi
  return 0
}

# --- the fleet doctor's CLI login check (task 1792504454) ---------------------
# THE 17.5-HOUR DEAD FLEET (2026-10-19 20:08Z -> 10-20 13:49Z, the queue at 8
# claimable): the seat CLI's credentials - the macOS Keychain item "Claude
# Code-credentials", shared by every CLI process of the user; the DESKTOP
# APP's login is a separate item and never carries over - expired. Every
# seat's next turn ended with the CLI's synthetic assistant entry "Login
# expired <middle dot> Please run /login" ("isApiErrorMessage":true, "error":
# "authentication_failed", model "<synthetic>") and the process then sat
# alive at its prompt; the prioritizer had died the same way a day earlier
# (its board went stale: the "1 stalled" from 2026-10-19 20:40Z on). The
# doctor never named the cause: a parked logged-out seat has a live pid and
# a fresh worktree write (boot-exec drops the boot prompt into the tree at
# every boot), so it read ACTIVE for 65 min, then STALLED (claimable > 0) ->
# killed + respawned -> the successor died on ITS first turn with the same
# text -> ACTIVE again: an hourly respawn loop that cannot heal (the 12:59Z
# and 13:44Z passes each revived 8 seats that all died on turn one) under a
# summary reading FLEET-OK / FLEET-STALLED 1. Now, on every pass:
#   1. The FLEET-LOGGED-OUT pre-check (fleet_login_check): `claude auth
#      status` - JSON, "loggedIn": true|false on 2.1.257, read with grep (no
#      jq), under a kill-after watchdog by pid (fleet_auth_status). Logged
#      out: the loud FLEET-LOGGED-OUT line with the one-login remedy (stdout
#      is the launchd log; fleet_log_line by hand), the stamp
#      tasks/factory/fleet-logged-out the board header reads (factory.sh
#      index, "CLI login"), a macOS notification (first sighting, then
#      hourly), and EVERY respawn of the pass is held - a successor booted
#      logged out dies on its first turn too - while the per-seat rows still
#      print. Unreadable ("unknown: ...") is judged as logged in: a CLI the
#      doctor cannot read must never hold the fleet.
#   2. The per-seat verdict LOGGED-OUT: a live pid whose transcript's LAST
#      conversation entry is that synthetic message (session_login_expired).
#      Report-only while FLEET-LOGGED-OUT stands.
#   3. Once auth status reads logged in again, a parked LOGGED-OUT session
#      never re-reads the Keychain (nobody sends it a next turn): under
#      --respawn the pass REPLACES it - the same kill-by-pid (fleet_kill_pids,
#      TERM then KILL, never by name) + spawn-successor path as STALLED, the
#      takeover handoff naming the reason - and KEEPS every seat whose
#      transcript moved past the login (the 2026-10-20 recovery by hand:
#      /login in one seat window, then kill -TERM + spawn-successor for the
#      other 7; all 7 booted logged in).
#   4. The prioritizer row: the same detection against ITS transcript (the
#      primary's transcript dir is shared with the operator's sessions, so
#      its file is the one whose agent-name line names its session); held
#      and replaced under --respawn exactly like a seat - kill by pid, then
#      prioritizer-boot (task 1792506027 made the prioritizer a spawn-path
#      citizen; before it the row carried a paste line and no auto-boot).
# WHICH TRANSCRIPT: the CLI keeps one <session>.jsonl per session under
# ~/.claude/projects/<cwd with every / and . as -> (FACTORY_TRANSCRIPT_ROOT
# overrides the root - the selftest's fixture tree, never the real store). A
# seat's is the newest file there whose tail carries its session name in an
# agent-name line, else the newest file; and it must be NEWER than the live
# process (pid_start_epoch): an older file is a predecessor's and says
# nothing about this session, so a fresh successor is never judged by the
# session it replaced.
# WHAT COUNTS: the newest conversation entry (type assistant|user in the
# line's head) among the last 400 lines - bookkeeping lines (turn_duration,
# last-prompt, agent-name, cost-state) follow a message, so the last LINE is
# never it - must be an assistant entry that is the CLI's own API-error
# message ("isApiErrorMessage":true - a JSON key, which cannot occur inside a
# string value where every quote is escaped, so prose QUOTING the text - a
# seat reporting this very verdict - can never match) whose text carries
# "Login expired" and "Please run /login": the middle dot between the two
# halves is the non-ASCII U+00B7, which this ASCII-only script matches
# around, never spells.
LOGGED_OUT_FILE="fleet-logged-out"   # tasks/factory/<file>: since/epoch/notified of the standing FLEET-LOGGED-OUT
LOGIN_REMEDY='one login covers every seat and the prioritizer: run `claude auth login` as the seat user, or /login inside any one seat window (the desktop app login is a separate Keychain item and never carries over)'
LOGIN_EXPIRED_TEXT='Login expired - Please run /login'   # the ASCII rendering of the CLI text in every line the doctor prints
FLEET_AUTH=""   # fleet_login_check's verdict for the pass: in | out | unknown: <why>

fleet_claude_bin() { printf '%s' "${FACTORY_CLAUDE_BIN:-$HOME/.local/bin/claude}"; }

fleet_auth_status() {  # -> "in" | "out" | "unknown: <why>" - `claude auth status` under a kill-after watchdog (by pid, never by name); never fatal
  local cbin tmp pid waited=0 secs="${FACTORY_AUTH_STATUS_SECS:-30}" rc=0 verdict
  cbin="$(fleet_claude_bin)"
  [ -x "$cbin" ] || { printf 'unknown: no claude CLI at %s (FACTORY_CLAUDE_BIN overrides)' "$cbin"; return 0; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/factory-auth.XXXXXX")"
  "$cbin" auth status >"$tmp" 2>&1 </dev/null &
  pid=$!
  while rr_alive "$pid"; do
    if [ "$waited" -ge "$secs" ]; then rr_kill_tree "$pid" TERM; sleep 1; rr_kill_tree "$pid" KILL; rc=124; break; fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null || true
  if [ "$rc" -eq 124 ]; then verdict="unknown: $cbin auth status gave no answer in ${secs}s (its own process tree killed by pid)"
  elif grep -q '"loggedIn":[[:space:]]*true' "$tmp" 2>/dev/null; then verdict="in"
  elif grep -q '"loggedIn":[[:space:]]*false' "$tmp" 2>/dev/null; then verdict="out"
  else verdict="unknown: $cbin auth status printed no loggedIn field"
  fi
  rm -f "$tmp"
  printf '%s' "$verdict"
}

pid_start_epoch() {  # pid_start_epoch <pid> -> the process's start as an epoch (now minus ps etime); nothing when unknown
  local et d=0 h=0 m=0 s=0 rest
  et="$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ' || true)"
  [ -n "$et" ] || return 0
  case "$et" in *-*) d="${et%%-*}"; et="${et#*-}" ;; esac
  case "$et" in
    *:*:*) h="${et%%:*}"; rest="${et#*:}"; m="${rest%%:*}"; s="${rest#*:}" ;;
    *:*)   m="${et%%:*}"; s="${et#*:}" ;;
    *)     s="$et" ;;
  esac
  case "$d$h$m$s" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$(( $(now_s) - (10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s) ))"
}

transcript_root() { printf '%s' "${FACTORY_TRANSCRIPT_ROOT:-$HOME/.claude/projects}"; }
transcript_dir_for() {  # transcript_dir_for <cwd path> -> the CLI's transcript dir for sessions started there (the executor_activity_dirs flattening)
  printf '%s/%s' "$(transcript_root)" "$(printf '%s' "$1" | sed 's#[/.]#-#g')"
}
transcript_newest() {  # transcript_newest <dir> -> the newest top-level session transcript (mtime), or nothing
  local d="$1" listing
  [ -d "$d" ] || return 0
  listing="$(ls -t "$d"/*.jsonl 2>/dev/null || true)"
  printf '%s' "${listing%%$'\n'*}"
}
transcript_named() {  # transcript_named <dir> <session-name> -> the newest transcript (of the newest 40) whose tail carries the session's agent-name line, or nothing
  local d="$1" sname="$2" f n=0 listing
  [ -d "$d" ] || return 0
  listing="$(ls -t "$d"/*.jsonl 2>/dev/null || true)"
  [ -n "$listing" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n+1)); [ "$n" -le 40 ] || break
    # grep WITHOUT -q: it reads the whole tail, so tail never takes a SIGPIPE
    # that pipefail would turn into a miss.
    if tail -n 2000 "$f" 2>/dev/null | grep -aF "\"agentName\":\"$sname\"" >/dev/null 2>&1; then printf '%s' "$f"; return 0; fi
  done <<EOF
$listing
EOF
  return 0
}
transcript_last_entry() {  # transcript_last_entry <jsonl> -> the newest conversation entry (type assistant|user in the line's head) among the last 400 lines
  tail -n 400 "$1" 2>/dev/null | awk '{ h = substr($0, 1, 160); if (h ~ /"type":"(assistant|user)"/) last = $0 } END { if (last != "") print last }' || true
}
login_expired_entry() {  # login_expired_entry <jsonl> -> prints "<basename> at <timestamp>" and returns 0 when its last conversation entry is the CLI's login-expired message; 1 otherwise
  local f="$1" e t
  [ -n "$f" ] && [ -f "$f" ] || return 1
  e="$(transcript_last_entry "$f" || true)"
  [ -n "$e" ] || return 1
  case "${e:0:160}" in *'"type":"assistant"'*) ;; *) return 1 ;; esac
  case "$e" in *'"isApiErrorMessage":true'*) ;; *) return 1 ;; esac
  case "$e" in *'Login expired'*'Please run /login'*) ;; *) return 1 ;; esac
  t="${e#*\"timestamp\":\"}"; t="${t%%\"*}"
  [ "$t" != "$e" ] || t="?"
  printf '%s at %s' "$(basename "$f")" "$t"
  return 0
}
seat_transcript() {  # seat_transcript <worktree> <session-name> -> the seat's transcript: the newest naming the session, else the newest in its dir (the raw path's dir, then the physical path's)
  local wt="$1" sname="$2" d f p
  for p in "$wt" "$(cd "$wt" 2>/dev/null && pwd -P || true)"; do
    [ -n "$p" ] || continue
    d="$(transcript_dir_for "$p")"
    [ -d "$d" ] || continue
    f="$(transcript_named "$d" "$sname")"
    [ -n "$f" ] || f="$(transcript_newest "$d")"
    [ -n "$f" ] || continue
    printf '%s' "$f"
    return 0
  done
  return 0
}
session_login_expired() {  # session_login_expired <transcript> <pids> -> prints "<basename> at <ts>" and returns 0 when the transcript is this live session's (newer than its process) and ends on the login-expired message; 1 otherwise
  local f="$1" pids="$2" p st m entry
  [ -n "$f" ] || return 1
  entry="$(login_expired_entry "$f" || true)"
  [ -n "$entry" ] || return 1
  m="$(stat -f %m "$f" 2>/dev/null || true)"
  for p in $pids; do
    st="$(pid_start_epoch "$p")"
    # The file must be at least as new as the process (120 s of slack): an
    # older file is a predecessor's and says nothing about this session.
    if [ -n "$st" ] && [ -n "$m" ] && [ "$m" -lt $((st - 120)) ]; then return 1; fi
  done
  printf '%s' "$entry"
  return 0
}

logged_out_path() { printf '%s/%s' "$FACTORY" "$LOGGED_OUT_FILE"; }
logged_out_since() {  # the standing FLEET-LOGGED-OUT's first-seen instant, or nothing
  local f; f="$(logged_out_path)"
  [ -f "$f" ] || return 0
  sed -n 's/^since: //p' "$f" 2>/dev/null | head -1 || true
}
logged_out_mark() {  # record the sighting (the first instant never moves); returns 0 when a notification is due (the first sighting, then hourly) and stamps it
  local f since epoch notified now
  f="$(logged_out_path)"; now="$(now_s)"
  since="$(sed -n 's/^since: //p' "$f" 2>/dev/null | head -1 || true)"
  epoch="$(sed -n 's/^epoch: //p' "$f" 2>/dev/null | head -1 || true)"
  notified="$(sed -n 's/^notified: //p' "$f" 2>/dev/null | head -1 || true)"
  [ -n "$since" ] || since="$(now_iso)"
  case "$epoch" in ''|*[!0-9]*) epoch="$now" ;; esac
  case "$notified" in ''|*[!0-9]*) notified=0 ;; esac
  if [ $((now - notified)) -ge "${FACTORY_LOGGED_OUT_NOTIFY_S:-3600}" ]; then
    printf 'since: %s\nepoch: %s\nnotified: %s\n' "$since" "$epoch" "$now" > "$f"
    return 0
  fi
  printf 'since: %s\nepoch: %s\nnotified: %s\n' "$since" "$epoch" "$notified" > "$f"
  return 1
}
logged_out_clear() { rm -f "$(logged_out_path)"; }

fleet_login_check() {  # fleet_login_check <dry:true|false>: sets FLEET_AUTH and prints the pass's login lines; the stamp, the fleet-log append and the notification are skipped under --dry-run
  local dry="$1" since osa loud
  FLEET_AUTH="$(fleet_auth_status)"
  case "$FLEET_AUTH" in
    in)
      since="$(logged_out_since)"
      if [ -z "$since" ]; then
        echo "cli login: logged in ($(fleet_claude_bin) auth status)"
      elif [ "$dry" = true ]; then
        echo "cli login: logged in again (FLEET-LOGGED-OUT stood since $since; dry-run: the stamp $(logged_out_path) stays)"
      else
        logged_out_clear
        fleet_log_line "fleet-doctor $(now_iso) FLEET-LOGGED-OUT cleared: $(fleet_claude_bin) auth status reads logged in again (stood since $since) - a parked LOGGED-OUT seat is replaced under --respawn"
      fi
      ;;
    out)
      since="$(logged_out_since)"; [ -n "$since" ] || since="this pass"
      loud="fleet-doctor $(now_iso) FLEET-LOGGED-OUT (since $since): $(fleet_claude_bin) auth status reads loggedIn false - every seat and the prioritizer die on their next turn (\"$LOGIN_EXPIRED_TEXT\") and NO respawn is made this pass (a successor booted logged out dies on its first turn too); $LOGIN_REMEDY"
      # The loud line: stdout always; the fleet log only on a live pass
      # (--dry-run touches nothing, the log included).
      if [ "$dry" = true ]; then echo "$loud"; else fleet_log_line "$loud"; fi
      if [ "$dry" = true ]; then
        echo "cli login: LOGGED OUT (dry-run: the stamp $(logged_out_path) and the notification are skipped)"
      elif logged_out_mark; then
        osa="${FACTORY_OSASCRIPT_BIN:-osascript}"
        "$osa" -e "display notification \"FLEET-LOGGED-OUT: the seat CLI login expired - $LOGIN_REMEDY\" with title \"Open SaaS fleet doctor\"" >/dev/null 2>&1 || true
        echo "cli login: LOGGED OUT since $(logged_out_since) - stamp $(logged_out_path) written, notification sent"
      else
        echo "cli login: LOGGED OUT since $(logged_out_since) - stamp $(logged_out_path) refreshed (notified within the hour)"
      fi
      ;;
    *)
      echo "cli login: $FLEET_AUTH - the verdicts judge as logged in (a CLI the doctor cannot read never holds the fleet)"
      ;;
  esac
}

branch_status() {  # branch_status <primary> <branch> -> "N ahead / M behind main" | "gone"
  local primary="$1" b="$2" lr
  git -C "$primary" rev-parse -q --verify "refs/heads/$b" >/dev/null 2>&1 || { printf 'gone'; return 0; }
  lr="$(git -C "$primary" rev-list --left-right --count "$b...main" 2>/dev/null || true)"
  [ -n "$lr" ] || { printf '?'; return 0; }
  printf '%s ahead / %s behind main' "${lr%%	*}" "${lr##*	}"
}

done_marker_word() {  # done_marker_word <worker> -> "present" | "absent"
  if [ -f "$TASKS/$1.done" ] || [ -f "$TASKS/sessions-done/$1.done" ]; then printf 'present'; else printf 'absent'; fi
}

seat_kill_named() {  # seat_kill_named <prefix> <seat>: kill the process(es) carrying the seat's session name; prints what it killed
  local prefix="$1" seat="$2" pids p sname
  for sname in "$prefix-executor-$seat" "$prefix-worker-$seat"; do
    pids="$(name_pids "$sname")"
    [ -n "$pids" ] || continue
    info "  killing '$sname' pid(s) $pids (TERM then KILL)"
    fleet_kill_pids $pids
    for p in $pids; do printf '%s ' "$p"; done
  done
}

cmd_seat_roster() {
  local rf of line seat first
  rf="$(roster_path)"; of="$(orphaned_path)"
  if [ ! -s "$rf" ]; then echo "NONE"; return 0; fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    seat="${line%%	*}"
    first="$([ -f "$of" ] && grep "^$seat	" "$of" | head -1 | cut -f2 || true)"
    if [ -n "$first" ]; then printf '%s\tORPHANED since %s\n' "$line" "$first"; else printf '%s\n' "$line"; fi
  done < "$rf"
}

cmd_seat_recreate() {
  local seat="" spawn=true row path old_path root worker branch primary prefix ahead ffword killed bootword adm handf triage cid act p relword
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-spawn) spawn=false ;;
      -*) die "usage: factory.sh seat-recreate <seat> [--no-spawn]" ;;
      *) [ -z "$seat" ] || die "usage: factory.sh seat-recreate <seat> [--no-spawn]"; seat="$(basename "$1")" ;;
    esac
    shift
  done
  [ -n "$seat" ] || die "usage: factory.sh seat-recreate <seat> [--no-spawn]"
  primary="$(fleet_primary)"
  [ -n "$primary" ] || die "seat-recreate: cannot resolve the primary checkout"
  primary="$(cd "$primary" 2>/dev/null && pwd -P || printf '%s' "$primary")"
  prefix="$(project_prefix)"
  root="$(seat_root)" || die "seat-recreate: cannot resolve the seat root"
  row="$(roster_row "$seat")"
  if [ -n "$row" ]; then
    old_path="$(printf '%s' "$row" | cut -f2)"; worker="$(printf '%s' "$row" | cut -f3)"; branch="$(printf '%s' "$row" | cut -f4)"
  else
    old_path=""; worker="claude-$seat"; branch="claude/$seat"
    info "seat-recreate: '$seat' is not on the roster - assuming worker $worker, branch $branch"
  fi
  # A seat lives under the SEAT ROOT (the seat-root section): a rebuilt seat
  # is minted there whatever its roster row said - the old tree is GONE, so
  # nothing is moved under a replica - and a legacy .claude/worktrees row is
  # how the desktop app's GC got it in the first place.
  path="$root/$seat"
  [ "$branch" != "?" ] || branch="claude/$seat"
  [ "$path" != "$primary" ] || die "seat-recreate refused: $seat resolves to the PRIMARY checkout"
  [ -z "$old_path" ] || [ "$old_path" = "$path" ] || [ ! -e "$old_path" ] || die "seat-recreate refused: $old_path exists - this command rebuilds a VANISHED worktree only (a present seat is revived by fleet-doctor --respawn / a hand boot)"
  [ ! -e "$path" ] || die "seat-recreate refused: $path exists - this command rebuilds a VANISHED worktree only (a present seat is revived by fleet-doctor --respawn / a hand boot)"
  relword=""
  if [ -n "$old_path" ] && [ "$old_path" != "$path" ]; then
    relword=" (was $old_path - a seat lives under the seat root $root, outside the desktop app's worktree pool)"
  fi
  echo "seat-recreate $seat: worktree $path$relword, worker $worker, branch $branch"
  # (1) the dead husk: a process carrying the seat's session name with a
  # deleted cwd can never claim again - it would also trip spawn-successor's
  # duplicate guard.
  killed="$(seat_kill_named "$prefix" "$seat")"
  [ -z "$killed" ] || echo "  killed dead-husk pid(s): $killed"
  # (2) the stale git admin entry for THIS seat's path(s) only - the roster's
  # old location and the new one (never a blanket `git worktree prune`:
  # other orphans' admin dirs are forensic evidence).
  for p in "$old_path" "$path"; do
    [ -n "$p" ] || continue   # each path one quoted value: a path may hold spaces
    adm="$(wt_admin_dir "$primary" "$p")"
    if [ -n "$adm" ]; then
      echo "  dropping stale git admin entry $adm (factory-seat: $(cat "$adm/factory-seat" 2>/dev/null || echo none))"
      rm -rf "$adm"
    fi
  done
  mkdir -p "$root" 2>/dev/null || die "seat-recreate: cannot create the seat root $root"
  # (3) the branch: fast-forward to main when nothing of its own is on it.
  if git -C "$primary" rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1; then
    ahead="$(git -C "$primary" rev-list --count "main..$branch" 2>/dev/null || echo '?')"
    if [ "$ahead" = "0" ]; then
      git -C "$primary" branch -f "$branch" main >/dev/null 2>&1 && ffword="fast-forwarded to main (was 0 ahead)" || ffword="fast-forward FAILED - kept as is"
    else
      ffword="kept as is ($ahead commit(s) ahead of main - not fast-forwarded; the successor merges main itself)"
    fi
    echo "  branch $branch: $ffword"
    git -C "$primary" worktree add "$path" "$branch" >/dev/null 2>&1 || die "seat-recreate: git worktree add $path $branch failed (is $branch checked out elsewhere? git -C $primary worktree list)"
  else
    ffword="created from main (branch did not exist)"
    echo "  branch $branch: $ffword"
    git -C "$primary" worktree add -b "$branch" "$path" main >/dev/null 2>&1 || die "seat-recreate: git worktree add -b $branch $path main failed"
  fi
  echo "  worktree added: $path"
  # (4) deps + the keys symlinks.
  if [ "${FACTORY_RECREATE_BOOTSTRAP:-1}" = "0" ]; then
    bootword="skipped (FACTORY_RECREATE_BOOTSTRAP=0)"
  elif [ -x "$path/scripts/bootstrap.sh" ]; then
    if (cd "$path" && ./scripts/bootstrap.sh); then bootword="ok"; else bootword="FAILED (rerun ./scripts/bootstrap.sh in $path before booting the seat)"; fi
  else
    bootword="skipped (no scripts/bootstrap.sh in the tree)"
  fi
  echo "  bootstrap: $bootword"
  # (5) the pin (also re-registers the roster row + the admin tripwire).
  (cd "$path" && cmd_worker_pin "$worker" >/dev/null) || die "seat-recreate: worker-pin failed in $path"
  echo "  pinned: $worker ($path/$PIN_FILE); roster updated"
  # (6) the takeover handoff - the spawn token. A pending file of the seat's
  # own stands (fleet_write_handoff never overwrites).
  cid=""
  for act in "$CLAIMED/$worker"/*.md; do [ -e "$act" ] && cid="$(id_of "$act")"; done
  triage="This seat was RECREATED after its worktree vanished (factory.sh seat-recreate, $(now_iso)): the tree at $path is fresh from branch $branch ($ffword), deps bootstrapped ($bootword), no replica running - your first live task's deploy-all --changed seeds one."
  if [ -n "$cid" ]; then
    triage="$triage You INHERIT claim $cid (tasks/claimed/$worker/, see factory.sh show $cid): judge it from DISK first - git -C $path log --oneline main.., and the archive - COMPLETE (merged, .done written) means archive; PARTIAL (commits on the branch) means verify what exists and finish it; ABSENT means start it clean."
  fi
  handf="$HANDOFF/$seat.md"
  if [ -f "$handf" ]; then
    echo "  handoff: pending file $handf kept as is"
  else
    {
      echo "cd $(shq "$path") && claude --model ${FACTORY_CLAUDE_MODEL:-$FACTORY_CLAUDE_MODEL_DEFAULT} --name '$prefix-executor-$seat'"
      echo
      echo "## Boot prompt"
      echo "Read .claude/skills/mdex-software-factory/SKILL.md. You are a TaskConsumer in executor mode taking over the seat at $path - recreated after its worktree vanished. $triage Work the queue continuously."
    } > "$handf"
    echo "  handoff: wrote $handf (recreated after its worktree vanished)"
  fi
  fleet_log_append "seat-recreate $(now_iso) $seat: worktree $path rebuilt from $branch ($ffword); bootstrap $bootword; husk killed: ${killed:-none}"
  # (7) boot the successor.
  if [ "$spawn" = true ]; then
    if ( cmd_spawn_successor "$seat" ); then echo "  spawned: $prefix-executor-$seat"; elif [ $? -eq 3 ]; then echo "  spawn PENDING (AppleEvent timed out - Terminal may still run it): no hand boot until the spawn-pending stamp clears (fleet-doctor reports it)"; else echo "  spawn FAILED - the handoff file stays on handoff-list: boot by hand ($(head -1 "$handf"))"; fi
  else
    echo "  spawn: skipped (--no-spawn) - boot by hand: $(head -1 "$handf"), then factory.sh handoff-clear $seat"
  fi
  echo "roster:"
  cmd_seat_roster | sed 's/^/  /'
}

cmd_seat_retire() {
  local seat="" dry=false keep_branch=false row path worker branch primary prefix here killed live rcword rmword brword adm handword
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=true ;;
      --keep-branch) keep_branch=true ;;
      -*) die "usage: factory.sh seat-retire <seat> [--dry-run] [--keep-branch]" ;;
      *) [ -z "$seat" ] || die "usage: factory.sh seat-retire <seat> [--dry-run] [--keep-branch]"; seat="$(basename "$1")" ;;
    esac
    shift
  done
  [ -n "$seat" ] || die "usage: factory.sh seat-retire <seat> [--dry-run] [--keep-branch]"
  primary="$(fleet_primary)"
  [ -n "$primary" ] || die "seat-retire: cannot resolve the primary checkout"
  primary="$(cd "$primary" 2>/dev/null && pwd -P || printf '%s' "$primary")"
  prefix="$(project_prefix)"
  row="$(roster_row "$seat")"
  if [ -n "$row" ]; then
    path="$(printf '%s' "$row" | cut -f2)"; worker="$(printf '%s' "$row" | cut -f3)"; branch="$(printf '%s' "$row" | cut -f4)"
  else
    path="$(git -C "$primary" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | grep "/$seat\$" | head -1 || true)"
    [ -n "$path" ] || die "seat-retire refused: '$seat' is neither on the roster (factory.sh seat-roster) nor a git worktree of $primary - nothing to retire"
    worker="$(head -1 "$path/$PIN_FILE" 2>/dev/null | tr -d '[:space:]' || true)"; [ -n "$worker" ] || worker="claude-$seat"
    branch="$(git -C "$path" branch --show-current 2>/dev/null || true)"; [ -n "$branch" ] || branch="?"
    info "seat-retire: '$seat' is not on the roster - resolved worktree $path, worker $worker, branch $branch from git"
  fi
  [ "$path" != "$primary" ] || die "seat-retire refused: $seat resolves to the PRIMARY checkout (law 5) - there is no override"
  here="$(pwd -P 2>/dev/null || pwd)"
  if [ "$here" = "$path" ] || [ "${here#"$path"/}" != "$here" ]; then
    die "seat-retire refused: you are standing INSIDE $path - run it from the primary checkout (a worktree cannot remove itself)"
  fi
  echo "seat-retire $seat: worktree $path$([ -d "$path" ] || echo ' (MISSING - retiring an orphan)'), worker $worker, branch $branch"
  if [ "$dry" = true ]; then
    live="$([ -d "$path" ] && live_cwd_pids "$path" || true)"
    echo "DRY-RUN would: kill $prefix-executor-$seat / $prefix-worker-$seat pid(s) [$(name_pids "$prefix-executor-$seat") $(name_pids "$prefix-worker-$seat")]; $([ -d "$path" ] && echo "replica-recycle in $path; git worktree remove --force $path" || echo "skip the tree (missing)"); drop admin entry $(wt_admin_dir "$primary" "$path" || echo none); $([ "$keep_branch" = true ] && echo "keep branch $branch" || echo "git branch -d $branch"); drop handoff + roster row; append to $(fleet_log_path)${live:+; REFUSAL PENDING: live cwd(s) $live}"
    return 0
  fi
  # (1) the seat's own process(es).
  killed="$(seat_kill_named "$prefix" "$seat")"
  [ -z "$killed" ] || echo "  killed pid(s): $killed"
  if [ -d "$path" ]; then
    # (2) NEVER remove a directory a live process stands in (lsof): the
    # named seat process is gone by now, so anything left is someone else's
    # session (the operator's Desktop sessions in the legacy seat-5 tree).
    live="$(live_cwd_pids "$path")"
    [ -z "$live" ] || die "seat-retire refused: live process(es) have their cwd inside $path: $live - not the seat's own process (that one is already gone); close them first, then rerun"
    # (3) the replica, through the allowlisted door (pin-resolved from the tree).
    if (cd "$path" && export FACTORY_WORKER="$worker" && cmd_replica_recycle 2>&1 | sed 's/^/    | /'); then rcword="recycled"; else rcword="replica-recycle FAILED (see above) - continuing"; fi
    echo "  replica: $rcword"
    # (4) the tree.
    if git -C "$primary" worktree remove --force "$path" >/dev/null 2>&1; then rmword="git worktree remove ok"; else rmword="git worktree remove failed - rm -rf"; fi
    [ ! -e "$path" ] || rm -rf "$path"
    echo "  worktree: $rmword$([ -e "$path" ] && echo ' (STILL PRESENT - remove by hand)' || echo '; gone')"
  else
    rcword="skipped (no tree)"; rmword="skipped (no tree)"
  fi
  adm="$(wt_admin_dir "$primary" "$path")"
  if [ -n "$adm" ]; then rm -rf "$adm"; echo "  git admin entry $adm dropped"; fi
  # (5) the branch: -d is the safety - it refuses an unmerged branch.
  if [ "$keep_branch" = true ] || [ "$branch" = "?" ]; then
    brword="kept"
  elif ! git -C "$primary" rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1; then
    brword="already gone"
  elif git -C "$primary" branch -d "$branch" >/dev/null 2>&1; then
    brword="deleted (was merged)"
  else
    brword="KEPT - unmerged ($(git -C "$primary" rev-list --count "main..$branch" 2>/dev/null || echo '?') commit(s) ahead of main; git branch -D by hand only if you mean it)"
  fi
  echo "  branch $branch: $brword"
  # (6) the runtime records.
  handword="none"; [ -f "$HANDOFF/$seat.md" ] && { rm -f "$HANDOFF/$seat.md"; handword="dropped"; }
  roster_remove "$seat"
  echo "  handoff file: $handword; roster row dropped"
  fleet_log_append "seat-retire $(now_iso) $seat: worker $worker, worktree $path ($rmword), replica $rcword, branch $branch $brword, killed: ${killed:-none}"
  echo "RETIRED $seat (log: $(fleet_log_path))"
  echo "roster:"
  cmd_seat_roster | sed 's/^/  /'
}

# Default stall threshold 65 min (2026-09-24, was 30): the idle watch sleeps
# 55 min (SKILL.md "On idle": watch 3300) and only a factory.sh command stamps
# the heartbeat, so a healthy idle seat is silent for up to ~56 min between
# wakes - the bar the prioritizer already had. A new task wakes every seat
# within 10 s (CHANGED) and its claim stamps the heartbeat, so claimable work
# plus 65 min of silence is still a dead seat, never an idle one.
fleet_doctor_bin() {  # $1 = primary ; the replica doctor to run: BESIDE this factory.sh first (the same checkout's
  # version knows the flags; the launchd job runs the primary's copy, so there they coincide), the primary's as
  # the fallback, nothing when neither exists. FACTORY_DOCTOR_BIN overrides (the selftest's recorder).
  local doctor="${FACTORY_DOCTOR_BIN:-$SELF_DIR/replica-doctor.sh}"
  [ -x "$doctor" ] || doctor="$1/scripts/replica-doctor.sh"
  [ -x "$doctor" ] || return 1
  printf '%s' "$doctor"
}

fleet_drill_orphans() {  # $1 = primary ; the doctor's DRILL-ORPHANS summary (pure ps/lsof/du, read-only) for the header
  { "$(fleet_doctor_bin "$1" 2>/dev/null || echo /nonexistent)" --help 2>&1 | grep -q -- "--drill-orphans"; } || { printf "unprobed (replica-doctor.sh has no --drill-orphans mode here)"; return 0; }   # MULTI/DEX overlay
  local out="" doctor
  doctor="$(fleet_doctor_bin "$1")" || { printf 'unprobed (no scripts/replica-doctor.sh beside factory.sh or at %s)' "$1"; return 0; }
  out="$("$doctor" --drill-orphans 2>/dev/null | sed -n 's/^DRILL-ORPHANS //p' | tail -1)"
  printf '%s' "${out:-unprobed (the doctor printed no DRILL-ORPHANS line)}"
}

fleet_drill_worktrees() {  # $1 = primary ; the doctor's DRILL-WORKTREES summary (read-only) for the header
  { "$(fleet_doctor_bin "$1" 2>/dev/null || echo /nonexistent)" --help 2>&1 | grep -q -- "--drill-worktrees"; } || { printf "unprobed (replica-doctor.sh has no --drill-worktrees mode here)"; return 0; }   # MULTI/DEX overlay
  local out="" doctor
  doctor="$(fleet_doctor_bin "$1")" || { printf 'unprobed (no scripts/replica-doctor.sh beside factory.sh or at %s)' "$1"; return 0; }
  out="$("$doctor" --drill-worktrees 2>/dev/null | sed -n 's/^DRILL-WORKTREES //p' | tail -1)"
  printf '%s' "${out:-unprobed (the doctor printed no DRILL-WORKTREES line)}"
}

# --- drill-worktree-prune (task 1791286192) ---------------------------------
# The hygiene door for the trees the drill-orphan reap leaves behind: an
# upgrade-drill's scratch worktree under a seat's Claude scratchpad whose
# replica is stopped (or never ran) is a REGISTERED worktree of this repo
# that nothing removes - three of them held ~17 GB of pocket-ic state after
# the 2026-10-06 reap, their owning sessions gone. The CANDIDATE set is the
# doctor's (`replica-doctor.sh --drill-worktrees`: every registered worktree
# under the scratchpad rule derived from the primary's path, attributed live
# mains/launchers by lsof, the in-use test incl. .upgrade-drill.pid) so the
# rule lives in one place; this door adds the structural belts and performs
# the git write FROM THE PRIMARY (the one sanctioned primary write besides
# the merge - law 5): never the primary itself, never a tree under a seat
# root (.factory/seats, .claude/worktrees), never a tree carrying
# .factory-worker or on the fleet roster (seat-retire is their door), never
# one with a live replica or a live user, never a tree the caller stands in.
# A dir the harness already GC'd under git leaves a prunable admin entry:
# `git worktree prune` covers it and the output says so. Size freed = the
# state dir's du (the bulk; node_modules rides along unmeasured).
cmd_drill_worktree_prune() {
  local dry=false primary doctor out line path mb verdict detail key pkey seat_root legacy_root here
  local n=0 n_pruned=0 n_refused=0 n_gone=0 kb_freed=0 why rm_word rc did_git=false roster_hit
  case "${1:-}" in
    --dry-run) dry=true ;;
    '') : ;;
    *) die "usage: factory.sh drill-worktree-prune [--dry-run]" ;;
  esac
  primary="$(fleet_primary)"
  [ -n "$primary" ] || die "drill-worktree-prune: cannot resolve the primary checkout (run it from inside the suite repo)"
  primary="$(cd "$primary" 2>/dev/null && pwd -P || printf '%s' "$primary")"
  pkey="$(path_key "$primary")"
  seat_root="$pkey/$SEAT_ROOT_REL"; legacy_root="$pkey/$LEGACY_SEAT_ROOT_REL"
  here="$(path_key "$(pwd -P 2>/dev/null || pwd)")"
  doctor="$(fleet_doctor_bin "$primary")" || die "drill-worktree-prune: no scripts/replica-doctor.sh beside factory.sh or at $primary - the candidate set is the doctor's --drill-worktrees"
  out="$("$doctor" --drill-worktrees 2>&1)" || die "drill-worktree-prune: $doctor --drill-worktrees failed:
$out"
  echo "drill-worktree-prune $(now_iso) primary $primary mode $([ "$dry" = true ] && echo dry-run || echo prune) (candidates: $doctor --drill-worktrees)"
  while IFS="$(printf '\t')" read -r line path mb verdict detail; do
    [ "$line" = "DRILL-WORKTREE" ] && [ -n "$path" ] || continue
    n=$((n + 1))
    key="$(path_key "$path")"
    # -- the structural belts (by construction the doctor's rule admits none of these; they stay) --
    why=""
    if [ "$key" = "$pkey" ]; then why="the PRIMARY checkout (law 5)"
    elif [ "${key#"$seat_root"/}" != "$key" ] || [ "${key#"$legacy_root"/}" != "$key" ]; then why="under a seat root ($SEAT_ROOT_REL / $LEGACY_SEAT_ROOT_REL) - seat-retire is the door"
    elif [ -f "$path/$PIN_FILE" ]; then why="carries $PIN_FILE ($(head -1 "$path/$PIN_FILE" 2>/dev/null | tr -d '[:space:]')) - a seat; seat-retire is the door"
    elif [ "$here" = "$key" ] || [ "${here#"$key"/}" != "$here" ]; then why="you are standing INSIDE it - a worktree cannot remove itself; run from elsewhere"
    else
      roster_hit=""
      while IFS="$(printf '\t')" read -r rseat rpath rrest; do
        [ -n "$rpath" ] || continue
        [ "$(path_key "$rpath")" = "$key" ] && roster_hit="$rseat"
      done <<EOF
$(cat "$(roster_path)" 2>/dev/null || true)
EOF
      [ -z "$roster_hit" ] || why="on the fleet roster as seat '$roster_hit' - seat-retire is the door"
    fi
    if [ -n "$why" ]; then
      n_refused=$((n_refused + 1)); echo "REFUSED $path: $why"; continue
    fi
    case "$verdict" in
      prunable) : ;;
      gone)
        n_gone=$((n_gone + 1))
        if [ "$dry" = true ]; then echo "WOULD PRUNE admin entry for $path: $detail"; else did_git=true; echo "PRUNE admin entry for $path: $detail (git worktree prune below)"; fi
        continue ;;
      *) n_refused=$((n_refused + 1)); echo "REFUSED $path: $verdict - $detail"; continue ;;
    esac
    if [ "$dry" = true ]; then
      echo "WOULD PRUNE $path (state ${mb} MB; $detail)"
      kb_freed=$((kb_freed + mb * 1024)); n_pruned=$((n_pruned + 1))
      continue
    fi
    # -- the removal, from the primary: --force once (dirty/untracked), twice for a locked tree, rm -rf last --
    rc=0; rm_word=""
    if git -C "$primary" worktree remove --force "$path" >/dev/null 2>&1; then rm_word="git worktree remove --force ok"
    elif git -C "$primary" worktree remove --force --force "$path" >/dev/null 2>&1; then rm_word="git worktree remove --force --force ok (the tree was locked)"
    else rm_word="git worktree remove refused"; fi
    if [ -e "$path" ]; then
      rm -rf "$path" 2>/dev/null || true
      if [ -e "$path" ]; then rm_word="$rm_word; rm -rf left it PRESENT - remove by hand"; else rm_word="$rm_word; rm -rf (no live cwd, no attributed process)"; fi
    fi
    did_git=true
    if [ -e "$path" ]; then
      n_refused=$((n_refused + 1)); echo "FAILED $path (state ${mb} MB): $rm_word"
    else
      n_pruned=$((n_pruned + 1)); kb_freed=$((kb_freed + mb * 1024)); echo "PRUNED $path (state ${mb} MB freed; $rm_word)"
    fi
  done <<EOF
$out
EOF
  if [ "$did_git" = true ]; then
    if git -C "$primary" worktree prune >/dev/null 2>&1; then echo "git worktree prune: ok (stale admin entries dropped)"; else echo "git worktree prune: FAILED - run it by hand from $primary"; fi
  fi
  if [ "$n" -eq 0 ]; then
    echo "DRILL-WORKTREE-PRUNE nothing to do: no registered worktree sits under this project's scratchpads"
  elif [ "$dry" = true ]; then
    echo "DRILL-WORKTREE-PRUNE dry-run: $n_pruned of $n would be removed ($(awk -v kb="$kb_freed" 'BEGIN { printf "%.1f", kb / 1048576 }') GB of state)$([ "$n_gone" -gt 0 ] && echo ", $n_gone admin entr$([ "$n_gone" -eq 1 ] && echo y || echo ies) pruned"), $n_refused refused - nothing touched"
  else
    echo "DRILL-WORKTREE-PRUNE pruned $n_pruned of $n ($(awk -v kb="$kb_freed" 'BEGIN { printf "%.1f", kb / 1048576 }') GB of state freed)$([ "$n_gone" -gt 0 ] && echo ", $n_gone admin entr$([ "$n_gone" -eq 1 ] && echo y || echo ies) pruned"), $n_refused refused"
    fleet_log_append "drill-worktree-prune $(now_iso): pruned $n_pruned of $n ($(awk -v kb="$kb_freed" 'BEGIN { printf "%.1f", kb / 1048576 }') GB of state), $n_gone admin entries, $n_refused refused"
  fi
}

cmd_fleet_doctor() {
  local stale_min="${FACTORY_FLEET_STALE_MIN:-65}" respawn=false dry=false primary prefix ref now claimable
  local wt seat worker sname pids last lsrc idle claim cid hand verdict note loc n_seat=0 n_stalled=0 n_unmanned=0
  local board pri_pids pri_idle pri_stale pri_verdict act pend pri_boot pri_lo
  local seen="" row rpath rbranch n_orphan=0 first husk pm adm parent pmt
  local n_loggedout=0 lo tf reason
  local wts=()
  FLEET_AUTH=""
  [ "${FACTORY_FLEET_RESPAWN:-}" = "1" ] && respawn=true
  while [ $# -gt 0 ]; do
    case "$1" in
      --stale-min) shift; stale_min="${1:-}" ;;
      --respawn) respawn=true ;;
      --dry-run) dry=true ;;
      --launchd-plist) fleet_launchd_plist "$(fleet_primary)" "$(project_prefix)"; return 0 ;;
      *) die "usage: factory.sh fleet-doctor [--stale-min N] [--respawn] [--dry-run] [--launchd-plist]" ;;
    esac
    shift
  done
  case "$stale_min" in ''|*[!0-9]*) die "fleet-doctor: --stale-min expects minutes" ;; esac
  [ "$stale_min" -ge 1 ] || stale_min=1
  primary="$(fleet_primary)"
  [ -n "$primary" ] || die "fleet-doctor: cannot resolve the primary checkout (run it from inside the suite repo)"
  primary="$(cd "$primary" 2>/dev/null && pwd -P || printf '%s' "$primary")"
  prefix="$(project_prefix)"
  now="$(now_s)"
  claimable="$(fleet_claimable)"
  ref="$(mktemp "${TMPDIR:-/tmp}/factory-fleet.XXXXXX")"
  touch -t "$(date -r $((now - stale_min * 60)) +%Y%m%d%H%M.%S)" "$ref"
  echo "fleet-doctor $(now_iso) threshold ${stale_min}m claimable-queue $claimable mode $([ "$respawn" = true ] && echo respawn || echo report-only)$([ "$dry" = true ] && echo ' (dry-run)')"
  echo "fsevents restarts: $(fsevents_ledger_summary) - unattended fseventsd restarts on record (ledger $(fsevents_ledger_path))"
  # Drill orphans (task 1791284696): upgrade-drill replicas left under this
  # project's Claude scratchpads - the doctor's fourth class, counted here so
  # the console's inbox sees them; the doctor's --reap stops the unused ones.
  echo "drill orphans: $(fleet_drill_orphans "$primary")"
  # Drill worktrees (task 1791286192): the registered scratch worktrees those
  # replicas ran in - they outlive the reap; drill-worktree-prune removes the
  # prunable ones (no live replica, no live user) from the primary.
  echo "drill worktrees: $(fleet_drill_worktrees "$primary")"
  fleet_fsevents_check "$primary" "$dry"
  # The CLI login pre-check (task 1792504454, the CLI login section): sets
  # FLEET_AUTH for the pass - "out" holds every respawn below and turns the
  # summary into FLEET-LOGGED-OUT; the per-seat rows still print.
  fleet_login_check "$dry"
  # One worktree per line of git's porcelain, each path whole: a primary under
  # a folder with spaces (or [ * ?) must not split into fragments no seat
  # lives at, which read every present seat ORPHANED.
  while IFS= read -r wt; do
    [ -z "$wt" ] || wts+=("$wt")
  done <<EOF
$(git -C "$primary" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' || true)
EOF
  for wt in ${wts[@]+"${wts[@]}"}; do
    [ -d "$wt" ] || continue
    [ "$(cd "$wt" 2>/dev/null && pwd -P)" = "$primary" ] && continue
    [ -f "$wt/$PIN_FILE" ] || continue        # unpinned worktrees are not seats
    # MULTI/DEX overlay: the OPERATOR seat is pinned (claude-operator) so its
    # claims resolve, but it is not a consumer - no verdict, never respawned
    # as an executor (SKILL.md Operator seat).
    case "$(head -1 "$wt/$PIN_FILE" 2>/dev/null | tr -d '[:space:]')/$(basename "$wt")" in operator/*|claude-operator/*|*/operator) continue ;; esac
    n_seat=$((n_seat+1))
    seat="$(basename "$wt")"
    worker="$(head -1 "$wt/$PIN_FILE" 2>/dev/null | tr -d '[:space:]')"
    seen="$seen $seat "
    # The roster: adopt a pinned worktree the roster does not know yet (a
    # present tree only - adoption never invents a seat), and a seat that
    # was ORPHANED and is back (recreated / re-pinned) forgets its mark.
    if [ -z "$(roster_row "$seat")" ]; then
      roster_register "$wt" "$worker"
      info "roster: adopted $seat ($worker) - pinned worktree not on the roster yet"
    else
      orphaned_forget "$seat"
    fi
    # The belt against the desktop app's untracked-dir GC (the seat-root
    # section): every pass re-drops the keep sentinel, so a running fleet
    # converges with no seat action, and a legacy-located seat is named.
    # (--dry-run touches nothing, the sentinel included.)
    [ "$dry" = true ] || seat_keep_sentinel "$wt"
    loc=""
    if seat_legacy_located "$wt"; then
      if [ -e "$wt/$KEEP_SENTINEL" ]; then loc="$KEEP_SENTINEL in place"; else loc="$KEEP_SENTINEL MISSING - the next non-dry pass drops it"; fi
      loc="legacy-location $LEGACY_SEAT_ROOT_REL (desktop-app GC root; $loc; moves to $SEAT_ROOT_REL at its next seat-recreate)"
    fi
    sname="$prefix-executor-$seat"
    pids="$(name_pids "$sname")"
    if [ -z "$pids" ]; then
      pids="$(name_pids "$prefix-worker-$seat")"
      [ -n "$pids" ] && sname="$prefix-worker-$seat"
    fi
    last="$(fleet_last_write "$wt" "$ref")"
    lsrc="${last#*$'\t'}"; last="${last%%$'\t'*}"   # "<epoch>\t<source>" (task 1792601787) - cmd_executor_watch's split; idle keeps the epoch
    if [ -n "$last" ]; then idle=$(( (now - last) / 60 )); else idle="?"; fi
    # The newest-write SOURCE rides the row's NOTE, after today's words (an
    # ACTIVE row's note is exactly this) - executor-watch's EXECUTOR-STALE
    # shape, so a false ACTIVE or STALLED is diagnosable from the fleet-doctor
    # log alone. Never a new tab-separated column and never ahead of the
    # existing words: the layout <verdict>\t<seat>\t<worker>\tidle <n>m\tpid
    # <p>\tclaim <id>\t<note> and every printed word are a compat surface (the
    # selftest's prefix assertions, the console's inbox check, the external
    # factory app that drives factory.sh as a CLI).
    if [ -n "$last" ]; then lsrc="newest write $(date -u -r "$last" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "epoch $last") from: $lsrc"; else lsrc="newest write: none (no heartbeat, git index, harness activity dir, guard log or in-window tree file)"; fi
    claim=""; cid=""
    for act in "$CLAIMED/$worker"/*.md; do [ -e "$act" ] && { claim="$act"; cid="$(id_of "$act")"; }; done
    hand=""; [ -f "$HANDOFF/$seat.md" ] && hand="handoff-pending"
    note=""
    # Spawn-pending (task 1789588684): a manned seat spends its stamp; an
    # unmanned one with a live stamp is reported, never respawned - the
    # queued AppleEvent may still boot it.
    pend=""
    if [ -n "$pids" ]; then
      [ "$dry" = true ] || spawn_pending_clear "$seat"
    else
      pend="$(spawn_pending_since "$seat")"
    fi
    # LOGGED-OUT (task 1792504454): a live process whose own transcript ends
    # on the CLI's login-expired message - it reads ACTIVE by every write
    # signal (boot-exec drops the boot prompt into the tree), so the
    # transcript is the only witness. Judged before the idle ladder.
    lo=""
    if [ -n "$pids" ]; then
      tf="$(seat_transcript "$wt" "$sname")"
      lo="$(session_login_expired "$tf" "$pids" || true)"
    fi
    if [ -z "$pids" ] && [ -n "$pend" ]; then
      verdict="UNMANNED"; n_unmanned=$((n_unmanned+1))
      note="spawn pending since $pend, Terminal AppleEvents timing out - check Terminal: a modal, a hung tab, or Automation permission (no respawn until $(spawn_pending_file "$seat") expires, FACTORY_SPAWN_PENDING_TTL default 6h, or the process appears)${hand:+; $hand}"
    elif [ -z "$pids" ]; then
      verdict="UNMANNED"; n_unmanned=$((n_unmanned+1))
      note="no process named $sname${hand:+; $hand}"
    elif [ -n "$lo" ]; then
      verdict="LOGGED-OUT"; n_loggedout=$((n_loggedout+1))
      note="parked on an expired CLI login - its last transcript entry is the CLI's \"$LOGIN_EXPIRED_TEXT\" message ($lo)"
      case "$FLEET_AUTH" in
        out) note="$note; FLEET-LOGGED-OUT: $LOGIN_REMEDY - the next --respawn pass then replaces it" ;;
        in)  note="$note; the login is back but a parked session never re-reads it: replaced under --respawn$([ "$respawn" = true ] || echo " (report-only now: kill pid $pids and factory.sh spawn-successor $seat by hand)")" ;;
        *)   note="$note; auth status unreadable this pass - report-only" ;;
      esac
      note="$note${hand:+; $hand}"
    elif [ "$idle" != "?" ] && [ "$idle" -lt "$stale_min" ]; then
      verdict="ACTIVE"
    elif [ -n "$cid" ] || [ "$claimable" -gt 0 ]; then
      verdict="STALLED"; n_stalled=$((n_stalled+1))
      note="silent ${idle}m with $([ -n "$cid" ] && echo "claim $cid held" || echo "$claimable claimable task(s) queued") - dead, not idle"
    else
      verdict="QUIET"
      note="silent ${idle}m, nothing claimable - healthy idle or parked, undecidable until work arrives"
    fi
    [ -z "$loc" ] || note="${note:+$note; }$loc"
    note="${note:+$note; }$lsrc"
    printf '%s\t%s\t%s\tidle %sm\tpid %s\tclaim %s\t%s\n' "$verdict" "$seat" "$worker" "$idle" "${pids:-none}" "${cid:-none}" "$note"
    if [ "$respawn" = true ] && [ -n "$pend" ]; then
      info "  spawn pending since $pend - no respawn (the timed-out AppleEvent may still boot $sname; stamp $(spawn_pending_file "$seat"))"
    elif [ "$respawn" = true ] && [ "$FLEET_AUTH" = "out" ] && { [ "$verdict" = "STALLED" ] || [ "$verdict" = "UNMANNED" ] || [ "$verdict" = "LOGGED-OUT" ]; }; then
      # FLEET-LOGGED-OUT holds every respawn of the pass: a successor booted
      # logged out dies on its first turn (the 12:59Z / 13:44Z passes of
      # 2026-10-20 each revived 8 seats that way). One login heals the lot.
      info "  held: FLEET-LOGGED-OUT - no respawn of $seat this pass (a successor booted logged out dies on its first turn); $LOGIN_REMEDY"
    elif [ "$respawn" = true ] && { [ "$verdict" = "STALLED" ] || [ "$verdict" = "UNMANNED" ] || { [ "$verdict" = "LOGGED-OUT" ] && [ "$FLEET_AUTH" = "in" ]; }; }; then
      # A LOGGED-OUT seat is REPLACED only once auth status reads logged in
      # again (never on "unknown"): the same handoff + kill-by-pid + spawn
      # path as a STALLED seat, the handoff naming the reason.
      reason=""; [ "$verdict" = "LOGGED-OUT" ] && reason="login"
      if [ "$dry" = true ]; then
        info "  would: $([ -f "$HANDOFF/$seat.md" ] && echo "keep the pending handoff" || echo "write takeover handoff $HANDOFF/$seat.md")$([ -n "$pids" ] && echo "; kill parked pid(s) $pids (TERM then KILL)"); spawn-successor $seat$([ "$reason" = "login" ] && echo " (replacing the logged-out session: the login is back)")"
        continue
      fi
      fleet_write_handoff "$seat" "$wt" "$sname" "$worker" "$cid" "$idle" "$reason"
      if [ -n "$pids" ]; then
        info "  killing parked $sname pid(s) $pids$([ "$reason" = "login" ] && echo " (parked on the expired login; the login is back)")"
        fleet_kill_pids $pids
      fi
      # Subshell: a die inside the spawn ends THIS seat's revive, not the
      # pass (the 2026-09-16 storm's passes each died at the spawn's die).
      if ( cmd_spawn_successor "$seat" ); then
        info "  revived $seat"
      elif [ $? -eq 3 ]; then
        info "  respawn of $seat PENDING (AppleEvent timed out - Terminal may still run it): no hand boot; the next pass reports it until the stamp clears"
      else
        info "  respawn of $seat FAILED - the handoff file stays on handoff-list for a hand boot"
      fi
    fi
  done
  # ORPHANED: a roster seat the walk did not see - its worktree is gone (or
  # no longer a pinned linked worktree). Never respawned here (no tree to
  # boot into): the line carries everything the operator needs to decide
  # between seat-recreate and seat-retire, plus the forensic anchors.
  for seat in $(roster_seats); do
    case "$seen" in *" $seat "*) continue ;; esac
    row="$(roster_row "$seat")"
    rpath="$(printf '%s' "$row" | cut -f2)"; worker="$(printf '%s' "$row" | cut -f3)"; rbranch="$(printf '%s' "$row" | cut -f4)"
    n_orphan=$((n_orphan+1))
    first="$(orphaned_mark "$seat")"
    pids="$(name_pids "$prefix-executor-$seat")"
    [ -n "$pids" ] || pids="$(name_pids "$prefix-worker-$seat")"
    if [ -n "$pids" ]; then husk="process pid $pids ALIVE with no tree - a dead husk that can never claim (seat-recreate/seat-retire kill it)"; else husk="no process"; fi
    cid=""
    for act in "$CLAIMED/$worker"/*.md; do [ -e "$act" ] && cid="$(id_of "$act")"; done
    pm="$(wt_prunable "$primary" "$rpath")"
    adm="$(wt_admin_dir "$primary" "$rpath")"
    if [ -n "$adm" ]; then adm="present ($adm: an rm -rf, not git worktree remove; factory-seat $(cat "$adm/factory-seat" 2>/dev/null || echo unset))"; else adm="absent (git worktree remove or prune ran)"; fi
    parent="$(dirname "$rpath")"
    pmt="$(stat -f %m "$parent" 2>/dev/null || true)"
    if [ -n "$pmt" ]; then pmt="$(date -u -r "$pmt" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$pmt")"; else pmt="?"; fi
    if [ -d "$rpath" ]; then note="directory $rpath exists but is no longer a pinned git worktree"; else note="worktree $rpath MISSING"; fi
    note="$note since $first (first pass that saw it); $husk; branch ${rbranch:-?} $(branch_status "$primary" "${rbranch:-?}"); .done $(done_marker_word "$worker"); git worktree list prunable: $pm; git admin dir $adm; parent $parent mtime $pmt (brackets the deletion) - remedy: factory.sh seat-recreate $seat (rebuild) or seat-retire $seat (drop)"
    printf '%s\t%s\t%s\tidle -\tpid %s\tclaim %s\t%s\n' "ORPHANED" "$seat" "$worker" "${pids:-none}" "${cid:-none}" "$note"
  done
  # The prioritizer: no worktree; its token is tasks/handoff/prioritizer.md
  # (written by prioritizer-boot, cleared by the booted prioritizer) and its
  # pass regenerates the board, so the board's age is its heartbeat. Its
  # watch sleeps up to an hour by design, so the bar is the larger of the
  # threshold and 65 min.
  # On a HOSTED checkout the role is RETIRED as a session - the canister runs
  # the pass itself (SKILL.md "Role changes in hosted mode"; the Operator
  # guide boots ONLY consumers) - so no verdict is judged and no boot line is
  # printed: ONE informational HOSTED row stands in its place. It is not one
  # of the five verdicts (the poller's fleetVerdicts admits only those, so it
  # never reaches the Fleet page) and it never counts toward the summary
  # (task 1791137234; iig-ai's twin 1791133702 landed first).
  # LOCAL mode (task 1792506027): the row keeps its shape (the external
  # factory app drives this CLI and parses it), the UNMANNED note names the
  # door - `boot: scripts/factory.sh prioritizer-boot` - and --respawn
  # REVIVES an UNMANNED or STALLED prioritizer exactly like a seat: the
  # parked pid(s) killed BY PID (TERM then KILL, never by name), then
  # prioritizer-boot in a subshell (a die ends that revive, not the pass;
  # exit 3 = PENDING, no hand boot), the spawn-pending stamp keyed
  # "prioritizer" holding respawns like a seat's. Before this every fleet
  # revive kept one hand step (the paste line this note used to carry).
  if hosted_mode; then
    printf 'HOSTED\tprioritizer\t-\tboard -\tpid -\tclaim -\t%s\n' "the canister's pass (no session on this machine)"
  else
    sname="$prefix-prioritizer"
    pri_pids="$(name_pids "$sname")"
    board="$FACTORY/index.md"
    pri_stale="$stale_min"; [ "$pri_stale" -lt 65 ] && pri_stale=65
    if [ -f "$board" ]; then pri_idle=$(( (now - $(stat -f %m "$board")) / 60 )); else pri_idle="?"; fi
    hand=""; [ -f "$HANDOFF/prioritizer.md" ] && hand="handoff-pending"
    # Spawn-pending (task 1789588684), the seat rule: a manned prioritizer
    # spends its stamp; an unmanned one with a live stamp is reported, never
    # respawned - the queued AppleEvent may still boot it.
    pend=""
    if [ -n "$pri_pids" ]; then
      [ "$dry" = true ] || spawn_pending_clear prioritizer
    else
      pend="$(spawn_pending_since prioritizer)"
    fi
    # LOGGED-OUT (task 1792504454): its transcript lives in the PRIMARY's
    # transcript dir beside the operator's own sessions, so only the file
    # whose agent-name line names its session counts (no newest fallback).
    # Held / replaced under --respawn exactly like a seat (below).
    pri_lo=""
    if [ -n "$pri_pids" ]; then
      tf="$(transcript_named "$(transcript_dir_for "$primary")" "$sname")"
      pri_lo="$(session_login_expired "$tf" "$pri_pids" || true)"
    fi
    if [ -z "$pri_pids" ] && [ -n "$pend" ]; then
      pri_verdict="UNMANNED"; note="spawn pending since $pend, Terminal AppleEvents timing out - check Terminal: a modal, a hung tab, or Automation permission (no respawn until $(spawn_pending_file prioritizer) expires, FACTORY_SPAWN_PENDING_TTL default 6h, or the process appears)${hand:+; $hand}"
    elif [ -z "$pri_pids" ]; then
      pri_verdict="UNMANNED"; note="no process named $sname - boot: scripts/factory.sh prioritizer-boot${hand:+; $hand}"
    elif [ -n "$pri_lo" ]; then
      pri_verdict="LOGGED-OUT"; n_loggedout=$((n_loggedout+1))
      note="parked on an expired CLI login - its last transcript entry is the CLI's \"$LOGIN_EXPIRED_TEXT\" message ($pri_lo)"
      case "$FLEET_AUTH" in
        out) note="$note; FLEET-LOGGED-OUT: $LOGIN_REMEDY - the next --respawn pass then replaces it" ;;
        in)  note="$note; the login is back but a parked session never re-reads it: replaced under --respawn$([ "$respawn" = true ] || echo " (report-only now: kill pid $pri_pids and scripts/factory.sh prioritizer-boot by hand)")" ;;
        *)   note="$note; auth status unreadable this pass - report-only" ;;
      esac
      note="$note${hand:+; $hand}"
    elif [ "$pri_idle" != "?" ] && [ "$pri_idle" -ge "$pri_stale" ] && [ "$claimable" -gt 0 ]; then
      pri_verdict="STALLED"; n_stalled=$((n_stalled+1)); note="board not regenerated for ${pri_idle}m with $claimable claimable task(s) queued - dead, not idle${hand:+; $hand}"
    elif [ "$pri_idle" != "?" ] && [ "$pri_idle" -ge "$pri_stale" ]; then
      pri_verdict="QUIET"; note="board ${pri_idle}m old, nothing claimable${hand:+; $hand}"
    else
      pri_verdict="ACTIVE"; note="$hand"
    fi
    printf '%s\tprioritizer\t-\tboard %sm\tpid %s\tclaim -\t%s\n' "$pri_verdict" "$pri_idle" "${pri_pids:-none}" "$note"
    if [ "$respawn" = true ] && [ -n "$pend" ]; then
      info "  spawn pending since $pend - no respawn (the timed-out AppleEvent may still boot $sname; stamp $(spawn_pending_file prioritizer))"
    elif [ "$respawn" = true ] && [ "$FLEET_AUTH" = "out" ] && { [ "$pri_verdict" = "STALLED" ] || [ "$pri_verdict" = "UNMANNED" ] || [ "$pri_verdict" = "LOGGED-OUT" ]; }; then
      # FLEET-LOGGED-OUT holds the prioritizer's revive like every seat's.
      info "  held: FLEET-LOGGED-OUT - no respawn of the prioritizer this pass (a successor booted logged out dies on its first turn); $LOGIN_REMEDY"
    elif [ "$respawn" = true ] && { [ "$pri_verdict" = "STALLED" ] || [ "$pri_verdict" = "UNMANNED" ] || { [ "$pri_verdict" = "LOGGED-OUT" ] && [ "$FLEET_AUTH" = "in" ]; }; }; then
      # A LOGGED-OUT prioritizer is REPLACED once auth status reads logged
      # in again (never on "unknown"): the same kill-by-pid + prioritizer-boot.
      if [ "$dry" = true ]; then
        info "  would: $([ -n "$pri_pids" ] && echo "kill parked pid(s) $pri_pids (TERM then KILL); ")prioritizer-boot$([ "$pri_verdict" = "LOGGED-OUT" ] && echo " (replacing the logged-out session: the login is back)")"
      else
        if [ -n "$pri_pids" ]; then
          info "  killing parked $sname pid(s) $pri_pids$([ "$pri_verdict" = "LOGGED-OUT" ] && echo " (parked on the expired login; the login is back)")"
          fleet_kill_pids $pri_pids
        fi
        # Subshell: a die inside the boot ends THIS revive, not the pass.
        if ( cmd_prioritizer_boot ); then
          info "  revived prioritizer"
        elif [ $? -eq 3 ]; then
          info "  respawn of the prioritizer PENDING (AppleEvent timed out - Terminal may still run it): no hand boot; the next pass reports it until the stamp clears"
        else
          info "  respawn of the prioritizer FAILED - boot by hand: scripts/factory.sh prioritizer-boot"
        fi
      fi
    fi
  fi
  rm -f "$ref"
  # The summary (the last line): FLEET-LOGGED-OUT outranks the rest - it is
  # the one cause with a one-line remedy, and every respawn was held.
  if [ "$FLEET_AUTH" = "out" ]; then
    echo "FLEET-LOGGED-OUT $n_loggedout logged out, $n_stalled stalled, $n_unmanned unmanned of $n_seat seats$([ "$n_orphan" -gt 0 ] && echo " (+ $n_orphan missing)") - every respawn held this pass; $LOGIN_REMEDY"
  elif [ "$n_orphan" -gt 0 ]; then
    echo "FLEET-DEGRADED $n_orphan missing of $((n_seat + n_orphan)) seats ($n_stalled stalled, $n_unmanned unmanned$([ "$n_loggedout" -gt 0 ] && echo ", $n_loggedout logged-out"); a vanished worktree is never respawned: factory.sh seat-recreate <seat> rebuilds it, seat-retire <seat> drops it from the roster)"
  elif [ "$n_stalled" -eq 0 ] && [ "$n_unmanned" -eq 0 ] && [ "$n_loggedout" -eq 0 ]; then
    echo "FLEET-OK seats $n_seat"
  else
    echo "FLEET-STALLED $n_stalled stalled, $n_unmanned unmanned$([ "$n_loggedout" -gt 0 ] && echo ", $n_loggedout logged-out (parked on the expired CLI login: replaced under --respawn once auth status reads logged in)") of $n_seat seats$([ "$respawn" = true ] || echo ' (report-only: --respawn or FACTORY_FLEET_RESPAWN=1 revives seats)')"
  fi
}

# --- operator signal commands -----------------------------------------------

cmd_signal() {
  local who="${1:-}" body="${2:-}" stage target
  [ -n "$who" ] && [ -n "$body" ] || die "usage: factory.sh signal <worker|all> <text|file.md>"
  who="$(basename "$who" .md)"          # a path or a .md suffix is a typo, not an address
  case "$who" in ''|.|..) die "bad signal addressee '${1:-}'" ;; esac
  target="$SIGNAL/$who.md"
  stage="$SIGNAL/.stage.$$"
  # A standing order is never overwritten: a second signal APPENDS, so an order
  # the seat has not acknowledged yet cannot be lost under a later one. The
  # compose and the mv run under the writers' lock, so a second writer composes
  # from the first one's file, never from the same old one.
  signal_lock
  {
    if [ -e "$target" ]; then cat "$target"; echo; fi
    echo "# Operator signal to $who ($(now_iso))"
    echo
    if [ -f "$body" ]; then cat "$body"; else printf '%s\n' "$body"; fi
  } > "$stage"
  if [ -e "$target" ]; then info "appended to the standing signal for $who"; fi
  # A (re-)sent broadcast resets the ack ledger before the file lands. The
  # reset alone did not keep the new order unread: a seat acking the OLD text
  # between the reset and the mv left a marker the new text then counted. Each
  # marker names the generation it acked (signal_gen), so that ack stays the
  # old text's and the new one blocks the seat until it is acked in turn.
  if [ "$who" = "all" ] && [ -d "$SIGNAL/all.acked" ]; then
    rm -rf "$SIGNAL/all.acked"
    info "broadcast ack ledger reset - every seat must acknowledge the new order"
  fi
  mv "$stage" "$target" || { rm -f "$stage"; die "cannot write $target"; }
  signal_unlock
  echo "$target"
}

signal_ack_ledger() {  # -> "acked N: w1 w2 ..." for the standing broadcast (N = 0 -> "acked 0")
  local m n=0 names=""
  for m in "$SIGNAL"/all.acked/*; do
    signal_acked "$(basename "$m")" || continue   # a marker of an older text acks nothing standing
    n=$((n+1)); names="$names $(basename "$m")"
  done
  printf 'acked %d' "$n"
  [ -n "$names" ] && printf ':%s' "$names"
  return 0
}

cmd_signal_list() {
  local f now n=0 line
  now="$(now_s)"
  for f in "$SIGNAL"/*.md; do
    n=$((n+1))
    line="$(file_age_line "$f" "$now")"
    # The broadcast line carries its ack ledger: who has already acknowledged.
    if [ "$(basename "$f")" = "all.md" ]; then line="$line	$(signal_ack_ledger)"; fi
    printf '%s\n' "$line"
  done
  [ "$n" -gt 0 ] || echo "NONE"
}

cmd_signal_clear() {
  local name="${1:-}" f want="" shown="$FACTORY/signal-shown" seen cur
  [ -n "$name" ] || die "usage: factory.sh signal-clear <worker|all> [--if '<crc> <size>']"
  if [ "${2:-}" = "--if" ]; then
    want="${3:-}"
    [[ "$want" =~ ^[0-9]+\ [0-9]+$ ]] || die "usage: factory.sh signal-clear <worker> --if '<crc> <size>' (what cksum printed for the order you read)"
    [ -z "${4:-}" ] || die "usage: factory.sh signal-clear <worker> --if '<crc> <size>'"
  elif [ -n "${2:-}" ]; then
    die "usage: factory.sh signal-clear <worker|all> [--if '<crc> <size>']"
  fi
  name="$(basename "$name" .md)"
  f="$SIGNAL/$name.md"
  if [ "$name" = "all" ]; then
    [ -z "$want" ] || die "signal-clear all takes no --if: it is the operator's hard delete of the broadcast and its ledger"
    # The operator's hard delete: the broadcast AND its ack ledger go together,
    # under the writers' lock, so a send in flight lands before it or after it.
    signal_lock
    [ -f "$f" ] || [ -d "$SIGNAL/all.acked" ] || die "no signal addressed to 'all' (factory.sh signal-list)"
    rm -f "$f"; rm -rf "$SIGNAL/all.acked"
    signal_unlock
    echo "cleared all"
    return 0
  fi
  if [ -f "$f" ]; then
    # The worker's own order. Deleting it acks it, and only the text that was
    # read: what the caller names with --if, else what the claim gate last
    # showed this worker of its own, else (never shown one) what stands.
    # An order appended after that text stands on; any other text is not the
    # one read, and nothing is cleared. Under the writers' lock: a send lands
    # before the check or after the clear.
    signal_lock
    if [ -f "$f" ]; then
      cur="$(cksum < "$f")"
      if [ -n "$want" ]; then seen="$want"
      elif [ -f "$shown/$name.own" ]; then seen="$(cksum < "$shown/$name.own")"
      else seen="$cur"
      fi
      if [ "$seen" = "$cur" ]; then
        rm -f "$f" "$shown/$name.own"   # the copy is used up with the order it showed
        signal_unlock
        echo "cleared $name"
        if [ -e "$SIGNAL/all.md" ] && ! signal_acked "$name"; then
          info "a broadcast (all.md) still addresses '$name' - carry it out, then: factory.sh signal-clear $name"
        fi
        return 0
      fi
      if [ "${cur##* }" -gt "${seen##* }" ] && [ "$(head -c "${seen##* }" "$f" | cksum)" = "$seen" ]; then
        # The order read, then one appended after it: drop the first, keep the rest.
        tail -c +"$(( ${seen##* } + 1 ))" "$f" | sed '1{/^$/d;}' > "$SIGNAL/.stage.$$"
        mv "$SIGNAL/.stage.$$" "$f"
        signal_unlock
        echo "cleared $name: the order it read"
        info "a later order to '$name' was appended after that one and still stands - the next claim prints it: carry it out, then factory.sh signal-clear $name"
        return 0
      fi
      signal_unlock
      [ -z "$want" ] || die "the order to '$name' changed after it was read, so nothing is cleared - read it again (factory.sh signal-list)"
      die "the order to '$name' standing now is not the one that was read, so nothing is cleared - claim again (its refusal prints the order), carry it out, then factory.sh signal-clear $name"
    fi
    signal_unlock
  fi
  if [ -e "$SIGNAL/all.md" ]; then
    # No per-seat order, a broadcast standing: this IS the seat's broadcast ack,
    # of the text that was read (as above: --if, the gate's copy, else what stands).
    if signal_acked "$name"; then
      echo "already acked broadcast for $name"
      return 0
    fi
    cur="$(signal_gen)"
    if [ -n "$want" ]; then seen="$want"
    elif [ -f "$shown/$name.all" ]; then seen="$(cksum < "$shown/$name.all")"
    else seen="$cur"
    fi
    if [ "$seen" != "$cur" ]; then
      [ -z "$want" ] || { echo "no order to '$name' stands as it was read: nothing acknowledged"; return 0; }
      die "the broadcast standing now is not the one '$name' was shown, so it is not acknowledged - claim again (its refusal prints it), carry it out, then factory.sh signal-clear $name"
    fi
    mkdir -p "$SIGNAL/all.acked"
    printf '%s\n' "$seen" > "$SIGNAL/all.acked/$name"   # the ack names the text it acknowledged
    rm -f "$shown/$name.all"   # the copy is used up with the ack it allowed
    echo "acked broadcast for $name"
    return 0
  fi
  [ -z "$want" ] || { echo "no order to '$name' stands as it was read: nothing acknowledged"; return 0; }
  die "no signal addressed to '$name' (factory.sh signal-list)"
}

cmd_index() {
  local out="$FACTORY/index.md" tmp="$FACTORY/.index.$$" f w now age flag listing n mt
  now="$(now_s)"
  # The board is rendered to a temp file and mv'd into place (atomic: a
  # reader never sees a half-written board). An abort between the two used
  # to leak the temp - 56 .index.<pid> files had accumulated by 2026-09-03 -
  # so the temp is removed on ANY exit before the mv, and leftovers older than
  # 10 minutes (a concurrent index is seconds long) are swept on the way in.
  find "$FACTORY" -maxdepth 1 -name '.index.*' -mmin +10 -delete 2>/dev/null || true
  trap "rm -f '$tmp'" EXIT
  {
    echo "# Factory board  (generated $(now_iso) by factory.sh index)"
    echo
    echo "## Queue (execution order)"
    echo
    for f in "$QUEUE"/*.md; do
      if is_operator_lane "$f"; then continue; fi
      printf -- '- `%s` [band %s] %s\n' "$(basename "$f")" "$(prio_of "$f" | cut -c1-2)" "$(title_of "$f")"
    done
    echo
    # Listed apart because they are not in the consumers' execution order at
    # all: no seat will ever claim one. This section is the point of the lane -
    # the work has to be SEEN at rollout time, not worked by a seat.
    echo "## Operator lane (engine / non-local targets - consumers never claim these)"
    echo
    for f in "$QUEUE"/*.md; do
      if is_operator_lane "$f"; then
        printf -- '- `%s` %s\n' "$(basename "$f")" "$(title_of "$f")"
      fi
    done
    echo
    echo "## Active claims"
    echo
    for f in "$CLAIMED"/*/*.md; do
      w="$(basename "$(dirname "$f")")"
      # A claim archived (or requeued) between the glob and this stat is not
      # an active claim any more: skip the row instead of aborting the board
      # (seen on disk 2026-09-03: a truncated .index.<pid> ending mid-list).
      mt="$(stat -f %m "$f" 2>/dev/null || true)"
      if [ -z "$mt" ]; then continue; fi
      age=$(( (now - mt) / 60 ))
      flag=""; [ "$age" -ge 240 ] && flag=" **STALE?**"
      # A claim taken as the DIRECT overlap fallback (its latest claim stamp
      # says so) shares a concrete token with another live claim: the
      # merge-conflict risk the prioritizer relays (task 1792508144).
      if sed -n '/^- claimed by /p' "$f" 2>/dev/null | tail -1 | grep -q 'overlap fallback: DIRECT'; then flag="$flag **DIRECT-OVERLAP**"; fi
      printf -- '- `%s` <- %s (%sm)%s %s\n' "$(basename "$f")" "$w" "$age" "$flag" "$(title_of "$f")"
    done
    echo
    # A seat that handed off but whose successor never booted is INVISIBLE
    # otherwise: its worktree sits idle, its self-spawn may have failed (or a
    # desktop-era chip evaporated with an app restart), and the fleet quietly
    # shrinks. One line per pending file.
    echo "## Seats awaiting successor (tasks/handoff - boot one per line)"
    echo
    for f in "$HANDOFF"/*.md; do
      printf -- '- `%s` staged %s ago - boot it, then: factory.sh handoff-clear %s\n' \
        "$(basename "$f" .md)" "$(file_age_line "$f" "$now" | cut -f2)" "$(basename "$f" .md)"
    done
    echo
    # Unacknowledged orders: each one is BLOCKING its addressee's next claim, so
    # a forgotten signal is a stopped seat. The addressee clears its own.
    echo "## Operator signals (tasks/signal - unacknowledged orders, each blocking that seat's claim)"
    echo
    for f in "$SIGNAL"/*.md; do
      if [ "$(basename "$f")" = "all.md" ]; then
        # The broadcast blocks every seat NOT in its ack ledger; each seat acks
        # with its own name, and only the operator's `signal-clear all` deletes it.
        printf -- '- `all` (broadcast) sent %s ago - %s - each seat acknowledges with: factory.sh signal-clear <its-worker>; operator delete: factory.sh signal-clear all\n' \
          "$(file_age_line "$f" "$now" | cut -f2)" "$(signal_ack_ledger)"
      else
        printf -- '- `%s` sent %s ago - the addressee acknowledges with: factory.sh signal-clear %s\n' \
          "$(basename "$f" .md)" "$(file_age_line "$f" "$now" | cut -f2)" "$(basename "$f" .md)"
      fi
    done
    echo
    # The unattended fseventsd restarts (task 1791198753): the operator's
    # condition on the YES was "report every restart", and the board is the
    # prioritizer's pass summary - one line from the ledger, last 7 days.
    echo "## FSEvents restarts (unattended fseventsd restarts, last 7 days)"
    echo
    echo "- FSEvents restarts: $(fsevents_ledger_summary 7) - ledger $(fsevents_ledger_path)"
    echo
    # The CLI login (task 1792504454): the fleet doctor's pre-check stamps
    # tasks/factory/fleet-logged-out while `claude auth status` reads logged
    # out and clears it on the first logged-in pass - the board carries it
    # the way it carries the fsevents restarts, so a stale fleet has a named
    # cause (the 17.5-hour dead fleet of 2026-10-19/20 had none).
    echo "## CLI login (the fleet doctor's claude auth status pre-check)"
    echo
    if [ -f "$(logged_out_path)" ]; then
      echo "- CLI login: LOGGED OUT since $(logged_out_since) (FLEET-LOGGED-OUT: every seat and the prioritizer die on their next turn, every respawn is held) - $LOGIN_REMEDY"
    else
      echo "- CLI login: no logged-out sighting standing (stamp $(logged_out_path) absent; the doctor writes it while auth status reads logged out and clears it on the first logged-in pass)"
    fi
    echo
    echo "## Recently archived"
    echo
    # The listing is read into the shell FIRST and walked with a counter, never
    # `ls -t | head -15 | while`: that pipeline SIGPIPEd ls once the archive
    # outgrew head's read (~1800 files), and under pipefail the 141 aborted the
    # whole index before the board was written (task 1788467120).
    listing="$(ls -t "$ARCHIVE" 2>/dev/null || true)"
    n=0
    while IFS= read -r f; do
      if [ -z "$f" ]; then continue; fi
      printf -- '- `%s` %s\n' "$f" "$(title_of "$ARCHIVE/$f")"
      n=$((n + 1))
      if [ "$n" -ge 15 ]; then break; fi
    done <<EOF
$listing
EOF
  } > "$tmp"
  mv "$tmp" "$out"
  trap - EXIT
  echo "$out"
}

# signal/ is IN the signature on purpose: an operator order must wake every
# long poll the moment it lands, with no queue-touch hack to shake the seats.
# The broadcast ACK LEDGER (signal/all.acked/) is OUT of it on purpose: one
# seat's ack is nothing the other seats must react to, and with ten seats
# acking one broadcast it would wake every parked poll ten times for no
# work. Only the signal FILES (*.md - an order landing, appending, or being
# deleted) count; the ledger dir's own mtime never enters the listing.
watch_sig() { { ls -Rl "$QUEUE" "$CLAIMED" "$ARCHIVE"; ls -l "$SIGNAL"/*.md; } 2>/dev/null | cksum; }

# The watch obituary (task 1788458457). A backgrounded watch that dies by
# signal leaves the harness's bare "[killed]" marker in its output file, which
# says nothing about WHO or WHAT. These traps print one stderr line naming the
# signal, the instant, and whether the parent (the harness's shell wrapper) is
# still alive, then re-raise so the exit status stays the signal's. Signal-only:
# the CHANGED/TIMEOUT/EXECUTOR-STALE contract on stdout is byte-identical. A
# "[killed]" with NO obituary above it means SIGKILL (untrappable) - diagnostic
# too. The 2026-09-03 sweep (SKILL.md, executor mode) was SIGTERM to the watch
# process alone, parent alive - exactly what this line distinguishes.
watch_obituary() {
  local signame="$1" pp="alive"
  kill -0 "$PPID" 2>/dev/null || pp="dead"
  echo "factory.sh $2: killed by SIG$signame at $(now_iso) (pid $$, ppid $PPID $pp)" >&2
  [ -n "${WATCH_CHILD:-}" ] && kill "$WATCH_CHILD" 2>/dev/null   # hosted watch: the client poller
  trap - "$signame"
  kill "-$signame" $$
}

watch_arm_obituary() {  # $1 = the command label the obituary names
  trap "watch_obituary TERM $1" TERM
  trap "watch_obituary INT $1"  INT
  trap "watch_obituary HUP $1"  HUP
}

cmd_watch() {
  local max="${1:-500}" sig cur waited=0 cap capword
  case "$max" in ''|*[!0-9]*) die "watch expects a whole number of seconds" ;; esac
  # The harness kills a foreground Bash call at ITS cap - 10 min unless the
  # boot line raised BASH_MAX_TIMEOUT_MS (factory.sh boot-env: an hour) - and
  # a watch outliving the cap ends as a kill, never as TIMEOUT. Clamp to a
  # minute under the cap and say so: a session booted without boot-env keeps
  # the old cadence and its output names the remedy (respawn on the boot
  # line). The other direction is the idle floor: every return of this
  # command is a full-context model turn, so a seat that CAN sleep an hour
  # and asks for minutes gets told (SKILL.md "On idle": watch 3300).
  cap="${BASH_MAX_TIMEOUT_MS:-600000}"
  case "$cap" in ''|*[!0-9]*) cap=600000 ;; esac
  cap=$((cap / 1000 - 60))
  [ "$cap" -ge 10 ] || cap=10
  if [ "$max" -gt "$cap" ]; then
    if [ -n "${BASH_MAX_TIMEOUT_MS:-}" ]; then capword="BASH_MAX_TIMEOUT_MS=$BASH_MAX_TIMEOUT_MS"; else capword="BASH_MAX_TIMEOUT_MS unset: this session was booted WITHOUT factory.sh boot-env - respawn it on the boot line"; fi
    echo "factory: watch: $max s exceeds this session's Bash cap ($capword) - clamped to $cap s (a longer call ends as a harness kill, not TIMEOUT)" >&2
    max="$cap"
  elif [ "$max" -lt 1800 ] && [ "$cap" -ge 3300 ]; then
    echo "factory: watch: $max s while this session can sleep an hour - every return is a full-context model turn; idle doctrine is 'watch 3300' with the Bash timeout at 3600000 ms (SKILL.md)" >&2
  fi
  watch_arm_obituary watch
  sig="$(watch_sig)"
  while [ "$waited" -lt "$max" ]; do
    # sleep as a child under `wait`, not inline: bash delivers a trapped signal
    # to a `wait` immediately, so the obituary prints at kill time instead of
    # up to 10s later (or never, if the sleep is what got killed).
    sleep 10 & wait $! || true
    waited=$((waited+10))
    cur="$(watch_sig)"
    [ "$cur" != "$sig" ] && { echo "CHANGED"; return 0; }
  done
  echo "TIMEOUT"
}

# The merge lock's GENERATION (its directory's inode and birth time, "" when
# there is none - every mkdir makes a new one) and its generation-checked
# remover: the shared lockdir_gen / lockdir_take (the signal writers' lock
# section). The stale break was mv-then-rm on the path, so two waiters that
# both judged one lock stale could both win, and the release checked the
# owner and then ran rm -rf, so a release racing a stale break could delete
# the breaker's new lock and let a third seat acquire beside it; both now
# remove only the generation they judged. Nothing in this file removes the
# lock another way.
merge_lock_gen() { lockdir_gen "$1"; }
merge_lock_take() { lockdir_take "$1" "$2"; }

# merge-lock acquire's CLAIM BELT (--task <id>, 2026-10-03, a reviewer's note on
# open-saas PR #17): nothing between a seat's execute and its merge looked at
# tasks/claimed/ - the integrate steps and this acquire took only a label, and
# the first command that reads the claim is `done` (step 7), after main
# already holds the merge. On 2026-09-29 an executor whose claim an app's
# Requeue button had taken saw the requeue, had no answer by step 6, and
# merged. With --task the acquire refuses - before it waits, and again once it
# holds the lock (released first) - unless that task is CLAIMED: locally a
# file under tasks/claimed/<worker>/, in hosted mode the canister's state
# (`client show`'s header names it). The holder must be THIS seat when one
# resolves (FACTORY_WORKER > the .factory-worker pin > the cwd branch, the
# done/requeue identity): the operator acting on another seat's claim acquires
# without --task, as before. Advisory in shape - a seat that omits --task
# merges as it always did; FACTORY_FORCE=1 turns the refusal into a warning.
# --- MULTI/DEX overlay: the POSTURE LAW gate (merge_gate) -------------------
# as the file above it grows). Empty when the shape is not found.
merge_gate_deploy_mode_block() {
  sed -n '/^[[:space:]]*public type DeployMode[[:space:]]*=/,/IS_DEV[[:space:]]*:[[:space:]]*Bool/p'
}

merge_gate() {  # $1 = branch-or-worker label given to merge-lock acquire
  local label="$1" repo tmp posture file bad="" blk_main blk_br
  repo="${FACTORY_PRIMARY:-$PRIMARY}"
  [ -n "$repo" ] || return 0
  if ! git -C "$repo" rev-parse -q --verify "refs/heads/$label" >/dev/null 2>&1; then
    info "posture gate: '$label' is not a branch of $repo - gate skipped (acquire with your branch name to be gated)"
    return 0
  fi
  tmp="$(mktemp -d)"
  for file in src/backend/main.mo src/bridge/main.mo; do
    if ! git -C "$repo" show "$label:$file" > "$tmp/f.mo" 2>/dev/null; then
      bad="$bad $file:unreadable"; continue
    fi
    posture="$( (. "$repo/scripts/lib/targets.sh" >/dev/null 2>&1; mdx_posture_of "$tmp/f.mo") 2>/dev/null || true)"
    [ "$posture" = "play" ] || bad="$bad $file:#${posture:-unresolved}"
    # H-02 (F20), belt to the reader's braces: the DEPLOY_MODE block (the
    # DeployMode type through IS_DEV) must be BYTE-IDENTICAL to main's. The
    # reader answers the posture WORD; it cannot see `IS_DEV = true` beside
    # a #play literal, a widened DeployMode type, or a spelling it refuses
    # for the wrong reason. Posture-touching work is the exceptional case
    # FACTORY_FORCE exists for - say so out loud when you use it.
    blk_main="$(git -C "$repo" show "main:$file" 2>/dev/null | merge_gate_deploy_mode_block)"
    blk_br="$(merge_gate_deploy_mode_block < "$tmp/f.mo")"
    if [ -z "$blk_main" ]; then bad="$bad $file:DEPLOY_MODE-block-not-found-on-main"
    elif [ "$blk_main" != "$blk_br" ]; then bad="$bad $file:DEPLOY_MODE-block-differs-from-main"; fi
  done
  if git -C "$repo" show "$label:icp.yaml" 2>/dev/null | grep -qE 'port:[[:space:]]*0([^0-9]|$)'; then
    bad="$bad icp.yaml:port-0"
  fi
  # H-02 (F8): the canister-id mappings are what a remote deploy installs
  # onto; editing them is OPERATOR-LANE work (paired with the pinned table
  # in scripts/lib/targets.sh, one reviewed commit). Any change to them on
  # the branch since it forked from main is refused. Three-dot: the
  # branch's own edits, not main's movement since the fork.
  for file in $(git -C "$repo" diff --name-only "main...$label" -- .icp/data/mappings 2>/dev/null); do
    bad="$bad $file:mapping-edit"
  done
  rm -rf "$tmp"
  [ -z "$bad" ] && return 0
  if [ "${FACTORY_FORCE:-}" = "1" ]; then
    echo "factory: warning: posture gate overridden (FACTORY_FORCE=1) -$bad" >&2
    return 0
  fi
  die "merge-lock refused for '$label':$bad - a branch merges only on #play/#play with no port-0 icp.yaml (the posture law, .claude/skills/mdex-software-factory/SKILL.md). Restore the committed defaults on the branch, commit, and re-acquire; FACTORY_FORCE=1 overrides."
}

merge_lock_claim_check() {  # merge_lock_claim_check <id>: 0 = claimed by this seat; else 1 + the refusal on stdout
  local id="$1" p m n=0 q=0 holder="" head me
  p="$(pad "$id" 2>/dev/null)" || { echo "merge-lock refused: '--task $id' is not a task id"; return 1; }
  if hosted_mode; then
    head="$(client show "$id" 2>/dev/null | head -1 || true)"
    case "$head" in
      "=== hosted:"*"/claimed/"*) holder="${head#*/claimed/}"; holder="${holder%%/*}" ;;
      "=== hosted:"*"/queue/"*)   echo "merge-lock refused: task $id is back in the QUEUE (requeued while you worked) - a merge of a claim you no longer hold: stop, report it, and claim again before merging"; return 1 ;;
      "=== hosted:"*"/archive/"*) echo "merge-lock refused: task $id is ARCHIVED - nothing of yours is claimed: stop and report"; return 1 ;;
      *) echo "merge-lock refused: cannot read task $id from the hosted factory (client show answered '${head:-nothing}') - retry, or acquire without --task to skip the claim check"; return 1 ;;
    esac
  else
    for m in "$CLAIMED"/*/*-"$p".md; do holder="$(basename "$(dirname "$m")")"; n=$((n+1)); done
    if [ "$n" -eq 0 ]; then
      for m in "$QUEUE"/*-"$p".md; do q=1; done
      if [ "$q" = 1 ]; then
        echo "merge-lock refused: task $id is back in the QUEUE (requeued while you worked) - a merge of a claim you no longer hold: stop, report it, and claim again before merging"
      elif [ -f "$ARCHIVE/$p.md" ]; then
        echo "merge-lock refused: task $id is ARCHIVED - nothing of yours is claimed: stop and report"
      else
        echo "merge-lock refused: task $id is not claimed (factory.sh show $id): stop and report"
      fi
      return 1
    fi
  fi
  me="$(hosted_seat_worker)"
  if [ -n "$me" ] && [ -n "$holder" ] && [ "$holder" != "$me" ]; then
    echo "merge-lock refused: task $id is claimed by '$holder' and this seat resolves as '$me' (FACTORY_WORKER > .factory-worker pin > the cwd branch) - law 3: a claimed task belongs to its worker; the operator acting on another seat's claim acquires without --task"
    return 1
  fi
  return 0
}

cmd_merge_lock() {
  local sub="${1:-}" label="" max=240 task="" lock="$FACTORY/merge.lock"
  local owner ts age gen rc=0 waited=0 reason
  [ $# -eq 0 ] || shift
  # acquire <label> [max-wait-s] [--task <id>] | release [label] | status
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) shift; task="${1:-}"; [ -n "$task" ] || die "usage: factory.sh merge-lock acquire <branch-or-worker> [max-wait-s] [--task <id>]" ;;
      -*) die "unknown merge-lock option '$1'" ;;
      *) if [ -z "$label" ]; then label="$1"; else case "$1" in ''|*[!0-9]*) die "merge-lock: unexpected argument '$1'" ;; *) max="$1" ;; esac; fi ;;
    esac
    shift
  done
  case "$sub" in
    acquire)
      [ -n "$label" ] || die "usage: factory.sh merge-lock acquire <branch-or-worker> [max-wait-s] [--task <id>]"
      # The claim belt, before any wait (merge_lock_claim_check) ...
      if [ -n "$task" ] && ! reason="$(merge_lock_claim_check "$task")"; then
        if [ "${FACTORY_FORCE:-}" = "1" ]; then info "warning: merge-lock claim belt overridden (FACTORY_FORCE=1) - $reason"; task=""
        else die "$reason"; fi
      fi
      # MULTI/DEX: the POSTURE LAW (merge_gate) - a branch merges only on
      # #play/#play with main's DEPLOY_MODE block and no port-0 icp.yaml.
      merge_gate "$label"
      while ! mkdir "$lock" 2>/dev/null; do
        # The generation this pass judges, read before its owner and stamp: a
        # break removes only the lock that was judged stale (merge_lock_take).
        gen="$(merge_lock_gen "$lock")"
        owner="$(cat "$lock/owner" 2>/dev/null || echo unknown)"
        ts="$(cat "$lock/ts" 2>/dev/null || true)"
        # No readable stamp: the holder is between its mkdir and its stamp,
        # or died there. Date the lock by its directory's mtime, never as 0
        # (0 read a just-made lock as decades old, broke it, and both seats
        # acquired); retry one that vanished before it could be dated, and
        # wait on one that cannot be dated.
        case "$ts" in ''|*[!0-9]*) ts="$(stat -f %m "$lock" 2>/dev/null || true)" ;; esac
        case "$ts" in ''|*[!0-9]*) [ -d "$lock" ] || continue; ts="$(now_s)" ;; esac
        age=$(( $(now_s) - 10#${ts:-0} ))
        if [ "$age" -gt 1800 ]; then
          # Merges take minutes; a 30-min-old lock is a dead session's. It is
          # broken as the one generation this pass read, never whatever holds
          # the path by the time the break runs: two waiters that judged one
          # lock stale break it once, and the second finds the first's hold.
          if merge_lock_take "$lock" "$gen"; then
            info "broke stale merge lock (owner $owner, ${age}s old)"
          fi
          continue
        fi
        [ "$waited" -ge "$max" ] && die "merge lock held by $owner (${age}s old); retry later"
        sleep 5; waited=$((waited+5))
      done
      echo "$label" > "$lock/owner"; now_s > "$lock/ts"
      # ... and again now that the lock is held - a requeue can land during
      # the wait. The lock is released before the refusal.
      if [ -n "$task" ] && ! reason="$(merge_lock_claim_check "$task")"; then
        merge_lock_take "$lock" "$(merge_lock_gen "$lock")" || true
        die "$reason (the merge lock was released)"
      fi
      # Law-5 tripwire (task 1787719645): a branch with NOTHING beyond main
      # at acquire time means there is nothing to merge - the signature of a
      # direct-to-main commit that skipped the worktree (76e5c40d: the sweep
      # was already ON main, so the seat's branch carried no unmerged work).
      # WARN, never refuse: a redundant or defensive acquire is legitimate
      # (e.g. re-acquiring after a completed merge), and labels that are
      # worker names rather than branch refs simply skip the check.
      if git rev-parse -q --verify "refs/heads/$label" >/dev/null 2>&1 \
        && git rev-parse -q --verify refs/heads/main >/dev/null 2>&1; then
        if [ "$(git rev-list --count "refs/heads/main..refs/heads/$label" 2>/dev/null || echo 1)" = "0" ]; then
          info "warning: branch '$label' has NO commits beyond main - nothing to merge. If you just committed work, check WHERE: a commit made in the PRIMARY checkout is already on main (law-5 breach) - verify with 'git log --oneline -3 main', release this lock, and do future work from your seat worktree."
        fi
      fi
      echo "acquired"
      ;;
    release)
      gen="$(merge_lock_gen "$lock")"
      [ -n "$gen" ] || { echo "already free"; return 0; }
      owner="$(cat "$lock/owner" 2>/dev/null || echo unknown)"
      if [ -n "$label" ] && [ "$label" != "$owner" ] && [ "${FACTORY_FORCE:-}" != "1" ]; then
        die "merge lock is owned by '$owner', not '$label' (FACTORY_FORCE=1 overrides)"
      fi
      # Only the generation whose owner was just checked is removed: a lock
      # broken as stale and made again in between is the next holder's.
      merge_lock_take "$lock" "$gen" || rc=$?
      if [ "$rc" -ne 0 ]; then
        [ "$rc" -eq 1 ] || [ "$rc" -eq 69 ] || die "cannot lock $lock to release it (lockf exit $rc) - retry"
        [ -d "$lock" ] || { echo "already free"; return 0; }
        die "merge lock changed hands before it was released: it is now held by '$(cat "$lock/owner" 2>/dev/null || echo unknown)', and this release removes only the hold it checked (factory.sh merge-lock status)"
      fi
      echo "released"
      ;;
    status)
      if [ -d "$lock" ]; then
        ts="$(cat "$lock/ts" 2>/dev/null || true)"
        case "$ts" in ''|*[!0-9]*) ts="$(stat -f %m "$lock" 2>/dev/null || now_s)" ;; esac   # unstamped: by the directory, never as 0
        echo "held by $(cat "$lock/owner" 2>/dev/null || echo unknown) for $(( $(now_s) - 10#${ts:-0} ))s"
      else
        echo "free"
      fi
      ;;
    *) die "usage: factory.sh merge-lock <acquire|release|status> [label] [max-wait-s] [--task <id>]" ;;
  esac
}

# --- merge-land: TaskConsumer step 6d-6h as ONE door -------------------------
#
# merge-land <branch> (-m <message> | -F <file>) [--task <id>] (task
# 1792601027, 2026-10-21). The step-6 chain was composed by hand in every
# executor prompt, and on 2026-10-21 one composition landed NOTHING while
# every exit code said it had: `git -C "$PRIMARY" merge --no-ff ...` answered
# "Already up to date." with exit 0, the push said "Everything up-to-date",
# the lock was released, and only a manual `rev-parse main` showed
# claude/seat-2 (390193070) was not on main (20828a64b). The one shape
# consistent with both reflogs is the SELF-MERGE: `git -C ""` leaves the cwd
# unchanged (git(1)), so a transiently empty $PRIMARY ran the merge inside the
# seat's own worktree, where the branch IS HEAD - and git truthfully reports
# nothing to do. Whatever the cause, the chain trusted the merge's exit code,
# and `done <id> done "merged <sha>"` would have archived work that lived only
# on a seat branch.
#
# This door is that chain with the proof built in, run from the seat's
# worktree (<branch> checked out there) under a merge lock ALREADY held for
# <branch> (step 6c, with its --task claim belt):
#   1. the lock must be held for exactly <branch> (free, or another label =
#      refused, nothing touched - another seat's lock is never released);
#   2. the primary is resolved the way every command here resolves it (the
#      first row of `git worktree list --porcelain`) and REFUSED when it is
#      this very worktree - the self-merge shape - or has anything but main
#      checked out; this tree must have <branch> checked out (the lints read
#      HEAD here);
#   3. the primary preflight (6d): no index.lock (GitHub Desktop), no
#      MERGE_HEAD (a half-finished merge: escalate);
#   4. the FOUR step-6d lints, `--changed`, from THIS worktree:
#      `lint-stable-compat.sh` + `lint-package-consumers.sh` +
#      `lint-claude-invariants.sh` + `lint-package-js-imports.sh` (6d;
#      FACTORY_LINT_DIR names the scripts/ they are read from - the
#      selftest's stubs; LINT_STABLE_COMPAT=0 / LINT_PACKAGE_CONSUMERS=0 /
#      LINT_CLAUDE_INVARIANTS=0 / LINT_PACKAGE_JS_IMPORTS=0 are the
#      protocol's recorded skips; a script that is not found is a refusal,
#      never a silent pass; the third is the double-36 backstop of task
#      1792717799: a duplicated top-level invariant number in a
#      services/*/CLAUDE.md first exists in the SECOND seat's tree after its
#      `git merge main` - every seat's own lint-all was green on 2026-10-22
#      - and this door is the one place that reads that tree; the fourth is
#      the plain-JS backstop of task 1792739412: a .js module of a shared
#      npm package importing a .ts or extensionless sibling passes tsc,
#      every vite build and the package's own tests and dies in the first
#      consumer vite-node verify AFTER landing (directory-link 0.15.0's
#      first handOffFragment cut, task 1792736193) - a seat whose step-5
#      gate choice skipped lint-all never ran the lint, so the door runs it
#      over the npm packages whose src/ the branch touched);
#   5. <branch> must carry commits beyond main (6c's acquire only WARNS;
#      here "nothing to merge" is a refusal - the merge would answer
#      "Already up to date." - and it is answered FIRST, so a re-run after a
#      landing says so instead of "main moved"), then main must be an
#      ancestor of <branch> (6e: main moved since your `git merge main` =
#      refused, back to 6a); with --task the claim belt runs once more right
#      here (a requeue can land during the lints);
#   6. `git -C <primary> merge --no-ff --no-edit` (6f) with the message from
#      -m or -F; a refused merge is aborted (MERGE_HEAD) and reported as the
#      protocol's "MERGE PENDING - operator" case;
#   7. THE PROOF: `rev-parse main` read before the merge must differ after
#      it, and <branch> must be an ancestor of main - both shas are printed;
#      "Already up to date." is a FAILURE here, never a landing;
#   8. the push (6g) under a kill-after bar (FACTORY_PUSH_BAR_S, default 600;
#      the push's own process tree, by pid): a failure NEVER blocks - no
#      retry, never --force, the landed merge stays - the line "PUSH FAILED:
#      <why>" is printed for the seat's report;
#   9. the lock release (6h).
# EVERY refusal after step 1 releases the lock (the protocol's "release the
# lock and fix / go back to (a)") and lands nothing, so a seat re-acquires to
# retry; a usage error (before step 1) touches nothing. The last stdout line
# of a landing is "merged <sha>" - the archive note's words. Local in both
# modes: git, worktrees and the primary are this machine's.
merge_land_release() {  # merge_land_release <lock> <label>: drop THIS door's hold (generation-checked; another holder's lock is never touched)
  local lock="$1" label="$2" gen owner
  gen="$(merge_lock_gen "$lock")"
  [ -n "$gen" ] || { echo "merge lock: already free"; return 0; }
  owner="$(cat "$lock/owner" 2>/dev/null || echo unknown)"
  [ "$owner" = "$label" ] || { echo "merge lock: now held by '$owner' - left alone"; return 0; }
  if merge_lock_take "$lock" "$gen"; then echo "merge lock released ($label)"; else echo "merge lock: changed hands before the release - left alone"; fi
}
merge_land_fail() {  # merge_land_fail <lock> <label> <message>: release this door's hold, then die - nothing has landed
  merge_land_release "$1" "$2"
  die "$3"
}
merge_land_gate() {  # merge_land_gate <worktree> <lint-dir> <script> <skip-var>: one of the four step-6d lints, --changed, from the seat's worktree; 0 = OK or a recorded skip
  local top="$1" dir="$2" s="$3" var="$4" rc=0 skip
  skip="${!var:-}"
  if [ "$skip" = "0" ]; then
    echo "$s: SKIPPED ($var=0 - the protocol's recorded skip: say so in your .done)"
    return 0
  fi
  if [ ! -x "$dir/$s" ]; then
    echo "$s: not found at $dir/$s (FACTORY_LINT_DIR names the scripts/ directory to read it from) - a missing gate never passes"
    return 1
  fi
  echo "== $s (from $top) =="
  (cd "$top" && "$dir/$s") || rc=$?
  [ "$rc" -eq 0 ] || echo "$s: FAILED (exit $rc)"
  return "$rc"
}
merge_land_push() {  # merge_land_push <primary>: `push origin main` under a kill-after bar; prints the one line the seat reports; never fails the door
  local primary="$1" secs="${FACTORY_PUSH_BAR_S:-600}" out pid waited=0 rc=0 why
  out="$(mktemp "${TMPDIR:-/tmp}/factory-push.XXXXXX")"
  GIT_TERMINAL_PROMPT=0 git -C "$primary" push origin main >"$out" 2>&1 </dev/null &
  pid=$!
  while rr_alive "$pid"; do
    if [ "$waited" -ge "$secs" ]; then rr_kill_tree "$pid" TERM; sleep 1; rr_kill_tree "$pid" KILL; rc=124; break; fi
    sleep 1; waited=$((waited + 1))
  done
  if [ "$rc" -ne 124 ]; then wait "$pid" 2>/dev/null && rc=0 || rc=$?; else wait "$pid" 2>/dev/null || true; fi
  if [ -s "$out" ]; then sed 's/^/    | /' "$out"; fi
  if [ "$rc" -eq 0 ]; then
    echo "pushed origin main"
  else
    if [ "$rc" -eq 124 ]; then why="no answer in ${secs}s (the push's own process tree killed by pid; FACTORY_PUSH_BAR_S)"
    else why="$(grep -v '^$' "$out" | tail -1)"; [ -n "$why" ] || why="exit $rc"; fi
    echo "PUSH FAILED: $why - not retried, never --force, the merge stays landed on main: note it in your report (the prioritizer's origin-lag alert catches persistent breakage)"
  fi
  rm -f "$out"
}

cmd_merge_land() {
  local branch="" msg="" msgfile="" task="" lock="$FACTORY/merge.lock" usage
  local owner primary top primary_p top_p head_b gitdir n before after tip second rc=0 lint_dir reason
  usage="usage: factory.sh merge-land <branch> (-m '<message>' | -F <file>) [--task <id>] - under a lock already held for <branch> (factory.sh merge-lock acquire <branch> --task <id>)"
  while [ $# -gt 0 ]; do
    case "$1" in
      -m) shift; msg="${1:-}"; [ -n "$msg" ] || die "$usage" ;;
      -F) shift; msgfile="${1:-}"; [ -n "$msgfile" ] || die "$usage"; [ -f "$msgfile" ] || die "merge-land: no message file '$msgfile'" ;;
      --task) shift; task="${1:-}"; [ -n "$task" ] || die "$usage" ;;
      -*) die "unknown merge-land option '$1' ($usage)" ;;
      *) [ -z "$branch" ] || die "merge-land: unexpected argument '$1' ($usage)"; branch="$1" ;;
    esac
    shift
  done
  [ -n "$branch" ] || die "$usage"
  if [ -z "$msg" ] && [ -z "$msgfile" ]; then
    die "merge-land: the merge message is required - -m 'merge: <summary> from $branch' or -F <file> ($usage)"
  fi
  [ -z "$msg" ] || [ -z "$msgfile" ] || die "merge-land: -m and -F are mutually exclusive"
  if [ -n "$msgfile" ]; then msgfile="$(cd "$(dirname "$msgfile")" && pwd -P)/$(basename "$msgfile")"; fi
  # 1. the lock, held for exactly this branch
  if [ ! -d "$lock" ]; then
    die "merge-land refused: the merge lock is FREE - step 6c first: factory.sh merge-lock acquire $branch --task <id>"
  fi
  owner="$(cat "$lock/owner" 2>/dev/null || echo unknown)"
  if [ "$owner" != "$branch" ]; then
    die "merge-land refused: the merge lock is held by '$owner', not '$branch' ($(cmd_merge_lock status)) - a landing runs only under the lock acquired for its own branch (factory.sh merge-lock acquire $branch --task <id>); another seat's lock is never touched"
  fi
  # 2. the primary, and the self-merge shape
  primary="$(fleet_primary)"
  [ -n "$primary" ] || merge_land_fail "$lock" "$branch" "merge-land refused: no primary checkout resolves from $PWD (git worktree list) - run it from inside the seat's worktree"
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] || merge_land_fail "$lock" "$branch" "merge-land refused: $PWD is not inside a git worktree - run it from the seat's worktree, where $branch is checked out"
  primary_p="$(cd "$primary" 2>/dev/null && pwd -P || printf '%s' "$primary")"
  top_p="$(cd "$top" && pwd -P)"
  if [ "$primary_p" = "$top_p" ]; then
    merge_land_fail "$lock" "$branch" "merge-land REFUSED: the primary resolved to THIS worktree ($top_p) - the SELF-MERGE shape (2026-10-21): a merge run where '$branch' is HEAD answers 'Already up to date.' with exit 0 and lands NOTHING on main. Run merge-land from the seat's worktree (a linked worktree of the primary - never from the primary, and never through an empty \$PRIMARY: 'git -C \"\"' stays in the cwd)"
  fi
  head_b="$(git -C "$top" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  if [ "$head_b" != "$branch" ]; then
    merge_land_fail "$lock" "$branch" "merge-land refused: this worktree ($top_p) has '${head_b:-a detached HEAD}' checked out, not '$branch' - the step-6d lints read HEAD here; run merge-land from $branch's own worktree"
  fi
  if [ -n "$(git -C "$top" status --porcelain --untracked-files=no 2>/dev/null | head -1)" ]; then
    info "warning: $top_p has uncommitted changes - they do NOT ride this merge (step 6a: commit everything on $branch first)"
  fi
  git -C "$primary" rev-parse -q --verify "refs/heads/$branch" >/dev/null 2>&1 \
    || merge_land_fail "$lock" "$branch" "merge-land refused: no branch '$branch' in $primary_p"
  head_b="$(git -C "$primary" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  if [ "$head_b" != "main" ]; then
    merge_land_fail "$lock" "$branch" "merge-land refused: the primary ($primary_p) has '${head_b:-a detached HEAD}' checked out, not main - the merge would land on the wrong branch: escalate to the operator"
  fi
  # 3. the primary preflight (6d)
  gitdir="$(git -C "$primary" rev-parse --git-dir 2>/dev/null || true)"
  case "$gitdir" in ''|/*) ;; *) gitdir="$primary/$gitdir" ;; esac
  if [ -n "$gitdir" ] && [ -e "$gitdir/index.lock" ]; then
    merge_land_fail "$lock" "$branch" "merge-land refused: $gitdir/index.lock exists (GitHub Desktop open, or a git command in flight in the primary) - wait, or ask the operator; never rm a git lock file yourself"
  fi
  if git -C "$primary" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    merge_land_fail "$lock" "$branch" "merge-land refused: the primary ($primary_p) has a HALF-FINISHED merge (MERGE_HEAD) - STOP and escalate to the operator; nothing of yours was touched"
  fi
  # 4. the four step-6d lints, --changed, from this worktree
  lint_dir="${FACTORY_LINT_DIR:-$top/scripts}"
  merge_land_gate "$top" "$lint_dir" lint-ratchet.sh LINT_RATCHET \
    || merge_land_fail "$lock" "$branch" "merge-land refused: scripts/lint-ratchet.sh FAILED (type-check / mops test / candid compatibility) - fix it on $branch and re-run; LINT_RATCHET=0 is the protocol's recorded skip (say so in your .done)"
  # 5. the nothing-to-merge refusal (first: a re-run after a landing must say so, not 'main moved'), the ancestor check (6e), the claim belt once more
  n="$(git -C "$primary" rev-list --count "main..$branch" 2>/dev/null || echo 0)"
  if [ "$n" = "0" ]; then
    merge_land_fail "$lock" "$branch" "merge-land refused: nothing to merge - '$branch' has NO commits beyond main ($(git -C "$primary" rev-parse --short main)); a merge here would answer 'Already up to date.' and land nothing. If you just committed work, check WHERE (law 5): 'git log --oneline -3 main' - a commit made in the PRIMARY is already on main"
  fi
  if ! git -C "$primary" merge-base --is-ancestor main "$branch" 2>/dev/null; then
    merge_land_fail "$lock" "$branch" "merge-land refused: main ($(git -C "$primary" rev-parse --short main)) is NOT an ancestor of $branch - main moved since your last 'git merge main': step 6a again (merge main INTO $branch, re-run the gates), then re-acquire the lock"
  fi
  if [ -n "$task" ] && ! reason="$(merge_lock_claim_check "$task")"; then
    if [ "${FACTORY_FORCE:-}" = "1" ]; then info "warning: merge-land claim belt overridden (FACTORY_FORCE=1) - $reason"
    else merge_land_fail "$lock" "$branch" "$reason (nothing landed)"; fi
  fi
  before="$(git -C "$primary" rev-parse main)"
  tip="$(git -C "$primary" rev-parse "refs/heads/$branch")"
  echo "main before: $before"
  echo "merging $branch ($tip, $n commit(s) beyond main) into main at $primary_p"
  # 6. the merge (6f)
  if [ -n "$msgfile" ]; then
    git -C "$primary" merge --no-ff --no-edit -F "$msgfile" "$branch" || rc=$?
  else
    git -C "$primary" merge --no-ff --no-edit -m "$msg" "$branch" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    if git -C "$primary" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
      git -C "$primary" merge --abort >/dev/null 2>&1 || true
      echo "the partial merge was aborted (no MERGE_HEAD left behind)"
    fi
    merge_land_fail "$lock" "$branch" "merge-land FAILED: 'git merge --no-ff' refused (exit $rc) in the primary - dirty overlapping files there? NOTHING landed (main still $before); archive with a 'MERGE PENDING - operator' note (step 6f) instead of blocking forever"
  fi
  # 7. the proof: main moved, and the branch is an ancestor of it
  after="$(git -C "$primary" rev-parse main)"
  if [ "$after" = "$before" ]; then
    merge_land_fail "$lock" "$branch" "merge-land FAILED: main did NOT move (still $before) - git answered without landing anything: the 'Already up to date.' shape (the merge ran where '$branch' is HEAD, or against refs that already held it). NOTHING of '$branch' is on main: do not archive; read 'git -C $primary_p reflog -3' before retrying"
  fi
  if ! git -C "$primary" merge-base --is-ancestor "$branch" main 2>/dev/null; then
    merge_land_fail "$lock" "$branch" "merge-land FAILED: main moved ($before -> $after) but '$branch' ($tip) is NOT an ancestor of it - do not archive; investigate the primary's reflog"
  fi
  second="$(git -C "$primary" rev-parse -q --verify 'main^2' 2>/dev/null || true)"
  [ "$second" = "$tip" ] || info "warning: main's second parent is '${second:-none}', not $branch's tip $tip - not the --no-ff shape this door makes; look before archiving"
  echo "main after:  $after"
  echo "landed: $branch ($tip) is an ancestor of main"
  # 8. the push (6g) - never blocks the factory
  merge_land_push "$primary"
  # 9. the release (6h)
  merge_land_release "$lock" "$branch"
  echo "merged $after"
}

cmd_help() {
  cat <<'EOF'
factory.sh - the software-factory task queue (.claude/skills/mdex-software-factory/SKILL.md)

  root                              print the resolved tasks root
  worker-pin [worker]               PIN this worktree's seat identity into <worktree-root>/.factory-worker
                                    (defaults to the flattened current branch). A seat's boot step: every
                                    later claim/requeue/done from anywhere inside the tree - executor
                                    subagents included - then resolves the same worker without the branch.
                                    Also registers the fleet roster row and drops .worktree-keep, the
                                    desktop app's keep sentinel (its 30-min untracked-dir GC over
                                    .claude/worktrees/ removed idle seats: task 1789581979) - the belt for
                                    a seat still at that LEGACY location (named on stderr).
                                    DUPLICATE-SESSION (task 1789588684): refuses when ANOTHER live process
                                    carries this session's --name and is OLDER (the caller's own tree
                                    exempt; a mid-exit predecessor is re-checked after FACTORY_DUP_GRACE_S,
                                    default 5) - an extra boot of a timed-out spawn exits here instead of
                                    claiming under the shared identity; claim carries the same gate;
                                    FACTORY_FORCE=1 overrides
  seat-root [seat]                  print the SEAT ROOT <primary>/.factory/seats (created on demand) - where
                                    every seat worktree lives since 2026-09-16, outside the desktop app's
                                    worktree pool root .claude/worktrees/ whose GC wiped seat-7 / seat-14 -
                                    or, with a seat name, the path that seat lives at (the git worktree
                                    add target: git worktree add "$(factory.sh seat-root <seat>)" -b
                                    claude/<seat> main). Existing seats stay put until their next natural
                                    retirement; a live seat is never moved under a running replica
  worker                            print the identity this cwd resolves to and where it came from
  executor-env [seat]               print 'FACTORY_WORKER=<pin> FACTORY_SEAT_ROOT=<worktree>' from the seat's
                                    .factory-worker pin (the cwd's seat, or the named one) - the line a
                                    seat puts at the HEAD of its executor subagent's Bash-prefix rule
                                    ('export <line>; cd "$FACTORY_SEAT_ROOT" && ...') so the subagent's
                                    shell carries the seat identity wherever its cd target drifts: the
                                    Agent tool inherits no exports and the pin stays in the worktree, so
                                    an executor without it passes every law-5 guard from the primary
                                    (1dc9df2fa, 2026-10-04; task 1791133471). The pin wins over a
                                    differing FACTORY_WORKER in the calling shell (noted on stderr)
  new <draft.md> [--attach <file>]... [--band NN]
                                    enqueue a finished draft (allocates the id; draft is left in place);
                                    the FILING band follows the draft's class: line (task 1792609968):
                                    hygiene -> 30, cosmetic -> 40, parked -> 90; every other class (or
                                    none) -> the natural band, the key = the id, as before - the DEMOTING
                                    defaults only, every promotion stays the prioritizer's; a 'band: NN'
                                    front-matter line or --band NN (the flag wins) overrides it, and
                                    reprioritize still moves anything afterwards (a FILING default, not
                                    a ruling). stdout stays the queue path alone; a banded filing adds
                                    ONE stderr line "factory: new: filed at band NN (<why>) - ...".
                                    HOSTED mode (task 1792613259): the canister bands the filing the same
                                    way at submit - task_submit_checked stores hygiene / cosmetic / parked
                                    at 30 / 40 / 90, a band: line at its band, the message's P half the
                                    banded key; --band rides to the client as the draft's band: line;
                                    --attach (repeatable; 2 MB per file, 5 files / 8 MB per task) copies the
                                    file to tasks/attachments/<id>/ (hosted: stages it on the canister) and
                                    appends an "## Attachments" section (path, size, sha256, uploader);
                                    WARNS on stderr - never refuses, never edits the draft - when the draft
                                    cites a task this seat holds under tasks/claimed/<worker>/ and its
                                    after: line does not name it (task 1792508238; both backends)
  amend <id> [text|-] [--attach <file>]...
                                    HOSTED ONLY: append to the body of YOUR claim and/or add files to it;
                                    the claim mirror is refreshed (local mode: edit the claimed file)
  list [--operator|--consumer]      queued tasks in execution order: filename + title
  show <id>                         print a task wherever it lives (queue/claimed/archive)
  claim [worker]                    atomically claim the best eligible task (REFUSED while an operator
                                    signal addresses this worker, and - consumer claims - while the
                                    seat's own replica is over the step-7 budget/age: RECYCLE-REQUIRED,
                                    measured by replica-doctor --rss on the caller's worktree, fail-open
                                    on broken measurement - remedy: replica-recycle, below; and
                                    DUPLICATE-SESSION while an OLDER live process carries this session's
                                    --name - the worker-pin gate, task 1789588684: exit, never claim;
                                    FACTORY_FORCE=1 overrides); prints its new path, or
                                    "EMPTY (queue N: X dep-gated, Y operator-lane, Z overlap-deferred)"
                                    ("EMPTY (queue 0)" when queue/ is literally empty; first word is
                                    always exactly EMPTY - relay the breakdown in idle reports).
                                    Overlap-defer ignores repo-wide touches tokens (FACTORY_OVERLAP_IGNORE,
                                    default "docs README"; empty = gate on every token); affinity and
                                    "suite" are unchanged. When everything eligible overlaps the fallback
                                    is GRADED: the first task overlapping only through "suite" before the
                                    first sharing a concrete token with another claim, never the plain
                                    head - and the claim says which on stderr ("factory: overlap fallback:
                                    suite-only (behind <seat>'s <id>)" / "factory: overlap fallback:
                                    DIRECT - shares '<token>' with <seat>'s <id>"), the same words on its
                                    Factory log stamp; the board marks a DIRECT claim **DIRECT-OVERLAP**.
                                    Band precedence beats the suite rule's soft defer: a task touching
                                    "suite" in a STRICTLY higher band than the free task about to be
                                    chosen is claimed over it - "factory: overlap fallback: suite-only
                                    (band NN outranks the free band MM; behind <seat>'s <id>)" (equal
                                    bands: the free task wins). A DIRECT candidate gains it ONLY from an
                                    EXPEDITED band (00-09) strictly higher than the pick in hand's -
                                    "factory: overlap fallback: DIRECT - shares '<token>' with <seat>'s
                                    <id> (band 05 outranks the free band 30)" (the rebase is the cost of
                                    the expedite; from band 10 up a concrete collision stays the last
                                    resort; the band ORDER rules inside the zone: 05 waits behind free 03)
  claim --affinity a,b [worker]     same, but prefer tasks touching a/b WITHIN the head priority band
  claim --operator [worker]         claim from the OPERATOR lane instead (tasks a consumer must never run)
  claim --operator --id <id>        take one SPECIFIC queued task - the safe-edit tweezers (claim, edit, requeue)
                                    claim resolves its worker: [worker] arg > FACTORY_WORKER env >
                                    .factory-worker seat pin (worker-pin, above) > cwd branch, and prints the
                                    effective worker on stderr - plus a warning whenever the pin and the
                                    resolved/derived name disagree (that disagreement IS cwd drift).
  done <id> <status> [note]         archive a claimed task (done|abandoned|split|superseded);
                                    status=done refuses a service-touching task while tasks/<worker>.done
                                    (or tasks/sessions-done/<worker>.done, the retired-marker fold)
                                    has no 'help:' line - the help law (FACTORY_FORCE=1 overrides)
  requeue <id> [band] [note]        put a claimed task back in the queue (note lands in its Factory log)
  reprioritize <id> <band|key>      rename a QUEUED task's priority half (prioritizer only)
  index                             regenerate tasks/factory/index.md (the human-readable board)
  handoff-list                      seats awaiting a successor: "<worktree>\t<age>" per line, or NONE
                                    (a retiring seat writes tasks/handoff/<worktree>.md with the boot
                                    prompt - the spawn token and the durable record a restart cannot reach)
  handoff-clear <worktree>          the successor's FIRST act once booted: drop that pending file
  spawn-successor <worktree>        CLI seat's handoff step: open a new Terminal window running the
                                    claude CLI (pinned model) with the boot prompt from that seat's
                                    pending handoff file; refuses when no handoff file exists (handoff
                                    first, spawn second). Session name is project-prefixed:
                                    <prefix>-executor-<worktree> (or <prefix>-worker-<worktree> for a
                                    non-executor boot prompt); prefix = FACTORY_PROJECT, else the
                                    primary checkout basename minus -ng/-main (open-saas-ng -> open-saas).
                                    Zero-residue window: the command ends '; exit 0' and the window gets
                                    the 'Factory' Terminal settings set ('When the shell exits: Close the
                                    window') when it exists - no such profile: spawn proceeds, the banner
                                    names the one-time manual setup (operator guide in the skill). The
                                    profile is applied by a SECOND osascript only AFTER the process is
                                    verified live (task 1788301542): the boot program is the bare
                                    'do script' - touching the window's settings while its shell starts
                                    up swallowed the boot command in 7 of 10 fleet-cycle spawns.
                                    The same post-live program sets the tab's CUSTOM title to the session
                                    name (task 1789581980) so fleet windows are findable by seat name -
                                    profile or not (a dead-prompt window still says which seat it was);
                                    the Factory profile's Window/Tab title components decide what else
                                    Terminal appends (operator guide: uncheck them so the title stands alone).
                                    Spawn verification (task 1788278149): refuses when a process already
                                    carries the session name (duplicate guard; the caller's own session
                                    tree is exempt; FACTORY_FORCE=1 overrides), and after the osascript
                                    polls for the named process (~10s, FACTORY_SPAWN_VERIFY_SECS) -
                                    absent, it re-drives the SAME window (empty 'do script' re-submits a
                                    command left typed-but-unexecuted at the prompt; never a new window)
                                    up to FACTORY_SPAWN_REDRIVES (default 2) times; 'spawned' is only
                                    reported once the process exists, else the error names the window id
                                    (press Return there) plus the manual boot line.
                                    SPAWN PENDING (task 1789588684): an AppleEvent REPLY timeout (-1712 /
                                    "timed out") is NOT a failure - Terminal may run the queued event hours
                                    later (15 timed-out doctor passes booted NINE sessions onto one seat
                                    on 2026-09-16). The spawn writes tasks/factory/spawn-pending/<seat>
                                    (instant + session name), polls the verify budget once, then prints
                                    'spawn PENDING (AppleEvent timed out - Terminal may still run it)' and
                                    exits 3 - never the hand-boot line. While the stamp is younger than
                                    FACTORY_SPAWN_PENDING_TTL (default 6h; N|Nh|Nm|Ns) every spawn refuses
                                    unless the seat's process exists (stamp cleared, duplicate refusal
                                    applies) or FACTORY_FORCE=1; handoff-clear spends it too.
                                    FACTORY_OSASCRIPT_BIN overrides the osascript binary (selftest fake).
                                    FACTORY_SPAWN_DRYRUN=1 prints the name, the typed boot line (with its
                                    byte count) + both programs instead of running
  prioritizer-boot                  boot the TaskPrioritizer through the SAME spawn path (task 1792506027;
                                    LOCAL mode only - a HOSTED checkout refuses: the canister runs that
                                    pass). Session name <prefix>-prioritizer (what fleet-doctor looks for),
                                    the pre-spawn guard by name ("already live (pid N)" - FACTORY_FORCE=1
                                    overrides), the spawn-pending stamp keyed `prioritizer`, the bare
                                    'do script' + verify + re-drive, the post-live Factory profile + tab
                                    title, the same banner + exit codes (3 = PENDING). The typed line is
                                    `cd <primary> && <self> boot-exec prioritizer --model <m> --name <n>;
                                    exit 0` - no prompt, no environment on it: the command writes the
                                    token tasks/handoff/prioritizer.md (seat-token shape, so handoff-list
                                    and the board list it) just before the spawn and boot-exec reads the
                                    prompt from it inside the window; the booted prioritizer's FIRST act
                                    is `handoff-clear prioritizer` (its prompt says so). No arguments;
                                    FACTORY_SPAWN_DRYRUN=1 prints the plan and writes nothing (the guards
                                    still apply); FACTORY_TASKS_ROOT / FACTORY_PROJECT, when set, ride the
                                    typed line so a scratch boot works a throwaway queue under its own
                                    prefix. fleet-doctor --respawn calls it to revive an UNMANNED/STALLED
                                    prioritizer (below)
  replica-recycle [--dry-run]       stop THIS SEAT'S OWN replica - the allowlisted door for the stop the
                                    doctrine requires (step 7 / RECYCLE-REQUIRED / wind-up) and that an
                                    auto-mode seat is DENIED as a raw `icp network stop`. Worktree = the
                                    .factory-worker pin's home (or the git toplevel under FACTORY_WORKER);
                                    no identity, a pin/env disagreement, or the PRIMARY checkout = refused,
                                    no override. Runs `ICP_PROJECT_ROOT=. icp network stop` there under a
                                    kill-after watchdog, then kills ONLY the pocket-ic/launcher processes
                                    lsof-attributed to that worktree's network state dir (the ZOMBIE:
                                    launcher dead, tree alive, status answering, nothing deploying), removes
                                    the per-worktree network lock and a descriptor nobody serves, prints
                                    RECYCLED | RECYCLED-ZOMBIE | NOTHING-RUNNING. Never a global pkill, never
                                    a port/name match, never icp-cli's global flocks. The next deploy-all
                                    --changed escalates itself to a seeding deploy (stop = retirement)
  boot-env                          the environment every factory session boots with, printed as the
                                    `env -u ... K=V ...` word list that goes before the claude command:
                                    scrubs the desktop markers a Terminal window inherits from whichever
                                    session launched Terminal.app (CLAUDE_CODE_CHILD_SESSION - transcript
                                    saving OFF - its session id, messaging socket, DISABLE_MICROCOMPACT)
                                    and sets the reap opt-out, transcript persistence, the one-hour Bash
                                    cap behind the hourly idle watch, a 10-min Bash default, max effort,
                                    no self-update. spawn-successor applies it itself; a hand boot runs
                                    `cd <worktree> && $(scripts/factory.sh boot-env) claude ...`.
  boot-exec <seat|prioritizer> --model <m> --name <n>   what the spawn-successor / prioritizer-boot
                                    boot line runs INSIDE the new window:
                                    applies boot-env, reads the boot prompt from tasks/handoff/<seat>.md
                                    and execs claude, so the typed line stays short (the tty splits typed
                                    input at 1024 bytes while a new window's shell starts up; the line
                                    is refused above 1000). On a failure the window holds the error for
                                    10 min before its '; exit 0' closes it.
  executor-watch [path|auto] [stale-s] [poll-s]   liveness probe a seat BACKGROUNDS alongside each
                                    executor subagent: resolves the live activity dirs ITSELF from the
                                    worktree (both /private/tmp/claude-<uid>/<flattened-worktree> - the
                                    CLI-harness session dirs where backgrounded-command outputs stream -
                                    and ~/.claude/projects/<flattened-worktree>, the transcript store,
                                    live on desktop harnesses but stubs-only on CLI seats) PLUS the
                                    worktree's own edits (git ls-files -m -o --exclude-standard:
                                    modified + untracked files, .gitignore honoured, and the git admin
                                    index - foreground Edit/Write-only stretches and commits count;
                                    replica ticks under .icp/cache never do) PLUS lib.sh
                                    suite_output_guard's per-run logs at the TOP of <worktree>/.icp/
                                    cache (<label>.<YYYYmmdd-HHMMSS>.<pid>.log - where a tee'd
                                    deploy-all's output goes after its one announce line, so the pipe
                                    and the live log stay silent for the whole wave; networks/ and
                                    every subdirectory never count), takes the newest write
                                    across the set (an explicit path is ADDED, never a replacement),
                                    and exits printing EXECUTOR-STALE - naming the source of the
                                    newest write - once nothing was written anywhere for stale-s
                                    (default 1500, polling every poll-s, default 600; no file ever
                                    appearing gets the same grace from watchdog start) - the
                                    background completion re-invokes the seat, which judges recovery
                                    from disk (SKILL.md, the executor liveness watchdog).
                                    FACTORY_ACTIVITY_DIRS (colon-separated) overrides the resolved
                                    harness dirs entirely and FACTORY_WATCH_ROOT the worktree root
                                    (selftest / unusual layouts). The spawn this watch accompanies
                                    MUST carry the seat identity: paste 'factory.sh executor-env'
                                    (above) into the executor prompt's Bash-prefix rule
  heartbeat                         touch <worktree>/.factory-heartbeat for the pinned seat at/above the cwd.
                                    EVERY factory.sh command run inside a pinned worktree already does this
                                    (the structural "the model just ran a command" mark fleet-doctor reads);
                                    this is the explicit form for a cycle that runs no other factory command
  fleet-doctor [--stale-min N] [--respawn] [--dry-run] [--launchd-plist]
                                    the stall self-heal (the 2026-09-03 fleet-wide silent park): one verdict
                                    per pinned worktree - ACTIVE (a write inside the window: heartbeat, git
                                    index, harness activity dirs, a suite_output_guard per-run log at the
                                    top of .icp/cache - a tee'd deploy-all's detached output - or the tree
                                    minus node_modules/.icp/.git; every seat row's NOTE field ends with
                                    WHICH source made the newest write and when - "newest write <ISO
                                    instant> from: <source>", source = heartbeat | git index | harness
                                    activity dir <path> | guard log <file> | tree (a file newer than the
                                    threshold edge - the walk is a yes/no) - executor-watch's
                                    EXECUTOR-STALE shape, appended after the note's other words (an
                                    ACTIVE row's note is exactly that), never a new column: a false
                                    ACTIVE or STALLED is diagnosable from the fleet-doctor log alone,
                                    task 1792601787),
                                    STALLED (a live process named <prefix>-executor-<seat>, silent past N
                                    minutes - default 65, FACTORY_FLEET_STALE_MIN - while it holds a claim
                                    or a claimable task is queued: DEAD, not idle), QUIET (silent, nothing
                                    claimable - undecidable until work arrives), LOGGED-OUT (a live process
                                    whose own transcript ends on the CLI's "Login expired - Please run
                                    /login" message - task 1792504454: every pass first runs `claude auth
                                    status` (FACTORY_CLAUDE_BIN; the cli login: header line); logged out =
                                    the loud FLEET-LOGGED-OUT line + the one-login remedy, the stamp
                                    tasks/factory/fleet-logged-out the board's "CLI login" line reads, a
                                    macOS notification, and EVERY respawn held; once it reads logged in
                                    again --respawn REPLACES each parked LOGGED-OUT seat - the same
                                    handoff + kill-by-pid + spawn-successor path - and keeps a seat whose
                                    transcript moved past the login), UNMANNED (no process; an
                                    UNMANNED seat with a live spawn-pending stamp reads "spawn pending
                                    since <instant>, Terminal AppleEvents timing out - check Terminal: a
                                    modal, a hung tab, or Automation permission" and is NEVER respawned
                                    until the stamp expires or its process appears - task 1789588684; a
                                    manned seat's stamp is cleared on the pass) -
                                    plus the prioritizer by its board's age (bar >= 65 min: its watch sleeps
                                    an hour by design; UNMANNED reads "boot: scripts/factory.sh
                                    prioritizer-boot", and --respawn REVIVES an UNMANNED/STALLED
                                    prioritizer like a seat since task 1792506027 - parked pid killed by
                                    pid, then prioritizer-boot under the name guard, the spawn-pending
                                    stamp `prioritizer` holding respawns; "would: ... prioritizer-boot"
                                    under --dry-run - LOCAL mode only: on a HOSTED checkout (remote-status reads
                                    "mode: hosted") the prioritizer is the canister's own pass and no
                                    session runs here, so that verdict row is SUPPRESSED and one
                                    informational line "HOSTED  prioritizer ... the canister's pass (no
                                    session on this machine)" stands in - never a verdict, never a boot
                                    command, never counted; task 1791137234), and ORPHANED for a ROSTER
                                    seat whose worktree is gone (task
                                    1788956135: seat-7 / seat-14 vanished under live processes and the
                                    fleet silently shrank) - the line carries the first pass that saw it
                                    missing (tasks/factory/fleet-orphaned, the forensic anchor), whether a
                                    dead-husk process still carries its session name, the branch's
                                    ahead/behind main, the .done marker, the git prunable state + admin
                                    dir (present = rm -rf, absent = git worktree remove - the desktop
                                    app's GC shape), and the parent dir's mtime (brackets the deletion).
                                    Every pass also re-drops .worktree-keep into each pinned seat (the GC
                                    belt) and tags a seat still under .claude/worktrees/ with
                                    "legacy-location". Last line: FLEET-OK | FLEET-STALLED
                                    n | FLEET-DEGRADED n missing of N (never FLEET-OK while a seat is
                                    missing; orphans are never respawned - seat-recreate/seat-retire
                                    below) | FLEET-LOGGED-OUT n logged out ... (auth status reads logged
                                    out: every respawn held, the one-login remedy on the line). The
                                    roster (tasks/factory/fleet-roster) is written by
                                    worker-pin, ADOPTS any pinned worktree the doctor enumerates that is
                                    not on it yet, and is dropped only by seat-retire. REPORT-ONLY by
                                    default; --respawn (or FACTORY_FLEET_RESPAWN=1 - operator opt-in)
                                    writes a takeover handoff (with the COMPLETE/PARTIAL/ABSENT triage
                                    note when a claim is held), kills ONLY the pids carrying the seat's
                                    session name (TERM then KILL) and spawn-successors the seat; --dry-run
                                    prints that plan and touches nothing. --launchd-plist prints the
                                    operator-installed 15-min job (runs from the primary, logs to
                                    ~/Library/Logs)
  seat-roster                       the roster: "<seat>\t<worktree>\t<worker>\t<branch>\t<registered>" per
                                    line (+ "ORPHANED since <iso>" for a seat whose worktree is gone), or NONE
  seat-recreate <seat> [--no-spawn] OPERATOR command (from the primary): rebuild a VANISHED seat - refuses
                                    when the worktree exists; kills the dead-husk process carrying the
                                    seat's session name, drops the stale git admin entry for THAT path only
                                    (never a blanket prune - other orphans' admin dirs are evidence),
                                    fast-forwards claude/<seat> to main when 0 ahead (else keeps it and
                                    says so), git worktree add UNDER THE SEAT ROOT (seat-root above - a
                                    legacy .claude/worktrees row is relocated, the old tree being gone;
                                    the banner says "was <old path>"), ./scripts/bootstrap.sh in the tree (deps +
                                    keys symlinks; FACTORY_RECREATE_BOOTSTRAP=0 skips), worker-pin, a
                                    takeover handoff ("recreated after its worktree vanished", with the
                                    claim triage when one is held), spawn-successor (--no-spawn: boot by
                                    hand from the handoff), appends to the fleet-doctor log, prints the roster
  seat-retire <seat> [--dry-run] [--keep-branch]
                                    OPERATOR command (from the primary): the ONLY sanctioned way to drop a
                                    seat - kills the named process, REFUSES while any other live process
                                    has its cwd inside the tree (lsof: never remove a directory a session
                                    stands in), replica-recycle in the tree, git worktree remove --force,
                                    the stale admin entry, git branch -d (kept when unmerged; --keep-branch
                                    always keeps), the handoff file, the roster row, a line in the
                                    fleet-doctor log (FACTORY_FLEET_LOG overrides ~/Library/Logs/<prefix>-
                                    fleet-doctor.log). Retiring an ORPHANED seat skips the tree steps.
                                    Refuses the primary and refuses to run from inside the seat
  drill-worktree-prune [--dry-run]  HYGIENE door (task 1791286192; from any worktree, acts on the PRIMARY's
                                    registry): remove the abandoned upgrade-drill scratch worktrees - the
                                    REGISTERED git worktrees under this project's Claude scratchpads
                                    (/private/tmp/claude-<uid>/<dashed primary>*/<session>/scratchpad/...,
                                    the rule derived from the primary's path) that outlive their stopped
                                    replicas (three held ~17 GB of pocket-ic state on 2026-10-06). The
                                    candidate set is replica-doctor.sh --drill-worktrees (lsof attribution
                                    of live mains/launchers, the in-use test incl. .upgrade-drill.pid);
                                    for each prunable one: git worktree remove --force from the primary
                                    (twice for a locked tree, rm -rf as the last resort), then ONE git
                                    worktree prune (a dir the harness already GC'd leaves only a prunable
                                    admin entry - the prune covers it, the output says so), printing the
                                    state-dir size freed (du -sk of .icp/cache/networks/local). REFUSES by
                                    name: a live replica attributed to the tree, a live user (pid file /
                                    drill naming it / any cwd under it), the primary, a tree under a seat
                                    root, one carrying .factory-worker or on the roster, one you stand in.
                                    --dry-run lists what would go. fleet-doctor's header counts them
                                    ("drill worktrees: N (M prunable, X GB)"). Appends to the fleet log
  signal <worker|all> <text|file>   OPERATOR ORDER for one seat (or all seats): writes tasks/signal/<name>.md,
                                    which wakes every watch at once and REFUSES that seat's next claim until
                                    it is acknowledged (a second signal appends - a standing order is never
                                    lost; a re-sent `all` also RESETS the broadcast ack ledger, so every
                                    seat must acknowledge the changed order again)
  signal-list                       unacknowledged signals: "<addressee>\t<age>" per line, or NONE; the
                                    broadcast line adds its ack ledger: "all\t<age>\tacked N: w1 w2 ..."
  signal-clear <worker>             the seat's ACK: deletes its own <worker>.md; with a broadcast standing
                                    (and no <worker>.md) it records the seat in tasks/signal/all.acked/
                                    instead, so all.md stops blocking THAT seat and keeps blocking the rest.
                                    From a refused claim until its ack, it acks only what the refusal
                                    showed: an order that landed after stands, and the next claim prints
                                    it (an operator withdrawing an order in that span uses --if)
  signal-clear <worker> --if '<crc> <size>'
                                    the same, only while the order standing is the one read (what cksum
                                    printed for it): a per-seat order changed since is refused; a changed
                                    broadcast, or none, is "no order ... stands as it was read" (exit 0).
                                    Local mode only: the hosted client is not given --if
  signal-clear all                  the OPERATOR's hard delete of the broadcast and its whole ack ledger
  watch [max-seconds]               block until queue/claimed/archive/signal change; prints CHANGED or TIMEOUT
                                    (idle doctrine: 3300 with the Bash timeout at 3600000 ms - every return is a
                                    full-context model turn; clamped a minute under BASH_MAX_TIMEOUT_MS, so a
                                    session booted without boot-env gets 540 s and a stderr line naming why)
  merge-lock acquire <label> [max-wait-s] [--task <id>]
                                    the cross-session lock around merges into main. --task is the CLAIM
                                    BELT: refused - before waiting, and again once held (released first) -
                                    unless that task is still CLAIMED by this seat (locally
                                    tasks/claimed/<worker>/, hosted the canister's state), so a requeue
                                    that landed while you worked stops the merge instead of landing
                                    behind it. The operator acting on another seat's claim omits --task;
                                    FACTORY_FORCE=1 turns the refusal into a warning
  merge-lock release [label]        release: the label must be the owner's (FACTORY_FORCE=1 overrides)
  merge-lock status                 the holder and the age of the hold
  merge-land <branch> (-m '<message>' | -F <file>) [--task <id>]
                                    TaskConsumer step 6d-6h as ONE door (task 1792601027), run from the
                                    seat's worktree under a lock ALREADY held for <branch>: the primary
                                    preflight (index.lock, MERGE_HEAD, main checked out), lint-stable-compat
                                    --changed + lint-package-consumers --changed + lint-claude-invariants
                                    --changed from this worktree (FACTORY_LINT_DIR names the scripts/ dir;
                                    LINT_STABLE_COMPAT=0 / LINT_PACKAGE_CONSUMERS=0 / LINT_CLAUDE_INVARIANTS=0
                                    are the protocol's recorded skips; a script not found refuses), the
                                    ancestor check, the `merge --no-ff` into the primary's
                                    main with the message from -m or -F, THE PROOF (main's sha before and
                                    after are printed and must differ, and <branch> must be an ancestor of
                                    main - "Already up to date." is a FAILURE, never a landing), the push (a
                                    failure prints "PUSH FAILED: <why>" and never blocks; FACTORY_PUSH_BAR_S,
                                    default 600, bounds a hung push by pid) and the lock release. Refuses
                                    outside a lock held for <branch>, when the primary resolves to THIS
                                    worktree (the self-merge shape: the 2026-10-21 "Already up to date."
                                    landing of nothing), and with "nothing to merge" when <branch> has no
                                    commits beyond main; every refusal after the lock check releases the
                                    lock and lands nothing. --task re-runs the claim belt right before the
                                    merge. Last stdout line of a landing: "merged <sha>" (the archive note)
                                    Since task 1792739412 the step-6d gate is FOUR lints: lint-package-js-imports
                                    --changed runs after lint-claude-invariants (a plain-JS module of a shared
                                    npm package imports only what Node loads natively, judged over the npm
                                    packages whose src/ the branch touched - instant OK when none was;
                                    LINT_PACKAGE_JS_IMPORTS=0 is its recorded skip; a script not found refuses
                                    the same way)

HOSTED MODE (Open Factories - docs/architecture/open-software-factories.md section 10):
  when <primary>/.factory-remote/config.json exists (FACTORY_REMOTE_DIR overrides), the queue
  commands new/list/show/claim/done/requeue/reprioritize/index/signal/signal-list/signal-clear/watch
  go to tools/factory-client (signed by the machine's ed25519 runner key, every mutation opId-replayed,
  transport errors retried, canister refusals printed verbatim) with the same stdout shapes as local
  mode; the seat-side gates (worker line, signal gate, primary refusal, recycle gate, heartbeat stamp)
  still run here. claim --operator --id <id> is the Operator SESSION's door (task_take under the runner,
  seat "operator"); an untargeted claim --operator has no hosted arm (the browser's Needs-a-human page).
  remote-pair <osf-url> <OSFR-code> [--label L] [--force]   pair this checkout: mints the runner key (--force = FACTORY_FORCE=1: re-pair a REVOKED runner with the existing key)
                                    REFUSES first, before any network call, while tools/factory-client is
                                    untracked or gitignored (a seat worktree would have no client);
                                    (.factory-remote/runner.pem, 0600), resolves the backend id from
                                    the URL's discovery catalog, redeems the code an owner minted on
                                    the factory's Fleet -> Runners tab; from then on: hosted mode
  remote-status                     client: tracked | UNTRACKED <path> (ignored by <rule>) first (is the client
                                    COMMITTED? a seat worktree has only what git has), then mode, factory,
                                    runner (whoami), last poll, ground-map sha, cursors
  remote-unpair                     FACTORY_FORCE=1 required: delete config + key, back to local mode
  remote-import [--dry-run] [--include-archive] [--include-claims]
                                    the 16.1 migration: move THIS checkout's local directory factory
                                    (tasks/queue, claimed/<worker> with --include-claims, archive with
                                    --include-archive, pending tasks/signal + all.acked) into the paired
                                    hosted factory with IDS PRESERVED - staged then committed as ONE
                                    batch (task_import_begin/task_import/task_import_commit), idempotent
                                    by id (an identical record is unchanged, a different body is
                                    IMPORT-CONFLICT <id> and nothing lands), claims re-leased under the
                                    same seats, archive status/note/.done report intact, Factory-log
                                    lines carried verbatim, after: re-validated live-ids-only over the
                                    whole batch, the hosted allocator moved above the range. --dry-run
                                    prints the plan (counts per state, id range, conflicts) and imports
                                    nothing. A real import FREEZES the local allocator
                                    (tasks/factory/.ids/FROZEN - local 'new' refuses past it) and logs
                                    to tasks/factory/imported-<date>.log; local files are never deleted
                                    (the imported tasks/signal files move aside to signal/.imported-<stamp>/
                                    so the hosted signal gate is the only one a seat meets from then on).
                                    PRIMARY checkout only, hosted mode required, refused while the
                                    merge lock is held
  remote-export [--out <dir>]       the reverse: the hosted factory written into the directory layout
                                    (queue/ claimed/<seat>/ archive/ signal/ + reports/<id>.md) at a
                                    FRESH directory (default tasks/factory/export-<stamp>) - the
                                    cutover's exit and a backup; same gates as remote-import
  remote-poll [--once] [--launchd-plist]   the poller (one launchd job, single-instance lock): every
                                    OSF_POLL_SECS (60) telemetry -> runner_heartbeat (seats from the
                                    roster: heartbeat age, live process, commits beyond main, replica
                                    footprint/age, fleet-doctor verdict; the machine line), the ground
                                    write-back (the producer's approved doc changes -> authored commits
                                    on main under the merge lock; FACTORY_WORKER must be unset), the
                                    ground map (upload on main-sha change + pull-through tickets), the Operator + Supervisor
                                    lane sessions (one headless claude -p --resume per lane, concurrent;
                                    OSF_CLAUDE_BIN / OSF_TURN_MAX_MIN / OSF_LANE_BACKOFF_MS), alerts
                                    (RUNNER-REVOKED, factory archived). --launchd-plist prints the
                                    KeepAlive agent <prefix>.osf-poll (log ~/Library/Logs)
EOF
}

# --- dispatch ---------------------------------------------------------------

main() {
  local cmd="${1:-help}"; shift || true
  resolve_root
  shopt -s nullglob
  # The seat heartbeat: any command run from inside a pinned worktree marks it
  # (fleet-doctor reads the mark; see the fleet section). Help is exempt.
  case "$cmd" in help|-h|--help) : ;; *) heartbeat_touch ;; esac
  # Hosted mode: the queue commands go to the client; everything else is local.
  case "$cmd" in
    new|list|show|claim|done|requeue|reprioritize|index|signal|signal-list|signal-clear|watch|amend)
      if hosted_mode; then cmd_hosted "$cmd" "$@"; return $?; fi ;;
  esac
  case "$cmd" in
    root)          cmd_root "$@" ;;
    remote-pair)   cmd_remote_pair "$@" ;;
    remote-status) cmd_remote_status "$@" ;;
    remote-unpair) cmd_remote_unpair "$@" ;;
    remote-poll)   cmd_remote_poll "$@" ;;
    remote-import) cmd_remote_import "$@" ;;
    remote-export) cmd_remote_export "$@" ;;
    worker-pin)    cmd_worker_pin "$@" ;;
    worker)        cmd_worker "$@" ;;
    executor-env)  cmd_executor_env "$@" ;;
    new)           cmd_new "$@" ;;
    amend)         die "amend is a hosted-mode command (the canister's task_amend); in local mode edit the claimed file under tasks/claimed/<worker>/ directly" ;;
    list)          cmd_list "$@" ;;
    show)          cmd_show "$@" ;;
    claim)         cmd_claim "$@" ;;
    done)          cmd_done "$@" ;;
    requeue)       cmd_requeue "$@" ;;
    reprioritize)  cmd_reprioritize "$@" ;;
    index)         cmd_index "$@" ;;
    handoff-list)  cmd_handoff_list "$@" ;;
    handoff-clear) cmd_handoff_clear "$@" ;;
    spawn-successor) cmd_spawn_successor "$@" ;;
    prioritizer-boot) cmd_prioritizer_boot "$@" ;;
    boot-env)      cmd_boot_env "$@" ;;
    boot-exec)     cmd_boot_exec "$@" ;;
    executor-watch) cmd_executor_watch "$@" ;;
    heartbeat)     cmd_heartbeat "$@" ;;
    fleet-doctor)  cmd_fleet_doctor "$@" ;;
    seat-roster)   cmd_seat_roster "$@" ;;
    seat-root)     cmd_seat_root "$@" ;;
    seat-recreate) cmd_seat_recreate "$@" ;;
    seat-retire)   cmd_seat_retire "$@" ;;
    replica-recycle) cmd_replica_recycle "$@" ;;
    drill-worktree-prune) cmd_drill_worktree_prune "$@" ;;
    signal)        cmd_signal "$@" ;;
    signal-list)   cmd_signal_list "$@" ;;
    signal-clear)  cmd_signal_clear "$@" ;;
    watch)         cmd_watch "$@" ;;
    merge-lock)    cmd_merge_lock "$@" ;;
    merge-land)    cmd_merge_land "$@" ;;
    help|-h|--help) cmd_help ;;
    *) die "unknown command '$cmd' (factory.sh help)" ;;
  esac
}

main "$@"
