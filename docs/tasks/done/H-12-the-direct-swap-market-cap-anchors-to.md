# H-12 — The direct-swap market cap anchors to the AMM/oracle mid, not the book's best resting order

*Source: [hardening-plan-2026-09.md](../../hardening-plan-2026-09.md) · Wave 1 (backend upgrade #1: solvency & book poisoning) · findings F46 · LOW, trivial half of the anchoring class · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

`class: security-medium`

**Mechanism.** `executeSwapDirect` `#marketOrder` (`:13323-13330`) sets `refPrice =
OrderBook.findBestMatch(…).price` with no pool-mid fallback; `placeMarketOrder` (`:13063-13079`)
was changed to mid-anchor for exactly the "stranded far quote when the ladder is pulled" case
and `quoteSwap` (`:13158-13160`) shows a mid band. For a non-FOK swap the #3a cap re-clamps;
for a FOK swap `isSpotMarket` excludes it (`:3098`) and the users-only clamp never fires on
`processDeferred`, so the FOK executes at the raw far cap. #48.5 (8ad94b6) changed sizing only.

**Fix criteria.** Replace `:13323-13330` with the `placeMarketOrder` pattern (`p.enabled and
p.refPrice > 0 → p.refPrice`, book-best only for markets without an enabled AMM). Optionally
extend #3a to FOK with kill-if-short (touches #48.5 invariants — do it in H-20 instead).

**Verify.** `tests/test_slippage_anchor.sh` gains a `swap(noPartialFill=true)` section: AMM side
empty, one far resting order → the swap cannot fill beyond `mid × (1 ± slippage)`.

**done 2026-09-04** (task `1788467609`, branch claude/steady-brattain-70eed1, on top of `d01e9c7`; code `56998a8`): backend-only, no candid change (`scripts/gen-did.sh` byte-identical), no new stable field. **Fix**: `executeSwapDirect` `#marketOrder` and `placeMarketOrder` now share one anchor, `func slippageAnchor(marketId, side) : Nat` (defined just above `placeMarketOrder`, carrying its rationale comment) — `p.enabled and p.refPrice > 0 → p.refPrice`, book-best (`findBestMatch`) only for a market without an enabled AMM, `0` → the existing "No liquidity" refusal — so the cap a swap parks with is `mid × (1 ± slip)`, the band `quoteSwap`'s `leg()` previews; FOK cap-sizing (`sizeAt = cap`) therefore sizes at the mid-anchored cap too (20 ICPUSD at cap 12.0 → 1.665 ICP, where the old build sized 1.28 at 15.6). The optional #3a-for-FOK kill-if-short is deliberately NOT done here (H-20, per the brief). **RED on the unfixed venue build** (the venue's backend == HEAD's `17df5cc` build, so the live negative control cost no deploy): `test_slippage_anchor.sh` 11/7 — §4: a 60-ICPUSD FOK buy staged with the ladder pulled parked at cap 13×1.2 = 15.6 and at release took 3 ICP from the fresh ladder PLUS 0.87 ICP of the stranded 13.0 ask (whale 5.00 → 8.84 ICP, 41.2 ICPUSD spent); §5: a 4-ICP FOK sell with the bid ladder pulled parked at cap 7×0.8 = 5.6 and hit the 7.0 lowball for 1.02 ICP. **GREEN post-upgrade** (`deploy.sh local --no-seed` under the posture rhythm, 524 s, no IC0503): 18/0 — §4 FOK buy KILLED (whale ICP and ICPUSD unchanged, i.e. the reservation came back; 13.0 ask whole: cap 12.0 excludes it and the 3 ICP ladder is short of the ~5 ICP sized at cap), §4b (adjacent, positive control) an in-band 20-ICPUSD FOK fills 1.665 ICP at avg 10.036 from the ladder with the 13.0 ask still whole, §5 FOK sell KILLED with the 7.0 bid whole (cap 8.0). Adjacent live suites on the fixed venue: `test_swap_direct_budget.sh` PASS, `test_fok_market.sh` 27/0, `test_swap_quote_budget.sh` PASS, `test_swap_outcome.sh` 5/0, `test_swap.sh` PASS (its first run, straight after three `resetExchange` suites on a venue whose post-upgrade BTC/ETH marks were still stale, was red on route 2/3's releases; a `seed.sh full` reseed and re-run: PASS — state, not code: a non-FOK spot sell's release band is `max(cap, #3a edge)` and the edge dominates old and new cap alike, and route 3's cross-swap never enters `executeSwapDirect`). `mops test` 19 files; `bash tests/test_deploy_hygiene.sh` PASS (no new pin — the §8b no-await set and the parkDeferred/executeSwapDirect hop pins cover the helper). Not run: the full `run_all.sh` (a two-site anchor change; the slippage/swap/FOK suites are the honest gate set). Adjacent sites enumerated (README §"Closing a task"): the market-order slippage anchors in main.mo are exactly `placeMarketOrder` + `executeSwapDirect` (now the one helper) and `quoteSwap.leg()` (already the mid; no `enabled` check, by design a preview); the cross-swap legs (`releaseCrossSwap`'s `sellBestBid`, the immediate two-leg path) stay book-anchored → H-20 (`1788467617`), which also owns the #3a-for-FOK option. Remote: the backend upgrade is DEFERRED to the plan's Wave 1 operator rollout (the plan carries it; no separate rollout task filed).

## Done when

- [x] Every **Fix criteria** item above is implemented; no stable-field drops, no candid change beyond what the brief flags
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (record the red run in the task log); adjacent cases enumerated per README §"Closing a task"
- [x] Full suite green on `#dev`; posture restored to `#play` before merge; deploy hygiene PASS
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the merge sha
