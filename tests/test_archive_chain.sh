#!/bin/bash
# Archive Phase D (hash chain + certified head) + Phase B (spawn-ahead,
# sealing, routing) — docs/archive-design.md §9.
#
# A tiny test capacity (20 events) makes the chain GROW deterministically.
# #delta ledger events inflate the tape (~3 events per withdrawal), so the
# chain LENGTH is workload-dependent — assertions are structural (ranges
# gapless, chains verify, heads certified), never count-exact. Pinned:
#   §1  events ship; a successor is pre-spawned and archive_0 SEALS
#   §2  getArchives routing table: sealed ranges gapless into the open active
#   §3  the first sealed archive's chain verifies end-to-end + certified head
#   §4  the active archive verifies AND its first event's prevHash equals its
#       PREDECESSOR's head — one unbroken chain across canisters (polled, and
#       NUDGED with 2 withdrawals when the pre-spawned active is still empty —
#       wave 2 can land exactly on the cap; an empty active verifies
#       vacuously, so `checked = 0` there is a failure, never a pass)
#   §5  adminUpgradeArchives upgrades the whole chain in place
#   §6  blackhole-at-seal: the immutable member is a DESIGN skip
#   §7  (#54.7) a hop that fails for any other reason is reported as a
#       FAILURE with its cause in the ring log — never as a design skip
# Timers stay ON (the shipper is heartbeat-driven); sim killed.
# ⚠️ Calls resetExchange (fresh epoch → seq 0, archives deleted).

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
arc() { local id="$1"; shift; icp canister call --identity anonymous "$id" "$@" 2>&1; }
mdx_identity_new arch_wd; WD=$(principal_of arch_wd)

# The sim must be dead (header: it would inject noise into the assertions).
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
adm setTestBalance "(principal \"$WD\", \"ICPUSD\", 1_000_000_000_000 : nat)" >/dev/null

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
    icp canister call --candid "$MDX_CANDID" --identity arch_wd backend withdraw "(\"ICPUSD\", 1_000_000_000 : nat, \"$tag-$i\")" >/dev/null 2>&1
    i=$((i+1))
  done
}

echo "── §1 wave 1 overflows the 20-cap → spawn-ahead + seal ──"
wd 15 chain
if drain; then ok "wave 1 shipped (queue drained)"; else nok "queue not drained" "unshipped=$UNSHIPPED"; fi
# The seal + spawn-ahead land on the shipper's NEXT heartbeat after the queue
# drains — immediately standalone, a beat or two later when a full-suite run
# has left the heartbeat busier. Poll briefly instead of asserting instantly,
# and scan 300 events (suite-context badge/AMM chatter buries an 80 lookback).
EV=""
sealtries=0
while [ $sealtries -lt 12 ]; do
  EV=$(adm getRecentEvents '(300 : nat)' --query 2>/dev/null)
  echo "$EV" | grep -q "successor pre-spawned" && echo "$EV" | grep -q "Archive sealed at seq" && break
  sleep 2; sealtries=$((sealtries+1))
done
if echo "$EV" | grep -q "successor pre-spawned"; then ok "successor pre-spawned at 90% capacity"; else nok "no spawn-ahead event" "$(echo "$EV" | grep -c spawn)"; fi
if echo "$EV" | grep -q "Archive sealed at seq"; then ok "archive_0 sealed at capacity"; else nok "no seal event" "$(echo "$EV" | head -c 200)"; fi
wd 5 chain2
if drain; then ok "wave 2 shipped into the successor"; else nok "wave 2 stuck" "unshipped=$UNSHIPPED"; fi

