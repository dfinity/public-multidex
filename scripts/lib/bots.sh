#!/usr/bin/env bash
# scripts/lib/bots.sh — start/stop the trading simulators for ONE target.
#
# SOURCE THIS from a start_bots_<target>.sh / stop_bots_<target>.sh wrapper.
# It is never invoked directly and takes no target from the environment: the
# wrapper passes it, so the target is always visible in the command that was
# typed, in the launched process's argv, and in the PID file.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/targets.sh"

# Which simulator drives each target.
#
# trading_simulation.sh supersedes the other two and is the one to run. The
# Every target runs the strategy engine; the old spot-only sim_trading.sh
# retired at the Phase I -> II reset (2026-08-01).
# driving multidex.ai's live volume today — switching the live fleet's engine
# is a behavioural change that belongs in its own commit, not in a refactor
# whose point is to stop things getting mixed up. When it is switched, this is
# the single line to change.
mdx_engine_for() {
  case "$1" in
    local|engine) echo "trading_simulation.sh" ;;
    subnet)       echo "trading_simulation.sh" ;;
  esac
}

# Is $1 (a PID read from a PID file) actually THIS target's fleet?
#
# A bare `kill -0` only proves that SOME process owns the number. After a
# reboot the kernel hands PIDs out again from the bottom, so a recorded low
# PID is very likely to name an unrelated process: on 2026-09-07 the subnet
# fleet's PID 818 came back as Jump Desktop Connect, the start guard refused
# "already running" 1,180 times over 40 hours, and the stop path would have
# killed the remote-desktop session's process tree. So the PID has to carry
# the fleet's own argv — the engine script and `--target <target>` — before
# either path treats it as the fleet. Both modes exec the engine, so the
# recorded PID's command line is always `bash …/scripts/<engine> --target …`.
mdx_pid_is_fleet() {
  local pid="$1" target="$2" cmd
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmd=$(ps -o command= -p "$pid" 2>/dev/null) || return 1
  case "$cmd" in
    *"scripts/$(mdx_engine_for "$target")"*" --target $target "*|*"scripts/$(mdx_engine_for "$target")"*" --target $target") return 0 ;;
  esac
  return 1
}

# What the recorded PID is, for the message that says why it was not trusted.
mdx_pid_describe() {
  local pid="$1" cmd
  if kill -0 "$pid" 2>/dev/null; then
    cmd=$(ps -o command= -p "$pid" 2>/dev/null | cut -c1-80)
    echo "pid $pid is alive but is not this fleet: ${cmd:-<unreadable>}"
  else
    echo "pid $pid is not running"
  fi
}

