#!/bin/bash
# tests/test_season_seal.sh — the season boundary vs the Bridge pair and the
# sealing window (public issues #55 §55.2 and #54 §54.1, OhShii round 18).
#
#   §1 #55.2: with the setBridge OVERRIDE CLEARED (the deploy-injected env is
#      the only Bridge wiring — exactly the state every scripted venue is in,
#      since no shipped script calls setBridge), a Bridge deposit then
#      resetSeason wipes the Bridge's half of the pair. Red pre-fix: resetSeason
#      switched on the raw `_bridgePrincipal` and took `case null`, so the
#      W4-12 wipe fired only when an EARLIER suite happened to call setBridge
#      (test_w4_batch2 §4 was green by alphabetical order alone).
#   §2 #54.1 latch: while the sealing latch is held (setTestSeasonSealing) every
#      emitting entry path refuses with the sealing #err and the EXIT SET still
#      passes; releasing the latch restores the paths.
#   §3 #54.1 honest seal: with setTestSeasonSealRace armed, ONE event lands
#      inside the Bridge round-trip window (emitted from inside resetSeason,
#      past the latch by construction). The record must seal at the archive's
#      certified extent — finalEventSeq == the active archive's headSeq+1 and
#      chainHead == its certified headHash — and the landed event is dropped
#      and logged, never recorded then deleted unshipped.
#   §4 #55 (1788468754): the season §3 just CLOSED is verifiable in practice —
#      getSeasonArchives(N) routes its detached tip (which getArchives no longer
#      lists), and `scripts/verify_ledger.mjs --season N` walks the sealed chain
#      by that table, matching the walked head to the SeasonRecord's chainHead
#      and the tape's end to finalEventSeq - 1 (exit 0); `--season --last` is
#      refused (exit 2).
#   §5 1788731610 (operator decision B, 2026-11-01): a staged LP request
#      (depositLp / withdrawLp) caught by the seal is CANCELLED on the tape
#      through the TTL backstop's own body — reservation released, the owner's
#      #cancelled outcome, the public `vault` row, reason naming the seal — and
#      the wipe clears the ring log / outcome lists BEFORE that pass, so the
#      cancellations are what the new epoch opens with (pre-fix: a silent
#      clear). Latch: withdrawLp (an exit) is accepted under it and settles on
#      the next fresh mark once the window closes; depositLp still refuses.
#
# Needs #dev (three hooks + setAmmRefPrice). ⚠️ §1, §3 and §5 season-wipe the
# venue — reseed afterwards. Order-INDEPENDENT by construction: §1 clears the
# override itself; §5 runs LAST because its seal opens a fresh epoch that §3's
# certified-head arithmetic must not see.

