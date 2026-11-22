// ── The frontend canister's `ic_env` cookie, read defensively ────────────
//
// The canister that hosts this app sets `ic_env=<urlencoded k=v&k=v>` on every
// HTML 200 — a host-only session cookie carrying the replica's root key
// (`ic_root_key=<hex>`) and one `PUBLIC_CANISTER_ID:<name>=<id>` per canister
// of the deployment. Since task 1793503326 that canister is the certified-
// assets (static-site) canister, which sets the value as TWO Set-Cookie rows:
// `Path=/; Secure; SameSite=Lax` and `Path=/; Secure; SameSite=None;
// Partitioned` (the legacy asset canister set one `SameSite=Lax` row). main.js
// binds every agent and actor to the ids it reads from that cookie.
// @icp-sdk/core's `safeGetCanisterEnv()` reads EVERY `ic_env=` entry of
// `document.cookie` and, since core 6.1.1, answers NOTHING when the copies
// disagree (5.x took the FIRST) — and a cookie jar is keyed by HOST NAME, not by
// origin, so on a developer machine the jar is not always only ours: the SDK
// of the day either picked the wrong row (5.x) or refuses the whole jar
// (6.1.1, no root key, no ids), and either way the app would be dead (tasks
// 1793499221 and 1793503326, all three flavours reproduced in Chrome
// 2026-11-01, written up in docs/seat-venue-bring-up.md "Browser smoke on a
// seat venue"):
//
//   (a) a FOREIGN twin. Every local replica draws its canister ids from the
//       same deterministic pool, so another project's frontend can draw the
//       id ours has, and its static-site canister's `Partitioned` row lists
//       FIRST at `http://<id>.localhost:<port>/`. A fresh 200 of ours
//       rewrites our rows, never that one: every query goes to a canister
//       this replica never had (IC0301 "Canister not found").
//   (b) a STALE row of our own. `frontend.local.localhost` is every local
//       venue's friendly name, so venue A, then venue B, then Back serves A's
//       HTML from the back/forward cache WITHOUT a Set-Cookie, and A's bundle
//       runs on B's ids: the "backend" is one of the pool's ids in another
//       role (IC0536 "Canister has no query method"). Another tab on the same
//       host name rewriting the jar mid-session is the same flavour.
//   (c) a MIXED FLEET at the shared name. A MULTI/DEX venue on the static-site
//       canister leaves its `Partitioned` row at `frontend.local.localhost`;
//       a venue still on the legacy canister, visited next at the same name,
//       replaces the `Lax` row but cannot touch the `Partitioned` one — which
//       lists FIRST. Both rows carry our key set, so the key-set rule cannot
//       tell them apart, and the name host has no id in it.
//
// This module is the one place the cookie is read. It parses EVERY `ic_env`
// entry with the SDK's exact semantics (so a jar the SDK accepts parses the
// same here — tests/frontend_canister_env.test.mjs runs the SDK beside it),
// then PICKS a row instead of taking the first:
//
//   1. rows that carry OUR key set rank first — `PUBLIC_CANISTER_ID:backend`,
//      `:bridge`, `:frontend` and `:arb`, the four canisters every MULTI/DEX
//      environment deploys (icp.yaml: local has all six, engine and subnet
//      exactly these four — the live subnet cookie was read to confirm). A
//      foreign row carries its own project's names (open-saas: `backend`,
//      `frontend`, and workspace-injected `open-team:backend`-shaped keys)
//      and lacks ours;
//   2. the row whose `PUBLIC_CANISTER_ID:frontend` IS the canister that served
//      this page ranks next: at an id host (`<canister-id>.localhost`,
//      `<canister-id>.icp0.io`, ...) the host name says which canister that
//      is; at a friendly name or a custom domain the build says — vite.config.mjs
//      (bakeFrontendCanisterId) stamps the deploy's frontend id into
//      index.html as <meta name="mdx:frontend-canister-id">, read here through
//      `servedByFrontendId()`. The host id wins when both exist (it cannot be
//      stale; a stamp built against another mapping can). Flavour (c) is
//      resolved by this rule alone; a fresh venue's FIRST build has no mapping
//      to stamp from and falls through to 3 until its next frontend deploy;
//   3. then document.cookie order, which is what the SDK did (5.x) before it
//      started refusing a jar whose copies disagree (6.1.1).
//
// It PREFERS and never rejects: a lone row that lacks our key set is still
// used (exactly what the SDK would do), so a deployment that adds or drops a
// canister can never make the app fall back to nothing. Rows the SDK would
// throw on (undecodable value, malformed or wrong-length root key, no root
// key) are skipped rather than aborting the whole read — one stale or broken
// row must not take a good one down with it.
//
// Flavour (b) has no second row to pick, so it is handled by main.js's
// one-shot self-heal (healCanisterEnvOnce): on the first IC0301/IC0536 reject
// the page is re-fetched with `cache: "reload"` (a same-origin fetch applies
// the fresh Set-Cookie), the env is re-read through here, and the actors are
// rebuilt when the backend id changed. `isCanisterEnvMismatchReject` is that
// trigger's classifier, kept here so it is testable without a DOM.
//
// DOM-free on purpose: every entry point takes the cookie string and the host
// name as arguments (defaulting to the document's at call time), so the node
// suite can feed it the jars captured in the browser.

