# W4-17 — Arbitrageur design cluster: unhedged commits, no price bound, stale marks, a 65-second budget

**Issue:** [#24](https://github.com/dfinity/public-multidex/issues/24) items 2–5 — OhShii Labs
**Status:** ALL VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` MEDIUM / `#production` **N/A while gated** — see below
**Effort:** M–L (cluster)

## Posture note — why these are deferred together

`extMarketSwap` and `fundArbitrageur` both hard-`#err` on `IS_PRODUCTION`, so the entire arb
external-market path is `#play`-only today. Every item below is a **latent design flaw that
activates the moment that gate is lifted**. Treat this file as the gate on making the arbitrageur
value-bearing: it should be worked *before* that flip, not after.

The one-line cap clamp is split out as [W4-08](W4-08-arb-trade-cap-clamp.md) because it fixes a
self-inflicted stuck state that bites on `#play` today.

## Item 2 — the import commits before the hedge exists

The rich branch reads the book, then commits `extMarketSwap(#importBase, q)` — which on the DEX side
subtracts cost, credits base, writes two permanent rows and charges `_arbHourUsd` — and only then
places the hedge. The justifying liquidity can be withdrawn inside the await (the attacker's timing
is free: `lastTickNs` is published on an unauthenticated query). The `#err` arm calls `note(...)` and
falls through — **no compensating action**.

Filed by the reporter as a design flaw rather than an await race, correctly: the defect would exist
even if the two calls were atomic, because an unconditional external haircut is paid before a venue
hedge that may be unfillable.

*Fix direction:* invert the legs — place the venue sell first as post-only/IOC and import only the
quantity that actually filled. If the import must lead, re-read depth immediately after it and export
straight back in the same tick rather than resting an 8-second order.

- `src/arb/main.mo:212` (depth read), `:222`, `:224` (commit), `:226` (hedge), `:231` (`#err`, no unwind)
- `src/backend/main.mo:5187-5198` — what the import commits

## Items 3 & 4 — no price bound, and two marks for one arbitrage

`extMarketSwap` has **no `maxCost` / `minProceeds` / `expectedMark` parameter in either canister**, so
the arb cannot express an acceptable price at all; the DEX's own marketable collar is 5%, twenty-five
times the arb's 20 bps edge. `mark` is captured once and then reused across three further awaits, so
the import is priced by the DEX at its **current** mark while the hedge is priced off the **stale**
one. `now` is likewise captured once before the loop and reused for every market's freshness test, so
the staleness guard is **loosest exactly where the data is oldest**.

*Fix direction:* add a price bound to the external-market interface and have the DEX refuse when its
current mark would breach it — under an unbounded await this is the only thing that makes the
cross-canister leg safe. On the arb side, re-read the pool immediately before pricing, and move the
`now` capture inside the loop.

- `src/arb/main.mo:117` (signature), `:187`, `:189`, `:192-194`, `:224`, `:226`
- `src/backend/main.mo:5153` (signature), `:5176`, `:5187`

## Item 5 — the hourly cap is gross on both legs against a tumbling window

`_arbHourUsd` is charged the **gross** notional on the import *and* on the export, so one round trip
of the same dollar costs the budget twice, and the window reset is **tumbling**, not rolling. Four
markets × 2 legs × $5,000 at a 5 s tick against a $512,500 cap trips in roughly **65 seconds**, after
which the arb is dark for the remaining ~59 minutes — **including its flatten leg**, so inventory
opened before the trip is stranded and unhedged. The trip returns before any `logEventF`, so the
event log records nothing.

The prior round approved this cap's stability properties; what was missed is that the same cap
doubles as a one-minute kill switch on the price-pinning mechanism.

*Fix direction:* charge on **net** external exposure rather than gross turnover (an import followed
by an export of the same base is exposure-neutral), or exempt `#exportBase` entirely since closing a
position can only reduce risk. Convert to a genuinely rolling window (a small ring of per-minute
buckets). Size `TICK_NS`, `TRADE_CAP_USD` and `ARB_HOURLY_CAP_USD` against each other in one place
with an assertion, and log the trip.

- `src/backend/main.mo:5176`, `:5178` (tumbling reset), `:5198`, `:5213`, `:5054` (the "rolling" comment)

## Done when

- [x] No leg commits value before its hedge is established, or an unwind exists
- [x] `extMarketSwap` carries a price bound the DEX enforces against its current mark
- [x] Marks and clocks are re-read per market, not captured once per loop
- [x] The hourly budget cannot dark the flatten leg; the trip is logged
- [x] The three sizing constants are reconciled in one place with an assertion
- [ ] Re-checked before any change that lifts the `IS_PRODUCTION` gate — **standing instruction, stays open by design**

## Completed 2026-08-15 (except the standing re-check gate)

- **Item 2**: a refused hedge now UNWINDS — the arb exports the just-imported base straight back
  (round-trip haircut, bounded and logged) instead of falling through unhedged. The
  legs-inverted design was weighed; with no order-id from `placeLimitOrderExp` a sell-first shape
  can't cancel its own resting order, so unwind-on-failure is the shape that fits the interface.
- **Items 3/4**: `extMarketSwap` takes `maxMarkE8 : ?Nat` and the DEX refuses when its CURRENT
  mark breaches it (import above / export below) — the only guard that works across an unbounded
  await. The arb passes its decision mark ±50bps on every leg (flatten, import, unwind) and reads
  its clock PER MARKET, so the staleness test no longer loosens as the loop ages.
- **Item 5**: exports are exempt from `_arbHourUsd` (closing exposure must never be darkened;
  measured pre-fix: ~65s to trip, then 59 minutes dark including the flatten), the trip is
  edge-logged per window, and the per-call cap still bounds any single export. Constants
  reconciled executably: hygiene §6h asserts arb ≤ DEX per-call AND hourly ≥ 10× per-call.
- The venue is unseeded at this point in the queue run; the arb's end-to-end exercise happens at
  the closing cold_start (play_start wires + funds it against the seeded venue). The
  IS_PRODUCTION-lift re-check box stays open deliberately — this file remains the gate.
