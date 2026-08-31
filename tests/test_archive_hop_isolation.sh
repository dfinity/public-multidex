#!/bin/bash
# W1-03 — the History fan-out isolates per-segment failures.
#
# archiveExecute walks the archive chain (active + sealed) inside one
# composite query. Before the fix, both federated awaits sat bare: ONE
# unreachable segment (stopped, frozen, mid-upgrade) rejected the whole
# query — for EVERY caller, since the surface is public — so the History
# page and the AI assistant's history queries died venue-wide. The fix
# wraps each segment hop in try/catch and reports the segments it could
# not read in a `degraded` field instead of failing the read.
#
#   §1 build a two-segment chain (tiny cap → seal + roll, the
#      test_archive_chain.sh recipe)
#   §2 baseline: archiveExecute returns rows, degraded = vec {}
#   §3 STOP the sealed segment → archiveExecute still ANSWERS: rows from
#      the reachable segment, degraded names the stopped cid. (Pre-fix
#      this call rejected outright — the regression this test pins.)
#      Anonymous callers get the same degraded-not-dead read (the surface
#      is deliberately public: transparency doctrine, see archiveExecute's
#      AUTH comment).
#   §4 restart the segment → degraded drains back to empty
#   §5 setTestArchiveStopped refuses a principal that is not one of OUR
#      archive segments (it must never be a generic stop_canister)
#
# Structural assertions only (delta chatter makes counts workload-dependent).
# Timers stay ON (the shipper is heartbeat-driven); sim killed.
# ⚠️ Calls resetExchange (fresh epoch → seq 0, archives deleted). Needs #dev.

set -u
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
WD=$(mkid hop_wd)

# The sim must be dead (it would inject noise into the assertions).
# Stop it via the PID-file stopper — NEVER a pattern kill: `pkill -f` cannot
# tell a local simulator from one driving multidex.ai and took the live fleet
# down three times (run_all.sh's stopper comment + scripts/lib/bots.sh).
# run_all.sh already stops the fleet for suite runs; this covers standalone.
STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
if [ -f "$STOPPER" ]; then
  bash "$STOPPER" >/dev/null 2>&1 || true
  sleep 2
else
  echo "⚠ stop_bots_local.sh not found at $STOPPER — the local fleet was NOT stopped."
  echo "  Red results below may be simulator noise rather than regressions."
fi
adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true   # shipper must run
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestArchiveCap '(opt (20 : nat))' >/dev/null
adm setTestBalance "(principal \"$WD\", \"ICPUSD\", 100_000_000_000 : nat)" >/dev/null

drain() {  # wait for the transit queue to empty (ship tick = 10s)
  local tries=0
  while [ $tries -lt 12 ]; do
    UNSHIPPED=$(adm getCanisterInfo '()' --query | tr -d '_' | grep -oE "journalUnshipped = [0-9]+" | grep -oE "[0-9]+")
    [ "${UNSHIPPED:-1}" = "0" ] && return 0
    sleep 3; tries=$((tries+1))
  done
  return 1
}
wd() {  # emit withdrawal events (each = 1 semantic + its ledger deltas)
  local n="$1" tag="$2" i=0
  while [ $i -lt "$n" ]; do
    icp canister call --identity hop_wd backend withdraw "(\"ICPUSD\", 100_000_000 : nat, \"$tag-$i\")" >/dev/null 2>&1
    i=$((i+1))
  done
}
# archiveExecute via an args file, so the shell cannot mangle the JSON.
# ${2:-hop_wd}: the withdrawer by default (exercises the caller's-own-events
# leg); pass `anonymous` to exercise the public money-flow leg.
hist() {
  printf '("%s")' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')" > /tmp/hopiso.did
  icp canister call --args-file /tmp/hopiso.did backend archiveExecute --query --identity "${2:-hop_wd}" 2>&1
}
Q='{"start":"userEvent","limit":200}'

echo "── §1 grow a two-segment chain (cap 20 → seal + roll) ──"
wd 15 hop
if drain; then ok "wave 1 shipped (queue drained)"; else nok "queue not drained" "unshipped=${UNSHIPPED:-?}"; fi
EV=""
sealtries=0
while [ $sealtries -lt 12 ]; do
  EV=$(adm getRecentEvents '(300 : nat)' --query 2>/dev/null)
  echo "$EV" | grep -q "Archive sealed at seq" && break
  sleep 2; sealtries=$((sealtries+1))
