#!/usr/bin/env bash
#
# replica-doctor.sh - read-only memory doctor for the local PocketIC replicas
# on this machine, attributed to the seat worktree that owns each one.
#
# Ported 2026-09-01 from the open-saas factory's replica-doctor (upstream
# 2594cf507 lineage) - the --rss / --rss-all modes ONLY. Upstream's reap /
# unwedge / orphan-classification modes were deliberately NOT ported: here
# stray-master reaping is cold_start.sh's job (worktree-safe since W1-06),
# and this doctor stays a pure read-only ps/lsof/pgrep/top tool that makes
# NO icp calls, so it can never wedge behind the icp CLI's global locks and
# is safe to run at any time, from any seat, against any worktree - it is
# the measurement half of factory.sh's claim-boundary recycle gate.
#
# WHY: seat venues ratchet upward with deploy/seed/suite churn. Upstream's
# failure mode (2026-08-28): five veteran seats quietly grew 4-10GB replicas
# at once. Same physics here, on a machine that also hosts live fleets - so
# growth must be visible and recycling enforceable BEFORE Activity Monitor
# screenshots are needed.
#
# ATTRIBUTION (adapted to OUR layout): every pocket-ic MAIN (`--ttl`) - or
# its parent icp-cli-network-launcher - holds open fds naming its owner:
#   1. <worktree>/.icp/cache/networks/...   (the network state dir; the icp
#      CLI keeps network state under the PROJECT even when ICP_HOME is set)
#   2. <worktree>/.icp-home/pkg/network-launcher/.../pocket-ic  (the binary
#      inside the seat's isolated ICP_HOME - the per-seat store every
#      multidex seat exports; the belt when marker 1 is absent)
# Never by port, never by process name alone: this machine runs SEVERAL icp
# projects (open-saas beside multidex) plus one replica per seat worktree,
# and misattribution is how a doctor kills someone else's live venue.
#
# THE METRIC is phys_footprint (resident + compressed - Activity Monitor's
# Memory column), summed over the whole process tree rooted at each owned
# main (launcher + server + canister sandboxes). macOS moves idle pocket-ic
# pages to the compressor, so a plain `ps -o rss` sum under-reads a fat
# instance by 10x+ (upstream 2026-08-27: 456MB reported while Activity
# Monitor showed 6.53GB, and the budget never fired). Sources, best first:
# one `top -l 1 -stats pid,mem` sample (MEM on modern macOS top IS the
# footprint), then /usr/bin/footprint per pid; `ps -o rss` summing is the
# LAST resort only, labeled an UNDERESTIMATE.
#
# Usage:
#   ./scripts/replica-doctor.sh --rss <worktree>
#       Footprint of the PocketIC instance(s) OWNED BY that worktree,
#       against the seat budget (REPLICA_RSS_BUDGET_GB, default 3 - the
#       env names keep upstream's historic "rss" spelling) and the AGE
#       BELT: an owned main older than REPLICA_MAX_AGE_HOURS (default 48;
#       0 disables) is a recycle verdict REGARDLESS of measured memory, so
#       a metric gap can never disable recycling.
#       Exit codes: 0 = under budget and under age (or no replica at all),
#       3 = OVER budget or past the age belt, 2 = usage error.
#       Every verdict's TOTAL line carries the oldest owned main's age as
#       `<n>h [<raw etime>]` - age_label, ONE formatter for all three shapes.
#   ./scripts/replica-doctor.sh --rss-all     (also the default, no flags)
#       Machine-wide sweep: every pocket-ic main, grouped by owning
#       project/worktree, one footprint line each - the prioritizer's
#       board sweep. Foreign projects are listed (memory is machine-wide)
#       but nothing is ever touched. Always exit 0.
#   ./scripts/replica-doctor.sh --start-wedge <worktree>
#       The START doctor (task 1788580163): diagnoses an `icp network start
#       --background` that never printed "Network started on port". Finds
#       THAT worktree's icp-cli-network-launcher by the `--state-dir
#       <worktree>/.icp/cache/networks/local/state` argument in its argv
#       (a ps snapshot taken BEFORE the filter runs, so the filter can never
#       match itself; relative-argv launchers fall back to the lsof
#       attribution above), then reports, read-only: status-dir file count,
#       CPU%, elapsed, TCP connections, the pocket-ic child and whether its
#       `--port-file` still exists, the ports it listens on and whether
#       `GET /instances` answers, the worktree's descriptor.json + gateway
#       probe, and the CLI's own stdout/stderr log tails. Only ps/lsof/ls/
#       cat and curl to 127.0.0.1 - NO icp calls, so it cannot wedge either.
#       Verdict (last line) and exit code:
#         0  HEALTHY            launcher serving: status dir populated
#                               (status.json) / descriptor present for it
#         4  STARTING (<n>s)    young - under the grace (REPLICA_START_GRACE_S,
#                               default 90); check again, do not intervene
#         5  WEDGED (launcher parked, port file unread)
#                               past the grace with the 2026-09-05 signature:
#                               launcher alive, 0% CPU, EMPTY status dir, no
#                               TCP to pocket-ic; the child listens, answers
#                               `[]` on /instances, and its pocketic.port file
#                               is still there - a healthy launcher reads and
#                               deletes it within seconds. It never recovers.
#         6  NO LAUNCHER        no launcher for this worktree at all - the
#                               start never happened, or its process group
#                               died with the shell that launched it (a
#                               timed-out harness call); stale descriptor /
#                               lock / logs are called out
#         2  usage error
#       The 2026-09-05 wedge is NOT transient (five retries in a row on one
#       seat): WEDGED twice in a row means stop retrying and escalate to
#       the operator (HUMAN NEEDED). The root cause, as far as the local
#       binary tells: the launcher waits for pocket-ic's port file through a
#       notify-rs FSEvents watcher with no polling fallback, so one dropped
#       filesystem event (fseventsd under churn) parks it forever.
#
# Recycling an over-budget/over-age SEAT venue is the full re-bring-up:
# `icp network stop` from THAT worktree root (its ICP_HOME exported), then
# cold_start per the posture rhythm (flip #dev, `bash scripts/cold_start.sh
# --mode full --no-simulate`, restore #play) - a network restart NEVER
# resumes state. Never `pkill pocket-ic`; never stop a replica this doctor
# attributes to someone else's worktree.

