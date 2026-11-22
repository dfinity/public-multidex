#!/usr/bin/env node
// scripts/smoke-harness.mjs — a static+proxy harness for undisturbed browser
// smokes of the BUILT bundle at any width against a seat venue (task
// 1793500998; docs/seat-venue-bring-up.md "Browser smoke on a seat venue",
// item 4 — the scratch server three seats had hand-written, made a tool).
//
// WHY. The asset canister serves every venue under the same friendly name
// (frontend.local.localhost) and the browser keeps ONE ic_env cookie jar per
// host name — so a second venue, another seat's smoke or a cached page
// rewrites the jar under a running smoke (item 2 of that section). And the
// venue refuses framing (x-frame-options: DENY + frame-ancestors 'none'), so
// a smoke at 375 px needs a page of its own to size. This server gives a
// smoke a host name nobody else writes and a frame it controls:
//
//   - serves <dist> (default: the repo's dist/ — `npm run build` first) with
//     an SPA fallback to index.html, cache-control: no-store, the right
//     content-types for .js/.css/.svg/.json/.woff2, and NO x-frame-options /
//     CSP (framing is the point);
//   - re-sets the venue's OWN ic_env cookie on every HTML response: at start
//     it HEADs http://frontend.local.localhost:<gateway>/ (on the wire,
//     127.0.0.1:<gateway> with that Host header — Node resolves *.localhost
//     to ::1 while the gateway listens on v4) and copies the
//     `set-cookie: ic_env=…` line verbatim; no such header = "frontend not
//     deployed on <gateway>" and it refuses to start (the bundle reads its
//     canister ids from that cookie);
//   - proxies /api/* verbatim to 127.0.0.1:<gateway> — method, headers with
//     Host rewritten (the gateway answers 400 to a foreign Host), body piped
//     both ways, 502 on an upstream error. Every agent in main.js is created
//     with `host: window.location.origin`, so queries follow the page;
//   - serves /__harness.html?w=375&h=780&route=markets: a same-origin page
//     whose <iframe> of /?nocache=1#<route> is sized by the query (default
//     375x780) and routed by it (default markets): `route` is the app hash
//     without its `#` - a lowercase slug the app routes (swap, docs/launch,
//     ai/agent-chat, account/deposit) or the market deep link markets/<ID>,
//     whose id keeps its case (markets/BTC-ICPUSD; task 1793561650): the
//     tab stays lowercase, the segments after it may carry mixed case -
//     ^[a-z0-9][a-z0-9_-]*(?:/[A-Za-z0-9][A-Za-z0-9_-]*)*$; anything else
//     (`#`, `?`, an uppercase tab, markup, an empty value) is a 400 naming
//     the page's usage, as text/plain. A smoke of another view loads it
//     directly - no post-load hash flip (task 1793555363); script the frame
//     via document.getElementById("app").contentWindow.
//
// Open it as http://<name>-smoke.local.localhost:<port>/ — every *.localhost
// name resolves to loopback in Chrome, src/frontend/src/host.js counts it as
// a local replica host, and a unique name is a jar nobody else writes.
// <name> defaults to the seat's .factory-worker pin.
//
// Usage:
//   node scripts/smoke-harness.mjs --gateway <port> [--dist dist] [--port 0]
//                                  [--name <label>] [--charts]
//                                  [--script <name> [--open] [--result-timeout <s>]]
//
//   --gateway <port>   the seat venue's gateway port — the OS-assigned one a
//                      seat gets from icp.yaml's `gateway: port: 0` (the
//                      network status line prints it). REQUIRED: this tool
//                      never guesses a port and never names the primary's
//                      machine-global venue (the operator's).
//   --dist <dir>       the built bundle to serve (default: <repo>/dist)
//   --port <n>         listen port on 127.0.0.1 (default 0 = OS-assigned)
//   --name <label>     the host-name prefix (default: the .factory-worker
//                      pin, else "seat")
//   --charts           build a SCRATCH dist first (below) and serve that
//   --script <name>    AUTO MODE (below): await the smoke script
//                      tests/smoke/<name>.mjs's `done` line on
//                      /__result/<name>, then exit - 0 on `done ok`, 1 on
//                      any other done line (`done FAIL <n>`)
//   --open             launch the auto page in a FRESH Chrome window through
//                      macOS LaunchServices: `open -na "Google Chrome"
//                      --args --new-window <url>` (elsewhere the URL is
//                      printed and the launch skipped). Needs --script
//   --result-timeout <s>  exit 1 when no `done` line has arrived after <s>
//                      seconds (default 120 with --script; 0 = wait for
//                      Ctrl-C). The auto page's own deadline sits 2 s inside
//                      it, so the window closes itself first
//
//   The page: /__harness.html?w=<px>&h=<px>&route=<slug> - w and h 100..4000
//   (default 375x780), route a slug with a lowercase tab (default markets; a
//   market id keeps its case: markets/BTC-ICPUSD - above).
//   The auto page: /__auto.html?w=<px>&h=<px>&route=<slug>&script=<name> -
//   the same sizes and route, plus the smoke script by name (REQUIRED).
//
// --charts: exact chart state without editing the tree. A generated Vite
// config under os.tmpdir() imports and spreads the repo's vite.config.mjs (the .js spelling second)
// with an ABSOLUTE build.outDir under that scratch dir and one `transform`
// plugin that appends
//   window.__mdxCharts = () => ({ chart: chartInstance, mini: miniChartInstance, candles: chartCandleData })
// to src/frontend/src/main.js (module-scope bindings are in reach of an
// appended closure); `vite build --config <scratch>` runs from the repo root
// (`root: "src/frontend"` resolves against the cwd; ~0.3 s), then THAT dist
// is served. Side effect handled: the base config's closeBundle hooks
// (emit-version-json, emit-well-known-ic-app-manifest,
// bake-ai-connect-canister-id) resolve ./dist from the CONFIG FILE and would
// re-stamp the repo's gitignored dist/version.json and
// dist/.well-known/ic-app.json (and rewrite dist/ai-connect.html) from the
// scratch build — harmless, but a smoke must not write into the tree it
// smokes, so the scratch config strips closeBundle from those three BY NAME
// (their transformIndexHtml stamps stay: the version badge still paints) and
// emits the scratch dist's own version.json. The build is verified by its
// EFFECT: the emitted bundle must carry the accessor, or the start is refused.
//
// AUTO MODE (task 1793577865): render-driven smokes - a ResizeObserver, a
// matchMedia change listener, requestAnimationFrame - cannot be driven from
// the claude-in-chrome extension's tab when its tab-group window is occluded:
// Chrome defers EVERY such callback in a hidden document
// (document.visibilityState === "hidden"; after ~5 min it throttles chained
// timers to one a minute too) while forced-layout reads (offsetHeight,
// getComputedStyle, an inline paint) still answer, so a smoke of --chrome-h
// across the 900px breakpoint read a stale value there (task 1793575742),
// and nothing from a seat can raise the window (window.open is popup-
// blocked; Chrome's AppleScript dictionary times out; no assistive access).
// So the page drives itself in a fresh, visible window on its OWN timers:
//   /__auto.html?w=<px>&h=<px>&route=<slug>&script=<name>
// is generated in memory (never written into the dist it serves) around the
// smoke script read from tests/smoke/<name>.mjs - <name> a slug like `route`
// (^[a-z0-9][a-z0-9_-]*$: no '/', no '.', so no path traversal; the file is
// read per request, so an edit is live without a restart) - embedded as a
// string literal and imported from a blob: URL, so the script is an ordinary
// ES module: `export default async function (api) { ... }`. `api`:
//   frame                 the app window (iframe #app of /?nocache=1#<route>),
//                         handed over once its document is complete
//   waitFor(pred, ms)     polls pred every 50 ms on setTimeout; resolves with
//                         its truthy value, rejects after ms (default 10 s)
//   setWidth(px, settle)  resizes the iframe, waits `settle` ms (default 400)
//                         on the page's own timer - never on a rAF, which a
//                         hidden page would await forever - and resolves
//                         with read()
//   read()                async: { visibility: {page, frame}, raf ("<n>ms" or
//                         "no rAF in 250ms"), chromeH (the frame's --chrome-h),
//                         topChromeH, headerH, banner: {class, display, h}
//                         (#fuel-banner's className, computed display,
//                         offsetHeight), controls: {mq, ro}, width, frameW }.
//                         The two controls are the page's own
//                         matchMedia("(max-width: 900px)") change listener
//                         and ResizeObserver on #top-chrome INSIDE the frame:
//                         they count only when the frame's rendering
//                         callbacks actually run
//   log(line)             appends the line to the page's <pre> and POSTs it
//                         to /__result/<name> (text/plain; the promise is the
//                         POST). The lines also land in localStorage under
//                         "__auto:<name>" as {done, at, lines} - a secondary
//                         channel for a same-origin tab
//   iframe, sleep(ms), controls   the raw pieces, for scripts that need them
// The script's return value ends the run: a string starting `done` is the
// done line verbatim, a positive integer N is `done FAIL N` (failed checks),
// anything else `done ok`. A throw logs `error <message>` then `done FAIL
// error`; the page's deadline (--result-timeout minus 2 s, else 10 min) logs
// `done FAIL timeout` - and in EVERY case the page window.close()s itself so
// no window lingers (a window with a single history entry may close itself).
// Which way it went is reported too: a pagehide beacon (`closed (pagehide:
// ...)`) when the window goes away, or `close refused - ...` 0.7 s later
// when Chrome kept it; with --script the harness waits up to 1.5 s after
// the done line for one of them, prints `closed ...`, and names a lingering
// window on stderr. Verified 2026-11-02 on a seat venue: the beacon arrives.
// Results need no extension: POST /__result/<name> (one or more lines) is
// kept in memory, each line is printed to this process's stdout as it
// arrives (`[<name>] <line>`), and GET /__result/<name> serves them as
// text/plain (404 until the first line - a curl loop can wait on it). With
// --script the first `done` line for THAT name ends the run (above).
//
// Not a daemon: foreground, Ctrl-C to stop; it prints its own pid. It never
// runs the CLI and never acts as an identity (law 10), and it never binds or
// references the operator's machine-global venue port — tests/
// test_deploy_hygiene.sh §3g pins both literals out of this file, comments
// included. Behaviour: tests/smoke_harness.test.mjs (stub gateway, no venue).

