#!/bin/bash
# tests/test_season_record_archives.sh — the SeasonRecord's archive snapshot
# and the pre-spawned successor at a season boundary (public issue #54 §54.4
# and #55 "empty successor as a season segment", OhShii round 18).
#
# Two seasons are closed on one venue, each with a multi-segment chain (tiny
# archive cap → seal + roll, the test_archive_chain.sh recipe) AND a successor
# pre-spawned at the boundary (spawn-ahead fires at 90% of the cap).
#
#   §1 grow season A: ≥1 sealed segment, the active tip, and a "next" row
#   §2 close A: SeasonRecord.archives == A's sealed segments + tip, exactly —
#      NOT the successor (it holds no event of A), and the successor is NOT
#      registered as a season row; it survives the detach as role "next"
#      (pre-fix: registered as a season row with firstSeq 0, then nulled)
#   §3 season B's first ship adopts A's successor as archive0 at seq 0 — the
#      canister is handed to the next epoch, never an empty season segment
#      (pre-fix: a fresh archive was spawned and the successor sat empty)
#   §4 close B: records[B].archives ∩ records[A].archives == ∅ (pre-fix:
#      allArchivePrincipals spanned the season registry, so B ⊇ A), and A's
#      successor is B's first segment
#   §5 no season row of A or B has firstSeq = 0 with an EMPTY certified head
#      (a segment that never held an event) — exactly one open (lastSeq null)
#      row per season, and it holds events
#   §6 the EMPTY-TIP boundary (1788511319): season C's chain is pushed across
#      the cap on its LAST drain, so the seal+swap leaves the fresh successor
#      as archive_0 with nothing chained (anchored at the shipped extent). The
#      close must treat it exactly like a pre-spawned successor: omitted from
#      records[C].archives, NOT a season row, carried as "next", adopted by
#      the next epoch's first ship at seq 0 (pre-fix: listed in the record
#      and registered { firstSeq N; lastSeq null } with a null certified head
#      — seen live 2026-09-04, 3 canisters "sealed at event seq 305")
#
# §2/§4 pin the cap far above the count between grow() and resetSeason
# (setTestArchiveCap 100_000, the test_retire_empty_season_segment.sh shape):
# grow() parks the active count in the spawn window [90% cap, cap), and any
# batch shipped by the closing drain — venue chatter scales with the user
# count — can cross the cap and seal the tip, which is §6's scenario, not
# theirs. (The boundary itself emits NOTHING in-window: the heartbeat returns
# under the sealing latch, main.mo heartbeat/timersHeld; the "[badge] badge
# awarded" burst is ring-log only, post-wipe, one line per registered user.)
#
# Structural assertions only (delta chatter makes counts workload-dependent).
# Needs #dev (setTestArchiveCap, setTestBalance, resetSeason's posture).
# ⚠️ Runs resetSeason THREE times — wallets zeroed, archives detached; reseed after.
# Order-independent: seasons are indexed relative to the records present.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
adm()  { echo y | icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
arc()  { local id="$1"; shift; echo y | icp canister call --identity anonymous "$id" "$@" 2>&1; }
flat() { tr -d '_\n' | tr -s ' '; }

[ "$(venue_posture)" = "dev" ] || skip_posture "test_season_record_archives" "setTestArchiveCap / setTestBalance / resetSeason (#dev backend)"

# The sim must be dead (it would inject noise). PID-file stopper — NEVER a
# pattern kill (scripts/lib/bots.sh; the live fleet went down three times).
STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }
adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true   # the shipper must run
adm setTestArchiveMaxHops '(null)' >/dev/null 2>&1 || true
adm setTestArchiveCap '(opt (60 : nat))' >/dev/null

mdx_identity_new sra_wd; WD=$(principal_of sra_wd)   # virgin each run, deleted on EXIT (tests/_lib.sh)

