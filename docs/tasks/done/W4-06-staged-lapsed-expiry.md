# W4-06 — A staged order whose expiry lapsed still executes as a taker

**Issue:** [#14](https://github.com/dfinity/public-multidex/issues/14) Finding 17 — andreij6
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` LOW–MEDIUM
**Effort:** S

## What's wrong

`releaseDeferred` reads the user's `orderExpiry` (and deletes the entry), then executes
**unconditionally**. The only consumer of that value is the stamp applied to the resting remainder
*after* the fill — so the expiry is carried forward but never **enforced** at release.

There is no `Time.now() >= e` check on any kill branch (fok / postOnly / clamp). An order the user
time-boxed can therefore fill up to the full deferred window past its own deadline.

Bounded, and worth saying so: the window is the 15 s `DEFERRED_EXPIRY` span (~13 s observed), and
the user's limit price still binds. So the **time** contract breaks while the **price** contract
holds — which is why this is LOW rather than higher. It is still a contract the venue advertises and
does not keep.

## Evidence

- `src/backend/main.mo:2557` — `userExpiry` read; `:2558` — deleted
- `:2686-2689` — unconditional execution, no expiry test
- `:2775-2776` — the only use of `userExpiry`: stamping the rested remainder, after the fill

## Fix

After reading `userExpiry`, if `?e` and `Time.now() >= e`, take the existing FOK kill path. The
reservation is already refunded by `subReserved` on that path, so no new unwind is needed.

## Done when

- [x] A staged order released after its expiry is killed, not filled
- [x] The reservation is refunded exactly once on that path
- [x] An order released *before* its expiry still fills and still stamps the remainder correctly
- [x] A test drives release at `expiry - ε` and `expiry + ε`

## Completed 2026-08-15 (W4 batch 1)

`releaseDeferred` enforces the user's expiry at release (kill mirrors the FOK path: release
rejection recorded, order.kill logged, idle pool borrow repaid, version bumped — the reservation
was already refunded above the branch). `test_w4_correctness_batch.sh` §4: a 2s GTD lapsed while
staged does not fill and its kill is visible in `getMyReleaseRejections`; `test_order_expiry`
still green for the before-expiry path.