import http from "node:http";
import { createReadStream, existsSync, mkdtempSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, extname, join, normalize, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn, spawnSync } from "node:child_process";
import { parseArgs } from "node:util";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const FRIENDLY = "frontend.local.localhost"; // every venue's friendly name — hence the unique host below
const LOOPBACK = "127.0.0.1";
const USAGE = "usage: node scripts/smoke-harness.mjs --gateway <port> [--dist <dir>] [--port <n>] [--name <label>] [--charts] [--script <name> [--open] [--result-timeout <s>]]";
// /__harness.html?route=<slug>: the app's hash routes are lowercase slugs
// (swap, docs/launch, ai/agent-chat, account/deposit - routeFromHash in
// main.js lowercases the TAB and splits on "/") with one exception, the
// market deep link markets/<ID>: the app writes the id verbatim
// (href="#markets/${m.id}"), ids are uppercase (BTC-ICPUSD) and selectMarket
// matches them exactly (m.id === marketId), so the first segment stays
// lowercase and the segments after it may carry mixed case (task
// 1793561650). Nothing else - no `#`, no `?`, no quote, angle bracket or
// ampersand, which is what lets the value be interpolated into the page.
const ROUTE_RE = /^[a-z0-9][a-z0-9_-]*(?:\/[A-Za-z0-9][A-Za-z0-9_-]*)*$/;
const HARNESS_USAGE = "usage: /__harness.html?w=<px>&h=<px>&route=<slug> - w, h: 100..4000 (default 375x780); route: the app hash without its '#' - tab lowercase (swap, docs/launch, ai/agent-chat, account/deposit); a market id keeps its case (markets/BTC-ICPUSD) (default markets; must match ^[a-z0-9][a-z0-9_-]*(?:/[A-Za-z0-9][A-Za-z0-9_-]*)*$)";
// The auto page (header, AUTO MODE): a smoke script is named by a SLUG and
// read from tests/smoke/<name>.mjs - no '/', no '.', so the name can never
// walk out of that directory, and it interpolates into the page safely.
const SLUG_RE = /^[a-z0-9][a-z0-9_-]*$/;
const SMOKE_DIR = join(REPO, "tests", "smoke");
const AUTO_USAGE = "usage: /__auto.html?w=<px>&h=<px>&route=<slug>&script=<name> - w, h and route as /__harness.html; script (REQUIRED): the smoke script tests/smoke/<name>.mjs by name - a lowercase slug ^[a-z0-9][a-z0-9_-]*$, no '/', no '.' (read from the repo, never a path); its lines: POST/GET /__result/<name>";
const RESULT_USAGE = "usage: POST /__result/<name> (text/plain, one report line per line) and GET /__result/<name> (text/plain; 404 until the first line) - <name> is the smoke script's slug, ^[a-z0-9][a-z0-9_-]*$";
function smokeScriptPath(slug) { return join(SMOKE_DIR, `${slug}.mjs`); }