# ── helpers ────────────────────────────────────────────────────────
# Rows of a getArchiveChain / getSeasonArchives reply, one per line, so each
# field is grepped WITHIN its own row — never positionally across fields
# (CLI textual records print in candid hash order).
rows() { flat | sed 's/record {/\nrecord {/g' | grep 'canisterId'; }
row_cid() { grep -oE 'canisterId = "[a-z0-9-]+"' | grep -oE '"[^"]+"' | tr -d '"'; }
chain_rows() { adm getArchiveChain '()' --query | rows; }
chain_cids_by_role() { chain_rows | grep "role = \"$1\"" | row_cid; }
season_rows() { adm getSeasonArchives "($1 : nat)" --query | rows; }
rec_archives() { flat | grep -oE 'archives = vec \{[^}]*\}' | grep -oE 'principal "[a-z0-9-]+"' | grep -oE '"[^"]+"' | tr -d '"' | sort; }
head_seq() { arc "$1" getCertifiedHead '()' --query | flat | grep -oE 'headSeq = (opt \([0-9]+|null)' | head -1; }
# set algebra over newline lists
inter() { comm -12 <(printf '%s\n' "$1" | sort -u) <(printf '%s\n' "$2" | sort -u); }
same_set() { [ "$(printf '%s\n' "$1" | sort -u | grep -c .)" = "$(printf '%s\n' "$2" | sort -u | grep -c .)" ] && [ -z "$(comm -3 <(printf '%s\n' "$1" | sort -u) <(printf '%s\n' "$2" | sort -u))" ]; }

drain() {  # ship until the semantic queue AND the ledger journal are empty
  local i=0
  while [ $i -lt 40 ]; do
    adm adminForceShipTick '()' >/dev/null 2>&1
    INFO=$(adm getCanisterInfo '()' --query | tr -d '_')
    UNSH=$(echo "$INFO" | grep -oE "journalUnshipped = [0-9]+" | grep -oE "[0-9]+$")
    JP=$(echo "$INFO" | grep -oE "ledgerJournalPending = [0-9]+" | grep -oE "[0-9]+$")
    [ "${UNSH:-1}" = "0" ] && [ "${JP:-1}" = "0" ] && return 0
    sleep 2; i=$((i+1))
  done
  return 1
}
wd() {  # emit withdrawal events (each = 1 semantic + its ledger deltas)
  local n="$1" tag="$2" i=0
  while [ $i -lt "$n" ]; do
    echo y | icp canister call --candid "$MDX_CANDID" --identity sra_wd backend withdraw "(\"ICPUSD\", 1_000_000_000 : nat, \"$tag-$i\")" >/dev/null 2>&1
    i=$((i+1))
  done
}
# Grow the current chain until it has ≥1 sealed segment AND a pre-spawned
# successor ("next"). The successor is observable only while the active
# count sits in [90% cap, cap): spawn-ahead and the seal both run inside one
# ship tick, so a wave that crosses the whole window leaves nothing to see.
# With cap 60 the window is 6 events wide and a single withdrawal is ~3, so
# waves of 4 reach the first seal fast and single steps then land in the
# window. Bounded both ways.
grow() {
  local tag="$1" i=0 sealed next
  while [ $i -lt 20 ]; do
    sealed=$(chain_cids_by_role sealed | grep -c .)
    [ "$sealed" -ge 1 ] && break
    wd 4 "$tag-w$i"; drain || return 1
    i=$((i+1))
  done
  i=0
  while [ $i -lt 60 ]; do
    next=$(chain_cids_by_role next | grep -c .)
    [ "$next" -ge 1 ] && [ "$(chain_cids_by_role sealed | grep -c .)" -ge 1 ] && return 0
    wd 1 "$tag-s$i"; drain || return 1
    i=$((i+1))
  done
  return 1
}

N0=$(adm getSeasonRecords '()' --query | flat | grep -oE 'season = [0-9]+' | grep -c .)
SA=$((N0 + 1)); SB=$((N0 + 2)); SC=$((N0 + 3))
echo "   (venue holds $N0 season record(s); this run closes seasons $SA, $SB and $SC)"

