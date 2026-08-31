# W4-20 — CSP is verified by configuration, never by response headers

**Issue:** [#4](https://github.com/dfinity/public-multidex/issues/4) item 2 — OhShii Labs
**Status:** **OUTSTANDING** at `01d2b23` (2026-08-14) — 1.60 triage §6 said "do that on the next remote deploy"
**Severity:** `#play` LOW / `#production` MEDIUM
**Effort:** S

## What's wrong

`security_policy: "standard"` is set on the shipping asset config, and the build was audited for what
`standard` would break (no `eval`, no WASM, no cross-origin fetches, no external fonts). That is a
configuration-level answer to the reporter's finding, and the reporter accepted it as such.

What has never happened: **nothing has been `curl -sD-`'d against a deployed asset canister**. So the
actual `Content-Security-Policy` response header the browser receives is unverified. The gap between
"the config says standard" and "the header is present and correct" is exactly the gap this whole
audit wave keeps finding elsewhere.

## Evidence

- `src/frontend/public/.ic-assets.json5:32` — `"security_policy": "standard"`
- `:23` — the comment noting `standard` is what emits the CSP header
- No test, gate or script fetches response headers from a deployed canister

## Fix

Two parts:

1. **Verify once, now** — on the next remote deploy, `curl -sD- https://multidex.ai` (and the
   canister URL) and record the actual headers in the deploy log or the checklist.
2. **Keep it verified** — add a post-deploy check that asserts the CSP header is present and contains
   the expected directives, so a config change or a recipe upgrade that drops it is caught.

Part 2 is what turns this from a one-off into a guarantee, and it is small.

## Done when

- [x] Actual response headers from a deployed asset canister are recorded
- [x] A post-deploy check asserts CSP presence and key directives
- [x] `pre-mainnet-checklist.md` carries the verification step with the real expected header

## Completed 2026-08-15

Verified NOW against the LIVE site (read-only): `curl -sD- https://multidex.ai` returned the full
strict set — CSP (script-src 'self', object-src 'none', frame-ancestors 'none'), HSTS, nosniff,
X-Frame-Options DENY, referrer-policy, permissions-policy — recorded verbatim in
`pre-mainnet-checklist.md`. Kept verified: `scripts/check_headers.sh` asserts presence + key
directives, and `deploy.sh` runs it after every subnet/engine deploy against the first recorded
https origin, failing the deploy loudly when a header is dropped.