function die(msg) {
  process.stderr.write(`smoke-harness: ${msg}\n`);
  process.exit(1);
}

// ── Arguments ───────────────────────────────────────────────────────
let args;
try {
  args = parseArgs({
    options: {
      gateway: { type: "string" },
      dist: { type: "string" },
      port: { type: "string", default: "0" },
      name: { type: "string" },
      charts: { type: "boolean", default: false },
      script: { type: "string" },
      open: { type: "boolean", default: false },
      "result-timeout": { type: "string" },
      help: { type: "boolean", short: "h", default: false },
    },
    strict: true,
    allowPositionals: false,
  }).values;
} catch (e) {
  die(`${e.message}\n${USAGE}`);
}
if (args.help) {
  const header = readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n")
    .slice(1).filter((l) => l.startsWith("//")).map((l) => l.replace(/^\/\/ ?/, ""));
  console.log(header.join("\n"));
  process.exit(0);
}

function portOf(raw, flag, allowZero) {
  if (raw === undefined) die(`--gateway <port> is required — the seat venue's own gateway port (never guessed, never a machine-global default)\n${USAGE}`);
  const n = Number(raw);
  if (!Number.isInteger(n) || n < (allowZero ? 0 : 1) || n > 65535) die(`${flag} must be a port number (got ${JSON.stringify(raw)})`);
  return n;
}
const gateway = portOf(args.gateway, "--gateway", false);
const listenPort = portOf(args.port, "--port", true);

function readPin() {
  try { return readFileSync(join(REPO, ".factory-worker"), "utf8").split("\n")[0].trim() || null; } catch { return null; }
}
const name = (args.name || readPin() || "seat").trim();
if (!/^[a-z0-9][a-z0-9-]*$/i.test(name)) die(`--name must be a DNS label (letters, digits, dashes): ${JSON.stringify(name)}`);
const host = `${name}-smoke.local.localhost`;

// ── Auto mode: --script / --open / --result-timeout ─────────────────
const awaited = args.script ?? null;   // the smoke script whose `done` line ends this run
if (awaited !== null) {
  if (!SLUG_RE.test(awaited)) die(`--script must name a smoke script by slug (tests/smoke/<name>.mjs; ^[a-z0-9][a-z0-9_-]*$, never a path): ${JSON.stringify(awaited)}\n${USAGE}`);
  if (!existsSync(smokeScriptPath(awaited))) die(`--script ${awaited}: no tests/smoke/${awaited}.mjs under ${REPO}`);
}
if (args.open && awaited === null) die(`--open needs --script <name> (the auto page it opens)\n${USAGE}`);
let resultTimeoutS = awaited === null ? 0 : 120;   // with --script: 120 s unless told otherwise; 0 = wait
if (args["result-timeout"] !== undefined) {
  if (awaited === null) die(`--result-timeout needs --script <name>\n${USAGE}`);
  const n = Number(args["result-timeout"]);
  if (!Number.isInteger(n) || n < 0) die(`--result-timeout must be a whole number of seconds (0 = wait; got ${JSON.stringify(args["result-timeout"])})`);
  resultTimeoutS = n;
}

