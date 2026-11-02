#!/bin/bash
# tests/test_retire_empty_season_segment.sh — adminRetireEmptySeasonSegment
# (task 1788499923; public issue #54 §54.4 + #55 "empty successor"): retiring
# a pre-fix EMPTY successor row from the season registry, and every refusal
# that keeps the op away from a real segment.
#
# Seasons closed before task 1788465055 registered the successor pre-spawned
# at the boundary as a season row — { firstSeq 0; lastSeq null } for a
# canister that never held an event ("0 – growing" in getSeasonArchives /
# getArchiveChain, refilled by the fuel loop forever, one archiveExecute hop
# per deep read). A build carrying the fix cannot produce that row any more,
# so this test SEEDS it with the setTestSeasonRow #dev hook, on the successor
# pre-spawned for the season it closes (captured as role "next" before the
# seal — the test_season_record_archives.sh recipe). Then:
#   §1 grow a chain (≥1 sealed segment + the tip + a "next"), close the season
#   §1b the join badge is a LIFETIME fact (task 1788515790): >40 users hold
#      it before the seal; every one survives the wipe with its original
#      awardedNs, the first tier tick after the seal re-awards none and
#      emits no backfill summary line
#   §2 refusals, nothing removed, nothing deleted:
#      (a) a principal that is no registry row — the carried successor itself,
#          this canister, and the management canister
#      (c) a row with lastSeq set — a sealed segment of the closed season
#      (b) a lastSeq-null row whose canister HOLDS events — the season's tip
#      plus: a non-controller cannot call it at all
#   §3 seed the pre-fix row for the successor (the hook also clears the
#      chain's "next" pointer — exactly the pre-fix shape); it reads
#      firstSeq 0 / lastSeq null in both tables; the hook's own scoping
#      refuses a foreign principal and a duplicate row
#   §4 retire it: #ok, the row is gone from getSeasonArchives AND
#      getArchiveChain, the canister no longer answers (deleted), the ring log
#      names it, and the tape carries a #config event (setter = the method)
#   §5 a second call refuses (no longer a row) — the op is not re-runnable
#      against a deleted canister
#
# Structural assertions only. Needs #dev (setTestArchiveCap, setTestBalance,
# setTestSeasonRow, resetSeason's posture); the op itself is controller-only
# on every posture.
# ⚠️ Runs resetSeason — wallets zeroed, archives detached; reseed after.
# Order-independent: the season is indexed relative to the records present.

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

[ "$(venue_posture)" = "dev" ] || skip_posture "test_retire_empty_season_segment" "setTestArchiveCap / setTestBalance / setTestSeasonRow / resetSeason (#dev backend)"

# The sim must be dead (it would inject noise). PID-file stopper — NEVER a
# pattern kill (scripts/lib/bots.sh; the live fleet went down three times).
STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }
adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true   # the shipper must run
adm setTestArchiveMaxHops '(null)' >/dev/null 2>&1 || true
adm setTestArchiveCap '(opt (60 : nat))' >/dev/null

mdx_identity_new ret_wd; WD=$(principal_of ret_wd)   # virgin each run, deleted on EXIT (tests/_lib.sh)
BACKEND_ID=$(icp canister status backend --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')

# ── helpers (the test_season_record_archives.sh recipe) ────────────
# Rows of a getArchiveChain / getSeasonArchives reply, one per line, so each
# field is grepped WITHIN its own row — never positionally across fields
# (CLI textual records print in candid hash order).
rows() { flat | sed 's/record {/\nrecord {/g' | grep 'canisterId'; }
row_cid() { grep -oE 'canisterId = "[a-z0-9-]+"' | grep -oE '"[^"]+"' | tr -d '"'; }
chain_rows() { adm getArchiveChain '()' --query | rows; }
chain_cids_by_role() { chain_rows | grep "role = \"$1\"" | row_cid; }
season_rows() { adm getSeasonArchives "($1 : nat)" --query | rows; }
head_seq() { arc "$1" getCertifiedHead '()' --query | flat | grep -oE 'headSeq = (opt \([0-9]+|null)' | head -1; }
retire() { adm adminRetireEmptySeasonSegment "(principal \"$1\")"; }
events() { adm getRecentEvents "($1 : nat)" --query 2>/dev/null | tr -d '\n'; }

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
    echo y | icp canister call --candid "$MDX_CANDID" --identity ret_wd backend withdraw "(\"ICPUSD\", 1_000_000_000 : nat, \"$tag-$i\")" >/dev/null 2>&1
    i=$((i+1))
  done
}
# Grow the current chain until it has ≥1 sealed segment AND a pre-spawned
# successor ("next"). The successor is observable only while the active
# count sits in [90% cap, cap) — with cap 60 the window is 6 events wide and
# a single withdrawal is ~3, so waves of 4 reach the first seal fast and
# single steps then land in the window. Bounded both ways.
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
SA=$((N0 + 1))
echo "   (venue holds $N0 season record(s); this run closes season $SA)"

