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
mdx_identity_new "$U"; mdx_identity_new "$V"; mdx_identity_new "$W"; mdx_identity_new "$X"   # virgin each run, deleted on EXIT (tests/_lib.sh)
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
assert_ok "in-cap simulate admitted" "$SIM"
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
BAL=$(call getTestBalance "(principal \"$UPRIN\", \"ICPUSD\")" --query --identity "$U")
assert_eq "wallet unchanged after refusal" "$A" "$(extract_first_nat "$BAL")"

# §4 admitted-but-unclaimed deposits count (their value is already consumed):
#    60% used + 25% admitted + 25% more = 110% → second refused
SIM=$(bcall devSimulateDeposit "(\"ICPUSD\", $C : nat)" --identity "$U")
assert_ok "25% simulate admitted" "$SIM"
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
CR=$(call creditAndRegister "(principal \"$WPRIN\", \"ICPUSD\", $OVER : nat, $OVER : nat, null)" --identity anonymous)
assert_contains "un-admitted over-cap credit refused (backstop)" "$CR" "allowance exceeded"
# --query: W is UNREGISTERED (its credit was refused), and since H-30 an
# unregistered principal's update-mode ingress reaches only the
# pre-registration set — a query read in update mode is refused at the gate.
BAL=$(call getTestBalance "(principal \"$WPRIN\", \"ICPUSD\")" --query --identity "$W")
assert_eq "no over-cap credit landed" "0" "$(extract_first_nat "$BAL")"
# Refused above, so nothing was applied — this claim still starts from 0.
CR=$(call creditAndRegister "(principal \"$WPRIN\", \"ICPUSD\", $D : nat, $D : nat, null)" --identity anonymous)
assert_ok "in-cap un-admitted credit ok" "$CR"
ALW=$(call getPlayDepositAllowance '()' --query --identity "$W")
assert_contains "claim-time debit for un-admitted credit (used = 10%)" "$ALW" "usedUsd = $D"

# §7 admission replay: the same seq twice debits ONCE (a lost-reply retry can
#    never double-consume), and settling the reservation consumes no more.
RES=$(call playDepositReserve "(principal \"$WPRIN\", \"ICPUSD\", $D : nat, $D : nat)" --identity anonymous)
assert_ok "direct admission ok" "$RES"
RES=$(call playDepositReserve "(principal \"$WPRIN\", \"ICPUSD\", $D : nat, $D : nat)" --identity anonymous)
assert_ok "replayed admission no-ops" "$RES"
ALW=$(call getPlayDepositAllowance '()' --query --identity "$W")
assert_contains "replay did not double-debit (used = 20%)" "$ALW" "usedUsd = $((D + D))"
# D units were applied above, so settling another D brings the total to 2D.
CR=$(call creditAndRegister "(principal \"$WPRIN\", \"ICPUSD\", $D : nat, $((D + D)) : nat, null)" --identity anonymous)
assert_ok "reserved credit settles" "$CR"
ALW=$(call getPlayDepositAllowance '()' --query --identity "$W")
assert_contains "settlement consumed nothing (used = 20%)" "$ALW" "usedUsd = $((D + D))"

# §8 mark-valued asset: a fresh user's BTC deposit consumes > 0 allowance at
#    SIMULATE time (0.1 BTC ≪ the cap at any sane mark); the claim doesn't
#    re-price it.
# MARK PIN (task 1788541235): the valuation reads the BTC mark through the
# H-33 freshness bar (fresh AND un-pended). In run_all order the predecessors
# (order_caps_margin / orderbook_priority / partial_close) each wipe the venue
# and leave BTC-ICPUSD ENABLED at a synthetic mark ($50,000 / $25,700) with the
# timers running, so the live feed's next tick PENDS the >2.5% jump to the
# real ~$80k and this simulate was refused: "the BTC mark is held pending a
# price-jump confirmation" (RED reproduced 2026-09-04 with exactly that
# chain; green alone on a fresh seed, where the mark IS the live price). On
# #dev, pin the mark at the feed's last aggregate (clears the pend, stamps
# now; a fetch that lands afterwards agrees with it) — provisioning the pool
# when a wiped predecessor left none, and enabling it so the feed keeps the
# mark fresh (the fixture rule in tests/_lib.sh). #play venues run no
# synthetic predecessors; their mark is the feed's already.
if [ "$MODE" = "dev" ]; then
  call createAmmPool '("BTC-ICPUSD")' --identity anonymous >/dev/null 2>&1 || true
  read -r BTC_PIN_E8 BTC_PIN_SRC <<EOF_PIN
