# W1-02 — Four `DEPLOY_MODE` gates read the posture by text, none comment-aware

**Issue:** [#37](https://github.com/dfinity/public-multidex/issues/37) item 37.3 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` HIGH / `#production` HIGH (deploy safety)
**Effort:** S–M

## What's wrong

Four independent gates re-read the `DEPLOY_MODE` literal out of `src/backend/main.mo` by text, in
three different ways, and **none strips comments**. A single commented-out decoy declaration above
the real one defeats all four, after which `deploy_to_subnet.sh` ships a `#dev` build — the open
faucet.

`scripts/lib/targets.sh:137-138` is the worst of the four:

```bash
MDX_POSTURE=$(grep -oE 'transient let DEPLOY_MODE : DeployMode = #[a-z]+' "$MDX_ROOT/src/backend/main.mo" \
       | grep -oE '#[a-z]+$' | tr -d '#')
```

No `head -1`. A second match makes `MDX_POSTURE` a two-line string, and `:140` tests
`[ "$MDX_POSTURE" = "dev" ]`, which a two-line value can never equal — so **ambiguity reads as
safety**. `head -1` is *not* the fix: it passes the shipping case for the wrong reason.

## Evidence

- `scripts/lib/targets.sh:137-141` — no comment strip, no `head -1`, refuses `#dev` on remote targets
- `scripts/deploy.sh:505` — `posture_of()`, `head -1`, no comment strip
- `scripts/cold_start.sh:153` — `grep -oE … | head -1 | sed 's/.*#//'`, no comment strip
- `scripts/play_start.sh:80` — `grep -q 'DEPLOY_MODE : DeployMode = #play'`, matches inside a comment
- `src/backend/main.mo:102` — the real declaration (`transient let DEPLOY_MODE : DeployMode = #play;`)

## Fix

One shared helper in `scripts/lib/targets.sh`, used by all four call sites:

1. Strip full-line comments before matching (`sed 's/^[[:space:]]*\/\/.*//'` for Motoko).
2. **Refuse ambiguity** — if the match count is not exactly 1, `die` with the count. Do not take
   the first match.
3. Have the other three gates call the helper instead of re-implementing the grep.

Same class as [W5-10](W5-10-deploy-hygiene-harness.md)'s comment stripper, different consumer and
much larger blast radius: that one is a test gate's pre-filter, this is four deploy-path gates and
a shipped posture.

## Done when

- [x] One helper resolves the posture; the other three sites call it
- [x] A decoy commented `DEPLOY_MODE` line makes every gate **fail loudly**, not pass
- [x] Two real declarations make every gate fail with the count, not silently pick one
- [x] Unmodified tree still resolves `#play` and deploys normally

## Completed 2026-08-14

- `mdx_posture_of <file>` added to `scripts/lib/targets.sh`: strips `//` comments (trailing too, not
  just full-line — a trailing decoy would survive full-line stripping), then refuses any match count
  other than exactly 1 with the count and matches on stderr. It returns 1 with empty stdout rather
  than exiting, so it is safe inside `$( )` per targets.sh's own NOTE ON SHAPE; every call site
  re-raises empty as fatal in its own shell. Block-comment decoys are deliberately not parsed — they
  inflate the count and land in the same refusal (fail-closed).
- All four gates delegate: `mdx_assert_posture_for_target` (targets.sh), `posture_of()` (deploy.sh,
  comparisons moved to bare words), the `DO_SEED` gate (cold_start.sh — which previously **tolerated
  an unreadable posture and seeded anyway**; now refuses), and the preflight in play_start.sh.
  deploy.sh, cold_start.sh and play_start.sh now source `lib/targets.sh` (pure definitions, no side
  effects; verified the live fleet never re-sources it).
- The fifth and sixth comment-blind reads — `test_deploy_hygiene.sh`'s own `BRIDGE_MODE`/`DEX_MODE`
  greps — also go through the helper.
- Pinned in `test_deploy_hygiene.sh` §6b: static delegation pins for all four sites (old grep
  spellings banned), plus behavioral fixture probes — clean → `play`; commented decoy over real
  `#dev` → resolves `dev` (so remote gates refuse the build); trailing-comment decoy → same; two
  real declarations → refusal naming "found 2", empty stdout; zero → refusal; real main.mo →
  unambiguous. Suite 86/86 green; `mdx_assert_posture_for_target subnet` passes on the #play tree.
- Raised [W3-09](W3-09-bridge-posture-deploy-gate.md): the deploy path reads only the DEX
  literal; the Bridge's posture is asserted one-directionally in the test suite but never on the
  deploy path itself. Cheap now that the reader takes a file argument.
- Noted in [W5-10](W5-10-deploy-hygiene-harness.md): §6b's haystacks moved its item-3 SIGPIPE
  bound from ≤6.8 KB to ≈30 KB (onset ≈48 KB).