echo "── §1 season $SA: a multi-segment chain with a successor pre-spawned, then closed ──"
adm setTestBalance "(principal \"$WD\", \"ICPUSD\", 1_000_000_000_000 : nat)" >/dev/null
if grow a; then ok "chain grown: ≥1 sealed segment + a pre-spawned successor"; else nok "chain did not grow to sealed + next" "$(chain_rows | head -c 300)"; fi
SEALED_A=$(chain_cids_by_role sealed | head -1); ACTIVE_A=$(chain_cids_by_role active | head -1); NEXT_A=$(chain_cids_by_role next | head -1)
[ -n "$NEXT_A" ] && ok "successor pre-spawned before the boundary: $NEXT_A" || nok "no successor" "$(chain_rows | head -c 300)"
[ -n "$SEALED_A" ] && [ -n "$ACTIVE_A" ] && ok "a sealed segment ($SEALED_A) and the tip ($ACTIVE_A) hold season $SA's events" || nok "no sealed segment or no tip" "$(chain_rows | head -c 300)"
HS=$(head_seq "$NEXT_A")
echo "$HS" | grep -q 'headSeq = null' && ok "the successor holds no event (certified $HS)" || nok "the successor already holds events" "$HS"
# Pin the cap far above the count NOW. grow() parks the active count in the
# spawn window [90% cap, cap), so any batch the closing drain ships (venue
# chatter scales with the user count) can cross the cap and seal the tip on
# that LAST pre-boundary drain — the successor is then archive_0 with nothing
# chained, and pre-1788511319 the detach registered it { firstSeq N; lastSeq
# null } (seen live 2026-09-04 with 18 seasons of users on the venue: exactly
# the class the op retires — but it would leave the hook's path untested).
# Nothing ships INSIDE the boundary: the heartbeat returns under the sealing
# latch (main.mo timersHeld), and the post-wipe "[badge] badge awarded" burst
# is ring-log only. A huge cap keeps the chain where grow() left it: the
# successor survives the detach as "next", the tip holds events. The
# empty-tip boundary itself is test_season_record_archives.sh §6.
adm setTestArchiveCap '(opt (100_000 : nat))' >/dev/null
# ── §1b the join badge is a LIFETIME fact (task 1788515790, operator decision (a)) ──
# performWorldWipe restarts every badge with the scorecards EXCEPT the join
# badge: it rides with registeredUsers (which no wipe arm clears) and is
# re-granted with its ORIGINAL awardedNs, so it never disappears / re-appears
# across a season and tickTier's backfill finds nothing to do. Pre-fix: gone
# at the wipe, back one tick later with a NEW stamp for EVERY registered
# principal (the ring log's 'join-badge backfill: N awarded' line, N = the
# venue's user count). >40 users: WD plus 44 phantom principals registered
# through bulkSetTestBalances — a #dev registration path that bypasses
# creditAndRegister, exactly the one the backfill exists for — then one forced
# tier tick (devTickTier) grants them the badge before the seal.
JOIN_N=44
phantom_principals() {  # N fresh self-authenticating principal texts (nobody holds the keys)
  python3 - "$1" <<'PY'
import sys, os, hashlib, zlib, base64
for _ in range(int(sys.argv[1])):
    body = hashlib.sha224(os.urandom(32)).digest() + b"\x02"
    raw = zlib.crc32(body).to_bytes(4, "big") + body
    s = base64.b32encode(raw).decode().lower().rstrip("=")
    print("-".join(s[i:i + 5] for i in range(0, len(s), 5)))
PY
}
join_ts() { adm getUserBadges "(principal \"$1\")" --query | flat | sed 's/record {/\nrecord {/g' | grep 'id = 1 :' | grep -oE 'awardedNs = [0-9]+' | grep -oE '[0-9]+' | head -1; }
join_snapshot() { local p; for p in $JOIN_USERS; do echo "$p $(join_ts "$p")"; done; }
backfill_lines() { events 2000 | grep -o 'join-badge backfill: [0-9]* awarded' | grep -c .; }
JOIN_USERS="$WD"; ENT=""
for p in $(phantom_principals "$JOIN_N"); do JOIN_USERS="$JOIN_USERS $p"; ENT="$ENT record { \"principal\" = principal \"$p\"; balances = vec { record { token = \"ICPUSD\"; amount = 1_000_000 : nat } } };"; done
R=$(adm bulkSetTestBalances "(vec { $ENT })" | flat)
echo "$R" | grep -qE "\($JOIN_N : nat\)" && ok "§1b: $JOIN_N phantom principals registered through the bulk seed (dev registration path)" || nok "§1b: the bulk seed did not register $JOIN_N principals" "$(echo "$R" | head -c 200)"
adm devTickTier '()' >/dev/null 2>&1
JB0=$(join_snapshot); JB0_N=$(printf '%s\n' "$JB0" | awk 'NF == 2' | grep -c .)
[ "$JB0_N" -gt 40 ] && ok "§1b: $JB0_N users (>40) hold the join badge before the seal (backfill granted the dev-registered ones)" || nok "§1b: fewer than 41 users hold the join badge before the seal" "$JB0_N of $((JOIN_N + 1))"
drain || nok "tape did not drain before the seal" "gates would refuse"
R=$(adm resetSeason '()')
if mdx_ok "$R"; then ok "resetSeason #ok (season $SA)"; else nok "resetSeason refused" "$(echo "$R" | flat | head -c 200)"; fi
JB1=$(join_snapshot)
[ "$JB1" = "$JB0" ] && ok "§1b: every join badge survived the season wipe with its original awardedNs ($JB0_N users)" || nok "§1b: join badges changed at the wipe (lost or re-stamped)" "$(diff <(printf '%s\n' "$JB0") <(printf '%s\n' "$JB1") | grep -c '^<') of $JB0_N differ; e.g. $(printf '%s\n' "$JB1" | head -1)"
adm devTickTier '()' >/dev/null 2>&1
JB2=$(join_snapshot)
[ "$JB2" = "$JB0" ] && ok "§1b: one tier tick after the seal: same badges, same stamps — none awarded twice" || nok "§1b: the first tier tick after the seal re-awarded join badges" "$(diff <(printf '%s\n' "$JB0") <(printf '%s\n' "$JB2") | grep -c '^<') of $JB0_N re-stamped"
# The wipe clears the ring log (performWorldWipe: Map.clear(eventLog)), so
# any backfill summary line present now was emitted by the post-seal tick.
BF1=$(backfill_lines)
[ "${BF1:-0}" = "0" ] && ok "§1b: no 'join-badge backfill' summary line after the seal (the sweep found nothing to do)" || nok "§1b: the post-seal tick emitted a backfill summary line" "$(events 2000 | grep -o 'join-badge backfill: [0-9]* awarded' | tail -1)"
SROWS=$(season_rows "$SA")
NROWS=$(printf '%s\n' "$SROWS" | grep -c .)
[ "$NROWS" -ge 2 ] && ok "getSeasonArchives($SA) routes $NROWS segment(s)" || nok "season $SA has no registry rows" "$SROWS"
printf '%s\n' "$SROWS" | grep "\"$ACTIVE_A\"" | grep -q 'lastSeq = null' && ok "season $SA's tip row ($ACTIVE_A) has lastSeq null — the same shape as the empty successor row, told apart only by its head" || nok "tip row is not lastSeq null" "$(printf '%s\n' "$SROWS" | grep "\"$ACTIVE_A\"" | head -c 200)"
printf '%s\n' "$SROWS" | grep "\"$SEALED_A\"" | grep -q 'lastSeq = opt' && ok "season $SA's sealed row ($SEALED_A) has lastSeq set" || nok "sealed row is not lastSeq opt" "$(printf '%s\n' "$SROWS" | grep "\"$SEALED_A\"" | head -c 200)"
chain_cids_by_role next | grep -qx "$NEXT_A" && ok "the successor survives the detach as role \"next\" (not a season row — the 1788465055 shape)" || nok "the successor did not survive the boundary as \"next\"" "$(chain_rows | grep "\"$NEXT_A\"" | head -c 200)"