# The waves are sized in EVENTS (15 + 5 withdrawals, each a semantic event
# plus its #delta), but the epoch-genesis journal resetExchange leaves behind
# ships FIRST — one #delta batch per drain — so the seal boundaries shift with
# the venue's live-ledger width (task 1788536324: the padded traders are
# funded now, ~475 rows instead of ~75). On one shape the wave's LAST event is
# exactly the one that fills the tip: `drain` returns (queue empty) while the
# tip sits AT the 20-cap, the shipper's next heartbeat seals it and promotes
# the pre-spawned successor, and §2-§4 then read a tip that holds NOTHING —
# `checked = 0`, getEventsRange(activeFirst, 1) = vec {}, and §4 reported
# "boundary link broken" (boundary=) against a chain that was intact (26/1 on
# the funded seat venue, 2026-09-04, standalone and under run_all). Settle
# before reading: a tip at/over the cap is about to be sealed — wait for the
# heartbeat; a tip with no event yet gets ONE padding withdrawal (2 events,
# far under the cap); a tip holding 1..19 events is stable, read it. (§4's
# own poll + nudge, 1788536325, is the belt for a hand-off that lands AFTER
# this settle; the two are complementary, not duplicates.)
tip_settle=0; tip_pads=0; TIP_N=0
while [ $tip_settle -lt 15 ]; do
  TIP=$(adm getArchives '()' --query | tr -d '_\n' | tr -s ' ')
  TIP_ID=$(echo "$TIP" | grep -oE 'canisterId = "[a-z0-9-]+"' | tail -1 | grep -oE '"[a-z0-9-]+"' | tr -d '"')
  TIP_FIRST=$(echo "$TIP" | grep -oE 'firstSeq = [0-9]+' | tail -1 | grep -oE '[0-9]+')
  [ -n "$TIP_ID" ] || break
  TIP_N=$(arc "$TIP_ID" getEventsRange "($TIP_FIRST : nat, 200 : nat)" --query | grep -oE '(^|[[:space:]])seq = [0-9_]+' | wc -l | tr -d ' ')
  if [ "${TIP_N:-0}" -ge 20 ]; then sleep 3                       # at capacity: the next heartbeat seals it
  elif [ "${TIP_N:-0}" -eq 0 ]; then wd 1 tippad$tip_pads; drain; sleep 2; tip_pads=$((tip_pads+1))
  else break; fi
  tip_settle=$((tip_settle+1))
done
[ $tip_settle -gt 0 ] && echo "  (tip settled after $tip_settle round(s), $tip_pads padding withdrawal(s): $TIP_ID from seq $TIP_FIRST holds $TIP_N event(s) — §2-§4 read a stable tip, not a seal in flight)"

