# W4-25 — The arb's import budget is a tumbling window; a 2-minute burst buys a 58-minute outage

**Issue:** internal red-team round 2, finding R5(b) — **retargeted**; largely a re-report of public
issue #24 / [W4-17](done/W4-17-arb-design-cluster.md), with one residual gap and a mis-framed risk
**Status:** VERIFIED LIVE at `d8f4c58` (2026-08-17)
**Severity:** `#play` LOW–MEDIUM / `#production` N/A while gated
**Effort:** M

## Corrections to the record first

- **"Drawn from working capital the controller funds out of the treasury" is wrong.**
  `fundArbitrageur` **mints** — `Accounts.addBalance` + `appendDeposit #deposit`
  (`main.mo:5295-5297`), with no treasury debit. Value flows the other way, via `skimArbitrageur`
  (`:5344-5352`).
- **No real value is at risk.** Both `extMarketSwap` (`:5372`) and `fundArbitrageur` (`:5288`)
  hard-`#err` on `IS_PRODUCTION`. Working capital is $1,281,250 **synthetic** ICPUSD
  (`scripts/play_start.sh:316`, `:322`), not $5k.
- The arb **is** live — deployed, funded and enabled on both mainnet stacks (engine and the subnet
  serving multidex.ai). Not a dormant experiment.

## The residual gap is real

W4-17 item 2 added an unwind for a **refused** placement (`src/arb/main.mo:242-254`). The
accepted-but-unfilled path (`:239-241`) still has none: the import at `:238` commits value, the sell
at `:240` is a staged `placeLimitOrderExp` that does not rest until the next GEPTOR
(`GEPTOR_DELAY_NS = 1s`, `main.mo:2441`) *and* a fresh price postdates it (`:2999`, anti-snipe). If
the justifying bid is gone by then, the arb holds base it unwinds next tick at ~20 bps
(`ARB_EXT_HAIRCUT_BPS = 10` charged both ways, `:5416`, `:5439`). `tests/test_arbitrage.sh` covers
only happy paths A–D — no spoof, no no-counterparty case.

## But the bleed is not the risk

The tumbling hourly import budget (`main.mo:5395-5406`) caps the haircut bleed at
$512.5k × 20 bps ≈ **$1,025/hour** — ~52 days of continuous attack to drain $1.28M.

The actual problem: 4 markets × $5k/tick at a 5s tick trips that budget in **~128 seconds**, and the
window is **tumbling, not rolling**, so the import leg goes dark for the remaining ~58 minutes.
During the dark window manipulation stops being taxed — which is the entire stated purpose of the
canister (`docs/amm-vault-design.md:168-177`, "manipulation becomes a taxed activity"). That is a
cheap, repeatable **DoS on the venue's price-convergence mechanism**, and it is what should drive
the fix order. W4-17 item 5 fixed the *flatten* darkening (exports are now exempt) but left the
tumbling window and the import darkening.

R5 also missed why the attack is cheap: a *funded* spoof bid loses the attacker ~60 bps when the
arb's sell fills it. It only works because unfunded depth is free and resting cancels carry no
commitment window — see [W4-24](W4-24-phantom-orderbook-depth.md), which is the upstream fix.

## Fix, by leverage

1. **[W4-24] first** — size the import against *funded* depth (`walkFillable` / `fokFillableDepth`)
   rather than `getOrderBookDepth` (`src/arb/main.mo:233`). Kills the spoof at the source.
2. **Rolling hourly window** (`main.mo:5395`) — per-minute ring buckets. This is W4-17 item 5's
   stated fix direction, not implemented; it is what turns a 2-minute burst into a 58-minute outage.
3. **`ORDER_TTL_SEC` 8 → ≤4** (`src/arb/main.mo:61`) so the sell is always dead before the next
   flatten. One line; removes the self-export overlap that makes the unfilled-hedge case the normal
   case rather than the exceptional one.
4. **Same-tick unwind on the success path** (`:239-241`): re-read depth after the import; if the
   justifying bid is gone, export back immediately rather than resting. Completes W4-17 item 2.

## Done when

- [x] The import budget is a rolling window; a burst cannot dark the import leg for the remainder of
      an hour
