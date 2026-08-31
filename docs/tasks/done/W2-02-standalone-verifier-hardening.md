# W2-02 — The standalone verifier exits 0 against a hostile gateway

**Issue:** [#37](https://github.com/dfinity/public-multidex/issues/37) items 37.1, 37.2, 37.5 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` HIGH / `#production` HIGH (37.1, 37.2); MEDIUM (37.5)
**Effort:** S–M (one file, one commit)

## Why this matters

`src/frontend/src/docs.js` heads this section *"Verify from a terminal (the auditor's tool)"* and
promises verification that **does not even trust this website**, then hands the user two commands
targeting `--host https://icp-api.io`. The invariant under test: *a user who follows the documented
procedure against a hostile gateway is told the truth, or is told nothing.* Three independent
mechanisms break it, and fixing any one does not close the others.

A runnable reproduction is published by the reporter at
<https://gist.github.com/rvnt9999/a5cbbd482a9dbdd8dc803743c6e70896> — an offline stub that
impersonates the gateway and is hashed with the verifier's own `canonical()`/`hashEvent()` sliced
from the real file at runtime, so the fixture cannot drift from what it tests.

## 37.1 — the tail concession makes reaching the certified head optional and unbounded

When a page comes back short, the run logs `~ tail not yet readable` and `continue`s — **skipping
the head comparison entirely**. Nothing bounds how far short it may stop. A host answering `[]` for
every seq, while serving a genuine, current, valid certificate, yields:

```
  ~ tail not yet readable from seq 0 (live tape / replica skew)
    verified up to seq -1 (active)
✓ 0 chain links verified
✓ IC certificate VALID — the subnet vouches for this head
exit=0
```

The concession is **correctly scoped** — `if (!a.lastSeq.length)` confines it to the *active*
archive, and a sealed archive that stops short is caught and exits 1 — and it is **legitimate**,
because an honest one-event replica skew must keep passing. So the remedy is a bound, not removal.

- `scripts/verify_ledger.mjs:394-402` — the concession; `:401` `continue` skips `:404`'s head compare
- `:364-369` — the `--last` path has the same shape
- no `MAX_TAIL_SKEW` anywhere in the file

## 37.2 — a missing certificate is a skip, not a failure

`:424` is `if (!failed && head.certificate.length)` with **no `else`**. A host that simply omits the
certificate skips the check and the run exits 0 with no certificate line printed at all. Contrast
`:348`, which exits 1 when the same record's `headHash` is missing — same record, opposite direction.

Note the block **does** fail closed when a certificate is present and bad (`:453-455` sets
`failed = true` on a non-local host). **Only absence is silent.**

## 37.5 — freshness is waived on every host

`:436` sets `disableTimeVerification: true` unconditionally, on every `--host`, including
`https://icp-api.io`. The browser sibling states the rule for itself: the window misfires on a
local replica, *"It must NOT be waived anywhere else."* That sentence is about **hosts**, not files
— and this file takes an arbitrary `--host`, so the rule binds it.

## Fix

1. **37.1** — bound the tail skew (e.g. `MAX_TAIL_SKEW`, default one page) and fail when a short
   read stops further below the certified head than that. The default is a number to pick, not a
   given.
2. **37.2** — add the `else`: absent certificate on a non-local host is a failure.
3. **37.5** — gate `disableTimeVerification` on `LOCAL_HOST`, matching the browser rule.

## Done when

- [x] A host answering `[]` for every seq exits **1**
- [x] A host omitting the certificate exits **1** on a non-local host
- [x] Time verification is enforced on non-local hosts
- [x] An honest one-event replica skew still passes (the gist's fourth run)
- [x] Pinned by a gate — see [W5-09](W5-09-gate-the-standalone-verifier.md); today no gate opens
      this file — **still open, deferred to W5-09 as designed** (annotated there with what this
      task learned about the harness)

## Completed 2026-08-15

- **37.1** — the tail concession is bounded two ways in both sites (`--last` and the full walk):
  `--max-tail-skew` (default 200, one page) fails a host stopping further below the certified head
  than an honest replica lag; AND a **zero-progress rule** — truncation with zero verified links
  (run total on the full walk) fails regardless of skew. The second rule came out of dry-running
  the reporter's own harness: its 3-event tape slips under any absolute allowance, i.e. a young
  venue's entire history can hide inside one page — "verified 0 links, exit 0" must be impossible,
  full stop.
- **37.2** — the certificate block has its `else`: absence on a non-local host is a failure
  ("a chain without the subnet's signature proves nothing"); local absence is a tolerated note.
- **37.5** — `disableTimeVerification: LOCAL_HOST` with the browser rule quoted.
- **Verified with the reporter's published reproduction** (gist rvnt9999/a5cbb…, reviewed line by
  line before running; offline stub, no sockets — one local patch: the slice window that mirrors
  `canonical()`/`hashEvent()` out of the real file is now marker-based, since this fix shifted the
  hardcoded 60f75f6 line numbers). All four runs behave: no-cert → exit 1 via the absent-cert
  branch (tape fully verified first); bad-cert → exit 1 (pre-existing fail-closed intact);
  good-cert + empty tape → exit 1 via zero-progress; good-cert + 2-event withhold → exit 0 with
  skew 1 ≤ 200 and the stub observing `disableTimeVerification=false` on the non-local host.
- Happy path against the live reseeded local venue: `--last 1000` → 1,000 links verified,
  recomputed head == certified head, certificate valid, exit 0.

## Notes

Distinct from [W2-01](W2-01-verifychain-tail-anchor.md): there the anchor does not exist; here it
exists and is bypassed. The reporter also retracted an over-claim on the delegation item in this
same issue (the signed delegation does **not** reach `attacker.example.com` — `fetch` throws on
credentials in the URL) — that retraction is theirs and is recorded in
[W6-01](W6-01-refresh-triage-document.md).
