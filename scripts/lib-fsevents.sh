#!/usr/bin/env bash
# lib-fsevents.sh - THE one macOS FSEvents delivery probe, shared by the deploy
# spine (lib.sh: fsevents_alive, the pre-start gate) and the standalone
# diagnostic (replica-doctor.sh: the "FSEvents delivery" section).
#
# PURE FUNCTION DEFINITIONS, deliberately: no `set -e`, no traps, no exports,
# no `need`, no top-level commands. replica-doctor.sh cannot source lib.sh
# (it imposes `set -euo pipefail` + `trap '' PIPE`, exports ICP_PROJECT_ROOT
# and `need`s python3/git at source time - the doctor is the tool you reach
# for when the spine is broken, so it stays standalone), and before this file
# existed the probe lived TWICE, byte-for-byte, kept in agreement by a
# comment. Source this fragment from either side; both keep their own
# gating, verdict lines and exit-code conventions on top of it.
#
# Why the probe exists: `icp network start`'s parent waits for the launcher
# handshake via an FSEvents watcher (notify-rs), so when macOS FSEvents
# delivery is dead on the state dir's volume every FRESH start parks forever
# (launcher at 0% CPU, 0-byte logs, no descriptor.json, no pocket-ic child -
# root-caused 2026-08-04). Running replicas are unaffected (no watchers).
# Delivery dies per-volume (/Users with /private/tmp healthy) or
# machine-wide; remedy ladder (fsevents_remedy_line below is the ONE text):
# step 1 restart the daemon - `sudo kill -9 <fseventsd pid>` (launchd's
# KeepAlive respawns it under a new pid within seconds; validated 2026-10-01
# on macOS 26.5, delivery back on both volumes in 6-13 ms) - then re-probe
# with ./scripts/replica-doctor.sh; step 2 REBOOT only if delivery is still
# dead. HISTORY: the pre-macOS-26 remedy, a `launchctl kickstart -k` of the
# system fseventsd service (validated 2026-08-04), is REFUSED under SIP on
# macOS 26 ("150: Operation not permitted while System Integrity Protection
# is engaged") - never retry it.
#
# The probe: watch a scratch dir, write into it, see whether events arrive
# within a bar. ONE MISSED BAR IS NOT A DEAD DAEMON (2026-09-02, tasks
# 1788331568 + 1788332068): at load ~50 with 14 replicas a single 3s probe
# answered DEAD on a healthy volume and ALIVE on the next nine (even alive
# probes take 1-3s to see their first event under that load), and the false
# verdict both hard-stopped a start and relocated a seat's state to
# /private/tmp. So fsevents_probe RETRIES: up to SUITE_FSEVENTS_PROBE_TRIES
# (default 3) attempts with a GROWING bar (base SUITE_FSEVENTS_PROBE_BAR_MS=
# 3000 times the attempt number: 3s, 6s, 9s - a slow daemon is caught on
# attempt 2, a truly dead one costs ~18s per volume, nothing next to the
# wedge it prevents). ALIVE on any attempt is alive; DEAD needs EVERY
# attempt silent. Each attempt is bounded by its own bar, so a caller never
# parks here.
#
# API (all bash 3.2):
#   fsevents_probe_knobs
#       validates the env knobs into FSEVENTS_TRIES / FSEVENTS_BAR_MS
#       (non-numeric or 0 -> the defaults 3 / 3000).
#   fsevents_probe_once <dir> <bar-ms>
#       one attempt. stdout: "fired <ms>" | "silent <ms>" | "skip";
#       exit 0 fired, 1 silent, 2 skip (no node, dir absent, or the node
#       side could not mkdtemp/watch - printed as "skip" by node itself).
#   fsevents_probe <dir>
#       the retry loop. Exit 0 alive (on any attempt), 1 dead (every attempt
#       silent), 2 unprobeable (fail-open is the CALLER's policy). Leaves
#       the per-attempt timings in FSEVENTS_PROBE_ATTEMPTS, e.g.
#       "silent 3000ms, fired after 608ms (alive on attempt 2/3)" or
#       "silent 3000ms, silent 6000ms, silent 9000ms (dead on every attempt,
#       3/3)", so callers put the evidence in their own lines.
#   FSEVENTS_WARN (env/global, optional): the name of a caller function that
#       takes one message argument; when set, every retry is announced
#       through it ("attempt 1/3 silent for 3000ms - retrying ..."). lib.sh
#       sets it to c_warn; the doctor to its info line; unset = silent loop.
#
# Gating (Darwin-only, SUITE_FSEVENTS_PROBE=0) is NOT here - lib.sh's
# fsevents_alive keeps the gate, the doctor gates its whole section.