echo "── §2 refusals: no registry row, a sealed row, a tip that holds events, a non-controller ──"
R=$(retire "$NEXT_A")
if ! mdx_ok "$R" && echo "$R" | flat | grep -qF "not a season registry row"; then ok "(a) the carried successor is no registry row → refused ($(echo "$R" | flat | grep -oE 'err = "[^"]{0,60}'))"
else nok "(a) a non-row principal was not refused with 'not a season registry row'" "$(echo "$R" | flat | head -c 200)"; fi
R=$(retire "$BACKEND_ID")
if ! mdx_ok "$R" && echo "$R" | flat | grep -qF "not a season registry row"; then ok "(a) this canister is no registry row → refused"
else nok "(a) this canister was not refused" "$(echo "$R" | flat | head -c 200)"; fi
R=$(retire "aaaaa-aa")
if ! mdx_ok "$R" && echo "$R" | flat | grep -qF "not a season registry row"; then ok "(a) the management canister is no registry row → refused"
else nok "(a) aaaaa-aa was not refused" "$(echo "$R" | flat | head -c 200)"; fi
R=$(retire "$SEALED_A")
if ! mdx_ok "$R" && echo "$R" | flat | grep -qF "is a sealed segment"; then ok "(c) a row with lastSeq set → refused as a sealed segment ($(echo "$R" | flat | grep -oE 'lastSeq [0-9]+'))"
else nok "(c) the sealed row was not refused on lastSeq" "$(echo "$R" | flat | head -c 200)"; fi
R=$(retire "$ACTIVE_A")
if ! mdx_ok "$R" && echo "$R" | flat | grep -qF "holds events (certified headSeq"; then ok "(b) the season tip (lastSeq null, head set) → refused on its certified head ($(echo "$R" | flat | grep -oE 'headSeq [0-9]+'))"
else nok "(b) the tip was not refused on its certified head" "$(echo "$R" | flat | head -c 200)"; fi
R=$(echo y | icp canister call --candid "$MDX_CANDID" --identity ret_wd backend adminRetireEmptySeasonSegment "(principal \"$NEXT_A\")" 2>&1)
if ! mdx_ok "$R"; then ok "a non-controller cannot call the op ($(echo "$R" | flat | grep -oiE '(not a canister controller|refused|reject)[^"]{0,40}' | head -1))"
else nok "a non-controller retired something" "$(echo "$R" | flat | head -c 200)"; fi
SROWS2=$(season_rows "$SA")
[ "$(printf '%s\n' "$SROWS2" | grep -c .)" = "$NROWS" ] && ok "every refusal left the registry alone ($NROWS row(s) still routed)" || nok "a refusal removed a row" "before=$NROWS after=$(printf '%s\n' "$SROWS2" | grep -c .)"
head_seq "$ACTIVE_A" | grep -q 'headSeq = opt' && ok "the tip still answers with its head (not deleted)" || nok "the tip no longer answers" "$(head_seq "$ACTIVE_A")"
head_seq "$SEALED_A" | grep -q 'headSeq = opt' && ok "the sealed segment still answers with its head (not deleted)" || nok "the sealed segment no longer answers" "$(head_seq "$SEALED_A")"
head_seq "$NEXT_A" | grep -q 'headSeq = null' && ok "the carried successor still answers (not deleted)" || nok "the successor no longer answers" "$(head_seq "$NEXT_A")"