// ── --charts: the scratch build ─────────────────────────────────────
function buildChartsDist() {
  // The repo's config by either spelling: .mjs first (Vite 8 asks for it; the repo's spelling since task 1793503783), then the legacy .js.
  const baseCfg = ["vite.config.mjs", "vite.config.js"].map((f) => join(REPO, f)).find((f) => existsSync(f)) || join(REPO, "vite.config.mjs");
  const mainJs = join(REPO, "src", "frontend", "src", "main.js");
  const viteBin = join(REPO, "node_modules", "vite", "bin", "vite.js");
  for (const [what, p] of [["the repo's vite.config.mjs", baseCfg], ["src/frontend/src/main.js", mainJs], ["vite (npm install first)", viteBin]]) {
    if (!existsSync(p)) die(`--charts: ${what} not found at ${p}`);
  }
  const version = JSON.parse(readFileSync(join(REPO, "package.json"), "utf8")).version;
  const scratch = mkdtempSync(join(tmpdir(), "mdx-smoke-charts-"));
  const outDir = join(scratch, "dist");
  const cfg = `// generated by scripts/smoke-harness.mjs --charts — a scratch build; the tree's dist/ is never written
import { writeFileSync } from "node:fs";
import base from ${JSON.stringify(baseCfg)};
const MAIN = ${JSON.stringify(mainJs)};
const OUT = ${JSON.stringify(outDir)};
const HOOK = "\\n;window.__mdxCharts = () => ({ chart: chartInstance, mini: miniChartInstance, candles: chartCandleData });\\n";
// Base plugins whose closeBundle resolves ./dist from the CONFIG FILE — the
// repo's gitignored dist/ — and would re-stamp it from this scratch build.
const REPO_DIST_WRITERS = new Set(["emit-version-json", "emit-well-known-ic-app-manifest", "bake-ai-connect-canister-id"]);
let applied = 0;
const plugins = (base.plugins || []).flat().filter(Boolean).map((p) => {
  if (REPO_DIST_WRITERS.has(p.name)) { const { closeBundle, ...rest } = p; return rest; }
  if (p.closeBundle) console.warn("[smoke-harness --charts] base plugin " + p.name + " carries a closeBundle hook this scratch config does not know — check that it writes nowhere in the tree");
  return p;
});
plugins.push({
  name: "mdx-smoke-charts-hook",
  transform(code, id) {
    if (id.split("?")[0] !== MAIN) return null;
    applied++;
    return { code: code + HOOK, map: null };
  },
  closeBundle() {
    if (applied !== 1) throw new Error("[smoke-harness --charts] the __mdxCharts hook was applied " + applied + " times (expected exactly 1) — did src/frontend/src/main.js move?");
    writeFileSync(OUT + "/version.json", JSON.stringify({ version: ${JSON.stringify(version)}, builtAt: new Date().toISOString(), scratch: true }) + "\\n");
    console.log("[smoke-harness --charts] __mdxCharts accessor appended to main.js; scratch version.json emitted");
  },
});
export default { ...base, plugins, build: { ...(base.build || {}), outDir: OUT, emptyOutDir: true } };
`;
  const cfgPath = join(scratch, "vite.config.mjs");
  writeFileSync(cfgPath, cfg);
  console.log(`smoke-harness --charts: scratch build → ${outDir}`);
  const r = spawnSync(process.execPath, [viteBin, "build", "--config", cfgPath], { cwd: REPO, stdio: "inherit" });
  if (r.status !== 0) die(`--charts: vite build failed (exit ${r.status ?? r.signal}); scratch config kept at ${cfgPath}`);
  // Verify the EFFECT, not the mechanism: the emitted bundle must carry the accessor.
  const assets = join(outDir, "assets");
  const hooked = existsSync(assets) && readdirSync(assets).some((f) => f.endsWith(".js") && readFileSync(join(assets, f), "utf8").includes("__mdxCharts"));
  if (!hooked) die(`--charts: the bundle built under ${outDir} carries no __mdxCharts accessor — the transform did not land`);
  return outDir;
}

let dist = args.dist ? resolve(args.dist) : join(REPO, "dist");
if (args.charts) dist = buildChartsDist();
if (!existsSync(join(dist, "index.html"))) die(`no index.html under ${dist} — build the bundle first (npm run build) or pass --dist <dir>`);

// ── The venue's cookie ──────────────────────────────────────────────
function fetchVenueCookie(port) {
  return new Promise((done) => {
    const req = http.request(
      { host: LOOPBACK, port, method: "HEAD", path: "/", headers: { host: `${FRIENDLY}:${port}` }, timeout: 5000 },
      (res) => {
        res.resume();
        const line = (res.headers["set-cookie"] || []).find((c) => c.startsWith("ic_env="));
        done({ status: res.statusCode, cookie: line || null });
      },
    );
    req.on("timeout", () => req.destroy(new Error("timed out after 5 s")));
    req.on("error", (e) => done({ error: e }));
    req.end();
  });
}
// ic_env=<url-encoded "ic_root_key=…&PUBLIC_CANISTER_ID:backend=…&…">; SameSite=Lax
function cookieIds(cookie) {
  try {
    return decodeURIComponent(cookie.slice("ic_env=".length).split(";")[0])
      .split("&").filter((kv) => kv.startsWith("PUBLIC_CANISTER_ID:"))
      .map((kv) => kv.slice("PUBLIC_CANISTER_ID:".length)).join(" ");
  } catch { return "(undecodable)"; }
}