fsevents_probe_knobs() {
  FSEVENTS_TRIES="${SUITE_FSEVENTS_PROBE_TRIES:-3}"
  FSEVENTS_BAR_MS="${SUITE_FSEVENTS_PROBE_BAR_MS:-3000}"
  case "$FSEVENTS_TRIES" in ''|*[!0-9]*|0) FSEVENTS_TRIES=3 ;; esac
  case "$FSEVENTS_BAR_MS" in ''|*[!0-9]*|0) FSEVENTS_BAR_MS=3000 ;; esac
}

fsevents_probe_once() {  # fsevents_probe_once <dir> <bar-ms>; stdout: "fired <ms>" | "silent <ms>" | "skip"
  command -v node >/dev/null 2>&1 || { echo "skip"; return 2; }
  [ -d "$1" ] || { echo "skip"; return 2; }
  node - "$1" "$2" <<'JS'
const fs = require("node:fs"), path = require("node:path");
const bar = parseInt(process.argv[3], 10) || 3000;
let dir, w, fired = false;
const t0 = Date.now();
function cleanup() { try { fs.rmSync(dir, { recursive: true, force: true }); } catch (e) {} }
try { dir = fs.mkdtempSync(path.join(process.argv[2], ".fsevents-probe-")); }
catch (e) { process.stdout.write("skip\n"); process.exit(2); }
try { w = fs.watch(dir, function () { fired = true; done(); }); }
catch (e) { cleanup(); process.stdout.write("skip\n"); process.exit(2); }
let n = 0;
const iv = setInterval(function () {
  try { fs.writeFileSync(path.join(dir, "ping"), String(n++)); } catch (e) {}
}, 400);
const t = setTimeout(done, bar);
function done() {
  clearTimeout(t); clearInterval(iv);
  try { w.close(); } catch (e) {}
  cleanup();
  process.stdout.write((fired ? "fired " : "silent ") + (fired ? Date.now() - t0 : bar) + "\n");
  process.exit(fired ? 0 : 1);
}
JS
}

FSEVENTS_PROBE_ATTEMPTS=""   # per-attempt timings of the last fsevents_probe call
fsevents_probe() {  # fsevents_probe <dir>  -> 0 alive, 1 dead (every attempt silent), 2 unprobeable
  local tries base n=1 bar out log=""
  fsevents_probe_knobs
  tries="$FSEVENTS_TRIES"; base="$FSEVENTS_BAR_MS"
  FSEVENTS_PROBE_ATTEMPTS=""
  while :; do
    bar=$((base * n))
    out="$(fsevents_probe_once "$1" "$bar")" || :   # verdict rides stdout; set -e safe
    case "$out" in
      fired*)
        log="${log:+$log, }fired after ${out#fired }ms"
        FSEVENTS_PROBE_ATTEMPTS="$log (alive on attempt $n/$tries)"
        return 0
        ;;
      silent*)
        log="${log:+$log, }silent ${bar}ms"
        ;;
      *)
        # probe infrastructure failed (skip / no output): the caller decides
        FSEVENTS_PROBE_ATTEMPTS="probe unavailable (node missing, dir absent, or the watch could not be set up)"
        return 2
        ;;
    esac
    if [ "$n" -ge "$tries" ]; then
      FSEVENTS_PROBE_ATTEMPTS="$log (dead on every attempt, $n/$tries)"
      return 1
    fi
    if [ -n "${FSEVENTS_WARN:-}" ]; then
      "$FSEVENTS_WARN" "FSEvents probe on $1: attempt $n/$tries silent for ${bar}ms - retrying with a longer bar (a single missed bar under load is not a dead daemon)"
    fi
    n=$((n + 1))
  done
}

