#!/bin/bash
# W3-04 — the Bridge's admission counter is write-ahead, so an admission whose
# continuation never finishes can no longer double-charge the lifetime
# allowance.
#
# Pre-fix: devSimulateDeposit advanced `admittedUnits` and `l.pending` only in
# the continuation AFTER the DEX call. A continuation that did not run (W3-04
# told it as an upgrade mid-await; #55 (d) measured that an upgrade cannot land
# inside an await on this toolchain — it waits for the message — so a trap is
# the shape) left the counter stale; the retry computed a DIFFERENT seq, the
# DEX's replay gate did not fire, and the allowance was debited twice.
# Write-ahead makes the state a stranded continuation leaves identical to a
# completed deposit, so:
#
#   §1 a normal deposit charges the allowance exactly once
#   §2 an upgrade between deposits changes nothing: the counter is
#      reproducible, the second deposit charges exactly its own value
#   §3 a DEX refusal (over-allowance) rolls BOTH write-aheads back —
#      pending and used are byte-identical before/after
#   §4 claim-side flow is untouched (confirm + claim still credit)
#
# Needs #dev. Uses a fresh identity; does not reset the venue.

set -u
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"     # mdx_ok + bridge_upgrade_if_posture_matches (NB: it REDEFINES SCRIPT_DIR as the repo root)
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
u() { if [ "$1" = backend ]; then icp canister call --identity bwa_u backend "${@:2}" --candid "$MDX_CANDID" 2>&1; else icp canister call --identity bwa_u "$1" "${@:2}" 2>&1; fi; }   # the --candid belt only for the backend: candid/backend.did is ITS contract, not the Bridge's (task 1788512331)
mdx_identity_new bwa_u; U=$(principal_of bwa_u)   # virgin each run, deleted on EXIT (tests/_lib.sh)

used() { u backend getPlayDepositAllowance '()' --query | tr -d '_\n' | tr -s ' ' | grep -oE "usedUsd = [0-9]+" | awk '{print $3}'; }
pend() { u bridge getMyDeposits '()' --query | tr -d '_\n' | tr -s ' ' | grep -oE "asset = \"BTC\"[^}]*" | grep -oE "pending = [0-9]+" | awk '{print $3}'; }

# The deposit is valued at the venue mark — make BTC's live.
icp canister call --candid "$MDX_CANDID" --identity anonymous backend createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
icp canister call --candid "$MDX_CANDID" --identity anonymous backend setAmmRefPrice '("BTC-ICPUSD", 10_000_000_000 : nat)' >/dev/null 2>&1
icp canister call --candid "$MDX_CANDID" --identity anonymous backend requoteAmm '("BTC-ICPUSD")' >/dev/null 2>&1

# Anti-Sybil: deposits need a verified binding — dev hook supplies one. The
# email is per-run: bwa_u is a VIRGIN principal every run now (deleted on
# EXIT), and one email binds to one principal for good — a fixed address
# re-bound to a new principal is refused, silently under >/dev/null, and every
# deposit below then reads "unbound" (8 reds on the first virgin run).
R=$(echo y | icp canister call --candid "$MDX_CANDID" --identity anonymous backend setTestEmailBinding "(principal \"$U\", \"bwa${RANDOM}$$@example.com\")" 2>&1)
mdx_ok "$R" && ok "bwa_u bound to a per-run verified email" || nok "binding refused (deposits below will read unbound)" "$(echo "$R" | head -c 200)"

echo "── §1 one deposit, one charge ──"
U0=$(used); [ -n "$U0" ] || U0=0
R=$(u bridge devSimulateDeposit '("BTC", 100_000_000 : nat)')
mdx_ok "$R" && ok "deposit admitted" || nok "deposit refused" "$R"
U1=$(used); P1=$(pend)
[ "${U1:-0}" -gt "${U0:-0}" ] && ok "allowance charged once (used $U0 → $U1)" || nok "allowance not charged" "u0=$U0 u1=$U1"
[ "${P1:-0}" = "100000000" ] && ok "pending credited (write-ahead visible)" || nok "pending wrong" "p1=$P1"

