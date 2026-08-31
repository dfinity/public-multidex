#!/bin/bash
# tests/run_all.sh — production-friendly test runner.
#
# Discovers every test_*.sh in this directory, runs each in a fresh
# subshell, captures timing + output, and prints a structured summary.
# Returns non-zero if any test fails (CI signal).
#
# Flags:
#   --verbose            Show full per-test output instead of just
#                        the pass/fail banner. Useful when iterating.
#   --filter NAME        Only run tests whose filename matches NAME
#                        (substring match). Repeatable. Useful for
#                        running one test at a time during dev.
#   --fail-fast          Stop on first failure. Default: run all.
#   --json FILE          Emit a structured summary JSON to FILE for
#                        downstream tooling.
#   --help               Show usage.
#
# Examples:
#   bash tests/run_all.sh
#   bash tests/run_all.sh --verbose
#   bash tests/run_all.sh --filter pending --filter zombie
#   bash tests/run_all.sh --fail-fast --json /tmp/uplands-tests.json

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

VERBOSE=false
FAIL_FAST=false
JSON_OUT=""
FILTERS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --verbose)   VERBOSE=true;  shift ;;
    --fail-fast) FAIL_FAST=true; shift ;;
    --filter)    FILTERS+=("$2"); shift 2 ;;
    --json)      JSON_OUT="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,22p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Discover tests. Sort so order is deterministic, runtime-friendly
