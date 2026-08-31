#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# factory.sh - the MULTI/DEX software-factory task queue.
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
# work law 8 forbids consumer seats to run (remote targets - engine/subnet -
# pushes, and anything needing human-held auth). `claim` never hands one
# out; `claim --operator` claims only those. See is_operator_lane() below.
#
# tasks/signal/<worker>.md (and all.md) is the OPERATOR's control channel to a
# seat: it wakes every `watch` and blocks that seat's next `claim` until the
# seat acknowledges it with `signal-clear`. See the signals section below.
#
# Two multidex gates ride the lifecycle:
#   - the POSTURE LAW (merge_gate, at merge-lock acquire): a seat's branch
#     merges only with src/backend/main.mo AND src/bridge/main.mo resolving
#     to #play (via mdx_posture_of - the ONE comment-aware reader, W1-02)
#     and no `port: 0` line in icp.yaml (the worktree-venue temp edit).
#   - the BOOKKEEPING LAW (docfile_gate, at done): a task executing a
#     docs/tasks/ brief archives as done only after the brief left its
#     original path (moved to docs/tasks/done/ on the merged branch).
#
# Works from the primary checkout or any git worktree of it (the queue root
# resolves to the PRIMARY checkout's tasks/ either way). FACTORY_TASKS_ROOT
# overrides the root - scripts/factory-selftest.sh uses it to exercise this
# script against a throwaway queue; FACTORY_PRIMARY likewise overrides the
# repo the merge gate inspects.
#
# FACTORY_WORKER pins the claim identity when the cwd's branch is not the
# seat's: harness-BACKGROUNDED invocations inherit the harness default cwd,
# whose branch can name a DIFFERENT seat. An explicit [worker] arg still
# wins. requeue/done locate claimed tasks BY ID across all workers, so they
# carry no identity and are safe from any cwd.
#
# <worktree-root>/.factory-worker is the DURABLE form of that pin: a seat
# writes it ONCE at boot (`factory.sh worker-pin`) and every later invocation
# from anywhere inside that worktree - executor subagents included, since they
# run inside it by construction - resolves the same identity without consulting
# the branch. Resolution order is: explicit [worker] arg > --operator >
# FACTORY_WORKER > .factory-worker (searched up from $PWD to the worktree root)
# > the cwd branch. Absent the file, behaviour is exactly as before. When the
# pin and the cwd-derived name DISAGREE, claim says so on stderr - that
# disagreement IS the drift the pin exists to catch (upstream open-saas
# factory, 2026-08-05 and again 2026-08-19: a subagent claim landed under
# another seat's identity, so the board and tasks/claimed lied about who held
# what).
# ---------------------------------------------------------------------------
set -euo pipefail
export LC_ALL=C

die()  { echo "factory: ERROR: $*" >&2; exit 1; }
info() { echo "factory: $*" >&2; }

# --- root resolution --------------------------------------------------------

resolve_root() {
  PRIMARY=""
  if [ -n "${FACTORY_TASKS_ROOT:-}" ]; then
    TASKS="$FACTORY_TASKS_ROOT"
  else
    PRIMARY="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || true)"
    [ -n "$PRIMARY" ] || die "not inside the multidex repo and FACTORY_TASKS_ROOT is unset"
    TASKS="$PRIMARY/tasks"
  fi
  QUEUE="$TASKS/queue"; CLAIMED="$TASKS/claimed"; ARCHIVE="$TASKS/archive"; FACTORY="$TASKS/factory"
  IDS="$FACTORY/.ids"   # append-only id allocator: one dir per id ever minted
  # Pending seat handoffs: one file per worktree awaiting a successor session.
  # A staged successor CHIP does not survive an app restart, so the boot
  # prompt is also written here, where a restart cannot reach it.
  HANDOFF="$TASKS/handoff"
  # Operator ORDERS to a seat: one file per addressee (see the signals section).
  SIGNAL="$TASKS/signal"
  mkdir -p "$QUEUE" "$CLAIMED" "$ARCHIVE" "$FACTORY" "$IDS" "$HANDOFF" "$SIGNAL"
}

