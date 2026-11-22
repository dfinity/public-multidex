# W5-23 — Delete the dead wallet-era margin gates, and enforce the invariant that made them dead

**Issue:** internal red-team round 2, finding R8 — **corrected**: seven sites, not six, and two of
the four helpers are live
**Status:** VERIFIED LIVE at `d8f4c58` (2026-08-17)
**Severity:** Informational / maintenance trap — **not** a live hole
**Effort:** S

## Confirmed

`MarginEngine.open` (`lib/MarginEngine.mo:110`) is the only writer of `marginAccounts`, with two
call sites: `createMarginPool` on `poolP` (`main.mo:10344`), and `previewOpenPosition` (`:10603`),
which is a `public query` whose state is discarded. `BorrowEngine.borrow` is the only writer of
`loans`, with three: `:10486`, `:10495` (both `poolP`), and the same query at `:10687`. The only
other touches are `Map.clear` in `resetExchange` (`:15578-15579`).

So no human principal has a margin account or carries debt, and every gate opening with
`if (not MarginEngine.hasAccount(marginAccounts, user))` returns immediately for every real caller.

**A pool principal can never be `msg.caller`.** `MarginPools.poolPrincipal` (`lib/MarginPools.mo:56`)
builds a **9-byte** principal (`0x70` ‖ be64(poolId)). Canister ids are 10 bytes ending `0x01`,
self-authenticating are 29 bytes ending `0x02`, anonymous is 1 byte `0x04` — a 9-byte blob matches no
caller class and has no signing key. And no internal path substitutes a pool for a caller:
`performLpDeposit` is only ever called with `msg.caller` (`:13123`, `:15217`), `deferredSwaps` are
staged with `owner = caller` (`:12434`), `placeLimitInner` receives only `msg.caller` at all six
sites, and `openPosition` bypasses it entirely (`parkDeferred` direct at `:10502`).

## Two corrections to the finding

**1. There is a seventh dead site**: `checkInitialMarginSwap(s.owner, …)` inside `releaseCrossSwap`
(`main.mo:3182`).

**2. `checkInitialMargin` / `checkInitialMarginSwap` are not a dead family.** Their release-time
sibling `clampToInitialMargin` (`:9416`) carries the identical `hasAccount` early-out and **is
live** — called at `:2837` with `d.owner`, which `openPosition` sets to `poolP`. That math runs in
production. Only the two placement-time entry points on `msg.caller` are dead.

Genuinely dead: `gateInitialMargin` (`:9352`), `hasOutstandingDebt` (`:9377`), and the seven call
sites.

## "Add a pool-principal test" is not possible — and is the wrong ask

None of the seven endpoints can be invoked *as* a pool. But the pool-era equivalents already exist
and are already tested: `withdrawMarginPool` carries its own inline initial-margin projection
(`:10393-10406`), pinned by `tests/test_margin_collateral_escape.sh` §1 (line 89 asserts on
`"initial-margin requirement"`). That test's header records the history — it was recreated because
"Model 2 made the ORIGINAL human-principal escapes structurally impossible."

## Risk in deleting, and the mitigation

Low. `docs/wallet-and-positions-design.md:3` records the whole-wallet model's removal with "no legacy
users; dev reset authorized", and `:22` states the Wallet is "pure custody — never collateral".
There is no plan to reinstate it.

**But** these seven sites are the only thing that would auto-re-arm if anyone later added a third
`MarginEngine.open` call site on a non-pool principal. Deleting them converts a latent-but-correct
guard into a silent hole. `main.mo:15216` already documents a near-miss of exactly that shape (a
`depositLp → await seedAmmPool` self-call would have made the canister the depositor).

## Fix

Delete the 4 helpers and 7 call sites, **and** add a one-line invariant at both `MarginEngine.open`
sites asserting the target is in `poolByPrincipal`. That converts "only pools have margin accounts"
from a documented assumption into an enforced one — which is what makes the deletion safe.

## Done when

- [ ] The 4 dead helpers and 7 dead call sites are gone
- [ ] Both `MarginEngine.open` sites assert a pool-principal target
- [ ] `clampToInitialMargin` is untouched, with a comment recording that it is the live sibling so
      the next reader does not delete it by association
- [ ] The deletion note records why a pool-principal test was not the answer, so this does not get
      re-filed
- [ ] `getMyMarginAccount`'s "compat read" status (`mixins/UserAccount.mo:295`) is confirmed or
      retired in the same pass

---
## Completion 2026-08-17 (factory task 1786989323)

- **Eight dead call sites, not seven** — the census re-run (the brief's own discipline applied to
  itself) found both `hasOutstandingDebt` guards: unstakeInsurance AND withdrawLp. All eight
  external sites deleted, each replaced with a W5-23 tombstone naming the enforcement that makes
  the absence safe; the four helpers (`gateInitialMargin`, `hasOutstandingDebt`,
  `checkInitialMargin`, `checkInitialMarginSwap`) are gone.
- **`clampToInitialMargin` untouched and marked LIVE** (release-time sibling, `d.owner` = pool
  principal), with the do-not-delete-by-association comment; its de-lever-escape comment reworded
  to stand without the deleted `gateInitialMargin`.
- **Invariant enforced**: `assertPoolMarginTarget` traps unless the open target is registered in
  `poolByPrincipal`; both `MarginEngine.open` sites (createMarginPool and the preview/respawn
  path) now REGISTER FIRST, then assert, then open. A future third open-site on a caller-shaped
  principal fails loudly instead of silently re-arming the wallet-margin holes.
- **Why no pool-principal test** (recorded here and in the code comment at the clamp block so it
  is not re-filed): none of the deleted endpoints can be invoked AS a pool — the 9-byte derived
  principal (`0x70‖be64(id)`) matches no caller class and has no signing key — and the pool-era
  equivalents are already pinned (`withdrawMarginPool`'s inline projection by
  `tests/test_margin_collateral_escape.sh` §1; the clamp by the release paths).
- **Compat read RETIRED**: `getMyMarginAccount` removed from mixins/UserAccount.mo, the inspect
  msg variant, and the published candid (gen-did.sh rerun). The frontend dropped its callers when
  model 2 landed (main.js:805 records it), and the removal rides the still-unpublished API 3.0.0
  window (nothing outward since W2-04 merged), so no version bump. Note for the next such change:
  `icp build` refuses a method removal against a stale `src/backend/backend.did` — run
  scripts/gen-did.sh first (and beware `| tail` masking that build's exit status).
- **Gates**: `test_margin_collateral_escape.sh` 11/0 on the seat venue (the in-kind withdrawLp
  case exercises exactly a deleted-guard path), `mops test` 17 files, hygiene PASS.