# tests roughly first.
ALL_TESTS=( $(ls test_*.sh 2>/dev/null | sort) )
if [ ${#ALL_TESTS[@]} -eq 0 ]; then
  echo "No tests found in $SCRIPT_DIR" >&2
  exit 2
fi

# Apply filters (any filter substring match keeps the test).
if [ ${#FILTERS[@]} -gt 0 ]; then
  KEPT=()
  for t in "${ALL_TESTS[@]}"; do
    for f in "${FILTERS[@]}"; do
      if echo "$t" | grep -q -- "$f"; then KEPT+=("$t"); break; fi
    done
  done
  ALL_TESTS=( "${KEPT[@]}" )
fi

# Two suites are NOT test_*.sh files — the Motoko unit tests (mops) and the
# frontend security guards (node) — so an empty shell-test list does not mean
# an empty run: `--filter frontend` selects one of them and nothing else.
# Without this, filtering to a built-in suite exited "no tests match" before
# ever reaching it.
BUILTIN_MATCH=false
if [ ${#FILTERS[@]} -gt 0 ] \
   && [ "$(printf '%s\n' "${FILTERS[@]}" | grep -c -E "mops|unit|frontend|security")" -gt 0 ]; then
  BUILTIN_MATCH=true
fi

if [ ${#ALL_TESTS[@]} -eq 0 ] && [ "$BUILTIN_MATCH" = "false" ]; then
  echo "No tests match the given filter(s): ${FILTERS[*]}" >&2
  exit 2
fi

# Stop the trading simulator if it's running. Tests assert exact trade
# counts and zero-order-book invariants; a 1Hz background simulator
# would inject noise that flakes them. The simulator is started by
# master.sh / cold_start.sh in production, not by tests.
# NEVER pattern-kill here. `pkill -f simulate_trading.sh` matched processes
# driving the LIVE fleet as readily as a local one, and the repo's own incident
# trail records it taking the fleet down on 2026-07-23, 2026-07-28 and again on
# 2026-08-01. The PID-file architecture in scripts/lib/bots.sh exists precisely
# to stop only the bots THIS machine started for THIS target.
# Resolve through SCRIPT_DIR (absolute, computed at the top), NEVER through
# `dirname "$0"`. $0 is the INVOCATION path, not the resolved one, and line 27
# already `cd`s into this directory — so from the repo root `dirname "$0"` is
# "tests" and the path becomes tests/tests/../scripts/..., which does not
# exist. The test then failed, the `if` had no else, and the guard silently
# did nothing: it worked when run from inside tests/ and no-oped when run
# from the repo root, which is how it is actually invoked. A whole suite came
# back 20 red on 2026-08-05 with the fleet trading underneath it.
#
# Gate on -f, not -x: we invoke through `bash <path>`, which does not need the
# executable bit, so -x would let a chmod silently disable the guard again.
STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
if [ -f "$STOPPER" ]; then
  echo -e "${DIM}Stopping the local simulator (would interfere with assertions)…${NC}"
  bash "$STOPPER" >/dev/null 2>&1 || true
  sleep 2
else
  # Never fail silently here. A missing stopper means every assertion below is
  # being made against a venue something else may be trading on.
  echo -e "${YELLOW}⚠ stop_bots_local.sh not found at $STOPPER — the local fleet was NOT stopped.${NC}"
  echo -e "${YELLOW}  Any red result below may be simulator noise rather than a regression.${NC}"
fi

# ORPHAN DETECTION — warn, never kill.
#
# stop_bots_local.sh can only stop what was started through start_bots_local.sh,
# because it kills by ancestry from .run/bots-<target>.pid. A fleet launched the
# old way (directly, before the PID-file architecture) leaves no record, so the
# stopper reports "no bots recorded" while the fleet keeps trading underneath
# every assertion — which is exactly how a clean run came back 19 red on
# 2026-08-02, four of which went green the moment the orphans were stopped.
#
# We do NOT kill these. A properly-started fleet always carries `--target` in
# argv, but a LEGACY invocation against subnet or engine carried its target only
# in IC_ENV, invisible to ps — so "no --target" cannot distinguish a stray local
# fleet from one driving multidex.ai, and guessing is how the live fleet was
# killed three times. Report it and let a human decide.
ORPHANS=$(ps ax -o pid=,command= 2>/dev/null | grep '[t]rading_simulation\.sh' | grep -v -- '--target' | wc -l | tr -d ' ')
if [ "${ORPHANS:-0}" -gt 0 ]; then
  echo -e "${YELLOW}⚠ ${ORPHANS} simulator process(es) are running with no --target and no PID file.${NC}"
  echo -e "${YELLOW}  They are NOT stoppable by stop_bots_local.sh, and if any of them point at this${NC}"
  echo -e "${YELLOW}  replica they will trade underneath these tests and produce spurious failures.${NC}"
  echo -e "${YELLOW}  Identify them before trusting a red result:${NC}"
  echo -e "${YELLOW}    ps ax -o pid=,ppid=,command= | grep '[t]rading_simulation'${NC}"
  echo -e "${YELLOW}  Stop only the ones you have confirmed are local, BY PID — never by pattern.${NC}"
fi

# ── Per-test execution ───────────────────────────────────────────
PASS=0
FAIL=0
SKIPS=0   # posture-skips (⊘ from tests/_lib.sh) — hook-dependent coverage deferred to a #dev venue
declare -a NAMES=()
declare -a STATUSES=()
declare -a DURATIONS=()
declare -a ASSERTS_PASSED=()
declare -a ASSERTS_FAILED=()

START_ALL=$(date +%s)

# ── Motoko unit tests (mops test) ────────────────────────────────
# Pure-function tests run via moc's interpreter — no canister deploy
# needed. Sub-second total runtime; running them first means a
# regression in the math primitives surfaces before we burn 5+
# minutes on integration tests that depend on those primitives.
MOPS_PASS=0
MOPS_FAIL=0
if [ ${#FILTERS[@]} -eq 0 ] || [ "$(printf '%s\n' "${FILTERS[@]}" | grep -c -E "mops|unit")" -gt 0 ]; then
  echo -e "${BOLD}── mops test (Motoko unit tests)${NC}"
  mops_log=$(mktemp)
  start=$(date +%s)
  if mops test --reporter compact > "$mops_log" 2>&1; then
    MOPS_RC=0
  else
    MOPS_RC=1
  fi
  end=$(date +%s)
  mops_dur=$(( end - start ))
  if [ "$VERBOSE" = "true" ]; then cat "$mops_log"; fi
  if [ "$MOPS_RC" -eq 0 ]; then
    # `compact` reporter writes ANSI-control sequences; the LAST line
    # has the final tally `passed N files`. Strip ANSI before parsing.
    n_files=$(tail -3 "$mops_log" | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' \
              | grep -oE "passed [0-9]+ files" | tail -1 \
              | grep -oE "[0-9]+" | head -1)
    echo -e "  ${GREEN}PASS${NC} (${mops_dur}s · ${n_files:-?} unit test files)"
    MOPS_PASS=1
  else
    echo -e "  ${RED}FAIL${NC} (${mops_dur}s)"
    grep -E "✖|FAIL" "$mops_log" | head -20 | sed 's/^/    /'
    MOPS_FAIL=1
    if [ "$FAIL_FAST" = "true" ]; then
      rm -f "$mops_log"
      echo ""; echo -e "${BOLD}═══ Summary ═══${NC}"
      echo -e "  ${GREEN}0 passed${NC} · ${RED}1 failed${NC} (mops unit tests)"
      exit 1
    fi
  fi
  rm -f "$mops_log"
fi

# ── Frontend guards (static analysis + pure-module tests, plain node) ─
# Source-level invariants for the browser-side code, in every *.test.mjs
# in this directory:
#   · frontend_security          — the certificate check is actually wired
#     up and fails closed, the root key is never fetched from the host being
#     verified, ai-connect.html cannot be pointed at another origin, no
#     third-party script is loaded, the .ic-assets.json5 that SHIPS sets a CSP.
#   · frontend_display_integrity — the e8 money boundary (which fields scale,
#     what a round trip preserves, no second divide at a render site), the
#     units contract handed to the assistant vs what the backend projects,
#     and the poll/chart cursors that index shared caches.
# Every one of these failed silently in production at some point — the
# certificate check threw on every call for its whole life and the page still
# painted green; a fifty-cent liability rendered as fifty million dollars and
# formatted perfectly — so they are asserted against the source (and, where a
# module is pure, against the module), with no replica, no browser and no
# network. Milliseconds; runs here next to mops for the same reason mops runs
# first. Suites are DISCOVERED, not listed: dropping a new *.test.mjs in this
# directory wires it in, exactly like a new test_*.sh.
FE_PASS=0
FE_FAIL=0
declare -a FE_FAILED=()
if [ ${#FILTERS[@]} -eq 0 ] || [ "$(printf '%s\n' "${FILTERS[@]}" | grep -c -E "frontend|security")" -gt 0 ]; then
  for fe_suite in $(ls *.test.mjs 2>/dev/null | sort); do
    echo -e "${BOLD}── ${fe_suite%.test.mjs} guards (node, static analysis)${NC}"
    fe_log=$(mktemp)
    start=$(date +%s)
    if node "$fe_suite" > "$fe_log" 2>&1; then
      FE_RC=0
    else
      FE_RC=1
    fi
    end=$(date +%s)
    fe_dur=$(( end - start ))
    if [ "$VERBOSE" = "true" ]; then cat "$fe_log"; fi
    fe_asserts=$(LC_ALL=C grep -ac '✓' "$fe_log" || true)
    if [ "$FE_RC" -eq 0 ]; then
      echo -e "  ${GREEN}PASS${NC} (${fe_dur}s · ${fe_asserts} assertions)"
      FE_PASS=$(( FE_PASS + 1 ))
    else
      echo -e "  ${RED}FAIL${NC} (${fe_dur}s)"
      LC_ALL=C grep -aE '✗' "$fe_log" | head -20 | sed 's/^/    /'
      FE_FAIL=$(( FE_FAIL + 1 ))
      FE_FAILED+=("$fe_suite")
      if [ "$FAIL_FAST" = "true" ]; then
        rm -f "$fe_log"
        echo ""; echo -e "${BOLD}═══ Summary ═══${NC}"
        echo -e "  ${GREEN}$(( MOPS_PASS + FE_PASS )) passed${NC} · ${RED}$FE_FAIL failed${NC} ($fe_suite)"
        exit 1
      fi
    fi
    rm -f "$fe_log"
  done
fi

for t in "${ALL_TESTS[@]}"; do
  echo -e "${BOLD}── $t${NC}"
  # NO suffix after the X's. BSD mktemp (macOS) only substitutes TRAILING X's:
  # given `...-XXXXXX.log` it silently creates that LITERAL path and exits 0, so
  # every test shares one file. The loop's `rm -f "$log"` hides it until a run is
  # interrupted — then the literal file survives, every later mktemp fails
  # "File exists", `log` comes back empty, and the whole suite reports 0s
  # failures until someone deletes a file nobody knows about. Trailing X's are
  # portable across BSD and GNU.
  log=$(mktemp /tmp/uplands-test-XXXXXX)
  # INTER-SUITE HYGIENE (2026-08-15): a suite that pauses the venue's timers
  # and then FAILS can exit without resuming them — the finaliser stops, and
  # the next suite's staged orders never release ("no trades" that is not its
  # own bug; found live as market_walks → matching_engine). Reset the one
  # venue-global switch every suite depends on. Tests that want a paused
  # venue pause it in their own setup, so this costs them nothing.
  echo "y" | icp canister call backend setTestTimersPaused '(false)' --identity anonymous > /dev/null 2>&1 || true
  start=$(date +%s)
  # LC_ALL=C pin (#45): under a UTF-8 locale, macOS /bin/bash 3.2 swallows a
  # multibyte glyph abutting an unbraced $VAR into the variable name, and
  # `set -u` aborts the suite mid-run. The sites are braced now, but pin the
  # child locale anyway so the runner's results never depend on the ambient
  # locale (the counting greps below are already LC_ALL=C).
  if LC_ALL=C bash "$t" > "$log" 2>&1; then
    rc=0
  else
    rc=1
  fi
  end=$(date +%s)
  dur=$(( end - start ))

  # Pass-count / fail-count parsing — tests print one ✓ or ✗ per
  # assertion. Cheap to count.
  passed=$(LC_ALL=C grep -ac '✓' "$log" || true)
  failed=$(LC_ALL=C grep -ac '✗' "$log" || true)
  skipped=$(LC_ALL=C grep -ac '⊘' "$log" || true)
  SKIPS=$(( SKIPS + ${skipped:-0} ))
  skipnote=""
  [ "${skipped:-0}" -gt 0 ] && skipnote=" · ${skipped} posture-skip(s)"

  if [ "$VERBOSE" = "true" ]; then
    cat "$log"
  fi

  # W5-02: a test that prints ✗ but exits 0 (the W5-01 class) must not be
  # recorded PASS — the count sat in `failed` one line above the verdict and
  # was never read. And a test that asserted NOTHING is flagged: that is how
  # the next dead test gets caught before it needs its own issue.
  if [ "$rc" -eq 0 ] && [ "${failed:-0}" -gt 0 ]; then
    echo -e "  ${RED}FAIL${NC} (${dur}s · exit 0 BUT ${failed} failing assertion(s) — the test's own verdict is broken)"
    LC_ALL=C grep -aE '✗' "$log" | head -10 | sed 's/^/    /'
    FAIL=$(( FAIL + 1 ))
    STATUSES+=("fail")
  elif [ "$rc" -eq 0 ]; then
    if [ "${passed:-0}" -eq 0 ] && [ "${skipped:-0}" -eq 0 ]; then
      echo -e "  ${YELLOW}PASS?${NC} (${dur}s · ZERO assertions — a test that asserts nothing proves nothing)"
    else
    echo -e "  ${GREEN}PASS${NC} (${dur}s · ${passed} assertions${skipnote})"
    fi
    # Surface the ⊘ REASONS even on a pass. A test that quietly runs fewer
    # assertions than it looks like it does is a blind spot; without this the
    # only trace of a posture/venue skip was the assertion count dropping.
    if [ "${skipped:-0}" -gt 0 ] && [ "$VERBOSE" != "true" ]; then
      # echo -e per line, not sed: $YELLOW holds a literal \033 sequence that
      # only echo -e interprets — sed would insert it verbatim as "33[1;33m".
      LC_ALL=C grep -a '⊘' "$log" | while IFS= read -r _sl; do echo -e "  ${YELLOW}${_sl}${NC}"; done
    fi
    PASS=$(( PASS + 1 ))
    STATUSES+=("pass")
  else
    echo -e "  ${RED}FAIL${NC} (${dur}s · ${passed} ok / ${failed} failed)"
    if [ "$VERBOSE" != "true" ]; then
      # Show only the failing-assert lines + the FAIL banner so the
      # console signal is meaningful even without --verbose.
      LC_ALL=C grep -aE '✗|^FAIL' "$log" | head -20 | sed 's/^/    /'
    fi
    FAIL=$(( FAIL + 1 ))
    STATUSES+=("fail")
    if [ "$FAIL_FAST" = "true" ]; then
      NAMES+=("$t"); DURATIONS+=("$dur")
      ASSERTS_PASSED+=("$passed"); ASSERTS_FAILED+=("$failed")
      break
    fi
  fi

  rm -f "$log"
  NAMES+=("$t")
  DURATIONS+=("$dur")
  ASSERTS_PASSED+=("$passed")
  ASSERTS_FAILED+=("$failed")
done

END_ALL=$(date +%s)
TOTAL=$(( END_ALL - START_ALL ))

# ── Summary ──────────────────────────────────────────────────────
echo ""
TOTAL_PASS=$(( PASS + MOPS_PASS + FE_PASS ))
TOTAL_FAIL=$(( FAIL + MOPS_FAIL + FE_FAIL ))
echo -e "${BOLD}═══ Summary ═══${NC}"
echo -e "  ${GREEN}$TOTAL_PASS passed${NC} · ${RED}$TOTAL_FAIL failed${NC}  (${TOTAL}s total · ${MOPS_PASS}+${FE_PASS}+${PASS} unit/static/integration)"
if [ "$SKIPS" -gt 0 ]; then
  echo -e "  ${YELLOW}⊘ $SKIPS posture-skip(s)${NC} — hook-dependent sections not runnable on this posture; full coverage requires a #dev venue (tests/_lib.sh)"
fi

if [ "$FE_FAIL" -gt 0 ]; then
  echo ""
  for fe_suite in "${FE_FAILED[@]}"; do
    echo -e "${RED}✗ ${fe_suite%.test.mjs} guards${NC}  (run: node tests/$fe_suite)"
  done
fi

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo -e "${RED}Failures:${NC}"
  for i in "${!NAMES[@]}"; do
    if [ "${STATUSES[$i]}" = "fail" ]; then
      echo -e "  ${RED}✗ ${NAMES[$i]}${NC}  (${DURATIONS[$i]}s · ${ASSERTS_FAILED[$i]} failing)"
    fi
  done
fi

# Optional JSON for CI.
if [ -n "$JSON_OUT" ]; then
  {
    echo "{"
    echo "  \"summary\": { \"passed\": $PASS, \"failed\": $FAIL, \"total_seconds\": $TOTAL },"
    echo "  \"tests\": ["
    for i in "${!NAMES[@]}"; do
      sep=","
      [ "$i" -eq $(( ${#NAMES[@]} - 1 )) ] && sep=""
      echo "    { \"name\": \"${NAMES[$i]}\", \"status\": \"${STATUSES[$i]}\", \"seconds\": ${DURATIONS[$i]}, \"asserts_passed\": ${ASSERTS_PASSED[$i]}, \"asserts_failed\": ${ASSERTS_FAILED[$i]} }$sep"
    done
    echo "  ]"
    echo "}"
  } > "$JSON_OUT"
  echo -e "${DIM}  → $JSON_OUT${NC}"
fi

if [ "$TOTAL_FAIL" -gt 0 ]; then exit 1; fi
exit 0
