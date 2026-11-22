# W4-12 — The reset clears `playReservedUnits` while the Bridge's claimables survive

**Issue:** [#25](https://github.com/dfinity/public-multidex/issues/25) item 2 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14) — maintainer confirmed open
**Severity:** `#play` HIGH / `#production` N/A (reset refuses on `#production`; class CRITICAL if it ever does not)
**Effort:** L

## What's wrong

A season reset is a DEX-side message. It clears `playReservedUnits` — the reservation ledger
recording units the DEX already valued and admitted — while the **Bridge, a separate canister**,
keeps every unclaimed `confirmed − claimed` balance. The Bridge has **no season or reset concept at
all**, so the two halves of the pair cannot agree by construction.

A claim that was already paid for under the old reservation is thrown back into the mark-valued
excess gate and re-charged against the allowance. `creditedSeq` is never cleared either, so the
post-reset claim of a surviving slice hits the excess path with `reserved == 0` and takes a **second
allowance debit**.

The core defect is a **double debit** of the allowance; permanent stranding is the near-cap subcase,
not the general outcome. Composed with the (now-fixed) allowance-bucket bug it could refuse outright.

This extends #5 item 1, which established that the two ledgers diverge after a Bridge
`--mode reinstall` — an out-of-band operation. This is the same divergence reached through the
**supported** reset path.

## Evidence

- `src/backend/main.mo:14721` — `performWorldWipe(true)` clears `playReservedUnits`
- `:5530-5551` — `creditAndRegister`'s excess gate re-values and re-debits when `reserved == 0`
- `:5471`, `:5484`, `:5557` — the only `creditedSeq` sites; never cleared
- `src/bridge/main.mo:103-104` — `Ledger { confirmed; pending; claimed }`; `:116` — `admittedUnits`
- `:287`, `:318` — `claimable = confirmed − claimed`
- `:423-428` — `postupgrade` clears only `claiming`/`admitting`, comment explicitly **keeps** `admittedUnits`

## Fix

A boundary that clears reservations must either be a **two-phase operation the Bridge participates
in**, or must **not clear reservations at all**. The reporter's two-phase framing is the right shape.

Design questions to settle before coding:

- does the Bridge get a season concept, or does the DEX stop clearing reservations?
- what happens to a claim in flight across the boundary?
- what clears `creditedSeq`, and is clearing it safe against replay?

## Done when

- [x] A pre-reset admitted-but-unclaimed deposit is claimable after the reset without a second debit
- [x] The DEX and Bridge cannot disagree about admitted units across a boundary
- [x] The reset path is documented in `bridge-and-cks-design.md` including the in-flight case
- [x] A test drives admit → reset → claim and asserts a single allowance debit

## Completed 2026-08-15 (W4 batch 2) — design decision recorded

Two-phase boundary: `resetSeason` calls the Bridge's new `adminSeasonWipe` (wired-DEX or
controller; REFUSES mid-claim/admission, aborting the reset) before wiping its own half. The DEX
clears `playReservedUnits`, `creditedSeq` and — found live by this batch's test — **`playAdmitSeq`**,
whose survival inverted the bug: post-reset deposits up to the old high-water replayed as
already-reserved and were admitted with ZERO allowance charge. Design question settled as "the
Bridge gets a season hook" (documented in `bridge-and-cks-design.md` with the in-flight case).
`test_w4_batch2.sh` §4: admit → reset → Bridge half wiped with the DEX half, and a fresh deposit
charges exactly once. Done-when #1's "claimable survives" reading was settled the other way — the
PAIR agreeing (both wiped) is the invariant; survival semantics would need reservations to outlive
a season wipe that clears every other balance.
