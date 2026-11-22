#!/bin/bash
# L1 admission shedding (docs/access-prioritization-design.md §5): when the
# shed floor rises, lower-RANK registered principals are refused at the
# `inspect` gate — the message never reaches execution — while earned high
# levels (and controllers) pass, and queries stay open to everyone. Rank is
# derived from the EARNED fee level (L0→0, L1–L2→1, L3–L4→2); the test earns
# L4 via setTestScorecard. Uses the setTestShedFloor pin (the real floor is
# heartbeat-driven from queue depth).
# NOTE: inspect refusal happens at ingress — the CLI surfaces a replica
# rejection, not a candid #err. Timers paused so the heartbeat can't unpin.
# ⚠️ Calls resetExchange.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_tier_shed ──"
setup_mode matching

mdx_identity_new shed_dep
mdx_identity_new shed_mm
DP=$(principal_of shed_dep); MP=$(principal_of shed_mm)
# Funding via setTestBalance REGISTERS both principals (the gate's precondition).
call setTestBalance "(principal \"$DP\", \"ICPUSD\", $(e8 100000) : nat)" --identity alice > /dev/null
call setTestBalance "(principal \"$MP\", \"ICPUSD\", $(e8 100000) : nat)" --identity alice > /dev/null
call setTestBalance "(principal \"$MP\", \"BTC\", $(e8 5) : nat)" --identity alice > /dev/null
# Earn L4 (rank 2): W = 2×$50k ≥ the $100k bar (1% scale) + qualified uptime.
call setTestScorecard "(principal \"$MP\", $(e8 50000) : nat, 0 : nat, 30 : nat, 25 : nat)" --identity alice > /dev/null
call setTestTimersPaused '(true)' --identity alice > /dev/null

# (0) floor open: both can place
A=$(call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 60000) : nat, $(e8 0.01) : nat)" --identity shed_dep)
assert_ok "floor 0: L0 update passes" "$A"

# (1) floor 1: L0 refused AT THE GATE, the L4 quoter passes
call setTestShedFloor '(opt (1 : nat))' --identity alice > /dev/null
B=$(call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 60001) : nat, $(e8 0.01) : nat)" --identity shed_dep)
assert_not_contains "floor 1: L0 update refused (no ok)" "$B" "ok = "
assert_contains "floor 1: refusal is the inspect gate itself" "$B" "explicitly refused message"
C=$(call placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 70000) : nat, $(e8 0.01) : nat)" --identity shed_mm)
assert_ok "floor 1: L4 update passes" "$C"

# (2) queries stay open to the shed principal (inspect gates UPDATE calls only)
Q=$(call getAccessPolicy '()' --identity shed_dep --query)
assert_contains "shed L0 can still QUERY the policy" "$Q" "shedFloor = 1"
assert_contains "policy shows their level" "$Q" "myLevel = 0"

# (3) floor 2: L4 (rank 2) still passes
call setTestShedFloor '(opt (2 : nat))' --identity alice > /dev/null
D=$(call placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 70001) : nat, $(e8 0.01) : nat)" --identity shed_mm)
assert_ok "floor 2: L4 update still passes" "$D"

# (4) pin released → L0 readmitted
call setTestShedFloor '(null)' --identity alice > /dev/null
E=$(call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 60002) : nat, $(e8 0.01) : nat)" --identity shed_dep)
assert_ok "floor released: L0 passes again" "$E"

call setTestTimersPaused '(false)' --identity alice > /dev/null
finish_test "test_tier_shed"
