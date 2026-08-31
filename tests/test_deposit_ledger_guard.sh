#!/bin/bash
# Deposit-ledger integrity: the two guards that keep the Bridge's ledger and
# the DEX's high-water from minting money when they disagree.
#
# ── The slice-credit guard (DEX side) ──
# `creditAndRegister(user, token, amount, seq)` credits `seq - prevSeq`, NOT
# `amount`: `seq` is the Bridge's cumulative confirmed high-water, `amount` its
# delta since its own last acked claim, and after a lost #ok reply the Bridge
# re-sends an OVERLAPPING, larger amount. Deriving the slice from our own
# high-water is what stops that double-minting.
#
# That fix has an inverse. If `creditedSeq` ever loses ground while the
# Bridge's `claimed` does not — a reinstall here, a restore from older state, a
# hand-set seq — then `seq - prevSeq` spans the user's whole history and we
# would mint all of it at once. `amount` is the cross-check: the Bridge never
# sends LESS than the slice it owes, so `creditAmt > amount` can only mean the
# two ledgers have diverged. Refuse rather than mint.
#
# ── The in-flight guards (Bridge side) ──
# `claiming` / `admitting` are set before an `await` and cleared in the
# continuation. They are implicitly STABLE (persistent actor), so an upgrade
# landing mid-call used to leave the flag `true` forever and permanently lock
# that (user, asset) out of claiming. `postupgrade` now clears both: no
# continuation survives an upgrade, so a surviving flag can only be a lie.
#
# What this pins:
#   §1 a consistent (amount, seq) pair PASSES the divergence guard
#   §2 the lost-reply shape (amount > slice) passes — that is the normal case
#      the slice fix was built for, and must not be caught by the inverse guard
#   §3 a divergent pair (slice > amount) is REFUSED, with a diagnostic naming
#      both numbers — and nothing is minted
#   §4 replay (seq <= prevSeq) is still a silent no-op, not an error
#   §5 the Bridge still serves after an upgrade, and its stable ledger
#      (`admittedUnits`, `ledgers`) survives while the guards do not
#   §6 THE SLICE ITSELF, at the balance: a credit moves the wallet by
#      `seq - applied`, NOT by `amount` — the arithmetic the CRITICAL
#      double-mint fix turns on, which until now had no balance-level
#      assertion anywhere in the suite
#
# POSTURE DOCTRINE (DEPLOY_MODE in main.mo): #dev runs the SAME user-facing
# code as #play — the verification gate and the deposit cap included — so
# §1-§5 assert identically on both postures: an UNBOUND identity that passes
# the divergence guard is then refused by the verification gate, a distinct
# later error, which is the discriminator §1/§2 use ("did it reach the credit
# path?"). Nothing is ever minted to an unbound principal on ANY posture.
# Every section still uses a FRESH principal so prevSeq is 0 no matter what
# an earlier section did — refused credits never advance creditedSeq today,
# but a reused principal would couple the sections to that implementation
# detail and turn §2's probe into a silent seq<=prevSeq replay if it changed.
#
# Error text proves the guard fired; the balance proves the arithmetic. §6
# binds an identity through the real normalize→hash→bind hook (dev-only) so
# credits LAND and the slice arithmetic is measured at the wallet. On a
# hookless posture (#play install) §6 self-skips with the ⊘ marker — the
# arithmetic stays covered by every #dev run, which is the doctrine.
#
# Never calls resetExchange. Credits land only on throwaway principals that
# are deleted afterwards; no existing account is touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_deposit_ledger_guard ──"

# `icp identity delete X --yes` is NOT valid ("unexpected argument"), so it
# silently fails and the name survives — a later `identity new` then no-ops and
# the run silently REUSES the previous principal, carrying its balance and its
# email binding. That made §6 pass once and fail on every rerun. Confirm-by-pipe
# is the form that actually deletes.
newid() { echo "y" | icp identity delete "$1" >/dev/null 2>&1 || true
          icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; }
