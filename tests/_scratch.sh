#!/bin/bash
# tests/_scratch.sh — where a test suite puts its scratch files. SOURCE THIS.
#
# H-04 (F24). Every suite scratch file used to be a FIXED NAME under /tmp:
# /tmp/oqlguard.did, /tmp/aiguard_*.did, /tmp/hopiso.did, /tmp/uplands-conc-N.log,
# /tmp/w42_*.out, /tmp/uplands-test-seed.log. /tmp is world-writable AND sticky
# (1777): a file another local user plants at that name is PERSISTENT — our
# `rm -f` fails silently, and our `>` writes THROUGH a planted symlink, blocks
# forever on a planted FIFO, or is refused outright. Several of those files were
# read straight back as `--args-file` signed by a controller identity (alice or
# anonymous — locally a controller): a plant was a controller-signed argument of
# someone else's choosing. scripts/lib/runfiles.sh tells the same story for the
# deploy scripts; this file is the suites' half of the same fix.
#
# Every suite gets ONE private per-run directory under $MDX_RUN_DIR (repo-local
# .run/ — operator-owned, not world-writable, gitignored), created by mktemp -d
# (0700, O_EXCL: nobody can pre-create it) and removed on EXIT.
#
#   scratch_new <name>   → a path inside it, asserted ABSENT before anyone writes
#                          (the [ ! -e ] check); a name that will not go away
#                          aborts the suite. Call as F=$(scratch_new x) || exit 1.
#   on_exit <cmd>        → registers a cleanup to run on EXIT (LIFO, so a suite's
#                          own cleanups run before the scratch dir goes). bash
#                          keeps ONE EXIT trap per shell, so a suite that writes
#                          its own `trap … EXIT` would silently REPLACE the
#                          cleanup here — register through on_exit instead.
#   seed_logged <args>   → runs scripts/seed.sh with its output in
#                          MDX_TEST_SEED_LOG — a STABLE name under .run/, because
#                          the operator reads it after a failed fixture, so it
#                          must outlive the run (and in .run/ rm -f means what it
#                          says). Written under noclobber after the rm.
#
# Suites that source tests/_lib.sh get all of this for free — _lib.sh is the ONE
# sourcer of this file. A suite that sources _lib.sh must NOT also source this
# file directly: the second run re-executes the mktemp -d above (a SECOND
# per-run directory), resets _MDX_EXIT_CMDS and re-arms the trap, so only the
# second directory is ever removed and the first is orphaned under .run/ on
# every run (task 1788497403). No suite that sources either installs its own
# `trap ... EXIT`; test_deploy_hygiene §2b pins both, and pins the census over
# tests/ that keeps /tmp out.

_MDX_SCRATCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/runfiles.sh
source "$_MDX_SCRATCH_ROOT/scripts/lib/runfiles.sh"

MDX_TEST_SEED_LOG="${MDX_TEST_SEED_LOG:-$MDX_RUN_DIR/test-seed.log}"
export MDX_TEST_SEED_LOG

# One private directory per suite run. Trailing X's only: BSD mktemp (macOS)
# substitutes TRAILING X's exclusively (run_all.sh's comment on the same trap).
TEST_SCRATCH="$(mktemp -d "$MDX_RUN_DIR/test-$(basename "${0%.sh}").XXXXXX")" \
  || { echo "cannot create a scratch directory under $MDX_RUN_DIR" >&2; exit 1; }

# The one EXIT trap, running every registered cleanup newest-first. The
# ${arr[@]+"${arr[@]}"} spelling is the bash-3.2 (macOS /bin/bash) safe way to
# expand a possibly-empty array under set -u.
_MDX_EXIT_CMDS=()
on_exit() { _MDX_EXIT_CMDS+=("$1"); }
_mdx_run_exit() {
  local i
  for (( i=${#_MDX_EXIT_CMDS[@]}-1; i>=0; i-- )); do eval "${_MDX_EXIT_CMDS[$i]}"; done
}
trap _mdx_run_exit EXIT
on_exit 'rm -rf "$TEST_SCRATCH"'

scratch_new() {   # scratch_new <name> → absolute path, guaranteed not to exist yet
  local f="$TEST_SCRATCH/$1"
  rm -f "$f"
  if [ -e "$f" ] || [ -L "$f" ]; then
    echo "scratch_new: $f still exists after rm — refusing to write into it" >&2
    return 1
  fi
  printf '%s' "$f"
}

seed_logged() {   # seed_logged <seed.sh args...>; aborts the suite on failure
  rm -f "$MDX_TEST_SEED_LOG"
  ( set -o noclobber; bash "$MDX_ROOT/scripts/seed.sh" "$@" > "$MDX_TEST_SEED_LOG" 2>&1 ) \
    || { echo "seed.sh $* failed — see $MDX_TEST_SEED_LOG" >&2; exit 1; }
}