done
if echo "$EV" | grep -q "Archive sealed at seq"; then ok "archive_0 sealed at capacity"; else nok "no seal event" "$(echo "$EV" | head -c 200)"; fi
wd 5 hop2
if drain; then ok "wave 2 shipped into the successor"; else nok "wave 2 stuck" "unshipped=${UNSHIPPED:-?}"; fi

ARCS=$(adm getArchives '()' --query | tr -d '_\n' | tr -s ' ')
IDS=($(echo "$ARCS" | grep -oE 'canisterId = "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"'))
N=${#IDS[@]}
if [ "$N" -ge 2 ]; then ok "chain has $N segments"; else nok "expected ≥2 segments" "$ARCS"; fi
SEALED_ID=${IDS[0]}

# STRANDED-STATE HYGIENE: a prior FAILED run's §3 leaves its segment
# stopped, and every later run's §2 baseline then reports it degraded — for
# real. The walk visits the SEASON REGISTRY (detached prior-season segments
# included), while getArchives lists only the current chain — so restart
# over the full chain table (idempotent; the hook itself is scoped to our
# own segments).
ALLIDS=$(adm getArchiveChain '()' --query | tr -d '_\n' | grep -oE 'canisterId = "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"' | sort -u)
for cid in $ALLIDS; do adm setTestArchiveStopped "(principal \"$cid\", false)" >/dev/null 2>&1; done
sleep 1

echo "── §2 baseline: all segments reachable ──"
R=$(hist "$Q" | tr -d '_\n' | tr -s ' ')
if echo "$R" | grep -q 'degraded = vec {}'; then ok "degraded is empty"; else nok "expected empty degraded" "$(echo "$R" | head -c 300)"; fi
# Rows are OQL cells (name/value pairs) — the seq cell proves ≥1 row came back.
if echo "$R" | grep -q 'name = "seq"' ; then ok "rows returned"; else nok "no rows in baseline" "$(echo "$R" | head -c 300)"; fi

echo "── §3 sealed segment stopped → degraded, not dead ──"
ST=$(adm setTestArchiveStopped "(principal \"$SEALED_ID\", true)")
if echo "$ST" | grep -q "ok"; then ok "sealed segment $SEALED_ID stopped"; else nok "stop refused" "$ST"; fi
R=$(hist "$Q" | tr -d '_\n' | tr -s ' ')
if echo "$R" | grep -q "reject\|Reject\|error"; then
  nok "archiveExecute failed outright (pre-fix behaviour)" "$(echo "$R" | head -c 300)"
else
  ok "archiveExecute still answers with a segment down"
fi
if echo "$R" | grep -Eq "degraded = vec \{[^}]*\"$SEALED_ID\""; then ok "degraded names the stopped segment"; else nok "degraded missing the cid" "$(echo "$R" | head -c 300)"; fi
if echo "$R" | grep -q 'name = "seq"'; then ok "reachable segment's rows still served"; else nok "no rows with one segment down" "$(echo "$R" | head -c 300)"; fi
RA=$(hist "$Q" anonymous | tr -d '_\n' | tr -s ' ')
if echo "$RA" | grep -Eq "degraded = vec \{[^}]*\"$SEALED_ID\""; then ok "anonymous caller gets the same degraded-not-dead read"; else nok "anonymous read did not degrade cleanly" "$(echo "$RA" | head -c 300)"; fi

echo "── §4 restart → degraded drains ──"
ST=$(adm setTestArchiveStopped "(principal \"$SEALED_ID\", false)")
if echo "$ST" | grep -q "ok"; then ok "sealed segment restarted"; else nok "restart refused" "$ST"; fi
sleep 1
R=$(hist "$Q" | tr -d '_\n' | tr -s ' ')
if echo "$R" | grep -q 'degraded = vec {}'; then ok "degraded empty again"; else nok "degraded did not drain" "$(echo "$R" | head -c 300)"; fi

echo "── §5 the stop hook is scoped to our own segments ──"
ST=$(adm setTestArchiveStopped '(principal "aaaaa-aa", true)')
if echo "$ST" | grep -q "not an archive segment"; then ok "foreign principal refused"; else nok "hook accepted a non-archive principal" "$ST"; fi

adm setTestArchiveCap '(null)' >/dev/null 2>&1
echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_archive_hop_isolation ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_archive_hop_isolation ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
