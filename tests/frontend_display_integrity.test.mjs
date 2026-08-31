#!/usr/bin/env node
// tests/frontend_display_integrity.test.mjs — guards for the frontend's
// display and cached-state integrity: the e8 money boundary, the units
// contract the assistant hands the model, and the two client caches whose
// cursors can silently desynchronise from the data they index.
//
// WHY THESE ARE WORTH A SUITE. None of the defects these pin lose funds, and
// not one of them throws. A figure 100,000,000x out still renders, still
// formats, still passes the `> 0` gate that decides whether to show it at all;
// a duplicated trade still paints; a chart with three pages missing from its
// middle still draws a continuous line. The failure mode is a confident wrong
// number in front of the person the page exists to inform — a staker reading
// pending yield, an operator reading uncovered bad debt, a model answering
// "how big is my position". Nothing but an explicit assertion catches that.
//
// Two kinds of check, mixed deliberately:
//   · BEHAVIOURAL — money.js is imported and exercised. It is pure, so its
//     contract (which field names scale, what a round trip preserves) can be
//     asserted directly rather than inferred from its source.
//   · STATIC — main.js/explorer.js/assistant.js only run in a browser against
//     a live replica, so their invariants are asserted against the SOURCE.
//     "This render site does not divide", "this poll cannot overlap itself",
//     "this preset's threshold is written in base units" are all properties of
//     the text, and a test that needed a signed-in browser to see them is a
//     test nobody runs.
//
// The assistant section reaches across into src/backend/main.mo on purpose:
// the prompt makes a claim ABOUT the backend's OQL projections, so the only
// way to know it is still true is to check the projections. If the backend
// changes which fields it pre-converts, this suite fails and names the prompt.
//
// Usage:
//   node tests/frontend_display_integrity.test.mjs           # the working tree
//   node tests/frontend_display_integrity.test.mjs <root>    # another checkout
//
// The second form is how the "fails before the fix" half of the contract is
// demonstrated: materialise an older tree (git worktree, or `git show`) and
// point this at it.

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
// A file that is supposed to exist but doesn't is a failure, not a crash —
// otherwise one moved file silently skips a whole section of this suite.
function must(p) {
  const s = read(p);
  if (s === null) bad(`${p} exists`, `not found under ${ROOT}`);
  return s;
}

// Brace-matched body of a function, from comment-stripped source. String
// bodies are skipped so a `{` inside a literal cannot unbalance the scan.
function funcBody(src, header) {
  const at = src.indexOf(header);
  if (at < 0) return null;
  let i = src.indexOf("{", at + header.length);
  if (i < 0) return null;
  const start = i;
  let depth = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === '"' || c === "'" || c === "`") {
      const q = c; i++;
      while (i < src.length) {
        if (src[i] === "\\") { i += 2; continue; }
        if (src[i] === q) { i++; break; }
        i++;
      }
      continue;
    }
    if (c === "{") depth++;
    else if (c === "}") { depth--; if (depth === 0) return src.slice(start, i + 1); }
    i++;
  }
  return null;
}

// Lines that READ a money field, i.e. everything except the IDL declaration
// that gives it its Candid type.
function readSites(src, field) {
  return src.split("\n")
    .map((text, i) => ({ ln: i + 1, text: text.trim() }))
    .filter((l) => l.text.includes(field) && !l.text.includes("IDL."));
}
// STATEMENT-scoped sites (W5-17): a line-wrapped `field\n  / 1e8` defeats
// per-line matching in both directions — the field line has no divide and
// the divide line no field. Statements are approximated by splitting on
// `;` and collapsing internal whitespace.
function readSiteStatements(src, field) {
  return src.split(";")
    .map((text) => text.replace(/\s+/g, " ").trim())
    .filter((t) => t.includes(field) && !t.includes("IDL."));
}
const DIVIDES_BY_E8 = /\/\s*(1e8|100_000_000|100000000)\b/;
// Downscale in EITHER spelling: divide by 1e8 or multiply by its inverse.
const DOWNSCALES_E8 = /(\/\s*(1e8|100_000_000|100000000)\b|\*\s*(1e-8|0\.00000001)\b)/;
// Module helpers that downscale (the fifth reintroduction variant: a
// one-line `const down = (x) => x / 1e8` applied at the render site). Best
// effort by regex — this is a STRUCTURE pin, not a behaviour pin; main.js
// cannot be imported outside a browser.
function e8HelperNames(src) {
  const names = new Set();
  const defs = src.split(";").map((t) => t.replace(/\s+/g, " ").trim());
  for (const d of defs) {
    const m = d.match(/(?:const|let|var)\s+(\w+)\s*=\s*(?:\([^)]*\)|\w+)\s*=>/) || d.match(/function\s+(\w+)\s*\(/);
    if (m && DOWNSCALES_E8.test(d)) names.add(m[1]);
  }
  return names;
}

console.log(`frontend display-integrity guards — ${ROOT}\n`);

// ════════════════════════════════════════════════════════════════════
// A. money.js — the e8 boundary (behavioural)
// ════════════════════════════════════════════════════════════════════
console.log("A. money.js — the e8 boundary");
let money = null;
try {
  money = await import(pathToFileURL(path("src/frontend/src/money.js")).href);
  ok("money.js imports");
} catch (e) {
  bad("money.js imports", e.message);
}

