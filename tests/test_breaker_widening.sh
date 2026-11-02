#!/bin/bash
# Breaker widening (docs/amm-vault-design.md §3): while the price-jump circuit
# breaker holds a PENDING candidate, the AMM must widen its half-spread by the
# full proposed gap IMMEDIATELY — a frozen mark with tight quotes is a free
# option during real gap moves (staleness widening alone waits out its 60s
# grace, because a pend does not advance refPriceUpdatedNs). Also locks in:
#
#   • the LP-deposit gate refuses to mint while a HELD leg has a pend — held
#     meaning LP-tracked holdings (a genesis / unheld-leg deposit still mints,
#     so seeding never wedges on a breaker tick; §2 pins both shapes),
#   • a direct (dev) price set CLEARS the pend and quotes snap back to normal
#     (the regression that once left tests quoting ±28% around a live-feed
#     pend that survived resetExchange).
#
# Uses the dev-only setTestPendingJump hook; needs a #dev backend.
# ⚠️ Calls resetExchange — at entry AND at exit: the vault is funded under
# bw_lp, a throwaway identity mdx_identity_new deletes at the end of the run,
# so an un-wiped exit strands an LP supply (~2.23e12) no successor can sum —
# _lib.sh's I1 read "got 0.0" in test_liq_direction after this suite (task
# 1788523488) — and leaves no SOL pool behind. The fixture-hygiene rule
# (_lib.sh assert_invariants I1): fund the vault under ad-hoc identities →
# resetExchange at exit. on_exit so a mid-suite exit cleans up too; the pend
# is cleared and timers resume in the same hook.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

MKT="ICP-ICPUSD"
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }
adm()  { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
u()    { icp canister call --candid "$MDX_CANDID" --identity bw_lp backend "$@" 2>&1; }

best() {  # best <asks|bids> → human price of the top level ("" if none)
  local side="$1" v
  if [ "$side" = "asks" ]; then
    v=$(adm getOrderBookDepth "(\"$MKT\", opt 3)" | tr -d '_' | awk '/asks = vec {/,/bids =/' | grep -oE "price = [0-9]+" | head -1 | grep -oE "[0-9]+")
  else
    v=$(adm getOrderBookDepth "(\"$MKT\", opt 3)" | tr -d '_' | awk '/bids = vec {/,/spread =|}$/' | grep -oE "price = [0-9]+" | head -1 | grep -oE "[0-9]+")
  fi
  [ -n "$v" ] && from_e8 "$v"
}
lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a <  b ? 0 : 1)}'; }
gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit (a >  b ? 0 : 1)}'; }

mdx_identity_new bw_lp; LP=$(principal_of bw_lp)
on_exit "adm setTestPendingJump '(\"ICP\", null, null)' >/dev/null 2>&1 || true; adm resetExchange '()' >/dev/null 2>&1 || true; adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true"

# ── Setup: quoted pool at mark $10 ─────────────────────────────────
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
adm createAmmPool "(\"$MKT\")" >/dev/null 2>&1
adm setAmmConfig "(\"$MKT\", 20:nat, $(e8 50.0):nat, 3:nat, 15:nat)" >/dev/null
adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null
AMM=$(adm getAmmPrincipal '()' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
adm setTestBalance "(principal \"$AMM\", \"ICP\", $(e8 1000.0):nat)" >/dev/null
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 20000.0):nat)" >/dev/null
adm setTestBalance "(principal \"$LP\", \"ICP\", $(e8 500.0):nat)" >/dev/null
adm setTestBalance "(principal \"$LP\", \"ICPUSD\", $(e8 50000.0):nat)" >/dev/null
adm enableAmm "(\"$MKT\", true)" >/dev/null
adm requoteAmm "(\"$MKT\")" >/dev/null

A0=$(best asks); B0=$(best bids)
echo "── baseline: ask=$A0 bid=$B0 (mark 10.00, half-spread 20bp) ──"
if [ -n "$A0" ] && lt "$A0" "10.1" && gt "${B0:-0}" "9.9"; then
  ok "baseline quotes tight around the mark ($B0 / $A0)"