mdx_bots_start() {
  local target="$1"; shift
  mdx_target_valid "$target" || mdx_die "unknown target '$target'"
  mkdir -p "$MDX_RUN_DIR"

  local pidfile; pidfile=$(mdx_pidfile "$target")
  if [ -f "$pidfile" ]; then
    local recorded; recorded=$(cat "$pidfile" 2>/dev/null)
    if mdx_pid_is_fleet "$recorded" "$target"; then
      mdx_die "bots already running for '$target' (pid $recorded) — stop_bots_$target.sh first"
    fi
    # A PID file whose number is dead, or owned by something that is not this
    # fleet (a reused PID after a reboot), must not block the start — under
    # launchd KeepAlive that is a throttled refusal loop that never ends.
    mdx_warn "stale PID file for '$target' cleared ($(mdx_pid_describe "$recorded"))"
    rm -f "$pidfile"
  fi

  # Bare calls: these must be able to kill THIS shell (see targets.sh).
  mdx_assert_runtime_posture_for_target "$target"
  mdx_assert_identity "$target"
  local mode="$MDX_POSTURE" identity="$MDX_IDENTITY"
  local env_name; env_name=$(mdx_env_for "$target")
  # The FUNDING identity (task 1789609263): refills sign as the designated
  # funding authority, never as the controller key above. Resolved here
  # (env > target conf > nothing) and handed to the engine as
  # MDX_FUNDING_IDENTITY on every launch line; an empty value makes the
  # engine fall back to BOT_IDENTITY — the pre-1789609263 behaviour — and
  # that fallback is named LOUDLY, because a remote fleet still signing
  # refills with the controller is the finding this exists to close.
  local funding; funding=$(mdx_funding_identity_for "$target")
  if mdx_is_remote "$target"; then
    if [ -n "$funding" ]; then
      icp identity principal --identity "$funding" >/dev/null 2>&1 \
        || mdx_die "funding identity '$funding' unusable for '$target' (not in this icp store?) — icp identity new $funding, then designate its principal: setFundingAuthority as the controller"
      mdx_info "refills sign as the funding authority '$funding' (the controller key '$identity' signs no refill)"
    else
      mdx_warn "no funding identity for '$target' — refills will sign as the CONTROLLER identity '$identity'.
   Designate one (setFundingAuthority as $identity, task 1789609263) and set SN_FUNDING_IDENTITY / CE_FUNDING_IDENTITY
   in the target conf (or MDX_FUNDING_IDENTITY in the environment) so the controller key does one job."
    fi
  fi
  local engine;   engine=$(mdx_engine_for "$target")
  local bots="${MDX_BOTS:-$(mdx_bots_for "$target")}" interval="${MDX_INTERVAL:-$(mdx_interval_for "$target")}"
  local pool_fund="${POOL_FUND_USD:-$(mdx_pool_fund_for "$target")}"
  local log="$MDX_RUN_DIR/bots-$target.log"

  # The target is passed to the engine in ARGV as well as via the variables it
  # reads, so `ps` shows which venue a bot fleet points at. Before this, the
  # target lived only in IC_ENV — invisible to ps — and a bare pattern kill
  # could not tell a local fleet from the one driving multidex.ai.
  mdx_info "starting bots → $target (env $env_name, identity $identity, posture #$mode, engine $engine)"

  # FOREGROUND mode, for a supervisor that expects to own the process
  # (launchd KeepAlive, systemd). The default backgrounds with nohup and
  # returns, which is right for a terminal but wrong under a supervisor: it
  # would see the starter exit within a second, restart it, and then hit the
  # "already running" pidfile guard — a throttled crash-loop. `exec` replaces
  # this shell so the supervisor's PID *is* the fleet, and its stop/restart
  # signals reach the engine's cleanup trap directly.
  if [ -n "${MDX_FOREGROUND:-}" ]; then
    echo "$$" > "$pidfile"
    mdx_ok "bots (foreground) for '$target' — $bots bots @ ${interval}s, pid $$"
    if [ "$target" = "local" ]; then
      exec env MDX_TARGET="$target" BOT_PREFIX="${target}bot" POOL_FUND_USD="$pool_fund" \
        bash "$MDX_ROOT/scripts/$engine" --target "$target" --bots "$bots" --interval "$interval"
    else
      exec env MDX_TARGET="$target" IC_ENV="$env_name" BOT_IDENTITY="$identity" MDX_FUNDING_IDENTITY="$funding" BOT_PREFIX="${target}bot" POOL_FUND_USD="$pool_fund" \
        bash "$MDX_ROOT/scripts/$engine" --target "$target" --bots "$bots" --interval "$interval"
    fi
  fi

  if [ "$target" = "local" ]; then
    nohup env MDX_TARGET="$target" BOT_PREFIX="${target}bot" POOL_FUND_USD="$pool_fund" \
      bash "$MDX_ROOT/scripts/$engine" --target "$target" --bots "$bots" --interval "$interval" \
      > "$log" 2>&1 &
  else
    nohup env MDX_TARGET="$target" IC_ENV="$env_name" BOT_IDENTITY="$identity" MDX_FUNDING_IDENTITY="$funding" BOT_PREFIX="${target}bot" POOL_FUND_USD="$pool_fund" \
      bash "$MDX_ROOT/scripts/$engine" --target "$target" --bots "$bots" --interval "$interval" \
      > "$log" 2>&1 &
  fi
  local pid=$!
  echo "$pid" > "$pidfile"
  sleep 1
  kill -0 "$pid" 2>/dev/null || { rm -f "$pidfile"; mdx_die "bots exited immediately — see $log"; }
  mdx_ok "bots running for '$target' (pid $pid, $bots bots @ ${interval}s) — log: $log"
  mdx_info "stop with: bash scripts/stop_bots_$target.sh"
}

mdx_bots_stop() {
  local target="$1"
  mdx_target_valid "$target" || mdx_die "unknown target '$target'"
  local pidfile; pidfile=$(mdx_pidfile "$target")

  if [ ! -f "$pidfile" ]; then
    mdx_ok "no bots recorded for '$target' (nothing to stop)"
    # Deliberately NOT falling back to a pattern search. A pattern cannot tell
    # this target's fleet from another's — that is the whole bug — so an
    # unrecorded fleet is reported, not guessed at.
    local stray
    stray=$(pgrep -f "MDX_TARGET=$target" 2>/dev/null | tr '\n' ' ')
    [ -n "$stray" ] && mdx_warn "processes tagged MDX_TARGET=$target exist but are not in a PID file: $stray
   (started outside the wrappers — stop them with the PID their own output printed)"
    return 0
  fi

  local pid; pid=$(cat "$pidfile" 2>/dev/null)
  if ! mdx_pid_is_fleet "$pid" "$target"; then
    # Never kill a number we cannot prove is the fleet: after a reboot the
    # recorded PID can belong to anything (see mdx_pid_is_fleet).
    mdx_ok "bots for '$target' already stopped (stale PID file cleared — $(mdx_pid_describe "${pid:-0}"))"
    rm -f "$pidfile"
    return 0
  fi

  mdx_info "stopping bots for '$target' (pid $pid and descendants)"
  mdx_kill_tree "$pid"
  rm -f "$pidfile"
  mdx_ok "bots stopped for '$target' — no other target was touched"
}
