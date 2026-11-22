#!/usr/bin/env node
// tests/frontend_canister_env.test.mjs — the ic_env cookie row-picker
// (src/frontend/src/canister-env.js) and the one-shot self-heal main.js hangs
// on it (task 1793499221).
//
// WHY. The asset canister serves every canister id the frontend needs in ONE
// host-only cookie, `ic_env`, and @icp-sdk/core 5.x read the FIRST `ic_env=` of
// document.cookie (6.1.1 reads them all and refuses a jar whose copies disagree
// — no env at all). A cookie jar is keyed by host name, not origin, so on a
// developer machine the first row is not always ours: another project's
// static-site canister leaves a `Partitioned` twin FIRST at an id host (its
// frontend drew the same id from the shared deterministic pool), and the
// shared friendly name `frontend.local.localhost` hands a back/forward-cached
// page the LAST venue's row. Both were reproduced in Chrome (2026-11-01) and
// both ended in the fuel banner blaming "a network or replica issue".
//
// Two kinds of check, as in the sibling suites:
//   · BEHAVIOURAL — canister-env.js is DOM-free (cookie string and host name
//     are arguments), so it is imported and fed the jars captured in the
//     browser; the SDK's own parser runs beside it on the same jars to prove
//     the semantics match (and to show what the SDK alone does at the
//     twin-first jar: 5.x picked the twin, 6.1.1 refuses the jar outright).
//   · STATIC — main.js only runs in a browser, so the eight read sites, the
//     self-heal's one-shot shape, its trigger points and the banner wording
//     are asserted against the source.
//
// Usage:
//   node tests/frontend_canister_env.test.mjs           # the working tree
//   node tests/frontend_canister_env.test.mjs <root>    # another checkout

import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { join, dirname, resolve } from "node:path";
import { stripJsComments } from "./_lib.mjs";

const ROOT = process.argv[2]
  ? resolve(process.argv[2])
  : resolve(dirname(fileURLToPath(import.meta.url)), "..");

let passed = 0;
let failed = 0;
function ok(name) { passed++; console.log(`✓ ${name}`); }
function bad(name, detail) {
  failed++;
  console.log(`✗ ${name}`);
  if (detail) console.log(`    ${String(detail).split("\n").join("\n    ")}`);
}
function check(name, cond, detail) { cond ? ok(name) : bad(name, detail); }
const path = (p) => join(ROOT, p);
function read(p) {
  const f = path(p);
  if (!existsSync(f)) return null;
  return readFileSync(f, "utf8");
}
function must(p) {
  const s = read(p);
  if (s === null) bad(`${p} exists`, `not found under ${ROOT}`);
  return s;
}
// Body of the first function whose header text matches, brace-balanced.
function funcBodyL(src, header) {
  const at = src.indexOf(header);
  if (at < 0) return null;
  const i = src.indexOf("{", at + header.length);
  if (i < 0) return null;
  let depth = 0;
  for (let j = i; j < src.length; j++) {
    const c = src[j];
    if (c === "{") depth++;
    else if (c === "}") { depth--; if (depth === 0) return src.slice(i + 1, j); }
  }
  return null;
}

// ── Fixtures ────────────────────────────────────────────────────────
// Root keys: a local replica's DER-wrapped BLS public key is 133 bytes (37 of
// DER prefix + 96 of key). A is seat-2's venue of 2026-11-01 (public — it is
// the replica's PUBLIC key, served in every HTML response); B and C are
// synthetic keys for the other venue and the foreign twin.
const DER_PREFIX = "308182301d060d2b0601040182dc7c0503010201060c2b0601040182dc7c05030201036100";
const ROOT_KEY_A = DER_PREFIX
  + "a587ac27884f235a91ddd86927eec11e09872417231b41ab8fb95605c633af9702849c0ad6929613392b39c715fc232c"
  + "0a0d8eb00a1ea91985b3e440bc9d0b78a5872f96dae753f395cd6602516ad58748d698958976c6c25b86c55aa30a3af9";
const ROOT_KEY_B = DER_PREFIX + "b1".repeat(96);
const ROOT_KEY_C = DER_PREFIX + "c2".repeat(96);

// The six ids every local replica draws, in seat-2's permutation …
const VENUE_A = {
  arb: "4zfnl-5t777-77775-aaadq-cai",
  backend: "4qggx-l3777-77775-aaaca-cai",
  bridge: "4caro-hl777-77775-aaaba-cai",
  frontend: "46el7-ql777-77775-aaada-cai",
  "fuel-mock": "4xhad-gd777-77775-aaacq-cai",
  "xrc-mock": "4fbx2-kt777-77775-aaabq-cai",
};
// … and in another venue's permutation (seat-3 and seat-4 both drew frontend
// 4xhad…; the rest is one such permutation).
const VENUE_B = {
  arb: "4caro-hl777-77775-aaaba-cai",
  backend: "4zfnl-5t777-77775-aaadq-cai",
  bridge: "4fbx2-kt777-77775-aaabq-cai",
  frontend: "4xhad-gd777-77775-aaacq-cai",
  "fuel-mock": "4qggx-l3777-77775-aaaca-cai",
  "xrc-mock": "46el7-ql777-77775-aaada-cai",
};
// The open-saas twin as the doc captured it: its own `backend` + `frontend`
// (frontend drew OUR 4xhad… id) plus workspace-injected `<service>:backend`
// dependency ids; no bridge, no arb.
const TWIN = {
  backend: "6r7so-pt777-77775-aaapq-cai",
  frontend: "4xhad-gd777-77775-aaacq-cai",
  "open-team:backend": "6s5lk-ut777-77775-aaapa-cai",
  "open-directory:backend": "6tbqz-hx777-77775-aaaoq-cai",
};
// The live subnet's cookie key set (curl -sI https://multidex.ai/, 2026-11-01):
// exactly backend, bridge, frontend, arb — NO mocks. The key-set rule must
// accept it, or production would fall back to a meta tag index.html lacks.
const SUBNET = {
  arb: "hxsn7-viaaa-aaabq-qaacq-cai",
  backend: "hmxr2-pqaaa-aaabq-qaaaa-cai",
  bridge: "hlwxo-ciaaa-aaabq-qaaaq-cai",
  frontend: "hcv4s-uaaaa-aaabq-qaaba-cai",
};

