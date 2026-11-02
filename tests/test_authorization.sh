#!/bin/bash
# Authorization tests — locks in the access-control rules so a future
# refactor of `requireAuth` / `requireController` or per-endpoint owner
# checks can't silently loosen them.
#
# Properties asserted:
#   1. Anonymous principal cannot call requireAuth-gated user endpoints
#      (placeLimitOrder, seedAmmPool, ...).
#   2. cancelMyOrder rejects callers who aren't the order's owner —
#      the "you can only cancel your own order" rule.
#   3. Admin endpoints (resetExchange, setTestBalance, createAmmPool,
#      ...) are controller-gated (Phase-6 hardening): an authenticated
#      NON-controller identity is rejected. We probe this with charlie,
#      never with anonymous — on a local network the anonymous principal
#      IS a controller (and cold_start.sh promotes alice), so an
#      anonymous admin call would SUCCEED locally. On mainnet anonymous
#      is never in the controller list (IC config, not app code).
#   4. debugInspectByUsername is controller-gated even in dev builds
#      (2026-06 pre-mainnet hardening, docs/pre-mainnet-checklist.md).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_authorization ──"
setup_mode matching   # Gives us alice's resting ASK at 67600 to attack.

# ── (1) Anonymous principal is rejected by requireAuth ───────────
# `--identity anonymous` signs as the IC's well-known anonymous principal
# `2vxsx-fae`. requireAuth must trap on it. Only endpoints that actually
# call requireAuth belong here — the requireController-only admin
# endpoints are probed in section (3), because locally anonymous IS a
# controller and would sail through their gate. The identity is passed
# PER CALL: this test used to flip the CLI's global default identity
# instead, which is machine-shared mutable state that other sessions and
# connectors move at will (mdex-process-safety §5) — and the flip leaked
# out of the test, changing what every later identity-less call on the
# machine signed as.

ANON_PLACE=$(call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 67600.0), $(e8 0.1))" --identity anonymous)
assert_contains "anonymous placeLimitOrder rejected" "$ANON_PLACE" "Authentication required"

ANON_SEED=$(call seedAmmPool "(\"BTC-ICPUSD\", $(e8 1.0), $(e8 75000.0))" --identity anonymous)
assert_contains "anonymous seedAmmPool rejected" "$ANON_SEED" "Authentication required"

# ── (2) cancelMyOrder enforces owner check ──────────────────────
# Alice has a resting ASK at 67600 from seed_matching. Bob (a
# different principal) attempts to cancel it — must fail.

ALICE_ORDERS=$(call getMyOrdersOnMarket '("BTC-ICPUSD")' --identity alice)
ALICE_ORDER_ID=$(echo "$ALICE_ORDERS" \
  | grep -oE "id = [0-9_]+ : nat" | head -1 \
  | grep -oE "[0-9_]+" | tr -d '_')
assert_contains "alice has an order to attack" "$ALICE_ORDERS" "$(e8 67600)"

# Bob attempts to cancel alice's order.
BOB_CANCEL=$(call cancelMyOrder "($ALICE_ORDER_ID : nat)" --identity bob)
assert_contains "bob can't cancel alice's order" "$BOB_CANCEL" "Not your order"

# Sanity: alice's order is still on the book.
ALICE_AFTER=$(call getMyOrdersOnMarket '("BTC-ICPUSD")' --identity alice)
assert_contains "alice's order survived bob's attack" "$ALICE_AFTER" "$(e8 67600)"

# Owner can still cancel their own. Staged non-post-only orders are COMMITTED
# for their first 3s (anti-free-look, drain fix 5b) — wait out the window so
# the cancel is deterministic whether the order is still staged or resting.
sleep 3.2
ALICE_CANCEL=$(call cancelMyOrder "($ALICE_ORDER_ID : nat)" --identity alice)
assert_ok "alice can cancel her own order" "$ALICE_CANCEL"

# ── (3) Admin endpoints are controller-gated (Phase-6) ──────────
# Charlie is authenticated but NOT a canister controller (the local
# controllers are anonymous + alice; see cold_start.sh). requireController
# must reject him on every admin endpoint. The rejected calls trap, so
# they can't mutate state — charlie's resetExchange can't wipe the
# fixture. (This section used to assert the OPPOSITE — that charlie
# could resetExchange — from before the Phase-6 controller ACL landed.)

CHARLIE_RESET=$(call resetExchange '()' --identity charlie)
assert_contains "charlie (non-controller) can't resetExchange" "$CHARLIE_RESET" "not a canister controller"

CHARLIE_BAL=$(call setTestBalance "(principal \"2vxsx-fae\", \"BTC\", $(e8 1.0))" --identity charlie)
assert_contains "charlie (non-controller) can't setTestBalance" "$CHARLIE_BAL" "not a canister controller"

CHARLIE_AMM=$(call createAmmPool '("BTC-ICPUSD")' --identity charlie)
assert_contains "charlie (non-controller) can't createAmmPool" "$CHARLIE_AMM" "not a canister controller"

# ── (4) debugInspectByUsername is controller-gated (review H3) ───
# The debug inspector resolves ANY user's balances, debts, and orders
# from their public username, so it must be controller-only even in
# dev builds (its IS_PRODUCTION no-op is not enough — the flag is
# false in every dev/sim deployment). Locks in the 2026-06 pre-mainnet
# hardening (docs/pre-mainnet-checklist.md); fails against a backend
# built before it, when the endpoint was open to any caller.

BOB_INSPECT=$(call debugInspectByUsername '("Nonexistent-User-00")' --identity bob)
assert_contains "bob (non-controller) can't debug-inspect" "$BOB_INSPECT" "not a canister controller"

# Controllers still get through (cold_start.sh promotes alice); an
# unknown username resolves to found=false rather than a trap.
ALICE_INSPECT=$(call debugInspectByUsername '("Nonexistent-User-00")' --identity alice)
assert_contains "alice (controller) can debug-inspect" "$ALICE_INSPECT" "found = false"

finish_test "test_authorization"
