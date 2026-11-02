#!/bin/bash
# History backfill over a sealed archive chain: FILLS-ONLY paging (task
# 1793489930). The history views (Spot History · Positions History · Account →
# Spot) restore a user's archived fills by walking the chain newest-first. The
# unfiltered pager (getMyArchivedEvents → getEventsForPrincipals) counts EVERY
# kind, so a segment holding only the user's #delta / withdrawal / config rows
# cost ceil(total/200) hops to learn it held no fills, one serial round trip
# per segment — minutes on a venue whose bot churn sealed dozens of segments
# above the user's last trade. The kind-filtered twin (getMyArchivedEventsFiltered
# → getEventsForPrincipalsFiltered, fills off a per-principal fill index, no
# re-sort) answers total = 0 in one hop, and the browser probes segments in
# parallel waves of 6.
#
#   §1 fixture: a virgin user's FILL lands in the active segment (F); a tiny
#      cap (10) and a withdrawal churn from the SAME user then seal ≥ 10
#      segments above it — every newer segment holds the user's NON-fill rows
#      (withdrawal + #delta), none a fill: the production shape.
#   §2 the filtered pager: every segment above F answers total = 0 (no fills)
#      with filtered = true; F answers its fills, and that total equals the
#      #fill rows the unfiltered pager returns for F; kinds = [] reproduces
#      the unfiltered total (the sort-free merge is equivalent); a withdrawal
#      filter counts exactly the withdrawal rows; offset paging is consistent
#      (offset 1 = the second row of offset 0); an unknown segment answers 0.
#   §3 the compatibility leg: a segment running PRE-filter code (spawned
#      before this backend was deployed, not yet upgraded) rejects the new
#      method — the federation falls back to the unfiltered pager and SAYS SO
#      (filtered = false, all-kinds total). Asserted when such a segment
#      exists (the first run after a deploy); then adminUpgradeArchives moves
#      the chain onto the new code, every segment answers filtered = true, and
#      each one's fill AND deposit/withdrawal index backfill themselves (one
#      postupgrade timer over both cursors — stats.fillIndexCursor and
#      stats.dwIndexCursor reach eventCount; task 1793495003 folded the D/W
#      cursor in: before it a SEALED segment's dwIndex was never caught up by
#      anything) with F's filtered total unchanged (index path = gather path);
#      the explicit driver adminBackfillArchiveDw (report mode, maxRounds = 0)
#      walks the WHOLE chain and names every segment complete (it used to loop
#      the active tip only).
#   §4 the measurement the task asks for: round trips / wall time to the first
#      fill row — the serial unfiltered walk vs waves of 6 filtered probes
#      (scripted with icp calls; logged for the completion note).
#   §5 a MISSING segment (task 1793569495 — the engine's first sealed segment
#      srh6u… vanished on 2026-11-01 while getArchives still routed to it):
#      the dev hook setTestArchiveDeleted stops + DELETES one churn segment
#      for real, row kept. Then: both federation pagers answer
#      `unavailable = opt "segment missing (canister not found) — …"` with
#      total 0 instead of rejecting (the other segments still serve);
#      adminRunArchiveFuelPass logs "does NOT EXIST … not funding";
#      adminUpgradeArchives' reply NAMES the hop with the IC's reject text
#      and the drop door (no more "see log"); adminDropMissingArchive refused
#      the row while the canister EXISTED, refuses a non-row, the active tip
#      and a non-controller, then drops the dead row: getArchives loses it,
#      getLedgerGaps gains [firstSeq, lastSeq+1), the tape carries #config
#      { setter = adminDropMissingArchive } + #gap { fromSeq; toSeq } and a
#      balance re-baseline (getShedBaselines +1), a second drop is refused,
#      and the next upgrade pass reports 0 failed.
# Needs #dev (setTestArchiveCap / setTestBalance / setAmmRefPrice /
# setTestArchiveDeleted). Leaves the tiny cap behind → restored (null) at
# exit. No resetExchange; the churn adds ~55 withdrawals of the throwaway
# identity, and §5 deletes ONE churn segment holding only that identity's
# rows — the venue keeps a declared #gap + re-baseline on its tape afterwards,
# exactly what the operator's engine drop leaves behind.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
u()   { icp canister call --candid "$MDX_CANDID" --identity afp_u backend "$@" 2>&1; }
arc() { local id="$1"; shift; icp canister call --identity anonymous "$id" "$@" 2>&1; }
flat() { tr -d '_\n' | tr -s ' '; }
# Numeric field by name, anchored on a leading space/brace.
num() { echo "$1" | grep -oE "[ {;]$2 = [0-9]+" | grep -oE "[0-9]+" | head -1; }
optnum() { echo "$1" | grep -oE "$2 = opt \([0-9]+" | grep -oE "[0-9]+" | head -1; }
# The two pagers, flattened. fq <segment> <kinds candid vec> <offset> <limit>; lq <segment> <offset> <limit>.
fq() { u getMyArchivedEventsFiltered "(principal \"$1\", $2, $3 : nat, $4 : nat)" --query | flat; }
lq() { u getMyArchivedEvents "(principal \"$1\", $2 : nat, $3 : nat)" --query | flat; }
fills_in() { echo "$1" | grep -o 'variant { fill = record' | wc -l | tr -d ' '; }
# Fills a filtered reply stands for: its total when the segment honoured the
# filter, else (filtered = false — a pre-filter segment answered all kinds)
# the #fill rows on the page, exactly the browser's client-side test.
fills_total() { if echo "$1" | grep -q 'filtered = true'; then num "$1" total; else fills_in "$1"; fi; }
seqs() { echo "$1" | grep -oE 'seq = [0-9]+' | grep -oE '[0-9]+' | tr '\n' ' '; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
dur() { awk -v a="$1" -v b="$2" 'BEGIN{ printf "%.1f", b - a }'; }

[ "$(venue_posture)" = "dev" ] || skip_posture "test_archive_fills_paged" "dev hooks (setTestArchiveCap / setTestBalance / setAmmRefPrice)"

# The sim must be dead (its fills would land in the churn segments). PID-file
# stopper only — never a pattern kill (scripts/lib/bots.sh).
STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 1; }
adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true   # the shipper must run
on_exit "adm setTestArchiveCap '(null)' >/dev/null 2>&1"