info() { printf '  %s\n' "$1"; }

# -- the age read (task 1789047001) -------------------------------------------
# The age belt's ONLY source is `ps -o etime=` on the owned main, and on this
# machine that read DEGRADES now and then (2 of ~55 hourly samples on seat-1:
# `oldest main 0h` against a 22h main, `24h` against a 43h one - an EMPTY
# read, and a day-prefixed read with a truncated remainder landing on a
# whole-day multiple). An age that reads LOW silently disables the belt, so
# a read that does not match [[dd-]hh:]mm:ss EXACTLY is UNKNOWN (-1), never
# a smaller number: the caller keeps its previous best and says so out loud.
# Both observed wobbles re-read fine a minute later, so the read retries.

# Seconds parsed from ONE etime string. Prints -1 for an empty or
# non-matching read. Pure (no ps), so tests/test_deploy_hygiene.sh §6bd
# can pin it: '01-19:22:50' -> 156170, '' / '01-19' / '01-19:22' -> -1.
etime_secs() {
  local et="$1" d=0 a b c
  case "$et" in
    *-*)
      d="${et%%-*}"; et="${et#*-}"
      case "$d" in ''|*[!0-9]*) printf -- '-1'; return ;; esac
      # with a day prefix BSD ps always prints hh:mm:ss - anything shorter
      # is the truncated read that once parsed to a whole-day multiple
      case "$et" in [0-9]*:[0-9]*:[0-9]*) ;; *) printf -- '-1'; return ;; esac
      ;;
  esac
  case "$et" in
    [0-9]*:[0-9]*:[0-9]*) a="${et%%:*}"; et="${et#*:}"; b="${et%%:*}"; c="${et#*:}" ;;
    [0-9]*:[0-9]*)        a=0; b="${et%%:*}"; c="${et#*:}" ;;
    *) printf -- '-1'; return ;;
  esac
  case "$a$b$c" in ''|*[!0-9]*) printf -- '-1'; return ;; esac
  printf '%s' "$(( (d * 24 + 10#$a) * 3600 + 10#$b * 60 + 10#$c ))"
}