const probe = await fetchVenueCookie(gateway);
if (probe.error) die(`no gateway answering at ${LOOPBACK}:${gateway} (${probe.error.code || probe.error.message}) — is the seat venue running?`);
if (!probe.cookie) die(`frontend not deployed on ${gateway} — HEAD http://${FRIENDLY}:${gateway}/ answered ${probe.status} with no ic_env Set-Cookie (the bundle reads its canister ids from it; deploy the frontend to this venue first)`);
const COOKIE = probe.cookie;

// ── Serving ─────────────────────────────────────────────────────────
const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
  ".json": "application/json; charset=utf-8",
  ".json5": "application/json5",
  ".map": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json",
  ".woff2": "font/woff2",
  ".woff": "font/woff",
  ".ttf": "font/ttf",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".txt": "text/plain; charset=utf-8",
  ".pdf": "application/pdf",
  ".wasm": "application/wasm",
};
const HOP_BY_HOP = new Set(["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade"]);

function sendHtml(req, res, body, extra = {}) {
  res.writeHead(200, { "content-type": TYPES[".html"], "cache-control": "no-store", "content-length": Buffer.byteLength(body), "set-cookie": COOKIE, ...extra });
  res.end(req.method === "HEAD" ? undefined : body);
}
function sendText(res, status, text) {
  res.writeHead(status, { "content-type": TYPES[".txt"], "cache-control": "no-store" });
  res.end(text + "\n");
}

// ?w=&h=: 100..4000, else the defaults (375x780) - shared by both pages.
function pageDims(u) {
  const dim = (k, d) => { const n = parseInt(u.searchParams.get(k) ?? "", 10); return Number.isInteger(n) && n >= 100 && n <= 4000 ? n : d; };
  return { w: dim("w", 375), h: dim("h", 780) };
}

function harnessPage(req, res) {
  const u = new URL(req.url, "http://x");
  const { w, h } = pageDims(u);
  // Sizes fall back to the defaults; the route does not - a value that is not
  // a slug is a mistake worth a 400 (a silent #markets would measure the
  // wrong view). Absent = markets; present and empty = refused.
  const route = u.searchParams.get("route") ?? "markets";
  if (!ROUTE_RE.test(route)) return sendText(res, 400, `smoke-harness: bad route ${JSON.stringify(route)} - ${HARNESS_USAGE}`);
  // The hash appears ONCE below, in the iframe src, so `grep -c '#<route>'` on this page reads 1.
  sendHtml(req, res, `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>smoke harness ${w}x${h} ${route}</title>
<style>body{margin:0;min-height:100vh;background:#1e1e1e;color:#ccc;font:12px/1.4 system-ui,sans-serif;display:flex;flex-direction:column;align-items:center;gap:8px;padding:12px;box-sizing:border-box}code{color:#9cf}iframe{border:1px solid #555;background:#fff;flex:none}</style></head>
<body><p>${w} &times; ${h} &middot; route <code>${route}</code> (<code>&amp;route=&lt;slug&gt;</code>, default <code>markets</code>) &middot; frame: <code>document.getElementById("app").contentWindow</code> &middot; size: <code>?w=&amp;h=</code></p>
<iframe id="app" src="/?nocache=1#${route}" width="${w}" height="${h}" style="width:${w}px;height:${h}px"></iframe>
</body></html>
`);
}

