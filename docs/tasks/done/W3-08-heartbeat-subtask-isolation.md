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
