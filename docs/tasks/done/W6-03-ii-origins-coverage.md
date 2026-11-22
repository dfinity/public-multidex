# W6-03 — A sign-in invariant stated as MUST, with no instrument

**Issue:** [#40](https://github.com/dfinity/public-multidex/issues/40) item 4 — OhShii Labs
**Status:** core finding CONFIRMED; the drift leg is IMPRECISE — verified at `01d2b23` (2026-08-14)
**Severity:** `#play` MEDIUM / `#production` MEDIUM
**Effort:** M

## Correction to the finding as filed, and to my own first pass

The finding says three statements of one list exist and one already disagrees. Verified:

- The **two shipped II artefacts agree** — `src/frontend/public/.well-known/ii-alternative-origins`
  and its `dist/` copy both list `icp.net`, `icp0.io`, `multidex.ai`, matching `II_PINNED_ORIGINS` at
  `src/frontend/src/main.js:1163-1167` and `II_CANONICAL_ORIGIN` at `:1162`. **No drift between them.**
- The "third statement" is `docs/deploy-to-subnet.md:141`'s
  `frontend_origins=https://<frontend-id>.icp0.io,https://<PLACEHOLDER-domain>` — which is the
  **anti-sybil verifier's** origin pin (`:209`: *"The anti-sybil verifier pins origins"*), a
  **different mechanism** from II's `alternativeOrigins` / derivation origin.

So "a third statement of the same list" is not accurate, and my first triage repeated it. Two
separate questions fall out, and both are real:

## Question A — the finding that robustly stands (do this)

**No test, gate or script reads either II artefact.** `main.js:1156` states the rule in the code's own
words — *"origin's `/.well-known/ii-alternative-origins`, which MUST list every origin"* — and nothing
verifies that the shipped file and the pinned list agree.

This is the sign-in path. The failure mode is not subtle: users unable to authenticate, or an origin
trusted that should not be. A MUST with zero coverage is exactly the class this whole audit wave is
about.

*Fix:* add a gate that parses `.well-known/ii-alternative-origins` and asserts set-equality with
`II_PINNED_ORIGINS`, including the canonical origin. Assert against the **built** `dist/` copy too, so
a build that drops or rewrites it fails.

## Question B — a separate, possibly real anti-sybil gap (investigate)

Should `frontend_origins` also list the canonical `icp.net` origin? If users can reach the app there
and the anti-sybil verifier pins origins, omitting it may break attribute verification on that origin.

This is **not** the II finding. Answer it on its own terms, and if it is real it deserves its own
entry rather than riding along.

## Evidence

- `src/frontend/src/main.js:1156` — the MUST; `:1162-1170` — canonical + pinned origins, `derivationOrigin` selection
- `src/frontend/public/.well-known/ii-alternative-origins` — the artefact (agrees)
- `docs/deploy-to-subnet.md:141`, `:181`, `:209`, `:287` — `frontend_origins`, the anti-sybil list
- `git grep` over `tests/ scripts/ ops/ .github/ icp.yaml` — **no reader** of either II artefact

## Done when

- [ ] A gate asserts the II artefact and `II_PINNED_ORIGINS` agree, in source and in `dist/`
- [ ] Removing an origin from either side turns the gate red
- [ ] Question B is answered yes/no in writing, and filed separately if yes
- [ ] The correction above is passed back on the issue thread, since the reporter asked to be held to precision

---
## Done — 2026-08-15

**Question A:** frontend_security.test.mjs §B2 now parses BOTH copies of
`.well-known/ii-alternative-origins` (source always; `dist/` required
whenever a build exists, so a build that drops or rewrites it fails),
extracts `II_PINNED_ORIGINS` + `II_CANONICAL_ORIGIN` from main.js, and
asserts set-equality plus canonical-in-list. Mutations verified red in both
directions (an origin dropped from the artefact; an origin dropped from the
pinned list). Suite: PASS 82.

**Question B: YES — real, filed separately** as
[W6-09](../W6-09-frontend-origins-antisybil-gap.md). The deploy template's
`frontend_origins` omitted the canonical `.icp.net` origin — the app's
PRIMARY origin — so Verify-with-Google would fail closed exactly there. The
template is fixed with a lockstep note; the live subnet env-var read/update
is an operator action recorded in the new task.

**Box 4 (pass the correction back on the issue thread):** the correction
text is written in this file's header ("two shipped artefacts agree; the
third statement is a different mechanism") and folded into the W6-01 triage
refresh. POSTING to the public thread is an outward-facing action awaiting
explicit go-ahead — queued under W6-05's acknowledgment batch.