echo "── §2 upgrade between deposits: counter reproducible, no phantom charge ──"
# An in-place upgrade lands a build of the Bridge tree. On a seat the tree
# sits at #play between deploys while the venue runs #dev, so the upgrade
# would silently flip the venue's Bridge posture and every later suite that
# needs a Bridge dev hook (test_season_wipe_fence, ...) would red for a
# reason that is not code. The shared guard (tests/_lib.sh) upgrades only
# when the two postures agree and prints the ⊘ otherwise; the counter
# assertions below still hold without it.
bridge_upgrade_if_posture_matches "§2 in-place upgrade (the across-upgrade counter)"; BUP_RC=$?
case "$BUP_RC" in
  0) ok "$BRIDGE_UPGRADE_NOTE" ;;
  1) : ;;
  *) nok "upgrade failed" "$BRIDGE_UPGRADE_NOTE" ;;
esac
R=$(u bridge devSimulateDeposit '("BTC", 100_000_000 : nat)')
mdx_ok "$R" && ok "post-upgrade deposit admitted" || nok "post-upgrade deposit refused" "$R"
U2=$(used); P2=$(pend)
D1=$((U1 - U0)); D2=$((U2 - U1))
[ "$D1" = "$D2" ] && ok "second charge equals the first exactly ($D2) — no double-charge, no skip" || nok "charge drifted across the upgrade" "d1=$D1 d2=$D2"
[ "${P2:-0}" = "200000000" ] && ok "pending accumulated exactly (2 × deposit)" || nok "pending wrong" "p2=$P2"

echo "── §3 DEX refusal rolls the write-aheads back ──"
R=$(u bridge devSimulateDeposit '("BTC", 100_000_000_000_000 : nat)')   # ≫ lifetime cap → DEX #err
if echo "$R" | grep -qi "err"; then ok "over-allowance deposit refused by the DEX"; else nok "giant deposit accepted?!" "$(echo "$R" | head -c 200)"; fi
U3=$(used); P3=$(pend)
[ "${U3:-x}" = "${U2:-y}" ] && ok "used byte-identical after refusal ($U3)" || nok "allowance moved on refusal" "u2=$U2 u3=$U3"
[ "${P3:-x}" = "${P2:-y}" ] && ok "pending byte-identical after refusal ($P3)" || nok "pending moved on refusal" "p2=$P2 p3=$P3"
R=$(u bridge devSimulateDeposit '("BTC", 50_000_000 : nat)')
mdx_ok "$R" && ok "counter healthy after rollback (small deposit admits)" || nok "counter wedged" "$R"

echo "── §4 claim side untouched ──"
u bridge devConfirmDeposits '()' >/dev/null
R=$(u bridge claim '("BTC")')
mdx_ok "$R" && ok "confirm + claim still credit" || nok "claim broke" "$(echo "$R" | head -c 200)"

