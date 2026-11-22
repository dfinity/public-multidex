# W5-17 — The display-integrity suite catches three properties by their spelling

**Issue:** [#36](https://github.com/dfinity/public-multidex/issues/36) item 8 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` MEDIUM (of the class it fails to catch)
**Effort:** M

## What the reporter concedes first, and it is fair

`tests/frontend_display_integrity.test.mjs` is new in 1.60, is exactly 461 lines, is dedicated rather
than bolted on, and its **section A is genuinely behavioural** — it imports the real `money.js` and
exercises `normMoney`/`toE8` across eleven assertions including an exact round trip. **The
money-scaling class from #20 is pinned by execution**, as claimed.

## What's wrong

Six of the file's 49 assertions, in two other sections, match a **regex against comment-stripped
source** instead of executing anything. Three behaviours the file names in its own check strings each
survive removal while it stays green at 49/49:

1. **Inverting the poll guard** at `main.js:2607` — the needle admits any prefix before
   `_pollInFlight`, while its sibling assertion rejects the identical inversion. One of two siblings
   is written correctly.
2. **Reintroducing the #20 downscale** as a line wrap, a `* 1e-8`, or a one-line module-scope helper.
3. **Deleting the trade-id membership check** at `main.js:2682`.

The reporter's own proposed fix for (2) closes four of five variants and **still leaves the helper
form green** — and they label it partial in its own heading rather than presenting it as complete.
That honesty is worth preserving in whatever we implement.

## Evidence

- `tests/frontend_display_integrity.test.mjs:403` — the permissive poll-guard needle; `:442` — the sibling that is correct
- Section A — genuinely behavioural, keep as the model
- Composes with [W5-11](W5-11-shared-js-stripper.md), which can hand these needles a corrupted window

## Fix

Convert the three source-text pins to **behavioural** assertions wherever the code can be imported —
section A proves it is possible in this codebase. Where a behaviour genuinely cannot be executed
without a browser, assert on parsed structure rather than raw text, and make the failure message
state what could not be observed.

Fix the permissive needle to match its correct sibling regardless.

## Done when

- [ ] Each of the three demonstrated removals turns the suite red
- [ ] The poll-guard inversion is caught by both sibling assertions
- [ ] Any remaining text-matching assertion says in its message that it is a text pin, not a behaviour pin

---
## Done — 2026-08-15

The six spelling-pins became structure pins with statement-scoped analysis
(main.js cannot execute outside a browser — every non-behavioural assertion
now says "[structure pin]" and why):

- **Downscale (the #20 class):** sites are read as STATEMENTS (split on `;`,
  whitespace-collapsed) so a line-wrap cannot split the field from its
  divide; the pattern covers both spellings (`/1e8` family AND `* 1e-8` /
  `* 0.00000001`); and a module-helper census (`e8HelperNames`) flags any
  one-line downscale helper APPLIED to a pinned field's statement or inside
  renderStatsIssues — the fifth variant the reporter's own partial fix left
  green. A whole-file ban was measured and rejected: 19 legitimate raw-unit
  divides exist (deposit formatter, quotes, avails), so scope stays with the
  normalised fields.
- **Poll guard:** the needle now requires the UNNEGATED flag in the
  early-return and separately asserts the negated form absent (the real
  guard is compound — `if (!src || _pollInFlight) return` — so anchoring
  like the chart sibling was impossible; absence-of-inversion is the
  property).
- **Trade-id merge:** two structural halves — the seen-set BUILD keyed by
  id, and the `seen.has(...) continue` SKIP — nested-paren tolerant.

Mutation battery, all red on the pre-restore tree and green restored (53
assertions, was 49): five downscale reintroductions (bare divide, line-wrap,
`* 1e-8`, helper form, retyped literal), both guard inversions (each reds
its own sibling), and the membership-check deletion.
