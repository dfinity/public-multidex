#!/bin/bash
# tests/test_bots_pidguard.sh — the fleet PID files are trusted only when the
# recorded PID is provably the fleet (scripts/lib/bots.sh: mdx_pid_is_fleet).
#
# STATIC — no replica, no venue, no real fleet. A fake engine (a script named
# scripts/trading_simulation.sh under the suite's private scratch dir, body
# `sleep`) stands in for the fleet, so its argv is exactly what the wrappers
# launch: `bash …/scripts/trading_simulation.sh --target <t> …`. A plain
# `sleep` stands in for a REUSED PID.
#
# Why this exists (2026-09-07/09): the machine rebooted under the launchd
# subnet fleet. Its PID file still said 818; after the reboot PID 818 was
# Jump Desktop Connect. The start guard was `kill -0 <pid>` — "some process
# owns this number" — so start_bots_subnet.sh refused "already running"
# 1,180 times over 40 hours under KeepAlive, and stop_bots_subnet.sh, had
# anyone run it as that message says to, would have walked PID 818's tree
# with mdx_kill_tree: the remote-desktop session. Every assertion here is one
# of those two paths behaving on a PID that is alive but not the fleet.
#
# Uses _lib.sh's _ok/_fail counters (and its private scratch dir) but its
# own verdict — like test_keychain_helper.sh, it never calls finish_test.

source "$(dirname "$0")/_lib.sh"

ROOT="$SCRIPT_DIR"
cd "$ROOT" || exit 1

echo "── test_bots_pidguard ──"

LIB="$ROOT/scripts/lib/bots.sh"
[ -f "$LIB" ] || { _fail "library missing at $LIB"; exit 1; }

# ── The fake engine and a private .run/ ──────────────────────────
FAKE_ROOT="$TEST_SCRATCH/fakeroot"
RUN="$TEST_SCRATCH/run"
mkdir -p "$FAKE_ROOT/scripts" "$RUN"
printf '#!/bin/bash\nsleep 300\n' > "$FAKE_ROOT/scripts/trading_simulation.sh"

# Every process this suite spawns is recorded here and killed BY PID on exit —
# never by name (the process-safety doctrine this suite exists to defend).
SPAWNED=()
reap_spawned() {
  local p k
  for p in "${SPAWNED[@]}"; do
    for k in $(pgrep -P "$p" 2>/dev/null); do kill "$k" 2>/dev/null; done
    kill "$p" 2>/dev/null
  done
}
on_exit reap_spawned

# Both set LAST_PID rather than printing it: `X=$(spawn …)` would run the
# function in a subshell and the SPAWNED bookkeeping (and the reap) would be
# lost with it — which is exactly how the first draft leaked a fake fleet.
spawn_fake_fleet() {  # spawn_fake_fleet <target> → LAST_PID: argv looks like the real fleet's
  bash "$FAKE_ROOT/scripts/trading_simulation.sh" --target "$1" --bots 1 --interval 4 </dev/null >/dev/null 2>&1 &
  LAST_PID=$!; SPAWNED+=("$LAST_PID"); disown "$LAST_PID"
}
spawn_bystander() {   # → LAST_PID: a live process that is NOT a fleet (stands in for a reused PID)
  sleep 300 </dev/null >/dev/null 2>&1 &
  LAST_PID=$!; SPAWNED+=("$LAST_PID"); disown "$LAST_PID"
}
alive() { kill -0 "$1" 2>/dev/null; }

# Run <fn args…> in a subshell that has bots.sh loaded against the private
# .run/ and the fake engine root, with the venue-touching asserts stubbed out
# (mdx_bots_start calls them BEFORE launching; they are exercised elsewhere).
# Prints stdout+stderr; the subshell's exit code is left in $?.
in_lib() {
  bash -c '
    . "$1"; shift
    MDX_RUN_DIR="$1"; shift
    MDX_ROOT="$1"; shift
    mdx_assert_runtime_posture_for_target() { MDX_POSTURE=play; }
    mdx_assert_identity() { MDX_IDENTITY=fake; }
    "$@"
  ' _ "$LIB" "$RUN" "$FAKE_ROOT" "$@" 2>&1
}

spawn_fake_fleet subnet; FLEET_S=$LAST_PID
spawn_fake_fleet local;  FLEET_L=$LAST_PID
spawn_bystander;         BYSTANDER=$LAST_PID
DEAD=4194000            # above macOS's PID range: never alive
sleep 0.3

# ── 1. mdx_pid_is_fleet: the argv has to say engine + --target <target> ──
in_lib mdx_pid_is_fleet "$FLEET_S" subnet >/dev/null && _ok "a fake subnet fleet is the subnet fleet" || _fail "the subnet fleet's own PID was not recognised"
in_lib mdx_pid_is_fleet "$FLEET_S" local  >/dev/null && _fail "the subnet fleet passed as the LOCAL fleet" || _ok "the subnet fleet is not the local fleet"
in_lib mdx_pid_is_fleet "$FLEET_L" subnet >/dev/null && _fail "the local fleet passed as the SUBNET fleet" || _ok "the local fleet is not the subnet fleet"
in_lib mdx_pid_is_fleet "$BYSTANDER" subnet >/dev/null && _fail "a live non-fleet PID (reused PID) passed as the fleet" || _ok "a live non-fleet PID is not the fleet"
in_lib mdx_pid_is_fleet "$DEAD" subnet >/dev/null && _fail "a dead PID passed as the fleet" || _ok "a dead PID is not the fleet"
in_lib mdx_pid_is_fleet "" subnet >/dev/null && _fail "an empty PID passed as the fleet" || _ok "an empty PID is not the fleet"