# --- small helpers ----------------------------------------------------------

now_s()   { date -u +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
pad()     { printf '%010d' "$((10#$1))"; }   # 10# so leading zeros are not octal

title_of() { sed -n 's/^# \(.*\)$/\1/p' "$1" 2>/dev/null | head -1; }
# Frontmatter-ish field: first "key: value" line in the first 40 lines.
field_of() { sed -n '1,40p' "$1" 2>/dev/null | sed -n "s/^$2:[[:space:]]*//p" | head -1; }

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

# The OPERATOR LANE. Work that law 8 forbids a consumer to execute (engine
# and subnet deploys, pushes, anything needing human-held auth) carries
# "lane: operator" and is never handed to a consumer seat. Parking such a
# task in band 90 only DELAYS a claim - with a contended queue "nothing else
# remains" arrives routinely, and the seat then reads the task, discovers it
# must not act, and requeues, burning a whole cycle. The lane refuses
# instead of delaying.
is_operator_lane() { [ "$(field_of "$1" lane)" = "operator" ]; }

touches_of()     { field_of "$1" touches | tr ',' ' '; }
active_touches() { local c; for c in "$CLAIMED"/*/*.md; do touches_of "$c"; echo; done | tr '\n' ' '; }

overlaps() {  # does $1's touches list overlap any active claim's? ("suite" = everything)
  local mine act a b
  mine="$(touches_of "$1")"
  act="$(active_touches)"
  case "$act" in *[!\ ]*) : ;; *) return 1 ;; esac   # no active claims -> no overlap
  case " $mine " in *" suite "*) return 0 ;; esac    # repo-wide task vs any claim
  case " $act "  in *" suite "*) return 0 ;; esac    # any repo-wide claim vs us
  for a in $mine; do for b in $act; do [ "$a" = "$b" ] && return 0; done; done
  return 1
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

# The BOOKKEEPING LAW, mechanically: a queue task that executes a tracked
# docs/tasks/ brief (frontmatter `docfile:`, comma list allowed) may archive
# as done only when each brief has LEFT its original path in the closing
# checkout - i.e. it was moved to docs/tasks/done/ (with its completion note
# and its README row struck) on the branch that merged. Purely positional:
# the gate makes FORGETTING the bookkeeping impossible; it does not judge
# the note. Operator-lane closes are exempt (remote rollouts re-run code
# whose consumer task already did the bookkeeping). FACTORY_FORCE=1
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

# The POSTURE LAW, mechanically: a branch merges into main only on the
# committed defaults. src/backend/main.mo AND src/bridge/main.mo must
# resolve to #play via mdx_posture_of (scripts/lib/targets.sh - the ONE
# comment-aware, ambiguity-refusing reader; W1-02 exists because a lesser
# grep here would recreate the divergence that task killed), and icp.yaml
# must carry no `port: 0` line (the worktree-venue recipe's uncommitted
# gateway edit). Runs at merge-lock acquire - the last gate before a
# flipped posture or a port-0 gateway would propagate to main. The #dev
# flip is a legitimate SEAT-LOCAL state (the venue runs #dev); this gate is
# what lets it exist without ever reaching main. Skips loudly when the
# label is not a branch (pass your branch name to acquire). Fails CLOSED on
# an unreadable file or a broken lib - FACTORY_FORCE=1 overrides.
merge_gate() {  # $1 = branch-or-worker label given to merge-lock acquire
  local label="$1" repo tmp posture file bad=""
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
  done
  if git -C "$repo" show "$label:icp.yaml" 2>/dev/null | grep -qE 'port:[[:space:]]*0([^0-9]|$)'; then
    bad="$bad icp.yaml:port-0"
  fi
  rm -rf "$tmp"
  [ -z "$bad" ] && return 0
  if [ "${FACTORY_FORCE:-}" = "1" ]; then
    echo "factory: warning: posture gate overridden (FACTORY_FORCE=1) -$bad" >&2
    return 0
  fi
  die "merge-lock refused for '$label':$bad - a branch merges only on #play/#play with no port-0 icp.yaml (the posture law, .claude/skills/mdex-software-factory/SKILL.md). Restore the committed defaults on the branch, commit, and re-acquire; FACTORY_FORCE=1 overrides."
}

# --- worker identity (the seat pin) -----------------------------------------
# A seat's identity used to be DERIVED per command from the cwd's git branch.
# That is exactly wrong for executor subagents and harness-backgrounded shells,
# whose cwd drifts to another worktree and mints another seat's name (twice
# upstream: 2026-08-05, recurred 2026-08-19). So a seat PINS its identity once
# at boot into <worktree-root>/.factory-worker; every command run anywhere
# inside that tree reads it back. The file is gitignored runtime state, one
# line, plain text.

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
# control plane: upstream (open-saas, 2026-08-19) a five-seat hand-off by
# message failed three ways inside an hour - messages parked unread behind
# hour-long `watch` polls; on wake the notification and the message competed and
# seats acted on fresh queue state first (one claimed new work despite a
# do-not-claim order); and three of five improvised. Signals ride the filesystem
# the seats already poll instead: watch_sig() covers signal/, so an order wakes
# every long poll at once, and claim REFUSES while one addresses the claiming
# worker - a seat cannot take new work before its order is processed, which
# fixes the ordering race by construction. Deleting the file (signal-clear) IS
# the acknowledgement.

signal_pending() {  # print the signal files addressing worker $1, broadcast first
  local f
  for f in "$SIGNAL/all.md" "$SIGNAL/$1.md"; do
    [ -e "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

signal_gate() {  # $1 = worker; refuses the claim while an unacknowledged order stands
  local pending f
  pending="$(signal_pending "$1")"
  [ -n "$pending" ] || return 0
  if [ "${FACTORY_FORCE:-}" = "1" ]; then
    echo "factory: warning: operator-signal gate overridden (FACTORY_FORCE=1) - unread: $(printf '%s' "$pending" | tr '\n' ' ')" >&2
    return 0
  fi
  {
    echo "factory: ERROR: claim refused: an operator signal is waiting for '$1' - do what it says FIRST, then acknowledge it (factory.sh signal-clear <name>) and claim again (FACTORY_FORCE=1 overrides)"
    for f in $pending; do
      echo "  --- $f"
      sed 's/^/  /' "$f"
    done
  } >&2
  exit 1
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
  f="$top/$PIN_FILE"
  if [ -f "$f" ]; then
    cur="$(head -1 "$f" 2>/dev/null | tr -d '[:space:]')"
    [ "$cur" = "$name" ] || info "repinning seat identity: was '$cur'"
  fi
  printf '%s\n' "$name" > "$f"
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

cmd_new() {
  local draft="${1:-}" stage id tries=0 target dep bad="" known m
  [ -n "$draft" ] && [ -f "$draft" ] || die "usage: factory.sh new <draft.md> (draft file must exist)"
  [ -n "$(title_of "$draft")" ] || die "draft has no '# <title>' line"
  # after:-reference validation (ported from the open-saas factory's
  # 2026-08-17 incident fix): a filing whose after: names an id that was
  # never minted gates NOTHING - claim's live-ids-only rule (correct,
  # unchanged) treats an unknown id as satisfied, so one guessed id
  # silently un-gates a strictly ordered chain (upstream, five guessed-id
  # gates let four "sequential" tasks claim concurrently within a minute).
  # Refuse the filing instead - the producer knows the real intent; new
  # cannot guess it. Existence = the append-only allocator (every id ever
  # minted, O(1)) with the queue/claimed/archive file scan as a belt for
  # foreign state. nullglob is on (main), so unmatched archive-variant
  # globs VANISH - test each candidate with -e, never pass a glob to an
  # external (an empty ls succeeds and defeats the check).
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
  target="$QUEUE/$(pad "$id")-$(pad "$id").md"
  ln "$stage" "$target" || { rm -f "$stage"; die "cannot create $target"; }
  rm -f "$stage"
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
  local worker="" want_op=0 want_id="" affinity="" top attempt=0 soft chosen f dest
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
  # The primary checkout is off limits to CONSUMERS (law 5). --operator is
  # the operator's own lane and the primary is one of the places they work.
  if [ -n "$PRIMARY" ] && [ "$want_op" -eq 0 ] && [ "${FACTORY_FORCE:-}" != "1" ]; then
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ "$top" = "$PRIMARY" ] && die "claim refused from the primary checkout - consumers work in worktrees (FACTORY_FORCE=1 overrides)"
  fi
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
    soft=""; chosen=""; head=""; head_band=""; aff=0
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
        [ -n "$soft" ] || soft="$f"
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
    [ -n "$chosen" ] || chosen="$soft"   # everything eligible overlaps: take head anyway
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
  if [ "$status" = "done" ]; then docfile_gate "$FOUND"; fi
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
    prio="$(pad "$((10#$band * 100000000 + 10#$(pad "$id") % 100000000))")"
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
    1|2) prio="$(pad "$((10#$key * 100000000 + 10#$p % 100000000))")" ;;
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
# which is exactly the signal that goes missing when a staged chip evaporates
# with an app restart.

file_age_line() {  # file_age_line <file> <now-epoch> -> "<basename>\t<age>" (handoffs, signals)
  local f="$1" now="$2" age h m
  age=$(( (now - $(stat -f %m "$f")) / 60 ))
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
      case "$w" in */*|*..*) : ;; *) printf '%s\n' "$w" > "$top/$PIN_FILE"; info "seat pinned as '$w' ($top/$PIN_FILE)" ;; esac
    fi
  fi
}