echo "── §3 seed the pre-fix row: the successor registered as season $SA's { firstSeq 0; lastSeq null } ──"
R=$(adm setTestSeasonRow "(principal \"aaaaa-aa\", 0 : nat, null, $SA : nat)")
if ! mdx_ok "$R" && echo "$R" | flat | grep -qF "not an archive segment of this exchange"; then ok "the hook refuses a principal this exchange did not spawn"
else nok "the hook registered a foreign principal" "$(echo "$R" | flat | head -c 200)"; fi
R=$(adm setTestSeasonRow "(principal \"$NEXT_A\", 0 : nat, null, $SA : nat)")
if mdx_ok "$R"; then ok "setTestSeasonRow registered the successor as a season $SA row"; else nok "setTestSeasonRow refused" "$(echo "$R" | flat | head -c 200)"; fi
R=$(adm setTestSeasonRow "(principal \"$NEXT_A\", 0 : nat, null, $SA : nat)")
if ! mdx_ok "$R" && echo "$R" | flat | grep -qF "already a season registry row"; then ok "the hook refuses a duplicate row"
else nok "the hook registered the same canister twice" "$(echo "$R" | flat | head -c 200)"; fi
ROW=$(season_rows "$SA" | grep "\"$NEXT_A\"" | head -1)
if [ -n "$ROW" ] && echo "$ROW" | grep -qE 'firstSeq = 0[^0-9]' && echo "$ROW" | grep -q 'lastSeq = null'; then ok "getSeasonArchives($SA) now carries the pre-fix row: firstSeq 0, lastSeq null (\"0 – growing\")"
else nok "the seeded row does not read firstSeq 0 / lastSeq null" "$(echo "$ROW" | head -c 200)"; fi
chain_rows | grep "\"$NEXT_A\"" | grep -q 'role = "season"' && ok "getArchiveChain lists it as a \"season\" segment" || nok "getArchiveChain does not list the seeded row as a season segment" "$(chain_rows | grep "\"$NEXT_A\"" | head -c 200)"
[ -z "$(chain_cids_by_role next)" ] && ok "the hook cleared the chain's \"next\" pointer (the pre-fix registered-then-nulled shape)" || nok "the successor is still role \"next\" beside its season row" "$(chain_cids_by_role next)"
head_seq "$NEXT_A" | grep -q 'headSeq = null' && ok "the seeded row's canister holds no event (certified head empty)" || nok "seeded canister holds events" "$(head_seq "$NEXT_A")"
NROWS3=$(season_rows "$SA" | grep -c .)

