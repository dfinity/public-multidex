#!/bin/bash
# test_funding_authority — task 1789609263 (keychain hardening F17): a
# controller-designated FUNDING AUTHORITY signs the bot fleet's refills, so
# the production controller key stops doing double duty.
#
# The unattended subnet fleet refilled its bots through setTestBalance signed
# with the target's CONTROLLER identity. Now a controller designates ONE
# non-controller principal (`setFundingAuthority`) that is admitted to
# EXACTLY the two balance setters (setTestBalance / bulkSetTestBalances) and
# the scoped getTestBalance read, on #play/#dev only. This suite drives the
# live gate on the seat venue; the #production refusal is pinned by
# `mops test` (tests/Funding.test.mo — the verdict is a pure lib function)
# and hygiene §6be pins the wiring (inspect arm, mixin gate, scripts).
#
#   §0 baseline: no authority designated; bob (a non-controller) is refused
#      by the mint gate with the controller phrase AND the designation hint
#   §1 alice (a controller) designates bob; getFundingAuthority reads it
#      back; whyAmIRefused.fundingAuthority = true for bob, false for charlie
#   §2 a refill LANDS: bob setTestBalance(dave) as the authority; bob can READ
#      dave's balance (the refill loop reads before it refills); bob's
#      bulkSetTestBalances lands too (#dev: the genesis window never closes)
#   §3 refusal as a random principal: charlie is still refused; bob is
#      admitted to NOTHING else (setTestTimersPaused, setFundingAuthority
#      itself, resetExchange — all controller-only, all refused)
#   §4 the anonymous principal can never be designated (the authority stays bob)
#   §5 clear: alice sets null; bob is refused again; the designation is gone
#   §6 the tape: the designation and the clear landed as #config rows
#
# Identities: alice (controller, cold_start promotes her), bob = the
# authority, charlie = the random principal, dave = the refill target.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_funding_authority ──"

BOB=$(principal_of bob); CHARLIE=$(principal_of charlie); DAVE=$(principal_of dave)
[ -n "$BOB" ] && [ -n "$CHARLIE" ] && [ -n "$DAVE" ] || { _fail "could not resolve bob/charlie/dave principals in this icp store"; finish_test "test_funding_authority"; }

# Leave the venue as we found it: dave's ICPUSD is restored at the end and
# the authority is cleared (§5) so no later suite inherits a designation.
DAVE_ICPUSD_BEFORE=$(call getTestBalance "(principal \"$DAVE\", \"ICPUSD\")" --identity alice | grep -oE "[0-9][0-9_]*" | head -1 | tr -d '_')
# A pre-existing designation (a suite that died mid-run) is cleared first so
# §0 starts from the documented baseline.
call setFundingAuthority "(null)" --identity alice > /dev/null

# ── §0 baseline ──────────────────────────────────────────────────
FA0=$(call getFundingAuthority '()' --identity anonymous)
assert_contains "§0 no funding authority designated at start" "$FA0" "(null)"
BOB0=$(call setTestBalance "(principal \"$DAVE\", \"ICPUSD\", $(e8 1.0))" --identity bob)
assert_contains "§0 bob (non-controller, not designated) is refused the mint" "$BOB0" "not a canister controller and not the designated funding authority"
assert_contains "§0 ...and the refusal names the designation path" "$BOB0" "setFundingAuthority"
WHY0=$(call whyAmIRefused '()' --identity bob)
assert_contains "§0 whyAmIRefused says bob is not the authority" "$WHY0" "fundingAuthority = false"

# ── §1 designate bob ─────────────────────────────────────────────
SET1=$(call setFundingAuthority "(opt principal \"$BOB\")" --identity alice)
assert_contains "§1 alice (controller) designates bob" "$SET1" "()"
FA1=$(call getFundingAuthority '()' --identity anonymous)
assert_contains "§1 getFundingAuthority reads bob back" "$FA1" "$BOB"
WHY1=$(call whyAmIRefused '()' --identity bob)
assert_contains "§1 whyAmIRefused names bob's role" "$WHY1" "fundingAuthority = true"
WHY1C=$(call whyAmIRefused '()' --identity charlie)
assert_contains "§1 ...and not charlie's" "$WHY1C" "fundingAuthority = false"