# --- successor spawning (CLI seats) -----------------------------------------
# A desktop seat stages a successor CHIP at handoff; a CLI seat has no chip
# tool, so (per the worker doctrine, claude CLI at ~/.local/bin/claude) it
# spawns its own successor Terminal: `spawn-successor <worktree-basename>`
# reads the pending tasks/handoff/<basename>.md - the handoff file is the
# TOKEN, so handoff first, spawn second, and a missing file is a refusal -
# extracts the boot prompt and the worktree path, and opens a new macOS
# Terminal window running the pinned-model claude CLI with that prompt. The
# handoff file is NOT cleared here: the successor's own handoff-clear is the
# ack, so a spawn that dies still leaves the seat visible on handoff-list
# (recoverable by hand). Session names carry the PROJECT PREFIX - several
# projects run this factory pattern on one machine, so bare seat names are
# ambiguous in cross-project listings: the spawned session is named
# '<prefix>-executor-<worktree-basename>' (or '<prefix>-worker-<seat>' when
# the boot prompt is not executor-mode). The prefix is DERIVED, never
# hardcoded: FACTORY_PROJECT env if set, else the primary checkout's
# directory basename with any -ng/-main suffix dropped (here multidex ->
# multidex), so forks inherit correct names for free.
# Zero-residue windows (upstream task 1787177577): the spawned command ends
# "; exit 0" so the window's shell exits cleanly the moment claude exits -
# even when the handoff self-kill ends claude with a signal exit code
# (137/143) - and the program applies the operator's "Factory" Terminal
# settings set (the profile with "When the shell exits: Close the window")
# to the window it creates, inside an AppleScript try block: no such
# settings set means the spawn proceeds without it and the success banner
# names the one-time manual setup. Only spawned windows get the profile -
# the operator's own windows keep default behavior.
# FACTORY_SPAWN_DRYRUN=1 prints the session name and the osascript program
# instead of running it (selftest + eyeballing); FACTORY_CLAUDE_BIN /
# FACTORY_CLAUDE_MODEL override the binary and model for testing - the fleet
# default stays pinned.

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

