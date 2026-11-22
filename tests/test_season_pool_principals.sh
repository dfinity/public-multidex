#!/bin/bash
# tests/test_season_pool_principals.sh — pool principals are unique for the
# lifetime of the archive set, and season-archive federation passes only the
# pools the caller owned IN THAT SEASON (H-29 / F45, task 1788467626).
#
# MarginPools.poolPrincipal is a pure function of the pool id, and every
# archive segment indexes ledger rows (#delta / #debtDelta) by that principal
# forever. performWorldWipe used to restart nextPoolId at 1, so the next
# epoch's pool #k wore the prior season's pool #k principal — and
# getMyArchivedEvents / archiveExecute, which built the caller's principal
# set from the CURRENT registry, handed the new owner the old owner's rows
# through the season federation (while the old owner, registry-less after
# the wipe, lost them).
#
#   §1 season N: A creates + funds a pool (id KA, principal PA); its #delta
#      rows are archived and A reads them through the current chain
#   §2 resetSeason: season N's segments are registered under N
#   §3 fix 1 — B's first pool of season N+1 gets id KB > KA (pre-fix: KB = 1)
#      and a principal PB ≠ PA
#   §4 fix 1 — B reads NOTHING of season N through getMyArchivedEvents
#      (pre-fix: PB = poolPrincipal(1) → pool #1's season-N rows, total > 0)
#   §5 fix 2 — A, the recorded owner, STILL reads PA's season-N rows
#      (pre-fix: the wipe emptied the registry, so A got human rows only)
#   §6 both, via archiveExecute (the OQL walk spans the season registry):
#      B's rows carry no PA; A's rows carry PA
#   §7 adjacent: A's NEW pool of season N+1 (PA2) is indexed in no season-N
#      segment — A's season-N read carries PA, never PA2
#
# Needs #dev (setTestBalance, setTestArchiveMaxHops, resetSeason's posture).
# ⚠️ Runs resetSeason ONCE — wallets zeroed, archives detached; reseed after.
# Order-independent: the season number is read from getSeasonRecords.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # mdx_ok — the only sanctioned #ok oracle; this suite keeps its own ok/nok frame
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
adm()  { echo y | icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
usr()  { local id="$1"; shift; echo y | icp canister call --candid "$MDX_CANDID" --identity "$id" backend "$@" 2>&1; }
flat() { tr -d '_\n' | tr -s ' '; }

[ "$(venue_posture)" = "dev" ] || skip_posture "test_season_pool_principals" "setTestBalance / setTestArchiveMaxHops / resetSeason (#dev backend)"

# The sim must be dead (it would inject noise). PID-file stopper — NEVER a
# pattern kill (scripts/lib/bots.sh; the live fleet went down three times).
STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }
adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true   # the shipper must run
# The OQL walk must reach season N's segments past whatever the venue's
# registry already holds (each closed season adds its segments in front).
adm setTestArchiveMaxHops '(opt (60 : nat))' >/dev/null 2>&1 || true
on_exit "call setTestArchiveMaxHops '(null)' >/dev/null 2>&1 || true"

# Per-run identity names (belt) on top of mdx_identity_new (braces, tests/_lib.sh:
# delete-first so a leftover name cannot hand back a previous run's principal,
# and the delete registered on_exit): §4 below asserts a VIRGIN principal, and
# a persisted identity would walk in wearing the previous run's season history.
IDA="spp_a_$$"; IDB="spp_b_$$"
mdx_identity_new "$IDA"; A=$(principal_of "$IDA")
mdx_identity_new "$IDB"; B=$(principal_of "$IDB")
[ -n "$A" ] && [ -n "$B" ] || { echo "could not mint the test identities"; exit 1; }