# Elapsed seconds of a pid: up to 3 `ps -o etime=` reads, a short sleep
# between them. Sets AGE_SECS (-1 when every read failed to parse) and
# AGE_RAW (the text of the LAST read, for the note / the TOTAL line) in the
# calling shell - no subshell, so the raw survives for the caller.
AGE_SECS=-1
AGE_RAW=""
age_read() {
  local try=0
  AGE_SECS=-1; AGE_RAW=""
  while :; do
    AGE_RAW="$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')"
    AGE_SECS="$(etime_secs "$AGE_RAW")"
    [ "$AGE_SECS" -ge 0 ] && return 0
    try=$(( try + 1 ))
    [ "$try" -ge 3 ] && return 0
    sleep 0.2
  done
}
# The printing form (the start doctor's callers): -1 = unreadable.
age_secs() { age_read "$1"; printf '%s' "$AGE_SECS"; }

# -- the age label (task 1793750605) ------------------------------------------
# ONE formatter for the oldest owned main's age, used by EVERY --rss verdict
# line - healthy, OVER budget, past the AGE BELT - so the bracketed raw etime
# rides all of them: "<n>h [<raw>]", the hours first and the raw `ps -o
# etime=` read bracketed beside them ("22h [22:14:33]" - the next wobble is
# diagnosable from the one line seats already log), or the UNREADABLE label
# when no owned main's etime parsed this pass. `$1` is an optional word
# between the hours and the bracket: the age-belt verdict reads `is <n>h old
# [<raw>]`. The `<n>h` token stays FIRST either way: factory.sh's claim gate
# parses `oldest main <n>h` and `is <n>h old` (recycle_gate) - keep those
# two shapes byte-compatible. Reads OLDEST_PID / OLDEST_AGE / OLDEST_RAW,
# the --rss loop's maximum over the owned mains (initialised here so the
# lib seam below exposes the formatter to tests/test_deploy_hygiene.sh §6bd).
# Before this the over-age verdict rendered its TOTAL line by hand, WITHOUT
# the bracket (the raw rode the next line only), and §6bd's live pin went
# red on any machine whose venue was past the belt (the operator's, 50 h,
# 2026-11-04 - the 1.80 rollout pre-flight).
OLDEST_AGE=0
OLDEST_PID=""
OLDEST_RAW=""
age_label() {
  if [ -n "$OLDEST_PID" ]; then printf '%sh %s[%s]' "$(( OLDEST_AGE / 3600 ))" "${1:+$1 }" "$OLDEST_RAW"
  else printf '%s' "UNREADABLE this pass (no owned main's etime parsed - see the note above)"; fi
}

# Test seam: `REPLICA_DOCTOR_LIB=1 . scripts/replica-doctor.sh` defines the
# functions above and stops here (tests/test_deploy_hygiene.sh §6bd).
if [ "${REPLICA_DOCTOR_LIB:-}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

RSS_TARGET=""
RSS_ALL=false
SW_TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rss)
      shift
      [ $# -gt 0 ] || { echo "--rss needs a worktree path"; exit 2; }
      RSS_TARGET="$1"
      ;;
    --rss-all) RSS_ALL=true ;;
    --start-wedge)
      shift
      [ $# -gt 0 ] || { echo "--start-wedge needs a worktree path"; exit 2; }
      SW_TARGET="$1"
      ;;
    *) echo "unknown flag: $1 (use --rss <worktree>, --rss-all, --start-wedge <worktree>)"; exit 2 ;;
  esac
  shift
done
[ -n "$RSS_TARGET" ] || [ -n "$SW_TARGET" ] || RSS_ALL=true


# Attribution: the state-dir (or ICP_HOME launcher) path in the process's -
# or its parent launcher's - open fds names the owning project/worktree.
rss_project_of() {  # $1 = pid ; echoes the owning project root or ""
  local pid="$1" out p=""
  out="$( { lsof -p "$pid" 2>/dev/null; PPID_="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"; \
          [ -n "$PPID_" ] && lsof -p "$PPID_" 2>/dev/null; } || true)"
  p="$(printf '%s\n' "$out" | grep -oE '/[^ ]*/\.icp/cache/networks/' | head -1 || true)"
  if [ -n "$p" ]; then printf '%s' "${p%/.icp/cache/networks/}"; return; fi
  # OUR layout's belt: the per-seat ICP_HOME (<worktree>/.icp-home) holds the
  # network-launcher + pocket-ic binaries the main keeps mapped.
  p="$(printf '%s\n' "$out" | grep -oE '/[^ ]*/\.icp-home/' | head -1 || true)"
  [ -n "$p" ] && printf '%s' "${p%/.icp-home/}"
}

