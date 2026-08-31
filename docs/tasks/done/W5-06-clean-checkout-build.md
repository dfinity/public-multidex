# W5-06 — Neither published build path works on a clean checkout

**Issue:** [#41](https://github.com/dfinity/public-multidex/issues/41) item 1 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` MEDIUM (voter-reproducible build)
**Effort:** S

## What's wrong

`mops.toml` declares `candid = "src/backend/backend.did"`. `.gitignore` **excludes** that file,
`git ls-files` returns nothing for it, and it is absent from the published tree. The only writer is
`scripts/gen-did.sh` — and the repository's own comment in that script states the consequence:
`mops build` *"treats it as a compat-check **INPUT**, so a build fails without it."*

**No documented path runs it.** `README.md` and `deploy-to-subnet.md` (including the launch-day row)
both reach the build with no generating step between. `.github/` holds only `dependabot.yml`, and
`.githooks/pre-push` contains no build.

Extracting the launch commit with `git archive` into an empty directory and running the documented
build fails:

```
Error during Candid compatibility check for canister backend
Candid file not found: src/backend/backend.did
```

## Why it matters despite the private tree building fine

`bridge-and-cks-design.md` requires a build "reproducible so **voters** can verify the wasm matches
the source", and makes it handover step 5. A voting neuron holder has the public mirror and nothing
else. The gap only matters under the ownership model that document names — which is why it is a
*readiness* finding rather than an engineering one.

**Second leg:** the build you cannot run is also a build whose tools are not recorded. `icp.yaml`
declares the recipe `@dfinity/motoko@v5.0.0`, which hard-requires `ic-wasm` on `PATH` and runs two
metadata passes over `mops build`'s output — so the installed module is not `moc`'s output, and every
section of it is re-encoded by a tool whose version is written down nowhere. **`ic-wasm` occurs in
zero tracked files** (positive controls: `lintoko` 4 files, `mops` 24), is absent from the README
prerequisites, and `mops.toml`'s `[toolchain]` cannot pin it.

## Evidence

- `mops.toml:15` — `candid = "src/backend/backend.did"`
- `.gitignore:66` — excludes it; `git ls-files` — untracked
- `scripts/gen-did.sh:33-34`, `:27-29` — the only writer, and the warning
- `README.md:61-71`, `docs/deploy-to-subnet.md:127-129` — build steps with no generate step
- `candid/backend.did` — the *published* copy **is** tracked (different file, different purpose)

## Fix

One line in two documents: add `bash scripts/gen-did.sh` before the build in `README.md` and
`docs/deploy-to-subnet.md`. Then verify by `git archive`-ing the tip into an empty directory and
running the documented steps end to end.

Pin the toolchain while here — see [W5-08](W5-08-mops-integrity-and-pinning.md), which owns
`ic-wasm` and the `mops` CLI.

## Done when

- [ ] `git archive` of the tip into an empty dir builds using only the documented steps
- [ ] `ic-wasm` appears in the README prerequisites with a version
- [ ] Dedup noted: this is **not** #10.4 (which said there was no build *verification*); this says the
      published source does not *build*

---
## Done — 2026-08-15

Both documented paths now generate the compat-check input before building:
README "Getting started" gains `bash scripts/gen-did.sh` (with the why: the
file is a gitignored INPUT) and deploy-to-subnet.md step 1 becomes
`mops install && bash scripts/gen-did.sh && icp build`. README prerequisites
now name `ic-wasm` 0.11.0 with the reason (the `@dfinity/motoko@v5.0.0`
recipe's metadata passes re-encode the wasm — the installed module is
ic-wasm's output, not moc's). Version pinning proper stays with [[W5-08]].

Verified end-to-end on a `git archive HEAD` extraction into an empty dir:
control (documented steps WITHOUT gen-did) fails with the reporter's exact
error ("Candid file not found: src/backend/backend.did"); with the new step,
`icp build backend` → "Canisters built successfully". Bonus fix: gen-did.sh
resolved the repo root via `git rev-parse` and printed `fatal: not a git
repository` inside the archive — the voter path's first line of output was
alarming noise. It now falls back to the script's parent dir; verified quiet
and correct in both the real tree (1648-line did) and the archive (1598).

Dedup note (Done-when box 3): this is NOT #10.4 — that finding said there
was no build *verification*; this one said the published source does not
*build*. Both are real; this closes only the latter.