# The remedy ladder, ONE text for the spine's hard stop (lib.sh
# network_fsevents_prestart / network_start_locked) and the doctor's
# machine-wide verdict + its --fsevents-remedy flag (task 1791024290,
# 2026-10-03). The kill line carries the LIVE fseventsd pid so the operator
# pastes it as printed. Nothing HERE runs it - the only thing that may is
# fsevents_remedy_run below, through the root-owned wrapper under the
# operator-installed NOPASSWD rule (task 1791198753); without that install
# the paste line IS the remedy. The pid lookup is read-only and stays on its
# own line: `kill` and a name-pattern pgrep never share a line in a
# checked-in script (lint-scripts-no-pattern-kill.sh).
#   fsevents_remedy_pid    -> the live fseventsd pid on stdout, or nothing
#   fsevents_remedy_kill   -> "sudo kill -9 <pid>", the paste line alone
#   fsevents_remedy_line   -> the whole ladder on one line
fsevents_remedy_pid() {
  pgrep -x fseventsd 2>/dev/null | head -1 || true
}
fsevents_remedy_kill() {
  local pid
  pid="$(fsevents_remedy_pid)"
  printf 'sudo kill -9 %s' "${pid:-<fseventsd pid>}"
}
fsevents_remedy_line() {
  local pid note=""
  pid="$(fsevents_remedy_pid)"
  if [ -n "$pid" ]; then
    note="fseventsd is pid $pid right now"
  else
    note="no fseventsd pid is visible right now - ps -axo pid,comm names it"
  fi
  printf 'step 1: %s (%s; launchd respawns the daemon within seconds), then re-probe with ./scripts/replica-doctor.sh; step 2: REBOOT only if delivery is still dead. Do NOT retry the old launchctl kickstart of com.apple.fseventsd - macOS 26 refuses it under SIP (error 150). Running replicas keep serving.' "$(fsevents_remedy_kill)" "$note"
}