// The asset canister percent-encodes everything but alphanumerics (`_`→%5F,
// `-`→%2D, `:`→%3A, `=`→%3D, `&`→%26); encodeURIComponent leaves -_.!~*'()
// bare, so finish the job. Proven against a captured header below.
const canisterEncode = (s) => encodeURIComponent(s).replace(/[-_.!~*'()]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
const pairsOf = (ids, rootKey) => [
  ...(rootKey ? [["ic_root_key", rootKey]] : []),
  ...Object.keys(ids).sort().map((n) => [`PUBLIC_CANISTER_ID:${n}`, ids[n]]),
];
const envValue = (ids, rootKey, enc = canisterEncode) => enc(pairsOf(ids, rootKey).map(([k, v]) => `${k}=${v}`).join("&"));
const row = (ids, rootKey, enc) => "ic_env=" + envValue(ids, rootKey, enc);

const ROW_A = row(VENUE_A, ROOT_KEY_A);
const ROW_B = row(VENUE_B, ROOT_KEY_B);
const ROW_TWIN = row(TWIN, ROOT_KEY_C);
const ROW_SUBNET = row(SUBNET, ROOT_KEY_B);
// document.cookie joins rows with "; ", same-named cookies included.
const JAR_TWIN_FIRST = `${ROW_TWIN}; ${ROW_B}`;
const JAR_TWO_VENUES_B_FIRST = `mdx.theme=dark; ${ROW_B}; ${ROW_A}`;
const JAR_SINGLE = ROW_A;
const JAR_NONE = "mdx.theme=dark; mdx.tab=markets";
const JAR_EMPTY_VALUE = "ic_env=; mdx.theme=dark";

// The static-site (certified-assets) canister — the frontend's host since task
// 1793503326 — sets ONE value as TWO rows: `Path=/; Secure; SameSite=Lax` and
// `Path=/; Secure; SameSite=None; Partitioned`. Captured 2026-11-01 at the
// scratch probe through a unique host name (docs/seat-venue-bring-up.md item
// 4): cookieStore.getAll({name:"ic_env"}) = [{partitioned:false, sameSite:
// "lax", secure:true, path:"/"}, {partitioned:true, sameSite:"none",
// secure:true, path:"/"}], document.cookie the same order. P is the probe's
// permutation of the six ids (its backend happens to equal A's — 4qggx — the
// bridge and frontend differ, which is what the picker is judged on).
const VENUE_P = {
  arb: "4fbx2-kt777-77775-aaabq-cai",
  backend: "4qggx-l3777-77775-aaaca-cai",
  bridge: "46el7-ql777-77775-aaada-cai",
  frontend: "4zfnl-5t777-77775-aaadq-cai",
  "fuel-mock": "4caro-hl777-77775-aaaba-cai",
  "xrc-mock": "4xhad-gd777-77775-aaacq-cai",
};
const ROW_P = row(VENUE_P, ROOT_KEY_C);
const JAR_STATIC_SITE_PAIR = `${ROW_P}; ${ROW_P}`;
// The MIXED FLEET, as captured: the probe's static-site venue visited at the
// shared name, then seat-2's LEGACY venue (asset canister, one `SameSite=Lax`
// row, not Secure) at the same name. The legacy row replaced the static-site
// Lax row; the Partitioned row survived and listed FIRST in cookieStore and in
// document.cookie: [{partitioned:true, frontend 4zfnl…, bridge 46el7…},
// {partitioned:false, secure:false, frontend 46el7…, bridge 4caro…}]. Both rows
// carry our key set, and the name host carries no id.
const JAR_MIXED_FLEET = `${ROW_P}; ${ROW_A}`;
// The same shape with a venue whose BACKEND differs too (synthetic — B).
const JAR_MIXED_FLEET_B = `${ROW_B}; ${ROW_A}`;

const ID_HOST_A = `${VENUE_A.frontend}.localhost`;
const ID_HOST_B = `${VENUE_B.frontend}.localhost`;
const NAME_HOST = "frontend.local.localhost";

// The exact Set-Cookie value seat-2's venue served on 2026-11-01 (curl -sI
// http://frontend.local.localhost:59587/), root key elided to its prefix.
const CAPTURED_PREFIX = "ic%5Froot%5Fkey%3D308182301d060d2b0601040182dc7c0503010201060c2b0601040182dc7c05030201036100";
const CAPTURED_TAIL = "%26PUBLIC%5FCANISTER%5FID%3Aarb%3D4zfnl%2D5t777%2D77775%2Daaadq%2Dcai%26PUBLIC%5FCANISTER%5FID%3Abackend%3D4qggx%2Dl3777%2D77775%2Daaaca%2Dcai%26PUBLIC%5FCANISTER%5FID%3Abridge%3D4caro%2Dhl777%2D77775%2Daaaba%2Dcai%26PUBLIC%5FCANISTER%5FID%3Afrontend%3D46el7%2Dql777%2D77775%2Daaada%2Dcai%26PUBLIC%5FCANISTER%5FID%3Afuel%2Dmock%3D4xhad%2Dgd777%2D77775%2Daaacq%2Dcai%26PUBLIC%5FCANISTER%5FID%3Axrc%2Dmock%3D4fbx2%2Dkt777%2D77775%2Daaabq%2Dcai";

const hexOf = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

// ── A. canister-env.js imports and parses the real cookie shape ─────
console.log("A. canister-env.js — the module, the fixtures, the SDK beside it");
let ce = null;
try {
  ce = await import(pathToFileURL(path("src/frontend/src/canister-env.js")).href);
  ok("canister-env.js imports without a DOM");
} catch (e) {
  bad("canister-env.js imports without a DOM", e?.stack || e);
}
for (const fn of ["readCanisterEnv", "inspectCanisterEnv", "parseCanisterEnvRows", "parseCanisterEnvValue", "pickCanisterEnvRow", "idHostCanisterId", "servedByFrontendId", "isCanisterEnvMismatchReject", "hexToBytes"]) {
  check(`canister-env.js exports ${fn}`, typeof ce?.[fn] === "function");
}
check("OUR_CANISTER_KEYS is the set every environment deploys: backend, bridge, frontend, arb",
  Array.isArray(ce?.OUR_CANISTER_KEYS) && [...ce.OUR_CANISTER_KEYS].sort().join(",") === "arb,backend,bridge,frontend",
  JSON.stringify(ce?.OUR_CANISTER_KEYS));

check("fixture root keys are 133 bytes (266 hex chars)", [ROOT_KEY_A, ROOT_KEY_B, ROOT_KEY_C].every((k) => k.length === 266));
check("the fixture encoder reproduces the asset canister's captured Set-Cookie byte for byte",
  envValue(VENUE_A, ROOT_KEY_A).startsWith(CAPTURED_PREFIX) && envValue(VENUE_A, ROOT_KEY_A).endsWith(CAPTURED_TAIL)
    && envValue(VENUE_A, ROOT_KEY_A).length === CAPTURED_PREFIX.length + (266 - DER_PREFIX.length) + CAPTURED_TAIL.length);

let sdk = null;
try {
  sdk = await import("@icp-sdk/core/agent/canister-env");
  ok("@icp-sdk/core/agent/canister-env imports in node (parity oracle)");
} catch (e) {
  bad("@icp-sdk/core/agent/canister-env imports in node (parity oracle)", e?.message || e);
}
// The SDK reads globalThis.document.cookie; lend it one for the duration.
function sdkRead(jar) {
  const prev = globalThis.document;
  globalThis.document = { cookie: jar };
  try { return sdk.safeGetCanisterEnv(); } finally {
    if (prev === undefined) delete globalThis.document; else globalThis.document = prev;
  }
}

if (ce && sdk) {
  // Parity on a single well-formed row, both encodings.
  for (const [label, jar] of [["canister encoding", JAR_SINGLE], ["plain encodeURIComponent", row(VENUE_A, ROOT_KEY_A, encodeURIComponent)]]) {
    const theirs = sdkRead(jar);
    const ours = ce.readCanisterEnv(jar, NAME_HOST);
    check(`parity (${label}): same key set as the SDK`,
      theirs && ours && Object.keys(theirs).sort().join("|") === Object.keys(ours).sort().join("|"),
      `sdk=${theirs && Object.keys(theirs).sort()} ours=${ours && Object.keys(ours).sort()}`);
    check(`parity (${label}): same root key bytes`, theirs && ours && hexOf(theirs.IC_ROOT_KEY) === hexOf(ours.IC_ROOT_KEY) && hexOf(ours.IC_ROOT_KEY) === ROOT_KEY_A);
    check(`parity (${label}): same canister ids`, theirs && ours && Object.keys(VENUE_A).every((n) => theirs[`PUBLIC_CANISTER_ID:${n}`] === VENUE_A[n] && ours[`PUBLIC_CANISTER_ID:${n}`] === VENUE_A[n]));
  }
  // The failure, stated by the oracle. core 5.x's first-row read picked the
  // twin (IC0301 "Canister not found" — the shape this suite exists for);
  // core 6.1.1 (task 1787222434) reads every copy and REFUSES a jar whose
  // copies disagree: safeGetCanisterEnv answers undefined — no root key, no
  // ids, nothing works. Either way the SDK alone leaves the app dead at this
  // jar, and the picker (section B) is still what answers it.
  const sdkTwin = sdkRead(JAR_TWIN_FIRST);
  check("the SDK alone cannot serve the twin-first jar: core 6.1.1 refuses the disagreeing ic_env copies (undefined; 5.x picked the twin's backend) — the IC0301 shape this suite exists for",
    sdkTwin === undefined, JSON.stringify(sdkTwin?.["PUBLIC_CANISTER_ID:backend"] ?? sdkTwin));
  // Parity on refusals: every jar the SDK answers `undefined` to, we do too
  // (when it is the only row), and vice versa.
  const refusals = {
    "no ic_env row": JAR_NONE,
    "empty value": JAR_EMPTY_VALUE,
    "odd-length root key hex": row(VENUE_A, ROOT_KEY_A.slice(0, -1)),
    "non-hex root key": row(VENUE_A, "zz" + ROOT_KEY_A.slice(2)),
    "132-byte root key": row(VENUE_A, ROOT_KEY_A.slice(0, -2)),
    "134-byte root key": row(VENUE_A, ROOT_KEY_A + "ff"),
    "no root key at all": row(VENUE_A, null),
    "undecodable percent sequence": "ic_env=ic%5Froot%5Fkey%3D" + ROOT_KEY_A + "%26PUBLIC%5FCANISTER%5FID%3Abackend%3D%E0%A4%A",
  };
  for (const [label, jar] of Object.entries(refusals)) {
    const theirs = sdkRead(jar);
    const ours = ce.readCanisterEnv(jar, NAME_HOST);
    check(`refusal parity (${label}): SDK undefined, ours undefined`, theirs === undefined && ours === undefined,
      `sdk=${theirs && "env"} ours=${ours && "env"}`);
  }
}

// ── B. the row-picker ───────────────────────────────────────────────
console.log("\nB. readCanisterEnv — picks OUR row, not the first");
if (ce) {
  const be = (env) => env?.["PUBLIC_CANISTER_ID:backend"];

  // (a) the foreign twin listed first, at the id host and at the name host.
  check("twin-first @ id host 4xhad…: the multidex row wins (backend = that venue's)", be(ce.readCanisterEnv(JAR_TWIN_FIRST, ID_HOST_B)) === VENUE_B.backend);
  check("twin-first @ id host: the root key is the multidex row's, not the twin's", hexOf(ce.readCanisterEnv(JAR_TWIN_FIRST, ID_HOST_B).IC_ROOT_KEY) === ROOT_KEY_B);
  check("twin-first @ the name host: the key-set rule alone still picks the multidex row", be(ce.readCanisterEnv(JAR_TWIN_FIRST, NAME_HOST)) === VENUE_B.backend);
  check("twin-first with the rows reversed (ours first) picks ours too", be(ce.readCanisterEnv(`${ROW_B}; ${ROW_TWIN}`, ID_HOST_B)) === VENUE_B.backend);
  {
    const d = ce.inspectCanisterEnv(JAR_TWIN_FIRST, ID_HOST_B);
    check("inspect: two rows, the twin not ours, its foreign keys named", d.rows.length === 2 && d.rows[0].ours === false && d.rows[1].ours === true
      && d.rows[0].foreignKeys.sort().join(",") === "open-directory:backend,open-team:backend", JSON.stringify(d.rows.map((r) => [r.ours, r.foreignKeys])));
    check("inspect: the twin's frontend id equals the host id (why the host rule alone could not have saved us)", d.hostId === VENUE_B.frontend && d.rows[0].frontendId === d.hostId);
    check("inspect: contested is true", d.contested === true);
    check("inspect: rows carry no raw cookie text", d.rows.every((r) => !("raw" in r)) && !JSON.stringify(d.rows).includes("ic%5F"));
  }

  // Two multidex rows from different venues (B listed first).
  check("two venues @ A's id host: A's row wins though B lists first", be(ce.readCanisterEnv(JAR_TWO_VENUES_B_FIRST, ID_HOST_A)) === VENUE_A.backend);
  check("two venues @ B's id host: B's row wins", be(ce.readCanisterEnv(JAR_TWO_VENUES_B_FIRST, ID_HOST_B)) === VENUE_B.backend);
  check("two venues @ the name host: cookie order (the SDK's rule) — the first listed; the self-heal covers this flavour", be(ce.readCanisterEnv(JAR_TWO_VENUES_B_FIRST, NAME_HOST)) === VENUE_B.backend);
  check("two venues @ an id host neither row served: cookie order", be(ce.readCanisterEnv(JAR_TWO_VENUES_B_FIRST, "aaaaa-bbbbb-ccccc-ddddd-cai.localhost")) === VENUE_B.backend);
  check("the id-host rule is case-insensitive on the host", be(ce.readCanisterEnv(JAR_TWO_VENUES_B_FIRST, ID_HOST_A.toUpperCase())) === VENUE_A.backend);
  check("an id host on a gateway domain is an id host too", ce.idHostCanisterId("hcv4s-uaaaa-aaabq-qaaba-cai.icp0.io") === "hcv4s-uaaaa-aaabq-qaaba-cai");
  check("friendly names are not id hosts", ce.idHostCanisterId(NAME_HOST) === null && ce.idHostCanisterId("multidex.ai") === null && ce.idHostCanisterId("localhost") === null && ce.idHostCanisterId("") === null);
  check("a look-alike host (4 groups + cai but no dot after) is not an id host", ce.idHostCanisterId("46el7-ql777-77775-aaada-cai") === null);

  // A single row.
  {
    const env = ce.readCanisterEnv(JAR_SINGLE, NAME_HOST);
    check("single row: picked, all six ids present", env && Object.keys(VENUE_A).every((n) => env[`PUBLIC_CANISTER_ID:${n}`] === VENUE_A[n]));
    check("single row: IC_ROOT_KEY is a 133-byte Uint8Array of the hex", env?.IC_ROOT_KEY instanceof Uint8Array && env.IC_ROOT_KEY.length === 133 && hexOf(env.IC_ROOT_KEY) === ROOT_KEY_A);
    check("single row: the raw ic_root_key hex is not also exposed (the SDK renames it)", env && !("ic_root_key" in env));
  }
  check("the live subnet's four-key cookie counts as OURS (production never falls back to the missing meta tag)",
    ce.parseCanisterEnvRows(ROW_SUBNET)[0]?.ours === true && be(ce.readCanisterEnv(`${ROW_TWIN}; ${ROW_SUBNET}`, "hcv4s-uaaaa-aaabq-qaaba-cai.icp0.io")) === SUBNET.backend);
  check("prefer, never reject: a lone row lacking our key set is still used (what the SDK would do)", be(ce.readCanisterEnv(ROW_TWIN, ID_HOST_B)) === TWIN.backend);

  // No row.
  check("no ic_env row: undefined (callers keep the meta fallback)", ce.readCanisterEnv(JAR_NONE, NAME_HOST) === undefined);
  check("empty string: undefined", ce.readCanisterEnv("", NAME_HOST) === undefined);
  check("`ic_env=` with an empty value: undefined", ce.readCanisterEnv(JAR_EMPTY_VALUE, NAME_HOST) === undefined);
  check("a cookie merely PREFIXED ic_env (ic_envx=) is not the cookie", ce.readCanisterEnv("ic_envx=" + envValue(VENUE_A, ROOT_KEY_A), NAME_HOST) === undefined);
  check("no arguments and no DOM: undefined, no throw", (() => { try { return ce.readCanisterEnv() === undefined; } catch { return false; } })());

  // A malformed root key.
  const malformedOnly = row(VENUE_B, ROOT_KEY_B.slice(0, -2));
  check("malformed root key alone: undefined", ce.readCanisterEnv(malformedOnly, ID_HOST_B) === undefined);
  check("malformed root key alone: the row is reported invalid with the reason", (() => {
    const r = ce.parseCanisterEnvRows(malformedOnly)[0];
    return r && r.valid === false && /132 bytes, expected 133/.test(r.error) && r.env === undefined;
  })());
  check("malformed FIRST, good second: the good row is used (the SDK would have returned undefined — one broken row must not take the jar down)",
    be(ce.readCanisterEnv(`${malformedOnly}; ${ROW_A}`, NAME_HOST)) === VENUE_A.backend);
  check("good first, malformed second: the good row, and the malformed one is still listed as invalid",
    (() => { const d = ce.inspectCanisterEnv(`${ROW_A}; ${malformedOnly}`, NAME_HOST); return be(d.env) === VENUE_A.backend && d.rows.length === 2 && d.rows[1].valid === false; })());
  check("odd-length hex names the noble error shape", /unpadded hex/.test(ce.parseCanisterEnvValue(envValue(VENUE_A, ROOT_KEY_A.slice(0, -1))).error || ""));
  check("non-hex names the offending character", /non-hex character/.test(ce.parseCanisterEnvValue(envValue(VENUE_A, "zz" + ROOT_KEY_A.slice(2))).error || ""));

  // SDK quirks mirrored.
  check("a later duplicate key wins (Object.fromEntries)", (() => {
    const v = canisterEncode(`ic_root_key=${ROOT_KEY_A}&PUBLIC_CANISTER_ID:backend=first-id&PUBLIC_CANISTER_ID:backend=${VENUE_A.backend}`);
    return be(ce.readCanisterEnv("ic_env=" + v, NAME_HOST)) === VENUE_A.backend;
  })());
  check("a pair with no `=` parses the SDK's way (key = pair minus its last char, value = the pair) and does not break the row", (() => {
    const v = canisterEncode(`ic_root_key=${ROOT_KEY_A}&junk&PUBLIC_CANISTER_ID:backend=${VENUE_A.backend}`);
    const env = ce.readCanisterEnv("ic_env=" + v, NAME_HOST);
    return be(env) === VENUE_A.backend && env.jun === "junk";
  })());
  check("hexToBytes: accepts upper-case hex", hexOf(ce.hexToBytes("ABcd01")) === "abcd01");
  check("hexToBytes: rejects a non-string", (() => { try { ce.hexToBytes(12); return false; } catch { return true; } })());
}

// ── B2. the static-site pair, the mixed fleet, the served-by stamp ─────
console.log("\nB2. two rows per venue (static-site Lax + Partitioned), the mixed fleet at the shared name, the served-by stamp");
if (ce) {
  const be = (env) => env?.["PUBLIC_CANISTER_ID:backend"];
  const br = (env) => env?.["PUBLIC_CANISTER_ID:bridge"];
  // (1) one venue, one value, two rows.
  {
    const d = ce.inspectCanisterEnv(JAR_STATIC_SITE_PAIR, NAME_HOST);
    check("static-site pair @ name host: both rows ours, the first picked, P's ids", d.rows.length === 2 && d.rows.every((r) => r.ours) && d.picked.index === 0 && be(d.env) === VENUE_P.backend && br(d.env) === VENUE_P.bridge);
    check("static-site pair: NOT contested (one value twice is no contest)", d.contested === false);
    check("static-site pair: both rows share one idsSignature naming the frontend", d.rows[0].idsSignature === d.rows[1].idsSignature && d.rows[0].idsSignature.includes(`frontend=${VENUE_P.frontend}`));
    check("static-site pair @ P's id host: the same answer", be(ce.readCanisterEnv(JAR_STATIC_SITE_PAIR, `${VENUE_P.frontend}.localhost`)) === VENUE_P.backend);
  }
  // (2) the mixed fleet at the shared name: the Partitioned row of another venue lists first.
  {
    const d0 = ce.inspectCanisterEnv(JAR_MIXED_FLEET, NAME_HOST);
    check("mixed fleet @ name host, NO stamp: cookie order — the other venue's Partitioned row wins (the hazard the stamp exists for)", d0.picked.index === 0 && br(d0.env) === VENUE_P.bridge && d0.want === null);
    check("mixed fleet: contested (two venues' ids in one jar)", d0.contested === true);
    const d1 = ce.inspectCanisterEnv(JAR_MIXED_FLEET, NAME_HOST, VENUE_A.frontend);
    check("mixed fleet @ name host, stamp = THIS venue's frontend: this venue's row wins (bridge and backend ours)", d1.picked.index === 1 && br(d1.env) === VENUE_A.bridge && be(d1.env) === VENUE_A.backend && d1.want === VENUE_A.frontend && d1.servedBy === VENUE_A.frontend);
    check("mixed fleet with a differing backend (B's static-site row first): no stamp -> B's backend; stamp -> ours", be(ce.readCanisterEnv(JAR_MIXED_FLEET_B, NAME_HOST)) === VENUE_B.backend && be(ce.readCanisterEnv(JAR_MIXED_FLEET_B, NAME_HOST, VENUE_A.frontend)) === VENUE_A.backend);
    check("mixed fleet @ a custom domain (the multidex.ai shape): the stamp is what picks", be(ce.readCanisterEnv(JAR_MIXED_FLEET_B, "multidex.ai", VENUE_A.frontend)) === VENUE_A.backend);
    check("the stamp is case-insensitive", be(ce.readCanisterEnv(JAR_MIXED_FLEET_B, NAME_HOST, VENUE_A.frontend.toUpperCase())) === VENUE_A.backend);
    check("a stamp matching no row: cookie order, no throw", be(ce.readCanisterEnv(JAR_MIXED_FLEET_B, NAME_HOST, "aaaaa-bbbbb-ccccc-ddddd-cai")) === VENUE_B.backend);
    check("a stamp that is not a canister id is ignored (placeholder, empty, null)", be(ce.readCanisterEnv(JAR_MIXED_FLEET_B, NAME_HOST, "place-deployed-canister-id-here")) === VENUE_B.backend && be(ce.readCanisterEnv(JAR_MIXED_FLEET_B, NAME_HOST, "")) === VENUE_B.backend && be(ce.readCanisterEnv(JAR_MIXED_FLEET_B, NAME_HOST, null)) === VENUE_B.backend);
    check("the stamp never outranks the key-set rule (a foreign twin naming our frontend id still loses to our row)", be(ce.readCanisterEnv(`${ROW_TWIN}; ${ROW_B}`, NAME_HOST, TWIN.frontend)) === VENUE_B.backend);
  }
  // (3) an id host outranks the stamp: the host cannot be stale, a stamp built against another mapping can.
  check("@ A's id host with a STALE stamp naming B: the host id wins", be(ce.readCanisterEnv(JAR_MIXED_FLEET_B, ID_HOST_A, VENUE_B.frontend)) === VENUE_A.backend);
  check("@ B's id host with a stamp naming A: the host id wins", be(ce.readCanisterEnv(JAR_MIXED_FLEET_B, ID_HOST_B, VENUE_A.frontend)) === VENUE_B.backend);
  check("the brief's shape: a Partitioned row FIRST at an id host still loses to the row whose frontend IS the host id", be(ce.readCanisterEnv(JAR_MIXED_FLEET, ID_HOST_A)) === VENUE_A.backend && be(ce.readCanisterEnv(JAR_MIXED_FLEET, `${VENUE_P.frontend}.localhost`)) === VENUE_P.backend);
  // (4) servedByFrontendId reads the build's stamp from the document.
  {
    const docWith = (content) => ({
      cookie: JAR_MIXED_FLEET_B,
      querySelector: (sel) => (sel === `meta[name="${ce.SERVED_BY_META}"]` ? { getAttribute: (a) => (a === "content" ? content : null) } : null),
    });
    check("SERVED_BY_META is mdx:frontend-canister-id", ce.SERVED_BY_META === "mdx:frontend-canister-id");
    check("servedByFrontendId reads the stamp", ce.servedByFrontendId(docWith(VENUE_A.frontend)) === VENUE_A.frontend);
    check("servedByFrontendId: no meta -> null", ce.servedByFrontendId({ querySelector: () => null }) === null);
    check("servedByFrontendId: the ai-connect placeholder -> null", ce.servedByFrontendId(docWith("place-deployed-canister-id-here")) === null);
    check("servedByFrontendId: no document -> null, no throw", ce.servedByFrontendId(undefined) === null && ce.servedByFrontendId(null) === null);
    // readCanisterEnv() with NO arguments — what main.js's eight sites call —
    // reads the jar, the host and the stamp from the document.
    const prevDoc = globalThis.document, prevLoc = globalThis.location;
    globalThis.document = docWith(VENUE_A.frontend);
    globalThis.location = { hostname: NAME_HOST };
    try {
      check("readCanisterEnv() with no arguments: the document's jar + stamp at the name host -> this venue's row", be(ce.readCanisterEnv()) === VENUE_A.backend);
    } finally {
      if (prevDoc === undefined) delete globalThis.document; else globalThis.document = prevDoc;
      if (prevLoc === undefined) delete globalThis.location; else globalThis.location = prevLoc;
    }
  }
  // (5) the build stamps it; the committed source does not hardcode it.
  {
    const vite = read("vite.config.mjs") || "";
    check("vite.config.mjs stamps <meta name=\"mdx:frontend-canister-id\"> into index.html (bakeFrontendCanisterId, from resolveCanisterId(\"frontend\"), registered)",
      /function bakeFrontendCanisterId\(\)/.test(vite) && /name: "mdx:frontend-canister-id", content: id/.test(vite) && /resolveCanisterId\("frontend"\)/.test(vite) && /bakeFrontendCanisterId\(\)\]/.test(vite));
    check("the stamp's meta name is the one canister-env.js reads", vite.includes(`name: "${ce.SERVED_BY_META}"`));
    check("the committed index.html carries NO hardcoded stamp (ids differ per venue; the build stamps it)", !(read("src/frontend/index.html") || "").includes("mdx:frontend-canister-id"));
    check("an unresolved id stamps nothing and warns (a fresh venue's first build), never a placeholder", /return \[\];/.test(vite) && /console\.warn\(\s*"\[frontend-canister-id\]/.test(vite));
  }
}

// ── C. the self-heal trigger's classifier ───────────────────────────
console.log("\nC. isCanisterEnvMismatchReject — IC0301 / IC0536 and nothing else");
if (ce) {
  const sdkShaped = (text, code) =>
    `The replica returned a rejection error:\n  Request ID: 0123abcd\n  Reject code: 3\n  Reject text: ${text}\n  Error code: ${code}\n`;
  const yes = {
    "IC0301 canister not found (the twin's backend)": sdkShaped(`Canister ${TWIN.backend} not found`, "IC0301"),
    "IC0536 no query method (our xrc-mock asked for getMarkets)": sdkShaped(`IC0536: Canister ${VENUE_A["xrc-mock"]} has no query method 'getMarkets'`, "IC0536"),
    "IC0536 for getCanisterInfo": sdkShaped(`Canister ${VENUE_A["fuel-mock"]} has no query method 'getCanisterInfo'`, "IC0536"),
    "bare reject text, no code line": `Canister ${TWIN.backend} not found`,
    "bare error code": "Error code: IC0301",
  };
  for (const [label, msg] of Object.entries(yes)) check(`matches: ${label}`, ce.isCanisterEnvMismatchReject(msg) === true);
  const no = {
    "IC0207 frozen / out of cycles": sdkShaped(`Canister ${VENUE_A.backend} is out of cycles: please top up the canister`, "IC0207"),
    "a trap inside our own backend": sdkShaped(`Canister ${VENUE_A.backend} trapped explicitly: assertion failed`, "IC0503"),
    "an unreachable replica": "TypeError: Failed to fetch",
    "a certificate failure": "Invalid certificate: Signature verification failed",
    "an unrelated 'not found' (a method, not a canister)": "Query method 'getFoo' not found on actor",
    "empty / null / undefined": "",
  };
  for (const [label, msg] of Object.entries(no)) check(`does not match: ${label}`, ce.isCanisterEnvMismatchReject(msg) === false);
  check("does not match: null", ce.isCanisterEnvMismatchReject(null) === false);
  check("does not match: undefined", ce.isCanisterEnvMismatchReject(undefined) === false);
}

// ── D. main.js — the eight reads, the one-shot heal, the banner ─────
console.log("\nD. main.js — every env read goes through readCanisterEnv; the heal is one-shot; the banner names the cookie");
{
  const rawMain = must("src/frontend/src/main.js");
  const main = rawMain === null ? null : stripJsComments(rawMain);
  if (main) {
    check("main.js imports readCanisterEnv + isCanisterEnvMismatchReject from ./canister-env.js",
      /import\s*\{[^}]*\breadCanisterEnv\b[^}]*\}\s*from\s*["']\.\/canister-env\.js["']/.test(main)
      && /import\s*\{[^}]*\bisCanisterEnvMismatchReject\b[^}]*\}\s*from\s*["']\.\/canister-env\.js["']/.test(main));
    check("main.js no longer calls the SDK's first-row safeGetCanisterEnv anywhere", !/safeGetCanisterEnv/.test(main));
    check("main.js no longer imports @icp-sdk/core/agent/canister-env itself", !/@icp-sdk\/core\/agent\/canister-env/.test(main));

    // The eight sites, by name.
    const sites = [
      ["getRawAgent (Ledger page raw agent)", "const getRawAgent = async () =>"],
      ["getCanisterId", "async function getCanisterId()"],
      ["createAnonymousActor", "async function createAnonymousActor()"],
      ["setupActor", "async function setupActor()"],
      ["getBridgeActor", "async function getBridgeActor()"],
      ["presentAttributesToBackend", "async function presentAttributesToBackend(attributes)"],
      ["mintNonceEphemeral", "async function mintNonceEphemeral()"],
      ["getPublicArchiveActor", "async function getPublicArchiveActor(archiveId)"],
    ];
    for (const [label, header] of sites) {
      const body = funcBodyL(main, header);
      check(`${label} reads the env through readCanisterEnv()`, body !== null && /\breadCanisterEnv\(\)/.test(body), body === null ? `header not found: ${header}` : undefined);
    }
    const metaFallbacks = (main.match(/meta\[name="canister-id"\]/g) || []).length;
    check("the meta[name=\"canister-id\"] fallback is kept at every id read (≥ 6 occurrences)", metaFallbacks >= 6, `${metaFallbacks} occurrences`);
    for (const header of ["async function createAnonymousActor()", "async function setupActor()"]) {
      const body = funcBodyL(main, header) || "";
      check(`${header.split(" ")[2]} records the backend id the actor was bound to (_boundBackendId)`, /_boundBackendId = canisterId;/.test(body));
    }
    check("the Ledger raw agent rebuilds when the env generation moves (stale root key cannot outlive a heal)",
      /rawAgent && rawAgentGen === _canisterEnvGeneration/.test(main) && /rawActors\.clear\(\)/.test(main) && /rawAgentGen = _canisterEnvGeneration;/.test(main));

    // The heal.
    const heal = funcBodyL(main, "async function healCanisterEnvOnce(") || "";
    check("healCanisterEnvOnce exists", heal.length > 0);
    const guardAt = heal.indexOf("if (_envHealTried) return false;");
    const setAt = heal.indexOf("_envHealTried = true;");
    const fetchAt = heal.indexOf("await fetch(location.pathname, { cache: \"reload\", credentials: \"same-origin\" })");
    check("the heal is one-shot: the tried-flag is checked, then set, BEFORE the re-fetch", guardAt >= 0 && setAt > guardAt && fetchAt > setAt, `guard@${guardAt} set@${setAt} fetch@${fetchAt}`);
    check("the re-fetch is same-origin with cache: \"reload\" (the one request shape that applies a fresh Set-Cookie)", fetchAt >= 0);
    check("the heal re-reads the env and compares the backend id against the bound one", /readCanisterEnv\(\)/.test(heal) && /now === was/.test(heal));
    check("the heal rebuilds the anonymous actor and, when signed in, the identity-bound one", /await createAnonymousActor\(\);/.test(heal) && /if \(identity\) await setupActor\(\);/.test(heal));
    check("the heal invalidates the lazily-built ids/agents (bridge id, public archive actor, env generation)", /_bridgeId = null;/.test(heal) && /_pubArchiveActor = null;/.test(heal) && /_canisterEnvGeneration \+= 1;/.test(heal));
    check("the heal logs exactly one console.info naming old -> new (and one for the no-change outcome)", (heal.match(/console\.info\(/g) || []).length === 2 && /-> \$\{now\}/.test(heal));
    check("the heal never loops: no setInterval / setTimeout / while / recursion inside it", !/setInterval|setTimeout|\bwhile\b|healCanisterEnvOnce\(/.test(heal));
    const handler = funcBodyL(main, "async function handleCanisterEnvMismatch(") || "";
    check("handleCanisterEnvMismatch heals once, names the outcome in the banner, and re-fetches markets only when healed",
      (handler.match(/healCanisterEnvOnce\(/g) || []).length === 1 && /updateFuelBannerUnreachable\("cookie", msg, \{ backendId: usedId, healed: healed \? _envHealed : null \}\)/.test(handler) && /if \(healed\) refreshMarkets\(\);/.test(handler));
    check("the handler captures the WRONG id before healing (the banner names the id the page actually called)", handler.indexOf("const usedId = _boundBackendId;") >= 0 && handler.indexOf("const usedId = _boundBackendId;") < handler.indexOf("healCanisterEnvOnce("));

    // The trigger points.
    const poll = funcBodyL(main, "async function refreshCanisterInfo()") || "";
    check("refreshCanisterInfo classifies IC0301/IC0536 BEFORE the 3-strike network verdict", (() => {
      const a = poll.indexOf("isCanisterEnvMismatchReject(msg)");
      const b = poll.indexOf("canisterInfoFailures >= 3");
      return a >= 0 && b > a && /handleCanisterEnvMismatch\(e, "getCanisterInfo"\)/.test(poll);
    })());
    check("refreshCanisterInfo still names a frozen canister first (IC0207 outranks the cookie rule)", poll.indexOf("frozenOutOfCycles") >= 0 && poll.indexOf("if (frozenOutOfCycles)") < poll.indexOf("isCanisterEnvMismatchReject(msg)"));
    const markets = funcBodyL(main, "async function refreshMarkets()") || "";
    check("refreshMarkets hands a mismatch reject to the same handler", /isCanisterEnvMismatchReject\(e\?\.message \?\? e\)/.test(markets) && /handleCanisterEnvMismatch\(e, "getMarkets"\)/.test(markets));

    // The banner.
    const banner = funcBodyL(main, "async function updateFuelBannerUnreachable(cause, msg, extra = {})") || "";
    check("updateFuelBannerUnreachable takes the cookie cause with the offending id", banner.length > 0 && /cause === "cookie"/.test(banner) && /extra\.backendId/.test(banner));
    const phrase = /this page read another venue's <code>ic_env<\/code> cookie \(backend <code class="fuel-banner-id">\$\{cid\}<\/code>\)/g;
    check("the cookie banner says 'this page read another venue's ic_env cookie (backend <id>)' — in the healed and the unhealed wording", (banner.match(phrase) || []).length === 2);
    check("the cookie banner points at docs/seat-venue-bring-up.md", (banner.match(/see docs\/seat-venue-bring-up\.md/g) || []).length >= 2);
    check("the cookie banner names the reject code it saw", /IC0301, canister not found/.test(banner) && /IC0536, no such query method/.test(banner));
    check("the healed wording is informational, the unhealed one critical", /extra\.healed/.test(banner) && /el\.className = "fuel-banner info";/.test(banner) && /el\.className = "fuel-banner critical";/.test(banner));
    {
      const cookieBranch = banner.slice(banner.indexOf('cause === "cookie"'), banner.indexOf('cause === "cycles"'));
      check("the cookie branch never says 'network or replica issue' (the misdiagnosis this replaces)", cookieBranch.length > 0 && !/network or replica issue/.test(cookieBranch));
      check("the genuine network verdict keeps its wording for genuine network faults", /likely a network or replica issue/.test(banner));
    }
    check("the self-heal state lives at module scope", /^let _boundBackendId = null;/m.test(main) && /^let _envHealTried = false;/m.test(main) && /^let _envHealed = null;/m.test(main) && /^let _canisterEnvGeneration = 0;/m.test(main));
  }
}

// ── E. the key set is what every environment deploys ────────────────
console.log("\nE. icp.yaml — OUR_CANISTER_KEYS ⊆ every environment's canister list");
{
  const yaml = must("icp.yaml");
  if (yaml && ce?.OUR_CANISTER_KEYS) {
    const envLists = [...yaml.matchAll(/^\s+canisters:\s*\[([^\]]*)\]/gm)].map((m) => m[1].split(",").map((s) => s.trim()).filter(Boolean));
    check("icp.yaml declares at least two environments with explicit canister lists (engine, subnet)", envLists.length >= 2, `${envLists.length} lists`);
    for (const list of envLists) {
      check(`environment list [${list.join(", ")}] carries every key the picker calls ours`, ce.OUR_CANISTER_KEYS.every((k) => list.includes(k)));
    }
    const topSection = yaml.slice(0, yaml.indexOf("\nnetworks:"));
    const names = [...topSection.matchAll(/^  - name: ([a-z0-9-]+)/gm)].map((m) => m[1]);
    check("the top-level canister roster (local deploys all of it) carries every key the picker calls ours", ce.OUR_CANISTER_KEYS.every((k) => names.includes(k)), names.join(","));
    check("the picker's key set is NOT the dev-only mocks (xrc-mock / fuel-mock are absent from engine and subnet)", !ce.OUR_CANISTER_KEYS.includes("xrc-mock") && !ce.OUR_CANISTER_KEYS.includes("fuel-mock"));
  }
}

// ── F. wiring ───────────────────────────────────────────────────────
console.log("\nF. wiring");
check("tests/run_all.sh discovers *.test.mjs, so this suite rides the run", /for fe_suite in \$\(ls \*\.test\.mjs/.test(read("tests/run_all.sh") || ""));
{
  const doc = read("docs/seat-venue-bring-up.md") || "";
  check("docs/seat-venue-bring-up.md 'Browser smoke' names the picker and the self-heal (the by-hand cure is no longer the only path)", /readCanisterEnv/.test(doc) && /1793499221/.test(doc));
}

// ── Summary ─────────────────────────────────────────────────────────
console.log("");
if (failed === 0) {
  console.log(`PASS — ${passed} assertions`);
  process.exit(0);
} else {
  console.log(`FAIL — ${failed} of ${passed + failed} assertions failed`);
  process.exit(1);
}