// ── The auto page (header, AUTO MODE) ───────────────────────────────
// The page's own script, inlined as a module after three constants the
// request supplies (NAME, SRC, DEADLINE_MS). String.raw: the escapes below
// (\n, \b, \r) reach the browser as written. No template syntax inside.
const AUTO_PAGE_SCRIPT = String.raw`
const iframe = document.getElementById("app");
const out = document.getElementById("log");
const lines = [];
const posts = [];
const controls = { mq: 0, ro: 0 };
let frame = null;
let finishing = false;
function stash(done) {
  try { localStorage.setItem("__auto:" + NAME, JSON.stringify({ done: done, at: new Date().toISOString(), lines: lines })); } catch (e) { /* storage blocked: the POST is the channel */ }
}
function log(line) {
  line = String(line).replace(/\r?\n/g, " ");
  lines.push(line);
  out.textContent += line + "\n";
  stash(/^done\b/.test(line));
  const p = fetch("/__result/" + NAME, { method: "POST", headers: { "content-type": "text/plain; charset=utf-8" }, body: line, keepalive: true }).catch(function () {});
  posts.push(p);
  return p;
}
// The window going away is reported by a beacon (it survives the unload):
// after the done line it is the self-close taking; before it, the window
// was closed on the page - either way the harness learns why it went quiet.
window.addEventListener("pagehide", function () {
  try { navigator.sendBeacon("/__result/" + NAME, "closed (pagehide: this window went away " + (finishing ? "after" : "BEFORE") + " its done line)"); } catch (e) { /* nothing left to report to */ }
});
function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
function waitFor(pred, ms, every) {
  if (ms === undefined) ms = 10000;
  if (every === undefined) every = 50;
  const until = performance.now() + ms;
  return new Promise(function (resolve, reject) {
    function tick() {
      let v;
      try { v = pred(); } catch (e) { v = undefined; }
      if (v) return resolve(v);
      if (performance.now() >= until) return reject(new Error("waitFor: timed out after " + ms + " ms on " + (pred.name || String(pred).slice(0, 80))));
      setTimeout(tick, every);
    }
    tick();
  });
}
function rafProbe() {
  return new Promise(function (resolve) {
    const t0 = performance.now();
    let settled = false;
    const timer = setTimeout(function () { if (!settled) { settled = true; resolve("no rAF in 250ms"); } }, 250);
    requestAnimationFrame(function () { if (!settled) { settled = true; clearTimeout(timer); resolve(Math.round(performance.now() - t0) + "ms"); } });
  });
}
async function read() {
  const d = frame ? frame.document : null;
  const root = d ? d.documentElement : null;
  const top = d ? d.getElementById("top-chrome") : null;
  const header = d ? d.querySelector("header.header") : null;
  const banner = d ? d.getElementById("fuel-banner") : null;
  const cs = frame ? function (el) { return frame.getComputedStyle(el); } : null;
  return {
    visibility: { page: document.visibilityState, frame: d ? d.visibilityState : null },
    raf: await rafProbe(),
    chromeH: root ? cs(root).getPropertyValue("--chrome-h").trim() : null,
    topChromeH: top ? top.offsetHeight : null,
    headerH: header ? header.offsetHeight : null,
    banner: banner ? { class: banner.className, display: cs(banner).display, h: banner.offsetHeight } : null,
    controls: { mq: controls.mq, ro: controls.ro },
    width: iframe.offsetWidth,
    frameW: frame ? frame.innerWidth : null,
  };
}
async function setWidth(px, settleMs) {
  if (settleMs === undefined) settleMs = 400;
  iframe.width = String(px);
  iframe.style.width = px + "px";
  await sleep(settleMs);   // the page's own timer - never a rAF, which a hidden page would await forever
  return read();
}
function installControls() {
  try {
    frame.matchMedia("(max-width: 900px)").addEventListener("change", function () { controls.mq++; });
    const top = frame.document.getElementById("top-chrome");
    if (top) new frame.ResizeObserver(function () { controls.ro++; }).observe(top);
  } catch (e) { log("controls: not installed: " + e.message); }
}
async function finish(doneLine) {
  if (finishing) return;
  finishing = true;
  await log(doneLine);
  await Promise.allSettled(posts);
  out.textContent += "closing this window\n";
  window.close();
  // Still here 0.7 s later = Chrome kept the window: say so on the page AND
  // to the harness, which is waiting for exactly this or the pagehide beacon.
  setTimeout(function () {
    out.textContent += "window.close() was refused (a tab with history, or one a script may not close) - close it by hand\n";
    log("close refused - window.close() did not close this window (a tab with history, or one a script may not close); close it by hand");
  }, 700);
}
const deadline = setTimeout(function () {
  log("error script timed out after " + DEADLINE_MS + " ms (the page's own deadline, 2 s inside the harness's)");
  finish("done FAIL timeout");
}, DEADLINE_MS);
(async function () {
  log("auto " + NAME + " start " + new Date().toISOString() + " visibility " + document.visibilityState + " frame " + iframe.width + "x" + iframe.height);
  await waitFor(function frameComplete() {
    const d = iframe.contentDocument;
    return d && d.location.href !== "about:blank" && d.readyState === "complete" && d.getElementById("top-chrome");
  }, 30000);
  frame = iframe.contentWindow;
  installControls();
  const mod = await import(URL.createObjectURL(new Blob([SRC], { type: "text/javascript" })));
  if (typeof mod.default !== "function") throw new Error("tests/smoke/" + NAME + ".mjs has no default export function (expected: export default async function (api) {})");
  const result = await mod.default({ frame: frame, iframe: iframe, waitFor: waitFor, setWidth: setWidth, read: read, log: log, sleep: sleep, controls: controls });
  clearTimeout(deadline);
  const doneLine = (typeof result === "string" && /^done\b/.test(result)) ? result
    : (Number.isInteger(result) && result > 0) ? "done FAIL " + result
    : "done ok";
  await finish(doneLine);
})().catch(async function (e) {
  clearTimeout(deadline);
  log("error " + (e && e.stack ? String(e.stack).split("\n").slice(0, 3).join(" | ") : String(e)));
  await finish("done FAIL error");
});
`;

