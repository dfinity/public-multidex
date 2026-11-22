# W3-08 — Nine heartbeat subtasks run inline, so a trap in any one stops maintenance permanently

**Issues:** [#5](https://github.com/dfinity/public-multidex/issues/5) item 7 (OhShii Labs) ·
re-raised by [#40](https://github.com/dfinity/public-multidex/issues/40) item 2 as a triage-doc error
**Status:** **LIVE** at `01d2b23` (2026-08-14) — the 1.60 triage marks §1.7 "implemented"; it is not
**Severity:** `#play` MEDIUM / `#production` MEDIUM
**Effort:** M

## What's wrong

The heartbeat dispatches two kinds of subtask, and only one kind is isolated:

- `ignore tickX()` on an `async` function **schedules a separate message** — a trap rolls back that
  message alone and the heartbeat survives. (Settled by the compiler in the 1.60 pass: moving the
  dispatch into a non-`async` helper makes moc reject it with `M0047, send capability required`.)
- a **direct synchronous call** runs inline — a trap kills the whole heartbeat message, and every
  subtask after it stops running, permanently, on every subsequent beat.

Nine subtasks are still in the second group:

| subtask | cadence |
|---|---|
| `reapClosedOrders` | `HB_REAP_NS` |
| `drainLedgerJournal` | **every beat** |
| `tickTier` | `HB_TIER_NS` |
| `tickHeatmaps` | `HB_HEAT_NS` |
| `tickLeaderboardShard` | `HB_LEADER_NS` |
| `settleInsuranceArrears` | **every beat** |
| `sweepStaleUserOrders` | `HB_TTLSWEEP_NS` |
| `tickCandleFill` | `HB_CANDLEFILL_NS` |
| `tickDeadman` | **every beat** |

Aggravating properties confirmed in the original report and still true: the ledger journal is
self-reinforcing (its sole write funnel keeps filling while the drain is dead, and `List.clear` is
only reachable after the full loop), every `HB_*` constant divides 300 s evenly so cadences align,
and there is **no consecutive-failure breaker** on any of them.

Note `sweepStaleUserOrders` is declared `: Nat`, not `async`, so its textual `ignore` defers
nothing — the reporters classified it correctly *despite* the misleading syntax.

## Evidence

- `src/backend/main.mo:6487-6550` — the heartbeat body
- `:6530`, `:6531`, `:6535`, `:6536`, `:6537`, `:6544`, `:6545`, `:6546`, `:6547` — the nine inline calls
- `:6523`, `:6524`, `:6528`, `:6529`, `:6532`, `:6534`, `:6538`, `:6539`, `:6540` — the isolated `ignore tickX()` dispatches

## Fix

Decide per subtask rather than converting all nine reflexively — each conversion costs a message and
changes ordering guarantees:

1. **Convert to `async` + `ignore`** the ones whose failure should not take the beat down and whose
   ordering does not matter (`tickTier`, `tickHeatmaps`, `tickLeaderboardShard`, `tickCandleFill`).
2. **Keep inline but make trap-proof** the cheap ones whose ordering matters
   (`recomputeShedFloor`, `tickDeadman`) — audit them for any subtraction/division/trap path.
3. **`drainLedgerJournal` needs care**: it runs ahead of the shipper deliberately so ledger rows
   chase their semantic events. Isolating it changes that ordering — decide explicitly.
4. Add a **consecutive-failure breaker** with backoff, mirroring the liquidation breaker
   (`LIQ_FAIL_BREAK_THRESHOLD`, geometric backoff, edge-triggered log, admin reset) — that pattern is
   already in the tree and was written for exactly this class.

## Done when

- [x] A forced trap in each of the nine leaves `_lastHeartbeatNs` advancing and the other subtasks running
- [x] A repeatedly-trapping subtask backs off and logs once, rather than burning every beat
- [x] The `drainLedgerJournal` ordering decision is written down
- [x] `docs/issue-triage-2026-08.md` §1.7 is corrected — deferred to [W6-01](W6-01-refresh-triage-document.md) as planned (noted there)

## Completed 2026-08-15

- All nine subtasks dispatch through `hbRun(name, task)` — a generic async self-send wrapper, so
  the ORIGINAL functions and their other callers are untouched and a trap kills one subtask
  message, never the beat. Guarded by `hbReady`: the liquidation-breaker pattern generalized —
  dispatch commits in the beat's message, completion in the subtask's, `dispatches > completions`
  at the next arm grows the streak → geometric cadence backoff (cap 32×; every-beat tasks back off
  on a 1s base), edge-triggered error log at streak 3, recovery log on completion. The task's own
  insight sharpened into the design rule: NO breaker can attach to an inline task — its accounting
  rolls back with the beat — so isolation and breakers are one decision, not two.
- Per-subtask decisions: `recomputeShedFloor` stays INLINE BY CHOICE (audited trap-free; the floor
  must move in the observing beat). `tickDeadman` gets a zero-cost inline size guard with the sweep
  isolated. `settleInsuranceArrears` keeps every-beat cadence, isolated. **drainLedgerJournal
  ordering decision, written down at the dispatch**: isolation can only delay ledger rows FURTHER
  BEHIND their semantic events (the safe direction of "rows chase events"; rows never precede),
  and the 10s-cadenced shipper still trails the every-beat drain in steady state — chosen over
  inline because the inline alternative both kills maintenance on a trap and cannot carry a
  breaker.
- `getHbHealth` query (dispatch/completion/streak per subtask) + dev hook `setTestHbTrap(name)`.
  `tests/test_heartbeat_isolation.sh` (8 green): with "drain" trapping every run, the beat keeps
  advancing, siblings keep completing, streak grows, backoff cuts dispatches to 1-in-8s, and
  clearing the trap resets the streak with a recovery log. Hygiene §6f pins all nine hbRun
  dispatches + both written decisions. Regressions: staged index 17/0, archive chain 21/0, sealed
  model 6/0, autofuel guards 11/11 (whose treasury-principal extraction also got fixed — the
  quoted "principal" field is a display collision).
- Live bonus observation: the W3-03 daily budget engaged during this session's suite churn
  (spentToday 555 ICP > 500 cap → auto-fuel deferring, logged) — the cap demonstrably works.

## Extended 2026-09-04 — D7 (H-09 / H-22): the last two bare self-sends join the breaker, and the release passes are paced

*Line numbers at `e987451` (`src/backend/main.mo`). Recorded here per the 2026-09 hardening plan's
decision D7 (task `1788467622`, H-25); the design-side note is `docs/access-prioritization-design.md` §6.*

- **Two self-sends had stayed outside `hbRun`**: the AMM tick (every pool requoted in one bare
  `async` self-send) and the finaliser (bare `ignore finaliseExpiredPending()` from the beat). A trap
  in either rolled back its own message — `removeDeferredExec` included — so the same staged entry
  re-trapped at full cadence, unaccounted, forever; and one market's junk band (F4) took every
  market's requote down with it. H-09 closed both (code `f02a73d`, merged `2178e8b`):
  - `finaliseExpiredPending` is an `async*` COMPUTATION (`:2209`) dispatched as
    `hbRunAsync("finalise", …)` (`:8983`). `hbRunAsync` (`:8881`) awaits it INLINE — `await* task()` —
    so it is still ONE isolated message carrying `hbRun`'s accounting (a genuine cross-round `await`
    would split the message, and a 0.5 s task would read as "lost" every beat on mainnet). `async*`
    rather than a sync task because `processGeptorDue` (`:4474`) is a real fire-and-forget send and
    needs send capability.
  - The AMM tick is split per market: `tickAmmPool(id, now)` (`:4891`) is dispatched once per pool as
    `hbRun("amm:" # id, …)` (loop `:8986-8992`), the snapshot separately as `hbRun("ammsnap", …)`
    (`:8993`). One market's trap backs off THAT market only; the others are serviced next beat.
  - `hbTrapTest` (`:8852`) and `hbComplete` (`:8862`) are the shared halves of `hbRun` (`:8869`) /
    `hbRunAsync`; the per-market keys live in the same `_hbDisp` / `_hbDone` / `_hbStreak` maps
    (`:8823-8825`) and surface in `getHbHealth` (`:8892`); `_lastAmmPoolNs` (`:8888`) holds the
    per-pool dispatch stamps `hbReady` (`:8832`) reads. `setTestHbTrap(?"amm:<marketId>")` (`:8906`)
    trips one market on `#dev`. The walk a tripped release was doing is bounded upstream too —
    `WALK_SCAN_MAX = 512` (`:3173`), `FOK_GATE_ITER_BUDGET = MatchingEngine.MAX_MATCH_ITERATIONS_PER_CALL`
    (256, `:3174`), `depthQueryCap` ±25 % of `refPrice` (`:3471`) — the breaker is the backstop, not
    the bound.
- **Dispatch table** (the breaker key IS the subtask name; cadence is the `hbReady` base, backed off
  ×2^streak, cap 32×, every-beat tasks on a 1 s base):

  | key | task | cadence | dispatcher |
  |---|---|---|---|
  | `finalise` | `finaliseExpiredPending` (`:2209`) — expiry sweep, GEPTOR due, deferred-expiry + cross-swap passes | `HB_FINALISE_NS` 0.5 s (`:8445`) | `hbRunAsync` (`:8983`) |
  | `amm:<marketId>` | `tickAmmPool` (`:4891`) — requote / panic-cancel, rebalance, resting sweep, THAT market's `processDeferred` | `HB_AMM_NS` 2 s (`:8446`), per pool via `_lastAmmPoolNs` | `hbRun` (`:8990`) |
  | `ammsnap` | `tickAmmSnapshot` (`:4934`) | `HB_AMM_NS` | `hbRun` (`:8993`) |
  | the nine of 2026-08-15 | `reap` `drain` `tier` `heat` `leader` `arrears` `ttlsweep` `candles` `deadman` | as above | `hbRun` (`:8960-9027`) |

- **The release passes are paced (H-22, code `be7d829`, merged `e987451`)** so the message the
  breaker isolates is also bounded. One shared pacer beside the expiry pass's constants
  (`MAX_EXPIRY_RELEASES_PER_PASS = 256` `:581`, `EXPIRY_PASS_FILL_BUDGET = 1_024` `:591` — the
  model): `MAX_RELEASES_PER_PASS = 256` and `RELEASE_PASS_FILL_BUDGET = 1_024` (`:611-612`, both
  `transient`), one `ReleaseBudget` per pass (`:617`) via `newReleaseBudget` / `releaseBudgetOpen` /
  `chargeRelease` (`:618-624`), checked at the TOP of each release. `processDeferred` (`:3972`)
  stops at either cap, leaves the remainder staged in the SAME (tierRank DESC, ts ASC) order
  (`stagedForMarketSorted` `:4127` → `sortDeferredByPriority` `:4146`), sets `stillStaged` (`:4004`,
  `:4013`) so the GEPTOR is re-armed (`:4026`), and the 2 s tick's requote resumes the cut pass;
  `processDeferredSwaps` (`:4174`) runs the same budget (`releaseCrossSwap` `:4291` returns its fills
  over both legs) and the next `finalise` resumes it. Nothing is dropped, only paced.
- **Which message a release rides is chosen by the breaker.** `ammRequote(pool, release : Bool)`
  (`:2572`): the tick and the operator's `requoteAmm` (`:19505`) pass `true`; the GEPTOR finalizer
  (`finalizePriceFanout` `:19169`, `#geptor`) passes `hbStreakOf("amm:" # mkt) == 0` (`:19283`) and
  runs the swap pass only while `hbStreakOf("finalise") == 0` (`:19292`; `hbStreakOf` at `:8861`).
  So a tripped market's fetched mark and fresh ladder ALWAYS commit in the finalizer's message, and
  its release runs only under its own backed-off `hbRun("amm:<marketId>")`; a healthy market keeps
  the inline release (no extra hop, release latency unchanged).
- **Dev hooks and probe.** `setTestReleasePacing(maxReleases, fillBudget)` (`:12942`; null = default,
  0 → 1) pins the pacer on `#dev`; `devSweepCostProbe` (`:21676`) reports `releaseSort` /
  `releaseSortSynth` / `releaseSynthAtProbe` / `releaseMaxPerPass` / `releaseFillBudget`
  (`:21731-21735`), the synthetic cohort being `RELEASE_PROBE_SYNTH = 5_000` (`:960`). Measured: the
  pre-pass collect+sort is the only N-dependent term left — 1.19 B instructions at 5,000 staged —
  filed as follow-up `1788550465` (per-market staged index + top-K selection).
- **Where the pins live.** `tests/test_heartbeat_isolation.sh` §5 (the finaliser runs behind the
  breaker), §6 (the tick is dispatched per market), §7 (a tripped market's mark commits while its
  release waits for its own `hbRun`); `tests/test_release_pacing.sh` §1–§5 (the real 256 cap in
  priority order, the pin, the fill budget, the swap pass, liveness under running timers + the
  probe); `tests/test_deploy_hygiene.sh` §6f (`hbRunAsync("finalise"`, `"amm:" # id`, no bare
  `ignore tickAmm()` / `ignore finaliseExpiredPending()` remains, `await* task()` inline) and §6an
  (`processDeferred(updated, now);` runs inside `ammRequote` after the pool put and the sweep).