const COOKIE_NAME = "ic_env";
const VAR_SEPARATOR = "&";
const ASSIGNMENT = "=";
const ROOT_KEY_VAR = "ic_root_key";
const ROOT_KEY_ENV = "IC_ROOT_KEY";
const ROOT_KEY_BYTES = 133;
const ID_PREFIX = "PUBLIC_CANISTER_ID:";

// The canister names whose ids every MULTI/DEX deployment's cookie carries.
// Pinned against icp.yaml's environment lists by the suite: a name here that
// an environment does not deploy would demote that environment's own row.
export const OUR_CANISTER_KEYS = Object.freeze(["backend", "bridge", "frontend", "arb"]);

// `<canister-id>.<anything>` — five-char groups, `-cai` last, then a dot.
const ID_HOST_RE = /^([a-z0-9]{5}(?:-[a-z0-9]{5})+-cai)\./;
// The build-time stamp naming the frontend canister this page was deployed
// to (vite.config.mjs, bakeFrontendCanisterId): <meta name="mdx:frontend-canister-id"
// content="<id>">. Absent on a fresh venue's first build (no id mapping yet).
export const SERVED_BY_META = "mdx:frontend-canister-id";
const CANISTER_ID_RE = /^[a-z0-9]{5}(?:-[a-z0-9]{5})+-cai$/;

// @noble/hashes `hexToBytes`, as the SDK calls it: a string of even length,
// hex digits only (either case), else it throws. Inlined so this module has
// no dependency a node test would have to resolve.
export function hexToBytes(hex) {
  if (typeof hex !== "string") throw new Error("hex string expected, got " + typeof hex);
  const hl = hex.length;
  if (hl % 2) throw new Error("hex string expected, got unpadded hex of length " + hl);
  const out = new Uint8Array(hl / 2);
  for (let ai = 0, hi = 0; ai < out.length; ai++, hi += 2) {
    const n1 = hexNibble(hex.charCodeAt(hi));
    const n2 = hexNibble(hex.charCodeAt(hi + 1));
    if (n1 === undefined || n2 === undefined) {
      throw new Error(`hex string expected, got non-hex character "${hex[hi]}${hex[hi + 1]}" at index ${hi}`);
    }
    out[ai] = n1 * 16 + n2;
  }
  return out;
}
function hexNibble(ch) {
  if (ch >= 48 && ch <= 57) return ch - 48;        // 0-9
  if (ch >= 65 && ch <= 70) return ch - 55;        // A-F
  if (ch >= 97 && ch <= 102) return ch - 87;       // a-f
  return undefined;
}