echo "── §4 retire it: row gone from both tables, canister deleted, ring log + #config on the tape ──"
R=$(retire "$NEXT_A")
if mdx_ok "$R"; then ok "adminRetireEmptySeasonSegment($NEXT_A) #ok"; else nok "the op refused the empty successor row" "$(echo "$R" | flat | head -c 240)"; fi
SROWS4=$(season_rows "$SA")
printf '%s\n' "$SROWS4" | grep -q "\"$NEXT_A\"" && nok "the row is still in getSeasonArchives($SA)" "$(printf '%s\n' "$SROWS4" | grep "\"$NEXT_A\"" | head -c 200)" || ok "the row is gone from getSeasonArchives($SA)"
[ "$(printf '%s\n' "$SROWS4" | grep -c .)" = "$((NROWS3 - 1))" ] && ok "exactly one row left the registry ($NROWS3 → $((NROWS3 - 1)))" || nok "row count moved by more than one" "before=$NROWS3 after=$(printf '%s\n' "$SROWS4" | grep -c .)"
printf '%s\n' "$SROWS4" | grep -q "\"$ACTIVE_A\"" && printf '%s\n' "$SROWS4" | grep -q "\"$SEALED_A\"" && ok "the season's real segments (sealed + tip) are still routed" || nok "a real segment left the registry" "$(printf '%s\n' "$SROWS4" | row_cid | tr '\n' ' ')"
chain_rows | grep -q "\"$NEXT_A\"" && nok "getArchiveChain still lists the retired canister" "$(chain_rows | grep "\"$NEXT_A\"" | head -c 200)" || ok "the retired canister is off getArchiveChain (no more fuel, no more hop)"
GONE=$(arc "$NEXT_A" getCertifiedHead '()' --query | flat)
# A deleted canister is IC0301 / DestinationInvalid ("Canister <cid> not
# found") — asserted positively: an EMPTY reply would also lack a head.
if echo "$GONE" | grep -q 'headSeq'; then nok "the canister still answers getCertifiedHead — not deleted" "$(echo "$GONE" | head -c 200)"
elif echo "$GONE" | grep -qE 'IC0301|DestinationInvalid|not found'; then ok "the canister no longer exists — deleted ($(echo "$GONE" | grep -oE '(DestinationInvalid|IC0301|not found)' | head -1))"
else nok "the canister neither answers nor reads as deleted" "$(echo "$GONE" | head -c 200)"; fi
EV=$(events 120)
echo "$EV" | grep -qF "SEASON REGISTRY: retired empty successor row $NEXT_A" && ok "the ring log names the retired row" || nok "no 'SEASON REGISTRY: retired empty successor row <cid>' line" "$(echo "$EV" | grep -oE 'SEASON REGISTRY[^;]{0,120}' | head -2)"
echo "$EV" | grep -qF "SEASON REGISTRY: empty successor $NEXT_A stopped and deleted" && ok "the ring log records the stop + delete" || nok "no 'stopped and deleted' line" "$(echo "$EV" | grep -oE 'SEASON REGISTRY[^;]{0,120}' | head -3)"
# The #config event rides the durable tape: the new epoch's first ship
# spawns a fresh archive_0 (the carried successor is gone) and lands it.
drain || nok "the tape did not drain after the retirement" "unshipped"
ACTIVE_B=$(chain_cids_by_role active | head -1)
[ -n "$ACTIVE_B" ] && [ "$ACTIVE_B" != "$NEXT_A" ] && ok "the new epoch spawned a fresh archive_0 ($ACTIVE_B), not the retired canister" || nok "no fresh archive_0 after the retirement" "active=${ACTIVE_B:-none}"
FS=$(chain_rows | grep 'role = "active"' | grep -oE 'firstSeq = opt \([0-9]+' | grep -oE '[0-9]+$')
TAPE=$(arc "$ACTIVE_B" getEventsRange "(${FS:-0} : nat, 200 : nat)" --query | flat)
if echo "$TAPE" | grep -q 'config' && echo "$TAPE" | grep -qF 'setter = "adminRetireEmptySeasonSegment"' && echo "$TAPE" | grep -qF "$NEXT_A"; then ok "the tape carries #config { setter = adminRetireEmptySeasonSegment; value names $NEXT_A }"
else nok "no #config event for the retirement on the tape" "$(echo "$TAPE" | grep -oE 'config[^}]{0,160}' | head -2)"; fi

echo "── §5 not re-runnable: the retired principal is no row any more ──"
R=$(retire "$NEXT_A")
if ! mdx_ok "$R" && echo "$R" | flat | grep -qF "not a season registry row"; then ok "a second call refuses (no registry row) — nothing to touch"
else nok "a second call did not refuse" "$(echo "$R" | flat | head -c 200)"; fi

adm setTestArchiveCap '(null)' >/dev/null 2>&1
echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_retire_empty_season_segment ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_retire_empty_season_segment ($fail failed, $pass passed)${NC}"; exit 1
fi
