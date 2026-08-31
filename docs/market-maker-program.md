# Market Maker Program — API, Tooling, Docs & Incentives

*Status: PROPOSAL (2026-07-09). Companion to docs/progressive-incentives-design.md (implemented) —
this document treats external market-making entities as a product with three surfaces (API,
templates, docs) and designs the incentive program on top of the machinery that already exists.*

---

## 0. Starting position: more is built than anyone has been told

Before adding anything, note what an external MM already gets today — none of it is documented
where a bot author would find it:

| Already built | Where |
|---|---|
| Maker volume counts **2×** toward the earned level score W | `MAKER_W_MULT = 2`, 15–30d rolling window |
| Maker fee **0.0 bps at L4** (5.0 at L0); taker 10.0 → 6.0 | `MAKER/TAKER_TENTH_BPS`, quote-leg both sides |
| **Volume-scaled level bars with a 1% floor** — on today's young venue, L4 needs only ~$100k of W | `scaleBps`, `REF_EXCHANGE_VOL` |
| **L4 quote-freshness shield** — resting quotes non-takeable while a staged reprice is in flight; whole book protected during oracle stalls | `isMMShieldedFresh/Stale`, 30s TTL |
| **Release priority** — L3/L4 staged orders execute before lower tiers within each sealed batch | `sortDeferredByPriority` |
| **Load-shed immunity** — under load, L0 (then L1–L2) ingress is refused at the gate; L3/L4 keep trading | `_shedFloor` + inspect |
| Full self-introspection: level, fees, thresholds, uptime, shed floor, MM quality constants | `getAccessPolicy` (one query) |
| Version-cursor **delta polling** (book deltas + own fills + balances in one query) | `getMarketChanges` |
| Order expiry (GTT), price band, self-trade = cancel-resting-maker (never silent) | `placeLimitOrderExp`, `getMyAdjustments` |
| Permanent badges incl. maker-specific (Maker Clout, Two-Sided, Iron Quoter) | badge sweep |

**The first deliverable is therefore marketing the existing machinery** — a docs page that says
"quote both sides and your fees go to zero, your orders jump the queue, and you can't be sniped."

---

## 1. API sufficiency — verdict and additions

**Verdict:** sufficient for a *casual* maker (the bash sims prove it), insufficient for a *serious*
one. The polling/data side is genuinely strong (`getMarketChanges` is a proper cursor API); the
order-management side is missing the safety and batch primitives every real MM program treats as
table stakes.

### P0 — safety & table stakes (small, ship first) — **SHIPPED 2026-07-10 (v0.71)**

*All five calls live: `cancelAllAfter` (dead-man, 5s–1d, re-armed by every spot trading call,
heartbeat-serviced, `getMyCancelAllAfter` introspection), `cancelAllMyOrders(?market)` → count
(wallet-scoped; pool orders excluded by design), `replaceMyOrder` (cancel always stands; GTC
same market/side), `placeLimitOrdersBulk` (≤32, per-item results, one sealed batch, per-item
`postOnly`), `placeLimitOrderPO` (maker-or-kill at release via the funded-depth walk — a stale
unfunded overlap doesn't kill). Post-only rides a `deferredPostOnly` side map (EOP-safe, like
`deferredFok`); the dead-man table is a new stable map. Docs: in-app `#docs/market-making`
(new Part VI "Automate & integrate"). Verified live on the local sim: bulk→rest, PO rest + PO
crossing-kill with recorded rejection, atomic replace, cancel-all count, dead-man fired after
12 s silence.*

1. **Dead-man switch** — `cancelAllAfter(expiresInSec : ?Nat)`: per-owner timer serviced by the
   maintenance heartbeat; re-armed on every trading call; null disarms. A crashed bot today leaves
   quotes resting for up to the 30-day TTL. This is Deribit's cancel-on-disconnect for a polling
   venue, and the single most important missing call.
2. **`cancelAllMyOrders(marketId : ?MarketId) : async Nat`** — the internal `cancelAllUserOrders`
   already exists (liquidation path); expose a caller-scoped version (null = all markets).