echo "── §1 season $SA: a multi-segment chain with a successor pre-spawned ──"
adm setTestBalance "(principal \"$WD\", \"ICPUSD\", 1_000_000_000_000 : nat)" >/dev/null
if grow a; then ok "chain grown: ≥1 sealed segment + a pre-spawned successor"; else nok "chain did not grow to sealed + next" "$(chain_rows | head -c 300)"; fi
SEALED_A=$(chain_cids_by_role sealed); ACTIVE_A=$(chain_cids_by_role active); NEXT_A=$(chain_cids_by_role next | head -1)
EXPECT_A=$(printf '%s\n%s\n' "$SEALED_A" "$ACTIVE_A" | grep . | sort)
[ -n "$NEXT_A" ] && ok "successor pre-spawned before the boundary: $NEXT_A" || nok "no successor" "$(chain_rows | head -c 300)"
[ "$(printf '%s\n' "$EXPECT_A" | grep -c .)" -ge 2 ] && ok "season $SA holds $(printf '%s\n' "$EXPECT_A" | grep -c .) event-bearing segment(s)" || nok "expected ≥2 event-bearing segments" "$EXPECT_A"
adm setTestArchiveCap '(opt (100_000 : nat))' >/dev/null   # the closing drain must not seal the tip (see the header; §6 owns that case)
drain || nok "tape did not drain before the seal" "gates would refuse"

echo "── §2 close season $SA: the record snapshots THIS season's ledger, not the successor ──"
R=$(adm resetSeason '()')
if mdx_ok "$R"; then ok "resetSeason #ok (season $SA)"; else nok "resetSeason refused" "$(echo "$R" | flat | head -c 200)"; fi
REC_A=$(echo "$R" | rec_archives)
if same_set "$REC_A" "$EXPECT_A"; then ok "records[$SA].archives == season $SA's sealed segments + tip (exactly)"
else nok "records[$SA].archives != the season's own chain (#54.4)" "rec=[$(echo "$REC_A" | tr '\n' ' ')] chain=[$(echo "$EXPECT_A" | tr '\n' ' ')]"; fi
if printf '%s\n' "$REC_A" | grep -qx "$NEXT_A"; then nok "records[$SA].archives lists the empty successor" "$NEXT_A"
else ok "records[$SA].archives omits the successor (it holds no event of season $SA)"; fi
SROWS_A=$(season_rows "$SA")
SROW_CIDS_A=$(printf '%s\n' "$SROWS_A" | row_cid | sort)
if same_set "$SROW_CIDS_A" "$EXPECT_A"; then ok "getSeasonArchives($SA) routes exactly the record's segments"
else nok "getSeasonArchives($SA) disagrees with the record" "rows=[$(echo "$SROW_CIDS_A" | tr '\n' ' ')]"; fi
if printf '%s\n' "$SROWS_A" | grep -q "\"$NEXT_A\""; then nok "the successor was registered as a season $SA row (#55 empty successor)" "$(printf '%s\n' "$SROWS_A" | grep "\"$NEXT_A\"" | head -c 200)"
else ok "the successor is NOT a season $SA row"; fi
if chain_cids_by_role next | grep -qx "$NEXT_A"; then ok "the successor survives the detach as role \"next\" (carried into the new epoch)"
else nok "the successor did not survive the boundary as \"next\"" "$(chain_rows | grep "\"$NEXT_A\"" | head -c 200)"; fi
[ -z "$(chain_cids_by_role active)" ] && ok "no active archive right after the detach (the new epoch has shipped nothing yet)" || nok "an active archive exists before the first ship" "$(chain_cids_by_role active)"

echo "── §3 season $SB's first ship adopts the carried successor as archive_0 ──"
adm setTestArchiveCap '(opt (60 : nat))' >/dev/null   # back to the tiny cap for season $SB's growth
adm setTestBalance "(principal \"$WD\", \"ICPUSD\", 1_000_000_000_000 : nat)" >/dev/null   # the season wipe zeroed the wallet
wd 1 b0; drain || nok "first wave of season $SB did not ship" "unshipped"
ACTIVE_B0=$(chain_cids_by_role active | head -1)
if [ -n "$ACTIVE_B0" ] && [ "$ACTIVE_B0" = "$NEXT_A" ]; then ok "season $SB's active archive IS season $SA's successor ($NEXT_A) — no fresh spawn"
else nok "season $SB spawned a fresh archive instead of adopting the successor" "active=${ACTIVE_B0:-none} successor=$NEXT_A"; fi
FS=$(chain_rows | grep 'role = "active"' | grep -oE 'firstSeq = opt \([0-9]+' | grep -oE '[0-9]+$')
[ "${FS:-x}" = "0" ] && ok "the adopted archive anchors at seq 0 (firstSeq = 0)" || nok "adopted archive firstSeq != 0" "got ${FS:-?}"
HS=$(head_seq "$NEXT_A")
echo "$HS" | grep -q 'headSeq = opt' && ok "the adopted archive holds season $SB events (certified head $HS)" || nok "adopted archive still empty after the first ship" "$HS"
[ -z "$(chain_cids_by_role next)" ] && ok "no second successor yet (the pointer was consumed, not duplicated)" || nok "a stray \"next\" row exists right after the adoption" "$(chain_cids_by_role next)"