delid() { echo "y" | icp identity delete "$1" >/dev/null 2>&1 || true; }

MODE=$(call getDeployMode '()' --query 2>/dev/null | grep -oE 'dev|play|production' | head -1)
if [ "$MODE" = "production" ]; then
  echo "SKIP: deposit-guard test never runs against a production deployment"; exit 0
fi
echo "  (deploy mode: ${MODE:-unknown})"

newid dlg_u1; U1=$(principal_of dlg_u1)
newid dlg_u2; U2=$(principal_of dlg_u2)
newid dlg_u3; U3=$(principal_of dlg_u3)
newid dlg_u4; U4=$(principal_of dlg_u4)

# Controller-called creditAndRegister, so we drive (amount, seq) directly.
credit() { call creditAndRegister "(principal \"$1\", \"ICP\", $2 : nat, $3 : nat)" --identity anonymous; }
# Read balances AS THE OWNER — getTestBalance is self-or-controller, so an
# unidentified read silently returns 0 and would make every "minted nothing"
# check below pass for the wrong reason.
balof() { extract_first_nat "$(call getTestBalance "(principal \"$1\", \"ICP\")" --identity "$2")"; }

DIVERGENCE="Deposit ledger divergence"
VERIFY="verified Google-linked"

# ── §1 consistent pair passes the guard ──
# prevSeq is 0 for a fresh principal, so slice == seq == amount.
R=$(credit "$U1" 100 100)
assert_not_contains "§1 consistent (amount=slice) is NOT flagged as divergence" "$R" "$DIVERGENCE"
assert_contains "§1 ...it reaches the downstream verification gate" "$R" "$VERIFY"
assert_eq "§1 ...which refused it before any mint" "0" "$(balof "$U1" dlg_u1)"

# ── §2 the lost-reply shape must still pass ──
# amount (500) EXCEEDS the slice (100) — exactly what a re-sent claim looks
# like after a dropped #ok. The slice fix discards the overlap; the inverse
# guard must not mistake this for divergence.
R=$(credit "$U2" 500 100)
assert_not_contains "§2 lost-reply shape (amount > slice) is not flagged" "$R" "$DIVERGENCE"
assert_contains "§2 ...it too reaches the verification gate" "$R" "$VERIFY"
assert_eq "§2 ...refused before any mint (slice arithmetic lives in §6)" "0" "$(balof "$U2" dlg_u2)"

# ── §3 divergence is refused ──
# The Bridge sends 1 unit while claiming a high-water 1000 ahead of ours: our
# ledger lost ground. Crediting the slice would mint 1000 from a 1-unit claim.
R=$(credit "$U3" 1 1000)
assert_contains "§3 slice > amount is REFUSED" "$R" "$DIVERGENCE"
# The diagnostic must name both figures — a bare refusal is not actionable.
assert_contains "§3 diagnostic names what the bridge sent" "$R" "bridge sent 1 units"
assert_contains "§3 diagnostic names the implied slice" "$R" "implies 1000"
# The refusal precedes everything downstream: no verification gate...
assert_not_contains "§3 ...and never reaches the verification gate" "$R" "$VERIFY"
# ...and no mint.
assert_eq "§3 ...and minted nothing" "0" "$(balof "$U3" dlg_u3)"

# A near-miss is still divergence: one unit short is the same class of bug.
# Same principal: both its credits were refused, so its prevSeq is still 0.
R=$(credit "$U3" 99 100)
assert_contains "§3 off-by-one divergence is refused too" "$R" "$DIVERGENCE"

# ── §4 replay stays a silent no-op ──
# seq <= prevSeq returns #ok BEFORE any mint. prevSeq is 0 for this fresh
# principal, so seq 0 is a replay on either posture — the short-circuit
# precedes the divergence guard and the verification gate alike.
R=$(credit "$U4" 50 0)
assert_contains "§4 replayed seq is a silent no-op" "$R" "ok"
assert_not_contains "§4 ...not reported as divergence" "$R" "$DIVERGENCE"
assert_eq "§4 ...and minted nothing" "0" "$(balof "$U4" dlg_u4)"

# ── §5 the Bridge survives an upgrade with its ledger intact ──
# postupgrade clears ONLY the in-flight latches. Deposit bookkeeping is stable
# and must come through untouched.
#
# REAL STATE across the boundary (W5-15 / #38.5): the old §5 read a
# compile-time constant (getSupportedAssets) and an unset latch key — neither
# could fail if every ledger map was wiped. Now the section SETS state the
# upgrade must carry: a pending deposit row (the W3-04 write-ahead — the
# parked mid-flow shape a lost continuation leaves) and the DEX-side
# allowance charge; upgrades; and asserts both survive byte-for-byte, the
# ledger keeps working (a post-upgrade deposit charges exactly its mark
# value), and the confirm path then finishes exactly-once.
newid dlg_u5; U5P=$(principal_of dlg_u5)   # FRESH principal — the bridge ledger is cumulative per identity
call createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
call setAmmRefPrice '("BTC-ICPUSD", 10_000_000_000 : nat)' >/dev/null 2>&1   # $100 mark
call requoteAmm '("BTC-ICPUSD")' >/dev/null 2>&1
BIND5=$(call setTestEmailBinding "(principal \"$U5P\", \"dlgu5${RANDOM}$$@gmail.com\")" --identity anonymous)
assert_contains "§5 fresh principal bound (anti-sybil hook)" "$BIND5" "ok"
u5_used() { call getPlayDepositAllowance '()' --identity dlg_u5 | tr -d '_\n' | tr -s ' ' | grep -oE "usedUsd = [0-9]+" | awk '{print $3}'; }
u5_pend() { icp canister call bridge getMyDeposits '()' --query --identity dlg_u5 2>&1 | tr -d '_\n' | tr -s ' ' | grep -oE "asset = \"BTC\"[^}]*" | grep -oE "pending = [0-9]+" | awk '{print $3}'; }
u5_conf() { icp canister call bridge getMyDeposits '()' --query --identity dlg_u5 2>&1 | tr -d '_\n' | tr -s ' ' | grep -oE "asset = \"BTC\"[^}]*" | grep -oE "confirmed = [0-9]+" | awk '{print $3}'; }
R=$(icp canister call bridge devSimulateDeposit '("BTC", 100_000_000 : nat)' --identity dlg_u5 2>&1)
assert_contains "§5 pre-upgrade deposit admitted" "$R" "ok"
PEND0=$(u5_pend); USED0=$(u5_used)
assert_eq "§5 write-ahead pending row SET before the upgrade (1.0 BTC)" "100000000" "${PEND0:-0}"
icp deploy bridge --identity anonymous >/dev/null 2>&1
PEND1=$(u5_pend); USED1=$(u5_used)
assert_eq "§5 pending row SURVIVES the upgrade (stable ledger intact)" "${PEND0:-x}" "${PEND1:-y}"
assert_eq "§5 allowance charge survives, charged exactly once" "${USED0:-x}" "${USED1:-y}"
# ledger continuity: the surface is not just readable, it still BOOKS —
# 0.5 BTC at the $100 mark must move usedUsd by exactly $50.
R=$(icp canister call bridge devSimulateDeposit '("BTC", 50_000_000 : nat)' --identity dlg_u5 2>&1)
assert_contains "§5 post-upgrade deposit admitted (ledger still books)" "$R" "ok"
USED2=$(u5_used)
assert_eq "§5 post-upgrade charge is exactly the mark value (+\$50)" "$(( ${USED1:-0} + 5000000000 ))" "${USED2:-0}"
# the parked rows then FINISH exactly-once through the confirm path — the
# W3-04 lost-continuation recovery: nothing doubled, nothing stranded.
# devConfirmDeposits confirms the CALLER's own parked rows (it iterates
# ASSETS under msg.caller's key) — so the depositor drives it.
call_bridge_confirm=$(icp canister call bridge devConfirmDeposits '()' --identity dlg_u5 2>&1)
CONF=$(u5_conf); PEND2=$(u5_pend)
assert_eq "§5 confirm finishes BOTH parked rows exactly-once (1.5 BTC)" "150000000" "${CONF:-0}"
assert_eq "§5 nothing left parked after confirm" "0" "${PEND2:-x}"
# A claim path that was never in flight behaves normally afterwards (the guard
# is clear, so this is the "nothing to claim" answer, not "already in progress").
R=$(icp canister call bridge claim '("ICP")' --identity dlg_u1 2>&1)
assert_not_contains "§5 no stranded claim guard after upgrade" "$R" "already in progress"

# ── §6 the slice arithmetic, measured at the wallet ──
# Everything above asserts on ERROR TEXT or throwaway wallets. This asserts on
# the full credit LIFECYCLE — land, overlap, replay, refuse — at one balance.
# A verified identity is required for a credit to land on #play, so bind one
# through the real normalize→hash→bind hook.
newid dlg_paid
PAID=$(icp identity principal --identity dlg_paid 2>/dev/null | tail -1)
BIND=$(call setTestEmailBinding "(principal \"$PAID\", \"dlgpaid${RANDOM}$$@gmail.com\")" --identity anonymous)
if [ "$MODE" != "dev" ] && echo "$BIND" | grep -q "dev-only hook"; then
  # setTestEmailBinding is #dev-only, and #play has no other way to mint a
  # verified binding without a real Google round trip. The slice arithmetic
  # below is posture-independent and every #dev run covers it (doctrine).
  skip_section "§6 slice-at-the-wallet — setTestEmailBinding is #dev-only, no verified binding possible on #$MODE"
else
  assert_contains "§6 test identity bound to a verified email" "$BIND" "ok"

  # Read the balance AS THE OWNER — getTestBalance is self-or-controller, so an
  # unidentified read silently returns 0 and would make every check below pass
  # for the wrong reason. (That is exactly what broke test_play_deposit_cap.)
  bal() { extract_first_nat "$(call getTestBalance "(principal \"$PAID\", \"ICPUSD\")" --identity dlg_paid)"; }
  paycredit() { call creditAndRegister "(principal \"$PAID\", \"ICPUSD\", $1 : nat, $2 : nat)" --identity anonymous; }

  assert_eq "§6 fresh wallet starts empty" "0" "$(bal)"

  # First claim: 100 units confirmed, none applied → credit 100.
  R=$(paycredit 100 100)
  assert_contains "§6 first credit accepted" "$R" "ok"
  assert_eq "§6 ...wallet moved by the slice (100)" "100" "$(bal)"

  # THE DOUBLE-MINT CASE. A lost #ok makes the Bridge re-send an OVERLAPPING,
  # larger amount: it reports 500 units since ITS last ack, but the cumulative
  # high-water is only 150. The slice is 50. Crediting `amount` would mint 500
  # and hand the user 350 units of free money.
  R=$(paycredit 500 150)
  assert_contains "§6 overlapping re-send accepted" "$R" "ok"
  assert_eq "§6 ...credited the 50-unit SLICE, not the 500 reported" "150" "$(bal)"

  # Replay of an already-applied high-water is a silent no-op — no second mint.
  R=$(paycredit 500 150)
  assert_contains "§6 replayed high-water no-ops" "$R" "ok"
  assert_eq "§6 ...wallet unchanged by the replay" "150" "$(bal)"

  # And the inverse guard still bites on a real balance: refused, nothing minted.
  R=$(paycredit 1 900000)
  assert_contains "§6 divergent claim refused" "$R" "$DIVERGENCE"
  assert_eq "§6 ...and minted nothing" "150" "$(bal)"
fi

delid dlg_paid
delid dlg_u1; delid dlg_u2; delid dlg_u3; delid dlg_u4

finish_test "deposit_ledger_guard"
