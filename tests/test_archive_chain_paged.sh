#!/bin/bash
# Archive chain: a PAGED audit must verify every link, including the one that
# joins each page to the page before it (docs/issue-triage-2026-08.md §2.11).
#
# The bug: verifyChain rebuilt `prev = null` on every call, so the first event
# of every page had its inbound prevHash checked against nothing — while the
# call still returned ok = true. A paged audit of N events at page size P
# silently skipped ceil(N/P)−1 links, and paging is the usage verifyChain's own
# docstring recommends. A rewritten prevHash sitting on a page boundary passed.
#
# On a healthy chain the fix is invisible through `ok` alone — which is the
# point: "ok = true" cannot distinguish a thorough pass from a vacuous one. So
# verifyChain now reports `linksChecked`, and these assertions pin COVERAGE
# over a bounded window of W events taken from the TAIL of the chain:
#   §2  one call over the window verifies W links (W−1 internal + the seeded
#       inbound one, because the window opens above the anchor)
#   §3  a paged walk over the SAME window sums to the same W — no link lost at
#       a page boundary
#   §4  a single-event page mid-chain verifies its inbound link (1, not 0):
#       the sharpest form of the bug — a page that verified NOTHING said ok
#   §5  a page starting AT the anchor claims 0 links, not 1 — the anchor's own
#       prevHash points before this chain and must not be counted as verified
#
# The window is deliberately small: a mature archive holds millions of events
# and hashing even the 10k per-call cap exceeds the 5B-instruction message
# limit, so "audit the whole tape in one call" is not a thing this test (or an
# operator) can do — which is exactly why paging, and this bug, matter.
#
# Non-destructive: no resetExchange, no process kills (the fleet-kill lesson in
# play_start.sh). The window is SNAPSHOTTED before the walk, so a concurrent
# shipper or simulator appending events cannot flake it.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
arc() { local id="$1"; shift; icp canister call --identity anonymous "$id" "$@" 2>&1; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }

flat() { tr -d '_\n' | tr -s ' '; }
# Numeric field by name. Anchored on a leading space/brace so ` checked` never
# matches the tail of `linksChecked` (and vice versa).
num() { echo "$1" | grep -oE "[ {;]$2 = [0-9]+" | grep -oE "[0-9]+" | head -1; }
# `field = opt (N : nat)` → N, empty when null.
optnum() { echo "$1" | grep -oE "$2 = opt \([0-9]+" | grep -oE "[0-9]+" | head -1; }

WD=$(mkid archpg_wd)
if [ -z "$WD" ]; then echo "cannot create test identity"; exit 1; fi

# Clear any tiny archive cap a previous test may have left behind, so the
# events below land in ONE archive and the walk has a chain to page over.
adm setTestArchiveCap '(null)' >/dev/null 2>&1 || true
adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true   # the shipper must run
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

echo "── §1 put a chain in the active archive ──"
i=0
while [ $i -lt 8 ]; do
  icp canister call --identity archpg_wd backend withdraw "(\"ICPUSD\", 100_000_000 : nat, \"paged-$i\")" >/dev/null 2>&1
  i=$((i+1))
done
if drain; then ok "events shipped (queue drained)"; else nok "queue not drained" "unshipped=${UNSHIPPED:-?}"; fi

