# W2-04 — Every structural input to the chain verifiers is an uncertified self-report

**Issue:** internal red-team round 2, finding R1 (+ R11 folded in, + one sibling found on verification)
**Status:** VERIFIED LIVE at `d8f4c58` (2026-08-17)
**Severity:** `#play` HIGH / `#production` **CRITICAL** — defeats the property the archive design exists to provide
**Effort:** M

## Framing

Under the W2 rationale, "verify without trusting us" is a requirement of the transparency doctrine,
not a feature. This is the finding that most directly undermines it, and it should go first.

The trust chain the ledger is supposed to give a reader is: IC certificate (BLS, subnet-signed) over
the **active** archive's `certified_data` → the active archive's tape → the hash carried across
canister boundaries → every sealed archive beneath it. Both verifiers implement exactly that — and
then hand the audited canister three ways to cut the chain.

## What's wrong

**1. The link-skip list is an uncertified query on the audited canister.**

`getLedgerGaps()` (`src/backend/main.mo:7558`) is a plain `public query` returning `_ledgerGaps`, a
`var [(Nat, Nat, Int)]` (`:7751`) written by `recordGap` on the L2 shed path (`:8106`). It is not
certified, not part of the hash chain, and is canister state authored by exactly the party under
audit. Both verifiers consume it to drop cross-archive links:

- `src/frontend/src/ledger.js:265-266` — `const reanchored = i > 0 && reanchorSeqs.has(from); const seed = reanchored ? null : carried;`
- `scripts/verify_ledger.mjs:412-413` — identical

A canister rewriting archives `0..k−1` returns one extra tuple whose `toSeq` equals archive `k`'s
`firstSeq`. Both verifiers stop carrying the hash there and thereafter check each earlier segment
only against its **own self-reported head**.

**2. Only the active archive's certificate is validated.**

`ledger.js:288` and `verify_ledger.mjs:459-478` both validate against `active.canisterId` only.
Sealed archives are compared against `getCertifiedHead().headHash` (`ledger.js:271`) — self-reported
state. The verifier still prints `IC certificate VALID — the subnet vouches for this head` and
returns `certOk: true`, because the active archive's certificate is genuinely fine.

**3. Genesis is not pinned, and the archive list is also uncertified — the same attack with no gap needed.**

Not in the report; found on verification. Neither verifier pins the origin: `archives[0]` is seeded
`null` by construction and its `firstSeq` is taken on faith (`ledger.js:260`,
`verify_ledger.mjs:406`). The list itself comes from `getArchives()` (`main.mo:7648`) — another
plain uncertified query. Omitting early archives truncates history with no gap tuple, no
discontinuity, and no complaint.

**Root cause, one sentence:** every structural input to the verifier — archive list, gap list, chain
start — is an uncertified self-report from the party under audit.

## Pushback on the reported fix menu

R1 offers two fixes "either of which closes it". That is not right:

- **Binding gaps to the chain (its fix 1) does not close it alone.** It makes a gap tamper-evident
  at emission time — real value, since one cannot be inserted retroactively without breaking the
  chain — but a canister willing to lie going forward can still emit a genuine `#gap` event today
  and rewrite behind it.
- **Validating every archive's certificate (its fix 2) is the load-bearing change**, and it composes
  with a control that already exists: `setBlackholeAtSeal` (`main.mo:7641`) is a documented
  pre-mainnet requirement (`docs/pre-mainnet-checklist.md:91`). With sealed archives blackholed
  *and* each certificate validated, rewriting a sealed segment costs a forged BLS signature. Without
  blackholing it costs a canister reinstall — better than a JSON tuple, but not absolute. The docs
  must say which of the two regimes is in force rather than implying certificates alone are
  dispositive.

Feasibility confirmed: sealed archives do set `certified_data` on their last `appendBatch`
(`src/backend/ArchiveCanister.mo:226`) and `getCertifiedHead()` is a query, so a certificate is
available per segment.

## R11 folded in here, and downgraded to documentation

R11's mechanics are correct — `ArchiveCanister.mo:203-218` anchors at whatever arrives first with no
check against the predecessor's head, and `verifyChain:299` starts at `Nat.max(fromSeq, anchor)`, so
the inbound link at the anchor is never verified. But the severity is wrong and it does **not** earn
code:

- `verifyChain` is a plain uncertified `public query`. A hostile canister returns `ok = true`
  regardless, so on-canister enforcement buys **no** security — it is a self-diagnostic for honest
  bugs and storage corruption.
- The successor is never *told* the predecessor's head. The install arg is `(owner)` only
  (`main.mo:7501`); `SealedArchive` (`:7481`) and `ArchiveChainEntry` (`:7195-7208`) carry no hash.
  "Fixing" it means new plumbing for zero security gain.