# All pids in the process tree rooted at $1 (the main + every descendant).
rss_tree_pids() {
  local pid="$1" kid
  printf '%s\n' "$pid"
  for kid in $(pgrep -P "$pid" 2>/dev/null || true); do
    rss_tree_pids "$kid"
  done
}

# -- the metric: phys_footprint, not rss (see the header) ---------------------
FP_SNAP=""
fp_snapshot() {  # one top sample, normalized to "PID KB" lines (may be empty)
  FP_SNAP="$(top -l 1 -stats pid,mem 2>/dev/null | awk '
    $1 ~ /^[0-9]+$/ && NF >= 2 {
      v = $2; sub(/[+-]$/, "", v)
      u = substr(v, length(v), 1); n = v
      if (u ~ /[BKMG]/) n = substr(v, 1, length(v) - 1)
      if (n !~ /^[0-9]+(\.[0-9]+)?$/) next
      if (u == "B") kb = n / 1024
      else if (u == "K") kb = n
      else if (u == "M") kb = n * 1024
      else if (u == "G") kb = n * 1024 * 1024
      else kb = n
      printf "%d %d\n", $1, kb
    }')"
}
fp_kb_top() {  # $1 = pid ; echoes footprint KB from the snapshot, or nothing
  [ -n "$FP_SNAP" ] || return 0
  printf '%s\n' "$FP_SNAP" | awk -v p="$1" '$1 == p { print $2; exit }'
}
fp_kb_footprint() {  # $1 = pid ; echoes footprint KB, or nothing
  [ -x /usr/bin/footprint ] || return 0
  /usr/bin/footprint "$1" 2>/dev/null | awk '
    /Footprint:/ {
      for (i = 1; i < NF; i++) if ($i == "Footprint:") { n = $(i+1); u = $(i+2) }
      if (n ~ /^[0-9]+(\.[0-9]+)?$/) {
        if (u ~ /^KB/) printf "%d\n", n
        else if (u ~ /^MB/) printf "%d\n", n * 1024
        else if (u ~ /^GB/) printf "%d\n", n * 1024 * 1024
        else if (u ~ /^B/) printf "%d\n", n / 1024
      }
      exit
    }'
}
# Footprint KB summed over a whitespace-separated pid list. Echoes
# "<totalKB> <source>" where source is top | footprint | mixed | rss.
fp_kb_of() {
  local total=0 pid kb ntop=0 nfpt=0 nrss=0 src
  for pid in $1; do
    kb="$(fp_kb_top "$pid")"
    if [ -n "$kb" ]; then ntop=$(( ntop + 1 ))
    else
      kb="$(fp_kb_footprint "$pid")"
      if [ -n "$kb" ]; then nfpt=$(( nfpt + 1 ))
      else
        kb="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
        if [ -n "$kb" ]; then nrss=$(( nrss + 1 )); else kb=0; fi
      fi
    fi
    total=$(( total + kb ))
  done
  if [ $(( ntop + nfpt )) -eq 0 ] && [ "$nrss" -gt 0 ]; then src="rss"
  elif [ "$nrss" -gt 0 ]; then src="mixed"
  elif [ "$nfpt" -gt 0 ]; then src="footprint"
  else src="top"
  fi
  printf '%s %s' "$total" "$src"
}
fp_src_note() {  # source tag -> human label for output lines
  case "$1" in
    top)       printf 'footprint via top' ;;
    footprint) printf 'footprint via /usr/bin/footprint' ;;
    mixed)     printf 'footprint; some pids via ps rss' ;;
    rss)       printf 'ps rss only - UNDERESTIMATE, compressed pages not counted' ;;
  esac
}