# ── helpers ────────────────────────────────────────────────────────
rows() { flat | sed 's/record {/\nrecord {/g' | grep 'canisterId'; }
row_cid() { grep -oE 'canisterId = "[a-z0-9-]+"' | grep -oE '"[^"]+"' | tr -d '"'; }
chain_cids() { adm getArchives '()' --query | rows | row_cid; }                # the CURRENT chain (sealed + active)
season_cids() { adm getSeasonArchives "($1 : nat)" --query | rows | row_cid; } # a closed season's segments
pool_id() { tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1; }
pool_principal() {  # $1 identity, $2 pool id → the pool's principal text (getMyMarginPools row keyed by id)
  usr "$1" getMyMarginPools '()' --query | flat | sed 's/record {/\nrecord {/g' | grep -E "id = $2[^0-9]" | grep -oE '"?principal"? = "[a-z0-9-]+"' | grep -oE '= "[^"]+"' | tr -d '=" ' | head -1
}
# getMyArchivedEvents over a SET of segments, as $1: prints "<total> <rows-for-principal-$3>"
mine_in() {  # $1 identity, $2 cids (newline list), $3 principal to count
  local tot=0 hits=0 cid out t h
  for cid in $2; do
    out=$(usr "$1" getMyArchivedEvents "(principal \"$cid\", 0 : nat, 200 : nat)" --query | flat)
    t=$(echo "$out" | grep -oE 'total = [0-9]+' | grep -oE '[0-9]+' | head -1)
    h=$(echo "$out" | sed 's/record {/\nrecord {/g' | grep -c "user = principal \"$3\"")
    tot=$((tot + ${t:-0})); hits=$((hits + h))
  done
  echo "$tot $hits"
}
# archiveExecute via an args file, so the shell cannot mangle the JSON.
hist() {  # $1 identity
  local args; args=$(scratch_new spp.did) || exit 1
  printf '("%s")' '{\"start\":\"userEvent\",\"limit\":200}' > "$args" || { echo "cannot write the args file $args" >&2; exit 1; }
  icp canister call --candid "$MDX_CANDID" --args-file "$args" backend archiveExecute --query --identity "$1" 2>&1
}
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

N0=$(adm getSeasonRecords '()' --query | flat | grep -oE 'season = [0-9]+' | grep -c .)
SN=$((N0 + 1))
echo "   (venue holds $N0 season record(s); this run closes season $SN)"

echo "── §1 season $SN: A owns pool KA (principal PA); its rows are archived ──"
adm setTestBalance "(principal \"$A\", \"ICPUSD\", 100_000_000_000 : nat)" >/dev/null
KA=$(usr "$IDA" createMarginPool '("h29 season-N pool", false)' | pool_id)
[ -n "$KA" ] && ok "A created pool #$KA in season $SN" || { nok "createMarginPool (A) failed" "?"; KA=0; }
PA=$(pool_principal "$IDA" "$KA")
[ -n "$PA" ] && ok "pool #$KA's principal: $PA" || nok "getMyMarginPools shows no principal for pool #$KA" "?"
F=$(usr "$IDA" fundMarginPool "($KA : nat, 50_000_000_000 : nat)")
mdx_ok "$F" && ok "A funded pool #$KA (a #delta row under PA)" || nok "fundMarginPool" "$(echo "$F" | flat | head -c 200)"
usr "$IDA" withdrawMarginPool "($KA : nat, 10_000_000_000 : nat)" >/dev/null 2>&1   # a second PA row, for good measure
drain && ok "season $SN tape drained to the archive" || nok "tape did not drain" "unshipped=${UNSH:-?} journal=${JP:-?}"
CHAIN_N=$(chain_cids)
[ -n "$CHAIN_N" ] && ok "season $SN has $(printf '%s\n' "$CHAIN_N" | grep -c .) event-bearing segment(s)" || nok "no archive segment after the drain" "$(adm getArchives '()' --query | flat | head -c 200)"
read -r TOT HITS <<< "$(mine_in "$IDA" "$CHAIN_N" "$PA")"
[ "${HITS:-0}" -ge 1 ] && ok "A reads PA's rows through the current chain ($HITS row(s) under PA, total $TOT)" || nok "A sees no PA row before the boundary (control)" "total=$TOT"

echo "── §2 close season $SN ──"
R=$(adm resetSeason '()')
mdx_ok "$R" && ok "resetSeason #ok (season $SN)" || nok "resetSeason refused" "$(echo "$R" | flat | head -c 200)"
SEASON_N=$(season_cids "$SN")
[ -n "$SEASON_N" ] && ok "getSeasonArchives($SN) routes $(printf '%s\n' "$SEASON_N" | grep -c .) segment(s)" || nok "season $SN has no registered segment" "$(adm getSeasonArchives "($SN : nat)" --query | flat | head -c 200)"