cmd_spawn_successor() {
  local name="${1:-}" f wt prompt cbin cmodel shcmd script prefix sname res
  [ -n "$name" ] || die "usage: factory.sh spawn-successor <worktree-basename>"
  name="$(basename "$name" .md)"
  f="$HANDOFF/$name.md"
  [ -f "$f" ] || die "no pending handoff for '$name' - write tasks/handoff/$name.md first (handoff, then spawn; factory.sh handoff-list)"
  # Worktree path: the "cd <path> && claude" boot line the handoff convention
  # carries; fall back to matching the basename against git worktree list.
  wt="$(sed -n 's/^cd \(.*\) && claude.*$/\1/p' "$f" | head -1)"
  if [ -z "$wt" ]; then
    wt="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | grep "/$name\$" | head -1 || true)"
  fi
  [ -n "$wt" ] || die "cannot resolve the worktree path for '$name' (no 'cd <path> && claude' line in $f and no matching worktree)"
  [ -d "$wt" ] || die "worktree '$wt' does not exist"
  # Boot prompt: everything after the "## Boot prompt" marker (the convention
  # since spawn-successor exists); legacy files carry the prompt after the
  # cd-boot line instead. Markdown fences are noise either way.
  prompt="$(awk '/^## Boot prompt/{found=1; next} found' "$f" | sed '/^```/d')"
  if [ -z "$(printf '%s' "$prompt" | tr -d '[:space:]')" ]; then
    prompt="$(awk 'found && $0 !~ /^```/ {print} /^cd .* && claude/{found=1}' "$f")"
  fi
  # The prompt travels as ONE shell argument inside an AppleScript string
  # literal, and AppleScript literals cannot span lines - flatten to one line
  # (prompts are prose; collapsed whitespace reads the same).
  prompt="$(printf '%s' "$prompt" | tr '\n' ' ' | sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//')"
  [ -n "$(printf '%s' "$prompt" | tr -d '[:space:]')" ] || die "no boot prompt found in $f (add a '## Boot prompt' section)"
  cbin="${FACTORY_CLAUDE_BIN:-$HOME/.local/bin/claude}"
  cmodel="${FACTORY_CLAUDE_MODEL:-claude-fable-5}"   # the fleet rule: consumer seats run Fable 5
  # Project-prefixed session name: executor boots (the standard worker mode -
  # the boot prompt says "executor") get <prefix>-executor-<seat>; anything
  # else gets <prefix>-worker-<seat>.
  prefix="$(project_prefix)"
  case "$prompt" in
    *[Ee]xecutor*) sname="$prefix-executor-$name" ;;
    *)             sname="$prefix-worker-$name" ;;
  esac
  # "; exit 0" ends the window's shell cleanly the moment claude exits, even
  # when the handoff self-kill ends claude by signal (137/143) - paired with
  # the "Factory" settings set below, the retired seat's window closes itself.
  shcmd="cd $(sq "$wt") && $(sq "$cbin") --model $(sq "$cmodel") --name $(sq "$sname") $(sq "$prompt"); exit 0"
  script="tell application \"Terminal\"
  activate
  set newTab to do script \"$(aq "$shcmd")\"
  try
    set current settings of newTab to settings set \"Factory\"
    return \"profile: Factory\"
  on error
    return \"profile: none\"
  end try