# -- the start doctor (--start-wedge) -----------------------------------------
# Everything here is a read: ps/lsof/ls/cat plus curl to 127.0.0.1. It runs
# BEFORE the memory doctor's pgrep/top work below and exits on its own, so a
# --start-wedge call never pays for a machine-wide top sample.
sw_argv_of() { ps -o command= -p "$1" 2>/dev/null; }
sw_opt_of() {  # $1 = argv text, $2 = --flag ; echoes the flag's value or ""
  printf '%s\n' "$1" | sed -n "s/.*$2 \([^ ]*\).*/\1/p" | head -1
}
sw_alive() { kill -0 "$1" 2>/dev/null; }
# Launchers whose argv names this worktree's state dir. The ps snapshot is
# taken FIRST and filtered afterwards, so the filter (which carries the
# pattern in its own argv) can never match itself - the process-safety
# skill's self-match trap, structurally avoided. Relative-argv launchers
# (`--state-dir ./.icp/...`, the primary checkout's shape) are attributed
# through their open fds instead, the same lsof marker --rss uses.
sw_launchers_for() {  # $1 = worktree ; prints one launcher pid per line
  local wt="$1" snap found pid
  snap="$(ps -eo pid=,command= 2>/dev/null)"
  found="$(printf '%s\n' "$snap" | awk -v wt="$wt" '
    index($0, "icp-cli-network-launcher") {
      pat = "--state-dir " wt "/.icp/cache/networks/local/state"; i = index($0, pat)
      if (i && (i + length(pat) > length($0) || substr($0, i + length(pat), 1) == " ")) print $1
    }')"
  if [ -n "$found" ]; then printf '%s\n' "$found"; return; fi
  for pid in $(printf '%s\n' "$snap" | awk '
    index($0, "icp-cli-network-launcher") && index($0, "--state-dir .") { print $1 }'); do
    if lsof -p "$pid" 2>/dev/null | grep -qF "$wt/.icp/cache/networks/"; then printf '%s\n' "$pid"; fi
  done
}
sw_listen_ports() {  # $1 = space-separated pids ; echoes the TCP ports they listen on
  local list
  list="$(printf '%s' "$1" | tr -s ' ' ',' | sed 's/^,//; s/,$//')"
  [ -n "$list" ] || return 0
  lsof -a -p "$list" -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk 'NR > 1 { n = split($9, a, ":"); print a[n] }' | sort -un | tr '\n' ' '
}
sw_tail() {  # $1 = label, $2 = file ; prints the last 3 lines, one-line each
  local f="$2" n
  if [ ! -f "$f" ]; then info "$1: (no file)"; return; fi
  n="$(wc -c < "$f" | tr -d ' ')"
  if [ "$n" -eq 0 ]; then info "$1: (empty)"; return; fi
  tail -n 3 "$f" | while IFS= read -r line; do info "$1: $line"; done
}

start_wedge() {  # $1 = worktree ; prints the report, exits with the verdict code
  local wt grace launchers nl pid argv ver etime elapsed cpu conns sdir nstatus has_status
  local kids kid kargv child="" cargv="" cetime="" ccpu="" pfile="" pfile_state="" ctree ports p inst="" inst_port=""
  local netdir desc dport="" dpid="" gw_code="" lock verdict rc remedy youngest="" yelapsed=""
  [ -d "$1" ] || { echo "--start-wedge: not a directory: $1"; exit 2; }
  wt="$(cd "$1" && pwd)"
  grace="${REPLICA_START_GRACE_S:-90}"
  case "$grace" in ''|*[!0-9]*) echo "REPLICA_START_GRACE_S must be a whole number of seconds"; exit 2 ;; esac
  netdir="$wt/.icp/cache/networks/local"
  desc="$netdir/descriptor.json"
  echo "Start doctor for $wt (read-only: ps/lsof/curl 127.0.0.1; grace ${grace}s, override REPLICA_START_GRACE_S):"
  launchers="$(sw_launchers_for "$wt")"
  nl="$(printf '%s\n' "$launchers" | grep -c '[0-9]' || true)"
  # The worktree-side leftovers are reported in every verdict: they are what
  # a human sees first, and what a stale start leaves behind.
  if [ -f "$desc" ]; then
    dport="$(sed -n 's/.*"port": *\([0-9][0-9]*\).*/\1/p' "$desc" | head -1)"
    dpid="$(sed -n 's/.*"pid": *\([0-9][0-9]*\).*/\1/p' "$desc" | head -1)"
  fi
  [ -e "$netdir/lock" ] && lock="present" || lock="absent"
  if [ "$nl" -eq 0 ]; then
    info "launcher: NONE whose --state-dir names this worktree (checked argv, then open fds)"
    if [ -f "$desc" ]; then
      if [ -n "$dpid" ] && sw_alive "$dpid"; then
        info "descriptor.json: gateway port ${dport:-?}, child pid $dpid is alive but is not a launcher for this worktree"
      else
        info "descriptor.json: STALE (gateway port ${dport:-?}, child pid ${dpid:-?} is dead)"
      fi
    else
      info "descriptor.json: absent"
    fi
    info "network lock ($netdir/lock): $lock"
    sw_tail "stderr.log" "$netdir/network-launcher/stderr.log"
    sw_tail "stdout.log" "$netdir/network-launcher/stdout.log"
    echo "NO LAUNCHER for $wt"
    echo "remedy: the start never ran, or its process group died with the shell that launched it (a"
    echo "  harness call that timed out kills its children). Relaunch in a SHORT call - from the"
    echo "  worktree root, ICP_HOME exported: nohup icp network start --background > <log> 2>&1 & -"
    echo "  then check \`icp network status\` in a SEPARATE call (~40s on a loaded machine)."
    exit 6
  fi
  if [ "$nl" -gt 1 ]; then
    info "WARNING: $nl launchers name this worktree ($(printf '%s' "$launchers" | tr '\n' ' ')) - overlapping starts;"
    info "  the youngest is evaluated below; the older ones are the ones to stop (by PID) after this verdict"
  fi
  # Evaluate the youngest launcher (the most recent start attempt).
  for pid in $launchers; do
    elapsed="$(age_secs "$pid")"
    [ "$elapsed" -ge 0 ] || continue   # unreadable age (-1) never wins "youngest"
    if [ -z "$youngest" ] || [ "$elapsed" -lt "$yelapsed" ]; then youngest="$pid"; yelapsed="$elapsed"; fi
  done
  [ -n "$youngest" ] || youngest="$(printf '%s\n' "$launchers" | head -1)"
  pid="$youngest"
  argv="$(sw_argv_of "$pid")"
  ver="$(printf '%s\n' "$argv" | sed -n 's#.*/network-launcher/\([^/]*\)/icp-cli-network-launcher.*#\1#p' | head -1)"
  etime="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
  elapsed="$(age_secs "$pid")"
  cpu="$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')"
  conns="$(lsof -a -p "$pid" -iTCP -P -n 2>/dev/null | awk 'NR > 1' | wc -l | tr -d ' ')"
  info "launcher PID $pid: version ${ver:-?}, elapsed ${elapsed}s (${etime:-?}), cpu ${cpu:-?}%, TCP connections $conns"
  sdir="$(sw_opt_of "$argv" --status-dir)"
  nstatus=0; has_status=no
  if [ -n "$sdir" ] && [ -d "$sdir" ]; then
    nstatus="$(ls -A "$sdir" 2>/dev/null | wc -l | tr -d ' ')"
    [ -f "$sdir/status.json" ] && has_status=yes
    info "status dir $sdir: $nstatus file(s) (status.json: $has_status)"
  else
    info "status dir ${sdir:-<none in argv>}: MISSING"
  fi
  # The pocket-ic child: by ancestry (pgrep -P, never a name), then its
  # --port-file - the file the launcher must read and delete to get going.
  kids="$(pgrep -P "$pid" 2>/dev/null | tr -d ' ' || true)"
  for kid in $kids; do
    kargv="$(sw_argv_of "$kid")"
    case "$kargv" in *pocket-ic\ --ttl*|*/pocket-ic\ *) child="$kid"; cargv="$kargv"; break ;; esac
  done
  if [ -n "$child" ]; then
    cetime="$(ps -o etime= -p "$child" 2>/dev/null | tr -d ' ')"
    ccpu="$(ps -o %cpu= -p "$child" 2>/dev/null | tr -d ' ')"
    pfile="$(sw_opt_of "$cargv" --port-file)"
    if [ -z "$pfile" ]; then pfile_state="none in argv"
    elif [ -f "$pfile" ]; then pfile_state="STILL PRESENT (contents: $(tr -d '\n' < "$pfile" 2>/dev/null)) - unread by the launcher"
    else pfile_state="gone (consumed by the launcher)"
    fi
    info "pocket-ic child PID $child: elapsed ${cetime:-?}, cpu ${ccpu:-?}%"
    info "  port file ${pfile:-?}: $pfile_state"
    ctree="$(rss_tree_pids "$child" | tr '\n' ' ')"
    ports="$(sw_listen_ports "$ctree")"
    info "  listens on TCP: ${ports:-<nothing>}"
    for p in $ports; do
      inst="$(curl -s -m 2 "http://127.0.0.1:$p/instances" 2>/dev/null || true)"
      case "$inst" in \[*) inst_port="$p"; break ;; esac
      inst=""
    done
    if [ -n "$inst_port" ]; then
      info "  GET /instances on $inst_port -> $(printf '%s' "$inst" | cut -c1-96)"
    else
      info "  GET /instances: no listening port answered"
    fi
  else
    info "pocket-ic child: NONE under launcher $pid (children: $(printf '%s' "${kids:-none}" | tr '\n' ' '))"
  fi
  if [ -f "$desc" ]; then
    if [ -n "$dport" ]; then
      gw_code="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$dport/api/v2/status" 2>/dev/null || true)"
    fi
    info "descriptor.json: gateway port ${dport:-?}, child pid ${dpid:-?}; GET /api/v2/status -> ${gw_code:-no answer}"
  else
    info "descriptor.json: absent (the CLI writes it only once the launcher reports its ports)"
  fi
  info "network lock ($netdir/lock): $lock"
  sw_tail "stderr.log" "$netdir/network-launcher/stderr.log"
  sw_tail "stdout.log" "$netdir/network-launcher/stdout.log"
  # -- the verdict --
  if [ "$has_status" = yes ] || { [ -f "$desc" ] && [ "$dpid" = "$pid" ]; }; then
    echo "HEALTHY (launcher $pid serving: status dir populated${dport:+, gateway $dport}${gw_code:+ answers $gw_code})"
    exit 0
  fi
  if [ "$elapsed" -lt 0 ]; then
    echo "STARTING (launcher age UNREADABLE this pass: ps etime '${etime}' after 3 reads) - treated as young; check again"
    echo "remedy: none yet - re-run; an unreadable age never produces a WEDGED verdict (a kill recipe) on its own."
    exit 4
  fi
  if [ "$elapsed" -lt "$grace" ]; then
    echo "STARTING (${elapsed}s) - under the ${grace}s grace; a healthy start populates the status dir in ~20-40s"
    echo "remedy: none yet - check again after the grace; do not stop, restart, or touch the port file."
    exit 4
  fi
  if [ -n "$child" ] && [ -n "$pfile" ] && [ -f "$pfile" ]; then
    echo "WEDGED (launcher parked, port file unread) - ${elapsed}s old, ${cpu:-?}% cpu, ${nstatus} status file(s), $conns TCP conns"
  else
    echo "WEDGED (launcher parked, status dir empty past the grace; port file ${pfile_state:-n/a}) - ${elapsed}s old, ${cpu:-?}% cpu"
  fi
  echo "remedy: it will not recover (touching/rewriting the port file does not wake it). Stop BOTH"
  echo "  halves by these PIDs (never a pattern): kill $pid${child:+ $child}; then rm -f $netdir/lock"
  echo "  and retry ONCE. WEDGED twice in a row is not a transient - stop retrying and escalate to the"
  echo "  operator (HUMAN NEEDED); see docs/seat-venue-bring-up.md."
  exit 5
}
[ -n "$SW_TARGET" ] && start_wedge "$SW_TARGET"