else nok "baseline should quote ±20bp" "ask=$A0 bid=$B0"; fi

# ── 1. Pend a +10% jump → both sides widen by ≥ the gap ────────────
echo ""
echo "── 1. pending +10% jump → ladder spans the proposed gap immediately ──"
adm setTestPendingJump "(\"ICP\", opt ($(e8 11.0):nat), null)" >/dev/null
adm requoteAmm "(\"$MKT\")" >/dev/null
A1=$(best asks); B1=$(best bids)
echo "   widened: ask=${A1:-none} bid=${B1:-none}"
# Half-spread ≥ gap (1000bp) + base 20bp → ask ≥ 11.0, bid ≤ 9.0 (about the
# proposed price on the up side; symmetric down — we don't know the direction).
if [ -n "${A1:-}" ] && gt "$A1" "10.9"; then ok "ask widened past the pending price (≥ ~11.0)"; else nok "ask should span the gap" "ask=${A1:-none}"; fi
if [ -n "${B1:-}" ] && lt "$B1" "9.1"; then ok "bid widened symmetrically (≤ ~9.0)"; else nok "bid should widen too" "bid=${B1:-none}"; fi

# Event log records the engage edge.
EV=$(adm getRecentEvents '(10)' | grep -c "jump pending confirmation" || true)
if [ "${EV:-0}" -ge 1 ]; then ok "widening engage logged to the event log"; else nok "expected a 'jump pending' event" "none found"; fi

# ── 2. LP deposits refuse to mint against a pending mark ───────────
echo ""
echo "── 2. LP deposit gate: minting refused while the HELD leg has a pend ──"
# The M1 gate (vaultPricesStale) applies to legs the vault HOLDS — and "holds"
# means LP-tracked holdings, not whatever sits in the AMM principal's balances.
# The setTestBalance pre-fund above is NOT vault holdings: at LP supply 0 the
# GHSA-h888 genesis sweep (performLpDeposit → sweepZeroSupplyVaultToTreasury)
# routes the AMM principal's un-reserved balances to the treasury BEFORE the
# vault snapshot the gate reads, so the first deposit sees an EMPTY basket.
# That is the seeding intent (a genesis / unheld-leg deposit must never wedge
# on a breaker tick), and both inputs are pinned here in one breath:
#
#   2a. genesis deposit under the pend MINTS (no held leg → gate silent; the
#       raw pre-fund is swept, so the vault afterwards holds exactly the deposit)
#   2b. the vault now HOLDS ICP through LP accounting → the same deposit under
#       the same pend is REFUSED (M1).
#
# (This §2 was red from dc2cef2 until 2026-09-04: the fixture assumed the raw
# pre-fund counted as "held" — task 1788476226.)
#
# apiVersion 6.0.0 (task 1788731608): depositLp is a STAGED request, and a
# breaker pend on ANY market the request waits on (its own market for a
# deposit, every held leg) makes it WAIT — accepted, funds reserved, never
# settled at a mark awaiting confirmation, never refused for it (docs/amm-
# vault-design.md §5: "a pend WAITS for its confirmation tick"). So the
# genesis / held-leg distinction M1 drew at the immediate door collapses
# into one property here: nothing mints while the pend stands, and the
# request settles on the stamp that clears it. Staged RAW (`u depositLp`) —
# mdx_lp_deposit's own re-stamp would clear the pend the pin needs.
echo "   2a. genesis request under the pend STAGES (never wedges) and stays PENDING"
DEP0=$(u depositLp "(\"$MKT\", $(e8 200.0):nat, $(e8 20000.0):nat)")
ID0=$(mdx_lp_reqid "$DEP0")
adm adminRunStagedLp '()' >/dev/null
if mdx_ok "$DEP0" && [ -n "$ID0" ] && [ -n "$(mdx_lp_pending bw_lp "$ID0")" ]; then ok "genesis deposit accepted under a pend as request #$ID0 (funds reserved) and pending through the pass — the sealed door never mints at a mark awaiting confirmation"; else nok "genesis request refused / settled under the pend" "$(echo "$DEP0" | head -1) :: $(mdx_lp_view bw_lp)"; fi
echo "   2b. the confirmation (a direct set) clears the pend → it settles; the vault HOLDS ICP via LP accounting"
adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null   # supersedes the pend AND stamps the postdating mark
adm adminRunStagedLp '()' >/dev/null
if mdx_lp_outcome bw_lp "$ID0" | grep -q "minted ="; then ok "request #$ID0 minted once the pend cleared (settled at the confirmed mark)"; else nok "genesis request did not settle after the pend cleared" "$(mdx_lp_view bw_lp)"; fi
VV=$(adm getVaultValue '()' --query | tr -d '\n ')
LPS=$(echo "$VV" | grep -oE 'lpSupply=[0-9_]+' | tr -d '_' | grep -oE '[0-9]+$')
# basket.icp is the FIRST `icp=` field (the second is prices.icp).
HELD_ICP=$(echo "$VV" | grep -oE 'icp=[0-9_]+' | head -1 | tr -d '_' | grep -oE '[0-9]+$')
if [ "${LPS:-0}" -gt 0 ] && [ "${HELD_ICP:-0}" = "$(e8 200.0)" ]; then
  ok "vault now holds ICP via LP accounting (basket.icp = 200, pre-fund swept; lpSupply=$LPS)"