mdx_identity_new afp_u; U=$(principal_of afp_u)
[ -n "$U" ] || { echo "cannot create the test identity"; exit 1; }

drain() {  # wait for the transit queue to empty (ship tick = 10s)
  local tries=0
  while [ $tries -lt 20 ]; do
    UNSHIPPED=$(adm getCanisterInfo '()' --query | tr -d '_' | grep -oE "journalUnshipped = [0-9]+" | grep -oE "[0-9]+")
    [ "${UNSHIPPED:-1}" = "0" ] && return 0
    sleep 3; tries=$((tries+1))
  done
  return 1
}
segments() {  # getArchives canister ids, oldest → newest (the last is the active tip)
  adm getArchives '()' --query | flat | grep -oE 'canisterId = "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"'
}

echo "── §1 fixture: one fill, then ≥10 fill-less segments sealed above it ──"
adm setTestArchiveCap '(null)' >/dev/null 2>&1   # the fill ships into the CURRENT active segment, uncapped
MKT="ICP-ICPUSD"
if ! adm getAmmPool "(\"$MKT\")" --query 2>/dev/null | grep -q 'refPrice'; then MKT="BTC-ICPUSD"; fi
adm setTestBalance "(principal \"$U\", \"ICPUSD\", $(e8 20000) : nat)" >/dev/null
ASSET="${MKT%%-*}"
PIN=$(mdx_restamp_mark "$ASSET" "$MKT" "$(e8 10)") || true
MARK=$(echo "$PIN" | awk '{print $1}')
# ~15 ICPUSD of base at the mark — above the 10 ICPUSD order-value minimum.
QTY=$(awk -v m="${MARK:-1000000000}" 'BEGIN{ printf "%.0f", 15e16 / m }')
R=$(u placeMarketOrder "(\"$MKT\", variant { buy }, $QTY : nat, $(e8 0.05) : nat, false)")
if mdx_ok "$R"; then ok "market buy staged on $MKT (mark ${MARK:-?}, ${PIN##* })"; else nok "market buy refused" "$(echo "$R" | head -c 200)"; fi
# Sealed model: the order fills on a release pass once a mark POSTDATES it —
# re-stamp (freshness, no move) + requote drive the pass (test_fok_market's
# freshrequote shape); the live heartbeat releases too.
tries=0; FILLED=0
while [ $tries -lt 30 ]; do
  [ -n "$MARK" ] && adm setAmmRefPrice "(\"$MKT\", $MARK : nat)" >/dev/null 2>&1
  adm requoteAmm "(\"$MKT\")" >/dev/null 2>&1
  H=$(u getMyTradeHistory '()' --query | flat)
  if echo "$H" | grep -q 'id = '; then FILLED=1; break; fi
  sleep 2; tries=$((tries+1))