end tell"
  if [ -n "${FACTORY_SPAWN_DRYRUN:-}" ]; then
    printf 'DRYRUN session name: %s\n' "$sname"
    printf 'DRYRUN osascript program:\n%s\n' "$script"
    return 0
  fi
  [ -x "$cbin" ] || die "claude CLI not found at $cbin (FACTORY_CLAUDE_BIN overrides) - boot by hand: $shcmd"
  command -v osascript >/dev/null 2>&1 || die "osascript unavailable (not macOS / no Terminal automation) - boot by hand: $shcmd"
  res="$(osascript -e "$script")" || die "Terminal automation failed (check System Settings > Privacy > Automation) - boot by hand: $shcmd"
  echo "spawned successor Terminal for $name ($wt)"
  case "$res" in
    *"profile: none"*)
      info "no 'Factory' Terminal settings set - the window will sit at a dead prompt after the seat retires."
      info "one-time setup: Terminal > Settings > Profiles > duplicate a profile, name it Factory, set 'When the shell exits' to 'Close the window'."
      ;;
  esac
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
  # the seat has not acknowledged yet cannot be lost under a later one.
  {
    if [ -e "$target" ]; then cat "$target"; echo; fi
    echo "# Operator signal to $who ($(now_iso))"
    echo
    if [ -f "$body" ]; then cat "$body"; else printf '%s\n' "$body"; fi
  } > "$stage"
  if [ -e "$target" ]; then info "appended to the standing signal for $who"; fi
  mv "$stage" "$target" || { rm -f "$stage"; die "cannot write $target"; }
  echo "$target"
}

