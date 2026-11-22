# W5-03 — The solvency rounding rule is pinned at the primitive and at none of its call sites

**Issue:** [#38](https://github.com/dfinity/public-multidex/issues/38) item 1 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14) — **shipped direction is correct**; coverage is absent
**Severity:** `#play` LOW / `#production` HIGH (of the class it fails to catch)
**Effort:** M

## What's wrong

`Fixed.mo` states the argument the whole integer-money migration rests on:

```
// THE CARDINAL RULE: every inexact division rounds AGAINST the user / toward
// protocol solvency
```

`Fixed.test.mo` pins the **primitive**. Nothing pins any **caller's use** of it. Flipping the
rounding flag at a call site leaves `mops test` at 15/15, green.

**No live defect is claimed** — at both demonstrated sites the shipped DOWN direction is the correct
one; it liquidates earlier and refuses earlier, exactly as the rule requires. The finding is that
nothing holds it there.

It reaches a decision at two independent thresholds, using the real `Fixed.div` and the real
constants:

```
liquidation      coll 11_499_999_999 / debt 10_000_000_000   T = 115_000_000
   DOWN (shipped) 114_999_999 → isLiquidatable TRUE   UP 115_000_000 → FALSE     flips
borrow admission coll 12_499_999_999 / debt 10_000_000_000   T = 125_000_000
   DOWN (shipped) 124_999_999 → REFUSED               UP 125_000_000 → ALLOWED   flips
```

The flip window is a constant 1e-8 of debt, so it is equally narrow at every position size — scale
neither helps nor hinders. **Reachability is not established**: whether a user can steer both
`collUsd` and `debtUsd` onto the window through the real deposit/borrow path is a separate question
the reporter did not run.

## Evidence

- `src/backend/lib/Fixed.mo:10-11` — the rule; `:30-39` — `mulDiv`/`div` and the `roundUp` parameter
- `src/backend/lib/BorrowEngine.mo:135` → `:142` — liquidation threshold
- `:197` → `:198` — borrow admission
- `src/backend/lib/MarginPools.mo:133`, `:139` — `liqPriceLong` / `liqPriceShort` (direction still an open question there)
- `tests/BorrowEngine.test.mo:54` — `eqN(…, 325_000_000)`, an exact pin on a fixture that **divides
  evenly**, so the flip is a no-op; `:58-59` — inequalities evaluated far from the boundary

**Why no conservation test can catch this in principle:** conservation asks whether value was
created; the cardinal rule asks *who gets the dust*. `test_property_fuzz.sh` asserts
Σ-conservation, which is invariant under a transfer of any magnitude.

## Fix

Add **boundary fixtures** — operands where `p % denom != 0` — at the four decision sites, asserting
the shipped direction:

- `BorrowEngine` liquidation threshold and borrow admission (the two above)
- `MarginPools.liqPriceLong` / `liqPriceShort` — and while there, **settle the direction argument**:
  the favourable side depends on position side, and the reporter explicitly did not make that
  argument. Decide it and encode it.

## Done when

- [ ] Flipping the rounding flag at each of the four sites turns `mops test` red
- [ ] Fixtures use non-dividing operands, so the assertion can see the flip
- [ ] The `MarginPools` direction question is answered in a comment at the site

---
## Done — 2026-08-15

Fixed.test.mo pins the primitive; these fixtures pin the DIRECTION at each
decision call site, with operands whose division is non-even so a flag flip
changes the observable verdict:

- **getHealth liquidation threshold** (BorrowEngine.mo:135): drove the REAL
  function to coll 11_499_999_999 / debt 10_000_000_000 (borrow admitted at
  a rich BTC price, then priced via null-px so only par-quote collateral
  remains). DOWN → ratio 114_999_999 → isLiquidatable TRUE. Flip to UP reads
  exactly 115_000_000 and spares it — verified red.
- **borrowCheck admission** (BorrowEngine.mo:197): projected coll
  12_499_999_999 / debt 10_000_000_000 → 124_999_999 < 1.25 → REFUSED;
  +1 dust-unit of collateral → admitted (the gate sits exactly at the
  boundary). Flip verified red.
- **liqPriceLong** (MarginPools.mo): DIRECTION DECIDED — display
  conservatism. These prices are the display surface (the decision is
  getHealth's DOWN ratio); a shown liq price must never look farther than
  reality, so LONG (mark falls toward P) now rounds UP — the one production
  code change of this task, comment at the site. Fixture pins exact
  3_333_333_334.
- **liqPriceShort**: already conservative (mark rises toward P, DOWN).
  Pinned exact 2_898_550_724.

All four deliberate flag-flips turn `mops test` red; restored tree green.
`mops check`: zero compile errors (the 6 lint errors are pre-existing
committed src/backend/oql/ rules, untouched by this work). No candid or
API change — no deploy needed; the display change rides the next backend
deploy (end-of-session regression at latest).