- [x] The arb sizes against takeable depth
- [x] TTL is shorter than the tick, so the arb never exports the backing of its own live order
- [x] `tests/test_arbitrage.sh` gains a spoof case: post bid → tick → cancel bid → assert the arb
      unwinds in-tick and the budget is not consumed
- [x] The re-check-before-`#production` box in W4-17 stays open, as that task intends

---
## Completion 2026-08-17 (factory task 1786989321)

Item 1 was verified already landed by W4-24 (sizing via `getTakeableDepth`, raw depth kept as the
deviation signal) and not re-done. The rest, and what the brief's own test forced:

- **Rolling window** — 60 per-minute STABLE ring buckets (`_arbMinuteBuckets` /
  `_arbBucketHeadMin`, main.mo) with `_arbHourUsd` kept as the live rolling sum and
  `_arbHourStartNs` fossil-parked (EOP refuses stable drops). A `-1` head sentinel folds legacy
  tumbling spend into the first touched bucket, so an upgrade mid-window carries spent budget
  forward instead of granting a fresh one (the W4-17 stability doctrine, preserved through the
  refit). `getArbStats.hourUsedUsd` is a query-side decayed view (`arbHourLiveUsd`) — stats no
  longer depend on an update having advanced the window.
- **TTL 8→4s** (< 5s tick) — the self-export overlap is gone; hygiene §6h′ pins TTL < tick plus
  the ring/refund/re-read/backoff sentinels (all five red-verified on the pre-fix tree).
- **Refund + backoff (the forced design)** — the spoof test demands "budget not consumed", but a
  naive refund converts the DoS into an uncapped bleed (~$29k/hr at tick rate: every refunded
  cycle costs the ~20bps round-trip haircut). So the refund is bounded three ways: a single-slot
  per-token import memo (decremented, 60s TTL), voided by ANY settled arb fill
  (`bumpPartyVolume`) so only ZERO-fill round-trips refund; and a per-market geometric rich-side
  backoff in the arb (10s·2ⁿ, cap ≈21min) whose streak clears only when a hedge MOSTLY fills
  (>50% — so resets are PAID by the spoofer at ~60bps, while dust-fill resets stay closed).
  Sustained-spoof bleed lands ≈$100/hr across 4 markets — below even the old tumbling cap's
  $1,025/hr — with spoof-free markets, the cheap side, and the flatten leg untouched.
- **In-tick unwind** — post-import re-read of takeable depth; if the justifying depth vanished,
  export straight back in the same tick. The cancel-after-rest variant is caught one tick later
  by the flatten-side verdict (remnant >50% of the import ⇒ bump; ≤50% ⇒ clear).
- **Test choreography** — the in-tick cancel interleave cannot be timed from a shell, so an
  IS_DEV latch (`setTestArbTakeableSpoof`: armed → flipped ACTIVE by the import update itself
  (a query cannot consume its own one-shot) → read by `getTakeableDepth` → cleared by the
  unwinding export) simulates exactly that interleave with every other mechanism real.
  `test_arbitrage.sh` §E: E1 live refund (charge → cancel → TTL death → flatten round-trip →
  hourUsed $4,000→$0), E2 hold (a resting rich bid draws no import through a held tick and
  still RESTS after it — separating the hold from the pre-fix accident where the TTL-8 zombie
  hedge CONSUMED the bid), E3 latch-driven in-tick unwind (path, refund, takeable-probe for a
  live leaked hedge, latch self-clears). RED on the pre-fix build: 6 reds on exactly the
  discriminating assertions (refund kept charge at $4k/$8k, no backoff, hedge placed) with A–D
  green; GREEN: 20/20 + hygiene PASS + `mops test` 17 files.

Deferred / filed onward: the UPGRADE path for the stable adds could not be exercised locally —
plain `icp deploy` traps IC0503 on seat venues even for identical wasm (W4-24's fixture mystery,
reproduced; hypothesis = the W2-04 one-shot `Migration.run` re-applying — filed as factory task
1786991552); reinstalls used throughout (play_start pattern). `mops generate candid arb` rewrites
mops.toml and strips its comment blocks (restored from the committed copy; footgun filed as
1786991553). The W4-17 re-check-before-`#production` box remains open, untouched, as intended.
