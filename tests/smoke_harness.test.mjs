#!/usr/bin/env node
// tests/smoke_harness.test.mjs — behavioural guards for scripts/smoke-harness.mjs
// (task 1793500998), in the shape of tests/frontend_security.test.mjs: plain
// `node tests/smoke_harness.test.mjs`, no deps, no venue, no browser, nothing
// off loopback. tests/run_all.sh discovers *.test.mjs, so this runs on every
// seat — everything it needs it starts itself:
//
//   - a STUB gateway (node:http on 127.0.0.1:0) that answers HEAD / with a
//     fake `set-cookie: ic_env=…; SameSite=Lax` and echoes every /api/*
//     request back as JSON (method, url, Host header, body) — the two legs of
//     the real gateway as the harness sees them;
//   - a temp dist (index.html + one .js) under os.tmpdir();
//   - the harness itself, spawned against the stub and killed BY THE PID WE
//     SPAWNED at the end (mdex-process-safety: never a pattern), its port
//     asserted gone afterwards. A global timer kills our own children on a
//     hang, so this file can never leave a listener behind.
//
// Asserted: the HTML carries the copied cookie and the .js does not; GET
// /api/v2/status and a POST /api/v3/canister/x/query reach the stub with
// method, path and body intact and Host rewritten to 127.0.0.1:<gateway>;
// /__harness.html?w=375&h=780 sizes the iframe 375x780 and defaults to it
// without the query, framing /?nocache=1#<route> - `markets` by default,
// `&route=swap` or `docs/launch` directly (task 1793555363: no post-load
// hash flip), the market deep link `markets/BTC-ICPUSD` with its id's case
// kept (task 1793561650) - while a value off the pattern ('#', an uppercase
// TAB, empty, markup) is a 400 carrying the page's usage as text/plain; an
// unknown path returns index.html (SPA fallback); no
// XFO / CSP leaves the harness; a dead upstream is a 502; a stub WITHOUT the
// cookie makes the harness exit non-zero naming "frontend not deployed on
// <port>"; a closed gateway port and a missing --gateway are refused too.
// Auto mode (task 1793577865): /__auto.html?w=&h=&route=&script=<name> is a
// 200 HTML page with the cookie and no XFO / CSP, sized and routed like the
// harness page, carrying tests/smoke/<name>.mjs embedded as a string literal
// and posting to /__result/<name>; a missing, traversal, dotted, unknown,
// uppercase or empty `script` is a 400 naming the usage as text/plain;
// POST /__result/<name> round-trips to GET (404 before the first line, 204
// per POST, appended in order) and each line reaches the harness's stdout as
// `[<name>] <line>`; with --script the awaited `done ok` exits 0, `done FAIL
// n` exits 1, --result-timeout 1 with no done line exits 1 naming it, and
// --script / --open / --result-timeout misuse is refused at start; the
// harness file still carries neither of hygiene §3g's two banned literals.

import http from "node:http";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const HARNESS = join(ROOT, "scripts", "smoke-harness.mjs");
const LOOPBACK = "127.0.0.1";
// What the asset canister sets (shape only): the url-encoded root key + ids.
const COOKIE = "ic_env=ic%5Froot%5Fkey%3Dstub%26PUBLIC%5FCANISTER%5FID%3Abackend%3Daaaaa%2Daa%26PUBLIC%5FCANISTER%5FID%3Afrontend%3Dbbbbb%2Dbb; SameSite=Lax";

let passed = 0;
let failed = 0;
function ok(name) { passed++; console.log(`✓ ${name}`); }
function bad(name, detail) {
  failed++;
  console.log(`✗ ${name}`);
  if (detail) console.log(`    ${String(detail).split("\n").join("\n    ")}`);
}
function check(name, cond, detail) { cond ? ok(name) : bad(name, detail); }

// ── Fixtures ────────────────────────────────────────────────────────
function listen(server) {
  return new Promise((done, fail) => { server.once("error", fail); server.listen(0, LOOPBACK, () => done(server.address().port)); });
}
function closeServer(server) {
  return new Promise((done) => { server.closeAllConnections(); server.close(() => done()); });
}

