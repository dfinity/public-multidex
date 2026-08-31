#!/bin/bash
# Play-mode lifetime deposit allowance (the Deposit page's "fair footing"
# layer) — RESERVE-AT-ADMISSION model: every user may take on bridge deposits
# worth at most the lifetime cap ($100k on #play). The allowance is consumed
# when a deposit is MADE — devSimulateDeposit → DEX playDepositReserve values
# it at press-time marks, debits the user's bucket, and reserves the admitted
# UNITS — and the claim (creditAndRegister) settles against that reservation
# unit-for-unit with NO re-valuation, so an admitted deposit can NEVER be
# refused by the cap: no over-cap claimable can be stranded on the Bridge by
# mark moves, racing simulates, or claimed history. Credits beyond any
# reservation (ops/direct credits, pre-reservation legacy claimables) still
# face the claim-time gate — the DEX's value-integrity backstop against a
# misbehaving Bridge.
#
# SELF-ADAPTING to the deployment mode (getDeployMode). Posture doctrine:
# #dev runs the same cap machinery as #play — the REAL $100k cap is active on
# both; the dev hook (setTestPlayDepositCap) only OVERRIDES its value:
#   #dev  → arms a $15k override so the fractions stay cheap, disarms at the
#           end (disarm reverts to the REAL cap, never to "no cap");
#           cap-lowering assertions run.
#   #play → the hook no-ops; the same sections assert the identical
#           invariant at the real cap.
# All identities are bound to throwaway verified emails via the test hook —
# REQUIRED on #play (unbound principals can't deposit at all) and harmless on
# #dev (same resolver path). Amounts are FRACTIONS of the detected cap so the
# arithmetic is exact in both modes; ICPUSD is valued 1:1 (no mark
# dependency), plus BTC to prove mark valuation.
#   §1  allowance query reflects the active cap, zero used
#   §2  simulate (60%) consumes the allowance IMMEDIATELY; the claim settles
#       the reservation without consuming more
#   §3  an over-cap simulate (60%+50%) is refused at the button; nothing is
#       created, nothing is debited
#   §4  admitted-but-unclaimed counts (already consumed): 60%+25% admitted,
#       +25% more refused
#   §5  NO DEAD ENDS: the admitted 25% claims even if the cap is lowered
#       below what's already consumed (dev-only lowering); remaining clamps
#       to 0 meanwhile
#   §6  value-integrity backstop: a DIRECT un-admitted credit is still gated
#       at claim time — over-cap (110%) refused, in-cap (10%) credits+debits
#   §7  admission replay (lost-reply retry): the same seq twice debits ONCE,
#       and settling the reservation consumes no further allowance
#   §8  mark-valued (BTC) admission consumes > 0 allowance at simulate time;
#       the claim does not re-price it
#   §9  EMAIL-BUCKET regression (the bucket-mismatch bug): for a bound user
#       with claimed history (60%), an over-cap simulate (50%) is REFUSED.
#       (The old pre-check read the principal bucket — empty for every bound
#       user — admitted it, and the claim gate then refused it: a permanently
#       stuck claimable.)
#   §10 disarm reverts to the REAL posture cap on #dev (posture doctrine —
#       there is no uncapped play-family posture); a huge simulate stays
#       refused on both postures
# Safe on a live sim (own throwaway identities + emails; dev cap disarmed at
# the end; on #play only fake-money deposits under the normal cap are made).

source "$(dirname "$0")/_lib.sh"