else nok "expected the basket to equal the LP deposit exactly" "lpSupply=${LPS:-?} basket.icp=${HELD_ICP:-?}"; fi
echo "   2c. a fresh pend on the now-HELD leg: the next request WAITS too (M1 — nothing settles at a frozen mark)"
adm setTestPendingJump "(\"ICP\", opt ($(e8 11.0):nat), null)" >/dev/null
DEP=$(u depositLp "(\"$MKT\", $(e8 10.0):nat, $(e8 1000.0):nat)")
IDB=$(mdx_lp_reqid "$DEP")
adm adminRunStagedLp '()' >/dev/null
if mdx_ok "$DEP" && [ -n "$IDB" ] && [ -n "$(mdx_lp_pending bw_lp "$IDB")" ]; then ok "deposit request #$IDB pending while the ICP jump awaits confirmation (held leg, M1)"; else nok "deposit settled against the pend" "$(echo "$DEP" | head -1) :: $(mdx_lp_view bw_lp)"; fi

# ── 3. Direct price set clears the pend; quotes snap back ──────────
echo ""
echo "── 3. dev price set supersedes the pend → quotes back to ±20bp ──"
adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null
adm requoteAmm "(\"$MKT\")" >/dev/null
A2=$(best asks); B2=$(best bids)
echo "   restored: ask=$A2 bid=$B2"
if [ -n "${A2:-}" ] && lt "$A2" "10.1" && gt "${B2:-0}" "9.9"; then
  ok "quotes snapped back to the tight ladder ($B2 / $A2)"
else nok "pend should clear on a direct set" "ask=${A2:-none} bid=${B2:-none}"; fi
if mdx_lp_outcome bw_lp "$IDB" | grep -q "minted ="; then ok "the request staged under the pend (#$IDB) settled on the clearing requote (processStagedLp runs inside the releasing pass)"; else nok "request #$IDB did not settle on the clearing requote" "$(mdx_lp_view bw_lp)"; fi
if DEP2=$(mdx_lp_deposit bw_lp "$MKT" "$(e8 10.0)" "$(e8 1000.0)"); then ok "a fresh deposit mints again after the pend clears (minted $DEP2 LP)"; else nok "deposit should succeed now" "$DEP2"; fi

