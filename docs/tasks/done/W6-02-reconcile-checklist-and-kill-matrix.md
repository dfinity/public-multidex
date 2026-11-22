# W6-02 — The production gate does not match the code it gates

**Issue:** [#41](https://github.com/dfinity/public-multidex/issues/41) item 2 — OhShii Labs
(step 4 is the artefact [#10](https://github.com/dfinity/public-multidex/issues/10) item 6c named by name)
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#production` LOW–MEDIUM
**Effort:** S

## Correction I owe the reporter, up front

My first triage pass repeated a claim that `claimPlayFunds` "is not actually retired", casting doubt
on step 4. **That was wrong.** There is no `func claimPlayFunds` anywhere in `src/`, `PLAY_BASKET` is
gone, and all remaining `src/` hits are comments. The reporter is right: **the fix reached the
checklist and not the kill matrix.**

## What's wrong

`SECURITY.md` nominates `docs/pre-mainnet-checklist.md` as "the production gate" and
`docs/deployment-modes.md` as the kill matrix; `main.mo` points at the same file; the checklist says
so of itself. Six steps do not match the code they gate. Verified spot-checks:

1. **The checklist asserts a literal the code does not emit.** It expects
   `#err("setAmmRefPrice is a dev-only override")`; `main.mo:12358` emits
   `"setAmmRefPrice is a dev-only hook (posture: play/production)"`. The checklist's literal appears
   in **no** `.mo` file. *Positive control on the same runbook:* another step asserts a string
   `main.mo:15008` emits byte for byte — so the pairing **can** be detected, which makes the mismatch
   a defect rather than an impossibility.
2. **A step cannot distinguish the two postures its own heading exists to verify** —
   `debugInspectByUsername` is expected to answer a controller with an empty record, but `main.mo:10610`
   **traps first**, on `#play` and `#production` alike.
3. **Three suites named under the mainnet heading**: two sign as `--identity anonymous`; one needs a
   mock canister the same page **forbids deploying** seventeen lines earlier.
4. **The kill matrix still carries five `claimPlayFunds` references** (`deployment-modes.md:38`, `:47`,
   `:82`, `:121`, `:123`) for a **retired** method, and names `tests/test_play_claim.sh` (`:90`, `:200`)
   which **does not exist**. `pre-mainnet-checklist.md:57-59` was correctly struck through.
5. **"Returns silently" contradicts the actor's own stated rule.** The checklist and kill matrix
   prescribe "returns silently" / "no-ops" / "returns 0", while `main.mo:8195-8198` states:
   *"THE RULE for every posture gate: refuse loudly … Never a silent return."* Six sites return
   silently, one live at the committed `#play` posture. `src/bridge/main.mo:65-68` copies the rule
   verbatim and `:389-390` shows compliance for a signature with no error channel.
6. **The faucet gate is described as `isProduction`**; the code gates on a flag bound to `not IS_DEV`.
   Stale in the safe direction — half a line.

## Two things the reporter concedes, and they matter

- Their own #7.4 named those same silent endpoints **approvingly**, as siblings that *did* carry the
  interlock. Step 5 is therefore a request to **reconcile two of our own artefacts**, not a claim of
  drift by them.
- **The battery is not degenerate**: `getDeployMode()` returning `"production"` is decisive on its
  own. Step 5's silence is redundancy lost, not a hole opened.

## Fix

- Reconcile the checklist's asserted literals against what the code emits (or make the code emit what
  the checklist asserts — pick per site).
- Remove or update the five `claimPlayFunds` rows and the `test_play_claim.sh` references in the kill
  matrix.
- Settle the "refuse loudly vs return silently" contradiction in **one** direction and make all six
  sites and both documents agree.
- Fix the faucet-gate description.

## Done when

- [ ] Every checklist literal appears in a `.mo` file, verified by grep
- [ ] The kill matrix names no retired method and no non-existent test
- [ ] The loud/silent rule is consistent across `main.mo`, `bridge/main.mo` and both documents
- [ ] Ideally: a gate that greps checklist-asserted literals against `src/` so this cannot drift again

---
## Done — 2026-08-15

**Direction settled: LOUD, per the actor's own rule** ("refuse loudly, in
whichever way the signature allows … Never a silent return"). All six silent
sites now refuse loudly: addTestTokens traps (`dev-only faucet` — this was
the one silent gate LIVE on the committed #play posture; gate bound to
`not IS_DEV`, now also documented as such in the kill matrix), setTestBalance
/ bulkSetTestBalances / getTestBalance / seedInsurance / resetExchange trap
"not available on #production" (getTestBalance keeps the caller-auth `0` for
non-controllers asking about others — that silence is the anti-oracle rule,
not a posture gate, and the checklist now says so). Deployed on #dev.

**Documents reconciled to the code:** the checklist's `setAmmRefPrice`
literal is the code's real string (`dev-only hook (posture: play/production)`);
`debugInspectByUsername` step expects the TRAP (a wrong `found=false` claims
the user doesn't exist); the mainnet suite trio is honest about where each
runs (fuel_topup = local-only mock; archive_replay signs as the local
controller; mainnet reconciliation = verify_ledger.mjs, itself gate-covered);
the kill matrix's five `claimPlayFunds` rows and two `test_play_claim.sh`
references are retired/rewritten around the reservation-flow on-ramp
(remaining mentions are retirement notices).

**Drift gate (§7d):** every `#err("…")` literal asserted by either document
must exist verbatim in src/**/*.mo, plus the four standardised trap literals
pinned by name. On its FIRST run it caught a real drift beyond the reported
one — deployment-modes.md asserted `#err("… genesis window closed …")` as an
ellipsised pseudo-literal; now quotes the code's verbatim prefix. A doctored
literal turns the gate red; restored tree green, `mops check` clean.
