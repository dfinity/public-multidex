# W1-01 — Retire `stop_local_bots.sh`: its pattern now selects the LIVE subnet fleet

**Issue:** [#36](https://github.com/dfinity/public-multidex/issues/36) item 36.5 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14) — **and armed right now**
**Severity:** `#play` MEDIUM / `#production` HIGH (live-fleet kill)
**Effort:** S

## Why this is first

`.run/bots-subnet.pid` holds a **live pid, alive since 2026-08-01**. The fleet this script would
kill is the one driving multidex.ai today. This is the fifth instance of a class that already has
four recorded incidents (2026-07-23, 2026-07-28, and the two recorded at `play_start.sh:335-339`).

## What's wrong

`scripts/lib/bots.sh:22-23` runs `trading_simulation.sh` for **every** target — `local`, `engine`
and `subnet`. `scripts/stop_local_bots.sh:25` still pattern-matches it:

```
PATTERN='scripts/(simulate_trading|trading_simulation)\.sh'
```

The target is chosen by environment (`IC_ENV` / `MDX_TARGET`), and environment assignments are not
part of `argv`, so `pgrep -f` **cannot** tell a local fleet from the subnet one. The script's own
header claims `sim_trading.sh` is the live-fleet script and is therefore excluded — that was true
when written, and the rename in `16137cf` moved the live fleet *into* the kill set. It then prints:

```
stop_local_bots: done (live subnet fleet untouched)
```

which is now false.

The standing rule added in that same commit
(`.claude/skills/mdex-process-safety/SKILL.md` §2, "Never `pkill -f` / pattern-kill") is prose:
it is cited in **0** tracked files, while §5 (the `--identity` rule) is cited in 10 and enforced
executably in two.

## Evidence

- `scripts/stop_local_bots.sh:25` — the pattern; `:26`, `:38` — `pgrep -f "$PATTERN"`; `:44` — the false claim
- `scripts/lib/bots.sh:22-23` — `local|engine` **and** `subnet` both → `trading_simulation.sh`
- Eleven test headers still instruct an operator to run it: `tests/test_amm_staleness.sh:11`,
  `test_inventory_floor.sh:28`, `test_cross_swap_sizing.sh:11`, `test_swap_outcome.sh:8`,
  `test_fok_market.sh:8`, `test_oracle_fallback_band.sh:10`, `test_cross_swap.sh:7`,
  `test_sealed_model.sh:6`, `test_slippage_anchor.sh:12`, `test_order_expiry.sh:7`,
  `test_margin_staleness.sh:22`
- `scripts/cold_start.sh:390` cites the script as *documentation of the incident* rather than as an
  instance of it

## Fix

The safe replacement already exists and is already used by automation
(`cold_start.sh:406-410`, `tests/run_all.sh:103`): `scripts/stop_bots_local.sh` → `mdx_bots_stop`,
which stops by PID-file ancestry (`mdx_kill_tree`) and never matches on a name.

1. Delete `scripts/stop_local_bots.sh`.
2. Repoint all eleven test headers at `bash scripts/stop_bots_local.sh`.
3. Give the pattern-kill rule an executable form so the class cannot come back by rename —
   extend `tests/test_deploy_hygiene.sh` §3 to scan **all** of `scripts/`, `scripts/lib/`, `ops/`
   and `tests/` for `pgrep -f` / `pkill -f` on a script name, not just the eight hand-listed files.

## Done when

- [x] `scripts/stop_local_bots.sh` no longer exists
- [x] No test header names it; `grep -rn stop_local_bots` returns only historical prose in `cold_start.sh`
- [x] A gate fails on a newly introduced `pkill -f`/`pgrep -f` against a script name anywhere in the tree
- [x] Verified with the live subnet fleet running that the local stopper touches only the local tree

## Completed 2026-08-14

- Deleted `scripts/stop_local_bots.sh`; all eleven test headers repointed at
  `bash scripts/stop_bots_local.sh`; `cold_start.sh`'s citation updated to record the retirement.
- `tests/test_deploy_hygiene.sh` §3 extended: scans `scripts/`, `scripts/lib/`, `tests/` and all of
  `ops/` for `pkill -f` **and** `pgrep -f`. The mechanism is banned rather than script-name
  patterns, because this instance held its pattern in a variable — a same-line name test cannot see
  through `pgrep -f "$PATTERN"`. Two reporting shapes are exempted by exact spelling
  (`pgrep -f "pocket-ic --ttl"`, `pgrep -f "MDX_TARGET=`); a separate assertion pins the deleted
  file as staying deleted.
- Negative control ran red: a probe with `pids=$(pgrep -f "$PAT")` and `pkill -9 -f` was flagged at
  both lines; an exemption-shaped probe passed; clean tree passes 64/64.
- Live-fleet check: with subnet supervisor 4667 up (13d15h, 34 children), `stop_bots_local.sh` was a
  clean no-op — "no bots recorded for 'local'", 4667 alive with all children after.
- Raised [W1-06](W1-06-pocket-ic-reaper-worktree-scope.md): the gate now permanently exempts the
  `pocket-ic --ttl` reaper trio, whose owner-resolution (port-8000 listener) misfires under
  worktree-parallel networks — cold_start's kill path has taken out a worktree's own master.

## Notes

Do **not** "fix" the pattern by re-excluding a name — that is what failed. The lesson recorded in
`bots.sh:96-98` is the right one: never guess, report unrecorded fleets instead.
