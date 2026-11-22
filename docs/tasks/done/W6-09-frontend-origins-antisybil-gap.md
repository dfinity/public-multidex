# W6-09 — `frontend_origins` omits the app's canonical origin (anti-sybil fails closed there)

**Issue:** filed separately per [W6-03](done/W6-03-ii-origins-coverage.md) question B (OhShii #40.4's
second half, disentangled from the II finding)
**Status:** CONFIRMED in the template; LIVE VALUE unverified (subnet env var — operator read needed)
**Severity:** `#play` MEDIUM (verification fails closed on the primary origin)
**Effort:** S (ops action + one doc line, done) — the live check remains

## What it is

The anti-sybil verifier pins ingress origins via the `frontend_origins` canister env var. The
deploy-to-subnet §3b template listed only `icp0.io` + the custom domain — while the app's CANONICAL
origin (the `.icp.net` URL, `II_CANONICAL_ORIGIN` in main.js, "the origin the venue launched on") was
absent. A user reaching the app there and pressing Verify with Google fails closed.

This is NOT the II derivation list (different mechanism, different consumer) — conflating the two was
the imprecision W6-03 corrected. The two lists must nonetheless stay in lockstep by POLICY: every
origin users reach the app from appears in both.

## Done already (W6-03, 2026-08-15)

- Template fixed: §3b now lists `.icp.net`, `.icp0.io`, the domain, with a lockstep note.

## Remaining

- [x] Read the LIVE `frontend_origins` on the subnet backend — **done 2026-08-17, operator-run**:
      all three origins present (`.icp0.io`, `.icp.net`, `multidex.ai`) and
      `trusted_attribute_signers=rdmx6-jaaaa-aaaaa-aaadq-cai` intact. Matches
      `SN_FRONTEND_ORIGINS` in `scripts/.subnet.conf` — the deploy.sh re-assert has been holding.
- [x] Settings update — **not needed**; live value already correct.
- [x] Post-deploy read-back gate — **done 2026-08-17**: `scripts/check_origins.sh` reads the
      deployed value back (`settings show`, explicit `--identity`) and set-diffs it against
      II_PINNED_ORIGINS parsed from main.js (`--expect <csv>` override for the engine, whose
      origins live in its conf); a parse miss or empty expected set fails closed. Wired in BOTH
      remote tails after `apply_anti_sybil_settings`, `|| die` — closing the deploy.sh:712
      silent-warn hole. Pinned in hygiene §6k (11 assertions incl. 3 offline `--from-file`
      fixtures through the real script; wiring pins mutation-verified red, suite green).

---
## Status 2026-08-15

Template + lockstep note landed (W6-03). The live read was attempted with
the anonymous identity and correctly refused (IC0542 — controller-only);
reading/updating the subnet canister's `frontend_origins` needs the operator
wallet identity, and per the deployment doctrine this session does not act
on the subnet unasked. Remaining boxes are the operator's.

---
## Status 2026-08-17 — CLOSED

Operator ran the live read: all three origins confirmed present, signer var
intact, no drift. No settings update needed. Same day, the read-back gate
landed (check_origins.sh + both deploy tails + hygiene §6k), so the next
drift is caught by the deploy itself, loudly, instead of by a manual
operator read. All boxes done.