echo "── §3 fix 1: pool ids never restart — B's first pool of season $((SN+1)) is #(KA+n), not #1 ──"
adm setTestBalance "(principal \"$B\", \"ICPUSD\", 100_000_000_000 : nat)" >/dev/null
KB=$(usr "$IDB" createMarginPool '("h29 season-N+1 pool", false)' | pool_id)
[ -n "$KB" ] && ok "B created pool #$KB in season $((SN+1))" || { nok "createMarginPool (B) failed" "?"; KB=0; }
[ "${KB:-0}" -gt "${KA:-0}" ] && ok "pool id is monotone across the boundary (#$KB > #$KA)" || nok "pool id RECYCLED across the season boundary" "season $SN's #$KA, season $((SN+1))'s #$KB (pre-fix: nextPoolId := 1)"
PB=$(pool_principal "$IDB" "$KB")
[ -n "$PB" ] && [ "$PB" != "$PA" ] && ok "B's pool principal differs from PA ($PB)" || nok "B's pool wears a season-$SN principal" "PB=${PB:-?} PA=$PA"
usr "$IDB" fundMarginPool "($KB : nat, 20_000_000_000 : nat)" >/dev/null 2>&1
drain >/dev/null 2>&1 || true

echo "── §4 fix 1: B reads nothing of season $SN ──"
read -r TOT HITS <<< "$(mine_in "$IDB" "$SEASON_N" "$PA")"
[ "${HITS:-0}" = "0" ] && ok "no PA row reaches B through season $SN's segments" || nok "B reads the PRIOR owner's pool rows" "$HITS row(s) under PA"
[ "${TOT:-0}" = "0" ] && ok "B's season-$SN history is empty (total 0 — a virgin identity in that season)" || nok "B has season-$SN history it never made" "total=$TOT"

echo "── §5 fix 2: A, the recorded owner, still reads PA's season-$SN rows ──"
read -r TOT HITS <<< "$(mine_in "$IDA" "$SEASON_N" "$PA")"
[ "${HITS:-0}" -ge 1 ] && ok "A reads $HITS row(s) under PA from season $SN (frozen owner map)" || nok "A lost PA's rows at the boundary" "total=$TOT — pre-fix: the wipe emptied the registry, so A federated the human principal only"

echo "── §6 archiveExecute agrees: the OQL walk federates per season ──"
RB=$(hist "$IDB" | flat)
echo "$RB" | grep -q 'name = "seq"' && ok "archiveExecute (B) answered with rows" || nok "archiveExecute (B) returned no rows" "$(echo "$RB" | head -c 200)"
echo "$RB" | grep -q "$PA" && nok "B's archiveExecute rows carry PA (the prior owner's pool)" "$(echo "$RB" | grep -o "[^{]*$PA[^}]*" | head -c 200)" || ok "B's archiveExecute rows never mention PA"
RA=$(hist "$IDA" | flat)
echo "$RA" | grep -q "$PA" && ok "A's archiveExecute rows carry PA (season $SN, via the frozen owner map)" || nok "A's archiveExecute rows lack PA" "$(echo "$RA" | head -c 200)"
echo "$RA" | grep -q 'unvisited = vec {}' && ok "A's walk reached every segment (unvisited = vec {})" || nok "A's walk stopped short (raise the hop pin?)" "$(echo "$RA" | grep -oE 'unvisited = vec \{[^}]*\}' | head -c 200)"

echo "── §7 adjacent: A's NEW pool of season $((SN+1)) is indexed in no season-$SN segment ──"
adm setTestBalance "(principal \"$A\", \"ICPUSD\", 100_000_000_000 : nat)" >/dev/null   # the season wipe zeroed the wallet
KA2=$(usr "$IDA" createMarginPool '("h29 season-N+1 pool (A)", false)' | pool_id)
PA2=$(pool_principal "$IDA" "${KA2:-0}")
[ -n "$PA2" ] && [ "$PA2" != "$PA" ] && ok "A's new pool #$KA2 has a fresh principal ($PA2)" || nok "A's new pool principal collides" "PA2=${PA2:-?}"
usr "$IDA" fundMarginPool "(${KA2:-0} : nat, 20_000_000_000 : nat)" >/dev/null 2>&1
drain >/dev/null 2>&1 || true
read -r TOT HITS <<< "$(mine_in "$IDA" "$SEASON_N" "$PA2")"
[ "${HITS:-0}" = "0" ] && ok "season $SN's segments carry no row under PA2" || nok "a season-$((SN+1)) pool principal is indexed in season $SN" "$HITS row(s)"
read -r TOT HITS <<< "$(mine_in "$IDA" "$SEASON_N" "$PA")"
[ "${HITS:-0}" -ge 1 ] && ok "...while PA's rows are still A's ($HITS)" || nok "PA's rows vanished after A made a new pool" "total=$TOT"

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_season_pool_principals ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_season_pool_principals ($fail failed, $pass passed)${NC}"; exit 1
fi