$(mdx_pin_mark BTC BTC-ICPUSD "$(e8 75000)")
EOF_PIN
  call enableAmm '("BTC-ICPUSD", true)' --identity anonymous >/dev/null 2>&1 || true
  echo "  (§8 BTC mark pinned at ${BTC_PIN_E8:-?} e8 — ${BTC_PIN_SRC:-none})"
fi
bcall createDepositAddress '()' --identity "$V" >/dev/null
SIM=$(bcall devSimulateDeposit '("BTC", 10_000_000 : nat)' --identity "$V")   # 0.1 BTC
assert_ok "BTC simulate admitted (mark-valued)" "$SIM"
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
assert_ok "bound user's simulate admitted" "$SIM"
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

# §11 H-15 (F5-DEX): the RELAY CEILING. The three Bridge-facing updates take
#     unbounded Nats; pre-fix the only bound was amount == 0, and a ~100 KB
#     `amount` (or `seq`) reached a refusal that Nat.toText'd it — Θ(bits²) —
#     so the DEX burned its whole 40 B instruction budget and trapped with
#     IC0522 (RED on d6f2784: 5 s → IC0522 for both the amount and the seq
#     probes; 2^128+1 formatted a 31-digit bignum into the allowance text).
#     Now anything above 2^128 (the Bridge's AMOUNT_CEILING, H-27) is refused
#     FIRST — before the replay-seq compare, the valuation and any write —
#     with a #err that never echoes the value; the bounded-instructions proof
#     is the #err itself (an IC0522 is the unbounded signature). Called
#     DIRECTLY on the DEX as the controller (the Bridge-or-controller gate),
#     so this runs whether or not the Bridge already refuses upstream. Y is a
#     fresh bound identity so the reservation reads start at 0/0.
Y="pdcap_y"; mdx_identity_new "$Y"; YPRIN=$(principal_of "$Y")
BIND=$(call setTestEmailBinding "(principal \"$YPRIN\", \"pdcapy${SFX}@gmail.com\")" --identity anonymous)
assert_contains "§11 email binding (y)" "$BIND" "variant { ok"
CEIL="340282366920938463463374607431768211456"   # 2^128 (SafeMath.RELAY_CEILING)
CEIL_P1="${CEIL%?}7"                                # 2^128 + 1 (bash arithmetic is 64-bit; edit the last digit)
resv_field() { echo "$2" | tr -d '_\n' | tr -s ' ' | grep -oE "$1 = [0-9]+" | head -1 | awk '{print $3}'; }
RV0=$(call playDepositReservation "(principal \"$YPRIN\", \"ICPUSD\")" --query --identity anonymous)
assert_eq "§11 fresh key: nothing reserved" "0" "$(resv_field reservedUnits "$RV0")"
assert_eq "§11 fresh key: admitSeq 0"       "0" "$(resv_field admitSeq "$RV0")"
# (a) playDepositReserve with the 100 KB amount the brief names (args file)
HUGE_ARGS=$(scratch_new h15_reserve_amount.did) || exit 1
python3 -c "print('(principal \"$YPRIN\", \"ICPUSD\", ' + '9'*100000 + ' : nat, 1 : nat)')" > "$HUGE_ARGS" || exit 1
T0=$(date +%s)
RES=$(call playDepositReserve --args-file "$HUGE_ARGS" --identity anonymous)
T1=$(date +%s)
assert_contains     "§11a 100 KB amount → the relay-ceiling refusal ($((T1 - T0)) s)" "$RES" "exceeds the deposit relay ceiling"
assert_not_contains "§11a ...in bounded instructions (no IC0522)"                     "$RES" "IC0522"
assert_not_contains "§11a ...never valued (no allowance verdict)"                     "$RES" "allowance exceeded"
assert_not_contains "§11a the refusal never echoes the amount"                        "$RES" "99999999999"
RV1=$(call playDepositReservation "(principal \"$YPRIN\", \"ICPUSD\")" --query --identity anonymous)
assert_eq "§11a nothing reserved"   "0" "$(resv_field reservedUnits "$RV1")"
assert_eq "§11a admitSeq unchanged" "0" "$(resv_field admitSeq "$RV1")"
# (b) a 100 KB SEQ with a small amount: the seq wears the ceiling too (pre-fix
#     it was compared, then STORED in playAdmitSeq — 100 KB of state per call)
HUGE_SEQ=$(scratch_new h15_reserve_seq.did) || exit 1
python3 -c "print('(principal \"$YPRIN\", \"ICPUSD\", $D : nat, ' + '9'*100000 + ' : nat)')" > "$HUGE_SEQ" || exit 1
RES=$(call playDepositReserve --args-file "$HUGE_SEQ" --identity anonymous)
assert_contains     "§11b 100 KB seq → the relay-ceiling refusal" "$RES" "exceeds the deposit relay ceiling"
assert_not_contains "§11b ...no IC0522"                             "$RES" "IC0522"
RV1=$(call playDepositReservation "(principal \"$YPRIN\", \"ICPUSD\")" --query --identity anonymous)
assert_eq "§11b the huge seq was not stored (admitSeq still 0)" "0" "$(resv_field admitSeq "$RV1")"
assert_eq "§11b nothing reserved"                              "0" "$(resv_field reservedUnits "$RV1")"
# (c) creditAndRegister with the 100 KB amount (and seq = amount, the honest
#     cumulative shape): pre-fix the excess branch valued it and formatted it
HUGE_CR=$(scratch_new h15_credit_amount.did) || exit 1
python3 -c "print('(principal \"$YPRIN\", \"ICPUSD\", ' + '9'*100000 + ' : nat, ' + '9'*100000 + ' : nat, null)')" > "$HUGE_CR" || exit 1
T0=$(date +%s)
CR=$(call creditAndRegister --args-file "$HUGE_CR" --identity anonymous)
T1=$(date +%s)
assert_contains     "§11c 100 KB credit → the relay-ceiling refusal ($((T1 - T0)) s)" "$CR" "exceeds the deposit relay ceiling"
assert_not_contains "§11c ...no IC0522"                                               "$CR" "IC0522"
assert_not_contains "§11c ...no divergence text (the seq compare never ran)"          "$CR" "ledger divergence"
BAL=$(call getTestBalance "(principal \"$YPRIN\", \"ICPUSD\")" --query --identity anonymous)
assert_eq "§11c nothing credited" "0" "$(extract_first_nat "$BAL")"
# (d) a small amount with a 100 KB seq: pre-fix this hit the DIVERGENCE
#     refusal (creditAmt = seq − 0 > amount), which Nat.toText'd the seq → IC0522
HUGE_CRS=$(scratch_new h15_credit_seq.did) || exit 1
python3 -c "print('(principal \"$YPRIN\", \"ICPUSD\", $D : nat, ' + '9'*100000 + ' : nat, null)')" > "$HUGE_CRS" || exit 1
CR=$(call creditAndRegister --args-file "$HUGE_CRS" --identity anonymous)
assert_contains     "§11d 100 KB seq → the relay-ceiling refusal"        "$CR" "exceeds the deposit relay ceiling"
assert_not_contains "§11d ...no IC0522"                                   "$CR" "IC0522"
assert_not_contains "§11d ...not the divergence refusal"                  "$CR" "ledger divergence"
# (e) a 100 KB pendingUnits hint wears the ceiling too (it is compared
#     against the reservation)
HUGE_PU=$(scratch_new h15_credit_pending.did) || exit 1
python3 -c "print('(principal \"$YPRIN\", \"ICPUSD\", $D : nat, $D : nat, opt (' + '9'*100000 + ' : nat))')" > "$HUGE_PU" || exit 1
CR=$(call creditAndRegister --args-file "$HUGE_PU" --identity anonymous)
assert_contains "§11e 100 KB pendingUnits → the relay-ceiling refusal" "$CR" "exceeds the deposit relay ceiling"
BAL=$(call getTestBalance "(principal \"$YPRIN\", \"ICPUSD\")" --query --identity anonymous)
assert_eq "§11e nothing credited" "0" "$(extract_first_nat "$BAL")"
# (f) the legacy pre-check (playDepositAdmit) — amount, then an outstanding hint
ADM=$(call playDepositAdmit "(principal \"$YPRIN\", \"ICPUSD\", $CEIL_P1 : nat, vec {})" --identity anonymous)
assert_contains "§11f playDepositAdmit refuses 2^128 + 1" "$ADM" "exceeds the deposit relay ceiling"
ADM=$(call playDepositAdmit "(principal \"$YPRIN\", \"ICPUSD\", $D : nat, vec { record { \"BTC\"; $CEIL_P1 : nat } })" --identity anonymous)
assert_contains "§11f playDepositAdmit refuses a 2^128 + 1 outstanding hint" "$ADM" "exceeds the deposit relay ceiling"
# (g) the boundary: 2^128 + 1 is ceiling-refused; exactly 2^128 PASSES the
#     gate (`>` not `>=`) and is judged by the allowance — whose text formats
#     the valuation through natDisplay: ≤ 39 digits, never a bignum run
RES=$(call playDepositReserve "(principal \"$YPRIN\", \"ICPUSD\", $CEIL_P1 : nat, 1 : nat)" --identity anonymous)
assert_contains "§11g 2^128 + 1 → ceiling refusal" "$RES" "exceeds the deposit relay ceiling"
RES=$(call playDepositReserve "(principal \"$YPRIN\", \"ICPUSD\", $CEIL : nat, 1 : nat)" --identity anonymous)
assert_contains     "§11g exactly 2^128 is not ceiling-refused (the allowance judges it)" "$RES" "allowance exceeded"
assert_not_contains "§11g ...and not by the ceiling"                                    "$RES" "exceeds the deposit relay ceiling"
LONGRUN=$(echo "$RES" | grep -oE '[0-9]{40,}' | head -1)
assert_eq "§11g the allowance refusal carries no 40+-digit run (display-clamped)" "" "$LONGRUN"
RV1=$(call playDepositReservation "(principal \"$YPRIN\", \"ICPUSD\")" --query --identity anonymous)
assert_eq "§11g the refused 2^128 reserved nothing" "0" "$(resv_field reservedUnits "$RV1")"
# (h) the zero twin, for the record, and a legitimate admission + settlement
#     right after the refusals: the key is unharmed
RES=$(call playDepositReserve "(principal \"$YPRIN\", \"ICPUSD\", 0 : nat, 1 : nat)" --identity anonymous)
assert_contains "§11h amount 0 still refused" "$RES" "Amount must be positive"
RES=$(call playDepositReserve "(principal \"$YPRIN\", \"ICPUSD\", $D : nat, $D : nat)" --identity anonymous)
assert_ok "§11h a normal admission lands after the refusals" "$RES"
RV1=$(call playDepositReservation "(principal \"$YPRIN\", \"ICPUSD\")" --query --identity anonymous)
assert_eq "§11h reserved = the admitted units" "$D" "$(resv_field reservedUnits "$RV1")"
assert_eq "§11h admitSeq = the admission seq"  "$D" "$(resv_field admitSeq "$RV1")"
CR=$(call creditAndRegister "(principal \"$YPRIN\", \"ICPUSD\", $D : nat, $D : nat, null)" --identity anonymous)
assert_ok "§11h ...and its claim settles" "$CR"
BAL=$(call getTestBalance "(principal \"$YPRIN\", \"ICPUSD\")" --query --identity anonymous)
assert_eq "§11h credited exactly the admitted units" "$D" "$(extract_first_nat "$BAL")"