set -u
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
# _lib.sh REDEFINES SCRIPT_DIR to the repo root (tests/..). Every path below
# hangs off ROOT so a `$SCRIPT_DIR/..` never silently points one level too
# high (that inert-guard shape hid the bot stopper AND §4's verifier run).
ROOT="$SCRIPT_DIR"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
adm()  { echo y | icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
u()    { echo y | icp canister call --candid "$MDX_CANDID" --identity ssl_u backend "$@" 2>&1; }
bu()   { echo y | icp canister call --identity ssl_u bridge "$@" 2>&1; }
flat() { tr -d '_\n' | tr -s ' '; }

[ "$(venue_posture)" = "dev" ] || skip_posture "test_season_seal" "setTestBridgeOverride / setTestSeasonSealing / setTestSeasonSealRace / setAmmRefPrice"

BRIDGE_ID=$(icp canister status bridge --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
[ -n "$BRIDGE_ID" ] || { echo "bridge canister not found — deploy it first"; exit 1; }

STOPPER="$ROOT/scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }
adm setTestTimersPaused '(false)' >/dev/null 2>&1   # the shipper must run: the seal gates need a drained tape

# Throwaway user: a FRESH principal each run keeps the Bridge ledger clean
# (mdx_identity_new deletes any leftover first and again on EXIT — tests/_lib.sh).
mdx_identity_new ssl_u; U=$(principal_of ssl_u)

# Drain the tape (semantic queue + ledger journal) so resetSeason's gates pass.
drain_tape() {
  for _ in $(seq 1 60); do
    INFO=$(adm getCanisterInfo '()' --query | tr -d '_')
    UNSH=$(echo "$INFO" | grep -oE "journalUnshipped = [0-9]+" | grep -oE "[0-9]+$")
    JP=$(echo "$INFO" | grep -oE "ledgerJournalPending = [0-9]+" | grep -oE "[0-9]+$")
    [ "${UNSH:-1}" = "0" ] && [ "${JP:-1}" = "0" ] && return 0
    adm adminForceShipTick '()' >/dev/null 2>&1
    sleep 2
  done
  return 1
}
# The venue's BTC mark: devSimulateDeposit values the deposit at the mark, so
# a wiped venue (an earlier reset) must be re-provisioned.
provision_mark() {
  adm setTestEmailBinding "(principal \"$U\", \"ssl${RANDOM}$$@example.com\")" >/dev/null 2>&1
  adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
  adm setAmmRefPrice '("BTC-ICPUSD", 10_000_000_000 : nat)' >/dev/null 2>&1
  adm requoteAmm '("BTC-ICPUSD")' >/dev/null 2>&1
}

echo "── §1 #55.2: the season wipe reaches the Bridge through the ENV wiring ──"
R=$(adm setTestBridgeOverride '(null)')
mdx_ok "$R" && ok "setBridge override cleared (env wiring is the only resolver)" || nok "hook refused" "$(echo "$R" | head -c 150)"
W=$(adm getBridgeWiring '()' --query | flat)
if echo "$W" | grep -q "override = null" && echo "$W" | grep -q "env = opt principal \"$BRIDGE_ID\""; then
  ok "getBridgeWiring: override null, env = the deployed bridge ($BRIDGE_ID)"
else nok "wiring not in the never-called-setBridge state" "$(echo "$W" | head -c 200)"; fi
provision_mark
R=$(bu devSimulateDeposit '("BTC", 100_000_000 : nat)')
mdx_ok "$R" && ok "pre-reset Bridge deposit admitted" || nok "admit failed" "$(echo "$R" | head -c 150)"
DEP=$(bu getMyDeposits '()' --query | flat)
if echo "$DEP" | grep -qE "pending = 100000000[^0-9]"; then ok "Bridge holds the deposit (pending = 1 BTC) before the boundary"
else nok "Bridge ledger empty before the reset — nothing to prove" "$(echo "$DEP" | head -c 200)"; fi
drain_tape || nok "tape did not drain" "gates would refuse"
R=$(adm resetSeason '()')
mdx_ok "$R" && ok "resetSeason #ok" || nok "resetSeason refused" "$(echo "$R" | head -c 200)"
DEP=$(bu getMyDeposits '()' --query | flat)
if echo "$DEP" | grep -qE "confirmed = 0[^0-9]" && echo "$DEP" | grep -qE "pending = 0[^0-9]"; then
  ok "Bridge half wiped through the env wiring (no setBridge ever called): confirmed 0, pending 0"
else nok "Bridge kept its half across the boundary (#55.2 — the W4-12 wipe took case null)" "$(echo "$DEP" | head -c 200)"; fi
INFO=$(adm getCanisterInfo '()' --query | flat)
echo "$INFO" | grep -q "seasonSealing = false" && ok "latch released after the wipe (getCanisterInfo seasonSealing = false)" \
  || nok "latch stranded after resetSeason" "$(echo "$INFO" | grep -oE 'seasonSealing = [a-z]+')"

echo "── §2 #54.1: under the latch, emitting entry paths refuse; the exit set passes ──"
provision_mark
adm setTestBalance "(principal \"$U\", \"ICPUSD\", $(e8 5000.0) : nat)" >/dev/null
R=$(adm setTestSeasonSealing '(true)')
mdx_ok "$R" && ok "latch held (setTestSeasonSealing true)" || nok "hook refused" "$(echo "$R" | head -c 150)"
INFO=$(adm getCanisterInfo '()' --query | flat)
echo "$INFO" | grep -q "seasonSealing = true" && ok "getCanisterInfo reports seasonSealing = true" || nok "telemetry missing" "$(echo "$INFO" | grep -oE 'seasonSealing = [a-z]+')"
R=$(u stakeInsurance "($(e8 100.0) : nat)")
echo "$R" | grep -q "sealing in progress" && ok "stakeInsurance refused with the sealing #err" || nok "stakeInsurance was NOT refused" "$(echo "$R" | head -c 150)"
R=$(u placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 90.0) : nat, $(e8 0.01) : nat)")
echo "$R" | grep -q "sealing in progress" && ok "placeLimitOrder refused with the sealing #err" || nok "placeLimitOrder was NOT refused" "$(echo "$R" | head -c 150)"
R=$(u depositLp "(\"BTC-ICPUSD\", 0 : nat, $(e8 100.0) : nat)")
echo "$R" | grep -q "sealing in progress" && ok "depositLp refused with the sealing #err" || nok "depositLp was NOT refused" "$(echo "$R" | head -c 150)"
R=$(u swap "(record { fromToken = \"ICPUSD\"; toToken = \"BTC\"; amount = $(e8 10.0) : nat; mode = variant { marketOrder = record { maxSlippage = 500 : nat } }; noPartialFill = false })")
echo "$R" | grep -q "sealing in progress" && ok "swap refused with the sealing #err" || nok "swap was NOT refused" "$(echo "$R" | head -c 150)"
R=$(u cancelAllMyOrders '(null)')
if echo "$R" | grep -q "sealing in progress"; then nok "cancelAllMyOrders (EXIT SET) was refused under the latch" "$(echo "$R" | head -c 150)"
elif echo "$R" | grep -qE "\(0 : nat\)|\([0-9_]+ : nat\)"; then ok "cancelAllMyOrders (exit set) passes the latch"
else nok "cancelAllMyOrders unexpected" "$(echo "$R" | head -c 150)"; fi
R=$(u unstakeInsurance '(0 : nat)')
if echo "$R" | grep -q "sealing in progress"; then nok "unstakeInsurance (EXIT SET) was refused under the latch" "$(echo "$R" | head -c 150)"
else ok "unstakeInsurance (exit set) reaches its own body under the latch ($(echo "$R" | grep -oE 'err = "[^"]{0,40}' | head -1))"; fi
R=$(adm setTestSeasonSealing '(false)')
mdx_ok "$R" && ok "latch released" || nok "hook refused" "$(echo "$R" | head -c 150)"
R=$(u stakeInsurance "($(e8 100.0) : nat)")
mdx_ok "$R" && ok "stakeInsurance #ok once the latch is released" || nok "stakeInsurance still refused" "$(echo "$R" | head -c 150)"

echo "── §3 #54.1: an event landing inside the window seals HONESTLY at the archive's extent ──"
drain_tape || nok "tape did not drain" "gates would refuse"
CHAIN=$(adm getArchiveChain '()' --query | flat)
ACTIVE=$(echo "$CHAIN" | tr '}' '\n' | grep 'role = "active"' | head -1 | grep -oE 'canisterId = "[a-z0-9-]+"' | grep -oE '"[^"]+"' | tr -d '"')
if [ -n "$ACTIVE" ]; then ok "active archive resolved: $ACTIVE"; else nok "no active archive in getArchiveChain" "$(echo "$CHAIN" | head -c 200)"; fi
HEAD=$(echo y | icp canister call --identity anonymous "$ACTIVE" getCertifiedHead '()' --query 2>&1 | flat)
HEAD_SEQ=$(echo "$HEAD" | grep -oE "headSeq = opt \([0-9]+" | grep -oE "[0-9]+$")
HEAD_HASH=$(echo "$HEAD" | grep -oE 'headHash = opt blob "[^"]*"' | sed 's/headHash = opt //')
EXPECT_FINAL=$(( ${HEAD_SEQ:-0} + 1 ))
[ -n "$HEAD_SEQ" ] && [ -n "$HEAD_HASH" ] && ok "archive certified head: seq $HEAD_SEQ (shipped extent = $EXPECT_FINAL)" \
  || nok "could not read the archive's certified head" "$(echo "$HEAD" | head -c 200)"
R=$(adm setTestSeasonSealRace '(true)')
mdx_ok "$R" && ok "in-window emit armed (setTestSeasonSealRace)" || nok "hook refused" "$(echo "$R" | head -c 150)"
R=$(adm resetSeason '()' | flat)
mdx_ok "$R" && ok "resetSeason #ok despite the landed event (the Bridge half was already wiped — no abort)" || nok "resetSeason refused" "$(echo "$R" | head -c 200)"
FINAL=$(echo "$R" | grep -oE "finalEventSeq = [0-9]+" | grep -oE "[0-9]+$")
REC_HASH=$(echo "$R" | grep -oE 'chainHead = opt blob "[^"]*"' | sed 's/chainHead = opt //')
if [ "${FINAL:-x}" = "$EXPECT_FINAL" ]; then ok "rec.finalEventSeq == shipped extent ($FINAL) — the landed event was NOT recorded"
else nok "rec.finalEventSeq = ${FINAL:-?} but the archive's extent is $EXPECT_FINAL (naive seal would read $((EXPECT_FINAL+1)))" "$(echo "$R" | head -c 200)"; fi
if [ -n "$REC_HASH" ] && [ "$REC_HASH" = "$HEAD_HASH" ]; then ok "rec.chainHead == the archive's certified headHash"
else nok "rec.chainHead does not match the archive's certified head" "rec=$(echo "$REC_HASH" | head -c 60) archive=$(echo "$HEAD_HASH" | head -c 60)"; fi
LOG=$(adm getRecentEvents '(60 : nat)' --query | flat)
if echo "$LOG" | grep -q "Season seal re-check FAILED" && echo "$LOG" | grep -q "1 event(s)"; then
  ok "operator log records the dropped in-window event (re-check FAILED, 1 event(s))"
else nok "no honest-seal log line" "$(echo "$LOG" | grep -oE 'Season seal[^"]{0,120}' | head -1)"; fi
SR=$(adm getSeasonRecords '()' --query | flat)
LASTF=$(echo "$SR" | grep -oE "finalEventSeq = [0-9]+" | tail -1 | grep -oE "[0-9]+$")
[ "${LASTF:-x}" = "$EXPECT_FINAL" ] && ok "getSeasonRecords carries the honest extent ($LASTF)" || nok "season record extent wrong" "got ${LASTF:-?} want $EXPECT_FINAL"

echo "── §4 #55 (1788468754): the closed season walks by getSeasonArchives and anchors to its record ──"
SEASON_NO=$(echo "$R" | grep -oE "season = [0-9]+" | head -1 | grep -oE "[0-9]+$")
[ -n "$SEASON_NO" ] && ok "closed season number from the record: $SEASON_NO" || nok "no season number in the resetSeason result" "$(echo "$R" | head -c 200)"
TABLE=$(adm getSeasonArchives "(${SEASON_NO:-0} : nat)" --query | flat)
if echo "$TABLE" | grep -q "canisterId = \"$ACTIVE\""; then ok "getSeasonArchives($SEASON_NO) routes the detached tip $ACTIVE"
else nok "the closed season's tip is not on its season table" "$(echo "$TABLE" | head -c 200)"; fi
LIVE=$(adm getArchives '()' --query | flat)
if echo "$LIVE" | grep -q "canisterId = \"$ACTIVE\""; then nok "the closed tip still sits on the LIVE routing table" "$(echo "$LIVE" | head -c 200)"
else ok "getArchives no longer lists $ACTIVE (the live table serves the current season only)"; fi
API_URL=$(icp network status 2>/dev/null | sed -n 's/^Api Url: //p' | head -1); API_URL=${API_URL%/}
BACKEND_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["backend"])' "$ROOT/.icp/cache/mappings/local.ids.json" 2>/dev/null)
if [ -n "$API_URL" ] && [ -n "$BACKEND_ID" ] && [ -n "$SEASON_NO" ]; then
  VOUT=$(cd "$ROOT" && node scripts/verify_ledger.mjs --backend "$BACKEND_ID" --host "$API_URL" --season "$SEASON_NO" 2>&1); VRC=$?
  if [ "$VRC" = "0" ] && echo "$VOUT" | grep -q "season $SEASON_NO anchored" && echo "$VOUT" | grep -q "chain links verified"; then
    ok "verify_ledger.mjs --season $SEASON_NO: exit 0 — $(echo "$VOUT" | grep -oE '[0-9,]+ chain links verified' | tail -1), walked head == SeasonRecord.chainHead, tape ends at finalEventSeq - 1"
  else nok "verify_ledger.mjs --season $SEASON_NO refused the honest sealed season" "rc=$VRC $(echo "$VOUT" | grep -E '✗|season' | tail -2 | tr '\n' ' ')"; fi
  if echo "$VOUT" | grep -q "last seq $((EXPECT_FINAL - 1)) == finalEventSeq $EXPECT_FINAL - 1"; then
    ok "the verifier's anchor line names the honest extent (last seq $((EXPECT_FINAL - 1)), finalEventSeq $EXPECT_FINAL)"
  else nok "anchor line does not carry the §3 extent" "$(echo "$VOUT" | grep -E 'anchored' | tail -1)"; fi
  VOUT2=$(cd "$ROOT" && node scripts/verify_ledger.mjs --backend "$BACKEND_ID" --host "$API_URL" --season "$SEASON_NO" --last 3 2>&1); VRC2=$?
  if [ "$VRC2" = "2" ] && echo "$VOUT2" | grep -q -- "drop --last"; then ok "--season with --last: exit 2 (a sealed season is walked in full)"
  else nok "--season --last not refused" "rc=$VRC2 $(echo "$VOUT2" | tail -1)"; fi