echo "── §4 close season $SB: disjoint from season $SA, the carried successor is its first segment ──"
if grow b; then ok "season $SB chain grown: ≥1 sealed + a new successor"; else nok "season $SB chain did not grow" "$(chain_rows | head -c 300)"; fi
SEALED_B=$(chain_cids_by_role sealed); ACTIVE_B=$(chain_cids_by_role active); NEXT_B=$(chain_cids_by_role next | head -1)
EXPECT_B=$(printf '%s\n%s\n' "$SEALED_B" "$ACTIVE_B" | grep . | sort)
adm setTestArchiveCap '(opt (100_000 : nat))' >/dev/null   # as in §1: the closing drain must not seal the tip
drain || nok "tape did not drain before the second seal" "gates would refuse"
R=$(adm resetSeason '()')
if mdx_ok "$R"; then ok "resetSeason #ok (season $SB)"; else nok "resetSeason refused" "$(echo "$R" | flat | head -c 200)"; fi
REC_B=$(echo "$R" | rec_archives)
if same_set "$REC_B" "$EXPECT_B"; then ok "records[$SB].archives == season $SB's sealed segments + tip (exactly)"
else nok "records[$SB].archives != the season's own chain" "rec=[$(echo "$REC_B" | tr '\n' ' ')] chain=[$(echo "$EXPECT_B" | tr '\n' ' ')]"; fi
X=$(inter "$REC_A" "$REC_B")
if [ -z "$X" ] && [ -n "$REC_A" ] && [ -n "$REC_B" ]; then ok "records[$SB].archives ∩ records[$SA].archives == ∅"
else nok "season records overlap (#54.4: season N carried seasons 1..N)" "shared=[$(echo "$X" | tr '\n' ' ')]"; fi
printf '%s\n' "$REC_B" | grep -qx "$NEXT_A" && ok "season $SA's successor is recorded under season $SB" || nok "the carried successor is missing from records[$SB]" "$(echo "$REC_B" | tr '\n' ' ')"
printf '%s\n' "$REC_B" | grep -qx "$NEXT_B" && nok "records[$SB].archives lists season $SB's empty successor" "$NEXT_B" || ok "records[$SB].archives omits season $SB's successor"
SROWS_B=$(season_rows "$SB")
ROW_NA=$(printf '%s\n' "$SROWS_B" | grep "\"$NEXT_A\"" | head -1)
if [ -n "$ROW_NA" ] && echo "$ROW_NA" | grep -qE 'firstSeq = 0[^0-9]' && echo "$ROW_NA" | grep -q 'lastSeq = opt'; then ok "getSeasonArchives($SB): the carried successor is a SEALED segment starting at seq 0"
else nok "the carried successor is not season $SB's first sealed segment" "$(echo "$ROW_NA" | head -c 200)"; fi
SR=$(adm getSeasonRecords '()' --query | flat)
NR=$(echo "$SR" | grep -oE 'season = [0-9]+' | grep -c .)
[ "$NR" = "$SB" ] && ok "getSeasonRecords holds $NR records" || nok "record count" "got $NR want $SB"

echo "── §5 no season row is an event-less segment (firstSeq 0, empty head) ──"
for S in "$SA" "$SB"; do
  SROWS=$(season_rows "$S")
  OPEN=$(printf '%s\n' "$SROWS" | grep 'lastSeq = null' | row_cid)
  NOPEN=$(printf '%s\n' "$OPEN" | grep -c .)
  [ "$NOPEN" = "1" ] && ok "season $S: exactly one open (lastSeq null) row — the tip" || nok "season $S: $NOPEN open rows (pre-fix: tip + the empty successor)" "$(echo "$OPEN" | tr '\n' ' ')"
  EMPTY=0
  for cid in $(printf '%s\n' "$SROWS" | row_cid); do
    HS=$(head_seq "$cid")
    echo "$HS" | grep -q 'headSeq = null' && { EMPTY=$((EMPTY+1)); echo "   empty segment in season $S: $cid ($HS)"; }
  done
  [ "$EMPTY" = "0" ] && ok "season $S: every registered segment holds events (no empty certified head)" || nok "season $S registers $EMPTY event-less segment(s)" "refilled forever, one hop each"