// The stub gateway. withCookie:false = a venue whose frontend is not deployed.
function stubGateway({ withCookie }) {
  const seen = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks);
      if (req.method === "HEAD" && req.url === "/") {
        seen.push({ method: req.method, url: req.url, host: req.headers.host });
        const headers = { "content-type": "text/html", "x-frame-options": "DENY" };
        if (withCookie) headers["set-cookie"] = COOKIE;
        res.writeHead(200, headers);
        return res.end();
      }
      if (req.url.startsWith("/api/")) {
        const echo = { method: req.method, url: req.url, host: req.headers.host, contentType: req.headers["content-type"] || null, body: body.toString("base64") };
        seen.push(echo);
        res.writeHead(200, { "content-type": "application/json", "x-stub-gateway": "1" });
        return res.end(JSON.stringify(echo));
      }
      res.writeHead(404);
      res.end();
    });
  });
  return { server, seen };
}

// A loopback request carrying the Host a browser would send (the unique
// *.localhost name — the harness must not care); status, headers, body.
function request(port, method, path, { headers = {}, body = null } = {}) {
  return new Promise((done, fail) => {
    const req = http.request({ host: LOOPBACK, port, method, path, headers: { host: `test-smoke.local.localhost:${port}`, ...headers } }, (r) => {
      const chunks = [];
      r.on("data", (c) => chunks.push(c));
      r.on("end", () => done({ status: r.statusCode, headers: r.headers, body: Buffer.concat(chunks) }));
    });
    req.on("error", fail);
    if (body) req.write(body);
    req.end();
  });
}

