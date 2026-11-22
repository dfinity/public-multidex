# H-31 — Per-principal trade history costs O(matches + bounded skips); anonymous history queries return before touching the tape; position fills resolve pools via the owner index

*Source: [hardening-plan-2026-09.md](../../hardening-plan-2026-09.md) · Wave 3 (Bridge upgrade + backend #3: season boundary & state growth) · findings F48 · LOW · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

`class: hygiene`

**Mechanism.** `OrderBook.getUserTrades` (`OrderBook.mo:1026-1041`) walks the ENTIRE
`store.trades` list forward (up to `TRADES_GLOBAL_TRIM_AT = 750_000`, `main.mo:197-198`) with
two `Principal.equal` per record regardless of `limit`; the `Since`/`SinceId` siblings
(`:1045-1093`) have no scan ceiling. `getMyTradeHistory`/`getMyTradeHistorySince`
(`UserAccount.mo:236-242`) are `query (msg)` with no `requireAuth` — anonymous scans the full
tape for a 20-byte request; `getMyPositionFills` (`:11749-11757`) multiplies by owned pools
(≤ 64) inside the global-pool scan. Public trade feeds were bounded for exactly this
(`MarketData.mo:51-55`).

**Fix criteria.** A transient per-principal trade-id side index rebuilt at init (the
`poolIdsByOwner` shape — not a new field on the `OrderStore` record type), or a lazy reverse walk
with a hard scan ceiling on all three lookups; early return for the anonymous principal;
`getMyPositionFills` one bounded pass over `ownedPoolIds`.

**Verify.** On a full 600k+ tape, `getMyTradeHistory`, `getMyTradeHistorySince(0)`,
`getMyTradesSinceId(0)` for a principal with no trades complete within a fixed small budget; a
64-pool caller's `getMyPositionFills` stays well inside the query limit
(`devSweepCostProbe`).

**done 2026-09-04** (task `1788467628`, branch claude/steady-brattain-70eed1, on top of `68e6617`; code `8b91463`): backend + tests, candid ADDITIVE (one new #dev query, `devTradeHistoryCostProbe`), no stable-field change (the index is transient). **Fix**: `OrderBook.UserTradeIndex` — a transient principal → fills side index in the `poolIdsByOwner` shape (never a field on the stable `OrderStore` record), written at the `refreshRolling24h` fill-capture choke point (the same single site every trade-producing flow already calls once per batch), pruned with the global tape trim (a prefix of each per-principal list; a principal whose whole history aged out loses its key), cleared with the world wipe, rebuilt at init and `adminRebuildIndexes`. `getMyTradeHistory` / `getMyTradeHistorySince` / `getMyTradesSinceId` / `getMarketChanges`' user-trade leg / `getMyPositionFills` (one bounded pass over `ownedPoolIds`, each pool off the index) all read it at O(min(own fills, 200)); the anonymous principal returns inside the three indexed lookups (and at the `getMyTradesSinceId` / `getMyPositionFills` entries) before anything is touched. The legacy walks stay as the rebuild reference and the probe's negative control. **Measured** (`devTradeHistoryCostProbe`, tape saturated to `TRADES_GLOBAL_CAP` = 600,000 in query state, 2026-09-04): legacy full walk 5.01×10^8 instr; never-traded principal 5.7×10^3 for all three lookups, anonymous 4.0×10^3, busiest live principal 1.5×10^5, a 64-pool owner's `getMyPositionFills` 6.65×10^7 for 12,800 rows (the pre-fix shape was 64 walks ≈ 3.2×10^10 — over the 5×10^9 query limit). **Verified**: `tests/test_h31_trade_history_index.sh` RED on the pre-fix venue (probe absent, 2 of 10) → GREEN 21/0 (bounds sized from the negative control: walk/1000 for virgin + anonymous reads, walk/100 for the busiest principal, inside one walk and ≤ 2×10^8 for the 64-pool owner; index entries == tape parties at live; virgin + anonymous `(vec {})` from all four public queries); `tests/UserTradeIndex.test.mo` (indexed == legacy walks per principal / limit / timestamp cursor / id cursor, self-crossed seed fills indexed once, anonymous early return, prune-after-trim == rebuild-from-trimmed-tape, aged-out key dropped); adjacent suites green on the seat venue (`test_pending_owner_index` 8/0, `test_h30_unregistered` 48/0, `test_walk_scan_budget` 13/0, `test_volume_credit`, `test_po_sweep_fee`, `test_sweep_expired_order`, `test_unfunded_maker_notice`, `test_market_walk_records`, `test_mm_shield_kill_exits`, `test_release_priority`; `test_position_accounting` §4 VWAP-from-fills and §6 pass, its §0/I1 red is the seat vault's ICP concentration cap refusing the suite's own AMM seed — venue state, not fills); `mops test` 20/20; deploy hygiene PASS; full `run_all` not re-run for a hygiene-class change. Not covered live: a fill produced by real matching AFTER the fix landing in the index is pinned by the live entries == parties invariant over the venue's seeded fills and by the unit test, not by a fresh trade in the suite. Remote upgrade deferred to the Wave 3 operator rollout.

## Done when

- [x] Every **Fix criteria** item above is implemented; no stable-field drops, no candid change beyond what the brief flags
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (record the red run in the task log); adjacent cases enumerated per README §"Closing a task"
- [x] Full suite green on `#dev`; posture restored to `#play` before merge; deploy hygiene PASS
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the merge sha