echo "── §2 routing table ──"
# Read getArchives into the per-archive arrays and name the tail: the open
# ACTIVE and its PREDECESSOR. A function because §4 re-reads it after nudging
# an empty active (the chain may have grown since §2 took its snapshot).
read_routing() {
  ARCS=$(adm getArchives '()' --query | tr -d '_\n' | tr -s ' ')
  # Records print fields in candid hash order (lastSeq, firstSeq, canisterId);
  # the k-th element of each per-field grep aligns to the k-th archive.
  IDS=($(echo "$ARCS" | grep -oE 'canisterId = "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"'))
  FIRSTS=($(echo "$ARCS" | grep -oE 'firstSeq = [0-9]+' | grep -oE '[0-9]+'))
  LASTS=($(echo "$ARCS" | grep -oE 'lastSeq = (opt \([0-9]+ : nat\)|null)' | sed -E 's/.*opt \(([0-9]+).*/\1/; s/lastSeq = null/open/'))
  N=${#IDS[@]}
  LASTIDX=$((N-1)); PREVIDX=$((N-2))
  ACTIVE_ID=${IDS[$LASTIDX]}; ACTIVE_FIRST=${FIRSTS[$LASTIDX]}
  PREV_ID=${IDS[$PREVIDX]}; PREV_LAST=${LASTS[$PREVIDX]}
}
read_routing
if [ "$N" -ge 2 ]; then ok "chain grew to $N archives"; else nok "expected ≥2 archives" "$ARCS"; fi
if [ "${FIRSTS[0]}" = "0" ] && [ "${LASTS[0]}" != "open" ]; then
  ok "first archive sealed: seqs 0..${LASTS[0]}"
else nok "first archive range wrong" "$ARCS"; fi
if [ "${LASTS[$LASTIDX]}" = "open" ]; then
  ok "last archive is the open-ended active (from seq $ACTIVE_FIRST)"
else nok "no open active archive" "$ARCS"; fi
if [ "$ACTIVE_FIRST" = "$((PREV_LAST + 1))" ]; then
  ok "ranges are gapless (…${PREV_LAST}][${ACTIVE_FIRST}…)"
else nok "range gap at the active boundary" "prevLast=$PREV_LAST activeFirst=$ACTIVE_FIRST"; fi

echo "── §3 sealed archive: chain verifies + certified head ──"
SEALED_ID=${IDS[0]}; SEALED_LAST=${LASTS[0]}
WANT=$((SEALED_LAST + 1))
V1=$(arc "$SEALED_ID" verifyChain '(0 : nat, 10_000 : nat)' --query | tr -d '_\n' | tr -s ' ')
if echo "$V1" | grep -q "ok = true" && echo "$V1" | grep -q "checked = $WANT"; then
  ok "sealed chain verifies ($WANT/$WANT links)"
else nok "sealed chain broken" "$V1"; fi
H1=$(arc "$SEALED_ID" getCertifiedHead '()' --query | tr -d '_\n' | tr -s ' ')
if echo "$H1" | grep -q "headSeq = opt ($SEALED_LAST"; then ok "certified head covers seq $SEALED_LAST"; else nok "head seq wrong" "$(echo "$H1" | head -c 150)"; fi
if echo "$H1" | grep -qE 'certificate = opt blob'; then ok "IC certificate present (query-call certified data)"; else nok "no certificate" "$(echo "$H1" | head -c 150)"; fi

# ── W2-01: the recomputed tail is anchored to the certified head ──
# (Sealed segment = deterministic forever: no append can move its head.)
# Full range: WANT−1 internal links + the head anchor = WANT — linksChecked
# equals checked exactly when the head is derivable from the tape. Pre-fix
# this was WANT−1, and ok=true never involved the certified head at all.
if echo "$V1" | grep -q "linksChecked = $WANT"; then
  ok "full sealed range is head-anchored (linksChecked = checked = $WANT)"
else nok "tail anchor did not fire on the full range" "$V1"; fi
# The reporter's reproduction: a single-event page at the tape end. Pre-fix
# it performed ZERO hash comparisons and returned ok=true; now it verifies
# its inbound link AND the head anchor.
VT=$(arc "$SEALED_ID" verifyChain "($SEALED_LAST : nat, 1 : nat)" --query | tr -d '_\n' | tr -s ' ')
if echo "$VT" | grep -q "ok = true" && echo "$VT" | grep -q "checked = 1" && echo "$VT" | grep -q "linksChecked = 2"; then
  ok "verifyChain(headSeq, 1) = 2 comparisons (inbound + anchor) — no longer a vacuous ok"
else nok "tail page not anchored" "$VT"; fi
# An interior range that stops short of the end still passes and makes no
# head claim: links = checked (inbound seeded), nextSeq points onward.
if [ "$SEALED_LAST" -ge 4 ]; then
  VP=$(arc "$SEALED_ID" verifyChain "(1 : nat, 3 : nat)" --query | tr -d '_\n' | tr -s ' ')
  if echo "$VP" | grep -q "ok = true" && echo "$VP" | grep -q "linksChecked = 3" && echo "$VP" | grep -q "nextSeq = opt"; then
    ok "interior range: ok with no head claim (links = 3, nextSeq set)"
  else nok "interior range wrong" "$VP"; fi
fi

echo "── §4 active archive: verifies + links to its predecessor's head ──"
# verifyChain on an EMPTY active returns ok=true VACUOUSLY (checked = 0) and
# getEventsRange yields no event — the boundary assertion below then compares
# a null prevHash against the sealed predecessor's real head and reds
# "boundary link broken" on a HEALTHY chain. Two ways the active is empty here:
#   (a) the hand-off race: §1's `drain` watches the backend's journalUnshipped,
#       which empties when wave 2 leaves the backend — not when the successor
#       has acked it; the first ship lands a heartbeat later. A poll cures it.
#   (b) the CAP-BOUNDARY steady state (reproduced on a fresh #dev venue,
#       2026-09-04): wave 2 landed EXACTLY on the 20-cap — 0..278 sealed,
#       279..298 (20 = cap) sealed, active from 299 holding NOTHING — and it
#       stays empty until more events arrive; the chain length is
#       workload-dependent (header), so no poll length cures this one.
# So: poll until the active holds ≥1 event (the §1 seal poll's 12×2s shape);
# still empty → NUDGE it with 2 withdrawals (~6 events, far below the cap, so
# the active cannot seal again), drain, re-read the routing table (the tail
# may have moved), re-poll. An active STILL empty after that is a FAILURE,
# never a vacuous pass — the lesson test_archive_chain_paged §4 pins for
# pages: "ok = true" cannot distinguish a thorough pass from one that verified
# nothing. The backend is NOT the fix target: spawn-ahead + first-ship-on-the-
# next-heartbeat is legitimately asynchronous, and an empty pre-spawned
# successor is by design; the test must feed and wait, not assume.
ACTIVE_POLLS=12
V2=""; V2_CHECKED=0; ACTTRIES=0
poll_active() {  # sets V2 / V2_CHECKED; 0 iff the active holds ≥1 chained event
  local tries=0
  while [ "$tries" -lt "$ACTIVE_POLLS" ]; do
    V2=$(arc "$ACTIVE_ID" verifyChain "($ACTIVE_FIRST : nat, 10_000 : nat)" --query | tr -d '_\n' | tr -s ' ')
    # Anchored on a leading space/brace/semicolon so ` checked` never reads
    # the tail of `linksChecked` (the paged sibling's `num` shape).
    V2_CHECKED=$(echo "$V2" | grep -oE '[ {;]checked = [0-9]+' | grep -oE '[0-9]+' | head -1)
    ACTTRIES=$((ACTTRIES+1))
    [ "${V2_CHECKED:-0}" -ge 1 ] && return 0
    sleep 2; tries=$((tries+1))
  done
  return 1
}
NUDGE=""
if ! poll_active; then
  echo "  active $ACTIVE_ID empty after ${ACTIVE_POLLS}×2s — nudging 2 withdrawals so it holds something to link"
  wd 2 nudge
  drain || true
  read_routing
  poll_active || true
  NUDGE=", after a 2-withdrawal nudge"
fi
PH=$(arc "$PREV_ID" getCertifiedHead '()' --query | tr -d '\n' | tr -s ' ' | grep -oE 'headHash = opt blob "[^"]+"' | sed 's/headHash = opt blob //')
if [ "${V2_CHECKED:-0}" -lt 1 ]; then
  nok "active archive is EMPTY — nothing to link" "checked = ${V2_CHECKED:-0} after ${ACTTRIES} poll(s)${NUDGE} (a vacuous ok=true is NOT a pass): $(echo "$V2" | head -c 200)"
elif echo "$V2" | grep -q "ok = true"; then
  ok "active chain verifies (checked = ${V2_CHECKED}, non-empty after ${ACTTRIES} poll(s)${NUDGE})"
else nok "active chain broken" "$V2"; fi
EA=$(arc "$ACTIVE_ID" getEventsRange "($ACTIVE_FIRST : nat, 1 : nat)" --query | tr -d '\n' | tr -s ' ')
BOUNDARY=$(echo "$EA" | grep -oE 'prevHash = opt blob "[^"]+"' | sed 's/prevHash = opt blob //')
if [ -n "$BOUNDARY" ] && [ "$BOUNDARY" = "$PH" ]; then
  ok "cross-archive link: active[$ACTIVE_FIRST].prevHash == predecessor head (ONE chain)"
else nok "boundary link broken" "prevHead=${PH//\\/} boundary=${BOUNDARY//\\/} (blob escapes stripped: nok's echo -e would swallow the line at a backslash-c byte)"; fi

echo "── §5 whole-chain in-place upgrade ──"
U=$(adm adminUpgradeArchives '()')
# #54.7: the reply carries THREE counts — upgraded, skipped (blackholed, from
# the seal-time record), failed (anything else, cause in the log). A clean
# chain is a clean sweep; the old single-cause label had no failed count.
if echo "$U" | grep -qE "[1-9][0-9]* archive\(s\) upgraded, 0 skipped \(blackholed\), 0 failed \(see log\)"; then ok "chain upgraded in place, clean sweep ($(echo "$U" | grep -oE '[0-9]+ archive\(s\) upgraded'))"; else nok "upgrade reply is not a clean sweep (old single-cause label, or a failed hop)" "$U"; fi
V3=$(arc "$SEALED_ID" verifyChain '(0 : nat, 10_000 : nat)' --query | tr -d '_\n' | tr -s ' ')
if echo "$V3" | grep -q "ok = true" && echo "$V3" | grep -q "checked = $WANT"; then
  ok "sealed chain still verifies after the upgrade (Region + head preserved)"
else nok "upgrade lost chain state" "$V3"; fi

echo "── §6 blackhole-at-seal (opt-in policy) ──"
adm setBlackholeAtSeal '(true)' >/dev/null
wd 15 chain3   # force another seal under the policy
if drain; then ok "wave 3 shipped (forced a policy-covered seal)"; else nok "wave 3 stuck" "unshipped=$UNSHIPPED"; fi
# The blackhole (an async ic00.update_settings) lands on the ship tick that
# seals — which may be a beat or two AFTER the queue drains. Poll for it rather
# than checking once (the single-shot check raced the seal and flaked).
BH=0
for _ in $(seq 1 12); do
  if adm getRecentEvents '(80 : nat)' --query 2>/dev/null | grep -q "BLACKHOLED (controllers"; then BH=1; break; fi
  sleep 3
done
if [ "$BH" = "1" ]; then ok "sealed archive blackholed — controllers emptied"; else nok "no blackhole event" "not seen within 36s"; fi
U2=$(adm adminUpgradeArchives '()')
if echo "$U2" | tr -d '_' | grep -qE "[1-9][0-9]* skipped \(blackholed\)"; then
  ok "chain upgrade skips the immutable member ($(echo "$U2" | grep -oE '[0-9]+ skipped'))"
else nok "blackholed archive not skipped" "$U2"; fi
# How MANY segments wave 3 seals under the policy is workload-dependent, like
# every count in this suite (header): a segment seals at ~47-52 events, so
# 15 withdrawals straddle one seal on a fresh seed and sometimes TWO when the
# tip's alignment differs — a second run on the same venue re-baselines the
# tape with one shed row per live wallet (resetExchange keeps wallets), which
# moves the cap boundaries (seen: `2 skipped`, task 1788539282). Every later
# reading is compared to THIS one, never to a literal. (A previous run's
# blackholed orphan is NOT in the walk: resetExchange clears every routing
# list and the seal-time record before it deletes what it can — the orphan
# only shows as "Could not delete archive" in the ring log.)
BH_N=$(echo "$U2" | tr -d '_' | grep -oE '[0-9]+ skipped \(blackholed\)' | grep -oE '^[0-9]+')
BH_N=${BH_N:-NaN}   # an unparseable reply must never compare equal to anything below
# The skip is classified from the seal-time record, so it is NOT a failure —
# and the reply must say so explicitly (old label: no failed count at all).
if echo "$U2" | grep -q ", 0 failed"; then ok "the immutable member is a design skip, not a failure (#54.7)"; else nok "blackholed segment reported as a failure, or old single-cause label" "$U2"; fi
adm setBlackholeAtSeal '(false)' >/dev/null

echo "── §7 a hop that fails for a NON-blackhole reason is a FAILURE (#54.7) ──"
# The pre-#54.7 catch dropped Error.message(e) and labelled every failed hop
# "skipped (blackholed)" — with the policy OFF on dev/play every non-zero skip
# was a misreport, and the subnet runbook proceeded on that string. Force a
# real failure: hand the FIRST sealed segment (sealed before §6 switched the
# policy on, so still ours) to the test identity — the backend is no longer a
# controller and the IC refuses its install_code. Same refusal class as a
# blackhole, but WITHOUT the seal-time record: that is exactly the hop the
# reply must count as failed, with the cause in the ring log.
BACKEND_ID=$(icp canister status backend --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
ANON="2vxsx-fae"
ARCS2=$(adm getArchives '()' --query | tr -d '_\n' | tr -s ' ')
VICTIM=$(echo "$ARCS2" | grep -oE 'canisterId = "[a-z0-9-]+"' | head -1 | grep -oE '"[a-z0-9-]+"' | tr -d '"')
H=$(adm setTestArchiveControllers "(principal \"$VICTIM\", vec { principal \"$ANON\" })")
if mdx_ok "$H"; then ok "handed $VICTIM to the test identity (backend no longer a controller)"; else nok "controller hand-off refused" "$H"; fi
U3=$(adm adminUpgradeArchives '()')
# Exactly ONE segment was handed away, so exactly one hop fails — the count
# is exact by construction (the #54.7 pin); the blackholed count is §6's.
if echo "$U3" | grep -q ", 1 failed"; then ok "the uncontrolled hop is counted as FAILED (1 failed)"; else nok "failed hop not reported as exactly 1 failure" "$U3"; fi
# 1793569495: the reply itself names the hop and the IC's cause (no more "see log").
if echo "$U3" | tr -d '\n' | tr -s ' ' | grep -q "1 failed — $VICTIM: "; then ok "the reply names the failed segment with its cause (1 failed — $VICTIM: …)"; else nok "reply does not name the failed segment" "$U3"; fi
if echo "$U3" | grep -qE "(^|[^0-9])$BH_N skipped \\(blackholed\\)"; then ok "…while the blackholed member(s) still read as the design skip ($BH_N skipped, §6's reading)"; else nok "blackholed count drifted from §6's reading ($BH_N skipped)" "$U3"; fi
LOGL=$(adm getRecentEvents '(150 : nat)' --query 2>/dev/null | tr -d '\n' | grep -oE "ARCHIVE UPGRADE: $VICTIM failed: [^\"]{8,}" | head -1)
if [ -n "$LOGL" ]; then ok "the ring log names the segment AND the IC's cause ($(echo "$LOGL" | head -c 100)…)"; else nok "no 'ARCHIVE UPGRADE: <cid> failed: <cause>' warn line" "$(adm getRecentEvents '(40 : nat)' --query | grep -oE 'ARCHIVE UPGRADE[^;]*' | head -3)"; fi
# Restore: the test identity is the segment's controller now, so it hands us
# back (leaving it stranded would orphan it like §6's blackholed member).
RS=$(icp canister settings update "$VICTIM" --add-controller "$BACKEND_ID" --force --identity anonymous 2>&1)
U4=$(adm adminUpgradeArchives '()')
if echo "$U4" | grep -qE "(^|[^0-9])$BH_N skipped \\(blackholed\\), 0 failed \\(see log\\)"; then ok "control restored — the hop upgrades again (0 failed, $BH_N still skipped)"; else nok "restore did not take" "settings: $(echo "$RS" | tail -1) / upgrade: $U4"; fi
# NOTE: the blackholed archive can't be deleted by resetExchange — one tiny
# orphan canister per test run on the local replica (harmless: the next
# wipe logs "Could not delete archive <cid> — delete it by hand" and drops
# it from every routing list, so no later run walks it).

adm setTestArchiveCap '(null)' >/dev/null
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