# ── 4. withdrawLp mark gate (task 1788513125) ──────────────────────
echo ""
echo "── 4. LP withdrawal gate: ungated at zero utilisation, refused on a pended / stale mark once the vault has lent ──"
# withdrawLp redeems at NAV / supply and pays IN KIND: each leg is held ×
# lpAmount/supply × keepBps × NAV/holdings (VaultMath.redeemLeg). With no loan
# book NAV == holdings, the marks cancel and a mis-marked leg is simply handed
# to the exiter pro rata — price-neutral, so the exit must stay ungated (a
# vault with no loans can always be drained in kind). With loans outstanding
# the exiter's loan-book claim is paid as an extra L/H slice of the held
# basket AT THE FROZEN MARK — the same class M1 closed on the mint side — so
# the redeem side runs the same three held-leg checks exactly when NAV !=
# holdings. The vault here holds ICP + ICPUSD via bw_lp's §2/§3 deposits.
LPBAL=$(u getMyVaultLp '()' | tr -d '_' | grep -oE '[0-9]+' | head -1)
SLICE=$(( ${LPBAL:-0} / 100 ))    # 1% of the position — well inside any instant cap
restamp() { adm setAmmRefPrice "(\"$MKT\", $(e8 10.0):nat)" >/dev/null; adm requoteAmm "(\"$MKT\")" >/dev/null; }
#
# apiVersion 6.0.0: withdrawLp is a STAGED request too. The settlement-time
# mark gate (vaultWithdrawPaused, disclosed by getMaxInstantWithdraw's
# withdrawalPaused) is unchanged and is what the QUOTE pins below hold; but
# the request itself now WAITS under a pend on a waited market whatever the
# utilisation, and waits for a postdating mark whatever refPriceUpdatedNs
# says — so the exit pins read "pending until the clearing / fresh stamp,
# then settled", not "refused". Staged RAW; restamp is the clearing stamp.
echo "   4a. zero utilisation (NAV == holdings): the quote discloses no pause, and the exit request waits for the confirmation"
adm setTestPendingJump "(\"ICP\", opt ($(e8 11.0):nat), null)" >/dev/null
Q4A=$(u getMaxInstantWithdraw '()' --query | tr -d '\n')
if echo "$Q4A" | grep -q 'withdrawalPaused = null' && echo "$Q4A" | grep -q 'vaultLentOutUsd = 0 '; then ok "quote: withdrawalPaused = null with nothing lent out"; else nok "quote should not report a pause at zero utilisation" "$(echo "$Q4A" | grep -oE 'withdrawalPaused = [^;]+|vaultLentOutUsd = [^;]+' | tr '\n' ' ')"; fi
W4A=$(u withdrawLp "(${SLICE}:nat)")
IDA=$(mdx_lp_reqid "$W4A")
adm adminRunStagedLp '()' >/dev/null
if mdx_ok "$W4A" && [ -n "$IDA" ] && [ -n "$(mdx_lp_pending bw_lp "$IDA")" ]; then ok "zero-utilisation exit is STAGED under the pend (#$IDA, shares reserved) and waits for the confirmation — the sealed door redeems at no mark awaiting one, even where the marks would cancel"; else nok "zero-utilisation exit refused / settled under the pend" "$(echo "$W4A" | head -1) :: $(mdx_lp_view bw_lp)"; fi
restamp   # a direct set clears the pend (§3) and stamps a fresh mark for openPosition's freshness check
if mdx_lp_outcome bw_lp "$IDA" | grep -q "redeemed ="; then ok "…and settles in kind on the clearing restamp"; else nok "exit #$IDA did not settle after the pend cleared" "$(mdx_lp_view bw_lp)"; fi

