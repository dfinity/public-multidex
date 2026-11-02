# Margin heat map — the exact liquidation surface

**Status: IMPLEMENTED (2026-07-26; k-anonymity removed 2026-08-01)** —
`getMarginHeatmap`, `getMarginHeatmaps`, `tests/test_margin_heatmap.sh`.

Publishes, per market, where the venue's leverage sits relative to the mark:
notional-at-risk per 1% liquidation-price band, published **exactly** (every
non-empty band verbatim, notionals rounded to $100). The original k-anonymous
design and why it was retired are recorded at the end of this document.

## Why publish this at all

Three arguments, in ascending order of force.

**1. It recruits exit liquidity for the vault.** A liquidation does not hit the
order book — `Liquidator` absorbs the seized collateral into the AMM vault at the
oracle mid ("no book trade is printed (no wick)"). Afterwards the vault carries
forced directional inventory it must unwind through skewed quotes. Traders who
can see that coming can be ready to take the other side, shortening the unwind
and reducing LP loss.

**2. LPs are underwriting this book and currently cannot see it.** The vault is
the margin system's lender *and* the senior absorber of uncovered bad debt, and
liquidation penalties drain its cash leg. Publishing aggregate leverage is
loan-book concentration disclosure to the people actually carrying the risk.

**3. The information is already public — just unevenly.** `#delta` and
`#debtDelta` on the public archive tape reconstruct every pool's exact holdings
and debt; the LTVs, `MAINTENANCE_HEALTH_RATIO` and the liquidation formulas are
public constants; the mark is a public query. So *anyone able to fold the tape
already knows every pool's exact liquidation price*. Publishing an aggregate
**destroys an asymmetry rather than creating one** — it levels sophisticated
tape-folders against ordinary users. That, and not privacy, is the case for it.

## Why it is safe here — and exactly when it would not be

Liquidations trigger on the **oracle mark** (`marginPriceLookup` reads
`refPrice`, a robust median over 8 external venues), never on a venue-traded
price. To force liquidations you must move that median — i.e. move the world's
major exchanges, not this book.

Better still, the failure mode is **fail-safe**: a single manipulated source
trips the 50bps stddev quality gate, which *freezes* the aggregate rather than
moving it, and a stale mark **skips liquidation entirely**. An attacker's best
case is a denial, not a forced liquidation.

That argument holds only while the *external* market is deep. For a thin listing
whose price genuinely is movable, the fault lines are dangerous knowledge — but
note that hiding the *map* would not hide them: the tape reconstructs them for
anyone motivated (argument 3), and the stddev freeze is the actual defence.
Leveraged positions on a movable-price asset are unsafe regardless of who can
see the fault lines; the `none` tier withholds geometry there because the mark
is meaningless, not because concealment protects anyone.

## Price-quality tier — derived, never hand-set

`heatTierFor` reads the last oracle aggregate for the base token:

| tier | condition | geometry |
|---|---|---|
| `full` | ≥6 sources and stddev ≤ 20bps | published (1% bands) |
| `coarse` | ≥3 sources | published (1% bands) |
| `none` | otherwise | *no buckets published* |

Since 2026-08-01 the tier gates nothing but **geometry availability**: a
`none`-tier mark (too few sources, or sources disagreeing) makes the
bps-from-mark axis itself meaningless, so bands are withheld while totals still
publish. `full` vs `coarse` survives as a feed-quality label for clients (the
tier is part of the stable history record and remains populated); how many
independent venues price an asset, and how tightly they agree, is computed
rather than configured, so a thin new listing labels itself with nobody
remembering to flip a switch.

Observed on the live seeded venue: BTC/ETH/SOL → `full`, **ICP → `coarse`**
(fewer venues price it).

## Disclosure construction

- **Bucket by distance to liquidation** (bps relative to mark), not absolute
  price, so the map stays meaningful as the mark moves.
- **Every non-empty 1% band publishes verbatim** — exact per-band long/short
  notional and position count, no merging, no minimum count.
