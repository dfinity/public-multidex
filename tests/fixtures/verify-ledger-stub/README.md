# Offline hostile-host harness for `scripts/verify_ledger.mjs` (MULTI/DEX @ `60f75f6`)

`scripts/verify_ledger.mjs` is the standalone Proof-of-Reserves / chain verifier that the docs page
hands to users who do not want to trust the site — `src/frontend/src/docs.js:1355`:

> For verification that does not even trust this website, the exchange's source repository ships a
> **standalone verifier** — one self-contained file, `scripts/verify_ledger.mjs`, with the canonical
> form re-implemented from scratch so it agrees with the canister only if the bytes really match.

This harness answers the question that claim raises: **if the gateway is hostile, does the verifier
say so?** It replaces the one dependency the verifier imports (`@icp-sdk/core`) with an offline stub
that impersonates the gateway. It opens no socket, contacts no canister, and modifies nothing.

Three mechanisms let a fabricated tape finish green. Each is independent — fixing one does not close
the others.

## Why the fixture cannot drift

The fabricated tape is hashed with the verifier's **own** `canonical()` and `hashEvent()`, sliced
out of the real file at runtime and evaluated as a module. The stub refuses to start if the slice
does not contain them. A hand-copied mirror could drift from the original and would then be
measuring the copy rather than the verifier; this way the fixture is correct by construction.

## Run it

```sh
git clone https://github.com/dfinity/public-multidex && cd public-multidex
git checkout 60f75f6

mkdir -p /tmp/harness/node_modules/@icp-sdk/core
cp scripts/verify_ledger.mjs /tmp/harness/
# from this gist — note package.json, without it Node cannot resolve the stub:
cp stub-package.json  /tmp/harness/node_modules/@icp-sdk/core/package.json
cp stub-agent.js      /tmp/harness/node_modules/@icp-sdk/core/agent.js
cp stub-principal.js  /tmp/harness/node_modules/@icp-sdk/core/principal.js
cp stub-candid.js     /tmp/harness/node_modules/@icp-sdk/core/candid.js

cd /tmp/harness
V="node verify_ledger.mjs --backend aaaaa-aa --host https://icp-api.io --full"

MDX_STUB_SCENARIO=no-cert   $V ; echo "exit=$?"
MDX_STUB_SCENARIO=bad-cert  $V ; echo "exit=$?"
MDX_STUB_SCENARIO=good-cert MDX_STUB_TAIL=1     $V ; echo "exit=$?"
MDX_STUB_SCENARIO=good-cert MDX_STUB_WITHHOLD=2 $V ; echo "exit=$?"
```

The harness is copied out of the repository rather than created inside it, so the tree stays
untouched. `--host` is passed because the verifier accepts an arbitrary gateway; nothing is sent
to it.

## The four runs, with their actual output

| run | what the host does | result |
|---|---|---|
| `no-cert` | omits the certificate (`certificate = []`) | **exit 0**, `✓ 2 chain links verified`, and **no certificate line at all** |
| `bad-cert` | serves a certificate that fails validation | **exit 1**, `✗ certificate check FAILED` — the control |
| `good-cert` + `MDX_STUB_TAIL=1` | genuine, current, valid certificate; answers `[]` for every event page | **exit 0**, `~ tail not yet readable from seq 0`, `verified up to seq -1 (active)`, `✓ 0 chain links verified`, `✓ IC certificate VALID` |
| `good-cert` + `MDX_STUB_WITHHOLD=2` | genuine certificate; one honest event of replica skew | **exit 0**, `verified up to seq 1`, `✓ 1 chain links verified` — the legitimate case |

## What each run shows

- **`no-cert`** — the certificate check sits inside `if (!failed && head.certificate.length)`. A host
  that omits the certificate skips it with no `else`, and the run still exits 0. Contrast the same
  record's `headHash`, whose absence *does* exit 1.
- **`bad-cert`** — the control that matters. It proves the certificate block is reachable and does
  fail closed. Only *absence* is silent.
- **`good-cert` + `MDX_STUB_TAIL=1`** — the tail concession lets a run reach the end without ever
  comparing the recomputed hash to the certified head, with **no bound** on how far short it stops.
  Zero links verified, a genuine certificate, exit 0, and the rendered line reads
  `verified up to seq -1`. This needs no certificate defect at all, so it survives any fix to the
  other two.
- **`good-cert` + `MDX_STUB_WITHHOLD=2`** — included because it is why the concession exists and why
  a fix must be *bounded* rather than absolute: a verifier that flagged this would be crying wolf on
  an ordinary live tape.

Separately and not scenario-dependent: `disableTimeVerification` is set unconditionally, on every
host, not only on a local replica.

## Scope

Offline, read-only, no network, no canister. Verified against `60f75f6` on Node v24. The stub
implements only the surface `verify_ledger.mjs` actually uses. Reported to DFINITY under the
repository's `SECURITY.md`.
