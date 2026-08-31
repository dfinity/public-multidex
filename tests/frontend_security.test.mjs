#!/usr/bin/env node
// tests/frontend_security.test.mjs — static-analysis guards for the frontend
// security fixes tracked in docs/issue-triage-2026-08.md §1.1, §1.2 and the
// CSP/SRI items.
//
// WHY STATIC. Every property below is a property of the SOURCE, not of a
// running page: "the certificate check is passed a tagged principal", "the root
// key is never fetched from a remote host", "the delegation relay cannot be
// pointed at another origin", "no third-party script is loaded", "the shipped
// asset config actually sets a CSP". Each of these was, at some point, wrong in
// a way that produced no runtime error at all — the certificate check threw on
// every call for its entire life and the page still painted green. A test that
// needs a replica, a browser and a signed-in user to notice that is a test that
// will not be run. These run in ~20ms with plain `node`, no deps, no network.
//
// Usage:
//   node tests/frontend_security.test.mjs           # check the working tree
//   node tests/frontend_security.test.mjs <root>    # check another checkout
//
// The second form is how the "fails before the fix" half of the contract is
// demonstrated: materialise an older tree (git worktree, or `git show`) and
// point this at it.

import { readFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
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

// A file that is supposed to exist but doesn't is a failure, not a crash —
// otherwise one moved file silently skips a whole section of this suite.
function must(p) {
  const s = read(p);
  if (s === null) bad(`${p} exists`, `not found under ${ROOT}`);
  return s;
}

const stripHtmlComments = (src) => src.replace(/<!--[\s\S]*?-->/g, "");

// ── JSON5-lite: strip comments + trailing commas, then JSON.parse ────
// String-aware, because the CSP value in .ic-assets.json5 contains "http://".
function parseJson5(src) {
  let out = "";
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === '"' || c === "'") {
      const quote = c;
      out += c; i++;
      while (i < src.length) {
        if (src[i] === "\\") { out += src.slice(i, i + 2); i += 2; continue; }
        out += src[i];
        if (src[i] === quote) { i++; break; }
        i++;
      }
      continue;
    }
    if (c === "/" && src[i + 1] === "/") { while (i < src.length && src[i] !== "\n") i++; continue; }
    if (c === "/" && src[i + 1] === "*") { i += 2; while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) i++; i += 2; continue; }
    out += c; i++;
  }
  return JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"));
}

// The exact bytes of the one inline script in ai-connect.html — what a CSP
// 'sha256-…' source expression is computed over.
function inlineScriptOf(html) {
  const open = "<" + "script>";
  const close = "</" + "script>";
  const a = html.indexOf(open);
  const b = html.lastIndexOf(close);
  if (a < 0 || b < a) return null;
  return html.slice(a + open.length, b);
}
const sriHash = (s) => "sha256-" + createHash("sha256").update(s, "utf8").digest("base64");

console.log(`frontend security guards — ${ROOT}\n`);