function autoPage(req, res) {
  const u = new URL(req.url, "http://x");
  const { w, h } = pageDims(u);
  const route = u.searchParams.get("route") ?? "markets";
  if (!ROUTE_RE.test(route)) return sendText(res, 400, `smoke-harness: bad route ${JSON.stringify(route)} - ${AUTO_USAGE}`);
  const script = u.searchParams.get("script");
  if (script === null) return sendText(res, 400, `smoke-harness: /__auto.html needs script=<name> - ${AUTO_USAGE}`);
  if (!SLUG_RE.test(script)) return sendText(res, 400, `smoke-harness: bad script ${JSON.stringify(script)} (a slug: lowercase, no '/', no '.') - ${AUTO_USAGE}`);
  let src;
  try { src = readFileSync(smokeScriptPath(script), "utf8"); } catch { return sendText(res, 400, `smoke-harness: no such smoke script tests/smoke/${script}.mjs - ${AUTO_USAGE}`); }
  // The page's own deadline sits 2 s inside the harness's (10 min with no harness deadline), so the window closes itself before the harness gives up.
  const deadlineMs = resultTimeoutS > 0 ? Math.max(5000, resultTimeoutS * 1000 - 2000) : 600000;
  // The script travels as a JS string literal: JSON escapes it, and `</`
  // becomes `<\/` so no `</script>` inside it can end the inline module.
  const lit = JSON.stringify(src).replace(/<\//g, "<\\/");
  sendHtml(req, res, `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>smoke auto ${script} ${w}x${h} ${route}</title>
<style>body{margin:0;min-height:100vh;background:#1e1e1e;color:#ccc;font:12px/1.4 system-ui,sans-serif;display:flex;flex-direction:column;align-items:flex-start;gap:8px;padding:12px;box-sizing:border-box}code{color:#9cf}iframe{border:1px solid #555;background:#fff;flex:none}pre{margin:0;white-space:pre-wrap;color:#ddd;font:12px/1.5 ui-monospace,Menlo,monospace}</style></head>
<body><p>auto <code>${script}</code> &middot; ${w} &times; ${h} &middot; route <code>${route}</code> &middot; results: <code>GET /__result/${script}</code> &middot; this window closes itself when the script is done</p>
<iframe id="app" src="/?nocache=1#${route}" width="${w}" height="${h}" style="width:${w}px;height:${h}px"></iframe>
<pre id="log"></pre>
<script type="module">
const NAME = ${JSON.stringify(script)};
const SRC = ${lit};
const DEADLINE_MS = ${deadlineMs};
${AUTO_PAGE_SCRIPT}
</script>
</body></html>
`);
}

// ── Results: POST /__result/<name> → memory + stdout; GET serves them ──
const RESULT_CAP = 64 * 1024;   // per POST; the page sends one line at a time
const results = new Map();      // slug -> lines, in arrival order
let doneSeen = false;
let resultTimer = null;
function settle(doneLine) {
  const ok = doneLine === "done" || /^done ok\b/.test(doneLine);
  process.stdout.write(`  done      ${awaited}: ${doneLine}${ok ? "" : " - exiting 1"}\n`);
  if (resultTimer) clearTimeout(resultTimer);
  // The page window.close()s itself right after its done line: its pagehide
  // beacon (`closed ...`) says the window went away, its `close refused` line
  // (0.7 s later) that Chrome kept it. Wait up to 1.5 s for either, so a
  // lingering window is NAMED here instead of discovered on the desktop.
  const started = Date.now();
  const poll = setInterval(() => {
    const lines = results.get(awaited) || [];
    const closed = lines.some((l) => /^closed\b/.test(l));
    const refused = lines.some((l) => /^close refused\b/.test(l));
    if (!closed && !refused && Date.now() - started < 1500) return;
    clearInterval(poll);
    if (closed) process.stdout.write(`  closed    the auto window closed itself (its pagehide beacon arrived)\n`);
    else if (refused) process.stderr.write(`smoke-harness: the auto window for ${awaited} did NOT close itself (window.close() refused) - close it by hand\n`);
    else process.stdout.write(`  closed    unconfirmed - no pagehide beacon within 1.5 s of the done line; look for a lingering window\n`);
    stop(ok ? 0 : 1);
  }, 50);
}
function resultRoute(req, res) {
  const path = req.url.split("?")[0];
  let slug;
  try { slug = decodeURIComponent(path.slice("/__result/".length)); } catch { slug = path.slice("/__result/".length); }
  if (!SLUG_RE.test(slug)) return sendText(res, 400, `smoke-harness: bad result name ${JSON.stringify(slug)} - ${RESULT_USAGE}`);
  if (req.method === "GET" || req.method === "HEAD") {
    const lines = results.get(slug);
    if (!lines) return sendText(res, 404, `smoke-harness: no results for ${slug} yet - ${RESULT_USAGE}`);
    const body = lines.join("\n") + "\n";
    res.writeHead(200, { "content-type": TYPES[".txt"], "cache-control": "no-store", "content-length": Buffer.byteLength(body) });
    return res.end(req.method === "HEAD" ? undefined : body);
  }
  if (req.method !== "POST") return sendText(res, 405, `smoke-harness: /__result/<name> takes POST and GET - ${RESULT_USAGE}`);
  const chunks = [];
  let size = 0;
  req.on("data", (c) => { size += c.length; if (size <= RESULT_CAP) chunks.push(c); });
  req.on("end", () => {
    if (size > RESULT_CAP) return sendText(res, 413, `smoke-harness: result body over ${RESULT_CAP} bytes - one line per POST`);
    const lines = Buffer.concat(chunks).toString("utf8").split(/\r?\n/).map((l) => l.trimEnd()).filter((l) => l.length > 0);
    let kept = results.get(slug);
    if (!kept) { kept = []; results.set(slug, kept); }
    for (const line of lines) {
      kept.push(line);
      process.stdout.write(`[${slug}] ${line}\n`);
      if (slug === awaited && !doneSeen && /^done\b/.test(line)) { doneSeen = true; settle(line); }
    }
    res.writeHead(204, { "cache-control": "no-store" });
    res.end();
  });
}

function proxyApi(req, res) {
  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) if (!HOP_BY_HOP.has(k)) headers[k] = v;
  headers.host = `${LOOPBACK}:${gateway}`;
  const up = http.request({ host: LOOPBACK, port: gateway, method: req.method, path: req.url, headers }, (ures) => {
    const out = {};
    for (const [k, v] of Object.entries(ures.headers)) if (!HOP_BY_HOP.has(k)) out[k] = v;
    res.writeHead(ures.statusCode, ures.statusMessage, out);
    ures.pipe(res);
  });
  up.on("error", (e) => {
    if (!res.headersSent) sendText(res, 502, `smoke-harness: upstream ${LOOPBACK}:${gateway} failed: ${e.code || e.message}`);
    else res.destroy();
  });
  res.on("close", () => { if (!res.writableFinished) up.destroy(); });
  req.pipe(up);
}