// Parse ONE cookie value (the part after `ic_env=`, still url-encoded) with
// the SDK's `getCanisterEnv` semantics: decodeURIComponent, split on `&`,
// split each pair at its FIRST `=`, `ic_root_key` hex -> `IC_ROOT_KEY` bytes
// that must be exactly 133 long, later duplicates win, and a missing root key
// is an error. Returns { env } or { error } — never throws.
export function parseCanisterEnvValue(rawValue) {
  const value = String(rawValue ?? "").trim();
  if (!value) return { env: undefined, error: "empty cookie value" };
  let decoded;
  try { decoded = decodeURIComponent(value); }
  catch (e) { return { env: undefined, error: "undecodable cookie value: " + (e?.message || e) }; }
  const entries = [];
  for (const pair of decoded.split(VAR_SEPARATOR)) {
    // The SDK slices at indexOf("=") unconditionally; a pair with no `=` thus
    // yields key = pair minus its last char and value = the whole pair.
    // Mirrored, not corrected: fidelity to what the SDK accepts is the point.
    const at = pair.indexOf(ASSIGNMENT);
    const key = pair.slice(0, at);
    const val = pair.substring(at + 1);
    if (key === ROOT_KEY_VAR) {
      let bytes;
      try { bytes = hexToBytes(val); }
      catch (e) { return { env: undefined, error: "malformed root key: " + (e?.message || e) }; }
      if (bytes.length !== ROOT_KEY_BYTES) {
        return { env: undefined, error: `root key is ${bytes.length} bytes, expected ${ROOT_KEY_BYTES}` };
      }
      entries.push([ROOT_KEY_ENV, bytes]);
    } else {
      entries.push([key, val]);
    }
  }
  const env = Object.fromEntries(entries);
  if (!env[ROOT_KEY_ENV]) return { env: undefined, error: "no root key in cookie" };
  return { env, error: null };
}

// Every `ic_env=` entry of a document.cookie string, in order, each parsed
// and classified. `raw` is deliberately NOT kept: the parsed env is what
// callers need, and a cookie string must never leak into a log or a banner.
export function parseCanisterEnvRows(cookieString) {
  const rows = [];
  const pieces = String(cookieString ?? "").split(";");
  for (let i = 0; i < pieces.length; i++) {
    const piece = pieces[i].trim();
    if (!piece.startsWith(COOKIE_NAME + ASSIGNMENT)) continue;
    // The SDK takes `split("=")[1]`; the canister percent-encodes `=` inside
    // the value, so "everything after the first `=`" is the same string on
    // every cookie the canister can emit — and survives a raw `=` besides.
    const { env, error } = parseCanisterEnvValue(piece.slice(COOKIE_NAME.length + 1));
    const ids = {};
    const foreignKeys = [];
    if (env) {
      for (const k of Object.keys(env)) {
        if (!k.startsWith(ID_PREFIX)) continue;
        const name = k.slice(ID_PREFIX.length);
        ids[name] = env[k];
        // A workspace-injected dependency id (`<service>:backend`) is a key
        // shape no MULTI/DEX deployment emits — named in the diagnostics.
        if (name.includes(":")) foreignKeys.push(name);
      }
    }
    const ours = !!env && OUR_CANISTER_KEYS.every((k) => typeof ids[k] === "string" && ids[k].length > 0);
    const canisterNames = Object.keys(ids).sort();
    rows.push({
      index: rows.length,
      valid: !!env,
      error,
      env,
      ours,
      foreignKeys,
      backendId: ids.backend || null,
      frontendId: ids.frontend || null,
      canisterNames,
      // One venue's ids as one string: two rows of one venue (the static-site
      // canister's Lax + Partitioned pair) share it; rows of different venues
      // never do.
      idsSignature: canisterNames.map((n) => `${n}=${ids[n]}`).join("&"),
    });
  }
  return rows;
}

// The canister id a host name names, when the page is served at an id host
// (`46el7-ql777-77775-aaada-cai.localhost`, `hcv4s-uaaaa-aaabq-qaaba-cai.icp0.io`);
// null at a friendly name (`frontend.local.localhost`, `multidex.ai`).
export function idHostCanisterId(hostname) {
  const m = ID_HOST_RE.exec(String(hostname ?? "").toLowerCase());
  return m ? m[1] : null;
}