done
if [ "$FILLED" = "1" ]; then ok "the buy filled (getMyTradeHistory shows a trade)"; else nok "no fill after $tries release nudges" "$(echo "$H" | head -c 200)"; fi
if drain; then ok "the fill shipped (queue drained)"; else nok "queue not drained" "unshipped=${UNSHIPPED:-?}"; fi
SEGS0=($(segments))
F=${SEGS0[$(( ${#SEGS0[@]} - 1 ))]}
[ -n "${F:-}" ] && ok "fill segment F = $F (the active tip at ship time; ${#SEGS0[@]} segment(s) in the chain)" || { nok "no archive in the chain" "$(adm getArchives '()' --query | head -c 200)"; echo "RESULT: passed=$pass failed=$fail"; exit 1; }
FQ0=$(fq "$F" 'vec {"fill"}' 0 200)
F_FILLS=$(fills_total "$FQ0")
[ "${F_FILLS:-0}" -ge 1 ] && ok "F answers the user's fills ($F_FILLS; $(echo "$FQ0" | grep -oE 'filtered = (true|false)'))" || nok "F answers no fills for the user" "$(echo "$FQ0" | head -c 200)"

# The churn: cap 10, then rounds of 5 withdrawals of 10 ICPUSD (2 rows each:
# the withdrawal + its #delta = one 10-cap segment, since a whole ship batch
# lands before the cap check) from the SAME user, each round waited to its
# seal — one seal per ship tick. Three fixture physics the first drafts
# tripped on: (a) a DUST exit (under EXIT_DUST_USD) is FOLDED into a 30 s
# per-user exit window (flushExitWindow — one summed row per window, not one
# per call), so 1-ICPUSD withdrawals churned almost nothing; (b) the journal
# drains per heartbeat, so a round waits on ledgerJournalPending AND
# journalUnshipped, not the ship queue alone; (c) a round's rows must reach
# the cap on their own or two rounds merge into one segment.
adm setTestArchiveCap '(opt (10 : nat))' >/dev/null
above_f() {  # segments newer than F in the routing table
  local segs; segs=($(segments)); local n=0 seen=0 s
  for s in "${segs[@]}"; do if [ "$seen" = "1" ]; then n=$((n+1)); fi; [ "$s" = "$F" ] && seen=1; done
  echo "$n"
}
W_OK=0; W_ERR=0; W_FIRST_ERR=""
round=0; ABOVE=$(above_f)
while [ "${ABOVE:-0}" -lt 11 ] && [ $round -lt 14 ]; do
  i=0; while [ $i -lt 5 ]; do
    R=$(u withdraw "(\"ICPUSD\", 1_000_000_000 : nat, \"afp-$round-$i\")")
    if mdx_ok "$R"; then W_OK=$((W_OK+1)); else W_ERR=$((W_ERR+1)); [ -z "$W_FIRST_ERR" ] && W_FIRST_ERR=$(echo "$R" | tr -d '\n' | head -c 160); fi
    i=$((i+1))
  done
  want=$(( ABOVE + 1 )); tries=0
  while [ $tries -lt 25 ]; do   # journal drain + ship tick 10 s + seal/roll on the next
    INFO=$(adm getCanisterInfo '()' --query | tr -d '_')
    JP=$(echo "$INFO" | grep -oE "ledgerJournalPending = [0-9]+" | grep -oE "[0-9]+")
    UNSH=$(echo "$INFO" | grep -oE "journalUnshipped = [0-9]+" | grep -oE "[0-9]+")
    ABOVE=$(above_f)
    [ "${ABOVE:-0}" -ge "$want" ] && [ "${JP:-1}" = "0" ] && [ "${UNSH:-1}" = "0" ] && break
    sleep 3; tries=$((tries+1))
  done
  round=$((round+1))
done
drain >/dev/null
echo "  (churn: $round round(s), $W_OK withdrawals ok, $W_ERR refused${W_FIRST_ERR:+ — first: $W_FIRST_ERR})"
if [ "${ABOVE:-0}" -ge 11 ]; then ok "$ABOVE segments above F ($(( ABOVE - 1 )) sealed + the active tip), queue drained"; else nok "chain did not grow ≥11 segments above F" "above=$ABOVE rounds=$round"; fi
adm setTestArchiveCap '(null)' >/dev/null 2>&1   # churn done — the venue's cap back to its default

echo "── §2 the filtered pager ──"
SEGS=($(segments)); N=${#SEGS[@]}
# F's index in the oldest→newest list; everything after it is a churn segment.
FI=-1; for ((k=0; k<N; k++)); do [ "${SEGS[$k]}" = "$F" ] && FI=$k; done
ZERO=0; NONZERO=0; UNFILTERED=0; CHURN=""
for ((k=FI+1; k<N; k++)); do
  R=$(fq "${SEGS[$k]}" 'vec {"fill"}' 0 200)
  T=$(num "$R" total)
  echo "$R" | grep -q 'filtered = false' && UNFILTERED=$((UNFILTERED+1))
  if [ "${T:-x}" = "0" ]; then ZERO=$((ZERO+1)); else NONZERO=$((NONZERO+1)); fi
  [ -z "$CHURN" ] && echo "$R" | grep -q 'filtered = true' && CHURN="${SEGS[$k]}"
done
[ "$NONZERO" = "0" ] && [ "$ZERO" -ge 11 ] && ok "every segment above F answers total = 0 in one hop ($ZERO segments, no fills to page)" || nok "a segment above F claims fills for the user" "zero=$ZERO nonzero=$NONZERO"
[ "$UNFILTERED" = "0" ] && ok "the churn segments (spawned by this backend) honour the kinds filter (filtered = true)" || nok "a churn segment answered filtered = false" "$UNFILTERED of $ZERO"
LQF=$(lq "$F" 0 200)
LF_TOTAL=$(num "$LQF" total); LF_FILLS=$(fills_in "$LQF")
F_FILLS=$(fills_total "$(fq "$F" 'vec {"fill"}' 0 200)")
[ "${F_FILLS:-0}" = "${LF_FILLS:-x}" ] && ok "F: filtered total ($F_FILLS) = the #fill rows the unfiltered pager returns ($LF_FILLS of $LF_TOTAL rows)" || nok "F: filtered total disagrees with the unfiltered page's fill count" "filtered=$F_FILLS unfiltered-fills=$LF_FILLS total=$LF_TOTAL"
FQ_ALL=$(fq "$F" 'vec {}' 0 200)
[ "$(num "$FQ_ALL" total)" = "${LF_TOTAL:-x}" ] && ok "F: kinds = [] reproduces the unfiltered total ($LF_TOTAL) — the sort-free merge is equivalent" || nok "F: kinds = [] total differs from the unfiltered pager" "filtered-all=$(num "$FQ_ALL" total) unfiltered=$LF_TOTAL"
# Same order too: the first seqs of both pages agree (newest-first).
S_ALL=$(echo "$FQ_ALL" | grep -oE 'seq = [0-9]+' | head -3 | tr '\n' ' '); S_LEG=$(echo "$LQF" | grep -oE 'seq = [0-9]+' | head -3 | tr '\n' ' ')
[ "$S_ALL" = "$S_LEG" ] && ok "F: kinds = [] pages in the same newest-first order ($S_ALL)" || nok "F: kinds = [] order differs" "all=[$S_ALL] legacy=[$S_LEG]"
if [ -n "$CHURN" ]; then
  LQC=$(lq "$CHURN" 0 200)
  W_LEG=$(echo "$LQC" | grep -o 'variant { withdrawal }' | wc -l | tr -d ' ')
  FQW=$(fq "$CHURN" 'vec {"withdrawal"}' 0 200)
  [ "$(num "$FQW" total)" = "$W_LEG" ] && [ "$W_LEG" -ge 1 ] && ok "churn segment $CHURN: kinds = [\"withdrawal\"] counts exactly its withdrawal rows ($W_LEG of $(num "$LQC" total))" || nok "withdrawal filter miscounts" "filtered=$(num "$FQW" total) legacy=$W_LEG"
  P0=$(seqs "$(fq "$CHURN" 'vec {"delta"}' 0 2)")
  P1=$(seqs "$(fq "$CHURN" 'vec {"delta"}' 1 1)")
  SECOND=$(echo "$P0" | awk '{print $2}')
  if [ -n "$SECOND" ]; then
    [ "$(echo "$P1" | awk '{print $1}')" = "$SECOND" ] && ok "offset paging is consistent in the filtered sequence (offset 1 = row 2 of offset 0: seq $SECOND)" || nok "filtered offset paging inconsistent" "page0=[$P0] page1=[$P1]"
  else
    nok "churn segment has fewer than 2 delta rows to page over" "page0=[$P0]"
  fi
else
  nok "no churn segment to probe the kind filters on" "chain=$N F=$FI"
fi
UNK=$(fq "aaaaa-aa" 'vec {"fill"}' 0 200)
[ "$(num "$UNK" total)" = "0" ] && ok "an unknown segment id answers total = 0 (refused, not trapped)" || nok "unknown segment not refused" "$(echo "$UNK" | head -c 160)"

echo "── §3 compatibility: pre-filter segments fall back, adminUpgradeArchives heals ──"
PRE=0; PRE_OK=0
for ((k=0; k<N; k++)); do
  R=$(fq "${SEGS[$k]}" 'vec {"fill"}' 0 200)
  if echo "$R" | grep -q 'filtered = false'; then
    PRE=$((PRE+1))
    L=$(lq "${SEGS[$k]}" 0 200)
    [ "$(num "$R" total)" = "$(num "$L" total)" ] && PRE_OK=$((PRE_OK+1))
  fi
done
if [ "$PRE" -gt 0 ]; then
  [ "$PRE_OK" = "$PRE" ] && ok "legacy fallback exercised on $PRE pre-filter segment(s): filtered = false with the all-kinds total (the browser filters client-side)" || nok "a pre-filter segment's fallback total disagrees with the unfiltered pager" "$PRE_OK of $PRE agree"
else
  echo "  (no pre-filter segment on this venue — the fallback leg runs on the first pass after a backend deploy; skipped)"
fi
R=$(adm adminUpgradeArchives '()')
if mdx_ok "$R"; then ok "adminUpgradeArchives: $(echo "$R" | grep -oE '[0-9]+ archive\(s\) upgraded[^"]*' | head -1)"; else nok "adminUpgradeArchives refused" "$(echo "$R" | head -c 200)"; fi
POST_UNF=0
for ((k=0; k<N; k++)); do fq "${SEGS[$k]}" 'vec {"fill"}' 0 200 | grep -q 'filtered = false' && POST_UNF=$((POST_UNF+1)); done
[ "$POST_UNF" = "0" ] && ok "after the upgrade every segment honours the kinds filter (filtered = true on all $N)" || nok "segments still answer filtered = false after the upgrade" "$POST_UNF of $N"
# Each segment's fill AND D/W index backfill themselves (postupgrade arms ONE
# timer over both cursors — task 1793495003; a sealed segment has no other way
# to catch up, and adminBackfillArchiveDw used to reach archive0 only).
tries=0; LAG=1; DWLAG=1
while [ $tries -lt 20 ]; do
  LAG=0; DWLAG=0
  for ((k=0; k<N; k++)); do
    ST=$(arc "${SEGS[$k]}" stats '()' --query | flat)
    C=$(optnum "$ST" fillIndexCursor); D=$(optnum "$ST" dwIndexCursor); E=$(num "$ST" eventCount)
    [ -n "$C" ] && [ "$C" = "${E:-x}" ] || LAG=$((LAG+1))
    [ -n "$D" ] && [ "$D" = "${E:-x}" ] || DWLAG=$((DWLAG+1))
  done
  [ "$LAG" = "0" ] && [ "$DWLAG" = "0" ] && break
  sleep 2; tries=$((tries+1))
done
[ "$LAG" = "0" ] && ok "every segment's fill index is complete (stats.fillIndexCursor = eventCount on all $N)" || nok "fill index backfill incomplete" "$LAG segment(s) lagging after $tries polls"
[ "$DWLAG" = "0" ] && ok "every segment's D/W index is complete (stats.dwIndexCursor = eventCount on all $N)" || nok "D/W index backfill incomplete" "$DWLAG segment(s) lagging after $tries polls"
# The explicit driver walks the WHOLE chain (allArchivePrincipals ⊇ the routed
# segments: + the pre-spawned successor): report mode names every segment
# complete, none lagging, none failed.
BF_RAW=$(adm adminBackfillArchiveDw '(0 : nat)'); BF=$(echo "$BF_RAW" | flat)
BF_SEG=$(echo "$BF" | grep -oE 'segments=[0-9]+' | grep -oE '[0-9]+'); BF_DONE=$(echo "$BF" | grep -oE 'complete=[0-9]+' | grep -oE '[0-9]+')
BF_LAG=$(echo "$BF" | grep -oE 'lagging=[0-9]+' | grep -oE '[0-9]+'); BF_FAIL=$(echo "$BF" | grep -oE 'failed=[0-9]+' | grep -oE '[0-9]+')
if mdx_ok "$BF_RAW" && [ -n "$BF_SEG" ] && [ "$BF_SEG" -ge "$N" ] && [ "$BF_DONE" = "$BF_SEG" ] && [ "${BF_LAG:-x}" = "0" ] && [ "${BF_FAIL:-x}" = "0" ]; then
  ok "adminBackfillArchiveDw walks the whole chain: segments=$BF_SEG (≥ the $N routed) complete=$BF_DONE lagging=0 failed=0 (report mode)"
else
  nok "adminBackfillArchiveDw did not report every segment complete" "$(echo "$BF" | head -c 240)"
fi
F_AFTER=$(fills_total "$(fq "$F" 'vec {"fill"}' 0 200)")
[ "$F_AFTER" = "${F_FILLS:-x}" ] && ok "F's fills total is unchanged on the index path ($F_FILLS) — index = gather = client-side count" || nok "F's fills total changed after the upgrade/index" "was $F_FILLS now $F_AFTER"

echo "── §4 measurement: round trips to the first fill row ──"
NEWEST=(); for ((k=N-1; k>=0; k--)); do NEWEST+=("${SEGS[$k]}"); done
T0=$(now); OLD_RT=0
for s in "${NEWEST[@]}"; do
  R=$(lq "$s" 0 200); OLD_RT=$((OLD_RT+1))
  [ "$(fills_in "$R")" -ge 1 ] && break
done
T1=$(now)
WAVES=0; REQS=0; HIT=0
for ((k=0; k<N && HIT==0; k+=6)); do
  pids=(); for ((j=k; j<k+6 && j<N; j++)); do
    ( fq "${NEWEST[$j]}" 'vec {"fill"}' 0 200 > "$TEST_SCRATCH/wave-$j" ) & pids+=($!); REQS=$((REQS+1))
  done
  wait "${pids[@]}"; WAVES=$((WAVES+1))
  for ((j=k; j<k+6 && j<N; j++)); do [ "$(fills_total "$(cat "$TEST_SCRATCH/wave-$j")")" != "0" ] && HIT=1; done
done
T2=$(now)
echo "  serial unfiltered walk: $OLD_RT round trips, $(dur "$T0" "$T1")s · parallel filtered walk: $WAVES wave(s) of ≤6 ($REQS requests), $(dur "$T1" "$T2")s · chain: $N segments"
echo "  (round trips are the metric: the local replica executes queries one at a time and each icp CLI process adds its own startup, so a wave's wall time here is not the browser's — on the IC the 6 probes run concurrently)"
[ "$HIT" = "1" ] && [ "$WAVES" -lt "$OLD_RT" ] && ok "first fill row in $WAVES wave(s) instead of $OLD_RT serial round trips" || nok "parallel filtered walk did not reach the fill row in fewer round trips" "hit=$HIT waves=$WAVES serial=$OLD_RT"

echo "── §5 a MISSING segment: canister deleted, routing row kept (task 1793569495) ──"
# The engine's 2026-11-01 shape, manufactured for real: the first churn
# segment above F (sealed; holds only this throwaway identity's withdrawal +
# #delta rows) is stopped and DELETED by the dev hook while getArchives keeps
# its row. The not-found reject class must then be TOLERATED by the federation
# (a value naming the cause, not a reject), NAMED by adminUpgradeArchives, and
# the row droppable by adminDropMissingArchive — which refused while the
# canister existed and refuses every other row. Afterwards the venue carries
# one declared #gap (the segment's seq range) + a balance re-baseline on its
# tape: what the operator's drop on the engine leaves behind.
SEGS5=($(segments)); N5=${#SEGS5[@]}
FI5=-1; for ((k=0; k<N5; k++)); do [ "${SEGS5[$k]}" = "$F" ] && FI5=$k; done
C="${SEGS5[$((FI5+1))]:-}"; TIP5="${SEGS5[$((N5-1))]}"
if [ -z "$C" ] || [ "$C" = "$TIP5" ]; then
  nok "no sealed churn segment above F to delete" "chain=$N5 F=$FI5"
else
  ROW=$(adm getArchives '()' --query | flat | sed 's/record {/\n&/g' | grep "canisterId = \"$C\"")
  C_FIRST=$(echo "$ROW" | grep -oE 'firstSeq = [0-9]+' | grep -oE '[0-9]+'); C_LAST=$(echo "$ROW" | grep -oE 'lastSeq = opt \([0-9]+' | grep -oE '[0-9]+')
  if [ -n "$C_FIRST" ] && [ -n "$C_LAST" ]; then ok "victim C = $C, a sealed churn segment (seq $C_FIRST..$C_LAST)"; else nok "could not read C's routing row" "$ROW"; fi
  C_TO=$(( ${C_LAST:-0} + 1 ))
  # Refusals while everything is healthy — the door never trusts its argument.
  R=$(adm adminDropMissingArchive "(principal \"$C\")")
  if echo "$R" | grep -q 'EXISTS (canister_status answered'; then ok "drop refused while C EXISTS (canister_status answered — the argument is never trusted)"; else nok "drop of an existing segment not refused" "$(echo "$R" | head -c 200)"; fi
  R=$(adm adminDropMissingArchive '(principal "aaaaa-aa")')
  if echo "$R" | grep -q 'not a sealed segment of the current chain'; then ok "drop refused for a principal that is not a row"; else nok "unknown row not refused" "$(echo "$R" | head -c 200)"; fi
  R=$(adm adminDropMissingArchive "(principal \"$TIP5\")")
  if echo "$R" | grep -q 'is the active archive of the current chain'; then ok "drop refused for the active tip"; else nok "active tip not refused" "$(echo "$R" | head -c 200)"; fi
  R=$(u adminDropMissingArchive "(principal \"$C\")")
  if ! mdx_ok "$R" && echo "$R" | grep -qi 'controller\|reject\|inspect'; then ok "drop is controller-only (the test identity is refused: $(echo "$R" | tr -d '\n' | grep -oiE 'not a canister controller|reject[a-z]*' | head -1))"; else nok "non-controller not refused" "$(echo "$R" | head -c 200)"; fi
  # The deletion (dev hook, scoped to OUR sealed rows: the tip is refused).
  R=$(adm setTestArchiveDeleted "(principal \"$TIP5\")")
  if echo "$R" | grep -q 'not a sealed archive segment'; then ok "the delete hook refuses the active tip"; else nok "delete hook accepted the tip" "$(echo "$R" | head -c 200)"; fi
  D=$(adm setTestArchiveDeleted "(principal \"$C\")")
  if mdx_ok "$D"; then ok "C stopped and DELETED by the hook (its routing row kept)"; else nok "delete hook refused" "$(echo "$D" | head -c 200)"; fi
  if segments | grep -q "^$C\$"; then ok "getArchives still lists C — the engine's shape (row kept, canister gone)"; else nok "C left getArchives on delete" "$(segments | tr '\n' ' ')"; fi
  echo "  (icp canister status $C → $(icp canister status "$C" --identity anonymous 2>&1 | tr '\n' ' ' | head -c 160))"
  # (1) the federation tolerates it: unavailable, total 0, no reject; the rest still serve.
  R=$(fq "$C" 'vec {"fill"}' 0 200)
  if echo "$R" | grep -q 'unavailable = opt "' && [ "$(num "$R" total)" = "0" ]; then ok "filtered pager: C answers unavailable = opt \"…\" with total 0 — a value, not a reject"; else nok "filtered pager did not answer unavailable for the missing segment" "$(echo "$R" | head -c 240)"; fi
  if echo "$R" | grep -q 'segment missing (canister not found)'; then ok "…classified as the not-found class: $(echo "$R" | grep -oE 'unavailable = opt "[^"]{0,140}')"; else nok "cause not classified as not-found" "$(echo "$R" | grep -oE 'unavailable = opt "[^"]*"' | head -c 240)"; fi
  L=$(lq "$C" 0 200)
  if echo "$L" | grep -q 'unavailable = opt "' && [ "$(num "$L" total)" = "0" ]; then ok "legacy pager: C answers unavailable with total 0 too (the Account → Archive page keeps paging)"; else nok "legacy pager did not answer unavailable" "$(echo "$L" | head -c 240)"; fi
  R2=$(fq "$F" 'vec {"fill"}' 0 200)
  if [ "$(fills_total "$R2")" = "${F_FILLS:-x}" ] && echo "$R2" | grep -q 'unavailable = null'; then ok "F still serves its fills ($F_FILLS, unavailable = null) beside the missing segment"; else nok "F degraded by the missing segment" "$(echo "$R2" | head -c 200)"; fi
  # The fuel pass names the state and funds nothing (it used to blind-fund a canister that is not there).
  adm adminRunArchiveFuelPass '()' >/dev/null 2>&1
  FL=$(adm getRecentEvents '(200 : nat)' --query 2>/dev/null | tr -d '\n' | grep -oE "ARCHIVE FUEL: sealed segment $C does NOT EXIST[^\"]{0,120}" | head -1)
  if [ -n "$FL" ]; then ok "the fuel pass logs the real state ($(echo "$FL" | head -c 120)…)"; else nok "no 'does NOT EXIST … not funding' fuel line for C" "$(adm getRecentEvents '(60 : nat)' --query 2>/dev/null | grep -oE 'ARCHIVE FUEL[^;]{0,100}' | head -3 | tr '\n' ' ')"; fi
  # (2) adminUpgradeArchives names the hop and the reject text.
  U=$(adm adminUpgradeArchives '()' | flat)
  if echo "$U" | grep -q ", 1 failed — $C: "; then ok "adminUpgradeArchives names the failed segment in its reply (1 failed — $C: …)"; else nok "reply does not name the failed segment" "$(echo "$U" | head -c 300)"; fi
  if echo "$U" | grep -qi "$C: [^;]*not found"; then ok "…with the IC's reject text ($(echo "$U" | grep -oE "$C: [^;(]{0,90}"))"; else nok "reply lacks the reject text" "$(echo "$U" | head -c 300)"; fi
  if echo "$U" | grep -q 'adminDropMissingArchive'; then ok "…and points at adminDropMissingArchive for the not-found cause"; else nok "reply does not name the drop door" "$(echo "$U" | head -c 300)"; fi
  if echo "$U" | grep -q 'see log'; then nok "reply still says 'see log'" "$(echo "$U" | head -c 200)"; else ok "the reply no longer says 'see log' (it names the ring-log surface instead)"; fi
  # (3) the drop: the row goes, the tape declares the hole, the chain is clean again.
  BL0=$(adm getShedBaselines '()' --query | flat | grep -o 'record {' | wc -l | tr -d ' ')
  R=$(adm adminDropMissingArchive "(principal \"$C\")")
  if mdx_ok "$R"; then ok "adminDropMissingArchive(C): $(echo "$R" | flat | grep -oE 'dropped routing row [^;]{0,110}')"; else nok "drop refused for the missing segment" "$(echo "$R" | head -c 300)"; fi
  if segments | grep -q "^$C\$"; then nok "C still listed by getArchives after the drop" "$(segments | tr '\n' ' ')"; else ok "getArchives no longer lists C"; fi
  GAPS=$(adm getLedgerGaps '()' --query | flat)
  if echo "$GAPS" | grep -q "record { $C_FIRST : nat; $C_TO : nat;"; then ok "getLedgerGaps records the lost range [$C_FIRST..$C_TO)"; else nok "no ledger-gap tuple for the lost range" "$(echo "$GAPS" | head -c 200)"; fi
  BL1=$(adm getShedBaselines '()' --query | flat | grep -o 'record {' | wc -l | tr -d ' ')
  if [ "$BL1" = "$(( BL0 + 1 ))" ]; then ok "getShedBaselines gained the balance re-baseline that reopens the tape for replay ($BL0 → $BL1)"; else nok "no new shed baseline recorded by the drop" "before=$BL0 after=$BL1"; fi
  R=$(adm adminDropMissingArchive "(principal \"$C\")")
  if echo "$R" | grep -q 'not a sealed segment of the current chain'; then ok "a second drop is refused (row absent)"; else nok "second drop not refused" "$(echo "$R" | head -c 200)"; fi
  U2=$(adm adminUpgradeArchives '()' | flat)
  if echo "$U2" | grep -q ', 0 failed'; then ok "adminUpgradeArchives after the drop: 0 failed (the chain is clean)"; else nok "upgrade still fails after the drop" "$(echo "$U2" | head -c 300)"; fi
  R=$(fq "$C" 'vec {"fill"}' 0 200)
  if [ "$(num "$R" total)" = "0" ] && echo "$R" | grep -q 'not an archive segment'; then ok "C is now refused as unknown (total 0, 'not an archive segment')"; else nok "dropped C not refused as unknown" "$(echo "$R" | head -c 200)"; fi
  # The tape rows: the door writes #config (who dropped what), then #gap (the
  # declared hole), then the re-baseline rows — so the newest baseline tuple
  # [bFrom, bTo) locates them exactly: #config at bFrom-2, #gap at bFrom-1.
  # (The baseline is one row per live balance — ~1,640 on a seeded venue — so
  # a fixed look-back from the tip's head cannot find them; the tuple can.)
  # They ship with the next tick; read them from whichever segment covers the
  # seq (the tip, unless it sealed meanwhile).
  drain >/dev/null
  BLT=$(adm getShedBaselines '()' --query | flat | grep -oE 'record \{ [0-9]+ : nat; [0-9]+' | tail -1)
  BF=$(echo "$BLT" | grep -oE '[0-9]+' | sed -n '1p'); BT=$(echo "$BLT" | grep -oE '[0-9]+' | sed -n '2p')
  S=$(( ${BF:-2} - 2 ))
  HOLDER=""
  while read -r row; do
    f=$(echo "$row" | grep -oE 'firstSeq = [0-9]+' | grep -oE '[0-9]+'); l=$(echo "$row" | grep -oE 'lastSeq = opt \([0-9]+' | grep -oE '[0-9]+')
    c=$(echo "$row" | grep -oE 'canisterId = "[a-z0-9-]+"' | grep -oE '"[^"]+"' | tr -d '"')
    if [ "$S" -ge "${f:-0}" ] && { [ -z "$l" ] || [ "$S" -le "$l" ]; }; then HOLDER="$c"; break; fi
  done < <(adm getArchives '()' --query | flat | sed 's/record {/\n&/g' | grep canisterId)
  TAPE=$(arc "${HOLDER:-$(segments | tail -1)}" getEventsRange "($S : nat, 2 : nat)" --query | flat)
  if echo "$TAPE" | grep -q "seq = $S : nat" && echo "$TAPE" | grep -q 'setter = "adminDropMissingArchive"'; then ok "the tape carries #config { setter = adminDropMissingArchive } at seq $S — the action, attributed (segment ${HOLDER:-?})"; else nok "no #config row for the drop at seq $S" "holder=${HOLDER:-?} baseline=[${BF:-?}..${BT:-?}) $(echo "$TAPE" | head -c 240)"; fi
  if echo "$TAPE" | grep -qE "gap = record \{ (toSeq = $C_TO : nat; fromSeq = $C_FIRST : nat|fromSeq = $C_FIRST : nat; toSeq = $C_TO : nat)"; then ok "the tape carries #gap { fromSeq = $C_FIRST; toSeq = $C_TO } at seq $(( S + 1 )) — the chain declares its hole"; else nok "no #gap row with the lost range at seq $(( S + 1 ))" "$(echo "$TAPE" | grep -oE 'gap = record \{[^}]*\}' | head -3 | tr '\n' ' ')"; fi
  if [ -n "$BF" ] && [ -n "$BT" ] && [ "$BT" -gt "$BF" ]; then ok "the re-baseline follows at [$BF..$BT): $(( BT - BF )) absolute rows, one per live balance — the tape is replayable past the hole"; else nok "the newest baseline tuple is malformed" "$BLT"; fi
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