echo "── §5 H-26 (F40): a refused first-time admission leaves the stable maps untouched ──"
# Pre-fix: the write-ahead get-or-created the counter and the Ledger row, and
# the #err rollback restored their VALUES but deleted no rows — two permanent
# zero rows per refused (unbound keypair, asset), reclaimable only by the
# season wipe. Sizes come from getBridgeStats; the identity is minted FRESH
# each run so the pre-call state has no row for it at all.
stats() { echo y | icp canister call --identity anonymous bridge getBridgeStats '()' --query 2>&1 | tr -d '_\n' | tr -s ' '; }
statn() { echo "$1" | grep -oE "$2 = [0-9]+" | awk '{print $3}'; }
mdx_identity_new bwa_x; X=$(principal_of bwa_x)   # UNBOUND on purpose: the DEX's binding gate refuses at admission
S0=$(stats); L0=$(statn "$S0" ledgers); A0=$(statn "$S0" admittedUnits)
[ -n "$L0" ] && [ -n "$A0" ] && ok "getBridgeStats readable (ledgers $L0, admittedUnits $A0)" || nok "getBridgeStats missing" "$(echo "$S0" | head -c 200)"
R=$(icp canister call --identity bwa_x bridge devSimulateDeposit '("BTC", 100_000_000 : nat)' 2>&1)
echo "$R" | grep -q "verified Google" && ok "unbound identity refused at admission (DEX binding gate)" || nok "unbound identity not refused as expected" "$(echo "$R" | head -c 200)"
S1=$(stats); L1=$(statn "$S1" ledgers); A1=$(statn "$S1" admittedUnits)
[ "${L1:-x}" = "${L0:-y}" ] && ok "ledgers size unchanged across the refusal ($L0)" || nok "ledgers grew on a refused admission" "l0=$L0 l1=$L1"
[ "${A1:-x}" = "${A0:-y}" ] && ok "admittedUnits size unchanged across the refusal ($A0)" || nok "admittedUnits grew on a refused admission" "a0=$A0 a1=$A1"
[ "$(statn "$S1" admitting)" = "0" ] && ok "interlock free after the refusal (admitting = 0)" || nok "admitting not released" "$(echo "$S1" | head -c 200)"
D=$(icp canister call --identity bwa_x bridge getMyDeposits '()' --query 2>&1 | tr -d '_\n' | tr -s ' ' | grep -oE "asset = \"BTC\"[^}]*")
echo "$D" | grep -qE "pending = 0[^0-9]" && ok "refused deposit shows pending 0 (view synthesised from an absent row)" || nok "pending visible after refusal" "$(echo "$D" | head -c 200)"
# Local eligibility runs ABOVE the guard and above any write: neither an
# unsupported asset nor a zero amount leaves a row or holds the interlock.
icp canister call --identity bwa_x bridge devSimulateDeposit '("DOGE", 1 : nat)' >/dev/null 2>&1
icp canister call --identity bwa_x bridge devSimulateDeposit '("BTC", 0 : nat)' >/dev/null 2>&1
S2=$(stats)
[ "$(statn "$S2" ledgers)" = "$L0" ] && [ "$(statn "$S2" admittedUnits)" = "$A0" ] && [ "$(statn "$S2" admitting)" = "0" ] \
  && ok "locally-ineligible calls (bad asset, zero amount) leave sizes and the interlock untouched" \
  || nok "locally-ineligible call touched state" "$(echo "$S2" | head -c 200)"

echo "── §6 H-26 (F40): controller purge of already-leaked zero rows ──"
R=$(icp canister call --identity bwa_u bridge adminPurgeZeroRows '()' 2>&1)
echo "$R" | grep -q "not a controller" && ok "purge refused for a non-controller" || nok "purge not gated" "$(echo "$R" | head -c 200)"
R=$(echo y | icp canister call --identity anonymous bridge adminPurgeZeroRows '()' 2>&1 | tr -d '_\n' | tr -s ' ')
mdx_ok "$R" && ok "purge ran as controller ($(echo "$R" | grep -oE 'admittedUnits = [0-9]+|ledgers = [0-9]+' | tr '\n' ' '))" || nok "purge failed" "$(echo "$R" | head -c 200)"
R2=$(echo y | icp canister call --identity anonymous bridge adminPurgeZeroRows '()' 2>&1 | tr -d '_\n' | tr -s ' ')
echo "$R2" | grep -qE "admittedUnits = 0[^0-9]" && echo "$R2" | grep -qE "ledgers = 0[^0-9]" && ok "second purge finds nothing (idempotent)" || nok "second purge still found rows" "$(echo "$R2" | head -c 200)"
D=$(u bridge getMyDeposits '()' --query | tr -d '_\n' | tr -s ' ' | grep -oE "asset = \"BTC\"[^}]*")
echo "$D" | grep -qE "claimed = [1-9]" && ok "a live row (claimed > 0) survives the purge — history intact" || nok "purge touched a live row" "$(echo "$D" | head -c 200)"
S3=$(stats)
[ "$(statn "$S3" ledgers)" -le "$L0" ] && ok "ledgers never above the pre-§5 size after purge ($(statn "$S3" ledgers) ≤ $L0)" || nok "ledgers grew" "$(echo "$S3" | head -c 200)"

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_bridge_write_ahead ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_bridge_write_ahead ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