else nok "§4 verifier run could not resolve its inputs" "api=[$API_URL] backend=[$BACKEND_ID] season=[$SEASON_NO]"; fi

echo "── §5 1788731610 (operator decision B): the seal CANCELS pending staged LP requests on the tape; withdrawals stay exempt from the latch ──"
# A staged LP request (depositLp / withdrawLp — docs/amm-vault-design.md §5
# "Sealed LP requests") reserves its legs or shares and settles at the first
# mark that postdates it. Caught by a season boundary it is CANCELLED through
# the TTL backstop's own body (cancelStagedLp): reservation released, the
# owner's #cancelled outcome, the public `vault` tape row — reason naming the
# seal — and performWorldWipe clears the ring log / outcome lists BEFORE that
# pass, so the cancellations are what the new epoch opens with (resetSeason's
# own "Season N closed" line follows the same rule). Pre-fix the wipe simply
# cleared the store and the reservations: the request vanished without a
# trace. Latch (#54.1): withdrawLp is an EXIT and passes; depositLp refuses.
#
# Fixture physics: the vault must HOLD a priced leg so every request waits on
# a mark (BTC-ICPUSD). The mark is pinned AT the live aggregate (mdx_pin_mark)
# so the running feed never pends it, and the balance-moving work (genesis
# mint, the latch-window redemption) runs with the timers ON — the ledger
# journal drains only from the heartbeat, and the seal gates on it. The two
# requests that must be PENDING at the seal are staged with the timers PAUSED
# (staging moves no balance — reservations only — so nothing new lands on the
# journal) and the seal follows at once. Runs LAST (see the header).
adm setTestTimersPaused '(false)' >/dev/null 2>&1
on_exit "echo y | icp canister call --identity anonymous backend setTestTimersPaused '(false)' >/dev/null 2>&1"
lp5()   { u getMyVaultLp '()' --query | tr -d '_' | grep -oE '[0-9]+' | head -1; }
rsv5()  { u getMyReservedBalance '("ICPUSD")' --query | tr -d '_' | grep -oE '[0-9]+' | head -1; }
pend5() { mdx_lp_view ssl_u | grep -oE 'waitingOn' | wc -l | tr -d ' '; }   # pending records carry waitingOn; outcomes do not
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
PIN5=$(mdx_pin_mark BTC BTC-ICPUSD "$(e8 50000.0)")
MARK5=${PIN5%% *}
if [ -n "$MARK5" ] && [ "$MARK5" -gt 0 ] 2>/dev/null; then ok "BTC-ICPUSD re-provisioned after §3's wipe, mark pinned at the live aggregate (\$$(from_e8 "$MARK5"), source ${PIN5#* })"; else nok "could not pin the BTC mark" "$PIN5"; fi
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1   # hygiene §6ab: a created pool that takes a base-leg mint must be enabled, or its mark freezes and every LP mint pauses 60 s later
adm requoteAmm '("BTC-ICPUSD")' >/dev/null 2>&1
adm setAutoFuel '(false)' >/dev/null 2>&1
adm setTestBalance "(principal \"$U\", \"BTC\", $(e8 1.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$U\", \"ICPUSD\", $(e8 10000.0) : nat)" >/dev/null
G5=$(mdx_lp_deposit ssl_u BTC-ICPUSD "$(e8 0.02)" "$(e8 1000.0)" 9); G5RC=$?
if [ "$G5RC" = "0" ] && [ "${G5:-0}" -gt 0 ] 2>/dev/null; then ok "fixture: ssl_u minted $(from_e8 "$G5") LP through the staged door (0.02 BTC + \$1,000) — the vault now HOLDS a BTC leg, so every later request waits on BTC-ICPUSD"; else nok "fixture genesis deposit did not settle" "rc=$G5RC $(echo "$G5" | head -c 200)"; fi

