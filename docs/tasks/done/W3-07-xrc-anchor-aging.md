# W3-07 — The XRC anchor is aged from arrival and re-stamped as instantaneous

**Issue:** [#27](https://github.com/dfinity/public-multidex/issues/27) item 4 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14) — maintainer confirmed open
**Severity:** `#play` LOW / `#production` MEDIUM
**Effort:** S–M

## What's wrong

The `XrcAnchor` record stores both clocks and documents them itself:

```motoko
xrcTimestampSecs : Nat;   // the minute XRC priced (already 30-90s behind wall clock)
receivedNs       : Int;   // when WE stored it — the freshness clock for use
```

`xrcTimestampSecs` has **no reader**. It appears at its declaration, at its write, in the dev
injector (which hardcodes `0`), and in docs — nowhere else. Freshness is judged only on
`receivedNs`, captured in the outcall's continuation.

Two consequences compound:

1. `XRC_ANCHOR_MAX_AGE_NS` (180 s) bounds how long *we* have held the anchor, not how old the price
   is. XRC's own timestamp is already 30–90 s behind wall clock **by the record's own comment**, and
   that lag is invisible to the gate.
2. The fallback writer calls `AMM.withRefPrice(p, a.rateE8, now)`, and `withRefPrice` sets
   `refPriceUpdatedNs = now`. So an anchor of arbitrary admissible age is **re-stamped as
   instantaneous**, and the 180 s window then *composes* with the downstream staleness walls
   (`MARGIN_MAX_REFPRICE_AGE_NS` = 300 s) instead of bounding them.

Same shape as the `xrcSources`-never-read item already recorded in the 1.60 triage: a field written
for a safety purpose with no consumer.

## Evidence

- `src/backend/main.mo:13711` — `XrcAnchor` declaration with both clocks
- `:13782` — the only write of `xrcTimestampSecs`; `:5443` — dev injector hardcodes `0`
- `:13798` — `xrcAnchorFresh` ages from `receivedNs` only
- `:13858` — `AMM.withRefPrice(p, a.rateE8, now)`; `src/backend/lib/AMM.mo:323` — `refPriceUpdatedNs = now`

## Fix

- Age the anchor from `xrcTimestampSecs` (converted to ns), or from
  `min(receivedNs, xrcTimestampSecs)`.
- Pass the anchor's own **effective timestamp** into `AMM.withRefPrice` instead of `now`, so
  downstream staleness gates see the true age.
- Make the dev injector supply a real timestamp rather than `0`, or the fix is untestable through it.

## Done when

- [x] An anchor whose XRC minute is old is rejected by the freshness gate even if just received
- [x] A fallback-written `refPrice` carries the anchor's age, not `now`
- [x] Downstream margin staleness walls bound total age rather than composing with the anchor window
- [x] `xrcTimestampSecs` has a reader, and the dev injector can exercise it

## Completed 2026-08-15 — landed with W3-06 as one oracle pass

- `xrcAnchorEffectiveNs(a)` = `min(receivedNs, xrcTimestampSecs·1e9)` (receivedNs alone when the
  minute is 0/unknown — legacy records). `xrcAnchorFresh` ages on it; the fallback writer stamps
  `AMM.withRefPrice` with it, so the 180 s anchor window is BOUNDED BY the 300 s margin wall
  instead of composing with it. `xrcTimestampSecs` has two readers now.
- The dev injector writes the real current minute and takes `opt ageSecs` to backdate it —
  `tests/test_oracle_time_bases.sh` §1 pins fresh-received-old-minute rejection, §2 pins the mark
  carrying the anchor's ≈60 s age (measured from `refPriceUpdatedNs`).
