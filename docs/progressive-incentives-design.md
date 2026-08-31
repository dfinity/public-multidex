# Progressive Incentives — earned fee levels, access ranks & badges

Status: IMPLEMENTED (branch `feat/progressive-incentives`).
Supersedes the grant-based `#depositor/#trader/#marketMaker` tiers of
`access-prioritization-design.md` §L2-tiering (the L1/L2 *machinery* — inspect
shedding, release ordering, freshness shield — is unchanged; only how a
principal *qualifies* changed). User-facing explainer: the `docs` canister
(`src/docs/site/index.html`), linked from Account → Status.

## 1. Principle

A DEX has no operator, so nothing can be "granted to enrolled partners."
Every privilege is computed on-chain from behaviour, and splits into:

- **Privileges (decay)** — fee level L0–L4 and the access rank derived from it.
  Keyed to a rolling ~30-day contribution window; lapse when contribution does.
- **Recognition (permanent)** — badges on lifetime milestones. Never revoked,
  gate nothing.

Every level change and badge award is event-logged (`access`/`level`,
`access`/`badge`). `getAccessPolicy` publishes the full schedule + the
caller's scorecard, so anyone can audit anyone's standing.

## 2. Scorecard

Per scorecard key (margin pools resolve to their **owner** via
`scorecardKeyOf`):

- `makerVol / takerVol` — rolling two-bucket window (15d half-window ≈ 30d).
  Maker attribution reads the trade record: the engine stamps the RESTING
  order's id on its side and 0 on the aggressing side; both ids non-zero ⇒
  both sides count as makers. W4-22 made that rule REAL on the AMM-sweep
  path: the sweep re-homes a resting order as the aggressor (for the
  equal-or-better price) and the engine now pre-reserves + stamps its id —
  before that fix the engine could not produce both-ids on a sweep, so a
  swept maker's volume was mis-binned as taker (and their post-only
  "never pays taker" promise broke). Swept makers also keep the maker FEE
  rate (`aggressorIsMaker` in `ProtectionCtx`).
  AMM/insurance/treasury legs are excluded (`isInternalPrincipal`).
- `W = 2·maker + taker` — the level input (`MAKER_W_MULT = 2`).
- `lifetimeVol / lifetimeMakerVol` — monotonic, badge inputs.
- Quote uptime — every owner with resting orders is sampled per tick
  (~60s, `HB_TIER_NS`): PASS = two-sided book on any market within ±1% of ref
  (`MM_MAX_SPREAD_BPS`) at ≥ $500/side (`MM_MIN_DEPTH_USD`). EWMA-ish counters
  (halve at 60); qualified = ≥50% over ≥20 samples. Previously-sampled owners
  with no resting orders take FAIL samples so a lapsed quoter decays rather
  than freezing at his last rate; fully-decayed entries are pruned.
- `exVolCur/exVolPrev` — exchange-wide window volume (one bump per trade with
  any external party) → threshold scaling input.

## 3. Fee ladder (tenth-bps; quote leg, both sides, → treasury)

| Level | W bar (full scale) | Maker | Taker | Rank |
|---|---|---|---|---|
| L0 | join | 5.0 | 10.0 | 0 |
| L1 | $20k | 4.5 | 9.0 | 1 |
| L2 | $200k | 3.5 | 8.0 | 1 |
| L3 | $2M | 2.5 | 7.0 | 2 |
| L4 | $10M **and** uptime qualified | 0.0 | 6.0 | 2 + shield |

- `quoteFeeFor` = ladder lookup by the party's earned level; internal
  principals exempt; floor rounding (toward solvency) unchanged.
- **Reservation stays at the L0 ceiling** (`TAKER_FEE_BPS = 10`,
  `MAKER_FEE_BPS = 5` in parkDeferred/swap sizing/quoteNeed): reserve
  worst-case, settle at the earned rate — discounts can't under-reserve.
- Maker floor is **0, never negative** (no rebates): with a rebate a wash pair
  could be paid by the venue; at 0 the cheapest self-volume still pays the
  full taker leg. STP already cancels literal self-crosses.

## 4. Dynamic thresholds