BUDGET_GB="${REPLICA_RSS_BUDGET_GB:-3}"
case "$BUDGET_GB" in ''|*[!0-9]*) echo "REPLICA_RSS_BUDGET_GB must be a whole number of GB"; exit 2 ;; esac
MAX_AGE_H="${REPLICA_MAX_AGE_HOURS:-48}"
case "$MAX_AGE_H" in ''|*[!0-9]*) echo "REPLICA_MAX_AGE_HOURS must be a whole number of hours (0 disables the age belt)"; exit 2 ;; esac
MAINS="$(pgrep -f "pocket-ic --ttl" 2>/dev/null || true)"
# The top sample is taken ONCE, in the main shell (subshell command
# substitutions could not cache it), and only when there is work to do.
[ -n "$MAINS" ] && fp_snapshot

if [ "$RSS_ALL" = true ]; then
  echo "PocketIC memory sweep (footprint = phys_footprint over each main's process tree; read-only):"
  if [ -z "$MAINS" ]; then
    info "no PocketIC instances are running (any project)"
    exit 0
  fi
  for pid in $MAINS; do
    proj="$(rss_project_of "$pid")"
    tree="$(rss_tree_pids "$pid" | tr '\n' ' ')"
    kbsrc="$(fp_kb_of "$tree")"
    kb="${kbsrc%% *}"; src="${kbsrc##* }"
    nproc="$(printf '%s\n' $tree | wc -l | tr -d ' ')"
    age="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
    info "$(( kb / 1024 )) MB  main PID $pid  ($nproc procs, age ${age:-?}, $(fp_src_note "$src"))  ${proj:-owner-unknown}"
  done
  exit 0