function serveStatic(req, res) {
  let pathname;
  try { pathname = decodeURIComponent(new URL(req.url, "http://x").pathname); } catch { return sendText(res, 400, "smoke-harness: bad request path"); }
  // normalize("/…") drops leading ".." segments, so the join can never leave dist.
  let file = join(dist, normalize("/" + pathname));
  if (file !== dist && !file.startsWith(dist + sep)) file = join(dist, "index.html");
  let st = null;
  try { st = statSync(file); } catch { st = null; }
  if (st && st.isDirectory()) { file = join(file, "index.html"); try { st = statSync(file); } catch { st = null; } }
  if (st && st.isFile()) {
    const type = TYPES[extname(file).toLowerCase()] || "application/octet-stream";
    const headers = { "content-type": type, "cache-control": "no-store", "content-length": st.size };
    if (type.startsWith("text/html")) headers["set-cookie"] = COOKIE;
    res.writeHead(200, headers);
    if (req.method === "HEAD") return res.end();
    return createReadStream(file).on("error", () => res.destroy()).pipe(res);
  }
  // SPA fallback: index.html with the cookie, marked so curl can tell it from a real file.
  const html = readFileSync(join(dist, "index.html"));
  res.writeHead(200, { "content-type": TYPES[".html"], "cache-control": "no-store", "content-length": html.length, "set-cookie": COOKIE, "x-smoke-fallback": "index.html" });
  res.end(req.method === "HEAD" ? undefined : html);
}

const server = http.createServer((req, res) => {
  const path = req.url.split("?")[0];
  if (path === "/__harness.html") return harnessPage(req, res);
  if (path === "/__auto.html") return autoPage(req, res);
  if (path === "/__result" || path.startsWith("/__result/")) return resultRoute(req, res);
  if (path === "/api" || path.startsWith("/api/")) return proxyApi(req, res);
  if (req.method !== "GET" && req.method !== "HEAD") return sendText(res, 405, "smoke-harness: static side — GET/HEAD only (/api/* is proxied)");
  return serveStatic(req, res);
});
server.on("error", (e) => die(`cannot listen on ${LOOPBACK}:${listenPort}: ${e.code || e.message}`));
server.listen(listenPort, LOOPBACK, () => {
  const port = server.address().port;
  const out = [
    `smoke-harness pid ${process.pid}`,
    `  gateway   ${LOOPBACK}:${gateway}  (ic_env cookie copied: ${cookieIds(COOKIE)})`,
    `  dist      ${dist}`,
    `  open      http://${host}:${port}/`,
    `  harness   http://${host}:${port}/__harness.html?w=375&h=780`,
  ];
  if (awaited !== null) {
    const autoUrl = `http://${host}:${port}/__auto.html?w=375&h=780&route=markets&script=${awaited}`;
    out.push(`  auto      ${autoUrl}`);
    out.push(`  results   http://${host}:${port}/__result/${awaited}  (each line prints below as [${awaited}] <line>; exit 0 on "done ok", 1 on any other done line)`);
    out.push(`  deadline  ${resultTimeoutS > 0 ? `${resultTimeoutS} s for a done line (--result-timeout; 0 = wait)` : "none (--result-timeout 0): Ctrl-C or kill the pid if no done line comes"}`);
    if (args.open) {
      if (process.platform === "darwin") {
        // LaunchServices hands the URL to the running Chrome's singleton,
        // which opens a NEW front window (task 1793575742's recipe).
        const opener = spawn("open", ["-na", "Google Chrome", "--args", "--new-window", autoUrl], { stdio: "ignore" });
        opener.on("error", (e) => process.stderr.write(`smoke-harness: open failed (${e.message}) - load the auto URL yourself\n`));
        opener.on("exit", (code) => { if (code !== 0) process.stderr.write(`smoke-harness: open exited ${code} - load the auto URL yourself\n`); });
        out.push(`  launched  a fresh Chrome window: open -na "Google Chrome" --args --new-window <auto url>`);
      } else {
        out.push(`  launched  nothing: --open drives macOS LaunchServices only (this is ${process.platform}) - load the auto URL yourself`);
      }
    }
    if (resultTimeoutS > 0) {
      resultTimer = setTimeout(() => {
        process.stderr.write(`smoke-harness: no done line from ${awaited} within ${resultTimeoutS} s (${(results.get(awaited) || []).length} line(s) arrived) - exiting 1\n`);
        stop(1);
      }, resultTimeoutS * 1000);
    }
  }
  out.push(`  stop      Ctrl-C (or kill ${process.pid}); not a daemon`, "");
  process.stdout.write(out.join("\n"));
});

let stopping = false;
function stop(code = 0) {
  if (stopping) return;
  stopping = true;
  server.close(() => process.exit(code));
  server.closeAllConnections();
  setTimeout(() => process.exit(code), 500).unref();
}
process.on("SIGINT", () => stop(0));
process.on("SIGTERM", () => stop(0));