// The frontend canister the build stamped into this document (SERVED_BY_META),
// or null: no stamp (a fresh venue's first build), no DOM, or not an id.
export function servedByFrontendId(doc = globalThis.document) {
  try {
    const el = doc && typeof doc.querySelector === "function" ? doc.querySelector(`meta[name="${SERVED_BY_META}"]`) : null;
    const v = el ? String(el.getAttribute("content") || "").trim().toLowerCase() : "";
    return CANISTER_ID_RE.test(v) ? v : null;
  } catch { return null; }
}

// The ranking described at the top: ours first, then the row whose frontend
// is the canister that served this page (the id host's canister when the host
// is an id host, else the build's stamp), then cookie order. Only valid rows
// compete. `want` is the serving-canister id the second rule used, for the
// diagnostics.
export function pickCanisterEnvRow(rows, hostname, servedBy = null) {
  const hostId = idHostCanisterId(hostname);
  const stamp = servedBy ? String(servedBy).toLowerCase() : null;
  const want = hostId || (stamp && CANISTER_ID_RE.test(stamp) ? stamp : null);
  const valid = rows.filter((r) => r.valid);
  valid.sort((a, b) => {
    if (a.ours !== b.ours) return a.ours ? -1 : 1;
    const am = want !== null && a.frontendId === want;
    const bm = want !== null && b.frontendId === want;
    if (am !== bm) return am ? -1 : 1;
    return a.index - b.index;
  });
  return { row: valid[0] || null, hostId, servedBy: stamp, want };
}

// The full picture, for diagnostics (the banner, the self-heal's log line).
export function inspectCanisterEnv(cookieString, hostname, servedBy = null) {
  const rows = parseCanisterEnvRows(cookieString);
  const { row, hostId, want } = pickCanisterEnvRow(rows, hostname, servedBy);
  // Rows that DISAGREE on the ids (another venue's row beside ours), or a
  // foreign project's row: worth naming when the backend then rejects our
  // calls. The static-site canister's own Lax + Partitioned pair carries one
  // value twice and is not a contest.
  const signatures = new Set(rows.filter((r) => r.valid).map((r) => r.idsSignature));
  return {
    env: row ? row.env : undefined,
    picked: row,
    rows,
    hostId,
    servedBy: servedBy ? String(servedBy).toLowerCase() : null,
    want,
    contested: signatures.size > 1 || rows.some((r) => r.valid && !r.ours),
  };
}

// The drop-in for `safeGetCanisterEnv()`: the chosen row's env — the same
// shape ({ IC_ROOT_KEY: Uint8Array, "PUBLIC_CANISTER_ID:<name>": id, ... }) —
// or undefined when no usable row exists (callers keep their meta fallback).
// The defaults read the document at call time: its cookie jar, the page's host
// name, and the build's served-by stamp.
export function readCanisterEnv(
  cookieString = (globalThis.document && globalThis.document.cookie) || "",
  hostname = (globalThis.location && globalThis.location.hostname) || "",
  servedBy = servedByFrontendId(),
) {
  return inspectCanisterEnv(cookieString, hostname, servedBy).env;
}

// Does a backend reject say "the id this page is calling is not a canister
// of this replica's exchange"? IC0301: the canister does not exist here (a
// foreign twin's ids). IC0536: the canister exists but has no such query
// method (one of our own ids in another role — a stale row). Both texts come
// through the SDK as `Reject text: ...` / `Error code: IC0301`. A frozen
// canister (IC0207), a trap, or an unreachable replica match none of these.
const MISMATCH_RE = /\bIC0301\b|\bCanister [a-z0-9-]+ not found\b|\bIC0536\b|\bhas no query method\b/;
export function isCanisterEnvMismatchReject(message) {
  return MISMATCH_RE.test(String(message ?? ""));
}