- **Rounded notionals** ($100 steps) for tidiness of display, not concealment.
- Range is ±3000bps; positions outside it, or with no finite liquidation price
  (unlevered), count in totals only — clients read the beyond-window remainder
  as `totals − Σ buckets`. (The pre-2026-08-01 design instead folded far
  exposure into the last bucket, stretching its mark-side edge to the window
  boundary — which corrupted the band's geometry for anything reading edges.)
- A band sits on the side of the mark its liquidation price lies on. Which way
  a pool liquidates follows its **health slope**, not the sign of its net
  size: `MarginPools.liqPrice` solves `coll(p) = M·debt(p)` and the sign of
  `A = heldBase·ltv − M·debtBase` picks the direction — `A > 0` liquidates as
  the mark FALLS (long-like), `A < 0` as it RISES (short-like). Because
  `ltv < M`, a net-long pool carrying base debt can have `A < 0` and sit
  ABOVE the mark as a long. One deliberate exception: a position already past
  maintenance has its liquidation price on the "wrong" side of the mark, and
  stays visible there — that is a signal, not noise.

### Direction and "liquidatable" (#54.8)

`liqPrice` returns the direction WITH the price (`{ price; dir : #down | #up }`,
`#down` iff `heldLtv > maintDebtBase`), read off the same `A` the price derives
from, so no consumer re-derives it. Two surfaces used to: the Markets bar's
Long/Short Liq (`tickMarketSideAgg`) signed the distance by the side —
`if net > 0 then mark − P else P − mark` — and the Positions row's `pctToLiq`
was unsigned with the sign implied by the side pill. On the slope fixture
(10 SOL held, 9 owed, $100 cash: `A = 8.5 − 10.35 < 0`, `P = $54.05`) a
HEALTHY pool at $50 read "Long Liq −0.0%" and a liquidatable one at $60 read
"−9.9%". Now:

- `MarginPools.distBps(mark, liq)` is the one signed-distance routine: bps
  toward the crossing on the side `dir` says (`#down`: `mark − P`, `#up`:
  `P − mark`), clamped at 0 once the mark is past it. The fixture reads
  +8.1% at $50.
- "Already past" is **`getHealth.isLiquidatable`**, never `mark` vs `P`:
  rounding puts the displayed price on the wrong side of the mark by dust.
  `PositionView.isLiquidatable` and `MarketTele.{long,short}Liquidatable`
  carry the verdict; both the row and the bar print the word **liquidatable**
  instead of a distance on it. The fixture at $60 reads "liquidatable".
- The direction is published as `PositionView.liqDir` and
  `MarketTele.{long,short}NearLiqDir` (the direction of the leg that set the
  side's minimum); the frontend signs the figure by it (`−` = the mark must
  fall, `+` = rise). `pctToLiq` stays unsigned and byte-compatible.
- `liqPrice = ?0` is the "liquidatable at every price" answer (short-like with
  nothing price-independent left), not a dust artefact — the row no longer
  maps it to the "no practical liquidation" glyph.
- All additive on the candid surface; `getHealth.isLiquidatable` remains the
  liquidation decision — this is display.

## Cost / DoS

Computed on the heartbeat every 30s and cached; queries are O(1) reads. It is a
public unauthenticated surface, so it must never be computed per call. The pool
scan is bounded by `HEAT_MAX_POOLS` (5,000) and reports `truncated` when it bites.

The cache is `transient` **by design** (see `deployment-modes.md`): it recomputes
itself, so it must not occupy stable memory. A query in the window right after an
upgrade sees `computedNs = 0`.

## Verified behaviour (local, seeded, 2026-07-26 — PRE-2026-08-01 semantics)

Historical record of the k-anonymous behaviour, kept because the stable history
ring still carries columns of this shape for ~4h after the 2026-08-01 upgrade
(renderers must keep handling wide merged bands):

- k-anonymity held: with only 3 positions carrying a liquidation price, **no
  buckets were published** — the floor refusing to expose them.
- With 11 such positions, one merged bucket emitted: `[-2800, -1400) bps,
  10 positions, $11,100 long`.
- `positionsTotal` (21) ≥ Σ bucket positions (10) — the difference is
  out-of-range and unlevered positions, counted in totals only (this remains
  true under the exact semantics).

## Why the k-anonymity floor was retired (2026-08-01)

The floor was a fairness measure against liquidation hunting. Both halves of
its rationale failed on inspection:

1. **It hid nothing.** Argument 3 above was already conceded at design time:
   the public tape (`#fill`/`#delta`/`#debtDelta`, principal-attributed, with
   a shipped browser-side verifier) reconstructs every pool's exact
   liquidation price. The floor therefore only blurred the map for casual
   players while tape-folders kept the sharp version — the *opposite* of
   fairness.
2. **The threat it guarded was already neutralised.** Liquidations key on the
   oracle mark; hunting an individual means moving the median of the world's
   major exchanges, and a manipulated source freezes the mark instead
   (fail-safe). Front-running *aggregate* liquidation flow remains possible —
   and is precisely the symmetric, everyone-sees-it information a public map
   exists to provide.

Meanwhile the merge/fold machinery carried real costs: empty maps on young
venues (patched three times — sub-k coarsening, far-exposure folding,
aggregate rendering), bucket edges stretched to the window boundary that broke
any consumer reading band geometry, and telemetry stats that had to grow a
second, separately-quantized disclosure policy. One exact policy replaced all
of it; the bar's Long/Short Liq stats now share the map's 1% precision (and,
since #54.8, take their sign from the health slope and print "liquidatable"
on the health verdict — see "Direction and 'liquidatable'" above).

## LP risk panel — `getMarginRiskSummary` (implemented)

The disclosure to the people carrying the risk. Identifies nobody, so it
publishes unconditionally — including for `none`-tier markets where band detail
is withheld:

`positions`, `totalNotionalUsd`, `totalDebtUsd`, `vaultValueUsd`,
`vaultBorrowCapUsd`, `vaultUtilisationBps`, `insuranceValueUsd`,
`liquidatablePositions`, `liquidatableNotionalUsd`, `worstCaseAbsorbUsd`.

Debt and health are read once per **pool** (both are pool-wide); notional is
summed per market leg. Computed in the same heartbeat pass as the heat map,
shares `HEAT_MAX_POOLS`, reports `truncated`.

Utilisation is against the **borrow cap** (half the vault per
`VAULT_BORROW_FRACTION_CAP`), not the vault — that is the number that actually
binds.

## The heat surface — history ring + `getMarginHeatmapHistory`

The industry-standard liquidation heat map (Coinglass et al.) is a **time ×
price field**: each column is one snapshot, colour is the notional resting at
each level, and the mark trace shows price walking into — or bouncing off —
the bright zones. Venues like Coinglass *infer* those levels from open
interest; we publish the real thing, already k-merged.

- `heatHistory : Map<MarketId, List<MarginHeatmap>>` — a per-market ring of
  the very snapshots `tickHeatmaps` already computes, appended once per 30s
  tick, capped at `HEAT_HISTORY_CAP = 480` (≈ 4h). **Stable on purpose**,
  unlike the `_heatmaps` cache: history is the one thing the heartbeat cannot
  recompute, and blanking the map's past on every upgrade would erase it
  exactly when we deploy most.
- Only priced columns enter (`markPrice > 0`) — a mark-less column has no bps
  geometry and would paint "no liquidity" as a claim rather than an absence of
  data. `none`-tier columns DO enter with their empty bucket list: the mark
  trace must not gap just because disclosure is withheld.
- `getMarginHeatmapHistory(marketId, sinceNs)` returns entries with
  `computedNs > sinceNs`, oldest first — the frontend polls incrementally
  (cursor = last seen `computedNs`) instead of re-pulling 4h of columns.
- **Privacy is unchanged by retention.** Every entry is byte-identical to what
  `getMarginHeatmap` answered at that moment, and the public tape — permanent
  and principal-attributed by doctrine — already dominates anything replaying
  this ring could reveal.

## UI

- **Chart cell (Markets page)**: the "Liquidations" view of the chart/liquidations/
  hide dropdown. Canvas time × price surface: thermal ramp (dark → blue → cyan
  → green → yellow → red → white-hot, log-scaled since notionals are
  heavy-tailed), colour driven by **$ per 1% of price** so a wide k-merged band
  does not paint hotter than a tight one just for being wide; white mark trace
  with the live mark labelled on the price axis; hover tooltip gives band price
  range, distance from mark, long/short split, position count. Bands above the
  mark line are liquidations a RISING mark reaches, below them a falling one —
  shorts and longs respectively in the common case, though the side of the mark
  follows the health slope (a net-long pool carrying base debt can sit above,
  see "Direction and 'liquidatable'") — and the split-at-the-mark sweep keeps
  every bucket unambiguously one side of the mark. A young ring renders wide
  columns (min-48 grid) so the first minutes fill the plot, and says
  *"building — a column is added every 30s"*.
- **Earn → AMM Vault card**: "What this vault underwrites", directly beneath the
  LP's own position stats — the point where someone decides to deposit. Six
  tiles; only utilisation (amber >50%, red >80%) and below-maintenance are
  coloured, since those are the two an LP should react to.
- **Positions card**: the same surface at fixed height — context beside your
  own pools. `none`-tier renders the mark trace and states *"band detail
  withheld — too few independent price sources"* on the canvas.

Both queries are optional-chained with a catch, so a backend predating them
cannot break either card; without the history method the frontend degrades to
appending the latest snapshot each poll (a surface that builds only while
watching).

## Not done / open

- Position privacy proper (hiding size/liquidation price from the tape) is NOT
  addressed here and cannot be by any API change: it requires publishing
  aggregate liabilities plus a per-account cryptographic commitment (Merkle-sum
  or Pedersen) so verifiers check Σliabilities without reading leaves. PoR needs
  the *sum* public, not every row.
