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
#       PREDECESSOR's head — one unbroken chain across canisters
#   §5  adminUpgradeArchives upgrades the whole chain in place
# Timers stay ON (the shipper is heartbeat-driven); sim killed.
# ⚠️ Calls resetExchange (fresh epoch → seq 0, archives deleted).

set -u
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
arc() { local id="$1"; shift; icp canister call --identity anonymous "$id" "$@" 2>&1; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
WD=$(mkid arch_wd)

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
    icp canister call --identity arch_wd backend withdraw "(\"ICPUSD\", 100_000_000 : nat, \"$tag-$i\")" >/dev/null 2>&1
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

echo "── §2 routing table ──"
ARCS=$(adm getArchives '()' --query | tr -d '_\n' | tr -s ' ')
# Records print fields in candid hash order (lastSeq, firstSeq, canisterId);
# the k-th element of each per-field grep aligns to the k-th archive.
IDS=($(echo "$ARCS" | grep -oE 'canisterId = "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"'))
FIRSTS=($(echo "$ARCS" | grep -oE 'firstSeq = [0-9]+' | grep -oE '[0-9]+'))
LASTS=($(echo "$ARCS" | grep -oE 'lastSeq = (opt \([0-9]+ : nat\)|null)' | sed -E 's/.*opt \(([0-9]+).*/\1/; s/lastSeq = null/open/'))
N=${#IDS[@]}
if [ "$N" -ge 2 ]; then ok "chain grew to $N archives"; else nok "expected ≥2 archives" "$ARCS"; fi
if [ "${FIRSTS[0]}" = "0" ] && [ "${LASTS[0]}" != "open" ]; then
  ok "first archive sealed: seqs 0..${LASTS[0]}"
else nok "first archive range wrong" "$ARCS"; fi
LASTIDX=$((N-1)); PREVIDX=$((N-2))
ACTIVE_ID=${IDS[$LASTIDX]}; ACTIVE_FIRST=${FIRSTS[$LASTIDX]}
PREV_ID=${IDS[$PREVIDX]}; PREV_LAST=${LASTS[$PREVIDX]}
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
PH=$(arc "$PREV_ID" getCertifiedHead '()' --query | tr -d '\n' | tr -s ' ' | grep -oE 'headHash = opt blob "[^"]+"' | sed 's/headHash = opt blob //')
V2=$(arc "$ACTIVE_ID" verifyChain "($ACTIVE_FIRST : nat, 10_000 : nat)" --query | tr -d '_\n' | tr -s ' ')
if echo "$V2" | grep -q "ok = true"; then
  ok "active chain verifies ($(echo "$V2" | grep -oE 'checked = [0-9]+'))"
else nok "active chain broken" "$V2"; fi
EA=$(arc "$ACTIVE_ID" getEventsRange "($ACTIVE_FIRST : nat, 1 : nat)" --query | tr -d '\n' | tr -s ' ')
BOUNDARY=$(echo "$EA" | grep -oE 'prevHash = opt blob "[^"]+"' | sed 's/prevHash = opt blob //')
if [ -n "$BOUNDARY" ] && [ "$BOUNDARY" = "$PH" ]; then
  ok "cross-archive link: active[$ACTIVE_FIRST].prevHash == predecessor head (ONE chain)"
else nok "boundary link broken" "prevHead=$PH boundary=$BOUNDARY"; fi

echo "── §5 whole-chain in-place upgrade ──"
U=$(adm adminUpgradeArchives '()')
if echo "$U" | grep -qE "[0-9]+ archive\(s\) upgraded"; then ok "chain upgraded in place ($(echo "$U" | grep -oE '[0-9]+ archive'))"; else nok "upgrade failed" "$U"; fi
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
if echo "$U2" | tr -d '_' | grep -qE "[1-9][0-9]* skipped"; then
  ok "chain upgrade skips the immutable member ($(echo "$U2" | grep -oE '[0-9]+ skipped'))"
else nok "blackholed archive not skipped" "$U2"; fi
adm setBlackholeAtSeal '(false)' >/dev/null
# NOTE: the blackholed archive can't be deleted by resetExchange — one tiny
# orphan canister per test run on the local replica (harmless, logged).

adm setTestArchiveCap '(null)' >/dev/null
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