So: amend the `verifyChain` docstring to state that it verifies links **within** this archive only
and cannot check the join to its predecessor. Also correct `docs/archive-design.md:382-386`, which
says the chain "runs UNBROKEN across sealed archives (the successor's first event links to the
sealed head — pinned by the test)" — the pinning is an off-chain shell assertion
(`tests/test_archive_chain.sh:149-152`), not on-canister enforcement, and the doc reads stronger
than the canister is.

## Fix

1. Validate **every** archive's certificate, not just the active one — both verifiers.
2. Pin genesis: refuse a first archive whose `firstSeq` / `chainStartSeq` is not the true origin
   unless a chain-visible gap explains it.
3. Bind gaps to the chain (emit a `#gap` event at the shed point) as defence in depth, and honour
   only re-anchors visible in the chain being validated.
4. Fix the verdict copy. Pre-fix, `certOk: true` means "the active archive's newest events are
   genuine", not "the ledger is intact" — the CLI `✓` and the UI string both overclaim.
5. Docstring + `archive-design.md` corrections per R11 above.

## Done when

- [x] Both verifiers validate a certificate per archive segment — CLI `validateArchiveCert`
      (absent cert on a real network = fail; dev host = loud note), browser per-archive
      `validateCertifiedHead` with `segCertsOk` counted. Proven live on the scratch venue:
      `2 segment certificate(s) subnet-validated` across sealed + active
- [x] Genesis pinned: coverage starting after the origin (active `chainStartSeq`, or the
      out-of-band `--expect-start` / `opts.expectStart`) demands a justified gap; plus
      coverage-continuity checks between archives (an omitted middle archive is a seq jump)
- [x] A fabricated gap tuple no longer suppresses a link check: re-anchors from `getLedgerGaps`
      are honored TENTATIVELY and must be justified post-walk by a `#gap` event hash-committed
      in the chain (or an operator-audited `--accept-gap FROM:TO` for legacy gaps). The shed now
      EMITS that `#gap` event (new `UserEventKind` case, canonical branch in EventChain + both
      JS mirrors + IDL copies). A fabricated tuple at a continuous boundary needs a #gap for an
      empty range, which the honest path never emits
- [x] Verdict copy states what was proven: per-segment counts in the summary; the active
      certificate line scoped to the ACTIVE head; `--last`/window mode says sealed history was
      not visited; browser gap-note upgraded to "chain-declared" only when proven
- [x] `verifyChain` docstring states within-this-archive scope + why plumbing the join buys no
      security; `archive-design.md` corrected (off-chain shell pin, not canister enforcement)
- [x] Pinned in `test_verify_ledger_gate.sh`: `fabricated-gap` and `truncated-list` scenarios
      added to the vendored stub (multi-archive, per-canister GENUINE certificates so the
      refusal comes from the trust-anchor logic alone) — **6/6 green**, both lies exit 1, the
      four W2-02 verdicts unchanged
- [x] Blackhole-at-seal dependency stated in `archive-design.md`, the CLI verdict comment, and
      the browser certNote comment (tamper-EVIDENT vs tamper-PROOF)

---
## Status 2026-08-17 — CLOSED; verified end-to-end on a scratch venue

The `#gap` widening required real machinery beyond the verifiers:

- **API major bump 2.0.0 → 3.0.0** (adding a variant case to a result-position type is
  candid-breaking for old decoders — deliberate; `candid/README.md` "Major bumps so far" has the
  entry; the lint-ratchet hatch opens when the bump COMMITS, by design).
- **One-shot EOP migration** (`src/backend/migration.mo`, fourth in the retired-migrations
  lineage): `userEvents` is a MUTABLE List, so the otherwise-compatible variant addition is
  memory-incompatible (invariance) — per-element copy with the widening coercion. Same root
  cause hit `archive0`/`_archiveNext` (stable ACTOR refs whose minimal sink interface still
  contained `UserEvent`): they are now bare **Principals** (interface-free forever; `sinkOf`
  derives the typed handle per call), so future kind additions never break the upgrade again.
  Rehearsed per doctrine on the scratch worktree venue: un-migrated build refused (IC0503
  "Memory-incompatible", twice — the negative control), migrated build upgrades clean, audit
  consistent after.
- **Runbook note** (deploy-to-subnet.md): run `adminUpgradeArchives` after a kind-widening
  backend deploy (the archive stores candid blobs, so IT needs no migration — but its
  `appendBatch` must decode the new case; skipping is self-healing via the L1 roll, just noisy).
- **Retirement follow-up**: remove `(with migration = Migration.run)` + `migration.mo` once
  local, engine and subnet have each upgraded through it once.

End-to-end proof: `test_archive_failover.sh` (18/0, its §C arithmetic now counts the +1 #gap
event) drove a REAL L2 shed on the migrated build; `verify_ledger.mjs --full` against that venue
walked sealed+active, validated both segment certificates, and justified the re-anchor from the
chain-committed #gap — 44 links, Motoko↔JS canonical agreement proven on live data. Frontend
builds clean; hygiene 175✓; M0155 at zero.
