# W1-06 — Pocket-ic reaper trio: owner-resolution assumes port 8000, misfires under worktree parallelism

**Issue:** none — raised by [W1-01](W1-01-retire-stop-local-bots.md) (queue step 5), 2026-08-14
**Status:** VERIFIED LIVE in the working tree; one misfire already on record (worktree master killed)
**Severity:** `#play` LOW-MEDIUM (local dev availability only — pocket-ic is the local replica binary
and can never select the live venue) — but the kill path sits inside `cold_start.sh`, the only
tool that restores a wiped local network
**Effort:** S-M

## Why this exists

W1-01's gate (`test_deploy_hygiene.sh` §3) now bans `pgrep -f`/`pkill -f` tree-wide with exactly
two exempted spellings. One of them, `pgrep -f "pocket-ic --ttl"`, is used by three scripts. The
exemption makes the trio permanent, so the trio deserves its own conscious review — and it has a
real defect.

## What's wrong

All three sites select every pocket-ic master on the machine, then decide which one is *legitimate*
by asking **who listens on TCP 8000**:

- `scripts/cold_start.sh` (`zombie_masters`, ~:188-206) — cwd-filters to this repo (good, that part
  is fixed and documented at :207), then treats any repo-owned master that is **not the :8000
  listener** as a zombie: `icp network stop` + `kill -9`.
- `scripts/play_start.sh` ~:90-102 — same shape, but `die`s instead of killing.
- `scripts/deploy.sh` ~:806-822 — same shape, warns + interactive `yesno`.

The `:8000` assumption is only true for the canonical checkout. The supported worktree-parallel
workflow (fresh `ICP_HOME`, `gateway.port 0`) gives a worktree's network a **random port**, so from
a worktree:

- the worktree's own healthy master is repo-owned (cwd == worktree) but is not the :8000 listener →
  `cold_start.sh` classifies it a zombie and **kills it** (this is the recorded incident behind the
  "STRAYS neutered" workaround);
- worse, its `icp network stop` runs against the **ambient** `ICP_HOME` — if the operator forgot to
  export the worktree's one, that stops the *canonical* network, and network stop/start **wipes
  state**;
- `play_start.sh` refuses to run for no reason; `deploy.sh` nags for no reason.

## Fix sketch (investigate, then pick)

1. Resolve the owner from the network's **own record** — the gateway port/PID that `icp network`
   writes under the active `ICP_HOME` — instead of hardwiring `:8000`. Each checkout then judges
   only against its own gateway, whatever port it landed on.
2. Alternatively: have `zombie_masters` compare against the port the *project config* declares
   (canonical checkout → 8000; worktree → whatever its `ICP_HOME` records), and make the kill path
   refuse-and-report (play_start's behaviour) whenever the two disagree, rather than kill.
3. Whatever is chosen: `cold_start.sh`'s `icp network stop` in the zombie branch must be provably
   scoped to the same `ICP_HOME` whose master it is about to kill — stopping A's network and
   killing B's master is the current worst case.

Keep the cwd filter — the 2026-07-29 open-saas lesson (another project's healthy replica is not our
zombie) still stands. This task is about the **owner** test, not the repo test.

## Done when

- [x] From a worktree with its own network up (fresh `ICP_HOME`, random port), `cold_start.sh`
      does not kill the worktree's own master, and the canonical checkout's network is untouched —
      **by construction, not by worktree e2e re-run** (see note below)
- [x] From the canonical checkout, a genuine zombie (repo-owned master that lost its gateway) is
      still detected and reaped
- [x] `play_start.sh` and `deploy.sh` no longer misclassify a worktree master as a zombie
- [x] The "STRAYS neutered" workaround in the worktree runbook is retired

## Completed 2026-08-15

- `mdx_local_gateway` + `mdx_stray_masters` in `scripts/lib/targets.sh`: the owner is resolved from
  `icp network status` (Api Url → port → listener PID) — the same ambient-`ICP_HOME`+cwd scope
  `icp network stop` acts on, so the judgment and the stop can no longer diverge (fix-sketch #3).
  All three scripts delegate; the cwd filter survives inside the shared detector.
- **Bonus finding fixed**: `deploy.sh`'s inline copy had **no cwd filter at all** — with twelve
  foreign pocket-ic masters running (a normal machine state, observed live), every plain local
  deploy tripped its zombie nag on a foreign master, and a non-interactive run would wedge on the
  `yesno`. The shared detector scopes it.
- Health probes and printed URLs in cold_start/play_start now use the resolved port instead of a
  hardwired `:8000` (re-resolved after `icp network start` — a fresh worktree network binds a
  random port).
- Verification: `mdx_local_gateway` → `12873 8000` matching lsof ground truth; `mdx_stray_masters`
  empty on the healthy checkout with 12 foreign masters up; a spoofed repo-owned master
  (argv-matched, cwd = repo, not the owner) detected as a stray and then killed by PID; a **full
  `cold_start.sh` play bring-up ran clean end-to-end** (106 s: gates → deploy → seed → bots →
  oracle live) — pre-fix that background run would have wedged on deploy.sh's nag. The worktree
  side is correct by construction (port-agnostic owner from the checkout's own record); a real
  worktree e2e re-run of the runbook recipe post-fix has not been done — if its old failure
  signature ever reappears, re-verify before re-neutering anything.
- Hygiene: §3's `pgrep -f "pocket-ic --ttl"` exemption is now scoped to `targets.sh` alone (the
  spelling anywhere else fails — negative-controlled); §3b pins the CLI-record resolution and bans
  the `lsof :8000` owner spelling in all three scripts.
- Runbook: the STRAYS workaround is retired in the worktree memory
  (`worktree-parallel-local-network`), with the not-yet-re-verified caveat recorded there too.

## Notes

The W1-01 gate exemption pins the *spelling* `pgrep -f "pocket-ic --ttl"`. If the fix changes how
masters are enumerated (e.g. reading the recorded PID instead of pgrep), delete the exemption from
`tests/test_deploy_hygiene.sh` §3 in the same commit — an exemption with zero uses is a hole, not
a grandfather clause.