3. **`replaceMyOrder(cancelId, price, quantity)`** — cancel + place in ONE message (both are
   synchronous state mutations, so it is atomic — no torn quote between two ingress calls, which
   today costs a consensus round of stale-quote exposure).
4. **Bulk placement** — `placeLimitOrdersBulk([{marketId; side; price; quantity; expiresInSec}])`
   with per-item results. Semantics to fix at design time: per-item (not all-or-nothing), bounded
   by `STAGED_CAP_PER_OWNER = 32` and the 2 MB ingress cap, one seal (all land in the same batch).
   Consider `mmReplaceQuotes(market, [...levels])` — atomic full-ladder replace per market.
5. **Post-only** — `placeLimitOrderPO(...)`: cancel at release if it would cross (the AMM's ladder
   insertion is already post-only internally). At maker fee 0, an MM must never accidentally pay
   taker.

### P1 — accounting & introspection (small–medium) — **SHIPPED 2026-07-10 (v0.72)**

*Items 6–11 live, with two deliberate deviations. (6) `Types.Trade` was NOT changed — per-trade
fees ride a bounded `tradeFees` side map (id → buyer/seller fee) fed by a new REQUIRED
`onTradeFees` ProtectionCtx callback at both engine fill sites; `getMyTradesSinceId(sinceId,
limit)` joins them (`feeQuote` null outside the retention window — the archive stays the exact
deep history). No reinstall/migration needed. (7) `getMyOrderStatus` — implementing it surfaced
that a staged id is REBORN as a fresh order id when the remainder rests; a bounded
`stagedReleasedAs` link map now bridges it (`releasedAsId` in the result), and
`replaceMyOrder`/`cancelOwnSpotOrder` resolve placement ids through the same link. (8)
`getMarketSpecs` (constants incl. band factor, caps, seal delay, stp policy, `apiVersion`
"1.1.0"). (9) `getReleaseInfo(market)` (armed GEPTOR deadline + delay + oracle age). (10)
`getAccessPolicy` gained counts/caps, `myUptimeQualified`, `myDeadmanArmed`, `stpPolicy`,
`apiVersion` — but NOT `myQuoteSampleNow`: the pass/fail sampler is slated for replacement
(guardrail 2), so cementing it in the API would be wrong; ships with the proximity-weighted
rework. (11) `whyAmIRefused()` (registered / rank vs shed floor / admittedNow / caps — a query,
so it bypasses the very gate it explains). Verified live: penny-exact taker fee on a real fill
(10 bps, maker=AMM=0), staged→resting→closed phases across the id rebirth, replace-by-placement-id.*

