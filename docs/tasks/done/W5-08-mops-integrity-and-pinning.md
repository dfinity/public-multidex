# W5-08 — The integrity claim the de-vendoring rests on is never checked

**Issue:** [#40](https://github.com/dfinity/public-multidex/issues/40) item 1 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` MEDIUM
**Effort:** M

## What's wrong

1.60 de-vendored the entire Motoko dependency tree — 286 tracked files removed, 256 of them `.mo` —
and justified it in `.gitignore` on the grounds that the lockfile *"carries a SHA-256 per file, so
integrity is verified rather than vendored."*

**The artefact delivers that.** The reporter checked before checking the claim: 175 of 175 hashes
match, coverage is exact in both directions, the dependency closure is complete, and
`package-lock.json` is 83 of 83 `sha512`. The lockfile is correct.

**The verification never happens.** Every `mops` command the repository actually runs — `mops sources`,
`mops test`, `mops toolchain bin`, and `mops build` via the recipe — resolves with lockfile integrity
checking disabled, which makes the integrity routine a no-op on every build path here. The commands
that *do* verify are executed by nothing: not by `lint-ratchet.sh`, not by `icp.yaml`, not by any test.

So the tree that left the repository is **pinned by version and checked by nobody**. The lockfile is
the version authority for every build path and the integrity authority for none of them.

## Unpinned tools

`mops.toml` pins `moc = "1.9.0"` and `lintoko = "0.5.1"`. It does **not** pin:

- the **`mops` CLI itself** — the tool whose defaults decide whether integrity is checked
- **`ic-wasm`** — required on `PATH` by the `@dfinity/motoko@v5.0.0` recipe, which runs two metadata
  passes over `mops build`'s output, so it **rewrites the bytes**. It occurs in zero tracked files,
  is absent from the README prerequisites, and `[toolchain]` structurally cannot pin it.

## Evidence

- `.gitignore:22-23` — the integrity claim
- `scripts/lint-ratchet.sh:66-68`, `scripts/lib/candid.sh:30-32` — `mops toolchain bin` / `mops sources`, no integrity flag
- `tests/run_all.sh:162` — `mops test`, same
- `icp.yaml:4` — the recipe that requires `ic-wasm`
- `git grep ic-wasm` — zero tracked files

## Fix

- Run a **verifying** `mops` invocation in a gate (`lint-ratchet.sh` or a pre-push step), so the
  hashes are actually checked on a path the repo runs.
- Pin the `mops` CLI version, and record `ic-wasm`'s version in the README prerequisites (and check
  it at build time if the recipe allows).

## Done when

- [ ] A tampered vendored file turns a gate red
- [ ] `mops` CLI and `ic-wasm` versions are recorded and checked
- [ ] The `.gitignore` sentence is true, or is reworded to what is actually guaranteed

## Notes

The reporter killed their own stronger claim in review — "nothing in the repository reads
`mops.lock`" is false, because `mops sources` reads the dependency map on every call. The corrected
claim above is both true and stronger. Their "one component not pinned" line was also corrected by
themselves to "one of at least two, and the other one rewrites the bytes".

---
## Done — 2026-08-15

lint-ratchet.sh gains a "toolchain" gate, FIRST in the file (trust the
toolchain before using it): (1) `mops install --lock check` — verified
empirically to re-hash the installed .mops/ tree against mops.lock's
per-file SHA-256s (a one-line tamper of sha2's types.mo turns it red; the
check is project-local, no global cache involvement); failure text routes
to the .gitignore de-vendoring claim. (2) `mops` CLI pinned 2.19.2 and
(3) `ic-wasm` pinned 0.11.0, both checked by version with failure text
explaining WHY each is part of the build (the CLI's defaults decide whether
integrity is checked anywhere; ic-wasm rewrites the built wasm's bytes).

.gitignore's sentence is now true as written — it names the enforcement
point ("enforced by scripts/lint-ratchet.sh"). README prerequisites name
mops CLI 2.19.2 (ic-wasm 0.11.0 was added there by W5-06).

Verified: tampered tree → "✗ toolchain: mops.lock integrity check FAILED"
through the full ratchet; restored → all three toolchain lines green.