echo "   4b. a margin pool borrows from the vault (loan book > 0)"
mdx_identity_new bw_liq; LIQ=$(principal_of bw_liq)
liq() { icp canister call --candid "$MDX_CANDID" --identity bw_liq backend "$@" 2>&1; }
adm setTestBalance "(principal \"$LIQ\", \"ICPUSD\", $(e8 300.0):nat)" >/dev/null
R4=$(liq createMarginPool '("bw gate", false)')
PID4=$(echo "$R4" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | tail -1)
liq fundMarginPool "(${PID4:-0}, $(e8 300.0):nat)" >/dev/null
# $300 collateral, 60 ICP long ($600 at the $10 mark, 2×) → ≈ $300 of the
# vault's cash lent out; the fill stages against the AMM ladder (3 × 50 ICP)
# and lands on the mark update that postdates the entry (restamp).
liq openPosition "(${PID4:-0}, \"$MKT\", variant { buy }, $(e8 60.0):nat, $(e8 0.05):nat, null)" >/dev/null
restamp
Q4B=$(u getMaxInstantWithdraw '()' --query | tr -d '\n')
L4=$(echo "$Q4B" | tr -d '_' | grep -oE 'vaultLentOutUsd = [0-9]+' | grep -oE '[0-9]+$')
if [ "${L4:-0}" -gt 0 ]; then ok "loan book live: \$$(from_e8 "$L4") lent out (precondition)"; else nok "loan not issued (precondition)" "$(echo "$Q4B" | head -c 300)"; fi
if echo "$Q4B" | grep -q 'withdrawalPaused = null'; then ok "quote: no pause on a fresh mark even with the loan book non-zero"; else nok "fresh mark must not pause" "$(echo "$Q4B" | grep -oE 'withdrawalPaused = [^;]+')"; fi

echo "   4c. the same pend now REFUSES the exit (loan book non-zero → the mark enters through NAV/holdings)"
adm setTestPendingJump "(\"ICP\", opt ($(e8 11.0):nat), null)" >/dev/null
Q4C=$(u getMaxInstantWithdraw '()' --query | tr -d '\n')
if echo "$Q4C" | grep -q 'withdrawalPaused = opt "LP withdrawal paused: a ICP price move is awaiting circuit-breaker confirmation'; then ok "quote discloses the pause (withdrawalPaused = opt \"LP withdrawal paused: …circuit-breaker…\")"; else nok "quote should disclose the pause" "$(echo "$Q4C" | grep -oE 'withdrawalPaused = [^;]+')"; fi
W4C=$(u withdrawLp "(${SLICE}:nat)")
IDC=$(mdx_lp_reqid "$W4C")
adm adminRunStagedLp '()' >/dev/null
if mdx_ok "$W4C" && [ -n "$IDC" ] && [ -n "$(mdx_lp_pending bw_lp "$IDC")" ]; then ok "withdrawal request #$IDC waits while the ICP jump is pending (the quote's pause is the settlement gate it would meet)"; else nok "withdrawal settled under the pend under utilisation" "$(echo "$W4C" | head -1) :: $(mdx_lp_view bw_lp)"; fi
LPBAL_C=$(u getMyVaultLp '()' | tr -d '_' | grep -oE '[0-9]+' | head -1)
if [ "${LPBAL_C:-x}" = "$(( LPBAL - SLICE ))" ]; then ok "a pending request burns nothing (LP balance unchanged since 4a's settled slice)"; else nok "staging changed the LP balance" "before=$(( LPBAL - SLICE )) after=${LPBAL_C:-?}"; fi
restamp   # clear the pend — #IDC settles on this stamp
if mdx_lp_outcome bw_lp "$IDC" | grep -q "redeemed ="; then ok "…and #$IDC settles once the pend clears"; else nok "exit #$IDC did not settle after the pend cleared" "$(mdx_lp_view bw_lp)"; fi

