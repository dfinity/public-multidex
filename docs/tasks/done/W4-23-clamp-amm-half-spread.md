# W4-23 — Clamp the AMM half-spread; an unconfirmed price jump silently withdraws every bid

**Issue:** internal red-team round 2, finding R12 — **retargeted**: the reported trigger is
unreachable, a sibling is not
**Status:** VERIFIED LIVE at `d8f4c58` (2026-08-17)
**Severity:** `#play` LOW / `#production` LOW–MEDIUM — liquidity withdrawal + observability, no value loss
**Effort:** S

## The reported trigger is theoretical

R12 blames `volRegime`. Confirmed unclamped (`lib/AMM.mo:294-295`), and the ladder math is as quoted
(`:188-197`), with `Fixed.fromFloat` clamping negatives to 0 (`lib/Fixed.mo:45-47`). But driving
`half > 1.0` needs `volRegime > ~19,960 bps` — a single-sample log-return of ~6.31, i.e. a **~550×
mark move in one requote step**. Moving `refPrice` at all requires ≥3 independent sources agreeing
within `PRICE_MAX_STDDEV_BPS = 50` (`main.mo:14373`, gate `:14734`) and then surviving the breaker.
Realistic magnitudes are well-behaved: +100% → `half` = 11%; +900% → 37%; +5000% → 62%. **Out of
reach.**

## The reachable sibling

`ammBreakerWidenBps` (`main.mo:1991-2003`) returns `|proposed − ref| / ref × 10000` with **no cap**,
and enters the same sum at full weight (`:2211`, `:2218`):

```
halfBps = spreadBps + 0.5*volRegime + hostilityBps + stalenessBps + breakerBps
```

`hostilityBps ≤ 40` (`:1139`) and `stalenessBps ≤ STALE_MAX_BPS = 2500` (`:208`) are bounded;
`volRegime` and `breakerBps` are not. A **merely pending, unconfirmed** jump proposing more than
~2.0× the current ref puts `breakerBps` over 9,980 and zeroes the entire bid ladder **on one
aggregate reading** — no 30s independence gap, no corroborating sample. Exposure is short for a
one-off glitch (the next reading within 2.5% deletes the pend, `:14455-14458`) but persists while a
bad source keeps proposing, up to the 5-minute TTL. Asymmetric: down-moves cap below 10000 bps by
construction, so only **upward** glitches do this.

## The failure is worse than "stops bidding"

R12 says `ammPlaceQuote` refuses each zeroed bid (`:1892`) so the failure is safe-but-silent. The
zeroed bid never reaches `ammPlaceQuote` — it is dropped first at `:2240`
(`if (px > 0 and q > 0) { List.add(bidTargets, ...) }`). `bidTargets` then goes in **empty**, and
`ammApplyQuotes`' off-ladder sweep (`:2059-2064`) **cancels every resting bid**.

So it is active withdrawal, not passive refusal: bids pulled from the book, asks parked at ≥2× mid
where nobody trades, **no AMM liquidity at all**, and nothing logged. The only surfacing is
`getPoolValue.volRegime` (`:15360`, `:15374`) — a query nobody watches during an incident. Decay is
~13 samples (~26s) to get `half` back under 1.0, ~80 samples (~160s) to normal.

Value safety holds throughout — the never-cross-mid invariant (`AMM.mo:185-186`) is untouched and no
bad fills occur. The cost is purely silent liquidity withdrawal.

## Fix

1. **Clamp the half-spread, not `volRegime`** — one line in `buildQuoteLadder` (`lib/AMM.mo:190`):
   `let half = Float.min(HALF_MAX, halfBps / 10000.0);` with `HALF_MAX ≈ 0.5`. This bounds **all
   four** contributors at once and closes the reachable `breakerBps` path. Clamping `newStdBps`
   alone leaves it open.
2. Optionally also clamp `newStdBps` at `AMM.mo:294`, so the *stable* field cannot persist an absurd
   value across an upgrade or while a pool sits disabled (`ammRequote` early-returns at `:2151`, so
   a disabled pool never decays).
3. **Add the missing diagnostic** — a fourth edge-triggered flag beside `_floorEngaged` /
   `_staleEngaged` / `_breakerWidenEngaged` (`:557-559`, pattern at `:2204-2208`, `:2251-2255`,
   `:2213-2217`): warn when `bidTargets` is empty while `ladder.bids` is not, e.g.
   `"BTC AMM bid side withdrawn (half-spread N%)"`, with the matching restore log. **This is the
   finding's real substance** — the cash-floor and inventory-floor withdrawals both log; this path
   does not.

## One-liner found alongside

`_breakerWidenEngaged` is **not** cleared on reset (`main.mo:15537-15539`) while its two siblings
are. A reset while a pend is engaged leaves the flag stale-true, and the next requote emits a
spurious `"jump resolved — AMM spread back to normal"` info log. Cosmetic; fix it here.

## Done when

- [x] `half = Float.min(0.5, halfBps / 10000.0)` in buildQuoteLadder — bounds ALL four
      contributors at once; `newStdBps` also clamped at 20,000 (2× the ladder threshold) so the
      stable field cannot persist absurdity across an upgrade or a disabled pool
- [x] A pending 2.5× proposal no longer empties the bids — `test_amm_spread_clamp.sh`
      **verified red pre-fix on the scratch venue** (baseline 5 bids → 0 on ONE unconfirmed
      reading → 5 restored on clear), **3/3 green post-fix** (bids survive at the clamp)
- [x] `_bidWithdrawnEngaged` edge-triggered warn/restore beside `_floorEngaged` — the silent
      active-withdrawal path now logs like the cash/inventory floors do
- [x] `_breakerWidenEngaged` (and the new flag) cleared on reset with the siblings — the
      stale-true spurious "jump resolved" log is gone
- [x] The test drives the BREAKER path via `setTestPendingJump` (venue-derived 2.5× pend —
      fixture lesson: the GEPTOR keeper re-stamps live refs, so synthetic marks don't stick)

---
## Status 2026-08-17 (final) — CLOSED, red/green verified live