`scale = clamp(exchangeWindowVol / REF_EXCHANGE_VOL, SCALE_MIN_BPS, 100%)`
with `REF = $100M`/window and a 1% floor; `effective bar_i = full_i × scale`
(ceil). A young venue's bars shrink (at floor: $200/$2k/$20k/$100k) so early
participants can earn real levels; bars grow back with venue volume. Faking
volume only **raises** the scale — it cannot lower the attacker's own bars.
Levels recompute per tick over every key with window signal or a held level
(the scale moves even when a holder's own volume doesn't).

## 5. Access wiring (unchanged machinery, new source)

- `levelRank`: L0→0, L1–L2→1, L3–L4→2; internal principals rank 3.
- inspect shed: `levelRank(levelOfKey(caller)) >= _shedFloor`.
- Release ordering: `sortDeferredByPriority` keyed on `tierRankOf` (now
  level-derived).
- Freshness shield (`isMMShieldedFresh/Stale`, stamp at `placeLimitInner`):
  **level == 4** only — the tier whose qualification is sustained quoting.

## 6. Badges (ids stable; names in `badgeName`, docs site, frontend)

1 DeFi 2.0 User (first deposit — inline in `creditAndRegister`, plus a tick
sweep over `registeredUsers` for dev registration paths) · 2 First Fill ·
3 MULTI/DEX Player $10k · 4 Maker Clout $100k maker · 5 Two-Sided (first
passed sample) · 6 Market Mover $500k · 7 Iron Quoter (uptime qualified) ·
8 Whale $10M · 9 Market Pillar $10M maker. Volume badges check lifetime
counters per tick; stored as `badges : Map<key, Map<badgeId, awardedNs>>`.

Public API (apiVersion 1.2.0): `getBadgeCatalog()` publishes the full table —
id, name, glyph, prose, and machine-readable criteria (`BadgeCriteria`
variant carrying the lifetime bars / uptime gate), so frontends and bots
don't hardcode a copy; `getUserBadges(principal)` resolves ANY account's
earned badges to `{id; name; awardedNs}` (recognition is public: awards are
event-logged and the leaderboard already shows `badgeCount`). The caller's
own bare `(id, awardedNs)` pairs stay on `getAccessPolicy().myBadges`.

Drift is gated, not reviewed by eye: the pre-push `scripts/lint-ratchet.sh`
runs `scripts/check-badge-sync.mjs` (backend catalog vs the frontend's
`BADGE_META` shelf table vs the docs page — ids, icons, names, prose, and
thresholds-quoted-in-prose), plus a candid gate (committed
`candid/backend.did` must match the source; with `didc` installed, must be a
subtype of origin/main's — the additive-only promise enforced mechanically).

## 7. Test hook

`setTestScorecard(user, makerVol, takerVol, samples, passes)` — controller-only
**and disabled in production**. There is deliberately NO production grant.
Tests: `test_access_levels.sh` (progression, fees, scaling floor, badges,
attribution, staged cap), `test_tier_shed.sh` (L1 shed on level ranks),
`test_release_priority.sh` (L2 ordering + shield at earned L4).

## 8. UX

Account → **Status**: level badge, my maker/taker bps (+ next level's rates),
weighted-volume progress bar against the *current effective* bar, scorecard
row, uptime row, priority/staged/min-order rows, scale note, shed banner, and
the badge shelf (earned lit + per-badge progress meters + "next badge" strip).
Deep explainer lives on the separate **docs canister** (`icp.yaml: docs`,
static site, no build step) — linked via `PUBLIC_CANISTER_ID:docs`.

## 9. Open follow-ups

- Fee-level history / "rate at fill time" surfaced per trade record.
- Governance path for retuning `LEVEL_W_FULL`, `REF_EXCHANGE_VOL`, fee rows
  (NNS-controlled on mainnet).
- ~~L3 survival items (compute allocation, treasury auto-top-up)~~ CLOSED
  2026-07-04: the treasury auto-top-up loop is live (`tickAutoFuel` +
  Stage 2 via the wired ICP-ledger/CMC fuel route — see the fuel block in
  main.mo and `tests/test_fuel_topup.sh`); compute allocation is a deploy
  setting, now cached from canister_status and surfaced on Stats → Canister,
  with the checklist step in docs/pre-mainnet-checklist.md.

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
