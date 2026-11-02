#!/bin/bash
# tests/test_credit_slice.sh
#
# Regression for the deposit-credit SLICE invariant (backend creditAndRegister).
#
# creditAndRegister(user, token, amount, seq) must credit the NEWLY-confirmed
# slice `seq − creditedSeq`, NOT the caller's `amount`. The Bridge derives
# `amount = confirmed − claimed` and `seq = confirmed`, advancing its `claimed`
# high-water only on a received #ok. On the IC a reply can be lost after the DEX
# already committed: the Bridge's `claimed` then lags, and a later retry (after
# MORE deposits confirmed) sends an `amount` that OVERLAPS the already-credited
# prefix. Crediting the raw `amount` there double-mints. The fix credits the
# seq-delta, so the overlap is de-duplicated.
#
# This drives creditAndRegister directly as controller (the Bridge's role),
# reproducing the lost-reply-then-confirm sequence without Bridge orchestration.
# On #dev the play allowance cap is null, so credits are pure (no reservation
# math in the way) — exactly the path a custody #production bridge would hit.
#
# NON-DESTRUCTIVE: a throwaway identity, no resetExchange.

source "$(dirname "$0")/_lib.sh"

BACKEND_ID=$(icp canister status backend --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
[ -z "$BACKEND_ID" ] && { echo "backend canister not found — deploy it first (icp deploy)"; exit 1; }

echo "── test_credit_slice ──"

# Fresh principal each run → its creditedSeq high-water starts at 0.
U="creditslice"; mdx_identity_new "$U"; UPRIN=$(principal_of "$U")   # deleted on EXIT (tests/_lib.sh)

# On #play the allowance gate refuses an unbound principal at claim time
# (playBucketFor). Bind a throwaway verified email — unique per run, since
# bindings are first-come and survive reruns — so this test is posture-
# independent. On #dev the cap is null and the binding is inert.
call setTestEmailBinding "(principal \"$UPRIN\", \"cslice${RANDOM}$$@gmail.com\")" --identity anonymous >/dev/null

# getTestBalance is scoped to self-or-controller, and $UPRIN is a throwaway
# identity that is NOT us — so read it as the controller (anonymous, locally).
bal() { extract_first_nat "$(call getTestBalance "(principal \"$UPRIN\", \"ICPUSD\")" --query --identity anonymous 2>/dev/null)"; }
credit() { call creditAndRegister "(principal \"$UPRIN\", \"ICPUSD\", $1 : nat, $2 : nat, null)" --identity anonymous >/dev/null 2>&1; }

# (1) first confirmation: amount 100, seq 100 → credit 100 (creditedSeq 0→100)
credit 100000000 100000000
assert_eq "first credit lands 100" "100000000" "$(bal)"

# (2) LOST-REPLY RETRY: the #ok for (1) was lost, so the Bridge's `claimed`
# stayed 0; more deposits confirmed (confirmed=150). The retry therefore sends
# amount=150, seq=150. Only 50 is new (seq 150 − creditedSeq 100). Balance must
# be 150 — the pre-fix bug credited the raw 150 for a total of 250.
credit 150000000 150000000
assert_eq "retry credits ONLY the 50 slice, not the raw 150 (no double-mint)" "150000000" "$(bal)"

# (3) exact replay of an already-applied seq → strict no-op
credit 100000000 100000000
assert_eq "replay of seq<=creditedSeq is a no-op" "150000000" "$(bal)"

# (4) normal incremental path still works (amount == seq−creditedSeq): +50 → 200
credit 50000000 200000000
assert_eq "normal increment credits the full new slice" "200000000" "$(bal)"

finish_test "credit_slice"