# ── §2 a refill lands ────────────────────────────────────────────
REFILL=$(call setTestBalance "(principal \"$DAVE\", \"ICPUSD\", $(e8 123456.0))" --identity bob)
assert_contains "§2 bob (the authority) refills dave" "$REFILL" "()"
READ=$(call getTestBalance "(principal \"$DAVE\", \"ICPUSD\")" --identity bob)
assert_contains "§2 bob can READ dave's balance (the refill loop's bal_of)" "$READ" "$(e8 123456.0)"
READ_C=$(call getTestBalance "(principal \"$DAVE\", \"ICPUSD\")" --identity charlie)
assert_contains "§2 charlie (neither) reads 0 for dave — the scope did not widen" "$READ_C" "(0 : nat)"
# The record LABEL is spelled "principal" (quoted): `principal` is a Candid
# keyword (scripts/seed.sh bulk_fund carries the same note).
BULK=$(call bulkSetTestBalances "(vec { record { \"principal\" = principal \"$DAVE\"; balances = vec { record { token = \"ICPUSD\"; amount = $(e8 123457.0) } } } })" --identity bob)
assert_contains "§2 bob's bulkSetTestBalances lands (one row; #dev keeps the genesis window open)" "$BULK" "(1 : nat)"
READ2=$(call getTestBalance "(principal \"$DAVE\", \"ICPUSD\")" --identity bob)
assert_contains "§2 ...and wrote the balance" "$READ2" "$(e8 123457.0)"

# ── §3 refusals: a random principal, and everything else for bob ──
CH3=$(call setTestBalance "(principal \"$DAVE\", \"ICPUSD\", $(e8 1.0))" --identity charlie)
assert_contains "§3 charlie (random principal) is still refused the mint" "$CH3" "not a canister controller"
CH3B=$(call bulkSetTestBalances "(vec {})" --identity charlie)
assert_contains "§3 charlie is refused the bulk mint" "$CH3B" "not a canister controller"
BOB3A=$(call setTestTimersPaused "(false)" --identity bob)
assert_contains "§3 bob is NOT a controller: setTestTimersPaused refused" "$BOB3A" "not a canister controller"
BOB3B=$(call setFundingAuthority "(opt principal \"$CHARLIE\")" --identity bob)
assert_contains "§3 bob cannot re-designate (controller-only)" "$BOB3B" "not a canister controller"
BOB3C=$(call resetExchange '()' --identity bob)
assert_contains "§3 bob cannot resetExchange" "$BOB3C" "not a canister controller"
FA3=$(call getFundingAuthority '()' --identity anonymous)
assert_contains "§3 the designation is still bob after the refused re-designation" "$FA3" "$BOB"

# ── §4 anonymous can never be the authority ──────────────────────
ANON4=$(call setFundingAuthority "(opt principal \"2vxsx-fae\")" --identity alice)
assert_contains "§4 designating the anonymous principal is refused" "$ANON4" "the anonymous principal cannot be the funding authority"
FA4=$(call getFundingAuthority '()' --identity anonymous)
assert_contains "§4 ...and the designation stays bob" "$FA4" "$BOB"

# ── §5 clear ─────────────────────────────────────────────────────
CLR=$(call setFundingAuthority "(null)" --identity alice)
assert_contains "§5 alice clears the authority" "$CLR" "()"
FA5=$(call getFundingAuthority '()' --identity anonymous)
assert_contains "§5 getFundingAuthority is null again" "$FA5" "(null)"
BOB5=$(call setTestBalance "(principal \"$DAVE\", \"ICPUSD\", $(e8 1.0))" --identity bob)
assert_contains "§5 bob is refused the mint once cleared" "$BOB5" "not a canister controller and not the designated funding authority"
WHY5=$(call whyAmIRefused '()' --identity bob)
assert_contains "§5 whyAmIRefused agrees" "$WHY5" "fundingAuthority = false"

# ── §6 the tape carries the designation as #config rows ──────────
# The ring log (getRecentEvents) carries the setter's logEvent lines — one
# for the designation (§1), one for the clear (§5); the durable #config row
# rides the same call (emitConfig; hygiene §6be pins the emit).
EVENTS=$(call getRecentEvents "(40 : nat)" --identity alice)
assert_contains "§6 the ring log recorded the designation" "$EVENTS" "Funding authority set: $BOB"
assert_contains "§6 ...and the clear" "$EVENTS" "Funding authority cleared"

# Restore dave's ICPUSD so the venue reads as before.
[ -n "$DAVE_ICPUSD_BEFORE" ] && call setTestBalance "(principal \"$DAVE\", \"ICPUSD\", $DAVE_ICPUSD_BEFORE : nat)" --identity alice > /dev/null

finish_test "test_funding_authority"