if (money) {
  const { E8, MONEY_KEYS, normMoney, fromE8, toE8 } = money;

  // A1 — getInsuranceFund's record is all-or-nothing. Its five fields are
  // rendered next to each other on four surfaces; one of them left off
  // MONEY_KEYS arrives as a raw bigint among four human Numbers.
  const INSURANCE_FUND_FIELDS = [
    "bufferUsd", "uncoveredBadDebtUsd", "totalShares", "shareValueUsd", "pendingYieldUsd",
  ];
  const missing = INSURANCE_FUND_FIELDS.filter((k) => !MONEY_KEYS.has(k));
  check("every getInsuranceFund money field is in MONEY_KEYS",
    missing.length === 0,
    `absent: ${missing.join(", ")} — normMoney leaves those as raw e8 bigints `
    + "while their siblings become dollars");

  // A2 — the same record, shaped as Candid decodes it, through the real
  // normaliser. This is the boundary the wrapped actor applies exactly once.
  const fund = normMoney({
    bufferUsd: 250_000n * BigInt(E8),
    uncoveredBadDebtUsd: 12_345n * BigInt(E8),
    totalShares: 250_000n * BigInt(E8),
    shareValueUsd: 1n * BigInt(E8),
    pendingYieldUsd: 1_234n * BigInt(E8),
  });
  const wrong = Object.entries(fund).filter(([, v]) => typeof v !== "number");
  check("normMoney converts the whole record to human Numbers",
    wrong.length === 0,
    wrong.map(([k, v]) => `${k} = ${v} (${typeof v})`).join("\n"));
  check("pendingYieldUsd normalises to dollars",
    fund.pendingYieldUsd === 1234,
    `got ${fund.pendingYieldUsd} — the render sites print this verbatim`);
  check("uncoveredBadDebtUsd normalises to dollars",
    fund.uncoveredBadDebtUsd === 12345, `got ${fund.uncoveredBadDebtUsd}`);

  // A3 — fromE8/toE8 are a round trip, not an approximation. `v * 1e8` in
  // floating point drifts a whole base unit past ~2^51: the old formula turned
  // 3355443200000019 into …020.
  const DRIFTED = 3355443200000019n;
  check("the round trip is exact at the first value the float multiply lost",
    toE8(fromE8(DRIFTED)) === DRIFTED,
    `toE8(fromE8(${DRIFTED})) = ${toE8(fromE8(DRIFTED))}`);

  let drift = null;
  for (let x = 3355443200000000n; x < 3355443200002000n && drift === null; x++) {
    if (toE8(fromE8(x)) !== x) drift = x;
  }
  check("the round trip is exact across that whole neighbourhood",
    drift === null,
    drift === null ? "" : `first drift at ${drift} -> ${toE8(fromE8(drift))}`);

  // Exactness holds everywhere a Number can still tell adjacent base units
  // apart, which is up to 2^52 base units (~45M tokens). Above that one ulp is
  // wider than one base unit, so no inverse exists and no implementation can
  // win — asserted in BOTH directions so the ceiling stays a known limit
  // rather than a surprise, and so nobody "extends" it by rounding harder.
  //
  // Full-entropy sampling matters here: `Math.random() * 4.5e15` only ever
  // yields doubles whose low bits are zero, which is exactly the population
  // that round-trips cleanest. This is xorshift64, seeded fixed — a flaky
  // money test is worse than none.
  let s = 0x9E3779B97F4A7C15n;
  const M64 = (1n << 64n) - 1n;
  const rnd = () => { s ^= (s << 13n) & M64; s ^= s >> 7n; s ^= (s << 17n) & M64; return s & M64; };
  const P52 = 4503599627370496n;

  let below = null;
  for (let i = 0; i < 200000 && below === null; i++) {
    const x = rnd() % P52;
    if (toE8(fromE8(x)) !== x) below = x;
  }
  check("the round trip is exact for every value below 2^52 base units",
    below === null,
    below === null ? "" : `drift at ${below} -> ${toE8(fromE8(below))}`);

  let above = null;
  for (let i = 0; i < 200000 && above === null; i++) {
    const x = P52 + (rnd() % P52);
    if (toE8(fromE8(x)) !== x) above = x;
  }
  check("above 2^52 the limit is acknowledged, not papered over",
    above !== null,
    "a round trip that looks exact past 2^52 means this sampler stopped "
    + "exercising the low bits, not that the arithmetic improved");

  // A4 — the ordinary path is untouched. Order entry, slippage and swap
  // amounts all pass through toE8; none of them may move.
  const ORDINARY = [0, 0.05, 0.25, 1, 1.5, 65000.5, 1234.56789012, 0.00000001, 0.15, 100000];
  const moved = ORDINARY.filter((v) => toE8(v) !== BigInt(Math.round(v * E8)));
  check("toE8 is unchanged for ordinary order-entry values",
    moved.length === 0,
    moved.map((v) => `${v}: ${toE8(v)} vs ${BigInt(Math.round(v * E8))}`).join("\n"));
  check("toE8 keeps its sign convention on negatives",
    toE8(-1.5) === -150000000n, `got ${toE8(-1.5)}`);
}