cmd_signal_list() {
  local f now n=0
  now="$(now_s)"
  for f in "$SIGNAL"/*.md; do
    n=$((n+1))
    printf '%s\n' "$(file_age_line "$f" "$now")"
  done
  [ "$n" -gt 0 ] || echo "NONE"
}

cmd_signal_clear() {
  local name="${1:-}" f
  [ -n "$name" ] || die "usage: factory.sh signal-clear <worker|all>"
  name="$(basename "$name" .md)"
  f="$SIGNAL/$name.md"
  [ -f "$f" ] || die "no signal addressed to '$name' (factory.sh signal-list)"
  rm -f "$f"
  echo "cleared $name"
}

cmd_index() {
  local out="$FACTORY/index.md" tmp="$FACTORY/.index.$$" f w now age flag
  now="$(now_s)"
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
    echo "## Operator lane (remote targets / human-held auth - consumers never claim these)"
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
      age=$(( (now - $(stat -f %m "$f")) / 60 ))
      flag=""; [ "$age" -ge 240 ] && flag=" **STALE?**"
      printf -- '- `%s` <- %s (%sm)%s %s\n' "$(basename "$f")" "$w" "$age" "$flag" "$(title_of "$f")"
    done
    echo
    # A seat that handed off but whose successor never booted is INVISIBLE
    # otherwise: its worktree sits idle, its chip may have evaporated with an
    # app restart, and the fleet quietly shrinks. One line per pending file.
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
      printf -- '- `%s` sent %s ago - the addressee acknowledges with: factory.sh signal-clear %s\n' \
        "$(basename "$f" .md)" "$(file_age_line "$f" "$now" | cut -f2)" "$(basename "$f" .md)"
    done
    echo
    echo "## Recently archived"
    echo
    ls -t "$ARCHIVE" 2>/dev/null | head -15 | while IFS= read -r f; do
      printf -- '- `%s` %s\n' "$f" "$(title_of "$ARCHIVE/$f")"
    done
  } > "$tmp"
  mv "$tmp" "$out"
  echo "$out"
}

# signal/ is IN the signature on purpose: an operator order must wake every
# long poll the moment it lands, with no queue-touch hack to shake the seats.
watch_sig() { ls -Rl "$QUEUE" "$CLAIMED" "$ARCHIVE" "$SIGNAL" 2>/dev/null | cksum; }

# The obituary: backgrounded watches on this machine get killed by an external
# 30-min-grid sweep (2026-08-20, hh:06:42/hh:36:42, across every CLI seat and
# project at once — task 1787260290). A silent death reads as noise and once
# sent a seat dormant for 10h; this one line in the harness task output says
# WHO/WHAT instead. Signal-only: the CHANGED/TIMEOUT contract on stdout is
# byte-identical, the obituary goes to stderr. A kill that leaves NO obituary
# behind a "[killed]" marker means SIGKILL — untrappable, and diagnostic too.
watch_obituary() {
  local signame="$1" pp="alive"
  kill -0 "$PPID" 2>/dev/null || pp="dead"
  echo "factory.sh watch: killed by SIG$signame at $(date -u '+%Y-%m-%dT%H:%M:%SZ') (pid $$, ppid $PPID $pp)" >&2
  trap - "$signame"
  kill "-$signame" $$
}

cmd_watch() {
  local max="${1:-500}" sig cur waited=0
  trap 'watch_obituary TERM' TERM
  trap 'watch_obituary INT'  INT
  trap 'watch_obituary HUP'  HUP
  sig="$(watch_sig)"
  while [ "$waited" -lt "$max" ]; do
    # sleep as a child under `wait`, not inline: bash delivers a trapped
    # signal to a `wait` immediately, so the obituary prints at kill time
    # instead of up to 10s later (or never, if the 10s never finishes).
    sleep 10 & wait $! || true
    waited=$((waited+10))
    cur="$(watch_sig)"
    [ "$cur" != "$sig" ] && { echo "CHANGED"; return 0; }
  done
  echo "TIMEOUT"
}

cmd_merge_lock() {
  local sub="${1:-}" label="${2:-}" max="${3:-240}" lock="$FACTORY/merge.lock"
  local owner ts age waited=0
  case "$sub" in
    acquire)
      [ -n "$label" ] || die "usage: factory.sh merge-lock acquire <branch-or-worker> [max-wait-s]"
      merge_gate "$label"
      while ! mkdir "$lock" 2>/dev/null; do
        owner="$(cat "$lock/owner" 2>/dev/null || echo unknown)"
        ts="$(cat "$lock/ts" 2>/dev/null || echo 0)"
        age=$(( $(now_s) - 10#${ts:-0} ))
        if [ "$age" -gt 1800 ]; then
          # Merges take minutes; a 30-min-old lock is a dead session's. The
          # mv-then-rm break means two waiters cannot both win.
          if mv "$lock" "$lock.breaking.$$" 2>/dev/null; then
            rm -rf "$lock.breaking.$$"
            info "broke stale merge lock (owner $owner, ${age}s old)"
          fi
          continue
        fi
        [ "$waited" -ge "$max" ] && die "merge lock held by $owner (${age}s old); retry later"
        sleep 5; waited=$((waited+5))
      done
      echo "$label" > "$lock/owner"; now_s > "$lock/ts"
      echo "acquired"
      ;;
    release)
      [ -d "$lock" ] || { echo "already free"; return 0; }
      owner="$(cat "$lock/owner" 2>/dev/null || echo unknown)"
      if [ -n "$label" ] && [ "$label" != "$owner" ] && [ "${FACTORY_FORCE:-}" != "1" ]; then
        die "merge lock is owned by '$owner', not '$label' (FACTORY_FORCE=1 overrides)"
      fi
      rm -rf "$lock"
      echo "released"
      ;;
    status)
      if [ -d "$lock" ]; then
        ts="$(cat "$lock/ts" 2>/dev/null || echo 0)"
        echo "held by $(cat "$lock/owner" 2>/dev/null || echo unknown) for $(( $(now_s) - 10#${ts:-0} ))s"
      else
        echo "free"
      fi
      ;;
    *) die "usage: factory.sh merge-lock <acquire|release|status> [label]" ;;
  esac
}

cmd_help() {
  cat <<'EOF'
factory.sh - the MULTI/DEX software-factory task queue (.claude/skills/mdex-software-factory/SKILL.md)

  root                              print the resolved tasks root
  worker-pin [worker]               PIN this worktree's seat identity into <worktree-root>/.factory-worker
                                    (defaults to the flattened current branch). A seat's boot step: every
                                    later claim/requeue/done from anywhere inside the tree - executor
                                    subagents included - then resolves the same worker without the branch
  worker                            print the identity this cwd resolves to and where it came from
  new <draft.md>                    enqueue a finished draft (allocates the id; draft is left in place)
  list [--operator|--consumer]      queued tasks in execution order: filename + title
  show <id>                         print a task wherever it lives (queue/claimed/archive)
  claim [worker]                    atomically claim the best eligible task (REFUSED while an operator
                                    signal addresses this worker); prints its new path, or
                                    "EMPTY (queue N: X dep-gated, Y operator-lane, Z overlap-deferred)"
                                    ("EMPTY (queue 0)" when queue/ is literally empty; first word is
                                    always exactly EMPTY - relay the breakdown in idle reports)
  claim --affinity a,b [worker]     same, but prefer tasks touching a/b WITHIN the head priority band
  claim --operator [worker]         claim from the OPERATOR lane instead (tasks a consumer must never run)
  claim --operator --id <id>        take one SPECIFIC queued task - the safe-edit tweezers (claim, edit, requeue)
                                    claim resolves its worker: [worker] arg > FACTORY_WORKER env >
                                    .factory-worker seat pin (worker-pin, above) > cwd branch, and prints the
                                    effective worker on stderr - plus a warning whenever the pin and the
                                    resolved/derived name disagree (that disagreement IS cwd drift).
  done <id> <status> [note]         archive a claimed task (done|abandoned|split|superseded);
                                    status=done refuses while a `docfile:` brief still sits at its
                                    original docs/tasks/ path - the bookkeeping law (FACTORY_FORCE=1 overrides)
  requeue <id> [band] [note]        put a claimed task back in the queue (note lands in its Factory log)
  reprioritize <id> <band|key>      rename a QUEUED task's priority half (prioritizer only)
  index                             regenerate tasks/factory/index.md (the human-readable board)
  handoff-list                      seats awaiting a successor: "<worktree>\t<age>" per line, or NONE
                                    (a retiring seat writes tasks/handoff/<worktree>.md with the boot
                                    prompt - the copy that survives an app restart when the chip does not)
  handoff-clear <worktree>          the successor's FIRST act once booted: drop that pending file
                                    (run from the seat's worktree it also refreshes the identity pin)
  spawn-successor <worktree>        CLI seat's handoff step: open a new Terminal window running the
                                    claude CLI (pinned model) with the boot prompt from that seat's
                                    pending handoff file; refuses when no handoff file exists (handoff
                                    first, spawn second). Session name is project-prefixed:
                                    <prefix>-executor-<worktree> (or <prefix>-worker-<worktree> for a
                                    non-executor boot prompt); prefix = FACTORY_PROJECT, else the
                                    primary checkout basename minus -ng/-main (here: multidex).
                                    Zero-residue window: the command ends '; exit 0' and the window gets
                                    the 'Factory' Terminal settings set ('When the shell exits: Close the
                                    window') when it exists - no such profile: spawn proceeds, the banner
                                    names the one-time manual setup (operator guide in the skill).
                                    FACTORY_SPAWN_DRYRUN=1 prints the name + program instead of running
  signal <worker|all> <text|file>   OPERATOR ORDER for one seat (or all seats): writes tasks/signal/<name>.md,
                                    which wakes every watch at once and REFUSES that seat's next claim until
                                    it is acknowledged (a second signal appends - a standing order is never lost)
  signal-list                       unacknowledged signals: "<addressee>\t<age>" per line, or NONE
  signal-clear <worker|all>         the addressee's ACK: delete the signal it has now carried out
  watch [max-seconds]               block until queue/claimed/archive/signal change; prints CHANGED or TIMEOUT
  merge-lock acquire|release|status [label]   the cross-session lock around merges into main;
                                    acquire <branch> enforces the POSTURE LAW: #play in backend AND
                                    bridge main.mo, no port-0 icp.yaml (FACTORY_FORCE=1 overrides)
EOF
}

# --- dispatch ---------------------------------------------------------------

main() {
  local cmd="${1:-help}"; shift || true
  resolve_root
  shopt -s nullglob
  case "$cmd" in
    root)          cmd_root "$@" ;;
    worker-pin)    cmd_worker_pin "$@" ;;
    worker)        cmd_worker "$@" ;;
    new)           cmd_new "$@" ;;
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
    signal)        cmd_signal "$@" ;;
    signal-list)   cmd_signal_list "$@" ;;
    signal-clear)  cmd_signal_clear "$@" ;;
    watch)         cmd_watch "$@" ;;
    merge-lock)    cmd_merge_lock "$@" ;;
    help|-h|--help) cmd_help ;;
    *) die "unknown command '$cmd' (factory.sh help)" ;;
  esac
}

main "$@"
