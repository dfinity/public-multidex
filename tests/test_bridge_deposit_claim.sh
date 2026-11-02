#!/bin/bash
# tests/test_bridge_deposit_claim.sh
#
# End-to-end regression for the (stub) Bridge canister ↔ DEX deposit→claim path
# (src/bridge/main.mo + backend creditAndRegister). Covers:
#   • createDepositAddress reveals the per-chain addresses
#   • two-ledger CREDIT axis: devSimulateDeposit→pending, devConfirmDeposits→
#     confirmed; claimable = confirmed − claimed
#   • claim() credits the DEX virtual wallet (via the inter-canister
#     creditAndRegister, which also REGISTERS the user) and advances the
#     `claimed` high-water mark
#   • idempotency: a second claim with nothing new is a no-op (balance unchanged)
#   • a later confirm+claim credits ONLY the delta
#   • creditAndRegister gating: a rogue (non-bridge, non-controller) caller is
#     rejected and gets no credit; amount 0 is rejected
#
# NON-DESTRUCTIVE: scoped to a throwaway identity and never calls resetExchange,
# so it is safe to run against a live/seeded exchange. Uses _lib.sh assertions but
# its own summary (the global vault/book invariants are irrelevant to this path).

source "$(dirname "$0")/_lib.sh"

BRIDGE_ID=$(icp canister status bridge  --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
BACKEND_ID=$(icp canister status backend --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
if [ -z "$BRIDGE_ID" ] || [ -z "$BACKEND_ID" ]; then
  echo "bridge/backend canister not found — deploy them first (icp deploy)"; exit 1
fi

# bridge-canister call wrapper (the _lib.sh `call` targets the backend).
bcall() { echo "y" | icp canister call bridge "$@" 2>&1; }

echo "── test_bridge_deposit_claim ──"

# (0) wire bridge ↔ DEX (idempotent; controller = anonymous locally)
call  setBridge "(principal \"$BRIDGE_ID\")"  --identity anonymous >/dev/null
bcall setDex    "(principal \"$BACKEND_ID\")" --identity anonymous >/dev/null

# throwaway users (virgin each run → clean bridge ledger; deleted on EXIT — tests/_lib.sh)
U="brdgtest"; ROGUE="brdgrogue"
mdx_identity_new "$U"; mdx_identity_new "$ROGUE"
UPRIN=$(principal_of "$U"); RPRIN=$(principal_of "$ROGUE")

# Bind U to a throwaway verified email (unique per run — bindings are
# first-come and survive reruns): on #play the deposit allowance gate refuses
# unbound principals at admission; on #dev (no cap) the binding is inert.
call setTestEmailBinding "(principal \"$UPRIN\", \"brdgtest${RANDOM}$$@gmail.com\")" --identity anonymous >/dev/null

# The play deposit cap is active on EVERY non-production posture (posture
# doctrine, main.mo DEPLOY_MODE) and values a BTC deposit at the venue mark
# AT SIMULATE TIME. In a full-suite run an earlier resetExchange can leave
# this venue with no BTC mark, which refuses the simulate outright ("no mark
# price") and cascades through every claim below. Provision a mark via the
# dev hook; a #play venue always carries live marks (GEPTOR requotes), and
# the hook is dead there anyway.
MODE=$(call getDeployMode '()' --query 2>/dev/null | grep -oE 'dev|play|production' | head -1)
if [ "$MODE" = "dev" ]; then
  call createAmmPool '("BTC-ICPUSD")' --identity anonymous >/dev/null 2>&1 || true
  call setAmmRefPrice '("BTC-ICPUSD", 5000000000000 : nat)' --identity anonymous >/dev/null   # $50k valuation mark
fi

# (1) addresses revealed, in native formats
ADDRS=$(bcall createDepositAddress '()' --identity "$U")
assert_contains "createDepositAddress lists BTC" "$ADDRS" "BTC"
assert_contains "BTC address is bech32 (bc1q…)"  "$ADDRS" "bc1q"

# (2) simulate a 0.5 BTC deposit → pending only
bcall devSimulateDeposit '("BTC", 50000000 : nat)' --identity "$U" >/dev/null
DEP=$(bcall getMyDeposits '()' --identity "$U")     # BTC is the first record
assert_eq "BTC pending after simulate" "50000000" "$(extract_nat pending "$DEP")"
assert_eq "BTC confirmed still 0"      "0"        "$(extract_nat confirmed "$DEP")"
assert_eq "BTC claimable still 0"      "0"        "$(extract_nat claimable "$DEP")"

# (3) confirm → confirmed; claimable = confirmed − claimed
bcall devConfirmDeposits '()' --identity "$U" >/dev/null
DEP=$(bcall getMyDeposits '()' --identity "$U")
assert_eq "BTC confirmed after confirm" "50000000" "$(extract_nat confirmed "$DEP")"
assert_eq "BTC pending back to 0"       "0"        "$(extract_nat pending "$DEP")"
assert_eq "BTC claimable = confirmed"   "50000000" "$(extract_nat claimable "$DEP")"

# (4) claim → #ok; DEX wallet credited + user registered (credit proves the path ran)
# getTestBalance is scoped to self-or-controller, and $UPRIN/$RPRIN are
# throwaway identities that are NOT us — so read them as the controller
# (anonymous, locally); the bare ambient identity would read silent zeros.
CLAIM=$(bcall claim '("BTC")' --identity "$U")
assert_contains "claim BTC returns ok = 50000000" "$CLAIM" "ok = 50000000"
BAL=$(call getTestBalance "(principal \"$UPRIN\", \"BTC\")" --identity anonymous)
assert_eq "DEX BTC balance credited" "50000000" "$(extract_first_nat "$BAL")"

# (5) claimed high-water advanced, claimable back to 0
DEP=$(bcall getMyDeposits '()' --identity "$U")
assert_eq "BTC claimed = 50000000" "50000000" "$(extract_nat claimed "$DEP")"
assert_eq "BTC claimable now 0"    "0"        "$(extract_nat claimable "$DEP")"

# (6) idempotent re-claim: rejected, balance unchanged (no double-credit)
CLAIM2=$(bcall claim '("BTC")' --identity "$U")
assert_contains "re-claim rejected (nothing to claim)" "$CLAIM2" "Nothing to claim"
BAL=$(call getTestBalance "(principal \"$UPRIN\", \"BTC\")" --identity anonymous)
assert_eq "DEX BTC balance unchanged after re-claim" "50000000" "$(extract_first_nat "$BAL")"

# (7) a later confirm+claim credits ONLY the new delta (0.25 BTC)
bcall devSimulateDeposit '("BTC", 25000000 : nat)' --identity "$U" >/dev/null
bcall devConfirmDeposits '()' --identity "$U" >/dev/null
CLAIM3=$(bcall claim '("BTC")' --identity "$U")
assert_contains "second claim ok = 25000000 (delta only)" "$CLAIM3" "ok = 25000000"
BAL=$(call getTestBalance "(principal \"$UPRIN\", \"BTC\")" --identity anonymous)
assert_eq "DEX BTC balance = 0.75 cumulative" "75000000" "$(extract_first_nat "$BAL")"

# (8) creditAndRegister gating: a rogue (non-bridge, non-controller) caller is refused, no credit
# H-30: an UNREGISTERED rogue never reaches the body — inspect admits unknown
# principals to the pre-registration set only, so the refusal is pre-consensus.
ROG=$(call creditAndRegister "(principal \"$RPRIN\", \"BTC\", 100000000 : nat, 1 : nat, null)" --identity "$ROGUE")
if echo "$ROG" | grep -qiE "refus|inspect"; then _ok "unregistered rogue creditAndRegister refused at the gate (H-30)"
else _fail "unregistered rogue creditAndRegister was NOT refused at the gate: $(echo "$ROG" | head -c 200)"; fi
# The body-level gate is pinned with a REGISTERED rogue (the #dev faucet
# registers its caller): only the Bridge (or a controller) may credit.
call addTestTokens '("ICPUSD", 100000000 : nat)' --identity "$ROGUE" >/dev/null 2>&1
ROG=$(call creditAndRegister "(principal \"$RPRIN\", \"BTC\", 100000000 : nat, 1 : nat, null)" --identity "$ROGUE")
assert_contains "registered rogue creditAndRegister rejected by the body" "$ROG" "Only the Bridge canister may credit deposits"
# Controller read — as the ambient identity this returned a scoped 0 and the
# no-credit assertion passed vacuously; anonymous sees the real balance.
RBAL=$(call getTestBalance "(principal \"$RPRIN\", \"BTC\")" --identity anonymous)
assert_eq "rogue received NO credit" "0" "$(extract_first_nat "$RBAL")"

# (9) amount 0 rejected even for the controller (isolates the amount check past the gate)
ZERO=$(call creditAndRegister "(principal \"$UPRIN\", \"BTC\", 0 : nat, 999 : nat, null)" --identity anonymous)
assert_contains "amount 0 rejected" "$ZERO" "Amount must be positive"

# ── (10) Asset allowlist — docs/issue-triage-2026-08.md §2.15 ─────
# ASSETS was declared and never used as a membership test, and there is no
# length check anywhere in the Bridge, so an arbitrary Text went straight into
# a permanent map key. Both write paths must now refuse an unknown asset.
BAD=$(bcall claim '("NOT-A-REAL-ASSET")' --identity "$U")
assert_contains "claim refuses an unsupported asset" "$BAD" "Unsupported asset"
BADSIM=$(bcall devSimulateDeposit '("NOT-A-REAL-ASSET", 1000 : nat)' --identity "$U")
assert_contains "devSimulateDeposit refuses an unsupported asset" "$BADSIM" "Unsupported asset"
# A long junk asset is the unbounded-state shape specifically (no length check).
LONGJUNK=$(printf 'A%.0s' $(seq 1 300))
BADLONG=$(bcall claim "(\"$LONGJUNK\")" --identity "$U")
assert_contains "claim refuses a 300-char asset name" "$BADLONG" "Unsupported asset"

# The allowlist the Bridge advertises must be the SAME list it enforces —
# every advertised asset has to get past the membership gate (it then fails on
# the nothing-to-claim check, which proves it passed validation).
SUPPORTED=$(bcall getSupportedAssets '()' --identity "$U")
assert_contains "getSupportedAssets lists ICPUSD" "$SUPPORTED" "ICPUSD"
for a in BTC ETH SOL ICP ICPUSD; do
  R=$(bcall claim "(\"$a\")" --identity "$U")
  assert_not_contains "$a passes the asset gate (advertised == enforced)" "$R" "Unsupported asset"
done

# A no-op claim on a SUPPORTED asset must still report exactly as before —
# the fix reorders the ledger lookup below the rejection, and an absent row is
# definitionally confirmed==claimed==0, so the caller-visible behaviour is
# unchanged. (That the rejection now writes NOTHING is not observable through
# this API — an absent row and a zeroed row both render as zeros in
# getMyDeposits — so it is pinned at source by tests/test_deploy_hygiene.sh's
# "claim never calls the get-or-create ledgerOf" assertion.)
NOOP=$(bcall claim '("ETH")' --identity "$U")
assert_contains "no-op claim still says nothing to claim" "$NOOP" "Nothing to claim"

# ── (11) Posture — §2.15, and the reason the dev hooks stay alive ──
# The Bridge now has a posture of its own instead of outsourcing its safety to
# the DEX's playDepositCap (which is null on #dev AND #production).
BMODE=$(bcall getDeployMode '()' --identity "$U" | tr -d '()" ' | tr -d "\n")
DMODE=$(call getDeployMode '()' | tr -d '()" ' | tr -d "\n")
_ok "postures — DEX #$DMODE / bridge #$BMODE"
# One-directional, not equality: a #dev DEX against a #play Bridge is normal
# on a local replica (the Bridge is stricter, which is safe). What must never
# happen is the Bridge being MORE PERMISSIVE than the DEX it credits — a
# value-bearing DEX with a stub Bridge still answering its unbacked-credit
# hooks is §2.15 wide open.
if [ "$DMODE" = "production" ] && [ "$BMODE" != "production" ]; then
  _fail "DEX is #production but the deployed bridge is #$BMODE — unbacked credit hooks are live"
else
  _ok "deployed bridge is not more permissive than the deployed DEX"
fi

# The posture gate is at #production, NOT at #dev. That is load-bearing:
# devSimulateDeposit is the live #play on-ramp — the Deposit page calls it
# (src/frontend/src/main.js) and the play allowance is consumed through it via
# the DEX's playDepositReserve — so gating it to #dev would delete the only
# on-ramp the committed default posture has.
#
# Assert that directly rather than inferring it from the sections above: the
# hook may legitimately refuse for OTHER reasons (an unverified principal on
# #play, say), but it must never refuse because of the posture.
POSTURE_PROBE=$(bcall devSimulateDeposit '("BTC", 1000 : nat)' --identity "$U")
assert_not_contains "devSimulateDeposit is not posture-refused on #play" \
  "$POSTURE_PROBE" "disabled on #production"
assert_not_contains "devSimulateDeposit is not gated to dev-only" \
  "$POSTURE_PROBE" "dev-only hook"

# ── (12–15) #55 "phantom pending" — a deposit the DEX refused in the catch
# arm can never become a confirmed, claimable balance ────────────────────
# Pre-fix: devSimulateDeposit wrote admittedUnits + pending AHEAD of the await
# (W3-04) and the catch arm KEPT both; devConfirmDeposits then moved the
# orphan pending to confirmed for an amount the DEX never reserved, and the
# claim died in creditAndRegister's excess branch — identically on retry —
# poisoning every later deposit on the asset (claim is all-or-nothing).
# Needs the #dev hooks (setTestPlayDepositCap, devTestStrandAdmission) and
# stops the DEX canister on THIS venue, so it is #dev-only.
if [ "$MODE" = "dev" ]; then
  # ETH keeps these sections independent of the BTC numbers above (§11 left
  # a BTC pending behind). The cap values at the venue mark — provision one.
  call createAmmPool '("ETH-ICPUSD")' --identity anonymous >/dev/null 2>&1 || true
  call setAmmRefPrice '("ETH-ICPUSD", 300000000000 : nat)' --identity anonymous >/dev/null   # $3k mark
  call setTestPlayDepositCap '(null)' --identity anonymous >/dev/null   # default cap, in case an earlier suite left an override
  eth_field() { echo "$2" | tr -d '_\n' | tr -s ' ' | grep -oE 'asset = "ETH"[^}]*' | grep -oE "$1 = [0-9]+" | awk '{print $3}'; }
  used_usd()  { call getPlayDepositAllowance '()' --identity "$U" | tr -d '_\n' | tr -s ' ' | grep -oE 'usedUsd = [0-9]+' | awk '{print $3}'; }

  # A legitimate ETH deposit FIRST, so the stopped-DEX confirm below has a
  # real pending to leave alone (fail closed ≠ drop).
  SIM=$(bcall devSimulateDeposit '("ETH", 100000000 : nat)' --identity "$U")
  assert_ok "§12 legitimate ETH deposit admitted (DEX running)" "$SIM"
  DEP=$(bcall getMyDeposits '()' --identity "$U")
  assert_eq "§12 ETH pending = 1.0 before the DEX stops" "100000000" "$(eth_field pending "$DEP")"
  USED_BEFORE=$(used_usd)

  # (12) DEX STOPPED — the reporter's corrected trigger (every DEX upgrade goes
  # through a stop): the Bridge's call is rejected at the system level and
  # lands in the catch arm.
  icp canister stop backend --identity anonymous >/dev/null 2>&1
  SIM=$(bcall devSimulateDeposit '("ETH", 50000000 : nat)' --identity "$U")
  assert_contains "§12 simulate against a stopped DEX is refused" "$SIM" "err"
  assert_contains "§12 the refusal says nothing was created" "$SIM" "nothing was created"
  DEP=$(bcall getMyDeposits '()' --identity "$U")
  assert_eq "§12 catch arm rolled the pending back (still exactly the legit 1.0)" "100000000" "$(eth_field pending "$DEP")"
  # Confirm with the DEX down must NOT mint a claimable it cannot verify —
  # and must not drop the legitimate pending either.
  bcall devConfirmDeposits '()' --identity "$U" >/dev/null
  DEP=$(bcall getMyDeposits '()' --identity "$U")
  assert_eq "§12 confirm with the DEX stopped leaves the pending pending" "100000000" "$(eth_field pending "$DEP")"
  assert_eq "§12 confirm with the DEX stopped confirmed nothing"         "0"         "$(eth_field confirmed "$DEP")"
  icp canister start backend --identity anonymous >/dev/null 2>&1
  # A retry the moment the DEX is back is the normal path again.
  RETRY=$(bcall devSimulateDeposit '("ETH", 50000000 : nat)' --identity "$U")
  assert_ok "§12 the same deposit admits once the DEX is back" "$RETRY"
  bcall devConfirmDeposits '()' --identity "$U" >/dev/null
  DEP=$(bcall getMyDeposits '()' --identity "$U")
  assert_eq "§12 confirm with the DEX back: confirmed = 1.0 + 0.5" "150000000" "$(eth_field confirmed "$DEP")"
  assert_eq "§12 nothing left pending"                             "0"         "$(eth_field pending "$DEP")"
  USED_AFTER=$(used_usd)
  # 1.5 ETH @ $3k = $4,500 of allowance for the two ADMITTED deposits; the
  # rejected one charged nothing (the DEX never ran).
  assert_eq "§12 allowance moved by exactly the admitted 0.5 ETH (\$1,500)" "$(( ${USED_BEFORE:-0} + 150000000000 ))" "${USED_AFTER:-0}"
  CLAIM=$(bcall claim '("ETH")' --identity "$U")
  assert_contains "§12 claim settles the whole 1.5 ETH against its reservation" "$CLAIM" "ok = 150000000"

  # (13) DEX RUNNING and the admission gate refusing (explicit #err): the
  # existing rollback still holds. A $1 cap makes any priced deposit over.
  call setTestPlayDepositCap '(opt (100000000 : nat))' --identity anonymous >/dev/null
  SIM=$(bcall devSimulateDeposit '("ETH", 100000000 : nat)' --identity "$U")
  assert_contains "§13 over-allowance deposit refused by the DEX (#err path)" "$SIM" "allowance exceeded"
  DEP=$(bcall getMyDeposits '()' --identity "$U")
  assert_eq "§13 explicit-#err rollback: ETH pending stays 0" "0" "$(eth_field pending "$DEP")"
  call setTestPlayDepositCap '(null)' --identity anonymous >/dev/null

  # (14) The strand the catch arm cannot see — a pending written ahead whose
  # continuation never ran its rollback while the DEX reserved nothing (told
  # as an upgrade in the await window; #55 (d): an upgrade cannot land there,
  # a trap is the shape). Manufactured by the dev hook; the DEX holds no
  # reservation and its applied admission seq lags the Bridge's counter by
  # exactly the phantom.
  #
  # devTestStrandAdmission is gated on the BRIDGE's own posture literal
  # (src/bridge/main.mo DEPLOY_MODE → IS_DEV), not the DEX's. Under the seat
  # posture rhythm only src/backend/main.mo is flipped, so a #dev DEX beside a
  # #play Bridge is the NORMAL local shape (§11 says so) and the hook refuses
  # with "dev-only hook (posture: play/production)". Cause ledger 2026-09-04
  # (task 1788485999): the old `assert_contains ... "ok"` matched the "hook"
  # inside that refusal, so the refusal PASSED and the phantom-pending read one
  # line later went red as if the write-ahead were broken. §14–15 gate on the
  # Bridge's posture (as test_bridge_write_ahead / test_season_wipe_fence do)
  # and pin the exact #ok, never a substring a refusal can contain.
  if [ "$BMODE" = "dev" ]; then
  STR=$(bcall devTestStrandAdmission "(principal \"$UPRIN\", \"ETH\", 30000000 : nat)" --identity anonymous)
  assert_ok "§14 strand hook accepted (Bridge #dev)" "$STR"
  DEP=$(bcall getMyDeposits '()' --identity "$U")
  assert_eq "§14 phantom pending visible before confirm" "30000000" "$(eth_field pending "$DEP")"
  RSV=$(call playDepositReservation "(principal \"$UPRIN\", \"ETH\")" --query --identity anonymous)
  assert_contains "§14 DEX reservation view is readable by a controller" "$RSV" "capActive = true"
  assert_eq "§14 DEX applied seq = the 1.5 ETH it admitted (the phantom is past it)" "150000000" "$(extract_nat admitSeq "$RSV")"
  ROGUE_RSV=$(call playDepositReservation "(principal \"$UPRIN\", \"ETH\")" --query --identity "$ROGUE")
  assert_contains "§14 reservation view is Bridge/controller-only" "$ROGUE_RSV" "Only the Bridge canister"
  bcall devConfirmDeposits '()' --identity "$U" >/dev/null
  DEP=$(bcall getMyDeposits '()' --identity "$U")
  assert_eq "§14 confirm DROPPED the phantom (pending 0)"          "0"         "$(eth_field pending "$DEP")"
  assert_eq "§14 confirm did not mint it (confirmed unchanged 1.5)" "150000000" "$(eth_field confirmed "$DEP")"
  assert_eq "§14 nothing claimable from the phantom"               "0"         "$(eth_field claimable "$DEP")"

  # (15) A later legitimate deposit on the SAME asset claims cleanly — the
  # counter re-synced to the DEX's seq, so this admission is reserved (not
  # no-op'd as a replay) and the claim settles inside its reservation.
  SIM=$(bcall devSimulateDeposit '("ETH", 200000000 : nat)' --identity "$U")
  assert_ok "§15 post-phantom deposit admitted" "$SIM"
  RSV=$(call playDepositReservation "(principal \"$UPRIN\", \"ETH\")" --query --identity anonymous)
  assert_eq "§15 DEX reserved exactly the new 2.0 ETH" "200000000" "$(extract_nat reservedUnits "$RSV")"
  assert_eq "§15 DEX applied seq advanced to 3.5 ETH"  "350000000" "$(extract_nat admitSeq "$RSV")"
  bcall devConfirmDeposits '()' --identity "$U" >/dev/null
  CLAIM=$(bcall claim '("ETH")' --identity "$U")
  assert_contains "§15 later legitimate deposit claims cleanly (ok = 2.0 ETH)" "$CLAIM" "ok = 200000000"
  BAL=$(call getTestBalance "(principal \"$UPRIN\", \"ETH\")" --identity anonymous)
  assert_eq "§15 DEX ETH balance = 1.5 + 2.0, never the phantom" "350000000" "$(extract_first_nat "$BAL")"
  else
    skip_section "§14–15 (devTestStrandAdmission needs the BRIDGE at #dev; the venue's Bridge is #${BMODE:-unknown} — flip src/bridge/main.mo to #dev, rebuild + upgrade the Bridge through bridge_upgrade_if_posture_matches (tests/_lib.sh), restore #play, then rerun to exercise the phantom-drop reconciliation)"
  fi

  # ── (16) Settlement-side twin of #55 (task 3088472021): an EXCESS claim must
  # not zero the reservation of a still-PENDING admitted deposit ──────────
  # The DEX reservation is per (user, token) and covers EVERY admitted-but-
  # uncredited unit — a deposit still pending on the Bridge included. The
  # Bridge's claimable (confirmed − claimed) is disjoint from its pending, so
  # a claim can never cover pending units; pre-fix, creditAndRegister's excess
  # branch (a claim larger than the reservation: a legacy claimable, an ops
  # credit, a re-armed allowance) nevertheless set the WHOLE reservation to
  # zero, and the pending's own claim then ran the excess branch again — valued
  # and debited a SECOND time. Fixed by the Bridge naming its pending units on
  # the claim (creditAndRegister's trailing `opt nat`, additive) and the DEX
  # fencing them off from settlement. Needs neither Bridge dev hook: the
  # legacy-style claimable is manufactured with adminResetPlayAllowances (the
  # ONE way a confirmed deposit loses its reservation on a posture whose cap
  # cannot be disarmed — the allowance re-arm the #55 note names). That re-arm
  # is venue-wide, which is why this stays inside the #dev block.
  # ICPUSD: valued 1:1 (no mark to provision), untouched by §1–15 for $U.
  dep_field() { echo "$3" | tr -d '_\n' | tr -s ' ' | grep -oE "asset = \"$1\"[^}]*" | grep -oE "$2 = [0-9]+" | awk '{print $3}'; }
  rsv_units() { extract_nat reservedUnits "$(call playDepositReservation "(principal \"$UPRIN\", \"ICPUSD\")" --query --identity anonymous)"; }
  DEP_A=500000000000   # $5,000
  DEP_B=200000000000   # $2,000
  call setTestPlayDepositCap '(null)' --identity anonymous >/dev/null   # default cap
  SIM=$(bcall devSimulateDeposit "(\"ICPUSD\", $DEP_A : nat)" --identity "$U")
  assert_ok "§16 deposit A admitted (reserved on the DEX)" "$SIM"
  bcall devConfirmDeposits '()' --identity "$U" >/dev/null
  DEP=$(bcall getMyDeposits '()' --identity "$U")
  assert_eq "§16 A confirmed, claimable = A, not claimed" "$DEP_A" "$(dep_field ICPUSD claimable "$DEP")"
  assert_eq "§16 DEX reserved exactly A"                   "$DEP_A" "$(rsv_units)"
  # The re-arm strips A's reservation: A is now a legacy-style claimable —
  # confirmed units the DEX holds NO reservation for.
  RESET=$(call adminResetPlayAllowances '()' --identity anonymous)
  assert_ok "§16 allowance re-arm accepted" "$RESET"
  assert_eq "§16 re-arm stripped A's reservation (legacy-style claimable)" "0" "$(rsv_units)"
  # Deposit B: admitted (allowance charged, units reserved) and left PENDING.
  SIM=$(bcall devSimulateDeposit "(\"ICPUSD\", $DEP_B : nat)" --identity "$U")
  assert_ok "§16 deposit B admitted" "$SIM"
  DEP=$(bcall getMyDeposits '()' --identity "$U")
  assert_eq "§16 B is pending, A still the only claimable" "$DEP_B" "$(dep_field ICPUSD pending "$DEP")"
  assert_eq "§16 DEX reservation = B (the pending's units)"  "$DEP_B" "$(rsv_units)"
  assert_eq "§16 allowance after the re-arm = B (charged at admission)" "$DEP_B" "$(used_usd)"
  # The EXCESS claim: A's claimable exceeds the reservation (B). A is valued
  # and debited at claim time (the value-integrity backstop) — and B's
  # reservation must SURVIVE it.
  CLAIM=$(bcall claim '("ICPUSD")' --identity "$U")
  assert_contains "§16 excess claim of A settles (ok = A)" "$CLAIM" "ok = $DEP_A"
  USED_AFTER_A=$(used_usd)
  assert_eq "§16 A was valued + debited at claim (used = B + A)" "$((DEP_B + DEP_A))" "${USED_AFTER_A:-0}"
  assert_eq "§16 B's reservation survives A's excess claim (reservedUnits = B, not 0)" "$DEP_B" "$(rsv_units)"
  # Now B confirms and claims: it must settle 1:1 against its reservation —
  # NO second charge (pre-fix: reserved == 0 → excess branch → used += B).
  bcall devConfirmDeposits '()' --identity "$U" >/dev/null
  DEP=$(bcall getMyDeposits '()' --identity "$U")
  assert_eq "§16 B confirmed → claimable = B" "$DEP_B" "$(dep_field ICPUSD claimable "$DEP")"
  CLAIM=$(bcall claim '("ICPUSD")' --identity "$U")
  assert_contains "§16 B claims (ok = B)" "$CLAIM" "ok = $DEP_B"
  assert_eq "§16 B settled against its reservation: usedUsd UNCHANGED (no double charge)" "${USED_AFTER_A:-0}" "$(used_usd)"
  assert_eq "§16 reservation fully consumed at exit (0)" "0" "$(rsv_units)"
  BAL=$(call getTestBalance "(principal \"$UPRIN\", \"ICPUSD\")" --identity anonymous)
  assert_eq "§16 DEX ICPUSD balance = A + B (each credited exactly once)" "$((DEP_A + DEP_B))" "$(extract_first_nat "$BAL")"
else
  _ok "§12–16 skipped on #$MODE (dev hooks, stopping the DEX and the allowance re-arm are #dev-only)"
fi

# ── (17) H-27 (F5-Bridge): a caller-supplied `amount` above the ceiling is
# refused BEFORE any write and the DEX is never called ───────────────────
# Pre-fix the only bound was amount == 0: a ~100 KB Nat rode the write-ahead
# into the DEX's playDepositReserve, whose refusal formats the valued amount
# through Nat.toText (Θ(bits²)) — the DEX burned its whole 40 B instruction
# budget (~20 DTS rounds, nothing else ran) and trapped with IC0522; the
# Bridge's catch arm rolled its writes back, so pending/admittedUnits were
# ALREADY unchanged pre-fix — the RED here is the DEX call itself (the
# refusal came back from the DEX, seconds later) and the send counter.
# Posture-independent (devSimulateDeposit is the live #play on-ramp and the
# ceiling gate sits above every posture-specific branch), so it runs on every
# posture; only the strand-hook twin needs the BRIDGE at #dev.
stats_field() { echo "$2" | tr -d '_\n' | tr -s ' ' | grep -oE "$1 = [0-9]+" | awk '{print $3}'; }
btc_field()   { echo "$2" | tr -d '_\n' | tr -s ' ' | grep -oE 'asset = "BTC"[^}]*' | grep -oE "$1 = [0-9]+" | awk '{print $3}'; }
CEIL="340282366920938463463374607431768211456"   # 2^128 (the Bridge's AMOUNT_CEILING)
CEIL_P1="${CEIL%?}7"                                # 2^128 + 1 (bash arithmetic is 64-bit; edit the last digit)
ST0=$(bcall getBridgeStats '()' --query --identity anonymous)
SENT0=$(stats_field dexAdmitCalls "$ST0")
[ -n "$SENT0" ] && _ok "§17 getBridgeStats exposes the DEX send counter (dexAdmitCalls = $SENT0)" \
               || _fail "§17 getBridgeStats has no dexAdmitCalls field: $(echo "$ST0" | head -c 200)"
DEP0=$(bcall getMyDeposits '()' --identity "$U")
PEND0=$(btc_field pending "$DEP0"); CONF0=$(btc_field confirmed "$DEP0")
# (a) the 100 KB Nat the brief names — via an args file (the CLI takes it)
HUGE_ARGS=$(scratch_new h27_huge.did) || exit 1
python3 -c 'print("(\"BTC\", " + "9"*100000 + " : nat)")' > "$HUGE_ARGS" || exit 1
T0=$(date +%s)
SIM=$(bcall devSimulateDeposit --args-file "$HUGE_ARGS" --identity "$U")
T1=$(date +%s)
assert_contains     "§17a 100 KB Nat → the BRIDGE's own ceiling refusal ($((T1 - T0)) s)" "$SIM" "exceeds the Bridge deposit ceiling"
assert_not_contains "§17a ...not the DEX's (no instruction-limit trap relayed)"          "$SIM" "IC0522"
assert_not_contains "§17a ...not the DEX's (no allowance verdict either)"                 "$SIM" "allowance exceeded"
assert_not_contains "§17a the refusal never echoes the amount"                            "$SIM" "99999999999"
ST1=$(bcall getBridgeStats '()' --query --identity anonymous)
assert_eq "§17a no DEX call was sent (dexAdmitCalls unchanged)" "${SENT0:-x}" "$(stats_field dexAdmitCalls "$ST1")"
assert_eq "§17a no ledger row created (ledgers size unchanged)"  "$(stats_field ledgers "$ST0")"       "$(stats_field ledgers "$ST1")"
assert_eq "§17a no admittedUnits row created (size unchanged)"   "$(stats_field admittedUnits "$ST0")" "$(stats_field admittedUnits "$ST1")"
assert_eq "§17a nothing held in flight (admitting = 0)"          "0" "$(stats_field admitting "$ST1")"
DEP1=$(bcall getMyDeposits '()' --identity "$U")
assert_eq "§17a BTC pending unchanged"   "$PEND0" "$(btc_field pending "$DEP1")"
assert_eq "§17a BTC confirmed unchanged" "$CONF0" "$(btc_field confirmed "$DEP1")"
# (b) one above the ceiling: the same refusal, still no send
SIM=$(bcall devSimulateDeposit "(\"BTC\", $CEIL_P1 : nat)" --identity "$U")
assert_contains "§17b 2^128 + 1 → ceiling refusal" "$SIM" "exceeds the Bridge deposit ceiling"
assert_eq "§17b no DEX call sent" "${SENT0:-x}" "$(stats_field dexAdmitCalls "$(bcall getBridgeStats '()' --query --identity anonymous)")"
# (c) the boundary itself PASSES the gate (`>` not `>=`): 2^128 reaches the
# DEX, which refuses it — on its OWN relay ceiling (H-15) when the key already
# carries admitted history (the Bridge's cumulative seq = prior + 2^128 is
# then > 2^128; the DEX bounds `seq` at the same constant), or on the
# allowance for a virgin key — and the send counter moves by exactly one,
# which is what makes the "unchanged" reads above a proof.
SIM=$(bcall devSimulateDeposit "(\"BTC\", $CEIL : nat)" --identity "$U")
DEX_VERDICT=$(echo "$SIM" | grep -oE 'allowance exceeded|exceeds the deposit relay ceiling' | head -1)
assert_contains "§17c exactly 2^128 is not Bridge-refused (the DEX judges it: ${DEX_VERDICT:-no DEX verdict})" "$SIM" "${DEX_VERDICT:-a DEX verdict (allowance exceeded | exceeds the deposit relay ceiling)}"
assert_not_contains "§17c ...and not by the ceiling" "$SIM" "exceeds the Bridge deposit ceiling"
assert_eq "§17c the send counter observes a real send (+1)" "$((SENT0 + 1))" "$(stats_field dexAdmitCalls "$(bcall getBridgeStats '()' --query --identity anonymous)")"
DEP1=$(bcall getMyDeposits '()' --identity "$U")
assert_eq "§17c the DEX refusal rolled back: BTC pending unchanged" "$PEND0" "$(btc_field pending "$DEP1")"
# (d) the zero twin, for the record (the sibling bound the ceiling joins)
SIM=$(bcall devSimulateDeposit '("BTC", 0 : nat)' --identity "$U")
assert_contains "§17d amount 0 still refused" "$SIM" "Amount must be positive"
# (e) a legitimate 1-unit deposit right after the refusals admits normally
SIM=$(bcall devSimulateDeposit '("BTC", 1 : nat)' --identity "$U")
assert_ok "§17e a 1-unit deposit admits after the refusals" "$SIM"
DEP1=$(bcall getMyDeposits '()' --identity "$U")
assert_eq "§17e BTC pending moved by exactly 1" "$((PEND0 + 1))" "$(btc_field pending "$DEP1")"
# (f) the strand hook (controller, Bridge #dev) wears the same ceiling: it
# writes the same pending/admittedUnits, and a later claim would relay them.
if [ "$BMODE" = "dev" ]; then
  STR=$(bcall devTestStrandAdmission "(principal \"$UPRIN\", \"BTC\", $CEIL_P1 : nat)" --identity anonymous)
  assert_contains "§17f strand hook refuses 2^128 + 1" "$STR" "exceeds the Bridge deposit ceiling"
  DEP2=$(bcall getMyDeposits '()' --identity "$U")
  assert_eq "§17f strand hook wrote nothing (pending unchanged)" "$((PEND0 + 1))" "$(btc_field pending "$DEP2")"
else
  skip_section "§17f (devTestStrandAdmission needs the BRIDGE at #dev; the venue's Bridge is #${BMODE:-unknown})"
fi

if [ "$_TEST_ERRORS" -eq 0 ]; then
  echo -e "\n\033[0;32mPASS: test_bridge_deposit_claim\033[0m"; exit 0
else
  echo -e "\n\033[0;31mFAIL: test_bridge_deposit_claim ($_TEST_ERRORS failing assertions)\033[0m"; exit 1
fi