// ════════════════════════════════════════════════════════════════════
// B. main.js — normalised money is never divided again
// ════════════════════════════════════════════════════════════════════
console.log("\nB. main.js — no second divide on boundary-normalised money");
{
  const rawMain = must("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);
  if (src) {
    // Both of these are in MONEY_KEYS, so every read site is dollars already.
    // A divide here is not a rounding difference, it is eight orders of
    // magnitude, and it renders green: the guard above each card tests the
    // undivided value, so the alert still fires and only the figure lies.
    const helperNames = e8HelperNames(src);
    for (const field of ["pendingYieldUsd", "uncoveredBadDebtUsd"]) {
      const stmts = readSiteStatements(src, field);
      check(`${field} has render sites at all`, stmts.length > 0,
        "field renamed? this section is then asserting nothing");
      const scaled = stmts.filter((t) => DOWNSCALES_E8.test(t));
      check(`no ${field} render statement downscales by e8 [structure pin: / and * spellings, statement-scoped]`,
        scaled.length === 0,
        scaled.map((t) => t.slice(0, 120)).join("\n"));
      // the helper variant: any module downscale-helper APPLIED to the field
      const helped = stmts.filter((t) =>
        [...helperNames].some((h) => new RegExp(`\\b${h}\\s*\\(`).test(t)));
      check(`no ${field} render statement routes through a downscale helper [structure pin: cannot execute main.js outside a browser]`,
        helped.length === 0,
        helped.map((t) => t.slice(0, 120)).join("\n"));
    }

    // Whole-function guard on the Stats alert cards. Every figure that pane
    // prints comes from an endpoint the wrapped actor already normalised, so
    // NO 1e8 divide belongs anywhere in it — and this is the pane where the
    // insurance shortfall spent a while rendering as rounding dust beside its
    // own copy calling it the venue's most material risk number. (Cycle
    // figures divide by 1e12 and are unaffected.)
    const issues = funcBody(src, "async function renderStatsIssues(");
    check("renderStatsIssues is extractable", issues !== null);
    if (issues) {
      const divides = issues.split("\n").filter((l) => DOWNSCALES_E8.test(l));
      check("no alert card downscales an already-normalised figure [structure pin]",
        divides.length === 0,
        divides.map((l) => l.trim()).join("\n"));
      const issueHelpers = [...helperNames].filter((h) => new RegExp(`\\b${h}\\s*\\(`).test(issues));
      check("no alert card routes through a downscale helper [structure pin]",
        issueHelpers.length === 0,
        `helper(s) applied inside renderStatsIssues: ${issueHelpers.join(", ")}`);
    }
  }
}

// ════════════════════════════════════════════════════════════════════
// C. assistant.js — the units contract the model is handed
// ════════════════════════════════════════════════════════════════════
console.log("\nC. assistant.js — units contract vs the backend's projections");
{
  const rawAsst = must("src/frontend/src/assistant.js");
  const asst = rawAsst === null ? null : stripJsComments(rawAsst);
  const mo = must("src/backend/main.mo");

  // What the backend actually does. A payload projection is HUMAN units if it
  // converts inline or delegates to a helper that does; anything else reaches
  // the model as the raw e8 integer.
  const CONVERTERS = ["Fixed.toFloat", "oqlLastPrice", "oqlRefPrice",
    "oqlEvAmount", "oqlEvPrice", "oqlEvQty"];

  // The delegating helpers are whitelisted above by name, so each one's own
  // body has to be checked or the whitelist rots into a false negative.
  if (mo) {
    for (const fn of CONVERTERS.filter((c) => c.startsWith("oql"))) {
      const at = mo.indexOf(`func ${fn}(`);
      const body = at < 0 ? null : mo.slice(at, at + 900).split(/\n  (?:func|transient|public|\/\/) /)[0];
      check(`${fn} converts to human units`,
        body !== null && /Fixed\.toFloat|100_000_000\.0/.test(body),
        at < 0 ? "helper not found in main.mo" : "no conversion in its body");
    }
  }

  function entityBlock(src, name) {
    const parts = src.split("OQL.Entity.manual<");
    const hit = parts.find((p) => new RegExp(`^[^\\n]*>\\(\\s*\\n?\\s*"${name}"`).test(p));
    return hit || null;
  }
  function projectionUnits(src, entity, field) {
    const block = entityBlock(src, entity);
    if (!block) return "no-entity";
    const m = new RegExp(`\\.payload\\(\\s*"${field}"\\s*,([^\\n]*)`).exec(block);
    if (!m) return "no-field";
    return CONVERTERS.some((c) => m[1].includes(c)) ? "human" : "e8";
  }

  // Every money field the model can see, and the unit it actually arrives in.
  // `position` is the one entity that mixes both — its size is converted and
  // its entryPrice is not — which is precisely why a blanket rule misleads.
  const UNIT_CONTRACT = [
    ["position", "size", "human"],
    ["position", "entryPrice", "e8"],
    ["position", "realizedPnl", "e8"],
    ["market", "lastPrice", "human"],
    ["market", "refPrice", "human"],
    ["order", "price", "e8"],
    ["order", "quantity", "e8"],
    ["order", "filled", "e8"],
    ["closedOrder", "price", "e8"],
    ["closedOrder", "quantity", "e8"],
    ["balance", "amount", "e8"],
    ["leaderboard", "profitUsd", "e8"],
    ["userEvent", "amount", "human"],
    ["userEvent", "price", "human"],
    ["userEvent", "qty", "human"],
  ];
  if (mo) {
    const mismatched = UNIT_CONTRACT
      .map(([e, f, want]) => [e, f, want, projectionUnits(mo, e, f)])
      .filter(([, , want, got]) => want !== got);
    check("the backend still projects each OQL money field in the documented unit",
      mismatched.length === 0,
      mismatched.map(([e, f, want, got]) => `${e}.${f}: prompt says ${want}, main.mo projects ${got}`)
        .join("\n") + "\n→ the UNITS section of assistantSystemPrompt must be updated to match");
  }

  if (asst) {
    const prompt = funcBody(asst, "function assistantSystemPrompt(") || "";
    check("the system prompt is extractable", prompt.length > 0);

    // The rule is right for most fields and must survive; asserting it as
    // UNIVERSAL is what makes a compliant model wrong on the pre-converted
    // ones — and `position` is the flagship self-scoped entity, so "show my
    // positions" is where it lands first.
    check("the prompt does not state the e8 rule as universal",
      !/ALWAYS divide by 100,000,000/.test(prompt),
      "one OQL field per entity may be pre-converted; an ALWAYS rule cannot be true");
    check("the prompt still teaches the e8 default",
      /divide by 100,000,000/.test(prompt));
    check("the prompt marks the pre-converted fields as exceptions",
      /EXCEPTIONS/.test(prompt),
      "the exception has to be findable by a model skimming the UNITS block");

    const exceptions = prompt.split("\n").filter((l) => l.includes("EXCEPTIONS")).join(" ");
    for (const [entity, field, unit] of UNIT_CONTRACT) {
      if (unit !== "human") continue;
      check(`the prompt names ${entity}.${field} as already-human`,
        exceptions.includes(field) && exceptions.includes(entity),
        `the model is told to divide it; it is projected through ${CONVERTERS[0]} or a helper`);
    }
  }
}

// ════════════════════════════════════════════════════════════════════
// D. explorer.js — the numeric-filter example teaches the right unit
// ════════════════════════════════════════════════════════════════════
console.log("\nD. explorer.js — preset filter units");
{
  const rawExp = must("src/frontend/src/explorer.js");
  const src = rawExp === null ? null : stripJsComments(rawExp);
  if (src) {
    // `order.price` is projected raw and the results table prints it raw, so a
    // bare human literal is a threshold 1e8 too low: it matches every resting
    // bid, and the preset reads as a working filter while doing nothing. This
    // is the explorer's only numeric-filter example, so it is also where
    // anyone writing one by hand learns the convention.
    const bare = [...src.matchAll(/\{\s*(?:gt|ge|lt|le)\s*:\s*\{\s*field\s*:\s*"(price|quantity|filled|amount)"\s*,\s*value\s*:\s*([0-9.]+)\s*\}/g)];
    check("no preset filters a raw-e8 field with a bare human-unit literal",
      bare.length === 0,
      bare.map((m) => `${m[1]} compared against ${m[2]} — that is $${Number(m[2]) / 1e8}`).join("\n"));

    check("the price-threshold preset is written in base units",
      /field\s*:\s*"price"\s*,\s*value\s*:\s*\d+\s*\*\s*E8/.test(src),
      "expected `value: 1000 * E8` so the unit is legible in the source");
    check("explorer.js takes the scale from the money boundary",
      /import\s*\{[^}]*\bE8\b[^}]*\}\s*from\s*["']\.\/money\.js["']/.test(src),
      "a locally-retyped 100000000 is one edit away from disagreeing with money.js");
    check("the preset's label states the threshold as money",
      /label:\s*"Buy orders above \$[\d,]+/.test(src),
      "the raw box shows 100000000000; only the label connects that to $1,000");
  }
}

// ════════════════════════════════════════════════════════════════════
// E. main.js — cursors that index a shared cache
// ════════════════════════════════════════════════════════════════════
console.log("\nE. main.js — poll + chart cursor integrity");
{
  const rawMain = read("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);
  if (src) {
    // E1 — pollChanges reads every cursor from the shared cache BEFORE its
    // await, so two calls in flight at once send identical cursors and both
    // get the same deltas back. A 2s interval plus the pollMarketStatus() fired
    // after each order placement makes that ordinary, not exotic.
    const poll = funcBody(src, "async function pollChanges()");
    check("pollChanges is extractable", poll !== null);
    if (poll) {
      check("an in-flight flag is declared at module scope",
        /let\s+_pollInFlight\s*=\s*false/.test(src));
      // The guard is a compound condition (`if (!src || _pollInFlight) return`),
      // so the needle admits other disjuncts — but a NEGATED flag is asserted
      // ABSENT separately, which is what the old permissive needle could not
      // do: `if (!_pollInFlight) return` satisfied it (the inversion, #36.8).
      check("pollChanges returns early while one is already in flight",
        /if\s*\([^)]*\b_pollInFlight\b[^)]*\)\s*(?:\{\s*)?return/.test(poll)
          && !/if\s*\([^)]*!\s*_pollInFlight[^)]*\)\s*(?:\{\s*)?return/.test(poll),
        "the file already does this for checkReleaseRejections (_rejCheckInFlight); "
        + "a NEGATED _pollInFlight in the early-return is the inversion and fails this");
      const setAt = poll.indexOf("_pollInFlight = true");
      const awaitAt = poll.indexOf("await");
      check("the flag is set before the first await",
        setAt >= 0 && awaitAt >= 0 && setAt < awaitAt,
        "a flag set after the await guards nothing");
      check("the flag is cleared in a finally",
        /finally\s*\{[^}]*_pollInFlight\s*=\s*false/.test(poll),
        "a thrown query would wedge the poll off permanently");

      // E2 — the market-trade cache has no key of its own, and
      // refreshTradesIncremental appends to it from a second cursor, so the
      // same trade can arrive twice. A duplicate prints the fill twice and
      // colours the copy as a zero tick until 100 trades push it out.
      const merge = poll.slice(poll.indexOf("resp.newTrades.length > 0"),
        poll.indexOf("renderTrades("));
      check("the market-trade merge is not a bare concatenation",
        !/\[\s*\.\.\.existing\s*,\s*\.\.\.resp\.newTrades\s*\]/.test(merge),
        "identical newTrades from two polls would both be appended");
      check("the market-trade merge builds a seen-set keyed by trade id [structure pin]",
        /new\s+Set\(\s*existing\.map\([\s\S]{0,60}?\bid\b/.test(merge),
        "expected `new Set(existing.map((t) => String(t.id)))` — the key half of the dedup");
      check("the market-trade merge SKIPS trades already seen [structure pin: the check the tape's duplicate-tick bug rode in on]",
        /if\s*\(\s*seen\.has\([\s\S]{0,60}?\)\s*continue/.test(merge),
        "a seen-set that is built but never consulted dedups nothing");
    }

    // E3 — refreshChartData refetches page 0 and replaces the series, so the
    // paging cursor has to go back with it. Left at 3, the next scroll-left
    // fetches page 4 and prepends it onto page 0: a history missing pages 1-3,
    // drawn as continuous, that never repairs itself.
    const refresh = funcBody(src, "async function refreshChartData()");
    check("refreshChartData is extractable", refresh !== null);
    if (refresh) {
      check("refreshChartData resets the page cursor with the series",
        /chartCurrentPage\s*=\s*0/.test(refresh),
        "changeChartInterval resets it after the same page-0 refetch");
      check("refreshChartData refreshes hasMore from the response",
        /chartHasMore\s*=\s*resp\.hasMore/.test(refresh),
        "a stale hasMore either blocks paging or pages past the end");
      check("refreshChartData yields to a page load already in flight",
        /if\s*\(\s*chartLoadingMore\s*\)\s*return/.test(refresh),
        "otherwise the older page it is fetching lands on top of a fresh page 0");
    }

    const interval = funcBody(src, "async function changeChartInterval(");
    check("changeChartInterval still resets the cursor too",
      interval !== null && /chartCurrentPage\s*=\s*0/.test(interval),
      "both page-0 refetch paths have to reset, not one");
  }
}

// ════════════════════════════════════════════════════════════════════
// F. assistant.js — action outcomes name the payload; candle-interval
//    honesty (#46.2 §1/§3, #46.4)
// ════════════════════════════════════════════════════════════════════
console.log("\nF. assistant.js — action outcome reporting + interval honesty");
{
  const rawAsst = must("src/frontend/src/assistant.js");
  const asst = rawAsst === null ? null : stripJsComments(rawAsst);
  const rawMain = must("src/frontend/src/main.js");
  const mainSrc = rawMain === null ? null : stripJsComments(rawMain);
  const rawOb = must("src/backend/lib/OrderBook.mo");
  const html = must("src/frontend/index.html");

  // F1 — BEHAVIOURAL. assistant.js is import-clean under node (its module
  // scope touches only state.js/oql.js/money.js, all pure), so the outcome
  // formatter is exercised directly. #46.2 §1: `res.ok` used to collapse to
  // the two chars "OK" for every record payload, so a STAGED swap and a
  // fill-nothing market order were indistinguishable from a completed one —
  // for the user (the chat note) AND for the model (the ACTION RESULT turn).
  let outcomeFn = null;
  try {
    const mod = await import(pathToFileURL(path("src/frontend/src/assistant.js")).href);
    outcomeFn = typeof mod.asstActionOutcome === "function" ? mod.asstActionOutcome : null;
  } catch (e) { bad("assistant.js imports under node", e.message || String(e)); }
  check("asstActionOutcome is exported for this battery", outcomeFn !== null,
    "the action-result formatter must be an exported pure function, not inlined");
  if (outcomeFn) {
    // Payload shapes mirror the wrapActor-normalized results the actor returns
    // (human-unit floats; opt Nat decodes to a 0/1-element array of BigInt).
    const staged = outcomeFn("swap", { fromAmount: 0, toAmount: 0, fullyFilled: false, swapOrderId: [123n] });
    check("a staged swap reports STAGED + its order id, not bare OK",
      /STAGED/i.test(staged) && staged.includes("123"), staged);
    const filledSwap = outcomeFn("swap", { fromAmount: 0.5, toAmount: 1500, fullyFilled: true, swapOrderId: [] });
    check("a filled swap reports the swapped amounts",
      filledSwap.includes("0.5") && filledSwap.includes("1500") && !/STAGED/i.test(filledSwap), filledSwap);
    const partialSwap = outcomeFn("swap", { fromAmount: 0.25, toAmount: 700, fullyFilled: false, swapOrderId: [] });
    check("a partial swap says partial", /partial/i.test(partialSwap), partialSwap);
    const mktStaged = outcomeFn("placeMarketOrder", { trades: [], pendingMatches: [], remainingQty: 1, totalFilled: 0, avgPrice: 0 });
    check("a fill-nothing market order reports STAGED, not bare OK", /STAGED/i.test(mktStaged), mktStaged);
    const mktFilled = outcomeFn("placeMarketOrder", { trades: [], pendingMatches: [], remainingQty: 0, totalFilled: 2, avgPrice: 65000 });
    check("a filled market order reports fill quantity + avg price",
      /filled 2\b/.test(mktFilled) && mktFilled.includes("65000"), mktFilled);
    const lim = outcomeFn("placeLimitOrder", { order: { id: 42n }, pendingMatches: [] });
    check("a placed limit order reports its order id", lim.includes("#42"), lim);
    check("a null ok still reads OK", outcomeFn("cancelMyOrder", null) === "OK");
    check("an unrecognized record ok surfaces its payload instead of swallowing it",
      outcomeFn("someFutureAction", { alpha: 7 }).includes("7"),
      "new actions must never regress to a bare OK");
  }

  if (asst) {
    check("the action dispatch routes res.ok through asstActionOutcome",
      /asstActionOutcome\(\s*obj\.method/.test(asst),
      "an exported formatter the dispatch does not call guards nothing");

    // #46.2 §3 — the post-action account refresh. The old guard read
    // `typeof refreshAccountData === "function"` on an identifier that was
    // never in this module's scope: typeof on an undeclared name is
    // "undefined", so the guard was ALWAYS false and the refresh dead code.
    check("the dead bare-identifier refreshAccountData guard is gone",
      !/typeof\s+refreshAccountData/.test(asst),
      "typeof on an out-of-scope identifier is 'undefined' — the guard can never pass");
    check("the post-action refresh runs through an injected dep",
      /if\s*\(\s*_refreshAccount\s*\)\s*_refreshAccount\(\)/.test(asst),
      "the refresh must come through setupAssistant(deps), the module's one injection point");
    check("setupAssistant accepts the refreshAccountData dep",
      /deps\.refreshAccountData/.test(asst));
  }
  if (mainSrc) {
    const at = mainSrc.indexOf("setupAssistant({");
    check("main.js injects refreshAccountData into setupAssistant",
      at >= 0 && mainSrc.slice(at, at + 400).includes("refreshAccountData"),
      "without the injection the fixed guard is false forever, same as the bug");
  }

  // F2 — interval honesty (#46.4). The backend materialises candles ONLY for
  // OrderBook.mo's CANDLE_INTERVALS and exposes no query for the set, so
  // every client-side interval list is a hand-copy; one that offers an
  // unmaterialised bucket (the old 12h, the chart's old 1M) gets an EMPTY
  // response that reads as "no price history". Parse the backend set and hold
  // every hand-copy to it.
  const ob = rawOb === null ? null : stripJsComments(rawOb);
  let backendIvs = null;
  if (ob) {
    const at = ob.indexOf("CANDLE_INTERVALS");
    const blk = at < 0 ? "" : ob.slice(at, ob.indexOf("];", at));
    backendIvs = [...blk.matchAll(/\(\s*([\d_]+)\s*,/g)].map((m) => Number(m[1].replace(/_/g, "")));
    check("the backend CANDLE_INTERVALS set is extractable and plausible",
      backendIvs.length >= 5 && backendIvs.includes(60000),
      `parsed: ${backendIvs.join(", ")}`);
  }
  const sameSet = (a, b) => a.length === b.length && a.every((x) => b.includes(x));
  if (asst && backendIvs && backendIvs.length) {
    const ivsM = /const\s+ALLOWED_IVS\s*=\s*\[([^\]]*)\]/.exec(asst);
    const allowed = ivsM ? ivsM[1].split(",").map((s) => Number(s.trim())).filter((n) => n > 0) : [];
    check("the candles tool's ALLOWED_IVS equals the backend's materialised set",
      sameSet(allowed, backendIvs),
      `assistant: ${allowed.join(", ")}\nbackend:   ${backendIvs.join(", ")}`);

    const promptLine = asst.split("\n").find((l) => l.includes("intervalMs must be one of")) || "";
    const offered = [...promptLine.matchAll(/(\d{5,})\s*\(/g)].map((m) => Number(m[1]));
    check("the prompt's interval list is extractable", offered.length > 0,
      "the 'intervalMs must be one of' line moved or lost its N (label) form");
    check("the prompt offers exactly the backend's materialised intervals",
      sameSet(offered, backendIvs),
      `prompt:  ${offered.join(", ")}\nbackend: ${backendIvs.join(", ")}`);
  }
  if (html && backendIvs && backendIvs.length) {
    const btns = [...html.matchAll(/data-interval="(\d+)"/g)].map((m) => Number(m[1]));
    const phantom = btns.filter((n) => !backendIvs.includes(n));
    check("every chart interval button maps to a materialised backend interval",
      btns.length > 0 && phantom.length === 0,
      `phantom buttons: ${phantom.join(", ")} — getCandles returns empty for these`);
  }

  // F3 — the depth-walk instruction (#46.4). `quantity` is the PLACED size;
  // a partially-filled resting row's remaining depth is quantity - filled,
  // so walking `quantity` alone overstates book depth exactly on the rows
  // where it matters.
  if (asst) {
    check("the depth-walk teaches resting size = quantity - filled",
      asst.includes("quantity - filled"),
      "the slippage walk must subtract filled from quantity per row");
    check("the depth-walk accumulates (quantity - filled)×price",
      asst.includes("(quantity - filled)×price"));
    check("the depth-walk tells the model to select the filled field",
      /Select[^\n]*filled/.test(asst),
      "a walk that never selects `filled` cannot subtract it");
    check("the old quantity-as-resting-size claim is gone",
      !asst.includes("as the resting size per row"));
  }
}

// ════════════════════════════════════════════════════════════════════
// G. Earn card — pool share percent + the LP loan-book disclosure (#50)
// ════════════════════════════════════════════════════════════════════
console.log("\nG. Earn card — pool share percent + LP value disclosure");
{
  // G1 (behavioural) — sharePercent crosses the money boundary as a 0..1
  // FRACTION of the pool: money.js divides the e8 fixed-point by 1e8 and
  // nothing more, so whoever renders it as a percent owns the ×100.
  if (money) {
    const { MONEY_KEYS, normMoney } = money;
    check("sharePercent is in MONEY_KEYS", MONEY_KEYS.has("sharePercent"),
      "normMoney would hand the render a raw e8 bigint");
    const pos = normMoney({ sharePercent: 5_000_000n }); // 5% of the pool at e8
    check("a 5% pool share normalises to the fraction 0.05, not 5",
      pos.sharePercent === 0.05,
      `got ${pos.sharePercent} — the render site's ×100 assumption just changed`);
  }

  const rawMain = must("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);
  if (src) {
    // G2 — the "Pool share" tile multiplies the fraction by 100 before
    // printing "%". Without it a 5% holder reads "0.05%" (#50.2) while the
    // three sibling weights on the same card multiply correctly — the worst
    // kind of wrong: plausible, green, and 100× out. main.js cannot run
    // outside a browser, so this is a structure pin on the render statement.
    const stmts = readSiteStatements(src, "earn-vault-share");
    check("the Pool share tile has a render site at all", stmts.length > 0,
      "element id renamed? this section is then asserting nothing");
    const bare = stmts.filter((t) => !/\*\s*100\b/.test(t));
    check("the Pool share render multiplies the fraction by 100 [structure pin]",
      bare.length === 0,
      bare.map((t) => t.slice(0, 120)).join("\n"));

    // G3 — the loan-book haircut disclosure (#50.1): the Earn card surfaces
    // a utilisation-adjusted figure beside the NAV-based "Value", because
    // withdrawLp pays in kind from physical holdings while the tile marks
    // f × NAV (loan book included) — up to ~2× apart at the 0.50 borrow cap.
    const body = funcBody(src, "function renderVaultHaircut(");
    check("renderVaultHaircut exists", body !== null,
      "the #50.1 disclosure renderer was removed or renamed");
    if (body) {
      check("the haircut note derives the adjusted figure from debt/NAV",
        /totalDebtUsd/.test(body) && /vaultValueUsd/.test(body),
        "the utilisation-adjusted figure must come from getMarginRiskSummary");
      check("the haircut note surfaces utilisation",
        /vaultUtilisationBps/.test(body));
      // The bps field is NOT in MONEY_KEYS; a stray e8 downscale here would
      // print utilisation as 0.0% forever.
      check("the haircut note does not e8-downscale the pre-normalised fields",
        !DOWNSCALES_E8.test(body));
    }
    const earnBody = funcBody(src, "async function renderEarnCard(") || "";
    check("renderEarnCard invokes the haircut disclosure",
      /renderVaultHaircut\s*\(/.test(earnBody),
      "the disclosure renderer is defined but never called from the Earn card");
  }

  // G4 — the LP docs carry the matching upper-bound sentence (#50.1): the
  // Earn docs must say the displayed value is an upper bound while the vault
  // is lending, and that withdrawals are paid in kind.
  const docs = must("src/frontend/src/docs.js");
  check("docs.js Earn section discloses the loan-book upper bound",
    docs !== null && /upper bound while the vault is lending/.test(docs)
      && /paid in kind/.test(docs),
    "the Earn docs upper-bound sentence is gone — #50.1's docs half");

  // G5 — the per-market order-cap error prints the human multiplier, never
  // the raw e8 constant (#50.3). Enforcement is fixed-point and unchanged;
  // only the message speaks human. (Behavioural pin lives in
  // tests/LiquidityManager.test.mo; this catches the lazy revert.)
  const lm = must("src/backend/lib/LiquidityManager.mo");
  check("the order-cap error no longer prints the raw fixed-point constant",
    lm !== null && !lm.includes("Nat.toText(Types.MARKET_ASSET_FACTOR)"),
    '"exceed 250000000x your ICPUSD balance" — meaningless to the person it addresses');
}

// ════════════════════════════════════════════════════════════════════
// H. Adjustment reasons — the WHY column stays wired end to end
//    (#50 follow-up, task 1787199451)
// ════════════════════════════════════════════════════════════════════
console.log("\nH. adjustment reasons — backend tags vs IDL, labels, and the pane");
{
  // The backend's AdjustmentReason variant is the source of truth. Every
  // hand-copy — the frontend IDL variant, the humanising label map — is held
  // to it, the same way the candle-interval lists are held to CANDLE_INTERVALS:
  // a tag added on one side without the other otherwise decodes to a raw key
  // (or throws in the IDL) with nothing but this suite to notice.
  const rawTypes = must("src/backend/lib/Types.mo");
  let backendTags = null;
  if (rawTypes) {
    const at = rawTypes.indexOf("public type AdjustmentReason");
    const blk = at < 0 ? "" : rawTypes.slice(at, rawTypes.indexOf("};", at));
    backendTags = [...blk.matchAll(/#(\w+)/g)].map((m) => m[1]);
    check("the backend AdjustmentReason tag set is extractable and plausible",
      backendTags.length >= 3 && backendTags.includes("balanceShrank"),
      `parsed: ${backendTags.join(", ")}`);
  }

  const rawMain = must("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);
  if (src && backendTags && backendTags.length) {
    // H1 — the IDL half: getMyAdjustments decodes reason as an opt variant
    // carrying exactly the backend's tags. A missing field here throws on
    // every decode; a missing TAG throws only when that walk first fires.
    const idlM = /const\s+AdjustmentReason\s*=\s*IDL\.Variant\(\{([^}]*)\}/.exec(src);
    const idlTags = idlM ? [...idlM[1].matchAll(/(\w+)\s*:\s*IDL\.Null/g)].map((m) => m[1]) : [];
    check("main.js declares the AdjustmentReason IDL variant with the backend's tags",
      idlTags.length === backendTags.length && backendTags.every((t) => idlTags.includes(t)),
      `IDL: ${idlTags.join(", ")}\nbackend: ${backendTags.join(", ")}`);
    check("OrderAdjustment's IDL record carries reason as Opt(AdjustmentReason)",
      /reason\s*:\s*IDL\.Opt\(AdjustmentReason\)/.test(src),
      "fossil rows arrive as null — a non-opt field fails to decode them");

    // H2 — the label half: every backend tag humanises; no orphan labels.
    const lblM = /const\s+ADJ_REASON_LABELS\s*=\s*\{([^}]*)\}/.exec(src);
    const lblTags = lblM ? [...lblM[1].matchAll(/(\w+)\s*:\s*"/g)].map((m) => m[1]) : [];
    check("ADJ_REASON_LABELS covers exactly the backend's tags",
      lblTags.length === backendTags.length && backendTags.every((t) => lblTags.includes(t)),
      `labels: ${lblTags.join(", ")}\nbackend: ${backendTags.join(", ")}`);

    // H3 — the render half: the pane prints the humanised reason per row and
    // survives the fossil rows (reason = [] from the opt decode). main.js
    // cannot run outside a browser, so these are structure pins.
    const pane = funcBody(src, "async function renderAccountAdjustments(");
    check("renderAccountAdjustments is extractable", pane !== null);
    if (pane) {
      check("each adjustment row renders through adjReasonLabel [structure pin]",
        /adjReasonLabel\(\s*a\.reason\s*\)/.test(pane),
        "a Reason <th> with no <td> shifts every row one column left");
      check("the empty state spans the widened table (8 columns)",
        /colspan="8"/.test(pane),
        "the Reason column widened the table; a colspan 7 empty row misaligns it");
    }
    const helper = funcBody(src, "function adjReasonLabel(");
    check("adjReasonLabel handles the fossil (empty opt) rows",
      helper !== null && /!\s*reason\s*\|\|\s*!\s*reason\.length/.test(helper),
      "pre-reason rows decode as [] — rendering them must not throw");

    const html = must("src/frontend/index.html");
    check("the adjustments table header carries the Reason column",
      html !== null && /<th>Status<\/th>\s*<th>Reason<\/th>/.test(html),
      "the render appends a Reason <td>; a missing <th> shears the header");
  }

  // H4 — the published contract: candid/backend.did must carry the field as
  // opt, or bots and tooling decode yesterday's record shape.
  const did = must("candid/backend.did");
  check("candid/backend.did publishes reason: opt AdjustmentReason",
    did !== null && /reason\s*:\s*opt AdjustmentReason/.test(did),
    "gen-did.sh was not re-run after the backend change");
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