const children = []; // every pid we spawn — the only things we ever kill
function spawnRaw(argv) {
  const child = spawn(process.execPath, [HARNESS, ...argv], { stdio: ["ignore", "pipe", "pipe"] });
  children.push(child);
  return child;
}
// Start the harness against <gatewayPort>; settle with its listening port once
// the `open` line appears, or with the exit if it refused to start.
function spawnHarness(gatewayPort, dist, extra = []) {
  return new Promise((done) => {
    const child = spawnRaw(["--gateway", String(gatewayPort), "--dist", dist, "--port", "0", "--name", "test", ...extra]);
    let out = "", err = "", settled = false;
    const settle = (v) => { if (!settled) { settled = true; clearTimeout(timer); done({ child, out: () => out, err: () => err, ...v }); } };
    const timer = setTimeout(() => { child.kill("SIGKILL"); settle({ timeout: true }); }, 15000);
    child.stdout.on("data", (d) => {
      out += d;
      const m = out.match(/^\s*open\s+http:\/\/([^/:]+):(\d+)\//m);
      if (m) settle({ host: m[1], port: Number(m[2]) });
    });
    child.stderr.on("data", (d) => { err += d; });
    child.on("exit", (code, signal) => settle({ exit: code, signal }));
  });
}
function waitExit(child) {
  return new Promise((done) => {
    if (child.exitCode !== null || child.signalCode) return done({ code: child.exitCode, signal: child.signalCode });
    child.on("exit", (code, signal) => done({ code, signal }));
  });
}
function collect(child) {
  return new Promise((done) => {
    let out = "", err = "";
    child.stdout.on("data", (d) => { out += d; });
    child.stderr.on("data", (d) => { err += d; });
    child.on("exit", (code, signal) => done({ code, signal, out, err }));
  });
}
function portRefuses(port) {
  return new Promise((done) => {
    const req = http.request({ host: LOOPBACK, port, method: "GET", path: "/" }, (r) => { r.resume(); done(false); });
    req.on("error", (e) => done(e.code === "ECONNREFUSED"));
    req.end();
  });
}
const iframeSized = (html, w, h) => new RegExp(`<iframe[^>]*\\bwidth="${w}"[^>]*\\bheight="${h}"`).test(html);
const sameCookie = (headers) => JSON.stringify(headers["set-cookie"]) === JSON.stringify([COOKIE]);

// ── The run ─────────────────────────────────────────────────────────
const scratch = mkdtempSync(join(tmpdir(), "mdx-smoke-test-"));
const dist = join(scratch, "dist");
mkdirSync(dist);
writeFileSync(join(dist, "index.html"), '<!doctype html><title>stub bundle</title><script type="module" src="/app.js"></script><div id="app">STUB-INDEX</div>\n');
writeFileSync(join(dist, "app.js"), "console.log('stub bundle');\n");
const servers = [];
const globalTimer = setTimeout(() => {
  bad("global timeout (60 s) — killing the children this test spawned");
  for (const c of children) if (c.exitCode === null && !c.signalCode) c.kill("SIGKILL");
  process.exit(1);
}, 60000);

try {
  // ── A. the happy path: a cookie-bearing stub ──
  const gw = stubGateway({ withCookie: true });
  servers.push(gw.server);
  const gwPort = await listen(gw.server);
  const h = await spawnHarness(gwPort, dist);
  check("the harness starts against a cookie-bearing stub and prints its open URL", h.port > 0 && h.exit === undefined, `${h.out()}\n${h.err()}`);
  if (h.port) {
    check("the start-up HEAD went to / with Host frontend.local.localhost:<gateway>", gw.seen.some((s) => s.method === "HEAD" && s.url === "/" && s.host === `frontend.local.localhost:${gwPort}`), JSON.stringify(gw.seen));
    check("it prints its own pid", new RegExp(`\\bpid ${h.child.pid}\\b`).test(h.out()), h.out());
    check("the open URL is the unique <name>-smoke.local.localhost host", h.host === "test-smoke.local.localhost", h.host);
    check("it prints the harness URL with the default sizes", /\/__harness\.html\?w=375&h=780/.test(h.out()), h.out());
    check("it names the canister ids the copied cookie carries", /backend=aaaaa-aa/.test(h.out()) && /frontend=bbbbb-bb/.test(h.out()), h.out());

    const root = await request(h.port, "GET", "/");
    check("GET / is the bundle's index.html", root.status === 200 && root.body.toString().includes("STUB-INDEX") && /^text\/html/.test(root.headers["content-type"]), `${root.status} ${root.headers["content-type"]}`);
    check("the HTML carries the venue's ic_env cookie, copied verbatim", sameCookie(root.headers), JSON.stringify(root.headers["set-cookie"]));
    check("the HTML is cache-control: no-store", root.headers["cache-control"] === "no-store", root.headers["cache-control"]);
    check("no x-frame-options / CSP on the HTML (framing is the point)", !root.headers["x-frame-options"] && !root.headers["content-security-policy"], JSON.stringify(root.headers));

    const js = await request(h.port, "GET", "/app.js");
    check("the .js is served with a JavaScript content-type", js.status === 200 && /^text\/javascript/.test(js.headers["content-type"]) && js.body.toString().includes("stub bundle"), `${js.status} ${js.headers["content-type"]}`);
    check("the .js carries NO cookie (HTML responses only)", js.headers["set-cookie"] === undefined, JSON.stringify(js.headers["set-cookie"]));
    check("the .js is cache-control: no-store too", js.headers["cache-control"] === "no-store", js.headers["cache-control"]);

    const status = await request(h.port, "GET", "/api/v2/status");
    let echo = null;
    try { echo = JSON.parse(status.body.toString()); } catch { echo = null; }
    check("GET /api/v2/status reaches the stub gateway with method and path intact", status.status === 200 && !!echo && echo.method === "GET" && echo.url === "/api/v2/status", status.body.toString());
    check("...with Host rewritten to 127.0.0.1:<gateway> (the real gateway answers 400 to a foreign Host)", !!echo && echo.host === `${LOOPBACK}:${gwPort}`, echo && echo.host);
    check("...and the upstream's own headers pass back", status.headers["x-stub-gateway"] === "1" && /^application\/json/.test(status.headers["content-type"]), JSON.stringify(status.headers));

    const payload = Buffer.concat([Buffer.from("DIDL\x00\x01", "latin1"), Buffer.from([0x00, 0xff, 0x80, 0x7f])]);
    const q = await request(h.port, "POST", "/api/v3/canister/x/query", { headers: { "content-type": "application/cbor", "content-length": payload.length }, body: payload });
    let qe = null;
    try { qe = JSON.parse(q.body.toString()); } catch { qe = null; }
    check("POST /api/v3/canister/x/query reaches the stub with method, path and body intact", q.status === 200 && !!qe && qe.method === "POST" && qe.url === "/api/v3/canister/x/query" && qe.body === payload.toString("base64"), q.body.toString());
    check("...with the content-type forwarded beside the body", !!qe && qe.contentType === "application/cbor", qe && qe.contentType);

    const hp = await request(h.port, "GET", "/__harness.html?w=375&h=780");
    check("/__harness.html?w=375&h=780 sizes the iframe 375x780", hp.status === 200 && iframeSized(hp.body.toString(), 375, 780), hp.body.toString().slice(0, 400));
    check("...framing /?nocache=1#markets (the default route)", /src="\/\?nocache=1#markets"/.test(hp.body.toString()), hp.body.toString().slice(0, 400));
    check("...with the cookie (it is HTML) and no XFO / CSP", sameCookie(hp.headers) && !hp.headers["x-frame-options"] && !hp.headers["content-security-policy"], JSON.stringify(hp.headers));
    const hd = await request(h.port, "GET", "/__harness.html");
    check("/__harness.html defaults to 375x780 without the query", iframeSized(hd.body.toString(), 375, 780), hd.body.toString().slice(0, 400));
    const hw = await request(h.port, "GET", "/__harness.html?w=1400&h=850");
    check("/__harness.html?w=1400&h=850 sizes 1400x850", iframeSized(hw.body.toString(), 1400, 850), hw.body.toString().slice(0, 400));
    const hg = await request(h.port, "GET", "/__harness.html?w=abc&h=-5");
    check("garbage sizes fall back to the defaults", iframeSized(hg.body.toString(), 375, 780), hg.body.toString().slice(0, 400));

    // ?route=<slug>: the view a smoke wants, framed directly (task 1793555363).
    const framed = (html) => (html.match(/src="\/\?nocache=1#([^"]*)"/) || [])[1];
    const times = (html, hash) => (html.match(new RegExp(hash, "g")) || []).length;
    check("no ?route= frames #markets, and '#markets' occurs once (the iframe src: `grep -c` reads 1)", framed(hd.body.toString()) === "markets" && times(hd.body.toString(), "#markets") === 1, hd.body.toString());
    const rSwap = await request(h.port, "GET", "/__harness.html?w=400&h=800&route=swap");
    check("/__harness.html?w=400&h=800&route=swap frames /?nocache=1#swap at 400x800", rSwap.status === 200 && framed(rSwap.body.toString()) === "swap" && iframeSized(rSwap.body.toString(), 400, 800), rSwap.body.toString().slice(0, 400));
    check("...with '#swap' exactly once in the page (`grep -c '#swap'` reads 1)", times(rSwap.body.toString(), "#swap") === 1, rSwap.body.toString());
    check("...with the cookie and no XFO / CSP, like the default page", sameCookie(rSwap.headers) && !rSwap.headers["x-frame-options"] && !rSwap.headers["content-security-policy"], JSON.stringify(rSwap.headers));
    const rNested = await request(h.port, "GET", "/__harness.html?route=docs/launch");
    check("a nested slug (route=docs/launch) frames #docs/launch at the default size", rNested.status === 200 && framed(rNested.body.toString()) === "docs/launch" && iframeSized(rNested.body.toString(), 375, 780), rNested.body.toString().slice(0, 400));
    const rDashed = await request(h.port, "GET", "/__harness.html?route=ai/agent-chat");
    check("a dashed nested slug (route=ai/agent-chat) is accepted", rDashed.status === 200 && framed(rDashed.body.toString()) === "ai/agent-chat", rDashed.body.toString().slice(0, 400));
    // The market deep link: the app writes #markets/<id> with the id verbatim and ids are uppercase (task 1793561650).
    const rMarket = await request(h.port, "GET", "/__harness.html?route=markets/BTC-ICPUSD");
    check("the market deep link (route=markets/BTC-ICPUSD) is a 200 framing /?nocache=1#markets/BTC-ICPUSD - the id keeps its case", rMarket.status === 200 && framed(rMarket.body.toString()) === "markets/BTC-ICPUSD", `${rMarket.status} ${rMarket.body.toString().slice(0, 400)}`);
    check("...with '#markets/BTC-ICPUSD' exactly once in the page (`grep -c '#markets/BTC-ICPUSD'` reads 1)", times(rMarket.body.toString(), "#markets/BTC-ICPUSD") === 1, rMarket.body.toString());
    const badRoute = async (q) => { const r = await request(h.port, "GET", `/__harness.html?w=375&h=780&route=${q}`); return { ...r, text: r.body.toString() }; };
    const rHash = await badRoute("bad%23x");
    check("route=bad%23x (a '#' inside) is a 400 naming the value and the page's usage", rHash.status === 400 && rHash.text.includes('"bad#x"') && rHash.text.includes("usage: /__harness.html"), `${rHash.status} ${rHash.text}`);
    check("...as text/plain, no-store, with no iframe in it", /^text\/plain/.test(rHash.headers["content-type"]) && rHash.headers["cache-control"] === "no-store" && !rHash.text.includes("<iframe"), JSON.stringify(rHash.headers));
    const rUpper = await badRoute("Swap");
    check("an uppercase TAB (route=Swap) is still a 400 - the first segment stays lowercase; only a later segment (a market id) keeps its case", rUpper.status === 400, `${rUpper.status} ${rUpper.text}`);
    const rEmpty = await badRoute("");
    check("an empty route= is a 400, not the default", rEmpty.status === 400, `${rEmpty.status} ${rEmpty.text}`);
    const rQuery = await badRoute("swap%3Fx%3D1");
    check("a '?' inside the route is a 400", rQuery.status === 400, `${rQuery.status} ${rQuery.text}`);
    const rMarkup = await badRoute("%3Cscript%3Ealert(1)%3C%2Fscript%3E");
    check("markup in the route is a 400 served as text/plain (never interpolated into the page)", rMarkup.status === 400 && /^text\/plain/.test(rMarkup.headers["content-type"]) && !rMarkup.text.includes("<iframe"), `${rMarkup.status} ${rMarkup.text}`);

    const deep = await request(h.port, "GET", "/account/earn?x=1");
    check("an unknown path returns index.html (SPA fallback) with the cookie", deep.status === 200 && deep.body.toString().includes("STUB-INDEX") && sameCookie(deep.headers), `${deep.status} ${deep.headers["content-type"]}`);
    check("...marked x-smoke-fallback so curl can tell it from a real file", deep.headers["x-smoke-fallback"] === "index.html", JSON.stringify(deep.headers));
    const trav = await request(h.port, "GET", "/../../etc/passwd");
    check("a traversal path never leaves the dist (index.html, not a file outside)", trav.status === 200 && trav.body.toString().includes("STUB-INDEX"), trav.body.toString().slice(0, 100));
    const head = await request(h.port, "HEAD", "/app.js");
    check("HEAD on an asset answers headers only", head.status === 200 && head.body.length === 0 && Number(head.headers["content-length"]) > 0, JSON.stringify(head.headers));
    const put = await request(h.port, "PUT", "/app.js");
    check("a non-GET on the static side is 405", put.status === 405, put.status);

    // ── The AUTO page (task 1793577865): generated in memory around tests/smoke/<name>.mjs ──
    const SMOKE_SCRIPT = "fuel-banner-breakpoint";   // the first script the repo ships
    const smokeFile = join(ROOT, "tests", "smoke", `${SMOKE_SCRIPT}.mjs`);
    check(`tests/smoke/${SMOKE_SCRIPT}.mjs exists and parses (node --check)`, existsSync(smokeFile) && spawnSync(process.execPath, ["--check", smokeFile]).status === 0, smokeFile);
    const auto = await request(h.port, "GET", `/__auto.html?w=1100&h=850&route=markets&script=${SMOKE_SCRIPT}`);
    const autoHtml = auto.body.toString();
    check("/__auto.html?w=1100&h=850&route=markets&script=<name> is a 200 HTML page", auto.status === 200 && /^text\/html/.test(auto.headers["content-type"]), `${auto.status} ${auto.headers["content-type"]}`);
    check("...with the venue's cookie and no XFO / CSP (the frame must load)", sameCookie(auto.headers) && !auto.headers["x-frame-options"] && !auto.headers["content-security-policy"], JSON.stringify(auto.headers));
    check("...sizing the iframe 1100x850 and framing /?nocache=1#markets", iframeSized(autoHtml, 1100, 850) && framed(autoHtml) === "markets", autoHtml.slice(0, 600));
    check("...carrying the script's text (its export default) as an embedded string literal", autoHtml.includes('const SRC = "') && autoHtml.includes("export default"), autoHtml.slice(0, 200));
    check("...posting its lines to /__result/<name> and closing its own window when done", autoHtml.includes('"/__result/" + NAME') && autoHtml.includes(`const NAME = "${SMOKE_SCRIPT}"`) && autoHtml.includes("window.close()"), autoHtml.slice(-900));
    check("...no-store, like every HTML the harness serves", auto.headers["cache-control"] === "no-store", auto.headers["cache-control"]);
    const autoDefaults = await request(h.port, "GET", `/__auto.html?script=${SMOKE_SCRIPT}`);
    check("/__auto.html?script=<name> alone defaults to 375x780 and #markets", autoDefaults.status === 200 && iframeSized(autoDefaults.body.toString(), 375, 780) && framed(autoDefaults.body.toString()) === "markets", autoDefaults.body.toString().slice(0, 400));
    const badAuto = async (q) => { const r = await request(h.port, "GET", `/__auto.html${q}`); return { ...r, text: r.body.toString() }; };
    const isUsage400 = (r) => r.status === 400 && r.text.includes("usage: /__auto.html") && /^text\/plain/.test(r.headers["content-type"]) && !r.text.includes("<iframe") && !r.text.includes("<script");
    const aNone = await badAuto("?w=1100&h=850");
    check("/__auto.html without script= is a 400 naming the usage (the script is required)", isUsage400(aNone), `${aNone.status} ${aNone.text}`);
    const aTrav = await badAuto("?script=..%2Fsmoke_harness.test");
    check("a traversal script (../smoke_harness.test) is a 400 naming the value and the usage, text/plain, no page", isUsage400(aTrav) && aTrav.text.includes('"../smoke_harness.test"'), `${aTrav.status} ${aTrav.text}`);
    const aDot = await badAuto("?script=fuel-banner-breakpoint.mjs");
    check("a script with a '.' (fuel-banner-breakpoint.mjs) is a 400 - the name is a slug, never a path", isUsage400(aDot), `${aDot.status} ${aDot.text}`);
    const aUnknown = await badAuto("?script=no-such-smoke");
    check("an unknown script is a 400 naming tests/smoke/<name>.mjs and the usage", isUsage400(aUnknown) && aUnknown.text.includes("tests/smoke/no-such-smoke.mjs"), `${aUnknown.status} ${aUnknown.text}`);
    const aUpper = await badAuto("?script=Fuel-Banner-Breakpoint");
    check("an uppercase script name is a 400 (slugs are lowercase)", isUsage400(aUpper), `${aUpper.status} ${aUpper.text}`);
    const aEmpty = await badAuto("?script=");
    check("an empty script= is a 400", isUsage400(aEmpty), `${aEmpty.status} ${aEmpty.text}`);
    const aRoute = await badAuto(`?script=${SMOKE_SCRIPT}&route=Swap`);
    check("a bad route on the auto page is a 400 too (the same slug rule as /__harness.html)", aRoute.status === 400 && /^text\/plain/.test(aRoute.headers["content-type"]), `${aRoute.status} ${aRoute.text}`);

    // ── Results: POST /__result/<name> round-trips to GET, and each line hits the harness's stdout ──
    const r404 = await request(h.port, "GET", "/__result/round-trip");
    check("GET /__result/<name> before any POST is a 404 (a curl loop can wait on it)", r404.status === 404 && r404.body.toString().includes("no results for round-trip"), `${r404.status} ${r404.body}`);
    const post1 = await request(h.port, "POST", "/__result/round-trip", { headers: { "content-type": "text/plain" }, body: "visibility visible\nchrome-h 113px\n" });
    check("POST /__result/<name> with two lines is accepted (204)", post1.status === 204, `${post1.status} ${post1.body}`);
    const get1 = await request(h.port, "GET", "/__result/round-trip");
    check("GET /__result/<name> serves them back as text/plain, one per line", get1.status === 200 && /^text\/plain/.test(get1.headers["content-type"]) && get1.body.toString() === "visibility visible\nchrome-h 113px\n", `${get1.status} ${JSON.stringify(get1.body.toString())}`);
    const post2 = await request(h.port, "POST", "/__result/round-trip", { headers: { "content-type": "text/plain" }, body: "done ok" });
    const get2 = await request(h.port, "GET", "/__result/round-trip");
    check("a second POST appends (three lines now, in order)", post2.status === 204 && get2.body.toString() === "visibility visible\nchrome-h 113px\ndone ok\n", JSON.stringify(get2.body.toString()));
    await new Promise((r) => setTimeout(r, 150));
    check("each line was printed to the harness's stdout as it arrived ([<name>] <line>)", h.out().includes("[round-trip] visibility visible") && h.out().includes("[round-trip] chrome-h 113px") && h.out().includes("[round-trip] done ok"), h.out());
    check("...and a done line for a name the harness is NOT awaiting (no --script) does not stop it", h.child.exitCode === null && (await request(h.port, "GET", "/")).status === 200, String(h.child.exitCode));
    const rBad = await request(h.port, "GET", "/__result/Bad%23name");
    check("a result name off the slug is a 400 naming the usage", rBad.status === 400 && rBad.body.toString().includes("usage: POST /__result/<name>"), `${rBad.status} ${rBad.body}`);
    const rNoName = await request(h.port, "GET", "/__result");
    check("/__result without a name is a 400", rNoName.status === 400, `${rNoName.status}`);
    const rPut = await request(h.port, "PUT", "/__result/round-trip", { body: "x" });
    check("PUT on /__result/<name> is a 405", rPut.status === 405, `${rPut.status}`);

    // The upstream dies: a 502 that names it, never a hang.
    await closeServer(gw.server);
    const dead = await request(h.port, "GET", "/api/v2/status");
    check("a dead upstream is a 502 naming 127.0.0.1:<gateway>", dead.status === 502 && dead.body.toString().includes(`${LOOPBACK}:${gwPort}`), `${dead.status} ${dead.body}`);
    check("the stub saw exactly the start-up HEAD plus the two /api requests", gw.seen.length === 3, JSON.stringify(gw.seen.map((s) => `${s.method} ${s.url}`)));

    // Stop it BY PID and prove it is gone.
    h.child.kill("SIGTERM");
    const ex = await waitExit(h.child);
    check("SIGTERM stops the harness cleanly (exit 0)", ex.code === 0, JSON.stringify(ex));
    check("...and its port refuses connections afterwards", await portRefuses(h.port), `port ${h.port} still answers`);
  } else {
    h.child.kill("SIGKILL");
  }

  // ── B. a venue whose frontend is not deployed: refuse to start ──
  const bare = stubGateway({ withCookie: false });
  servers.push(bare.server);
  const barePort = await listen(bare.server);
  const hb = await spawnHarness(barePort, dist);
  if (hb.port) hb.child.kill("SIGKILL");
  const exB = await waitExit(hb.child);
  check("a stub with no set-cookie makes the harness exit non-zero without listening", !hb.port && exB.code !== 0 && exB.code !== null, JSON.stringify({ port: hb.port, exit: exB, out: hb.out() }));
  check(`...with the message "frontend not deployed on ${barePort}"`, hb.err().includes(`frontend not deployed on ${barePort}`), hb.err());
  check("...and the stub still saw the HEAD (the probe is real, not a config check)", bare.seen.some((s) => s.method === "HEAD" && s.url === "/"), JSON.stringify(bare.seen));
  await closeServer(bare.server);

  // ── C. nothing at the gateway port: refuse to start, naming it ──
  const hc = await spawnHarness(barePort, dist); // barePort is closed now
  if (hc.port) hc.child.kill("SIGKILL");
  const exC = await waitExit(hc.child);
  check("a closed gateway port makes the harness exit non-zero naming 127.0.0.1:<port>", !hc.port && exC.code !== 0 && exC.code !== null && hc.err().includes(`${LOOPBACK}:${barePort}`), hc.err());

  // ── D. --gateway is required: no default, no guessing ──
  const hd2 = await collect(spawnRaw(["--dist", dist, "--port", "0", "--name", "test"]));
  check("a missing --gateway is refused non-zero, naming the flag", hd2.code !== 0 && hd2.code !== null && hd2.err.includes("--gateway <port> is required"), hd2.err);
  const he = await collect(spawnRaw(["--gateway", "notaport", "--dist", dist]));
  check("a non-numeric --gateway is refused", he.code !== 0 && he.code !== null && /--gateway must be a port number/.test(he.err), he.err);

  // ── E. --script: auto mode without a browser - the awaited done line ends the run ──
  const gw2 = stubGateway({ withCookie: true });
  servers.push(gw2.server);
  const gw2Port = await listen(gw2.server);
  const SMOKE = "fuel-banner-breakpoint";
  const hs = await spawnHarness(gw2Port, dist, ["--script", SMOKE, "--result-timeout", "20"]);
  check("--script <name> starts and prints the auto URL (w=375&h=780&route=markets&script=<name>) and the results URL", hs.port > 0 && new RegExp(`^\\s*auto\\s+http://test-smoke\\.local\\.localhost:${hs.port}/__auto\\.html\\?w=375&h=780&route=markets&script=${SMOKE}$`, "m").test(hs.out()) && hs.out().includes(`/__result/${SMOKE}`), hs.out());
  check("...naming the 20 s deadline, and launching no Chrome without --open", /deadline\s+20 s/.test(hs.out()) && !/launched/.test(hs.out()), hs.out());
  if (hs.port) {
    await request(hs.port, "POST", `/__result/${SMOKE}`, { body: "visibility visible\n" });
    await new Promise((r) => setTimeout(r, 100));
    check("a non-done line keeps it running", hs.child.exitCode === null, String(hs.child.exitCode));
    await request(hs.port, "POST", `/__result/${SMOKE}`, { body: "done ok\n" });
    await request(hs.port, "POST", `/__result/${SMOKE}`, { body: "closed (pagehide: this window went away after its done line)" });   // the page's beacon
    const exS = await waitExit(hs.child);
    check("`done ok` for the awaited script exits 0", exS.code === 0, JSON.stringify(exS));
    check("...after printing the line and a done summary", hs.out().includes(`[${SMOKE}] done ok`) && new RegExp(`^\\s*done\\s+${SMOKE}: done ok`, "m").test(hs.out()), hs.out());
    check("...and, the pagehide beacon having arrived, that the auto window closed itself", /^\s*closed\s+the auto window closed itself/m.test(hs.out()), hs.out());
    check("...and its port refuses connections afterwards", await portRefuses(hs.port), `port ${hs.port} still answers`);
  } else hs.child.kill("SIGKILL");
  const hf = await spawnHarness(gw2Port, dist, ["--script", SMOKE, "--result-timeout", "20"]);
  if (hf.port) {
    await request(hf.port, "POST", `/__result/${SMOKE}`, { body: "check FAIL x\ndone FAIL 1\n" });
    await request(hf.port, "POST", `/__result/${SMOKE}`, { body: "close refused - window.close() did not close this window" });   // the page's 0.7 s report
    const exF = await waitExit(hf.child);
    check("`done FAIL 1` exits 1 (the script's failed checks fail the run)", exF.code === 1, JSON.stringify(exF));
    check("...and a `close refused` line names the lingering window on stderr", hf.err().includes(`the auto window for ${SMOKE} did NOT close itself`), hf.err());
  } else { hf.child.kill("SIGKILL"); bad("the --script run for the FAIL case did not start", hf.err()); }
  const ht = await spawnHarness(gw2Port, dist, ["--script", SMOKE, "--result-timeout", "1"]);
  if (ht.port) {
    const exT = await waitExit(ht.child);
    check("--result-timeout 1 with no done line exits 1, naming the script and the seconds", exT.code === 1 && ht.err().includes(`no done line from ${SMOKE} within 1 s`), `${JSON.stringify(exT)} ${ht.err()}`);
    check("...and the port is released", await portRefuses(ht.port), `port ${ht.port} still answers`);
  } else { ht.child.kill("SIGKILL"); bad("the --script run for the timeout case did not start", ht.err()); }
  await closeServer(gw2.server);
  // The refusals fire before the gateway probe, so the closed stub port is fine here.
  const hu = await collect(spawnRaw(["--gateway", String(gw2Port), "--dist", dist, "--script", "no-such-smoke"]));
  check("--script naming no tests/smoke/<name>.mjs is refused non-zero, naming the file", hu.code !== 0 && hu.code !== null && hu.err.includes("tests/smoke/no-such-smoke.mjs"), hu.err);
  const hp = await collect(spawnRaw(["--gateway", String(gw2Port), "--dist", dist, "--script", "../smoke_harness.test"]));
  check("--script with a path is refused (a slug only)", hp.code !== 0 && hp.code !== null && /--script must name a smoke script by slug/.test(hp.err), hp.err);
  const ho = await collect(spawnRaw(["--gateway", String(gw2Port), "--dist", dist, "--open"]));
  check("--open without --script is refused", ho.code !== 0 && ho.code !== null && /--open needs --script/.test(ho.err), ho.err);
  const hr = await collect(spawnRaw(["--gateway", String(gw2Port), "--dist", dist, "--result-timeout", "5"]));
  check("--result-timeout without --script is refused", hr.code !== 0 && hr.code !== null && /--result-timeout needs --script/.test(hr.err), hr.err);
  const hn = await collect(spawnRaw(["--gateway", String(gw2Port), "--dist", dist, "--script", SMOKE, "--result-timeout", "soon"]));
  check("a non-numeric --result-timeout is refused", hn.code !== 0 && hn.code !== null && /--result-timeout must be a whole number/.test(hn.err), hn.err);

  // ── F. hygiene §3g's two bans, asserted here too: the harness file names no machine-global venue port and spells no CLI invocation ──
  const harnessSrc = readFileSync(HARNESS, "utf8");
  const banned = ["80" + "00", "ic" + "p "];   // spelled in halves so this file carries neither literal either
  check("scripts/smoke-harness.mjs carries neither of §3g's banned literals (the venue-port digits, a CLI invocation)", banned.every((b) => !harnessSrc.includes(b)), `found: ${banned.filter((b) => harnessSrc.includes(b)).join(", ")}`);
  check("...and still carries §3g's three positive pins", ["--gateway <port> is required", 'const LOOPBACK = "127.0.0.1"', "frontend not deployed on ${gateway}"].every((p) => harnessSrc.includes(p)), "a positive pin moved");
} finally {
  clearTimeout(globalTimer);
  for (const c of children) if (c.exitCode === null && !c.signalCode) c.kill("SIGKILL");
  for (const s of servers) { try { s.closeAllConnections(); s.close(); } catch { /* already closed */ } }
  rmSync(scratch, { recursive: true, force: true });
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