# (3) + (2): under the latch a staged ENTRY refuses; a staged EXIT is accepted and settles on the next fresh mark once the window closes.
R=$(adm setTestSeasonSealing '(true)')
mdx_ok "$R" && ok "latch held (setTestSeasonSealing true)" || nok "hook refused" "$(echo "$R" | head -c 150)"
R=$(u depositLp "(\"BTC-ICPUSD\", 0 : nat, $(e8 100.0) : nat)")
echo "$R" | grep -q "sealing in progress" && ok "(3) depositLp — a staged ENTRY — refused under the latch with the sealing #err" || nok "depositLp was NOT refused under the latch" "$(echo "$R" | head -c 150)"
LPALL5=$(lp5); PART5=$(( ${LPALL5:-0} / 4 ))
W5=$(u withdrawLp "($PART5 : nat)"); WID5=$(mdx_lp_reqid "$W5")
if mdx_ok "$W5" && [ -n "$WID5" ]; then ok "(2) withdrawLp — an EXIT — ACCEPTED under the latch: request #$WID5 for $(from_e8 "$PART5") LP"; else nok "withdrawLp refused under the latch" "$(echo "$W5" | head -c 200)"; fi
echo "$W5" | tr -d '\n' | tr -s ' ' | grep -q 'waitingOn = vec { "BTC-ICPUSD" }' && ok "...waiting on the held leg's market (BTC-ICPUSD): the timers are held under the latch, so nothing settles inside the window" || nok "waitingOn" "$(echo "$W5" | tr -d '\n' | tr -s ' ' | head -c 200)"
R=$(adm setTestSeasonSealing '(false)')
mdx_ok "$R" && ok "latch released — the window closed WITHOUT a seal (the abort arm's shape)" || nok "hook refused" "$(echo "$R" | head -c 150)"
O5=$(mdx_lp_settle ssl_u "$WID5" "$W5" "BTC-ICPUSD" 9); O5RC=$?
if [ "$O5RC" = "0" ] && echo "$O5" | grep -q 'redeemed = record'; then ok "(2) the next fresh mark SETTLES it: #$WID5 redeemed in kind (not refused, not cancelled)"; else nok "the withdrawal staged under the latch did not settle on the fresh mark" "rc=$O5RC $(echo "$O5" | head -c 200)"; fi