ARCS=$(adm getArchives '()' --query | flat)
IDS=($(echo "$ARCS" | grep -oE 'canisterId = "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"'))
N=${#IDS[@]}
if [ "$N" -lt 1 ]; then
  nok "no archive spawned — nothing to audit" "$ARCS"
  echo ""; echo "═══════════════════════════════════════════════════════"
  echo "RESULT: passed=$pass failed=$fail"; exit 1
fi
ACTIVE=${IDS[$((N-1))]}
ok "active archive: $ACTIVE"

# SNAPSHOT the window under audit. Everything below verifies [ANCHOR, LAST]
# only, so events arriving mid-walk cannot change the expected link count.
ST=$(arc "$ACTIVE" stats '()' --query | flat)
ANCHOR=$(optnum "$ST" "chainStartSeq")
NEXT=$(num "$ST" "nextSeq")
if [ -z "${ANCHOR:-}" ] || [ -z "${NEXT:-}" ]; then
  nok "cannot read the archive's chain window" "$ST"
  echo ""; echo "═══════════════════════════════════════════════════════"
  echo "RESULT: passed=$pass failed=$fail"; exit 1
fi
TOTAL=$(( NEXT - ANCHOR ))          # events in the chained range
if [ "$TOTAL" -lt 8 ]; then
  nok "too few chained events to page over" "anchor=$ANCHOR next=$NEXT total=$TOTAL"
  echo ""; echo "═══════════════════════════════════════════════════════"
  echo "RESULT: passed=$pass failed=$fail"; exit 1
fi
# Audit a bounded window near the tail, opening strictly ABOVE the anchor so
# every page — including the first — has a real inbound link to verify, and
# closing strictly BELOW the tape end: a walk that reaches the end now makes
# one extra comparison (the certified-head anchor, W2-01), which would turn
# these fixed counts into a race against any concurrent append. The anchored
# tail case is asserted deterministically on a SEALED archive by
# test_archive_chain.sh instead.
W=12
FROM=$(( NEXT - W - 1 ))
if [ "$FROM" -le "$ANCHOR" ]; then FROM=$(( ANCHOR + 1 )); fi
END=$(( FROM + W ))
if [ "$END" -ge "$NEXT" ]; then END=$(( NEXT - 1 )); W=$(( END - FROM )); fi
WANT_LINKS=$W                       # W−1 internal links + the seeded inbound one
ok "window snapshotted: seqs $FROM..$((END-1)) ($W events, $WANT_LINKS links, anchor=$ANCHOR)"

echo "── §2 one call over the window verifies W links ──"
V=$(arc "$ACTIVE" verifyChain "($FROM : nat, $W : nat)" --query | flat)
FULL_CHECKED=$(num "$V" "checked")
FULL_LINKS=$(num "$V" "linksChecked")
if [ -z "${FULL_LINKS:-}" ]; then
  nok "verifyChain does not report linksChecked" "coverage is unauditable: $V"
elif echo "$V" | grep -q "ok = true" && [ "${FULL_CHECKED:-0}" -eq "$W" ] && [ "$FULL_LINKS" -eq "$WANT_LINKS" ]; then
  ok "window: ok, checked=$FULL_CHECKED, linksChecked=$FULL_LINKS (pre-fix: $((W-1)) — the inbound link went unchecked)"
else
  nok "windowed audit wrong" "want checked=$W linksChecked=$WANT_LINKS, got: $V"
fi

echo "── §3 a paged walk loses no boundary link ──"
PAGE=3
SUM_CHECKED=0; SUM_LINKS=0; PAGES=0; ALL_OK=1
S=$FROM
while [ -n "$S" ] && [ "$S" -lt "$END" ] && [ "$PAGES" -lt 200 ]; do
  LIM=$(( END - S )); [ "$LIM" -gt "$PAGE" ] && LIM=$PAGE   # never read past the window
  P=$(arc "$ACTIVE" verifyChain "($S : nat, $LIM : nat)" --query | flat)
  echo "$P" | grep -q "ok = true" || { ALL_OK=0; nok "page at seq $S reported not-ok" "$P"; break; }
  C=$(num "$P" "checked"); L=$(num "$P" "linksChecked")
  if [ -z "${C:-}" ] || [ -z "${L:-}" ]; then ALL_OK=0; nok "page at seq $S unparseable" "$P"; break; fi
  [ "$C" -eq 0 ] && break
  SUM_CHECKED=$(( SUM_CHECKED + C ))
  SUM_LINKS=$(( SUM_LINKS + L ))
  PAGES=$(( PAGES + 1 ))
  S=$(( S + C ))
done
if [ "$ALL_OK" = "1" ]; then
  ok "walked $W events in $PAGES pages of $PAGE, every page ok"
  if [ "$SUM_CHECKED" -eq "$W" ]; then
    ok "paged walk covered every event in the window ($SUM_CHECKED)"
  else
    nok "paged walk skipped events" "summed checked=$SUM_CHECKED, expected $W"
  fi
  # THE regression. Before the fix each page re-seeded prev=null, so a page of
  # k events verified only k−1 links and the walk summed to W−PAGES — PAGES
  # links short — while every page still said ok = true.
  SKIPPED_BEFORE=$(( W - PAGES ))
  if [ "$SUM_LINKS" -eq "$WANT_LINKS" ]; then
    ok "paged walk verified all $SUM_LINKS links (pre-fix this same walk verified $SKIPPED_BEFORE — $PAGES boundary links skipped silently)"
  else
    nok "boundary links unverified" "summed linksChecked=$SUM_LINKS, expected $WANT_LINKS (pre-fix value: $SKIPPED_BEFORE)"
  fi
  if [ "$SUM_LINKS" -eq "${FULL_LINKS:-0}" ]; then
    ok "paged coverage == single-call coverage ($SUM_LINKS links either way)"
  else
    nok "paging changes how much gets verified" "paged=$SUM_LINKS single=${FULL_LINKS:-?}"
  fi
fi

echo "── §4 a single-event page mid-chain checks its inbound link ──"
MID=$(( FROM + 2 ))
V4=$(arc "$ACTIVE" verifyChain "($MID : nat, 1 : nat)" --query | flat)
C4=$(num "$V4" "checked"); L4=$(num "$V4" "linksChecked")
if echo "$V4" | grep -q "ok = true" && [ "${C4:-0}" = "1" ] && [ "${L4:-0}" = "1" ]; then
  ok "verifyChain($MID, 1): checked=1 linksChecked=1 — the boundary link IS verified"
else
  nok "single-event page verified nothing while reporting ok" "want checked=1 linksChecked=1, got: $V4"
fi

echo "── §5 the anchor's own inbound link is not claimed ──"
V5=$(arc "$ACTIVE" verifyChain "($ANCHOR : nat, 1 : nat)" --query | flat)
C5=$(num "$V5" "checked"); L5=$(num "$V5" "linksChecked")
if echo "$V5" | grep -q "ok = true" && [ "${C5:-0}" = "1" ] && [ "${L5:-9}" = "0" ]; then
  ok "verifyChain($ANCHOR, 1): checked=1 linksChecked=0 — the anchor's prevHash points before this chain"
else
  nok "anchor page miscounts its links" "want checked=1 linksChecked=0, got: $V5"
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
