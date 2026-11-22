# W6-08 — Latent OQL defects: a watch item, not work

**Issues:** [#21](https://github.com/dfinity/public-multidex/issues/21) part two — andreij6 ·
[#39](https://github.com/dfinity/public-multidex/issues/39) correction to #21 — OhShii Labs
**Status:** LATENT — not reachable in the deployed canister
**Severity:** none today
**Effort:** none now; **blocks** any change that adopts served entities or secondary indexes

## Why this is a watch item

Five latent defects are known in the vendored OQL engine. **None fires in the deployed canister.**
Four activate only if the served-entity or secondary-index path is adopted; the fifth (below,
added 2026-08-20) is reachable today but needs a duplicate entity name that the current decl
arrays do not contain.

The reason they cannot fire is worth writing down, because it is not obvious from reading
`Executor.mo` and a reader grepping for `served =` will not reproduce it:

> The only way to declare a served index is `Entity.withServed` (`oql/Entity.mo:291`). It has exactly
> **two** occurrences in the tree — its definition and one call site inside `oql/IndexedMap.mo:173` —
> and `IndexedMap` has no occurrence outside the `oql/` tree. So `aggPlan`, `planServed` and
> `planJoin` are unreachable, and **every live query is a full scan.**

## The four

- **Three from #21 part two** — latent defects in the vendored engine, filed as a note on a future
  change rather than as live findings.
- **One from #39** — a synthesised `__N` column name can **collide with a declared one**, after which
  the owner check authorises on the wrong cell. Filed by OhShii as a correction *into the #21 thread*
  rather than as a separate issue, deliberately, so it stays with the other three.

That last one is the sharpest: a column-name collision that misdirects an **authorisation** check is
exactly the kind of thing that turns from latent to critical the moment the feature is enabled.

## The fifth (added 2026-08-20 — filed 2026-08-10 into the #21 thread)

`Registry.build` (`src/backend/oql/Registry.mo:22-26`) inserts decls with `Map.add`, which
silently **overwrites** on a duplicate key: two entities declared with the same name collapse to
whichever comes last, `.auth(...)` policy included — a later `.public_()` decl would silently
replace an owner-scoped one, with no diagnostic. Unlike the four planner defects it is reachable
today (`build` runs on the live decl arrays at every init and upgrade); it cannot fire only
because the current arrays have unique names.

**The reporter's caveat stands and shapes the fix:** the check must NOT be a trap in `build` —
`build` runs in the `transient` initializer, which executes during upgrade, so a trapping
duplicate check turns the release carrying the duplicate into an unshippable one (the upgrade
itself fails). The guard is test-time instead:

- `tests/OqlRegistry.test.mo` (mops test) pins the silent-last-wins behaviour on the auth policy
  and pins that `build` does **not** trap on duplicates (if someone "fixes" this with a trap, the
  test goes red and points back here).
- `tests/test_deploy_hygiene.sh` §7g statically asserts the real decl arrays in `main.mo`
  (`archiveRegistry`, `oqlEntities`) carry no duplicate entity names — the defect is caught at
  test time, not upgrade time.

## What to do

**Nothing now.** Two things instead:

1. **Record the unreachability in the code** — a comment at `Entity.withServed` and in `Executor.mo`
   stating the chain above, so a future reader knows why the planner paths are dead and what enabling
   them would switch on.
2. **Gate the future change on this file.** Any PR that adopts served entities, secondary indexes, or
   the aggregate/join planner must fix all four first. Reference this task from the OQL design notes
   so it is found at the moment it matters.

## Done when

- [ ] The unreachability chain is a comment in the OQL source, not just in an issue thread
- [ ] A note in the OQL design doc points at #21 part two and the #39 correction
- [ ] Re-read when — and only when — the served/secondary-index path is proposed

---
## Done — 2026-08-15 (the two recordable halves; the re-read trigger stands)

- The unreachability chain is now IN THE SOURCE: a doc comment at
  `Entity.withServed` (the only gate into the planner) and a DEAD-IN-THIS-TREE
  banner above `Executor.aggPlan` — both naming the four defects, the #39
  authorisation-misdirect specifically, and pointing here.
- `src/backend/oql/README.md` (the OQL design notes' home) gains a
  "Latent-defect watch" section gating any served/secondary-index adoption on
  fixing all four first.
- Box 3 is a standing trigger by design ("re-read when — and only when — the
  served path is proposed"); it stays with the file.
