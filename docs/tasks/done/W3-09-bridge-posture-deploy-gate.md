# W3-09 — The deploy path never reads the Bridge's posture literal

**Issue:** none — raised by [W1-02](W1-02-deploy-mode-gate-comment-blind.md) (queue step 5), 2026-08-14
**Status:** VERIFIED at the working tree, 2026-08-14 — documented gap, currently guarded only by a
test-suite assertion that does not run on the deploy path
**Severity:** `#play` LOW / `#production` MEDIUM-HIGH (the §2.15 unbacked-credit hooks live against
a value-bearing DEX)
**Effort:** S

## What's wrong

Every posture gate on the deploy path resolves `src/backend/main.mo` and only it:
`mdx_assert_posture_for_target` (targets.sh), `posture_of()` (deploy.sh), the seeding gate
(cold_start.sh), the preflight (play_start.sh). The Bridge has its own independent
`transient let DEPLOY_MODE` literal (`src/bridge/main.mo:62`), and `icp.yaml` wires the same bridge
into both production-facing targets.

The invariant that matters is one-directional and already stated in
`tests/test_deploy_hygiene.sh` §7: **the Bridge must never be more permissive than the DEX it
credits.** A `#production` DEX deployed alongside a `#play`/`#dev` Bridge leaves the Bridge's
unbacked-credit dev hooks (§2.15) answering against a value-bearing venue. Today that combination is
caught only if somebody runs the test suite — nothing on the deploy path itself reads the Bridge's
literal, so `deploy.sh subnet` would ship it without a murmur.

Not urgent while the live posture is `#play` (DEX `#play` / bridge `#play` is the committed pair and
`#play` is not value-bearing), which is why this is W3, not W1.

## Fix

`mdx_posture_of` (from [W1-02](W1-02-deploy-mode-gate-comment-blind.md)) already takes a file
argument, so the reader exists:

1. In deploy.sh's remote-target posture block, also resolve
   `mdx_posture_of src/bridge/main.mo` and refuse when the DEX resolves `production` and the Bridge
   does not — the same one-directional rule as the test, with the same remediation text.
2. Consider the same check in `mdx_assert_posture_for_target`, so `deploy_to_subnet.sh` and any
   future entry point inherit it rather than re-implementing it.
3. Pin in `test_deploy_hygiene.sh`: the deploy path resolves **both** literals (static), and the
   refuse branch names the Bridge (the §7 suite-side invariant stays as the backstop).

## Done when

- [x] A `#production` DEX with a non-`#production` Bridge is refused **on the deploy path** for
      remote targets, loudly, before any build ships
- [x] The committed `#play`/`#play` pair and the local `#dev` flow deploy exactly as before
- [x] The gate reads both literals through `mdx_posture_of` (no new hand-rolled greps)

## Completed 2026-08-15

- Both deploy-path gates extended: `mdx_assert_posture_for_target` (targets.sh — inherited by
  every wrapper) and `posture_of`'s block in deploy.sh refuse a remote target when the DEX
  resolves `#production` and `src/bridge/main.mo` does not, naming the unbacked-credit risk. Both
  read through `mdx_posture_of` (comment-aware, ambiguity-refusing).
- Hygiene §6g: static pins on both call sites + a behavioural fixture pair (#production DEX /
  #play bridge → REFUSED). §7's suite-side one-directional invariant stays as the backstop.
- Live gate probes: the #dev tree is refused for `subnet` (the W1-02 gate, still working); the
  committed #play/#play pair passes.