# ── 2. stop: a reused PID is NOT killed; the stale file is cleared ──
echo "$BYSTANDER" > "$RUN/bots-subnet.pid"
out=$(in_lib mdx_bots_stop subnet); rc=$?
[ "$rc" = "0" ] && _ok "stop on a reused PID exits 0" || _fail "stop on a reused PID exited $rc: $out"
alive "$BYSTANDER" && _ok "stop on a reused PID left that process alive" || _fail "stop on a reused PID KILLED the bystander"
[ ! -e "$RUN/bots-subnet.pid" ] && _ok "stop on a reused PID cleared the stale PID file" || _fail "stale PID file survived stop"
printf '%s' "$out" | grep -q 'not this fleet' && _ok "stop says why the PID was not trusted" || _fail "stop did not explain the stale PID: $out"

# ── 3. stop: a dead PID is cleared without touching anything ──
echo "$DEAD" > "$RUN/bots-subnet.pid"
out=$(in_lib mdx_bots_stop subnet); rc=$?
[ "$rc" = "0" ] && [ ! -e "$RUN/bots-subnet.pid" ] && _ok "stop on a dead PID clears the file and exits 0" || _fail "stop on a dead PID: rc=$rc file=$([ -e "$RUN/bots-subnet.pid" ] && echo present || echo gone)"

# ── 4. stop: the real fleet (by argv) IS killed, by ancestry ──
echo "$FLEET_S" > "$RUN/bots-subnet.pid"
out=$(in_lib mdx_bots_stop subnet); rc=$?
[ "$rc" = "0" ] && _ok "stop on the fleet exits 0" || _fail "stop on the fleet exited $rc: $out"
alive "$FLEET_S" && _fail "stop on the fleet left it running" || _ok "stop on the fleet killed it"
alive "$FLEET_L" && _ok "stop on the subnet fleet did not touch the local fleet" || _fail "stop on the subnet fleet KILLED the local fleet"
alive "$BYSTANDER" && _ok "stop on the subnet fleet did not touch the bystander" || _fail "stop on the subnet fleet KILLED the bystander"
[ ! -e "$RUN/bots-subnet.pid" ] && _ok "stop on the fleet removed the PID file" || _fail "PID file survived a real stop"

# ── 5. start: a stale file (reused PID) does not block the start ──
echo "$BYSTANDER" > "$RUN/bots-subnet.pid"
out=$(in_lib mdx_bots_start subnet); rc=$?
NEW=$(cat "$RUN/bots-subnet.pid" 2>/dev/null); [ -n "$NEW" ] && SPAWNED+=("$NEW")
[ "$rc" = "0" ] && _ok "start over a reused-PID file proceeds (exit 0)" || _fail "start over a reused-PID file refused: $out"
printf '%s' "$out" | grep -q 'stale PID file' && _ok "start reports the stale file it cleared" || _fail "start did not report the stale file: $out"
[ -n "$NEW" ] && [ "$NEW" != "$BYSTANDER" ] && alive "$NEW" && _ok "start recorded the NEW fleet's PID ($NEW)" || _fail "start did not record a live new PID (got '$NEW')"
alive "$BYSTANDER" && _ok "start over a reused-PID file left that process alive" || _fail "start KILLED the bystander"
in_lib mdx_pid_is_fleet "$NEW" subnet >/dev/null && _ok "the PID start recorded is the fleet by argv" || _fail "start's recorded PID is not recognised as the fleet"

# ── 6. start: a live fleet still refuses "already running" ──
out=$(in_lib mdx_bots_start subnet); rc=$?
[ "$rc" != "0" ] && _ok "start with the fleet up refuses (exit $rc)" || _fail "start with the fleet up did NOT refuse"
printf '%s' "$out" | grep -q 'already running' && _ok "the refusal says already running" || _fail "unexpected refusal text: $out"
[ "$(cat "$RUN/bots-subnet.pid" 2>/dev/null)" = "$NEW" ] && _ok "the refusal left the live PID file alone" || _fail "the refusal changed the PID file"

# ── 7. a dead recorded PID does not block the start either ──
in_lib mdx_bots_stop subnet >/dev/null
echo "$DEAD" > "$RUN/bots-subnet.pid"
out=$(in_lib mdx_bots_start subnet); rc=$?
NEW2=$(cat "$RUN/bots-subnet.pid" 2>/dev/null); [ -n "$NEW2" ] && SPAWNED+=("$NEW2")
[ "$rc" = "0" ] && [ -n "$NEW2" ] && alive "$NEW2" && _ok "start over a dead-PID file proceeds and records the new fleet" || _fail "start over a dead-PID file: rc=$rc new='$NEW2' $out"
in_lib mdx_bots_stop subnet >/dev/null

# ── Verdict ──
if [ "$_TEST_ERRORS" -eq 0 ]; then
  echo -e "\n\033[0;32mPASS: test_bots_pidguard\033[0m"; exit 0
else
  echo -e "\n\033[0;31mFAIL: test_bots_pidguard ($_TEST_ERRORS failing assertions)\033[0m"; exit 1
fi