echo "   4d. a STALE mark (refPriceUpdatedNs backdated past the 60 s bar): requests WAIT — no fresh dispatch postdates them"
adm setTestRefPriceUpdatedNs "(\"$MKT\", 1 : int)" >/dev/null
W4D=$(u withdrawLp "(${SLICE}:nat)")
IDD=$(mdx_lp_reqid "$W4D")
D4D=$(u depositLp "(\"$MKT\", $(e8 1.0):nat, $(e8 100.0):nat)")
IDE=$(mdx_lp_reqid "$D4D")
adm adminRunStagedLp '()' >/dev/null
if mdx_ok "$W4D" && [ -n "$IDD" ] && [ -n "$(mdx_lp_pending bw_lp "$IDD")" ] && mdx_lp_pending bw_lp "$IDD" | grep -q "\"$MKT\""; then ok "withdrawal #$IDD stays pending on the stale ICP mark (waitingOn names $MKT — nothing redeems against it)"; else nok "stale mark: withdrawal settled or refused" "$(echo "$W4D" | head -1) :: $(mdx_lp_view bw_lp)"; fi
if mdx_ok "$D4D" && [ -n "$IDE" ] && [ -n "$(mdx_lp_pending bw_lp "$IDE")" ]; then ok "deposit #$IDE waits on the same stale mark (both sides, one rule)"; else nok "stale mark: deposit settled or refused" "$(echo "$D4D" | head -1) :: $(mdx_lp_view bw_lp)"; fi

echo "   4e. a fresh mark settles both"
restamp
if mdx_lp_outcome bw_lp "$IDD" | grep -q "redeemed =" && mdx_lp_outcome bw_lp "$IDE" | grep -q "minted ="; then ok "withdrawal #$IDD redeemed and deposit #$IDE minted on the fresh mark"; else nok "fresh mark should settle both" "$(mdx_lp_view bw_lp)"; fi
if W4E=$(mdx_lp_withdraw bw_lp "$SLICE"); then ok "a new withdrawal redeems straight through while the mark is fresh"; else nok "fresh mark should lift the gate" "$W4E"; fi
echo "   4f. the close repays IN FULL — the loan book returns to exactly 0 and the gate disarms again (task 1788515291)"
# The close's fill lands on the restamp (a later message than closePosition's
# own accrueAll). deleveragePool used to read the debt BEFORE repay's accrual,
# leaving the in-message interest (~a few base units here) on the book — so a
# vault that had EVER lent stayed gated on every pend until the dust cleared,
# which it never did. Now it accrues first and repays the whole debt: NAV ==
# holdings again, and the same pend that refused in 4c no longer gates.
liq closePosition "(${PID4:-0}, \"$MKT\", $(e8 0.05):nat, null)" >/dev/null 2>&1 || true
restamp
adm setTestPendingJump "(\"ICP\", opt ($(e8 11.0):nat), null)" >/dev/null
Q4F=$(u getMaxInstantWithdraw '()' --query | tr -d '\n')
if echo "$Q4F" | grep -q 'vaultLentOutUsd = 0 '; then ok "loan book back to exactly \$0 after the close (no dust residue)"; else nok "close left a loan residue" "$(echo "$Q4F" | grep -oE 'vaultLentOutUsd = [^;]+')"; fi
if echo "$Q4F" | grep -q 'withdrawalPaused = null'; then ok "quote: withdrawalPaused = null again under the pend — the gate disarmed once the loan repaid"; else nok "gate still armed under a pend after the loan repaid (residue keeps NAV != holdings)" "$(echo "$Q4F" | grep -oE 'withdrawalPaused = [^;]+')"; fi
W4F=$(u withdrawLp "(${SLICE}:nat)")
IDF=$(mdx_lp_reqid "$W4F")
adm setTestPendingJump "(\"ICP\", null, null)" >/dev/null
W4FS=$(mdx_lp_settle bw_lp "$IDF" "$W4F" "" 0); RCF=$?
if mdx_ok "$W4F" && [ "$RCF" = "0" ] && echo "$W4FS" | grep -q "redeemed ="; then ok "exit staged under the pend after the repaid loan settles once it clears (the 4a control holds for a vault that HAS lent)"; else nok "exit after a repaid loan did not settle" "$(echo "$W4F" | head -1) :: rc=$RCF $W4FS"; fi

adm setTestPendingJump "(\"ICP\", null, null)" >/dev/null 2>&1 || true
adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
