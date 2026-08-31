# Vendored: OQL — Object Query Layer for Motoko (`mo:oql`)

This directory is a **vendored copy** of DFINITY's OQL library — a Motoko
object-query layer that lets a canister expose a queryable, navigable view over
data it already keeps in memory (schema discovery, filtered/sorted/aggregated
queries, edge joins, and per-caller row-level authorization).

- **Upstream:** https://github.com/caffeinelabs/oql-prototype
- **Vendored from:** upstream `main` @ `1981d6a` (2026-07-26)
- **Copyright:** © DFINITY Foundation
- **License:** Apache-2.0 (as declared in the upstream `mops.toml`) — see
  [LICENSE](LICENSE) in this directory. The rest of this repository is MIT;
  this directory is the exception.

It is vendored (rather than a package dependency) because the upstream is not
on the mops registry. The `.mo` sources here are **byte-identical to upstream**
— local integration (entity declarations, auth levels, the `Expose` include)
lives in `src/backend/main.mo`, not in patches to this directory.

## Re-vendoring procedure

1. Clone upstream and copy `src/*.mo` over this directory (expect a 1:1 file
   set; do not keep local edits here).
2. Watch the auth surface: entity authorization is **per-entity `TableAuth`**
   resolved per caller; the `Expose` mixin config accepts only `{ entities }`.
   Passing stale extra config fields still compiles — Motoko's structural
   subtyping silently ignores them — so verify the per-entity `.auth(...)` /
   `.public_()` / `.ownedBy(...)` declarations in `main.mo` still express the
   intended policy after every upgrade.
3. If upstream removes or reshapes any **stable** state that an older vendored
   mixin declared, the next canister upgrade needs a one-shot inline migration
   (see the `oqlMintedTokens` drop in this repo's history).
4. Run `bash scripts/lint-ratchet.sh` (this directory is excluded from lintoko
   as third-party code) and `mops test`, then upgrade a local canister and
   smoke `schema()` / `execute()` / `archiveExecute()` before shipping.

## Latent-defect watch (W6-08 — read before enabling the planner)

Five latent defects are known. Four sit on the served-entity /
secondary-index / aggregate-join planner paths (issues #21 part two and #39 —
the #39 one misdirects an authorisation check via a `__N` column-name
collision). None of those four can fire today: `withServed`'s only call site
is `IndexedMap.mo`, which nothing outside `oql/` uses, so
`aggPlan`/`planServed`/`planJoin` are dead and every live query is a full
scan (the unreachability chain is commented at `Entity.withServed` and above
`aggPlan`). **Any change that adopts served entities or secondary indexes
must fix all four first** — see
`docs/tasks/done/W6-08-latent-oql-watch-item.md` for the item list and
provenance.

The fifth (filed 2026-08-10 into the #21 thread) is in `Registry.build`
(`Registry.mo:22-26`): it inserts decls with `Map.add`, which silently
OVERWRITES on a duplicate key — so two entities declared with the same name
collapse to whichever comes last, `.auth(...)` policy included. A later,
laxer decl (say `.public_()`) would silently replace an owner-scoped one
with no diagnostic anywhere. Unlike the four above it is reachable today
(`build` runs on the live decl arrays at every init/upgrade); it cannot fire
only because the current arrays happen to have unique names. Do NOT fix it
with a trap in `build`: `build` runs in the `transient` initializer, which
executes during upgrade — a trapping duplicate check would make the release
carrying the duplicate unshippable (the upgrade itself fails). The guard is
test-time instead: `tests/OqlRegistry.test.mo` pins the silent-last-wins
behaviour (and that `build` does not trap), and
`tests/test_deploy_hygiene.sh` §7g asserts the real decl arrays in `main.mo`
carry no duplicate entity names.