fi

[ -d "$RSS_TARGET" ] || { echo "--rss: not a directory: $RSS_TARGET"; exit 2; }
WT="$(cd "$RSS_TARGET" && pwd)"
TOTAL_KB=0
OWNED=""
ANY_RSS=false
echo "Replica footprint for $WT (budget ${BUDGET_GB}GB resident+compressed; override REPLICA_RSS_BUDGET_GB):"
for pid in $MAINS; do
  proj="$(rss_project_of "$pid")"
  [ "$proj" = "$WT" ] || continue
  OWNED="$OWNED $pid"
  tree="$(rss_tree_pids "$pid" | tr '\n' ' ')"
  kbsrc="$(fp_kb_of "$tree")"
  kb="${kbsrc%% *}"; src="${kbsrc##* }"
  case "$src" in rss|mixed) ANY_RSS=true ;; esac
  nproc="$(printf '%s\n' $tree | wc -l | tr -d ' ')"
  TOTAL_KB=$(( TOTAL_KB + kb ))
  age_read "$pid"; a="$AGE_SECS"
  if [ "$a" -lt 0 ]; then
    # UNKNOWN keeps the previous best - an unreadable age never drives the belt DOWN
    info "note: age of main PID $pid unreadable this pass (raw: '$AGE_RAW') after 3 ps reads - previous best kept, never a smaller number"
  elif [ -z "$OLDEST_PID" ] || [ "$a" -gt "$OLDEST_AGE" ]; then OLDEST_AGE="$a"; OLDEST_PID="$pid"; OLDEST_RAW="$AGE_RAW"; fi
  info "main PID $pid: $(( kb / 1024 )) MB across $nproc processes (launcher + server + sandboxes; $(fp_src_note "$src"))"