# --- the UNATTENDED remedy (task 1791198753; operator decision 1791024648,
# 2026-10-05: "yes, restart fseventsd without me but make sure to report that
# it has happened") -----------------------------------------------------------
# Two halves. ROOT HALF, installed ONCE by the operator with
# `sudo scripts/ops/install-fsevents-remedy.sh`: the root-owned wrapper
# /usr/local/sbin/open-saas-restart-fseventsd (source scripts/ops/
# restart-fseventsd.sh: pgrep -x fseventsd, kill -9, wait <= 10 s for
# launchd's respawn, print `old=<pid> new=<pid>`) and the ONE sudoers line
# /etc/sudoers.d/open-saas-fleet-doctor granting NOPASSWD on exactly that
# path. FLEET HALF, this: fsevents_remedy_run, called at the three sites
# that hit a DEAD-on-BOTH-volumes verdict (lib.sh network_start_locked -
# trigger deploy-all; replica-doctor.sh's machine-wide verdict - trigger
# replica-doctor; factory.sh fleet-doctor's probe - trigger fleet-doctor).
#   permitted  = `sudo -n -l <wrapper>` answers 0 (the rule is installed;
#                -n never prompts, so an uninstalled machine fails fast and
#                keeps today's behaviour: print the paste line, die).
#   one attempt per process, EVER (FSEVENTS_REMEDY_ATTEMPTED): a second
#                DEAD verdict after a restart returns 2 - the caller dies
#                with step 2 of the ladder (REBOOT), never kills twice.
#   re-probe   = both volumes (the caller's project dir + /private/tmp)
#                through FSEVENTS_REMEDY_PROBE (default fsevents_probe;
#                lib.sh sets fsevents_alive so its gate policy + the
#                SUITE_FSEVENTS_PROBE_FORCE test seam apply). Exit 1 from
#                the probe is DEAD; 0 or 2 (unprobeable, fail-open) counts
#                as alive.
# REPORTING (the operator's condition - every attempt, success or not):
#   - the loud line (FSEVENTS_WARN, or stderr): "FSEVENTS RESTARTED
#     unattended (trigger <t>): fseventsd <old> -> <new>, both volumes ALIVE
#     after <ms>" - also left in FSEVENTS_REMEDY_REPORT for the caller's
#     own log lines; FSEVENTS_REMEDY_OLD / _NEW carry the pids.
#   - the durable ledger, appended on EVERY attempt: fsevents_ledger_path
#     (FSEVENTS_LEDGER, default ~/Library/Logs/open-saas-fsevents-restarts.
#     tsv): timestamp, trigger, worktree, old pid, new pid, re-probe ms,
#     verdict (restarted-alive | restarted-dead | wrapper-failed |
#     dry-alive | dry-dead | dry-failed). fsevents_ledger_summary [days]
#     renders "N (last <ts>, trigger <t>)" counting the restarted-* rows -
#     the fleet-doctor header + log line and the board's "FSEvents
#     restarts" line read it; the macOS notification is the fleet
#     doctor's (factory.sh).
# DRY RUN: FSEVENTS_REMEDY_DRY=1 walks the whole path without killing - the
# permission probe still runs, the REPO wrapper's --check mode stands in for
# the sudo'd restart (old == new, "untouched"), the re-probe is real, the
# ledger row says dry-*. Self-tests set FSEVENTS_LEDGER to a scratch file (the
# real ledger is never written by a test) and FSEVENTS_REMEDY_SUDO to a stub
# that answers 0/1 for `-n -l` (so a test never depends on the machine's
# install, and never runs a real sudo). Return codes:
#   0  restarted (or dry) and both volumes ALIVE - the caller continues /
#      RETRIES the start
#   1  not permitted (no attempt made) - today's behaviour
#   2  attempted and still DEAD, the wrapper failed, or a second verdict
#      after an attempt - the caller dies with the reboot ladder
FSEVENTS_REMEDY_WRAPPER="/usr/local/sbin/open-saas-restart-fseventsd"
FSEVENTS_REMEDY_SUDOERS="/etc/sudoers.d/open-saas-fleet-doctor"
FSEVENTS_REMEDY_ATTEMPTED=0
FSEVENTS_REMEDY_REPORT=""
FSEVENTS_REMEDY_OLD=""
FSEVENTS_REMEDY_NEW=""

fsevents_ledger_path() { printf '%s' "${FSEVENTS_LEDGER:-$HOME/Library/Logs/open-saas-fsevents-restarts.tsv}"; }

fsevents_now_ms() {  # epoch milliseconds (perl ships on macOS; seconds*1000 as the fallback)
  local ms
  ms="$(perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' 2>/dev/null || true)"
  case "$ms" in ''|*[!0-9]*) ms=$(( $(date +%s) * 1000 )) ;; esac
  printf '%s' "$ms"
}

fsevents_remedy_permitted() {  # 0 = the NOPASSWD rule answers for the wrapper (never prompts)
  "${FSEVENTS_REMEDY_SUDO:-sudo}" -n -l "$FSEVENTS_REMEDY_WRAPPER" >/dev/null 2>&1
}

fsevents_remedy_wrapper_src() {  # the repo copy of the wrapper (the dry run's --check stand-in)
  if [ -n "${FSEVENTS_REMEDY_WRAPPER_SRC:-}" ]; then printf '%s' "$FSEVENTS_REMEDY_WRAPPER_SRC"; return 0; fi
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  printf '%s/ops/restart-fseventsd.sh' "${d:-scripts}"
}

fsevents_remedy_say() {  # the caller's warn hook (FSEVENTS_WARN), else stderr
  if [ -n "${FSEVENTS_WARN:-}" ]; then "$FSEVENTS_WARN" "$*"; else printf '%s\n' "$*" >&2; fi
}

