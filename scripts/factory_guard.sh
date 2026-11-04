# factory_guard.sh - mechanical law-5/law-8 tripwires for the deploy paths.
# Sourced (not executed) by scripts/deploy.sh and scripts/cold_start.sh.
# Ported from the open-saas factory's lib.sh factory_primary_guard
# (a6e6e6e44), adapted to this repo's topology: here the sharp edges are
# (a) a consumer seat deploying a REMOTE target at all (law 8), and (b) a
# consumer seat running a venue script against the PRIMARY checkout - whose
# :8000 venue is the operator's standing demo - instead of its own worktree
# (law 5). Identity is the CONSUMER seat's (FACTORY_WORKER, else the nearest
# .factory-worker pin at/above the cwd); the operator's declared identity
# (`operator` / `claude-operator` - one principal) is never belted. With NO
# identity, LOCAL mode and any resolution failure pass untouched (the
# primary's :8000 venue is the operator's) - but a REMOTE deploy is REFUSED
# while a consumer seat is pinned anywhere (under .factory/seats/*/, the
# legacy .claude/worktrees/*/, or any linked worktree - `git worktree list`,
# the same list the pre-commit hook's guard C reads) unless the operator's
# rollout declares itself with FACTORY_DIRECT=1: the no-identity belt in
# factory_primary_guard, re-synced 2026-10-31 and selftest-pinned since task
# 1793617711 (scripts/factory-selftest.sh, "the guard's half"). Fail-open
# is ONLY the no-factory case: a checkout with no consumer pin anywhere.
# FACTORY_FORCE=1 overrides, as everywhere.

factory_seat_identity() {  # prints the consumer-seat identity, or nothing
  local seat="${FACTORY_WORKER:-}" d
  if [ -z "$seat" ]; then
    d="$(pwd -P 2>/dev/null || pwd)"
    while [ -n "$d" ] && [ "$d" != "/" ]; do
      if [ -f "$d/.factory-worker" ]; then
        seat="$(head -1 "$d/.factory-worker" 2>/dev/null | tr -d '[:space:]')"
        break
      fi
      d="$(dirname "$d")"
    done
  fi
  case "$seat" in ""|operator|claude-operator) return 0 ;; esac
  printf '%s' "$seat"
}

factory_primary_guard() {  # $1 = script label, $2 = "remote" | "local"
  local label="$1" mode="${2:-local}" seat top primary
  [ "${FACTORY_FORCE:-}" = "1" ] && return 0
  case "${FACTORY_WORKER:-}" in operator|claude-operator) return 0 ;; esac   # the operator's declared identity: never a consumer, never belted
  seat="$(factory_seat_identity)"
  case "$seat" in operator|claude-operator) return 0 ;; esac
  if [ -z "$seat" ]; then
    # The NO-IDENTITY BELT (re-synced from open-saas 2026-10-31, their task
    # 1791133471): an identity-free REMOTE deploy from the primary while any
    # CONSUMER seat is pinned (either seat dir, or any linked worktree) is
    # how a drifted executor subagent deploys - its shell carries no
    # FACTORY_WORKER and its cd target left the seat worktree, so the law-8
    # refusal below cannot see it. The operator's own rollout declares
    # itself: FACTORY_DIRECT=1 bash scripts/deploy.sh <target>. Local mode
    # is untouched (the primary's :8000 venue is the operator's).
    [ "$mode" = "remote" ] || return 0
    [ "${FACTORY_DIRECT:-}" = "1" ] && return 0
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] || return 0
    local pins="" f w
    for f in "$top"/.factory/seats/*/.factory-worker "$top"/.claude/worktrees/*/.factory-worker; do
      [ -f "$f" ] || continue
      case "$(head -1 "$f" 2>/dev/null | tr -d '[:space:]')" in operator|claude-operator) continue ;; esac   # the operator seat's pin is no running factory (its fleet-doctor overlay skip; the hook's guard C reads it the same way)
      pins="$pins $(basename "$(dirname "$f")")"
    done
    # Linked worktrees anywhere else (a seat minted at an unusual path) - the
    # hook's guard C reads the same list, so a seat is a running factory to
    # BOTH belts or to neither (task 1793617711).
    while IFS= read -r w; do
      [ -n "$w" ] && [ "$w" != "$top" ] && [ -f "$w/.factory-worker" ] || continue
      case "$(head -1 "$w/.factory-worker" 2>/dev/null | tr -d '[:space:]')" in operator|claude-operator) continue ;; esac
      case " $pins " in *" $(basename "$w") "*) ;; *) pins="$pins $(basename "$w")" ;; esac
    done <<EOF
$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
EOF
    [ -n "$pins" ] || return 0                      # no factory running: plain checkout, fail-open
    echo "✗ $label: REFUSED - a REMOTE deploy from the primary with NO seat identity while a factory is running (seat pins:$pins). A drifted executor subagent deploys exactly like this. If you ARE a seat: cd to YOUR worktree and park the task into the operator lane (law 8). If you ARE the operator's rollout: declare it - FACTORY_DIRECT=1 bash scripts/deploy.sh <target>. FACTORY_FORCE=1 overrides." >&2
    exit 1
  fi
  if [ "$mode" = "remote" ]; then
    echo "✗ $label: REFUSED - consumer seat '$seat' targeting a remote deployment (law 8: engine/subnet rollouts are the operator's act; park the task into the operator lane instead). FACTORY_FORCE=1 overrides." >&2
    exit 1
  fi
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  primary="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || true)"
  [ -n "$top" ] && [ -n "$primary" ] || return 0
  if [ "$(cd "$top" && pwd -P)" = "$(cd "$primary" && pwd -P)" ]; then
    echo "✗ $label: REFUSED - consumer seat '$seat' running against the PRIMARY checkout (law 5: the :8000 venue is the operator's; your cd target drifted - run from YOUR worktree with your own ICP_HOME). FACTORY_FORCE=1 overrides." >&2
    exit 1
  fi
  return 0
}