BRIDGE_ID=$(icp canister status bridge  --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
BACKEND_ID=$(icp canister status backend --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
if [ -z "$BRIDGE_ID" ] || [ -z "$BACKEND_ID" ]; then
  echo "bridge/backend canister not found — deploy them first (icp deploy)"; exit 1
fi
bcall() { echo "y" | icp canister call bridge "$@" 2>&1; }
newid() { icp identity delete "$1" --yes >/dev/null 2>&1 || echo "y" | icp identity delete "$1" >/dev/null 2>&1 || true
          icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; }
delid() { icp identity delete "$1" --yes >/dev/null 2>&1 || echo "y" | icp identity delete "$1" >/dev/null 2>&1 || true; }

echo "── test_play_deposit_cap ──"

MODE=$(call getDeployMode '()' --query 2>/dev/null | grep -oE 'dev|play|production' | head -1)
if [ "$MODE" = "production" ]; then
  echo "SKIP: deposit-cap test never runs against a production deployment"; exit 0
fi
echo "  (deploy mode: ${MODE:-unknown})"

# (0) wire bridge ↔ DEX (idempotent); on #dev arm a $15k cap (no-op on #play)
call  setBridge "(principal \"$BRIDGE_ID\")"  --identity anonymous >/dev/null
bcall setDex    "(principal \"$BACKEND_ID\")" --identity anonymous >/dev/null
if [ "$MODE" = "dev" ]; then
  call setTestPlayDepositCap '(opt (1_500_000_000_000 : nat))' --identity anonymous >/dev/null   # $15k @ e8
fi

U="pdcap_u"; V="pdcap_v"; W="pdcap_w"; X="pdcap_x"
newid "$U"; newid "$V"; newid "$W"; newid "$X"
UPRIN=$(principal_of "$U")
VPRIN=$(principal_of "$V")
WPRIN=$(principal_of "$W")
XPRIN=$(principal_of "$X")

# Bind every identity to a distinct throwaway verified email (test hook runs
# the real normalize→hash→bind path). Unique local-parts per run: bindings
# are first-come-first-bound and survive reruns.
SFX="${RANDOM}$$"
for pair in "u:$UPRIN" "v:$VPRIN" "w:$WPRIN" "x:$XPRIN"; do
  BIND=$(call setTestEmailBinding "(principal \"${pair#*:}\", \"pdcap${pair%%:*}${SFX}@gmail.com\")" --identity anonymous)
  # Needle anchored to the variant (#51.9): a bare "ok" was satisfied by the
  # #play "dev-only hoOK" refusal text, so the binding pin could not go red.
  assert_contains "email binding (${pair%%:*})" "$BIND" "variant { ok"
done

# §1 allowance visible, untouched; derive the cap + fraction amounts from it
ALW=$(call getPlayDepositAllowance '()' --query --identity "$U")
CAP_E8=$(extract_nat capUsd "$ALW")
assert_gt "a deposit cap is active" "${CAP_E8:-0}" "0"
assert_contains "nothing used yet" "$ALW" "usedUsd = 0"
A=$((CAP_E8 * 6 / 10))   # 60% — the big first deposit
B=$((CAP_E8 / 2))        # 50% — over-cap on top of A (110%)
C=$((CAP_E8 / 4))        # 25% — fits after A (85%), second one doesn't (110%)
D=$((CAP_E8 / 10))       # 10% — direct-credit / replay probe amounts
OVER=$((CAP_E8 + D))     # 110% — over-cap for a fresh user

# §2 a 60% ICPUSD deposit is admitted and consumes 60% AT SIMULATE TIME;
#    the claim settles the reservation without consuming more
bcall createDepositAddress '()' --identity "$U" >/dev/null
SIM=$(bcall devSimulateDeposit "(\"ICPUSD\", $A : nat)" --identity "$U")
assert_contains "in-cap simulate admitted" "$SIM" "ok"
ALW=$(call getPlayDepositAllowance '()' --query --identity "$U")
assert_contains "allowance consumed at simulate (used = 60%)" "$ALW" "usedUsd = $A"
bcall devConfirmDeposits '()' --identity "$U" >/dev/null
CLAIM=$(bcall claim '("ICPUSD")' --identity "$U")
assert_contains "60% claim ok" "$CLAIM" "ok = $A"
ALW=$(call getPlayDepositAllowance '()' --query --identity "$U")
assert_contains "claim consumed nothing more (used = 60%)" "$ALW" "usedUsd = $A"
assert_contains "remaining = 40%"                           "$ALW" "remainingUsd = $((CAP_E8 - A))"

# §3 a further 50% would exceed the cap → REFUSED at simulate; nothing
#    created, nothing debited
SIM=$(bcall devSimulateDeposit "(\"ICPUSD\", $B : nat)" --identity "$U")
assert_contains "over-cap simulate refused" "$SIM" "allowance exceeded"
DEP=$(bcall getMyDeposits '()' --identity "$U")
assert_not_contains "no pending created by refused simulate" "$DEP" "pending = $B"
ALW=$(call getPlayDepositAllowance '()' --query --identity "$U")
assert_contains "refusal debited nothing (used = 60%)" "$ALW" "usedUsd = $A"
BAL=$(call getTestBalance "(principal \"$UPRIN\", \"ICPUSD\")" --identity "$U")
assert_eq "wallet unchanged after refusal" "$A" "$(extract_first_nat "$BAL")"

# §4 admitted-but-unclaimed deposits count (their value is already consumed):
#    60% used + 25% admitted + 25% more = 110% → second refused
SIM=$(bcall devSimulateDeposit "(\"ICPUSD\", $C : nat)" --identity "$U")
assert_contains "25% simulate admitted" "$SIM" "ok"
SIM=$(bcall devSimulateDeposit "(\"ICPUSD\", $C : nat)" --identity "$U")
assert_contains "second 25% refused (unclaimed already consumed)" "$SIM" "allowance exceeded"

# §5 NO DEAD ENDS: the admitted 25% claimable claims NO MATTER WHAT the cap
#    says at claim time. On #dev, prove the strong form: lower the cap below
#    the 85% already consumed — settlement bypasses the cap and still claims.
#    Before reservations this was the stuck state: an all-or-nothing claim
#    the claim-time gate refused forever.
bcall devConfirmDeposits '()' --identity "$U" >/dev/null    # the §4 25% → claimable
if [ "$MODE" = "dev" ]; then
  call setTestPlayDepositCap "(opt ($((CAP_E8 * 7 / 10)) : nat))" --identity anonymous >/dev/null   # 70% < the 85% consumed
  ALW=$(call getPlayDepositAllowance '()' --query --identity "$U")
  assert_contains "remaining clamps to 0 under a lowered cap" "$ALW" "remainingUsd = 0"
fi
CLAIM=$(bcall claim '("ICPUSD")' --identity "$U")
assert_contains "admitted claimable still claims (no dead ends)" "$CLAIM" "ok = $C"
if [ "$MODE" = "dev" ]; then
  call setTestPlayDepositCap "(opt ($CAP_E8 : nat))" --identity anonymous >/dev/null   # restore
fi
ALW=$(call getPlayDepositAllowance '()' --query --identity "$U")
assert_contains "used = 85%" "$ALW" "usedUsd = $((A + C))"

# §6 value-integrity backstop: an UN-ADMITTED direct credit (controller
#    stands in for a misbehaving Bridge / ops path) is still valued and gated
#    at claim time — over-cap refused, in-cap credits and debits the bucket.
# seq is the CUMULATIVE confirmed-units high-water, NOT a nonce: the DEX
# credits `seq - previouslyApplied`, so seq must equal the units this claim
# brings the total to. W is fresh (applied = 0), so seq = the amount itself.
CR=$(call creditAndRegister "(principal \"$WPRIN\", \"ICPUSD\", $OVER : nat, $OVER : nat)" --identity anonymous)
assert_contains "un-admitted over-cap credit refused (backstop)" "$CR" "allowance exceeded"
BAL=$(call getTestBalance "(principal \"$WPRIN\", \"ICPUSD\")" --identity "$W")
assert_eq "no over-cap credit landed" "0" "$(extract_first_nat "$BAL")"
# Refused above, so nothing was applied — this claim still starts from 0.
CR=$(call creditAndRegister "(principal \"$WPRIN\", \"ICPUSD\", $D : nat, $D : nat)" --identity anonymous)
assert_contains "in-cap un-admitted credit ok" "$CR" "ok"
ALW=$(call getPlayDepositAllowance '()' --query --identity "$W")
assert_contains "claim-time debit for un-admitted credit (used = 10%)" "$ALW" "usedUsd = $D"

# §7 admission replay: the same seq twice debits ONCE (a lost-reply retry can
#    never double-consume), and settling the reservation consumes no more.
RES=$(call playDepositReserve "(principal \"$WPRIN\", \"ICPUSD\", $D : nat, $D : nat)" --identity anonymous)
assert_contains "direct admission ok" "$RES" "ok"
RES=$(call playDepositReserve "(principal \"$WPRIN\", \"ICPUSD\", $D : nat, $D : nat)" --identity anonymous)
assert_contains "replayed admission no-ops" "$RES" "ok"
ALW=$(call getPlayDepositAllowance '()' --query --identity "$W")
assert_contains "replay did not double-debit (used = 20%)" "$ALW" "usedUsd = $((D + D))"
# D units were applied above, so settling another D brings the total to 2D.
CR=$(call creditAndRegister "(principal \"$WPRIN\", \"ICPUSD\", $D : nat, $((D + D)) : nat)" --identity anonymous)
assert_contains "reserved credit settles" "$CR" "ok"
ALW=$(call getPlayDepositAllowance '()' --query --identity "$W")
assert_contains "settlement consumed nothing (used = 20%)" "$ALW" "usedUsd = $((D + D))"

# §8 mark-valued asset: a fresh user's BTC deposit consumes > 0 allowance at
#    SIMULATE time (0.1 BTC ≪ the cap at any sane mark); the claim doesn't
#    re-price it.
bcall createDepositAddress '()' --identity "$V" >/dev/null
SIM=$(bcall devSimulateDeposit '("BTC", 10_000_000 : nat)' --identity "$V")   # 0.1 BTC
assert_contains "BTC simulate admitted (mark-valued)" "$SIM" "ok"
ALW=$(call getPlayDepositAllowance '()' --query --identity "$V")
USED_AT_SIM=$(extract_nat usedUsd "$ALW")
assert_gt "BTC admission consumed mark-valued allowance at simulate" "${USED_AT_SIM:-0}" "0"
bcall devConfirmDeposits '()' --identity "$V" >/dev/null
CLAIM=$(bcall claim '("BTC")' --identity "$V")
assert_contains "BTC claim ok (settles reservation)" "$CLAIM" "ok = 10000000"
ALW=$(call getPlayDepositAllowance '()' --query --identity "$V")
assert_eq "claim did not re-price (used unchanged)" "$USED_AT_SIM" "$(extract_nat usedUsd "$ALW")"

# §9 EMAIL-BUCKET regression: X (bound) funds + claims 60%, then an over-cap
#    50% simulate must be REFUSED — admission must read the EMAIL bucket the
#    binding folds usage into, not the (now empty) principal bucket.
bcall createDepositAddress '()' --identity "$X" >/dev/null
SIM=$(bcall devSimulateDeposit "(\"ICPUSD\", $A : nat)" --identity "$X")
assert_contains "bound user's simulate admitted" "$SIM" "ok"
ALW=$(call getPlayDepositAllowance '()' --query --identity "$X")
assert_contains "debit landed in the email bucket (used = 60%)" "$ALW" "usedUsd = $A"
bcall devConfirmDeposits '()' --identity "$X" >/dev/null
CLAIM=$(bcall claim '("ICPUSD")' --identity "$X")
assert_contains "bound user's claim ok" "$CLAIM" "ok = $A"
SIM=$(bcall devSimulateDeposit "(\"ICPUSD\", $B : nat)" --identity "$X")
assert_contains "over-cap simulate REFUSED for a bound user (regression)" "$SIM" "allowance exceeded"
DEP=$(bcall getMyDeposits '()' --identity "$X")
assert_not_contains "nothing stranded on the bridge" "$DEP" "pending = $B"

# §10 disarm reverts to the REAL posture cap, never to "no cap" (posture
#     doctrine: #dev mirrors #play, and no play-family posture is uncapped).
#     On #dev the $15k override comes off and the $100k cap takes over; on
#     #play the hook no-ops. Either way the huge simulate stays refused.
HUGE=$((CAP_E8 * 10))
if [ "$MODE" = "dev" ]; then
  call setTestPlayDepositCap '(null)' --identity anonymous >/dev/null
  ALW=$(call getPlayDepositAllowance '()' --query --identity "$U")
  CAP2=$(extract_nat capUsd "$ALW")
  assert_gt "disarm reverts to the real posture cap (not null)" "${CAP2:-0}" "0"
  assert_gt "...which is the posture cap, above the armed override" "${CAP2:-0}" "$CAP_E8"
fi
SIM=$(bcall devSimulateDeposit "(\"ICPUSD\", $HUGE : nat)" --identity "$U")
assert_contains "the cap cannot be escaped by disarming (huge simulate refused)" "$SIM" "allowance exceeded"

delid "$U"; delid "$V"; delid "$W"; delid "$X"

if [ "$_TEST_ERRORS" -eq 0 ]; then
  echo -e "\n\033[0;32mPASS: test_play_deposit_cap\033[0m"; exit 0
else
  echo -e "\n\033[0;31mFAIL: test_play_deposit_cap ($_TEST_ERRORS failing assertions)\033[0m"; exit 1
fi