# (1) PENDING at the seal: a staged deposit AND a staged withdrawal, timers paused so no mark postdates them.
drain_tape || nok "tape did not drain before the seal" "gates would refuse"
adm setTestTimersPaused '(true)' >/dev/null 2>&1
LPLEFT5=$(lp5)
D5=$(u depositLp "(\"BTC-ICPUSD\", 0 : nat, $(e8 1000.0) : nat)"); DID5=$(mdx_lp_reqid "$D5")
W5b=$(u withdrawLp "(${LPLEFT5:-0} : nat)"); WID5b=$(mdx_lp_reqid "$W5b")
if mdx_ok "$D5" && mdx_ok "$W5b" && [ -n "$DID5" ] && [ -n "$WID5b" ]; then ok "staged a \$1,000 deposit (#$DID5) and a $(from_e8 "${LPLEFT5:-0}") LP withdrawal (#$WID5b) with the timers paused — both wait on BTC-ICPUSD"; else nok "could not stage the pair" "$(echo "$D5" | head -c 120) :: $(echo "$W5b" | head -c 120)"; fi
adm adminRunStagedLp '()' >/dev/null 2>&1
[ "$(pend5)" = "2" ] && ok "both still PENDING through a pass (no mark postdates them)" || nok "a request settled or vanished before the seal" "$(mdx_lp_view ssl_u | head -c 300)"
[ "$(rsv5)" = "$(e8 1000.0)" ] && ok "the deposit's \$1,000 leg is RESERVED (getMyReservedBalance)" || nok "reservation before the seal" "$(rsv5)"
seal5() {  # the seal; on an 'unshipped' refusal (rows landed between the drain and the pause) let the beat drain, re-pause, retry
  local i r
  for i in 1 2 3; do
    r=$(adm resetSeason '()' | flat)
    if mdx_ok "$r"; then printf '%s' "$r"; return 0; fi
    echo "$r" | grep -q "unshipped" || break
    adm setTestTimersPaused '(false)' >/dev/null 2>&1; drain_tape || true; adm setTestTimersPaused '(true)' >/dev/null 2>&1
  done
  printf '%s' "$r"; return 1
}
R5=$(seal5)
mdx_ok "$R5" && ok "resetSeason #ok with two staged LP requests pending — the seal did NOT wait on them" || nok "resetSeason refused" "$(echo "$R5" | head -c 200)"
adm setTestTimersPaused '(false)' >/dev/null 2>&1
EV5=$(adm getRecentEvents '(100 : nat)' --query | tr -d '\n' | tr -s ' ')
echo "$EV5" | grep -q "staged LP deposit #${DID5:-x} cancelled — season sealed before settlement; nothing settled, funds released" && ok "(1) the deposit's cancellation is on the tape AFTER the seal, naming it (getRecentEvents, category vault)" || nok "no post-seal tape row for the deposit's cancellation" "$(echo "$EV5" | grep -oE 'staged LP[^"]{0,110}' | head -3 | tr '\n' '|')"
echo "$EV5" | grep -q "staged LP withdrawal #${WID5b:-x} cancelled — season sealed before settlement; nothing settled, funds released" && ok "(1) the withdrawal's cancellation is on the tape AFTER the seal, naming it" || nok "no post-seal tape row for the withdrawal's cancellation" "$(echo "$EV5" | grep -oE 'staged LP[^"]{0,110}' | head -3 | tr '\n' '|')"
V5=$(mdx_lp_view ssl_u)
echo "$V5" | grep -q 'pending = vec {}' && ok "getMyStagedLpRequests: pending EMPTY after the seal — gone from the live store, exactly as after a TTL cancel" || nok "pending not empty after the seal" "$(echo "$V5" | head -c 300)"
C5=$(echo "$V5" | grep -oE 'cancelled = "season sealed before settlement; nothing settled, funds released"' | wc -l | tr -d ' ')
[ "$C5" = "2" ] && ok "...and recent carries BOTH as #cancelled(\"season sealed before settlement; nothing settled, funds released\") — the TTL cancel's own shape, no third one" || nok "recent does not carry the two seal cancellations" "$(echo "$V5" | head -c 400)"
if echo "$V5" | grep -qE 'minted = |redeemed = '; then nok "the closed season's settled outcomes survived the wipe" "$(echo "$V5" | head -c 300)"; else ok "the closed season's settled outcomes (the genesis mint, the (2) redemption) are gone: the new epoch's recent holds only the boundary's verdicts"; fi
[ "$(rsv5)" = "0" ] && ok "reservation released: getMyReservedBalance(ICPUSD) = 0 after the seal" || nok "reservation stranded" "$(rsv5)"
[ "$(lp5)" = "0" ] && ok "LP at zero after the boundary (as before)" || nok "LP survived the boundary" "$(lp5)"
BAL5=$(adm getTestBalance "(principal \"$U\", \"ICPUSD\")" --query | tr -d '_' | grep -oE '[0-9]+' | head -1)
[ "${BAL5:-x}" = "0" ] && ok "wallet at zero after the boundary (as before — nothing of value was lost to the cancel)" || nok "wallet not zero" "${BAL5:-?}"
INFO=$(adm getCanisterInfo '()' --query | flat)
echo "$INFO" | grep -q "seasonSealing = false" && ok "latch released after the wipe (getCanisterInfo seasonSealing = false)" || nok "latch stranded" "$(echo "$INFO" | grep -oE 'seasonSealing = [a-z]+')"

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_season_seal ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_season_seal ($fail failed, $pass passed)${NC}"; exit 1
fi