done
Z=$(printf '%s\n%s\n' "$SROWS_A" "$SROWS_B" | grep -E 'firstSeq = 0[^0-9]' | grep -c 'lastSeq = null')
[ "$Z" = "0" ] && ok "no season row reads firstSeq = 0 with lastSeq null (the \"0 – growing\" successor row)" || nok "$Z season row(s) read firstSeq 0 / lastSeq null" "$(printf '%s\n%s\n' "$SROWS_A" "$SROWS_B" | grep -E 'firstSeq = 0[^0-9]' | grep 'lastSeq = null' | head -c 200)"

echo "── §6 the EMPTY-TIP boundary (1788511319): a tip that chained nothing is carried, never recorded ──"
adm setTestArchiveCap '(opt (60 : nat))' >/dev/null
adm setTestBalance "(principal \"$WD\", \"ICPUSD\", 1_000_000_000_000 : nat)" >/dev/null
if grow c; then ok "season $SC chain grown: ≥1 sealed segment + a pre-spawned successor"; else nok "season $SC chain did not grow" "$(chain_rows | head -c 300)"; fi
TIP_C=$(chain_cids_by_role active | head -1); NEXT_C=$(chain_cids_by_role next | head -1)
# Cross the cap in ONE drain: the whole wave ships into the old tip, then the
# seal check fires and swaps the successor in as archive_0 — with nothing
# chained. This is the shape the closing drain of §2/§4 would take without
# their cap pin, and the shape seen live (the tip sealed at 304, the
# successor registered { firstSeq 305; lastSeq null }).
wd 4 c-cross; drain || nok "the crossing wave did not ship" "unshipped"
ACTIVE_C=$(chain_cids_by_role active | head -1)
if [ -n "$NEXT_C" ] && [ "$ACTIVE_C" = "$NEXT_C" ]; then ok "the crossing drain sealed the tip ($TIP_C) and swapped the successor in as archive_0 ($NEXT_C)"
else nok "no seal+swap on the crossing drain" "active=${ACTIVE_C:-none} successor-before=${NEXT_C:-none}"; fi
HS=$(head_seq "$NEXT_C")
echo "$HS" | grep -q 'headSeq = null' && ok "the new tip has chained NOTHING (certified $HS) — the empty-tip precondition holds" || nok "the new tip already holds events; §6's precondition failed" "$HS"
[ -z "$(chain_cids_by_role next)" ] && ok "no successor pending beside the empty tip (spawn-ahead needs ≥90% of a non-empty tip)" || nok "a successor is pending beside the empty tip" "$(chain_cids_by_role next)"
EXPECT_C=$(chain_cids_by_role sealed | grep . | sort)
[ "$(printf '%s\n' "$EXPECT_C" | grep -c .)" -ge 2 ] && ok "season $SC holds $(printf '%s\n' "$EXPECT_C" | grep -c .) event-bearing (sealed) segment(s)" || nok "expected ≥2 sealed segments" "$EXPECT_C"
drain || nok "tape did not drain before the third seal" "gates would refuse"
R=$(adm resetSeason '()')
if mdx_ok "$R"; then ok "resetSeason #ok (season $SC)"; else nok "resetSeason refused" "$(echo "$R" | flat | head -c 200)"; fi
REC_C=$(echo "$R" | rec_archives)
if same_set "$REC_C" "$EXPECT_C"; then ok "records[$SC].archives == the sealed segments exactly — the empty tip is omitted"
else nok "records[$SC].archives lists the empty tip (pre-fix: every canister incl. the one that chained nothing)" "rec=[$(echo "$REC_C" | tr '\n' ' ')] sealed=[$(echo "$EXPECT_C" | tr '\n' ' ')]"; fi
printf '%s\n' "$REC_C" | grep -qx "$NEXT_C" && nok "records[$SC].archives names the empty tip" "$NEXT_C" || ok "records[$SC].archives omits $NEXT_C (it holds no event in [0, finalEventSeq))"
FINAL_C=$(echo "$R" | flat | grep -oE 'finalEventSeq = [0-9]+' | grep -oE '[0-9]+$')
SROWS_C=$(season_rows "$SC")
MAXLAST=$(printf '%s\n' "$SROWS_C" | grep -oE 'lastSeq = opt \([0-9]+' | grep -oE '[0-9]+$' | sort -n | tail -1)
[ -n "$FINAL_C" ] && [ -n "$MAXLAST" ] && [ "$FINAL_C" = "$((MAXLAST + 1))" ] && ok "finalEventSeq ($FINAL_C) == the last sealed segment's lastSeq + 1 — the record's extent ends where the sealed chain ends" || nok "finalEventSeq (${FINAL_C:-?}) != last sealed lastSeq + 1 (${MAXLAST:-?})" "$(echo "$SROWS_C" | head -c 200)"
if printf '%s\n' "$SROWS_C" | grep -q "\"$NEXT_C\""; then nok "the empty tip was registered as a season $SC row" "$(printf '%s\n' "$SROWS_C" | grep "\"$NEXT_C\"" | head -c 200)"
else ok "the empty tip is NOT a season $SC row"; fi
NOPEN=$(printf '%s\n' "$SROWS_C" | grep -c 'lastSeq = null')
[ "$NOPEN" = "0" ] && ok "season $SC has no open (lastSeq null) row — every registered segment is sealed" || nok "season $SC has $NOPEN open row(s) (pre-fix: the empty tip as { firstSeq N; lastSeq null })" "$(printf '%s\n' "$SROWS_C" | grep 'lastSeq = null' | head -c 200)"
EMPTY=0
for cid in $(printf '%s\n' "$SROWS_C" | row_cid); do
  HS=$(head_seq "$cid")
  echo "$HS" | grep -q 'headSeq = null' && { EMPTY=$((EMPTY+1)); echo "   empty segment in season $SC: $cid ($HS)"; }
