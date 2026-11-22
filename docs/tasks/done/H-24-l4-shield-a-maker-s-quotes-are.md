# H-24 — L4 shield: a maker's quotes are non-takeable only while a genuine repricing intent is in flight; shielded depth earns neither display weight nor uptime; the sweep honours the shield for non-AMM makers and rates the aggressor maker only against the AMM

*Source: [hardening-plan-2026-09.md](../../hardening-plan-2026-09.md) · Wave 2 (backend upgrade #2: matching fairness & release pacing) · findings F2 + F25 · HIGH + LOW · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

`class: security-high` · `stable: +map` if a cumulative shield budget is chosen — `after: D1`, `after: H-14`

**Mechanism.** `placeLimitInner` stamps `mmQuoteStamp`/`mmOwnerStamp` on ANY staged L4 limit
(`:10426-10429`) — no size, price or relevance condition; `isMMShieldedFresh` (`:1173-1178`,
`stamp > refNs`) and `isMMShieldedStale` (`:1180-1185`, bare `MM_STAMP_TTL_NS = 30 s` at `:911`)
gate every release ctx (`:3329`, `:3396-3398`); `clearMmShield` (`:1161`) fires on kills and
cancels only — a landed intent keeps its shield by design (`:2996-2998`; `test_mm_shield_kill_exits.sh`
§E is a *positive* control for landing). A $10 dust limit far from mid always lands, so one
staging per <30 s renews the owner shield forever and one per ~1 s (refPriceUpdatedNs is the
sample time, W3-06) keeps `stamp > refNs` at every pass. `getTakeableDepth` (`:2936-2943`) passes
`null` excl and `sampleUptime` counts shielded quotes, so the phantom book also sustains L4.
`docs/market-maker-program.md:300-302` already lists "staged-then-cancelled orders stamp
freshness (free shield refresh) — charge or exclude them" as unshipped. F25: `sweepCtx`
(`:2444-2471`) sets `isNonTakeable = false` (W4-22 DECISION, `:2455-2460`) and `aggressorIsMaker
= true` (`:2468`) for a *full taker walk* at the swept order's limit (`:2482-2486`), so a
user-vs-user sweep fill settles maker/maker (no taker leg, 2× maker volume both sides —
contradicting the wash guardrail at `MatchingEngine.mo:876-879` and
`docs/market-maker-program.md` guardrail #1) and can take a shielded L4 quote before its staged
reprice lands; W4-22's record (`done/W4-22…md:91-93`) knew the walk "can also hit other users"
and guarded only the resting leg's rate.

**Fix criteria (per D1).** (1) The stamp is written only for an intent that could reprice the
shielded book (notional/price-proximity commensurate with the owner's resting depth on that
market) and lapses when the intent lands, **or** total shielded time per owner/market is bounded
by a cumulative budget per window (new stable map). (2) `getTakeableDepth` threads
`isMMShieldedFresh` into `excl`; `sampleUptime` skips shielded quotes (with H-14). (3) The sweep
walk honours the shield for non-AMM makers (`isNonTakeable = not AMM(o) and isMMShieldedFresh(…)`)
— preserving W4-22's price-improvement rationale for the AMM leg — and the aggressor is
fee-rated maker only when the counterparty is the AMM (ctx predicate replacing the Bool at ctx
field 52; five construction sites `:2444, :3315, :3381, :3522, :10253`); a user-vs-user sweep
fill carries a taker leg with the swept order as taker.

**Verify.** A bot staging dust limits at any cadence cannot keep `isMMShieldedFresh`/`Stale` true
across more than one release pass beyond each intent's landing; a fully shielded two-sided book
reports zero takeable depth and fails the uptime sample; a crossed user-vs-user book re-homed by
the sweep produces no trade with maker roles on both sides and never fills a shielded L4 quote
(`test_mm_shield_kill_exits.sh` §E re-decided per D1; `test_po_sweep_fee.sh`,
`test_volume_credit.sh`, `test_release_priority` green).

## Done when

- [x] Every **Fix criteria** item above is implemented; no stable-field drops, no candid change beyond what the brief flags (no stable-layout change at all — D1 chose (a); candid unchanged)
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (record the red run in the task log); adjacent cases enumerated per README §"Closing a task" (above)
- [x] Full suite green on `#dev` (see the archive note for the run); posture restored to `#play` before merge; deploy hygiene PASS
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the code sha (the merge sha is minted by the merge itself)

**done 2026-09-05** (task 1788467621, branch claude/seat-1, on top of main `534fded`, code commit `100c687`): D1's operator
answer — option **(a)** + the W4-22 amendment — implemented as written; where the brief's Fix criteria offered (a) *or* (b)
the operator answer decided (a), so no cumulative budget map and no stable-layout change at all (the two stamp maps are
unchanged; `MM_SHIELD_MIN_NOTIONAL_BPS` / `MM_SHIELD_PROX_BPS` are transient constants). Per criterion:

1. **Commensurate intent, lapses on landing** — `placeLimitInner` stamps only when `isRepricingIntent(caller, market,
   price, qty)`: the staged limit's notional is ≥ 20% of the owner's RESTING notional on that market (the OrderBook's
   O(log n) `userMarketBuyValue` / `userMarketSellQty` running totals — Σ open-bid value plus Σ open-ask base valued at
   the mark; no book walk, so no hot-path scan to cost) AND its price is within 200 bps of the mark; an unpriced market
   or an empty resting book earns nothing. `landMmShield(owner, market, d.ts)` runs right after the engine call in
   `releaseDeferred`: it clears a stamp written at or before the landing intent's staging time and KEEPS a newer one
   (a later in-flight repricing intent is still in flight). Kills and cancels keep the unconditional clear. Both go
   through one delete primitive, `clearMmShieldUpTo` — hygiene's "mmQuoteStamp cleared in 1 place" pin still holds.
   The `:2996-2998` landing-window comment is rewritten; `test_mm_shield_kill_exits.sh` §E re-decided (landing lapses,
   RED → GREEN), §F added as the in-flight positive control, §A's killer intent re-priced inside the proximity band.
2. **Shielded depth earns neither display weight nor uptime** — `getTakeableDepth` now threads `isMMShieldedFresh`
   (release reference = `releaseRefs` dispatch, the same predicate `processDeferred`'s ctx applies) and `isExpired` into
   `walkFillable`'s `excl` (whose `taker` became `?Principal`: null = caller-agnostic, no self-trade exclusion; the FOK
   and cross-swap gates pass `?owner`). `sampleUptime` credits nothing on a market where the owner's quotes are shielded
   at sample time (with H-14's funding budgets intact).
3. **The sweep honours the shield for non-AMM makers; the aggressor is maker only vs the AMM** —
   `MatchingEngine.ProtectionCtx.aggressorIsMaker : Bool` → `aggressorRole : { #taker; #swept : { makerVs :
   Principal -> Bool } }` (the field-52 Bool replaced by the ctx predicate the brief asked for, carried inside a variant
   so id pre-reservation and the H-10 unfunded doctrine stay whole-walk properties while the fee role and the trade-id
   stamp are decided PER SLICE by the counterparty). `sweepCtx`: `isNonTakeable = not AMM(o) and isMMShieldedFresh(o,
   sweepRef, now)`, `aggressorRole = #swept({ makerVs = isAMM })`; the other four sites, `buildProtectionCtx` and the
   engine's `unprotected` pass `#taker`. A user-vs-user sweep fill now carries id 0 on the swept side → taker fee, taker
   volume; the swept-vs-AMM leg is unchanged (`test_po_sweep_fee`, `test_volume_credit` §2/§3 stay green).

**Verify (RED on the pre-fix build deployed to the seat venue, GREEN after):** `tests/test_mm_shield_intent.sh`
RED 10/16 (§1 dust and §2 far-from-mid intents shielded, §4 landing kept the shield, §6 shielded depth counted 0.4 not
0.2, §7 shielded book sampled 83% not 80%) → GREEN 16/16; `tests/test_sweep_shield_roles.sh` RED 6/11 (§1 the sweep took
the shielded L4 ask at 50050 instead of the AMM's 50100; §2 the user-vs-user fill was maker-rated 5 bps, id-stamped,
binned maker volume) → GREEN 11/11 (whale pays 10 bps taker, `buyOrderId = 0`, taker volume; MM maker at 0 bps);
`test_mm_shield_kill_exits.sh` §E RED → GREEN, 11/11; `MatchingEngine.test.mo` H-24 roles block (two slices — vs the
"AMM" id-stamped + 5 bps, vs a user id-0 + 10 bps; the user maker still nets maker) in `mops test` 21/21. Ground filters
on the reseeded #dev venue: `shield/mm_/sweep` 8/8, `maker/volume_credit/release_priority/uptime` 4/4,
`fok/takeable/walk` 4/4, `cross_swap/swap_direct/arb_take` 5/5; `test_deploy_hygiene` PASS; candid unchanged (no
ratchet run needed); plain `deploy.sh local` upgrade kept venue state ×2. Full `run_all`: see the completion note in
`tasks/archive/1788467621.md` (run once after this note was written).

**Adjacent cases enumerated (README §"Closing a task"):** stamp writers — `placeLimitInner` is the ONLY writer
(`grep 'Map.add(mmQuoteStamp'` = 1); market orders, PO and cross-swaps never stamped and still don't. Clear sites —
`clearMmShield` ×12 (cancel paths ×5, kill exits ×6, the H-05 hold arm) unconditional, `landMmShield` ×1 conditional; the users-only
expiry pass's FOK kill and `processDeferredExpiry`'s landing both reach `releaseDeferred`, so landing on the stale path
lapses too. Readers — `isMMShieldedFresh` in `processDeferred`, `sweepCtx`, `getTakeableDepth`, `sampleUptime`;
`isMMShieldedStale` in `usersOnlyCtx` — all five keep the L4 gate. `aggressorRole` construction sites: five in main.mo +
`unprotected` + three test ctxs (compile-enforced). `walkFillable` callers: FOK gate (`?d.owner`), `fokCrossGate`
(`?s.owner`), `getTakeableDepth` (null), PO probe / `quoteSwap` (excl null, unchanged). Boundaries: notional exactly 20%
passes (`≥`), proximity exactly 200 bps passes (`≤`, round-up division against the maker); 0 resting → false; mark 0 →
false. Deliberately NOT changed: the swept order's OWN shield never blocks its re-homing against the AMM (W4-22's
price-improvement rationale, kept by D1); `isMMShieldedStale` still owner-level on the stall path (D1 did not amend it).
**Remote rollout DEFERRED** to the operator's Wave 2 deploy sitting (`1788469062`) — law 8.