fsevents_ledger_append() {  # <timestamp> <trigger> <worktree> <old> <new> <ms> <verdict> - never fatal
  local f
  f="$(fsevents_ledger_path)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  if [ ! -s "$f" ]; then
    printf 'timestamp\ttrigger\tworktree\told_pid\tnew_pid\treprobe_ms\tverdict\n' >> "$f" 2>/dev/null || true
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$f" 2>/dev/null || true
}

fsevents_ledger_summary() {  # fsevents_ledger_summary [days] -> "N (last <ts>, trigger <t>)" | "0 (none on record)"
  local f days="${1:-0}" cutoff=""
  f="$(fsevents_ledger_path)"
  [ -s "$f" ] || { printf '0 (none on record)'; return 0; }
  case "$days" in ''|*[!0-9]*|0) days=0 ;; esac
  if [ "$days" -gt 0 ]; then
    cutoff="$(date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${days} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  fi
  # ISO-8601 UTC stamps compare lexicographically, so no date parsing in awk.
  awk -F'\t' -v cutoff="$cutoff" -v days="$days" '
    NR == 1 && $1 == "timestamp" { next }
    $7 ~ /^restarted-/ && (cutoff == "" || $1 >= cutoff) { n++; last = $1; trig = $2 }
    END {
      if (n) printf "%d (last %s, trigger %s)", n, last, trig
      else if (days > 0) printf "0 (none in the last %s days)", days
      else printf "0 (none on record)"
    }' "$f" 2>/dev/null || printf '0 (ledger unreadable)'
}

