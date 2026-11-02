# H-08 — The swap `#limitOrder` path enforces `priceBandCheck` like every sibling limit path

*Source: [hardening-plan-2026-09.md](../../hardening-plan-2026-09.md) · Wave 1 (backend upgrade #1: solvency & book poisoning) · findings F3 · HIGH, one line · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

`class: security-high`

**Mechanism.** `executeSwapDirect`'s `#limitOrder` branch (`:13375-13396`) checks
`limitPrice == 0`, `validateNewOrder` (`:13382`), `openOrderCapCheck` (`:13391`, added by
fc89d2c) and parks — no `priceBandCheck` (`:10369`; 100× band + 5% `MARKETABLE_BAND_BPS`
collar, `:10353`), which `placeLimitInner` calls at `:10405`. At release a `#limit` entry under
the fresh ctx executes at its raw limit (`effLimit = d.limitPrice`, `:3027`; #3a excludes
`#limit`). Two accounts print trades at arbitrary prices, set last price / 24h stats, buy
leaderboard rank and level-ladder privileges, and re-poison book depth beyond 100×.

**Fix criteria.** Insert `switch (priceBandCheck(marketId, side, limitPrice)) { case (?e) return
#err(e); case null {} }` before `validateNewOrder` at `:13382` (mirror `placeLimitInner`'s
order). Better: fold the two placement paths onto one choke point.

**Verify.** `tests/test_swap.sh` new §: `swap({mode:#limitOrder})` marketable outside the collar,
and any price outside 100×, rejected with the same string `placeLimitOrder` returns.

**done 2026-09-03**: priceBandCheck gate in executeSwapDirect #limitOrder (6d3a7a5, merged 06d3f5a); test_swap §4 red→green (task `1788467605`, code by claude/seat-2: `6d3a7a5` on top of `4e3adf5`, merged to main `06d3f5a` 2026-09-04; bookkeeping half closed from claude/exec-a after the H-wave corpus landed on main at `59906ee`). **Fix.** `switch (priceBandCheck(marketId, side, limitPrice)) { case (?e) { return #err(e) }; case null {} }` inserted in `executeSwapDirect`'s `#limitOrder` branch (`main.mo:15965`) in `placeLimitInner`'s order — zero check, band (100× fat-finger + 5% `MARKETABLE_BAND_BPS` collar on marketable prices), then `validateNewOrder`; backend only, 8 lines, candid unchanged, no stable-field change. **Verify.** `tests/test_swap.sh` §4 (§4a/§4b band above/below, §4c collar, §4d resting allowed, §4e boundary, §4f/§4g adjacent paths): RED on the pre-fix build (11 failing assertions), GREEN after, and the refusal strings are byte-equal to `placeLimitOrder`'s. Gates run on seat-2: `mops test`, `test_deploy_hygiene` PASS, `test_swap` + `test_price_collar` PASS, full suite on `#dev` 92/94 (the 2 reds pre-existing and unrelated: `test_breaker_widening`, filed as its own task, and `test_oracle_time_bases` §3 in-suite livelock noise, passes alone). **REMOTE rollout DEFERRED**: the engine/subnet upgrade of the merged build is not a consumer act (law 8) — it rides the operator's folded deploy sitting (task `1788469062`); until that sitting both remote targets still run the pre-fix `#limitOrder` branch.

## Done when

- [x] Every **Fix criteria** item above is implemented; no stable-field drops, no candid change beyond what the brief flags
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (record the red run in the task log); adjacent cases enumerated per README §"Closing a task"
- [x] Full suite green on `#dev`; posture restored to `#play` before merge; deploy hygiene PASS
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the merge sha