# §12 H-33 (F47): the admission VALUATION wears a freshness bar — a play
#     deposit is valued only at a FRESH, UN-PENDED mark. Pre-fix,
#     markValueUsd read the pool's refPrice with no age bound and no
#     circuit-breaker check, so a deposit made while an asset's mark sat
#     frozen below market was charged allowance at the stale value (RED on
#     4efbcf9: every §12a/§12c refusal came back `ok` — admitted, consumed,
#     reserved). The bar is the 5-min MARGIN wall (MARGIN_MAX_REFPRICE_AGE_NS),
#     NOT the 60 s LP/swap bar: a quiet market refreshes at ≥ 45 s age on a
#     30 s cadence, so §12b pins that a 240 s-old mark still admits. Both
#     admission callers wear it — the Bridge path (devSimulateDeposit →
#     playDepositReserve), the direct controller admission, and the
#     claim-time excess path of creditAndRegister — and a refusal is a plain
#     #err the Bridge rolls back on (W3-04): nothing created, nothing
#     consumed, nothing reserved. ICPUSD is 1:1 and never stale. Needs the
#     dev hooks (setTestRefPriceUpdatedNs backdates the stamp WITHOUT
#     touching the price; setTestPendingJump injects a breaker pend;
#     setAmmRefPrice re-stamps now and clears the pend) → a loud ⊘ on #play.
if [ "$MODE" = "dev" ]; then
  H33_MKT="BTC-ICPUSD"; H33_AMT=10000000   # 0.1 BTC
  pool_field() { echo "$2" | tr -d '\n' | tr -s ' ' | grep -oE "$1 = [0-9_]+" | head -1 | grep -oE '[0-9_]+' | tr -d '_'; }
  h33_stamp() { pool_field refPriceUpdatedNs "$(call getAmmPool "(\"$H33_MKT\")" --query --identity anonymous)"; }
  H33_PX=$(pool_field refPrice "$(call getAmmPool "(\"$H33_MKT\")" --query --identity anonymous)")
  assert_gt "§12 BTC carries a mark" "${H33_PX:-0}" "0"
  Z="pdcap_z"; mdx_identity_new "$Z"; ZPRIN=$(principal_of "$Z")
  BIND=$(call setTestEmailBinding "(principal \"$ZPRIN\", \"pdcapz${SFX}@gmail.com\")" --identity anonymous)
  assert_contains "§12 email binding (z)" "$BIND" "variant { ok"
  bcall createDepositAddress '()' --identity "$Z" >/dev/null
  # The live feed re-stamps every market on a 30 s cadence — a refresh landing
  # between a backdate and its probe un-stales the mark (seen: the direct
  # admission admitted 10 s after the simulate was refused). Pause the timers
  # for the section (resumed at its end) and re-backdate before every probe.
  call setTestTimersPaused '(true)' --identity anonymous >/dev/null
  # h33_backdate N: re-stamp the mark to NOW (same price; clears any pend),
  # then set its stamp N s into the past — absolute, never cumulative.
  h33_backdate() {
    call setAmmRefPrice "(\"$H33_MKT\", $H33_PX : nat)" --identity anonymous >/dev/null
    call setTestRefPriceUpdatedNs "(\"$H33_MKT\", $(( $(h33_stamp) - $1 * 1000000000 )) : int)" --identity anonymous >/dev/null
  }
  # (a) STALE: backdate the stamp 400 s (past the 5-min wall); the price VALUE is untouched
  h33_backdate 400
  SIM=$(bcall devSimulateDeposit "(\"BTC\", $H33_AMT : nat)" --identity "$Z")
  assert_contains     "§12a a BTC deposit at a 400 s-old mark is REFUSED"         "$SIM" "BTC mark is stale"
  assert_contains     "§12a ...actionably (when to retry)"                        "$SIM" "try again once the oracle refreshes"
  assert_not_contains "§12a ...and not by the allowance"                          "$SIM" "allowance exceeded"
  DEP=$(bcall getMyDeposits '()' --identity "$Z")
  assert_not_contains "§12a nothing created on the Bridge (W3-04 rollback)"        "$DEP" "pending = $H33_AMT"
  ALW=$(call getPlayDepositAllowance '()' --query --identity "$Z")
  assert_contains     "§12a nothing consumed"                                     "$ALW" "usedUsd = 0"
  RV=$(call playDepositReservation "(principal \"$ZPRIN\", \"BTC\")" --query --identity anonymous)
  assert_eq           "§12a nothing reserved"                                     "0" "$(resv_field reservedUnits "$RV")"
  h33_backdate 400
  RES=$(call playDepositReserve "(principal \"$ZPRIN\", \"BTC\", $H33_AMT : nat, $H33_AMT : nat)" --identity anonymous)
  assert_contains     "§12a the direct admission refuses at the stale mark too"    "$RES" "BTC mark is stale"
  h33_backdate 400
  CR=$(call creditAndRegister "(principal \"$ZPRIN\", \"BTC\", $H33_AMT : nat, $H33_AMT : nat, null)" --identity anonymous)
  assert_contains     "§12a creditAndRegister's excess path refuses at the stale mark" "$CR" "BTC mark is stale"
  BAL=$(call getTestBalance "(principal \"$ZPRIN\", \"BTC\")" --query --identity anonymous)
  assert_eq           "§12a nothing credited"                                     "0" "$(extract_first_nat "$BAL")"
  SIM=$(bcall devSimulateDeposit "(\"ICPUSD\", $D : nat)" --identity "$Z")
  assert_ok           "§12a an ICPUSD deposit (1:1, no mark) is unaffected by the stale BTC mark" "$SIM"
  # (b) the bar is the 5-min wall, not the 60 s LP bar: a 240 s-old mark still admits
  h33_backdate 240
  SIM=$(bcall devSimulateDeposit "(\"BTC\", $H33_AMT : nat)" --identity "$Z")
  assert_ok           "§12b a 240 s-old mark (past the 60 s LP bar, under the 5-min wall) ADMITS" "$SIM"
  ALW=$(call getPlayDepositAllowance '()' --query --identity "$Z")
  H33_USED=$(extract_nat usedUsd "$ALW")
  assert_gt           "§12b ...and consumed mark value on top of the ICPUSD deposit" "${H33_USED:-0}" "$D"
  # (c) PENDED: a just-stamped mark held out by the circuit breaker refuses; cleared → admits
  call setAmmRefPrice "(\"$H33_MKT\", $H33_PX : nat)" --identity anonymous >/dev/null          # re-stamp now (clears any pend)
  call setTestPendingJump "(\"BTC\", opt ($H33_PX : nat), null)" --identity anonymous >/dev/null
  SIM=$(bcall devSimulateDeposit "(\"BTC\", $H33_AMT : nat)" --identity "$Z")
  assert_contains     "§12c REFUSED while the BTC mark is held pending a price-jump confirmation" "$SIM" "pending a price-jump confirmation"
  DEP=$(bcall getMyDeposits '()' --identity "$Z")
  assert_not_contains "§12c nothing created on the Bridge"                          "$DEP" "pending = $((H33_AMT * 2))"
  ALW=$(call getPlayDepositAllowance '()' --query --identity "$Z")
  assert_contains     "§12c nothing consumed (used unchanged)"                      "$ALW" "usedUsd = $H33_USED"
  # the claim-time excess path: 2× the reserved units → the excess is valued → refused under the pend
  CR=$(call creditAndRegister "(principal \"$ZPRIN\", \"BTC\", $((H33_AMT * 2)) : nat, $((H33_AMT * 2)) : nat, null)" --identity anonymous)
  assert_contains     "§12c creditAndRegister's excess path refuses under the pend"   "$CR" "pending a price-jump confirmation"
  BAL=$(call getTestBalance "(principal \"$ZPRIN\", \"BTC\")" --query --identity anonymous)
  assert_eq           "§12c nothing credited"                                       "0" "$(extract_first_nat "$BAL")"
  call setTestPendingJump '("BTC", null, null)' --identity anonymous >/dev/null      # clear the pend
  SIM=$(bcall devSimulateDeposit "(\"BTC\", $H33_AMT : nat)" --identity "$Z")
  assert_ok           "§12c ADMITTED once the pend clears"                          "$SIM"
  ALW=$(call getPlayDepositAllowance '()' --query --identity "$Z")
  H33_USED2=$(extract_nat usedUsd "$ALW")
  assert_gt           "§12c ...consuming mark value at admission"                   "${H33_USED2:-0}" "$H33_USED"
  # (d) no dead ends: both admissions (b, c) claim unit-for-unit, no re-valuation
  bcall devConfirmDeposits '()' --identity "$Z" >/dev/null
  CLAIM=$(bcall claim '("BTC")' --identity "$Z")
  assert_contains     "§12d the two admitted BTC deposits claim"                     "$CLAIM" "ok = $((H33_AMT * 2))"
  ALW=$(call getPlayDepositAllowance '()' --query --identity "$Z")
  assert_contains     "§12d the claim consumed nothing more (used unchanged)"        "$ALW" "usedUsd = $H33_USED2"
  call setTestTimersPaused '(false)' --identity anonymous >/dev/null   # resume venue dynamics
else
  skip_section "§12 H-33 freshness bar needs the dev hooks (setTestRefPriceUpdatedNs / setTestPendingJump / setAmmRefPrice)"
fi

if [ "$_TEST_ERRORS" -eq 0 ]; then
  echo -e "\n\033[0;32mPASS: test_play_deposit_cap\033[0m"; exit 0
else
  echo -e "\n\033[0;31mFAIL: test_play_deposit_cap ($_TEST_ERRORS failing assertions)\033[0m"; exit 1
fi