fsevents_remedy_run() {  # fsevents_remedy_run <trigger> [project-dir]  -> 0 healed, 1 not permitted, 2 still dead / failed / second verdict
  local trigger="${1:-unknown}" dir="${2:-$PWD}" dry="${FSEVENTS_REMEDY_DRY:-0}" probe="${FSEVENTS_REMEDY_PROBE:-fsevents_probe}"
  local out="" rc=0 old="" new="" t0 t1 ms rc_a=0 rc_b=0 log_a="" log_b="" verdict="" stamp tag=""
  FSEVENTS_REMEDY_REPORT=""; FSEVENTS_REMEDY_OLD=""; FSEVENTS_REMEDY_NEW=""
  [ "$dry" = "1" ] && tag=" [DRY RUN - FSEVENTS_REMEDY_DRY=1: wrapper --check, nothing killed]"
  if [ "${FSEVENTS_REMEDY_ATTEMPTED:-0}" -ge 1 ]; then
    FSEVENTS_REMEDY_REPORT="FSEVENTS still DEAD after the unattended fseventsd restart earlier in this run (trigger $trigger) - no second attempt is ever made: step 2 of the ladder, REBOOT.$tag"
    fsevents_remedy_say "$FSEVENTS_REMEDY_REPORT"
    return 2
  fi
  if ! fsevents_remedy_permitted; then
    FSEVENTS_REMEDY_REPORT="FSEVENTS unattended restart NOT permitted on this machine (sudo -n -l $FSEVENTS_REMEDY_WRAPPER refused: the operator has not installed the root half - sudo scripts/ops/install-fsevents-remedy.sh, once) - falling back to the paste line.$tag"
    fsevents_remedy_say "$FSEVENTS_REMEDY_REPORT"
    return 1
  fi
  FSEVENTS_REMEDY_ATTEMPTED=1
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  old="$(fsevents_remedy_pid)"
  if [ "$dry" = "1" ]; then
    out="$(sh "$(fsevents_remedy_wrapper_src)" --check 2>&1)" && rc=0 || rc=$?
    new="$old"
    if [ "$rc" -ne 0 ] || [ "$out" != "permitted" ]; then
      fsevents_ledger_append "$stamp" "$trigger" "$dir" "${old:-none}" "none" 0 "dry-failed"
      FSEVENTS_REMEDY_REPORT="FSEVENTS dry run (trigger $trigger): the repo wrapper's --check did not answer permitted (rc $rc: ${out:-no output}) - $(fsevents_remedy_wrapper_src)$tag"
      fsevents_remedy_say "$FSEVENTS_REMEDY_REPORT"
      return 2
    fi
  else
    out="$("${FSEVENTS_REMEDY_SUDO:-sudo}" -n "$FSEVENTS_REMEDY_WRAPPER" 2>&1)" && rc=0 || rc=$?
    case "$out" in
      *old=*) old="$(printf '%s' "$out" | sed -n 's/.*old=\([^ ]*\).*/\1/p' | head -1)" ;;
    esac
    new="$(printf '%s' "$out" | sed -n 's/.*new=\([^ ]*\).*/\1/p' | head -1)"
    if [ "$rc" -ne 0 ] || [ -z "$new" ] || [ "$new" = "none" ]; then
      fsevents_ledger_append "$stamp" "$trigger" "$dir" "${old:-none}" "none" 0 "wrapper-failed"
      FSEVENTS_REMEDY_REPORT="FSEVENTS unattended restart FAILED (trigger $trigger): $FSEVENTS_REMEDY_WRAPPER exited $rc (${out:-no output}) - fseventsd ${old:-?} may be gone with no respawn: step 2 of the ladder, REBOOT."
      fsevents_remedy_say "$FSEVENTS_REMEDY_REPORT"
      return 2
    fi
  fi
  FSEVENTS_REMEDY_OLD="$old"; FSEVENTS_REMEDY_NEW="$new"
  t0="$(fsevents_now_ms)"
  "$probe" "$dir" && rc_a=0 || rc_a=$?
  case "$probe" in fsevents_alive) log_a="${FSEVENTS_PROBE_LOG:-}" ;; *) log_a="${FSEVENTS_PROBE_ATTEMPTS:-}" ;; esac
  "$probe" /private/tmp && rc_b=0 || rc_b=$?
  case "$probe" in fsevents_alive) log_b="${FSEVENTS_PROBE_LOG:-}" ;; *) log_b="${FSEVENTS_PROBE_ATTEMPTS:-}" ;; esac
  t1="$(fsevents_now_ms)"
  ms=$(( t1 - t0 ))
  if [ "$rc_a" -ne 1 ] && [ "$rc_b" -ne 1 ]; then
    if [ "$dry" = "1" ]; then verdict="dry-alive"; else verdict="restarted-alive"; fi
    fsevents_ledger_append "$stamp" "$trigger" "$dir" "${old:-none}" "${new:-none}" "$ms" "$verdict"
    if [ "$dry" = "1" ]; then
      FSEVENTS_REMEDY_REPORT="FSEVENTS RESTARTED unattended (trigger $trigger): fseventsd ${old:-?} -> ${new:-?}, both volumes ALIVE after ${ms}ms$tag (ledger $(fsevents_ledger_path))"
    else
      FSEVENTS_REMEDY_REPORT="FSEVENTS RESTARTED unattended (trigger $trigger): fseventsd $old -> $new, both volumes ALIVE after ${ms}ms (ledger $(fsevents_ledger_path))"
    fi
    fsevents_remedy_say "$FSEVENTS_REMEDY_REPORT"
    return 0
  fi
  if [ "$dry" = "1" ]; then verdict="dry-dead"; else verdict="restarted-dead"; fi
  fsevents_ledger_append "$stamp" "$trigger" "$dir" "${old:-none}" "${new:-none}" "$ms" "$verdict"
  FSEVENTS_REMEDY_REPORT="FSEVENTS RESTARTED unattended (trigger $trigger): fseventsd ${old:-?} -> ${new:-?}, but delivery is STILL DEAD after ${ms}ms ($dir: ${log_a:-rc $rc_a}; /private/tmp: ${log_b:-rc $rc_b}) - no second attempt: step 2 of the ladder, REBOOT.$tag (ledger $(fsevents_ledger_path))"
  fsevents_remedy_say "$FSEVENTS_REMEDY_REPORT"
  return 2
}