// ════════════════════════════════════════════════════════════════════
// A. The ledger verifier's certificate check actually runs, and fails closed
// ════════════════════════════════════════════════════════════════════
console.log("A. ledger.js — IC certificate validation");
{
  const raw = must("src/frontend/src/ledger.js");
  const src = raw === null ? null : stripJsComments(raw);
  if (src) {
    // The SDK dispatches on the object SHAPE. A bare Principal takes an
    // unreachable branch and throws, which the catch downgraded to {ok:null} —
    // so the check never ran, in any environment, for its whole life.
    check("Certificate.create is passed a TAGGED principal ({ canisterId: … })",
      /principal:\s*\{\s*canisterId\s*:/.test(src),
      "expected `principal: { canisterId: cid }` — see scripts/verify_ledger.mjs:430-435");

    check("no bare `principal: <Principal>` is passed",
      !/principal:\s*cid\s*,/.test(src),
      "a bare Principal makes Certificate.create throw UNREACHABLE_ERROR");

    // With time verification off, a replayed OLD certificate over an OLD head
    // verifies — which is exactly how a truncated tape stays invisible.
    const timeLines = src.split("\n").filter((l) => l.includes("disableTimeVerification"));
    check("disableTimeVerification is not set unconditionally",
      timeLines.length > 0 && timeLines.every((l) => /local|isLocalReplica/.test(l)),
      timeLines.length
        ? `unguarded occurrence(s):\n${timeLines.filter((l) => !/local|isLocalReplica/.test(l)).join("\n")}`
        : "expected the flag, gated on a local-replica check");

    check("locality comes from the shared exact-match predicate",
      /import\s*\{[^}]*isLocalReplicaOrigin[^}]*\}\s*from\s*["']\.\/host\.js["']/.test(src),
      "expected `import { isLocalReplicaOrigin } from \"./host.js\"`");

    // FAIL CLOSED: ok===null (the swallowed-throw case) must not paint green.
    check("green `lg-ok` is never set unconditionally",
      !/className\s*=\s*["']lg-verify-out lg-ok["']/.test(src),
      "the verified state was painted regardless of the certificate result");

    check("green `lg-ok` is gated on a true certificate result",
      /certOk\s*\?\s*["']lg-verify-out lg-ok["']/.test(src),
      "expected `res.certOk ? \"lg-verify-out lg-ok\" : …`");

    check("verifyChainClient reports certOk as a hard boolean",
      /certOk:\s*certCheck\.ok\s*===\s*true/.test(src),
      "callers must not have to interpret null themselves");

    check("the unverified state says so in words",
      /certificate NOT verified/i.test(src) && /self-consistent/i.test(src),
      "expected a distinct \"chain self-consistent, certificate NOT verified\" state");
  }
}

// ════════════════════════════════════════════════════════════════════
// B. The root key never comes from the host being verified
// ════════════════════════════════════════════════════════════════════
console.log("\nB. main.js / host.js — root key provenance");
{
  const rawMain = must("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);
  if (src) {
    const calls = [...src.matchAll(/fetchRootKey\s*\(/g)];
    check("fetchRootKey is called at most once", calls.length <= 1,
      `${calls.length} call sites — each needs its own guard`);

    for (const m of calls) {
      // The guard must be adjacent to the call, not somewhere up the file.
      const before = src.slice(Math.max(0, m.index - 300), m.index);
      check("fetchRootKey is guarded by a local-host check",
        /if\s*\(\s*isLocalReplicaOrigin\s*\(\s*\)\s*\)/.test(before),
        "on mainnet the IC gateway proxies /api/v2/status, so an unguarded "
        + "fetchRootKey takes the certificate anchor from the party being checked");
    }
    if (calls.length === 0) ok("fetchRootKey is guarded by a local-host check (no call sites)");

    check("main.js imports the shared local-host predicate",
      /import\s*\{[^}]*isLocalReplicaOrigin[^}]*\}\s*from\s*["']\.\/host\.js["']/.test(src));
  }

  // The CLI twin (scripts/verify_ledger.mjs) carries the same waiver under
  // the same rule — but here ABSENCE passes: deleting the CLI's waiver
  // outright is the strictest posture, and this pin must not force keeping
  // it (the ledger.js pin above requires presence because the BROWSER needs
  // the flag on a local replica; the CLI does not owe that). Behavioural
  // execution of this file lives in tests/test_verify_ledger_gate.sh.
  {
    const rawCli = must("scripts/verify_ledger.mjs");
    const cli = rawCli === null ? null : stripJsComments(rawCli);
    if (cli) {
      const cliTime = cli.split("\n").filter((l) => l.includes("disableTimeVerification"));
      check("CLI verifier: time waiver absent, or every occurrence local-guarded",
        cliTime.every((l) => /LOCAL_HOST|isLocalReplica/.test(l)),
        `unguarded occurrence(s):\n${cliTime.filter((l) => !/LOCAL_HOST|isLocalReplica/.test(l)).join("\n")}`);
    }
  }

  const rawHost = must("src/frontend/src/host.js");
  const host = rawHost === null ? null : stripJsComments(rawHost);
  if (host) {
    // Exact hostname match, so `localhost.evil.example` is NOT local.
    for (const h of ["localhost", "127.0.0.1", "::1"]) {
      check(`host.js matches ${h} by equality`,
        new RegExp(`===\\s*["']${h.replace(/\./g, "\\.")}["']`).test(host));
    }
    check("host.js allows the reserved .localhost TLD by suffix",
      /endsWith\(\s*["']\.localhost["']\s*\)/.test(host));
    // Backstop ban: the WHOLE substring family, case-insensitive (the old
    // three-method needle missed `.lastIndexOf(`, `.search(` and
    // `/localhost/.test(h)` — reintroduction shipped clean through it).
    check("host.js never substring-matches the hostname (family ban)",
      !/\.\s*(includes|indexOf|lastIndexOf|search|match|matchAll|test)\s*\(/i.test(host),
      "substring matching makes `localhost.evil.example` look local");
    check("host.js reads a hostname, never a whole URL",
      !/location\.href|location\.origin/.test(host));

    // The closure is EXECUTION, not needles: import the real predicate and
    // classify a hostname battery. Any parse-clean rewrite that changes
    // behaviour — `endsWith("localhost")`, a dropped equality arm, any
    // substring form the ban never heard of — flips one of these.
    let realHost = null;
    try {
      realHost = await import(pathToFileURL(path("src/frontend/src/host.js")).href);
    } catch (e) {
      bad("host.js imports cleanly for behavioural checks", e);
    }
    if (realHost && typeof realHost.isLocalReplicaHost === "function") {
      const f = realHost.isLocalReplicaHost;
      for (const h of ["localhost", "LOCALHOST", "127.0.0.1", "::1", "[::1]",
                       "app.localhost", "a.b.localhost"]) {
        check(`predicate executed: "${h}" is LOCAL`, f(h) === true);
      }
      for (const h of ["notlocalhost", "evil-localhost", "localhost.evil.example",
                       "localhost.evil", "xlocalhost", "127.0.0.1.evil.example",
                       "127.0.0.2", "::1.evil.example", "multidex.ai",
                       "evil.example", "", "https://evil.example/?host=localhost"]) {
        check(`predicate executed: "${h}" is REMOTE`, f(h) === false);
      }
      check('predicate executed: null hostname is REMOTE', f(null) === false);
      check("isLocalReplicaOrigin fails CLOSED with no window (node)",
        typeof realHost.isLocalReplicaOrigin === "function"
          && realHost.isLocalReplicaOrigin() === false);
    } else if (realHost) {
      bad("host.js exports isLocalReplicaHost", "behavioural battery has nothing to run");
    }
  }
}

// ════════════════════════════════════════════════════════════════════
// B2. Internet Identity origin pinning — the MUST with no instrument
// ════════════════════════════════════════════════════════════════════
// main.js pins ONE canonical derivationOrigin and states, in its own words,
// that /.well-known/ii-alternative-origins "MUST list every origin below".
// Nothing read either artefact until this section (OhShii #40.4 / W6-03) —
// on the SIGN-IN path, where drift means users who cannot authenticate or
// an origin trusted that should not be.
console.log("\nB2. ii-alternative-origins — pinned-list agreement");
{
  const mainRaw = must("src/frontend/src/main.js");
  const mainSrc = mainRaw === null ? null : stripJsComments(mainRaw);
  let pinned = null, canonical = null;
  if (mainSrc) {
    const pm = mainSrc.match(/II_PINNED_ORIGINS\s*=\s*\[([^\]]*)\]/);
    const cm = mainSrc.match(/II_CANONICAL_ORIGIN\s*=\s*["']([^"']+)["']/);
    pinned = pm ? [...pm[1].matchAll(/["']([^"']+)["']/g)].map((m) => m[1]) : null;
    canonical = cm ? cm[1] : null;
    check("II_PINNED_ORIGINS is extractable", Array.isArray(pinned) && pinned.length > 0);
    check("II_CANONICAL_ORIGIN is extractable", canonical !== null);
    check("the canonical origin is itself in the pinned list",
      pinned !== null && canonical !== null && pinned.includes(canonical),
      "a canonical origin outside its own list cannot pass id.ai validation");
  }
  const setEq = (a, b) => a && b && a.length === b.length && [...a].sort().join("|") === [...b].sort().join("|");
  const checkArtefact = (path, required) => {
    const raw = read(path);
    if (raw === null) {
      if (required) bad(`${path} exists`, "the II artefact is MISSING — sign-in origin validation has nothing to serve");
      else ok(`${path} absent (no build present) — source copy is the gated artefact`);
      return;
    }
    let listed = null;
    try { listed = JSON.parse(raw).alternativeOrigins; } catch { /* fallthrough */ }
    check(`${path} parses with an alternativeOrigins array`, Array.isArray(listed));
    if (Array.isArray(listed) && pinned) {
      check(`${path} lists EXACTLY the pinned origins (set-equal)`,
        setEq(listed, pinned),
        `artefact: ${JSON.stringify(listed)}\n    pinned:   ${JSON.stringify(pinned)}`);
    }
  };
  checkArtefact("src/frontend/public/.well-known/ii-alternative-origins", true);
  // The BUILT copy: a build that drops or rewrites it must fail here. Only
  // required when a dist/ exists at all (fresh checkouts have none).
  const distExists = existsSync(path("dist"));
  checkArtefact("dist/.well-known/ii-alternative-origins", distExists);
}

// ════════════════════════════════════════════════════════════════════
// C. ai-connect.html — the delegation handshake
// ════════════════════════════════════════════════════════════════════
console.log("\nC. ai-connect.html — II delegation handshake");
let aiScript = null;
{
  const html = must("src/frontend/public/ai-connect.html");
  if (html) {
    aiScript = inlineScriptOf(html);
    check("the handshake script is present and extractable", aiScript !== null);
  }
  // Patterns are matched against the script with comments removed; the CSP
  // hash in section E is computed over the RAW bytes, which is what ships.
  const s = aiScript === null ? "" : stripJsComments(aiScript);

  // C1 — the callback authority. `1@attacker.example.com` as the port turns
  // "http://127.0.0.1:" + PORT + "/callback" into an attacker-hosted URL, and
  // the SIGNED delegation is POSTed there.
  check("the callback port is validated as a decimal integer",
    /\/\^\[0-9\]\{1,5\}\$\//.test(s),
    "expected a /^[0-9]{1,5}$/ test on the port fragment param");
  check("the callback port is range-checked to 1-65535",
    /65535/.test(s) && />=\s*1\b/.test(s));
  check("the callback URL is built with new URL(), not concatenation",
    /new URL\(\s*["']http:\/\/127\.0\.0\.1\//.test(s));
  check("no string-concatenated callback authority survives",
    !/["']http:\/\/127\.0\.0\.1:["']\s*\+/.test(s),
    "concatenating an unvalidated port into the authority is the whole bug");
  check("an invalid port is refused visibly rather than defaulted away",
    /CALLBACK\s*===\s*null/.test(s) && /refuse\(/.test(s));
  check("the outbound destination is re-checked at the send site",
    /dest\.hostname\s*!==\s*["']127\.0\.0\.1["']/.test(s),
    "nothing validated where the signed delegation actually leaves the page");

  // C2 — displayed lifetime must be the minted lifetime.
  check("the display-only ttl_hours param is gone",
    !/ttl_hours/.test(s),
    "the lifetime shown and the lifetime minted were two different inputs");
  check("the displayed TTL is derived from the minted TTL",
    /getElementById\(["']ttl["']\)\.textContent\s*=[^;]*TTL_NS/.test(s));
  check("the minted TTL is clamped to a ceiling",
    /TTL_MAX_NS/.test(s) && /TTL_MAX_NS\s*:\s*requested|requested\s*>\s*TTL_MAX_NS/.test(s));
  check("the ceiling is 8 hours",
    /8n\s*\*\s*60n\s*\*\s*60n\s*\*\s*1000000000n/.test(s));
  check("the TTL actually sent is the clamped value",
    /maxTimeToLive:\s*TTL_NS\b/.test(s));

  // C3 — scope. No `targets` ⇒ valid for every canister on the IC.
  check("the authorize-client request carries targets",
    /targets:\s*\[\s*BACKEND_ID\s*\]/.test(s),
    "without targets the delegation is valid for EVERY canister");
  check("the target id comes from the ic:canister-id meta tag",
    /meta\[name=["']ic:canister-id["']\]/.test(s));
  check("an unresolved/placeholder canister id refuses to mint",
    /BACKEND_OK/.test(s) && /!BACKEND_OK/.test(s));

  // C4 — both ends of the relay pinned.
  check("the inbound postMessage checks event.source",
    /event\.source\s*!==\s*ii/.test(s),
    "the origin check alone lets any window on that origin drive the handshake");
  check("the inbound postMessage still checks event.origin",
    /event\.origin\s*!==\s*II_ORIGIN/.test(s));

  // C5 — derivationOrigin: the same principal as the app (issue #46.3).
  // Without it II derives from THIS page's origin, so on multidex.ai the
  // connector acts as a DIFFERENT principal than the one the user funded —
  // and the page's own consent text promises the app's principal.
  check("the authorize-client request carries the canonical derivationOrigin",
    /derivationOrigin:\s*DERIVATION_ORIGIN/.test(s),
    "without it, multidex.ai derives a different principal than the app");
  check("the derivationOrigin is gated on the pinned-origins list",
    /II_PINNED_ORIGINS\.includes\(\s*location\.origin\s*\)/.test(s),
    "unconditionally pinning breaks sign-in from unpinned origins (local venues)");
  check("an unpinned origin omits the key entirely, not `derivationOrigin: undefined`",
    /\.\.\.\(\s*DERIVATION_ORIGIN\s*\?\s*\{\s*derivationOrigin/.test(s),
    "a present-but-undefined key is provider-interpretation roulette");
  // The constants must not drift from main.js's — same extraction as B2.
  const mainRawC = read("src/frontend/src/main.js");
  const mainC = mainRawC === null ? null : stripJsComments(mainRawC);
  if (mainC && s) {
    const grab = (src) => {
      const pm = src.match(/II_PINNED_ORIGINS\s*=\s*\[([^\]]*)\]/);
      const cm = src.match(/II_CANONICAL_ORIGIN\s*=\s*["']([^"']+)["']/);
      return {
        pinned: pm ? [...pm[1].matchAll(/["']([^"']+)["']/g)].map((m) => m[1]) : null,
        canonical: cm ? cm[1] : null,
      };
    };
    const app = grab(mainC), page = grab(s);
    check("ai-connect.html pins the same canonical origin as main.js",
      page.canonical !== null && page.canonical === app.canonical,
      `main.js: ${app.canonical}\n    ai-connect: ${page.canonical}`);
    const setEqC = (a, b) => Array.isArray(a) && Array.isArray(b) && a.length === b.length
      && [...a].sort().join("|") === [...b].sort().join("|");
    check("ai-connect.html's pinned-origins list is set-equal to main.js's",
      setEqC(app.pinned, page.pinned),
      `main.js: ${JSON.stringify(app.pinned)}\n    ai-connect: ${JSON.stringify(page.pinned)}`);
  }
}

// ════════════════════════════════════════════════════════════════════
// D. Third-party script + Content-Security-Policy
// ════════════════════════════════════════════════════════════════════
console.log("\nD. third-party script + CSP");
{
  const rawIndex = must("src/frontend/index.html");
  const html = rawIndex === null ? null : stripHtmlComments(rawIndex);
  if (html) {
    check("index.html references no CDN script host",
      !/unpkg\.com|cdn\.jsdelivr\.net|cdnjs\.cloudflare\.com/.test(html));
    check("index.html loads no absolute-URL script",
      !/<script[^>]*\ssrc\s*=\s*["']https?:/i.test(html));
    check("index.html has no inline script block",
      !/<script(?![^>]*\ssrc=)[^>]*>[\s\S]*?<\/script>/i.test(html),
      "an inline block would need 'unsafe-inline' or a hash under the CSP");
  }

  const pkg = must("package.json");
  const lock = read("package-lock.json");
  if (pkg) {
    const j = JSON.parse(pkg);
    check("lightweight-charts is a declared dependency",
      !!(j.dependencies && j.dependencies["lightweight-charts"]),
      "it was loaded from a CDN and appeared in neither package.json nor the lockfile");
  }
  check("lightweight-charts is pinned in package-lock.json",
    !!lock && /"node_modules\/lightweight-charts"/.test(lock));

  const rawMainD = read("src/frontend/src/main.js");
  const main = rawMainD === null ? null : stripJsComments(rawMainD);
  if (main) {
    check("main.js imports the charting library",
      /import\s*\{[^}]*createChart[^}]*\}\s*from\s*["']lightweight-charts["']/.test(main));
    check("main.js no longer reads the library off `window`",
      !/window\.LightweightCharts/.test(main));

    // `standard` forbids inline event-handler attributes. These 8 used to be
    // `onerror="this.style.display='none'"` on token-logo <img>s.
    const inline = [...main.matchAll(/\son[a-z]+\s*=\s*["'][^"']*["']/gi)]
      .filter((m) => !/\son(ly|e)\b/i.test(m[0]));
    check("main.js emits no inline event-handler attributes",
      inline.length === 0,
      inline.map((m) => m[0].trim()).join("\n"));
    check("main.js contains no `onerror=` attribute",
      !main.includes("onerror=\""),
      "converted to a capture-phase addEventListener(\"error\", …)");
    check("the replacement error handler is wired with addEventListener",
      /addEventListener\(\s*["']error["'][\s\S]{0,200}?,\s*true\s*\)/.test(main),
      "`error` does not bubble — the listener must be in the capture phase");
  }
}

// ════════════════════════════════════════════════════════════════════
// E. The asset config that actually ships
// ════════════════════════════════════════════════════════════════════
console.log("\nE. .ic-assets.json5 — the file that ships");
{
  check("the dead sibling src/frontend/.ic-assets.json5 is gone",
    !existsSync(path("src/frontend/.ic-assets.json5")),
    "vite copies only publicDir; rules at the vite root silently do nothing");

  const raw = must("src/frontend/public/.ic-assets.json5");
  if (raw) {
    let cfg = null;
    try { cfg = parseJson5(raw); ok("public/.ic-assets.json5 parses"); }
    catch (e) { bad("public/.ic-assets.json5 parses", e.message); }

    if (Array.isArray(cfg)) {
      const catchAll = cfg.filter((r) => r && r.match === "**/*");
      check("a catch-all rule sets a security_policy",
        catchAll.some((r) => typeof r.security_policy === "string" && r.security_policy.length > 0),
        "with no security_policy the deployed app serves no CSP at all");

      const ai = cfg.find((r) => r && r.match === "ai-connect.html");
      const csp = ai && ai.headers && ai.headers["Content-Security-Policy"];
      check("ai-connect.html carries its own Content-Security-Policy", !!csp);
      if (csp) {
        const m = /'(sha256-[A-Za-z0-9+/=]+)'/.exec(csp);
        check("that policy pins the inline script by hash", !!m,
          "the page has an inline script; 'unsafe-inline' would defeat the point");
        if (m && aiScript !== null) {
          const want = sriHash(aiScript);
          check("the pinned hash matches the script as committed",
            m[1] === want,
            `config has ${m[1]}\nscript hashes to ${want}\n`
            + "→ paste the second value into src/frontend/public/.ic-assets.json5");
        }
        check("the policy keeps frame-ancestors 'none'", /frame-ancestors\s+'none'/.test(csp));
        check("the policy allows the loopback callback",
          /connect-src[^;]*127\.0\.0\.1/.test(csp));
        // `standard` includes upgrade-insecure-requests, which would rewrite the
        // http://127.0.0.1 callback to https and break every sign-in.
        check("the policy does not upgrade the loopback callback to https",
          !/upgrade-insecure-requests/.test(csp));
      }
    }
  }
}

// ════════════════════════════════════════════════════════════════════
// F. assistant.js — identity-boundary reset + fail-closed action side
// ════════════════════════════════════════════════════════════════════
// GHSA-6qpg. Item 1: logout() tore down ~16 identity-bound targets but not
// the assistant, so on a shared browser the next sign-in spliced the previous
// user's transcript (account snapshots, positions) into ITS prompts and
// relayed them over its own authenticated aiComplete outcall. Item 2:
// asstSide failed OPEN — any token that was not exactly "sell" encoded as a
// buy — while the confirm card rendered the RAW token, so "side":"short"
// showed SHORT and submitted a buy.
console.log("\nF. assistant.js — transcript reset at logout + fail-closed side");
{
  // ── Static half: wiring a behavioural run cannot see ──
  const rawAsst = must("src/frontend/src/assistant.js");
  const asst = rawAsst === null ? null : stripJsComments(rawAsst);
  if (asst) {
    check("asstSide no longer fails open (the `: { buy: null }` fallback is gone)",
      !/\?\s*\{\s*sell:\s*null\s*\}\s*:\s*\{\s*buy:\s*null\s*\}/.test(asst),
      "any token that is not exactly \"sell\" encoded as a BUY");
    const sideSummaries = asst.split("\n").filter((l) => l.includes("summary:") && /a\.side/.test(l));
    check("side-carrying confirm summaries exist at all", sideSummaries.length >= 3,
      "actions renamed? this section is then asserting nothing");
    for (const line of sideSummaries) {
      check(`confirm summary derives from the resolved variant: ${line.trim().slice(0, 58)}…`,
        /asstSideLabel\s*\(/.test(line),
        "the card must label what run() will submit, never the raw token");
    }
    const rIdx = asst.indexOf("export function resetAssistant(");
    check("assistant.js exports resetAssistant", rIdx >= 0);
    if (rIdx >= 0) {
      const body = asst.slice(rIdx, asst.indexOf("\n}", rIdx));
      for (const s of ["_asstTurns = []", "_asstWorkings = []", "_asstSeeded = false",
                       "_oqlSchema = null", "_asstBusy = false"]) {
        check(`resetAssistant resets ${s.split(" ")[0]}`, body.includes(s));
      }
    }
  }
  const rawMainF = must("src/frontend/src/main.js");
  const mainF = rawMainF === null ? null : stripJsComments(rawMainF);
  if (mainF) {
    check("main.js imports resetAssistant from assistant.js",
      /import\s*\{[^}]*resetAssistant[^}]*\}\s*from\s*["']\.\/assistant\.js["']/.test(mainF));
    const at = mainF.indexOf("async function logout()");
    check("logout() is extractable", at >= 0);
    check("logout() calls resetAssistant()",
      at >= 0 && /resetAssistant\s*\(\s*\)/.test(mainF.slice(at, at + 2000)),
      "the transcript survives sign-out and the next user's prompts splice it in");
  }

  // ── Behavioural half: drive the real module under a stub DOM ──
  // assistant.js touches `document` only inside functions, so it imports
  // cleanly in node; a small DOM stub is enough to run the real
  // submit → aiComplete → reply agent loop and inspect what each prompt
  // actually carries across the identity boundary.
  const mkEl = () => ({
    children: [], className: "", textContent: "", style: {}, value: "",
    disabled: false, scrollTop: 0, scrollHeight: 0, _html: "", listeners: {},
    appendChild(c) { this.children.push(c); return c; },
    addEventListener(ev, fn) { (this.listeners[ev] ||= []).push(fn); },
    querySelector() { return mkEl(); },
    querySelectorAll() { return []; },
    focus() {},
    set innerHTML(v) { this._html = String(v); if (this._html === "") this.children = []; },
    get innerHTML() { return this._html; },
  });
  const els = new Map();
  globalThis.document = {
    getElementById(id) { if (!els.has(id)) els.set(id, mkEl()); return els.get(id); },
    createElement: () => mkEl(),
    addEventListener() {},
    body: mkEl(),
  };
  let mod = null, liveAppState = null;
  try {
    liveAppState = (await import(pathToFileURL(path("src/frontend/src/state.js")).href)).appState;
    mod = await import(pathToFileURL(path("src/frontend/src/assistant.js")).href);
  } catch (e) {
    bad("assistant.js imports cleanly under a stub DOM", e);
  }

  if (mod && typeof mod.asstSide === "function") {
    const f = mod.asstSide;
    const enc = (x) => JSON.stringify(f(x));
    for (const s of ["buy", "BUY", " Buy "]) {
      check(`asstSide executed: ${JSON.stringify(s)} → {buy:null}`, enc(s) === '{"buy":null}');
    }
    for (const s of ["sell", "SELL", " Sell "]) {
      check(`asstSide executed: ${JSON.stringify(s)} → {sell:null}`, enc(s) === '{"sell":null}');
    }
    for (const s of ["short", "long", "hold", "", "buy sell", "buyy", undefined, null, 0, {}]) {
      check(`asstSide executed: ${JSON.stringify(s)} fails CLOSED (null)`, f(s) === null);
    }
  } else if (mod) {
    bad("assistant.js exports asstSide", "the behavioural side battery has nothing to run");
  }

  if (mod && typeof mod.resetAssistant === "function"
      && typeof mod.setupAssistant === "function" && liveAppState) {
    const prompts = [];
    const replies = [];   // queued aiComplete results, shifted per call
    let schemaCalls = 0;
    let orderCalls = 0;
    liveAppState.isAuthenticated = true;
    liveAppState.myPrincipalText = "aaaaa-aa";
    liveAppState.actor = {
      schema: async () => { schemaCalls++; return "{}"; },
      archiveSchema: async () => "{}",
      aiComplete: async (p) => {
        prompts.push(p);
        return replies.length ? replies.shift() : { ok: '{"type":"reply","text":"done"}' };
      },
      placeMarketOrder: async () => { orderCalls++; return { ok: 1n }; },
      aiActionExecuted: async () => {},
    };
    mod.setupAssistant({});
    const input = document.getElementById("asst-input");
    const send = document.getElementById("asst-send");
    const list = document.getElementById("asst-messages");
    const submit = async (text, expectCalls) => {
      input.value = text;
      send.listeners.click[0]();
      const t0 = Date.now();
      while (prompts.length < expectCalls || send.disabled) {
        if (Date.now() - t0 > 5000) {
          throw new Error(`timeout in the agent loop (prompts=${prompts.length}, want ${expectCalls})`);
        }
        await new Promise((r) => setTimeout(r, 10));
      }
    };
    try {
      // User A talks; the transcript rides every subsequent prompt.
      replies.push({ ok: '{"type":"reply","text":"noted"}' });
      await submit("my SECRET-ALPHA strategy", 1);
      check("behavioural: user A's text reaches the model", prompts[0].includes("SECRET-ALPHA"));
      replies.push({ ok: '{"type":"reply","text":"ok"}' });
      await submit("second question", 2);
      check("behavioural: without a reset the transcript persists across turns (the leak mechanism)",
        prompts[1].includes("SECRET-ALPHA"));

      // The sign-out boundary.
      mod.resetAssistant();
      check("behavioural: resetAssistant clears the rendered chat",
        list.children.length === 0 && list.innerHTML === "");
      mod.assistantOnShow();
      check("behavioural: the greeting reseeds after reset (seed flag cleared)",
        list.children.length === 1);

      // User B asks; nothing of A may ride along, and the schema refetches.
      replies.push({ ok: '{"type":"reply","text":"fresh"}' });
      await submit("what did we discuss before?", 3);
      check("behavioural: after resetAssistant user B's prompt carries NOTHING of user A",
        !prompts[2].includes("SECRET-ALPHA") && !prompts[2].includes("second question"),
        "the transcript leaked across the identity boundary");
      check("behavioural: the cached OQL schema is refetched after reset", schemaCalls === 2);

      // Fail-closed side: a proposal with side:"short" must produce NO
      // confirm card, NO canister call, and an ERROR the model sees.
      replies.push({ ok: '{"type":"action","method":"placeMarketOrder","args":{"marketId":"ICP-ICPUSD","side":"short","quantity":1,"maxSlippage":0.05}}' });
      replies.push({ ok: '{"type":"reply","text":"cannot"}' });
      await submit("sell my ICP", 5);
      const cards = list.children.filter((c) => String(c.className).includes("asst-confirm"));
      check('behavioural: a side:"short" proposal shows NO confirm card', cards.length === 0,
        "the old code showed SHORT on the card and submitted a BUY");
      check('behavioural: a side:"short" proposal never reaches the canister', orderCalls === 0);
      check("behavioural: the model is told the side was invalid",
        prompts[4].includes("ERROR: invalid side"),
        "the agent loop must get a tool ERROR so it can re-propose");
    } catch (e) {
      bad("the behavioural assistant battery completes", (e && e.stack) || e);
    }
  } else if (mod) {
    bad("assistant.js exports resetAssistant",
      "the identity-boundary behavioural battery has nothing to run");
  }
}

// ════════════════════════════════════════════════════════════════════
// G. assistant.js — bounded tool feed-back + recoverable transcript (#46.1)
// ════════════════════════════════════════════════════════════════════
// Public issue #46 finding 1. The backend's aiComplete guard refuses prompts
// over AI_MAX_PROMPT_BYTES (32,768 — GHSA-c6g7), and the transcript is resent
// on EVERY agent step — so one oversized OQL read used to wedge the assistant
// for the rest of the page load: every later prompt carried the giant tool
// turn and was refused. The fix caps rows fed back (like the candles tool's
// 48, plus a character clamp for wide rows) and trims what assistantFullPrompt
// sends so the rebuilt prompt always fits. This battery reuses section F's
// stub DOM (the module import is cached, so it drives the SAME live module).
console.log("\nG. assistant.js — bounded tool feed + recoverable transcript (#46.1)");
{
  let mod = null, liveAppState = null;
  try {
    liveAppState = (await import(pathToFileURL(path("src/frontend/src/state.js")).href)).appState;
    mod = await import(pathToFileURL(path("src/frontend/src/assistant.js")).href);
  } catch (e) {
    bad("assistant.js re-imports for the #46.1 battery", e);
  }
  const BACKEND_GUARD = 32768;   // AI_MAX_PROMPT_BYTES (src/backend/main.mo)

  if (mod && typeof mod.resetAssistant === "function"
      && typeof mod.setupAssistant === "function" && liveAppState) {
    mod.resetAssistant();   // shed section F's transcript — fresh ground
    const prompts = [];
    const replies = [];
    // 500 modest rows ≈ 55k chars serialised — well past the backend guard
    // on its own. Row markers are unique so we can see exactly which rows
    // the model was fed.
    const bigRes = {
      rows: Array.from({ length: 500 }, (_, i) => [
        { name: "id", value: { nat: BigInt(i) } },
        { name: "owner", value: { text: "ROW-" + i + "-" + "x".repeat(80) } },
        { name: "price", value: { float: 65000.5 } },
      ]),
      hasMore: false, degraded: [],
    };
    // Wide rows: ~1k chars EACH, so 40 of them bust the per-turn char clamp
    // even under the 48-row cap. qn makes each query's rows distinguishable.
    let qn = 0;
    const wideRes = () => ({
      rows: Array.from({ length: 40 }, (_, i) => [
        { name: "blob", value: { text: "Q" + qn + "R" + i + "-" + "y".repeat(1000) } },
      ]),
      hasMore: false, degraded: [],
    });
    let serveWide = false;
    liveAppState.isAuthenticated = true;
    liveAppState.myPrincipalText = "aaaaa-aa";
    liveAppState.actor = {
      schema: async () => "{}",
      archiveSchema: async () => "{}",
      execute: async () => { if (serveWide) { qn++; return wideRes(); } return bigRes; },
      aiComplete: async (p) => {
        prompts.push(p);
        return replies.length ? replies.shift() : { ok: '{"type":"reply","text":"done"}' };
      },
    };
    mod.setupAssistant({});
    const input = document.getElementById("asst-input");
    const send = document.getElementById("asst-send");
    const submit = async (text, expectCalls) => {
      input.value = text;
      send.listeners.click[0]();
      const t0 = Date.now();
      while (prompts.length < expectCalls || send.disabled) {
        if (Date.now() - t0 > 5000) {
          throw new Error(`timeout in the agent loop (prompts=${prompts.length}, want ${expectCalls})`);
        }
        await new Promise((r) => setTimeout(r, 10));
      }
    };
    try {
      // G1 — an oversized read is capped in the fed-back tool turn.
      replies.push({ ok: '{"type":"query","oql":{"start":"order"}}' });
      replies.push({ ok: '{"type":"reply","text":"big list handled"}' });
      await submit("show the whole order book", 2);
      check("behavioural: an oversized query result feeds back a 'first 48 of 500 rows' note",
        /first 48 of 500 rows/.test(prompts[1]),
        "the full 500-row serialisation used to ride every later prompt");
      check("behavioural: the capped feed-back keeps the first rows",
        prompts[1].includes("ROW-0-") && prompts[1].includes("ROW-47-"));
      check("behavioural: rows past the cap never reach the model",
        !prompts[1].includes("ROW-48-") && !prompts[1].includes("ROW-499-"));
      check("behavioural: the prompt after a huge read fits the backend guard",
        prompts[1].length <= BACKEND_GUARD,
        `prompt is ${prompts[1].length} chars; the backend refuses > ${BACKEND_GUARD}`);

      // G2 — the transcript recovered: the NEXT question still reaches the
      // model and its prompt also fits (the wedge was every later call
      // being refused).
      replies.push({ ok: '{"type":"reply","text":"still here"}' });
      await submit("are you still working?", 3);
      check("behavioural: the next question still reaches the model (no wedge)",
        prompts[2].includes("are you still working?"));
      check("behavioural: the follow-up prompt also fits the backend guard",
        prompts[2].length <= BACKEND_GUARD, `prompt is ${prompts[2].length} chars`);

      // G3 — wide rows: the character clamp bites BELOW the row cap.
      serveWide = true;
      replies.push({ ok: '{"type":"query","oql":{"start":"event"}}' });
      replies.push({ ok: '{"type":"reply","text":"wide handled"}' });
      await submit("show events", 5);
      check("behavioural: wide rows are clamped below the row cap by characters",
        /first 10 of 40 rows/.test(prompts[4]),
        "40 × ~1k-char rows must halve down (40→20→10) to fit the per-turn clamp");

      // G4 — many big turns: the prompt builder trims the OLDEST tool
      // feed-backs so the rebuilt prompt always fits, newest turns intact.
      replies.push({ ok: '{"type":"query","oql":{"start":"event"}}' });
      replies.push({ ok: '{"type":"reply","text":"more"}' });
      await submit("more events", 7);
      replies.push({ ok: '{"type":"query","oql":{"start":"event"}}' });
      replies.push({ ok: '{"type":"reply","text":"and more"}' });
      await submit("even more events", 9);
      const last = prompts[8];
      check("behavioural: after repeated big reads every prompt still fits the backend guard",
        prompts.every((p) => p.length <= BACKEND_GUARD),
        `longest prompt is ${Math.max(...prompts.map((p) => p.length))} chars`);
      check("behavioural: the newest tool feed-back survives the trim",
        last.includes("Q3R0"));
      check("behavioural: the oldest tool feed-back was elided, not resent",
        !last.includes("Q1R0") && last.includes("elided"),
        "the oldest bulky tool turn must give way first");
      check("behavioural: the newest user turn survives the trim",
        last.includes("even more events"));
      check("behavioural: _asstTurns itself keeps full history (trim is per-call only)",
        prompts[7].includes("Q2R0") || last.includes("Q2R0"),
        "trimming must not destroy turns that still fit");

      // G5 — a backend refusal breaks the loop but leaves the pane usable:
      // the next submit reaches the model again.
      replies.push({ err: "Prompt too long (max 32768 bytes)." });
      await submit("does a refusal wedge you?", 10);
      replies.push({ ok: '{"type":"reply","text":"recovered"}' });
      await submit("and now?", 11);
      check("behavioural: a backend refusal does not wedge the next submit",
        prompts[10].includes("and now?") && prompts[10].length <= BACKEND_GUARD);
    } catch (e) {
      bad("the #46.1 behavioural battery completes", (e && e.stack) || e);
    }
  } else if (mod) {
    bad("assistant.js exports resetAssistant/setupAssistant",
      "the #46.1 behavioural battery has nothing to run");
  }
}

// ════════════════════════════════════════════════════════════════════
// H. assistant.js — the client prompt budget counts UTF-8 BYTES
// ════════════════════════════════════════════════════════════════════
// Follow-up to GHSA-c6g7: the backend's aiComplete guard counts UTF-8 BYTES
// (AI_MAX_PROMPT_BYTES = 32,768, Text.encodeUtf8), but the client trim used
// to compare `prompt.length` — UTF-16 CODE UNITS. A CJK/emoji-heavy
// transcript passes a 30,000-unit check while serialising to ~3× that in
// UTF-8, so the backend (correctly) refused it and the user saw a hard
// "Prompt too long" instead of the intended silent transcript-eliding. The
// trim must measure `new TextEncoder().encode(prompt).length`. Same stub-DOM
// harness as F/G (the module import is cached — same live module).
console.log("\nH. assistant.js — prompt budget measured in UTF-8 bytes");
{
  // Static half: the trim loop measures encoded bytes, not code units.
  const rawAsst = read("src/frontend/src/assistant.js");
  const asst = rawAsst === null ? null : stripJsComments(rawAsst);
  if (asst) {
    check("the trim loop's measure is TextEncoder().encode(…).length",
      /TextEncoder\s*\(\s*\)\.encode\([^)]*\)\.length/.test(asst),
      "the budget must count UTF-8 bytes — what the backend guard sees");
    check("no bare `prompt.length` is compared to ASSIST_PROMPT_BUDGET",
      !/prompt\.length\s*>\s*ASSIST_PROMPT_BUDGET/.test(asst),
      "`.length` is UTF-16 code units; CJK/emoji serialise to 3-4 bytes each");
  }

  let mod = null, liveAppState = null;
  try {
    liveAppState = (await import(pathToFileURL(path("src/frontend/src/state.js")).href)).appState;
    mod = await import(pathToFileURL(path("src/frontend/src/assistant.js")).href);
  } catch (e) {
    bad("assistant.js re-imports for the byte-budget battery", e);
  }
  const BACKEND_GUARD = 32768;   // AI_MAX_PROMPT_BYTES (src/backend/main.mo)
  const utf8len = (s) => new TextEncoder().encode(s).length;

  if (mod && typeof mod.resetAssistant === "function"
      && typeof mod.setupAssistant === "function" && liveAppState) {
    mod.resetAssistant();   // shed section G's transcript — fresh ground
    const prompts = [];
    const replies = [];
    liveAppState.isAuthenticated = true;
    liveAppState.myPrincipalText = "aaaaa-aa";
    liveAppState.actor = {
      schema: async () => "{}",
      archiveSchema: async () => "{}",
      aiComplete: async (p) => {
        prompts.push(p);
        return replies.length ? replies.shift() : { ok: '{"type":"reply","text":"done"}' };
      },
    };
    mod.setupAssistant({});
    const input = document.getElementById("asst-input");
    const send = document.getElementById("asst-send");
    const submit = async (text, expectCalls) => {
      input.value = text;
      send.listeners.click[0]();
      const t0 = Date.now();
      while (prompts.length < expectCalls || send.disabled) {
        if (Date.now() - t0 > 5000) {
          throw new Error(`timeout in the agent loop (prompts=${prompts.length}, want ${expectCalls})`);
        }
        await new Promise((r) => setTimeout(r, 10));
      }
    };
    // Three CJK user turns of 5,000 chars each: 5,000 UTF-16 units but
    // ~15,000 UTF-8 bytes apiece (3 bytes/char). The full transcript sits
    // around ~15k units — comfortably under a 30,000-UNIT check, so a
    // code-unit trim never fires — yet ~45k+ UTF-8 bytes, past the 32,768-
    // byte backend guard. Exactly the GHSA-c6g7 shape this section pins.
    const cjkTurn = (tag) => tag + "、" + "訊".repeat(5000);
    {
      const turns = [cjkTurn("第一"), cjkTurn("第二"), cjkTurn("第三")];
      const units = turns.reduce((s, t) => s + t.length, 0);
      const bytes = turns.reduce((s, t) => s + utf8len(t), 0);
      check("fixture: the turns total >32,768 UTF-8 bytes yet <30,000 UTF-16 units",
        bytes > BACKEND_GUARD && units < 30000,
        `turns are ${bytes} bytes / ${units} units — the units-vs-bytes gap is not exercised; rebuild the fixture`);
    }
    try {
      replies.push({ ok: '{"type":"reply","text":"一"}' });
      await submit(cjkTurn("第一"), 1);
      replies.push({ ok: '{"type":"reply","text":"二"}' });
      await submit(cjkTurn("第二"), 2);
      replies.push({ ok: '{"type":"reply","text":"三"}' });
      await submit(cjkTurn("第三"), 3);
      const last = prompts[2];
      check("behavioural: a CJK-heavy transcript's prompt fits the backend BYTE guard",
        utf8len(last) <= BACKEND_GUARD,
        `prompt is ${utf8len(last)} UTF-8 bytes (${last.length} UTF-16 units); the backend refuses > ${BACKEND_GUARD} bytes`);
      check("behavioural: every prompt sent fits the backend byte guard",
        prompts.every((p) => utf8len(p) <= BACKEND_GUARD),
        `largest is ${Math.max(...prompts.map(utf8len))} bytes`);
      check("behavioural: the newest multibyte turn survives the byte trim",
        last.includes("第三"));
      check("behavioural: the byte trim actually fired (the oldest CJK turn gave way)",
        !last.includes("第一"),
        "under a code-unit budget this transcript is never trimmed at all");
    } catch (e) {
      bad("the byte-budget behavioural battery completes", (e && e.stack) || e);
    }
  } else if (mod) {
    bad("assistant.js exports resetAssistant/setupAssistant",
      "the byte-budget behavioural battery has nothing to run");
  }
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
