# W4-05 — `cancelMyOrder` never consults `stagedReleasedAs`

**Issue:** [#14](https://github.com/dfinity/public-multidex/issues/14) Finding 16 — andreij6
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW–MEDIUM / `#production` MEDIUM
**Effort:** S

## What's wrong

`cancelMyOrder` resolves an id by trying `deferredExecs`, then `deferredSwaps`, then the raw order
store — and never consults `stagedReleasedAs`. So once a staged order has been released under a new
id, cancelling it **by the id the venue returned at staging** answers "Order not found".

The user is holding the only identifier they were given, and it no longer cancels anything. For a
market maker that is live quote exposure they cannot retract by the documented handle.

Two resolver sites already exist and do this correctly (`cancelOwnSpotOrder`, `getMyOrderStatus`),
so the affordance is present and simply unused here. `getMyOrderStatus` returning `releasedAsId`
gives a manual bridge, which is why this is not higher.

## Evidence

- `src/backend/main.mo:11911` — `cancelMyOrder`
- `:11915` — `deferredExecs` lookup; `:11942` — `deferredSwaps`; `:11953` — raw `OrderBook.getOrder`
- `:9154` (`cancelOwnSpotOrder`), `:9379` (`getMyOrderStatus`) — the two existing resolver sites

## Fix

Resolve `orderId` through `stagedReleasedAs` before the final `getOrder` switch, keeping the
ownership check on the **resolved** order.

Land with [W4-07](W4-07-amm-sweep-order-identity.md), which is the other half of the same identity
problem — an order re-rested under a fresh id without updating the release link.

## Done when

- [x] Cancelling by the staging id cancels the released order
- [x] Ownership is enforced against the resolved order, not the staging id
- [x] A test stages, releases, then cancels by the original id

## Completed 2026-08-15 (W4 batch 1, landed with W4-07)

`cancelMyOrder` resolves through `stagedReleasedAs` exactly as `cancelOwnSpotOrder` and
`getMyOrderStatus` do, with ownership, pool routing, void, cancel and metadata cleanup all on the
RESOLVED id. `test_w4_correctness_batch.sh` §3: after release, both status and cancel by the
staging id resolve the released order.
