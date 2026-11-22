# H-09 — Every book-walking simulator has a scan budget; the FOK gate counts every maker it passes and fails closed; public depth queries are bounded

*Source: [hardening-plan-2026-09.md](../../hardening-plan-2026-09.md) · Wave 1 (backend upgrade #1: solvency & book poisoning) · findings F4 · HIGH + F35 · LOW · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

`class: security-high`

**Mechanism.** `crossableDepth` (`:2665-2690`) and `walkFillable` (`:2747-2903`, loop at
`:2795`) iterate `OrderBook.findBestMatchExcluding` (`OrderBook.mo:526-546`, "O(log K +
entries skipped)" *per call*) with a growing exclude set and no scan counter — O(N²) in resting
orders inside the cap, a count attackers inflate (no reservation on resting orders, W4-24; 100
per owner; spend-all placements exempt from min notional). Sinks: `getTakeableDepth` public
query (`:2936-2944`, `#all` budget, caller-chosen `capPrice`), `quoteSwap` (`:13177`), the FOK
gate (`:3053-3055`), the post-only probe (`:3079`, `#base(1)` walks every unfunded maker),
`releaseCrossSwap` (`:3556`). `tickAmm` and `finaliseExpiredPending` are bare self-sends
(`:7560-7561`), not under `hbReady`/`hbRun`; a trap rolls back `removeDeferredExec` so the same
entry re-traps at full cadence — the sibling pass was capped after 2,970 orders trapped 40B
(`:3365-3374`). Separately (F35), the FOK gate compares *depth* only: the engine spends one of
`MAX_MATCH_ITERATIONS_PER_CALL = 256` per maker touched (fills, skips, unfunded cancels), so
~250 unfunded dust makers ahead of real depth pass the gate and the FOK partial-fills — the
outcome `MatchingEngine.mo:153-164` forbids. 6940dcf added ctx exclusions to the walker but no
budget.

**Fix criteria.** (1) `WALK_SCAN_MAX` counter in `walkFillable` and `crossableDepth` counting
every entry visited (skipped, unfunded, shielded, self); the walker returns a `truncated` flag.
(2) The FOK gate's budget equals the engine's per-call iteration cap (the
`FOK_SIM_MAKER_BUDGET` shape): a gate that hits the budget before reaching `d.qty` KILLS (fails
closed), never passes. (3) `getTakeableDepth`/`quoteSwap` clamp the walk to a band around
`refPrice` or the scan cap. (4) Dispatch `tickAmm` and `finaliseExpiredPending` through an async
variant of `hbReady`/`hbRun` (the `armLiquidationDispatch` pattern at `:7564`) so a repeated
trap backs off — record as an extension of W3-08 (D7).

**Verify.** Junk-band fixture (several thousand unfunded resting orders inside the cap): one
release pass and one `getTakeableDepth`/`quoteSwap` complete within a bounded instruction count
(`devSweepCostProbe`); a staged FOK over >256 small funded makers, and over ~250 unfunded makers
ahead of sufficient AMM depth, records a kill with no trade settled (`test_fok_market.sh`);
an injected trap in one market's release leaves other markets serviced on the next beat
(`test_heartbeat_isolation.sh` gains `amm`/`finalise`).

**done 2026-09-04** (task `1788467606`, branch claude/steady-brattain-70eed1; code `f02a73d`, merged to main as `2178e8b`): backend + tests, candid ADDITIVE and dev-only (`devSweepCostProbe` gained `walk*` fields; `candid/backend.did` committed), no stable-field change. **Fix**: (1) `walkFillable` / `crossableDepth` count EVERY visited entry (skipped, unfunded, shielded, self) against `WALK_SCAN_MAX = 512` and return `truncated` + `scanned` — 1,024 tripped the 5B query limit in the probe; 512 measured 0.73B for the depth walk, 0.72B for the swap walk, 0.18B for the 256-maker FOK gate. (2) The FOK gate walks with `FOK_GATE_ITER_BUDGET = MatchingEngine.MAX_MATCH_ITERATIONS_PER_CALL` (256) and KILLS when the budget runs out before the quantity is reached (fails closed; the outcome record names the quantity reached); the post-only probe walks under the same budget. (3) `getTakeableDepth` clamps the caller's cap to ±25% of `refPrice` (`depthQueryCap`) plus the scan cap; `quoteSwap` walks under the scan cap; `releaseCrossSwap` sizes from the truncated depth. (4) D7: `finaliseExpiredPending` is `async*`, dispatched via `hbRunAsync("finalise")`; the AMM tick is split into `tickAmmPool` per market as `hbRun("amm:<marketId>")` + `hbRun("ammsnap")`, so one market's trap backs off that market only. **Gates**: new `tests/test_walk_scan_budget.sh` 13/13 (RED pre-fix: both public queries trapped at the 5B query limit on 2,048 junk asks); `test_fok_market.sh` §10/§11 27/27 (RED pre-fix: the FOK partial-filled past unfunded dust); `test_heartbeat_isolation.sh` §5/§6 28/28 (`amm`/`finalise` breakers); hygiene §6f pins PASS; `mops test` 19/19; `test_swap_direct_budget` PASS post-merge; full `run_all.sh` on a reseeded venue 98 passed / 2 failed, both proven NOT H-09: `test_breaker_widening` §2 pre-existing (filed `1788476226`, fixed by seat-1 `f43c7e4`) and `test_margin_heatmap` §8 a suite-order artefact (filed `1788476227`, fixed by seat-3 `037de7d`). **Remote**: the engine/subnet upgrade of the merged build is DEFERRED to the operator's folded deploy sitting (task `1788469062`), per the operator's answer in the task file; the bookkeeping half closed 2026-09-04 after the H-wave corpus landed on main (`59906ee`).

## Done when

- [x] Every **Fix criteria** item above is implemented; no stable-field drops, no candid change beyond what the brief flags
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (record the red run in the task log); adjacent cases enumerated per README §"Closing a task"
- [x] Full suite green on `#dev`; posture restored to `#play` before merge; deploy hygiene PASS
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the merge sha