*Additive bump to `apiVersion` "1.2.0": `getBadgeCatalog()` (every badge id → name, glyph,
machine-readable earning criteria incl. the lifetime bars) and `getUserBadges(principal)` (any
account's earned badges with names + award timestamps) — see
docs/progressive-incentives-design.md §6.*

*MAJOR bump to `apiVersion` "2.0.0" (July 2026): the public trade feeds `getRecentTrades` /
`getAllTrades` / `getTradesSince` return de-identified `PublicTrade` (no maker/taker principals) —
a breaking parse for bots reading those three. Own-fill flows (`getMyTradesSinceId`,
`getMarketChanges`) are unchanged; attributed history stays on the archive tape.
`getUserBadges(principal)` is now self-or-controller (privacy batch). Additive in the same bump:
`getMarginHeatmap(s)`, `getMarginHeatmapHistory`, `getMarginRiskSummary` — see
docs/margin-heatmap-design.md.*

6. **Fills with fees, by cursor** — add `feeQuoteBuyer/feeQuoteSeller` to `Types.Trade` (stable-type
   change → reinstall/migration) and `getMyTradesSinceId(sinceTradeId, limit)`. Today PnL
   reconciliation to the penny requires the archive fold.
7. **`getMyOrderStatus(orderId)`** → `{order; phase : #staged | #resting | #closed}` — one call
   instead of scanning three queries.
8. **`getMarketSpecs()`** — machine-readable: decimals (8), tick (1 unit), `MIN_ORDER_ICPUSD`,
   price-band factor, exposure factors, caps. Constants exist; bots currently learn them from
   rejections.
9. **Release-timing introspection** — `geptorDeadlineNs`, `refPriceUpdatedNs`, `geptorDelayNs` on
   `getMarketStatus` (or a `getReleaseInfo`), so a bot can phase-align its quoting with the seal.
10. **`getAccessPolicy` additions** — `myOpenOrderCount`/`openOrderCap`, `stpPolicy`
    ("cancel-resting-maker"), `myQuoteSampleNow : [(market, Bool)]` (am I passing the uptime check
    *right now*), `myShieldStamps`, and a machine-readable `apiVersion`.
11. **Structured rejection diagnostics** — inspect refusals are opaque replica errors; a
    `whyAmIRefused()`-style query (admission rank vs shed floor, staged count vs cap, registered?)
    turns support tickets into self-service.

### P2 — differentiators (medium)

12. **Scoped session keys** — a trade-only sub-principal (no withdrawals) bound to the funded
    account, building on the OQL token machinery. A leaked quoting box today loses the whole
    balance; for professional desks this is worth more than a rebate.
13. **Canister-bot push** — registered MM *canisters* get one-way `onFill/onLevelChange`
    notification calls (0-attach, bounded-wait). Off-chain bots poll; on-chain bots get push.
14. **Certified book head** — a `(marketVersion, bookHash)` in `certified_data` so a paranoid bot
    can detect boundary-node tampering (all trading reads are uncertified queries today — document
    this loudly either way).

### Corrections the audit surfaced

- `placeProtectedLimitOrder`'s window is a validated **no-op** (sealed matching superseded it) —
  deprecate in docs, keep for compat.
- The public tape for markout analysis: `getPublicTradesSince` exists and aggressor side is
  derivable (zero-orderId side), but document it as *the* toxicity data source; the archive is the
  deep-history path.

---

## 2. Template scripts

Three tiers, in order of delivery:

1. **`templates/mm-quickstart.sh`** (day one) — a cleaned fork of `scripts/sim_trading.sh`'s maker
   loop: one market, cancel-and-replace around `getAmmPool.refPrice`, parameterized spread/size,
   env-driven canister id + identity, the `--query` gotcha handled, dead-man switch armed once it
   exists. Two-sided quotes in ~100 lines of bash; time-to-first-quote under 30 minutes.
2. **`templates/mm-reference-ts/`** (the real one) — TypeScript on `@dfinity/agent`: raw Ed25519
   keypair identity (bots can't use Internet Identity — WebAuthn is browser-only), the funded-
   registration bootstrap, a `getMarketChanges` cursor loop, a quote engine (skew by inventory,
   requote on refPrice move), fill reconciliation via staged-id tracking (placement `#ok` ≠ fill —
   release can still kill an order), and PnL accounting. This doubles as the living documentation
   of every API semantic above.
3. **`templates/mm-canister-mo/`** (phase 2, the flagship) — a Motoko reference maker that runs
   *on-chain*: inter-canister calls skip the ingress gate and every poll round-trip; paired with
   cycles sponsorship (below) the pitch becomes *"your bot runs inside the exchange's trust domain
   and the venue pays its gas"* — a capability no CEX and no EVM DEX can offer.

Plus a **sandbox kit**: `scripts/play_start.sh` already builds a private funded venue in one
command — package it (README + pinned toolchain) as the rehearsal environment, and note
`setTestScorecard` lets an author test L4 behavior (shield, priority) locally.

**Publish `backend.did`** (currently only a build artifact in `.mops/.build/`) as a versioned file
with an additive-only stability policy — the `outAmount` rename (bfaabb9) already demonstrated
what field churn does to clients.

---

## 3. Docs additions (in-app Docs tab, `src/frontend/src/docs.js`)

New Part — **"Automate & integrate"** (4 pages):

1. **Run a market-making bot** — quickstart: keypair identity → Deposit (registration happens on
   first bridge claim; $100k play allowance) → first two-sided quote via the bash template →
   reading your fee level. 30-minute promise.
2. **Bot API reference** — the polling model (no websockets; `getMarketStatus` nonce →
   `getMarketChanges` cursors), *staged-execution semantics* (every order stages; ~0.5–2s to
   release; `placeMarketOrder` returns before fills; reconcile via `getMyStagedOrderIds` +
   `getMyReleaseRejections`), money units (Nat @1e8), caps and bands, self-trade policy, failure
   modes, certified-vs-uncertified reads, the icp-CLI arity quirk, the `--query` gotcha.
3. **The maker economics** — worked P&L at each level; the W formula and today's *actual* (volume-
   scaled) bars; the shield explained honestly (including what takers give up); adverse selection
   under sealed 1–2s batching; the AMM as the incumbent competitor, with its live effective spread
   published as *the rate card to beat*.
4. **Market Maker Program terms** — measurement spec (auto-anchored to `getAccessPolicy` constants
   so prose can never drift from code), reward budget rule, manipulation/disqualification policy,
   play-to-production conversion promises, change/termination rights. This page does not exist in
   any form today and is load-bearing for every incentive below.

---

## 4. Incentives — the menu

Organizing principle: **on a play venue the money is fake, so the real currencies are status,
capital access, and option value on the production venue.** Every reward should be measurable from
the tamper-evident ledger — auditability is this venue's brand.

### Tier A — already built; just announce (free)
The Section-0 table, presented as a program: *fees→0, queue priority, snipe shield, shed immunity,
2× maker credit, permanent badges.* Plus the honest recruiting poster: publish the house AMM's
capital-normalized P&L (+40% in 48h) as a **beat-the-house benchmark** rather than hiding it.

### Tier B — trivial/small builds, high leverage (play-phase)
- **Earned deposit-allowance ladder** — sustained L2/L3/L4 uptime unlocks $250k/$500k/$1M play
  allowance (the $100k cap is the binding constraint on quoting several markets; machinery is
  `getPlayDepositAllowance` + the scorecard). *Trivial build, immediately felt.*
- **Maker League** — a second leaderboard ranked by maker-quality composite (time-weighted
  depth-at-touch × spread proximity, uptime, filled maker volume, markout quality) instead of
  P&L-vs-HODL. Punters win the profit board; craftsmen need their own. Seasonal, sealed into the
  archive at season end (provably permanent titles).
- **Market plaques** — each market header credits the trailing-7d time-at-best leader: *"kept
  tight by 〈identicon〉 X"*. Territory beats rank as a status hook; also routes makers to under-
  served books via **orphan-market bounties** (flame icon + League multiplier on wide markets).
- **Uptime streaks** (7/30/90-day quoting streaks as badges) and **certified README badges** — an
  `http_request` SVG/JSON endpoint serving level/uptime/rank under `certified_data`: every badge
  embedded in a GitHub README is a self-updating advert in exactly the repos where the next bot
  author browses.
- **Provisional-tier trial pass** — controller-granted, time-boxed L3 seed for a recruited desk
  (the prod-safe cousin of `setTestScorecard`), erasing the cold-start fee disadvantage vs
  incumbents.

### Tier C — direct economics (small–medium; the core program)
- **Per-fill taker-fee kickback** — divert X% (≤50%) of each taker fee to the resting maker at
  settlement, through the same `quoteFeeFor`/treasury path. **Invariant that makes it safe: a
  round trip between two colluding keys must stay strictly net-negative after all rewards** (taker
  pays 6.0 tenth-bps minimum; any maker credit must stay below that). Effective negative maker fee
  without a mintable exploit.
- **Quoting SLA stipends** — extend the uptime sampler to score *proximity-weighted depth-seconds*
  (min(depth, cap) × closeness-to-touch, two-sided, random sample offsets) and pay a capped
  per-market stipend pro-rata per epoch. Pays for *standing* liquidity the way fills pay for
  *consumed* liquidity. This scoring upgrade also fixes the audit's abuse finding that today's
  ±1%/±$500 pass-fail sampler lets a wide-quoter farm L4 on a sleepy market.
- **Epoch fee-share pool** — a fixed slice (~20–25%) of epoch taker fees redistributed by filled
  maker volume, each payout journaled as ledger events with a **per-maker machine-readable epoch
  statement** that reconciles against the public fold. "Auditable rebates" is a differentiator no
  CEX can copy.
- **Markout makeup** — using the fact that fills and oracle prices share one event stream, refund
  fees on a maker's provably toxic fills (30s markout beyond a threshold), capped per epoch at
  fees-paid. Insures the tail that makes small MMs quote wide.
- **Maker loss-rebate month** — first calendar month net-negative? Fees refunded (production:
  cash; play: League points). A free option that removes the "pay to learn your venue's toxicity"
  onboarding tax.

### Tier D — ownership & alignment (on-chain-unique)
- **AMM vault seats** — League qualifiers earn *capped* deposit headroom in the house AMM vault
  (deposit machinery exists): "if you can't out-quote the house, buy into it — but you must earn
  the seat by quoting." Converts the +40% house edge from deterrent into prize.
- **Insurance-share grants with uptime vesting** — epochs of sustained quote-uptime vest stakeable
  insurance shares; missed epochs pause vesting (**vesting handcuffs**: rewards create tenure, not
  tourists). Aligns makers with venue solvency — they profit by quoting *through* volatility.
- **Treasury revenue-share points** — a fourth claim-ledger class (after debt/LP/insurance) minted
  per epoch by maker score; redeemable at production for fee credits (or better, counsel
  permitting). Makers become evangelists for total venue volume, not just their own spread.
- **Retro-airdrop scoring, published now** — announce that any future token/governance allocation
  will be a *versioned deterministic function folded over the tamper-evident archive* (maker-
  weighted W per epoch, uptime, markout quality). The Uniswap/dYdX playbook, minus the "trust our
  private database" — anyone can compute their own score today.
- **Maker performance oracle** — certified `makerScore(principal, market)` query other IC
  canisters can consume; every integrating protocol makes an UPLANDS maker score more valuable.
  Same machinery yields the **certified maker résumé** (portable, provable track record — the
  scarcest asset an anonymous bot author has).

### Tier E — capital & operations
- **Maker-rate margin** — L3/L4 borrow inventory at preferential APR / bumped LTV through the
  existing pool machinery (prime-broker economics).
- **House backstop bid** — L3+ makers may unwind bounded inventory into the AMM at oracle ±k bps
  even in an empty book: converts the small-MM nightmare (stuck inventory) into a fixed, priceable
  cost. Guard with TWAP delay + per-epoch caps (this aims adverse selection at the house).
- **House capital lease** (large, later) — the vault lends inventory into a jointly-funded
  segregated pool; the maker quotes with house capital and splits the P&L, sized by certified
  maker score.
- **Cycles sponsorship** — the fuel loop (`convertTreasuryToFuel`/`tickAutoFuel`) gains a third
  route: epoch `deposit_cycles` into registered maker *canisters*, capped at measured call costs,
  gated on uptime. "We pay your infra" — the on-chain colocation giveaway.
- **AMM step-back** — in markets with a qualified DMM meeting an SLA, the house ladder widens by
  X bps, deliberately transferring edge from the house to the human maker. The house *makes room*.

### Tier F — structure & competition (production-facing)
- **DMM slot auctions with slashable bonds** — 1–3 scarce named slots per market per epoch;
  bidders commit an SLA (max spread, min size, uptime) and post insurance-fund shares as a
  performance bond; the sampler verifies compliance on-chain; meeting it pays the stipend,
  missing it slashes. Self-enforcing contracts — no trust required in either direction.
- **Guaranteed participation** — registered DMMs receive up to K% (10–20%) of fills at their price
  level before strict price-time allocation (NYSE parity, but provable). Disclose prominently.
- **Play-to-production ladder** — the competition *is* the RFP: Maker League season winners
  receive the production DMM slots and genesis maker badges. People compete hardest when the
  prize is a business.
- **Quote-off duels, ELO, Maker Cam curation, referral overrides** — the social layer; note the
  audit correction that the ledger already publishes raw principals in real time, so "delayed
  attribution" is UI curation of an already-public tape, not a privacy feature.

---

## 5. Guardrails (from the adversarial pass — bake in before any money moves)

1. **The wash invariant** (publish it): any two-key round trip must be net-negative after all
   rewards. Kickbacks < taker fee; pool payouts capped at a multiple of fees the account itself
   paid; sybils are blunted by the $100k-per-principal allowance but never assume identity cost.
2. **Fix wide-quote farming before paying for uptime**: replace the binary ±1%/$500 sample with
   proximity-weighted, randomly-offset, fill-through-obligated scoring.
3. **Shield transparency**: publish shield-denial stats and TTL per market (else "snipe-proof
   quoting" reads as house-sanctioned fading to takers); verify staged-then-cancelled orders don't
   stamp freshness (free shield refresh) — charge or exclude them.
4. **Budget equation, live**: maker pool ≤ X% of epoch taker fees + fixed allowance, shown as a
   counting-up Season Pool ticker on the treasury tile. Unverifiable "capped pools" would betray
   the venue's whole pitch.
5. **The taker side exists too**: makers stay for flow. Ship price-improvement receipts ("you
   saved $X vs AMM-only execution" — computable exactly, since the AMM is the on-chain
   counterfactual) and taker fee holidays in DMM markets, or the program pays people to quote at
   each other.
6. **Program terms page** before any reward with future value (play→production conversion promises
   are liabilities; write them down).
7. **Ops surface**: off-chain status page (the canister can't report its own freeze), upgrade
   policy for in-flight orders, sandbox parity statement, API stability contract with
   `apiVersion`.

---

## 6. Suggested phasing

| Phase | Scope |
|---|---|
| **0 — this week** | Docs Part "Automate & integrate" (4 pages) · publish `backend.did` · bash quickstart template · P0 APIs (dead-man, cancel-all, replace, bulk, post-only) · `getMarketSpecs` · allowance ladder · announce Tier A |
| **1 — season one** | Maker League tab + plaques + streaks + orphan bounties · proximity-weighted sampler (abuse fix) · ONE core economic lever (recommend: per-fill kickback, capped, with the wash invariant published) · TS reference bot · sandbox kit · epoch statements |
| **2 — production prep** | DMM slots + bonds · vault seats + insurance vesting · revenue-share points ledger · canister SDK + cycles sponsorship + push callbacks · scoped session keys · markout systems (makeup, toxicity dashboard) · certified résumé/oracle |

The single highest-leverage sequence: **docs + dead-man + cancel-all + the bash template** — an
outsider can then run a safe two-sided bot in an afternoon against machinery that already rewards
them (2× W, fees→0, shield). Everything else compounds from there.

## Volume-credit consolidation (W4-18, 2026-08-15)

Volume credit is written by exactly one place — the credit loop inside
`updateStatsAfterTrades` — so EVERY settlement path (direct fills, AMM-sweep
fills, both cross-swap legs, pending-finalize) credits both parties, and a
new settlement path cannot be added without crediting (it has to book stats
to exist). Historical injection books stats via `updateStatsCore` and
credits nobody: backdrop trades must scale no one's level.

Backfill decision, recorded: **start clean from this deploy.** Historical
under-credit is not reconstructed — the affected quantities are play-money
scorecard rows, the level scale recalibrates automatically as newly-counted
volume flows, and a mid-season retroactive rewrite would move everyone's
level without an action of theirs.