done
if [ -z "$OWNED" ]; then
  info "no PocketIC instance owned by this worktree - nothing to measure"
  exit 0
fi
TOTAL_MB=$(( TOTAL_KB / 1024 ))
# Every verdict's TOTAL line renders the oldest main's age through age_label
# (one formatter, above): the bracketed raw etime rides all three shapes, and
# factory.sh's `oldest main <n>h` / `is <n>h old` parses stay byte-compatible.
if [ "$TOTAL_MB" -gt $(( BUDGET_GB * 1024 )) ]; then
  info "TOTAL: ${TOTAL_MB} MB footprint - OVER the ${BUDGET_GB}GB budget (oldest main $(age_label))"
  info "recycle at your next task boundary: icp network stop from THIS worktree root"
  info "(its ICP_HOME exported), then cold_start per the posture rhythm (flip #dev,"
  info "bash scripts/cold_start.sh --mode full --no-simulate, restore #play)."
  exit 3
fi
# The AGE BELT: a metric gap (rss fallback under-reading, a source going
# dark) must never disable recycling, so an old-enough replica is a recycle
# verdict regardless of what was measured.
if [ "$MAX_AGE_H" -gt 0 ] && [ "$OLDEST_AGE" -ge $(( MAX_AGE_H * 3600 )) ]; then
  # ONE line, every word of the former two kept: the TOTAL line is the age
  # line here as well (hygiene §6bd reads the first TOTAL line; the claim
  # gate reads `is <n>h old` anywhere in the output).
  info "TOTAL: ${TOTAL_MB} MB footprint - under the ${BUDGET_GB}GB budget, BUT main PID $OLDEST_PID is $(age_label old) - past the ${MAX_AGE_H}h AGE BELT (override REPLICA_MAX_AGE_HOURS; 0 disables)."
  info "Recycle at this boundary regardless of measured memory: icp network stop from"
  info "THIS worktree root (its ICP_HOME exported), then cold_start per the posture rhythm."
  exit 3
fi
if [ "$ANY_RSS" = true ]; then
  info "note: some or all of that total is ps rss (an underestimate) - the age belt is the recycling guarantee."
fi
info "TOTAL: ${TOTAL_MB} MB footprint - under the ${BUDGET_GB}GB budget (oldest main $(age_label) of the ${MAX_AGE_H}h age belt)"
exit 0