done
[ "$EMPTY" = "0" ] && ok "season $SC: every registered segment holds events (no empty certified head)" || nok "season $SC registers $EMPTY event-less segment(s)" "refilled forever, one hop each"
chain_cids_by_role next | grep -qx "$NEXT_C" && ok "the empty tip survives the detach as role \"next\" (carried into the new epoch)" || nok "the empty tip did not survive the boundary as \"next\"" "$(chain_rows | grep "\"$NEXT_C\"" | head -c 200)"
[ -z "$(chain_cids_by_role active)" ] && ok "no active archive right after the detach" || nok "an active archive exists before the first ship" "$(chain_cids_by_role active)"
adm setTestBalance "(principal \"$WD\", \"ICPUSD\", 1_000_000_000_000 : nat)" >/dev/null
wd 1 d0; drain || nok "the next epoch's first wave did not ship" "unshipped"
ACTIVE_D=$(chain_cids_by_role active | head -1)
[ -n "$ACTIVE_D" ] && [ "$ACTIVE_D" = "$NEXT_C" ] && ok "the next epoch's first ship adopts the carried tip as archive_0 ($NEXT_C) — no fresh spawn" || nok "the next epoch spawned a fresh archive instead of adopting the carried tip" "active=${ACTIVE_D:-none} carried=$NEXT_C"
FS=$(chain_rows | grep 'role = "active"' | grep -oE 'firstSeq = opt \([0-9]+' | grep -oE '[0-9]+$')
[ "${FS:-x}" = "0" ] && ok "the adopted archive anchors at seq 0 (firstSeq = 0)" || nok "adopted archive firstSeq != 0" "got ${FS:-?}"
HS=$(head_seq "$NEXT_C")
echo "$HS" | grep -q 'headSeq = opt' && ok "the adopted archive now holds the new epoch's events (certified $HS)" || nok "adopted archive still empty after the first ship" "$HS"
NR=$(adm getSeasonRecords '()' --query | flat | grep -oE 'season = [0-9]+' | grep -c .)
[ "$NR" = "$SC" ] && ok "getSeasonRecords holds $NR records" || nok "record count" "got $NR want $SC"

adm setTestArchiveCap '(null)' >/dev/null 2>&1
echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_season_record_archives ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_season_record_archives ($fail failed, $pass passed)${NC}"; exit 1
fi
