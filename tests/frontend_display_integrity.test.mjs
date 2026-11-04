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

import { readFileSync, existsSync, statSync } from "node:fs";
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
//
// Two scanner faults fixed in task 1788637309, both of which made a pin
// SILENTLY test the wrong text rather than fail:
//   · a header written `function NAME(` stops INSIDE the parameter list, and
//     the first `{` after it was taken as the body opener — for a destructured
//     parameter (`function renderStatsOracle({ feedStats, ... }) {`) that is
//     the parameter list, so the "body" came back as 41 chars of parameter
//     names and every `!/x/.test(body)` pin on it passed trivially. The scan
//     now skips the balanced `(...)` first and takes the first `{` AFTER its
//     matching `)`.
//   · a backtick was treated as a plain quote, so the first nested template
//     inside `${ cond ? `...` : "" }` CLOSED the outer one and every brace
//     after it was counted against the wrong depth. Template literals now
//     recurse through their `${ ... }` holes (skipLiteral/skipBraces below).
// Regex literals holding a quote or brace remain outside the contract, as
// before — the source is comment-stripped, not tokenised.

// Index just past the string/template literal that opens at src[i].
function skipLiteral(src, i) {
  const q = src[i]; i++;
  while (i < src.length) {
    const c = src[i];
    if (c === "\\") { i += 2; continue; }
    if (c === q) return i + 1;
    if (q === "`" && c === "$" && src[i + 1] === "{") {
      const past = skipBraces(src, i + 1);
      if (past < 0) return src.length;
      i = past;
      continue;
    }
    i++;
  }
  return i;
}
// Index just past the `}` matching the `{` at src[i]; -1 when unbalanced.
function skipBraces(src, i) {
  let depth = 0;
  while (i < src.length) {
    const c = src[i];
    if (c === '"' || c === "'" || c === "`") { i = skipLiteral(src, i); continue; }
    if (c === "{") depth++;
    else if (c === "}") { depth--; if (depth === 0) return i + 1; }
    i++;
  }
  return -1;
}
function funcBodyRaw(src, header) {
  const at = src.indexOf(header);
  if (at < 0) return null;
  let i = at + header.length;
  // Finish the parameter list the header left open (`function NAME(` opens
  // one paren it never closes; `function NAME()` is already balanced).
  let parens = 0;
  for (const c of header) { if (c === "(") parens++; else if (c === ")") parens--; }
  while (parens > 0 && i < src.length) {
    const c = src[i];
    if (c === '"' || c === "'" || c === "`") { i = skipLiteral(src, i); continue; }
    if (c === "(") parens++;
    else if (c === ")") parens--;
    i++;
  }
  const start = src.indexOf("{", i);
  if (start < 0) return null;
  const end = skipBraces(src, start);
  return end < 0 ? null : { body: src.slice(start, end), end };
}

// Self-check ledger (task 1788637309): every funcBody() call is recorded and
// section O asserts, per call, that a body which came back is a BODY — long
// enough to be one and not immediately followed by `)`, the parameter-list
// signature (`{ a, b }) {`). A pin whose regex runs over the wrong slice
// passes or fails on the wrong evidence; this is the one place that notices.
// Null returns are the caller's to assert on (several pins WANT null).
const FUNC_BODY_CALLS = [];
const FUNC_BODY_MIN_CHARS = 80;
function funcBody(src, header) {
  const hit = funcBodyRaw(src, header);
  if (hit === null) return null;
  const tail = src.slice(hit.end).trimStart();
  FUNC_BODY_CALLS.push({ header, length: hit.body.length, paramShaped: tail.startsWith(")") });
  return hit.body;
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
    "oqlEvAmount", "oqlEvPrice", "oqlEvQty", "oqlUsd"];

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
  // The leaderboard's Usd columns are pre-converted since task 1793551691 (a
  // live model handed the e8 integers printed a $10,000 account as
  // $10,000,000 even with the UNITS rule naming them); its returnBps is basis
  // points, not money, and stays the raw integer.
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
    ["leaderboard", "profitUsd", "human"],
    ["leaderboard", "capitalUsd", "human"],
    ["leaderboard", "equityUsd", "human"],
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
    // A blanket conversion over the leaderboard row would be wrong: returnBps
    // is basis points (÷100 = %), never scaled by 10^8.
    check("leaderboard.returnBps stays an unconverted integer (basis points, not money)",
      projectionUnits(mo, "leaderboard", "returnBps") === "e8",
      `main.mo projects it as ${projectionUnits(mo, "leaderboard", "returnBps")}`);
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

    // An entity whose money columns are ALL pre-converted is named on the
    // EXCEPTIONS line only: the 2026-11-01 live model had the leaderboard on
    // the DEFAULT list and divided its columns by 100 (task 1793551691). The
    // mixed `position` is named on both by design and is skipped here.
    const dflt = prompt.split("\n").filter((l) => l.includes("DEFAULT:")).join(" ");
    const allHuman = [...new Set(UNIT_CONTRACT.filter(([, , u]) => u === "human").map(([e]) => e))]
      .filter((e) => !UNIT_CONTRACT.some(([e2, , u]) => e2 === e && u === "e8"));
    for (const entity of allHuman) {
      check(`the UNITS DEFAULT line does not also list ${entity} (every money column of it is pre-converted)`,
        !dflt.includes(entity),
        "a field named on both lines contradicts itself; the exception has to be the only mention");
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

    // E3 — the periodic refreshes MERGE page 0 into the series the chart
    // holds (1793498836). Before: refreshChartData (5 s) and refreshMiniChart
    // (10 s) refetched page 0 and setData'd it wholesale, so every older page
    // the user had scrolled into vanished on the next tick (measured on the
    // seat venue: 346 -> 100 candles), and the overlay reset its paging
    // cursor with it while the mini chart's cursor kept counting past pages
    // it no longer held. Now mergeChartPage keys by bar time (replace the
    // overlap, append the new, keep the rest), the next older page is DERIVED
    // from the held real-bar count (pages are cut from the newest candle, so a
    // counted cursor drifts as the series grows), and the view is left to the
    // library — no re-anchor — exactly as the mdx:theme re-skin (§P P8b).
    const refresh = funcBody(src, "async function refreshChartData()");
    const reanchor = /showLastCandles\(|fitContent\(|scrollToRealTime\(|setVisibleLogicalRange\(|setVisibleRange\(|scrollToPosition\(/;
    const setDataArgs = (body) => [...body.matchAll(/\.setData\(([^)]*)\)/g)].map((m) => m[1].trim());
    check("refreshChartData is extractable", refresh !== null);
    if (refresh) {
      check("refreshChartData merges page 0 into the held series (mergeChartPage over the held candle + volume arrays)",
        /mergeChartPage\(data\.candles, data\.volumes, page\)/.test(refresh),
        "the merge is what keeps the older pages across the 5 s tick");
      const args = setDataArgs(refresh);
      check("refreshChartData re-feeds ONLY the arrays it holds — every setData in it is of chartCandleData.candles / .volumes, never the fresh page [a bare setData(page) is the 2026-11-01 regression]",
        args.length >= 2 && args.every((a) => a === "chartCandleData.candles" || a === "chartCandleData.volumes"),
        `setData args: ${args.join(" | ") || "(none)"}`);
      check("refreshChartData never re-anchors the view — lightweight-charts keeps the bars on screen and follows a new bar only when the last bar is visible (shiftVisibleRangeOnNewBar)",
        !reanchor.test(refresh), (refresh.match(reanchor) || []).join(", "));
      check("refreshChartData reads resp.hasMore only on the start-over branch — a page-0 merge never moves the old end of the held run",
        (refresh.match(/chartHasMore\s*=\s*resp\.hasMore/g) || []).length === 1
          && /if \(merged && merged\.overlap > 0\) \{[^}]*\} else \{[^}]*chartHasMore = resp\.hasMore/.test(refresh),
        "hasMore refreshed on every tick re-arms paging past the last page already loaded");
      check("refreshChartData drops a page that lands after the hold it was fetched for was replaced (interval change, re-open)",
        /if \(data !== chartCandleData/.test(refresh),
        "a stale page merged into the new hold is never repaired");
      check("refreshChartData yields to a page load already in flight",
        /if\s*\(\s*chartLoadingMore\s*\)\s*return/.test(refresh),
        "two re-feeds in one breath buy nothing — the next tick is 5 s away");
    }

    const older = funcBody(src, "async function loadOlderCandles()");
    check("loadOlderCandles derives the page from the held real-bar count (nextOlderCandlePage) and merges it — a counted cursor drifts as the series grows, and a prepend duplicates the overlap",
      older !== null && /nextOlderCandlePage\(chartCandleData\.candles\)/.test(older)
        && /mergeChartPage\(chartCandleData\.candles, chartCandleData\.volumes, older\)/.test(older)
        && !/\[\s*\.\.\.older\.candles\s*,/.test(older),
      "expected getCandles(..., nextOlderCandlePage(...)) + mergeChartPage, no [...older.candles, ...]");
    check("the counted cursor chartCurrentPage is gone from main.js", !/chartCurrentPage/.test(src),
      "a cursor that is counted drifts; the page is derived from the hold");

    const interval = funcBody(src, "async function changeChartInterval(");
    check("changeChartInterval replaces the hold with page 0 and re-anchors — the one legitimate reset",
      interval !== null && /chartCandleData = backendCandlesToChart\(resp\.candles, chartInterval\)/.test(interval) && /showLastCandles\(/.test(interval),
      "an interval switch is a new series; a refresh tick is not");

    // E3b — the same contract on the mini chart, whose arrays live in
    // renderMiniChart's closure: refreshMiniChart fetches page 0 and hands it
    // to miniChartMerge (module-level like miniChartReskin); the closure merges.
    const miniRefresh = funcBody(src, "async function refreshMiniChart()");
    const miniMerge = /miniChartMerge = \(resp, market, interval\) => \{([\s\S]*?)\n  \};/.exec(src);
    check("refreshMiniChart touches no series itself — page 0 goes to miniChartMerge(resp, market, interval)",
      miniRefresh !== null && !/setData\(/.test(miniRefresh) && /miniChartMerge\(resp, market, interval\)/.test(miniRefresh),
      miniRefresh ? `setData args: ${setDataArgs(miniRefresh).join(" | ") || "(none)"}` : "body not found");
    check("miniChartMerge merges page 0 into the held arrays and re-feeds ONLY them (miniAllCandles / miniAllVolumes), never the fresh page",
      miniMerge !== null && /mergeChartPage\(miniAllCandles, miniAllVolumes, page\)/.test(miniMerge[1])
        && setDataArgs(miniMerge[1]).length >= 2 && setDataArgs(miniMerge[1]).every((a) => a === "miniAllCandles" || a === "miniAllVolumes"),
      miniMerge ? `setData args: ${setDataArgs(miniMerge[1]).join(" | ") || "(none)"}` : "closure not found");
    check("miniChartMerge never re-anchors, and drops a page for another market or interval",
      miniMerge !== null && !reanchor.test(miniMerge[1]) && /market !== marketAtCall \|\| interval !== miniChartCandleInterval/.test(miniMerge[1]),
      miniMerge ? (miniMerge[1].match(reanchor) || ["guard missing"]).join(", ") : "closure not found");
    check("the mini chart's lazy older-page load derives its page from the hold and merges it; the counted miniPage cursor is gone",
      /getCandles\(selectedMarket, interval, nextOlderCandlePage\(miniAllCandles\)\)/.test(src)
        && /mergeChartPage\(miniAllCandles, miniAllVolumes, older\)/.test(src) && !/\bminiPage\b/.test(src),
      "expected nextOlderCandlePage(miniAllCandles) + mergeChartPage; no miniPage");
    check("miniChartMerge is nulled wherever miniChartReskin is (the chart it closes over is gone)",
      (src.match(/miniChartReskin = null;\s*miniChartMerge = null;/g) || []).length === 2);

    // E3c — the helpers, exercised: mergeChartPage is pure, so its body is
    // lifted out of main.js and run (the file itself only runs in a browser).
    const md = must("src/backend/mixins/MarketData.mo");
    check("CANDLE_PAGE_SIZE is the backend's getCandles page size (MarketData.mo passes 100)",
      /const CANDLE_PAGE_SIZE = 100;/.test(src) && md !== null && /OrderBook\.getCandles\(orderStore, marketId, intervalMs, page, 100\)/.test(md),
      "the derived cursor is floor(held real bars / page size): a drifted size pages into holes or repeats");
    const nextPage = funcBody(src, "function nextOlderCandlePage(");
    check("nextOlderCandlePage = floor(held real bars / CANDLE_PAGE_SIZE) — whitespace gap markers do not count",
      nextPage !== null && /c\.open !== undefined/.test(nextPage) && /Math\.floor\(real \/ CANDLE_PAGE_SIZE\)/.test(nextPage));
    const mergeBody = funcBody(src, "function mergeChartPage(");
    check("mergeChartPage is extractable", mergeBody !== null);
    if (mergeBody) {
      let mergeFn = null;
      try { mergeFn = new Function(`return function mergeChartPage(heldCandles, heldVolumes, page) ${mergeBody}`)(); } catch (e) { bad("mergeChartPage evaluates", e.message); }
      if (mergeFn) {
        const bar = (t, extra = {}) => ({ time: t, open: t, high: t + 1, low: t - 1, close: t, ...extra });
        const vol = (t, v = 1) => ({ time: t, value: v });
        // the hold: pages 1 + 0 as of an earlier tick — bars 100..299, with a whitespace gap marker at 250
        const held = []; const heldV = [];
        for (let t = 100; t < 300; t++) { if (t === 250) { held.push({ time: t }); heldV.push({ time: t }); } else { held.push(bar(t)); heldV.push(vol(t)); } }
        // a fresh page 0 after 20 new bars: 220..319, bar 299 (the open candle) changed, 250 now real
        const page = { candles: [], volumes: [] };
        for (let t = 220; t < 320; t++) { page.candles.push(bar(t, t === 299 ? { close: 9999 } : {})); page.volumes.push(vol(t, 2)); }
        const r = mergeFn(held, heldV, page);
        const times = r.candles.map((c) => c.time);
        check("merge: the older page survives, the overlap is replaced, the new bars are appended — 100..319, ascending, no duplicate time",
          r.candles.length === 220 && times[0] === 100 && times[219] === 319 && times.every((t, i) => i === 0 || t > times[i - 1]),
          `length ${r.candles.length}, first ${times[0]}, last ${times[219]}`);
        check("merge: the incoming bar wins at a shared time (the open candle's new close), and a gap marker is upgraded by a real bar",
          r.candles[199].close === 9999 && r.candles[150].open === 250 && r.volumes[150].value === 2);
        check("merge: overlap counts the incoming real bars at held real times (79 — the gap marker at 250 was not real)",
          r.overlap === 79, `overlap ${r.overlap}`);
        check("merge: volumes merge the same way (220 bars, the incoming value on the overlap, the held value below it)",
          r.volumes.length === 220 && r.volumes[199].value === 2 && r.volumes[0].value === 1);
        const ws = mergeFn(held, heldV, { candles: [{ time: 150 }], volumes: [{ time: 150 }] });
        check("merge: a whitespace marker never overwrites a real bar (and is not an overlap)",
          ws.candles[50].open === 150 && ws.overlap === 0);
        const far = mergeFn(held, heldV, { candles: [bar(400), bar(401)], volumes: [vol(400), vol(401)] });
        check("merge: a page that does not reach back to the hold reports overlap 0 (the callers start over rather than draw a hole)",
          far.overlap === 0 && far.candles.length === 202);
        const kept = mergeFn(held, heldV, { candles: [], volumes: [] });
        check("merge: an empty page changes nothing", kept.candles.length === 200 && kept.overlap === 0);
      }
    }

    // E4 — the full-size chart overlay is REACHABLE (1793498839). #chart-btn,
    // the market-header button that owned openChart, had been
    // `.market-header #chart-btn { display: none; }` since the initial commit
    // 7cd9635: the overlay — its own lightweight-charts instance, the 5 s merge
    // refresh pinned above, the lazy older pages — could not be opened by a
    // user at any width, and every pin on it guarded a surface nobody saw.
    // The header button is retired; the chart cell's bar carries an expand
    // control instead: a real <button> with an aria-label (Tab reaches it,
    // Enter opens it — a div with a click handler does neither), wired to
    // openChart at the interval the cell shows, hidden only where the
    // interval buttons are (the liquidation map, the collapsed cell) and
    // never by an unconditional rule — the 7cd9635 defect again. The overlay
    // is a dialog: role, labelled by its title, focused on open, Escape
    // closes it like the × does, focus returns to the opener; and its header
    // wraps under 900px so the × stays on screen at 375px (the seven
    // interval buttons alone are ~300px wide).
    const stripHtml = (s) => s.replace(/<!--[\s\S]*?-->/g, "");
    const stripCss = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "");
    const rawHtml = must("src/frontend/index.html");
    const html = rawHtml === null ? null : stripHtml(rawHtml);
    const sheets = Object.fromEntries(["header", "markets", "responsive", "chart-overlay"].map((f) => [f, read(`src/frontend/src/styles/${f}.css`)]));
    check("the hidden market-header #chart-btn is gone from index.html, and no stylesheet carries a #chart-btn rule",
      html !== null && !/id="chart-btn"/.test(html) && Object.values(sheets).every((c) => c !== null && !/#chart-btn/.test(stripCss(c))),
      "the button that was display:none since 7cd9635 is retired, not un-hidden: the cell's expand control owns openChart now");
    const bar = /container\.innerHTML = `<div class="mini-chart-bar">([\s\S]*?)<div class="mini-chart-canvas"/.exec(src);
    check("renderMiniChart's bar carries the expand control: a real <button class=\"mini-chart-expand\" type=\"button\"> with an aria-label",
      bar !== null && /<button class="mini-chart-expand" type="button" aria-label="[^"]+"/.test(bar[1]),
      "a div with a click handler is not reachable from the keyboard");
    check("the expand control opens the overlay through openChart, at the interval the cell is showing",
      /querySelector\("\.mini-chart-expand"\)\.addEventListener\("click", \(\) => \{\s*chartInterval = miniChartCandleInterval;\s*openChart\(\);/.test(src),
      "expected chartInterval = miniChartCandleInterval; openChart();");
    check("setupEventListeners no longer wires #chart-btn (nothing but the expand control opens the overlay)",
      !/getElementById\("chart-btn"\)/.test(src));
    const hides = [];
    for (const [f, raw] of Object.entries(sheets)) {
      if (raw === null) continue;
      for (const m of stripCss(raw).matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
        if (!/mini-chart-expand/.test(m[1]) || !/display\s*:\s*none/.test(m[2])) continue;
        for (const sel of m[1].split(",")) if (/mini-chart-expand/.test(sel) && !/mcv-showing-heat|mini-chart-collapsed/.test(sel)) hides.push(`${f}.css: ${sel.trim()}`);
      }
    }
    check("no stylesheet hides .mini-chart-expand outside the map / collapsed states — it is reachable wherever the interval buttons are", hides.length === 0, hides.join("\n"));
    check("header.css styles .mini-chart-expand (a visible hit target, a :focus-visible ring) and hides it with the interval buttons in both chart-less states",
      sheets.header !== null && /\.mini-chart-expand \{/.test(sheets.header) && /\.mini-chart-expand:focus-visible \{ outline: 2px solid var\(--accent\)/.test(sheets.header)
        && /\.mini-chart\.mcv-showing-heat \.mini-chart-expand \{ display: none; \}/.test(sheets.header) && /\.mini-chart\.mini-chart-collapsed \.mini-chart-expand \{ display: none; \}/.test(sheets.header));
    check("index.html: #chart-overlay is a dialog — role, aria-modal (E4b traps Tab), labelled by #chart-title, focusable (tabindex=-1); the × carries an aria-label",
      html !== null && /<div id="chart-overlay" class="chart-overlay" style="display:none" role="dialog" aria-modal="true" aria-labelledby="chart-title" tabindex="-1">/.test(html)
        && /<button id="chart-close-btn" class="chart-close-btn" title="Close" aria-label="[^"]+">/.test(html));
    const open = funcBody(src, "async function openChart()");
    const close = funcBody(src, "function closeChart()");
    check("openChart focuses the overlay (the keyboard's home for Escape and Tab) and remembers the opener; closeChart returns focus to it",
      open !== null && close !== null && /chartReturnFocus = document\.activeElement/.test(open) && /overlay\.focus\(/.test(open)
        && /chartReturnFocus = null/.test(close) && /back\.focus\(/.test(close));
    check("Escape closes the open overlay — a keydown handler keyed on the overlay being shown; the × is not the only way out",
      /keydown", \(e\) => \{\s*if \(e\.key === "Escape" && document\.getElementById\("chart-overlay"\)\.style\.display !== "none"\) closeChart\(\);/.test(src));
    check("chart-overlay.css: the header wraps under 900px — title + × on the first row, the intervals on their own row",
      sheets["chart-overlay"] !== null && /@media \(max-width: 900px\) \{[\s\S]*?\.chart-overlay-header \{ flex-wrap: wrap;[\s\S]*?\.chart-intervals \{ order: 1; flex: 0 0 100%;/.test(stripCss(sheets["chart-overlay"])));

    // E4b — the chart cell's view menu is a KEYBOARD-OPERABLE menu button, and
    // the overlay is a modal that traps Tab (1793503737). The view menu
    // ("Chart | Liquidations | Hide") was divs with click handlers — no
    // tabindex, no role, no key handling — so the Liquidations view and Hide
    // were unreachable from the keyboard, unlike the interval buttons and the
    // expand control beside them. Now: a real <button> trigger
    // (aria-haspopup=menu; aria-expanded mirrored from the wrapper's .open by
    // ONE setter, which the outside-click closer uses too, so the two cannot
    // drift; aria-controls naming the menu), role=menuitem buttons at
    // tabindex=-1 inside a role=menu (the trigger is the one tab stop),
    // Enter / Space / ArrowDown open onto the first item and ArrowUp onto the
    // last, the arrows move with wrap, Home / End jump, Escape closes back to
    // the trigger and stops there, Tab closes; activation returns focus to
    // the trigger because applyChartView rebuilds the items under it. The
    // visual design is unchanged: the trigger draws the box the wrapper drew
    // (and the wrapper draws none), the items are reset buttons. And
    // #chart-overlay claims aria-modal only now that Tab cannot leave it:
    // trapChartOverlayFocus wraps Tab / Shift+Tab over the overlay's rendered
    // controls and pulls body-focus back in, routed from the same keydown
    // listener as Escape.
    check("renderMiniChart's bar: the view trigger is a real <button> — aria-haspopup=menu, aria-expanded=false at build, aria-controls=mcv-menu — inside the #mini-chart-view wrapper the outside-click closer keys on",
      bar !== null && /<div class="mini-chart-view" id="mini-chart-view">`[\s\S]*?<button type="button" class="mcv-trigger" id="mcv-trigger" aria-haspopup="menu" aria-expanded="false" aria-controls="mcv-menu">/.test(bar[1]),
      "a div with a click handler is not a menu button");
    check("renderMiniChart's bar: the menu container is role=menu with an accessible name, and the chevron is aria-hidden",
      bar !== null && /<div class="mcv-menu" id="mcv-menu" role="menu" aria-label="[^"]+">/.test(bar[1]) && /<svg width="10" height="10" viewBox="0 0 10 10" fill="none" aria-hidden="true">/.test(bar[1]));
    const applyView = funcBody(src, "function applyChartView(");
    check("applyChartView renders the items as role=menuitem buttons at tabindex=-1 (the trigger is the one tab stop; the arrows move inside) through setMenuItems keyed by view, so a rebuild under the keyboard keeps the item — no bare innerHTML rebuild",
      applyView !== null && /setMenuItems\(menu, CHART_VIEWS\s*\.filter\([\s\S]*?<button type="button" class="mcv-item" role="menuitem" tabindex="-1" data-view="\$\{v\.id\}">\$\{escH\(v\.label\)\}<\/button>`\)\s*\.join\(""\), "view"\);/.test(applyView)
        && !/menu\.innerHTML/.test(applyView),
      "div items cannot take focus or activate on Enter / Space; a bare innerHTML rebuild drops focus to the body mid-walk");
    // Re-pointed by 1793509280: the view menu rides the shared helper of E4c
    // below — chartViewMenu is a makeDropdown instance whose ONE setter keeps
    // the wrapper's .open and the trigger's aria-expanded together, the
    // outside-click closer walks it with the page's other dropdowns, and
    // renderMiniChart wires the fresh trigger / menu through wireMenuButton on
    // every rebuild. The keys this section promised are wireMenuButton's (E4c
    // pins each in full; they are read again here so this section stays the
    // view menu's contract). The inline wiring and setChartViewMenuOpen, the
    // cell's private setter, are gone — a second copy of the keys would drift.
    check("the view menu is a makeDropdown instance — chartViewMenu resolves #mini-chart-view and #mcv-trigger per call (the cell is rebuilt on every renderMiniChart) — and setChartViewMenuOpen, its former private setter, is gone",
      /const chartViewMenu = makeDropdown\(\{\s*wrap: \(\) => document\.getElementById\("mini-chart-view"\),\s*trigger: \(\) => document\.getElementById\("mcv-trigger"\),\s*\}\);/.test(src)
        && funcBody(src, "function setChartViewMenuOpen(") === null && !/setChartViewMenuOpen/.test(src),
      "a setter of its own beside makeDropdown's is the drift E4c closed");
    const setupSrc = funcBody(src, "function setupEventListeners()");
    check("the outside-click closer has no view-menu special case — the DROPDOWNS walk is the only mechanism (no mini-chart-view lookup in setupEventListeners, no bare classList.remove(\"open\") on the wrapper anywhere), so aria-expanded cannot drift from .open",
      setupSrc !== null && !/mini-chart-view/.test(setupSrc) && !/chartView\b/.test(setupSrc) && !/chartView\.classList\.remove\("open"\)/.test(src));
    const mini = funcBody(src, "async function renderMiniChart()");
    check("renderMiniChart is extractable", mini !== null);
    if (mini) {
      const menuWiring = mini.slice(mini.indexOf("applyChartView(container)"), mini.indexOf('querySelector(".mini-chart-expand")'));
      check("renderMiniChart wires the view menu through wireMenuButton(chartViewMenu, …) right after applyChartView(container) — the fresh #mcv-menu, .mcv-item items, activation = setChartView(item.dataset.view) — and carries no key handling of its own (no keydown listener in the cell's wiring, no openViewMenu / closeViewMenu anywhere)",
        /^applyChartView\(container\);\s*wireMenuButton\(chartViewMenu, \{\s*menu: container\.querySelector\("#mcv-menu"\),\s*itemSelector: "\.mcv-item",\s*onActivate: \(item\) => setChartView\(item\.dataset\.view\),\s*\}\);/.test(menuWiring)
          && !/addEventListener\("keydown"/.test(menuWiring) && !/openViewMenu|closeViewMenu/.test(src),
        "the keys live in wireMenuButton (E4c) — a second copy here would drift");
    }
    const viewKeys = funcBody(src, "function wireMenuButton(");
    check("the keys E4b promised the view menu hold in the router it now rides — Enter / Space / ArrowDown open onto the first item, ArrowUp onto the last, Home / End jump, Escape closes back to the trigger and stops there, Tab closes, activation refocuses the trigger (E4c pins the router in full)",
      viewKeys !== null && /e\.key === "ArrowDown" \|\| e\.key === "Enter" \|\| e\.key === " "\) \{ e\.preventDefault\(\); open\(0\); \}/.test(viewKeys)
        && /e\.key === "ArrowUp"\) \{ e\.preventDefault\(\); open\(-1\); \}/.test(viewKeys)
        && /"Home"\) \{ e\.preventDefault\(\); list\[0\]\?\.focus\(\); \}/.test(viewKeys) && /"End"\) \{ e\.preventDefault\(\); list\[list\.length - 1\]\?\.focus\(\); \}/.test(viewKeys)
        && /"Escape"\) \{ e\.preventDefault\(\); e\.stopPropagation\(\); close\(true\); \}/.test(viewKeys) && /"Tab"\) \{ close\(true\);/.test(viewKeys)
        && /onActivate\(item\);\s*close\(true\);/.test(viewKeys));
    const wrapRule = sheets.header === null ? null : /\.mini-chart-view \{([^}]*)\}/.exec(stripCss(sheets.header));
    check("header.css: .mcv-trigger draws the box .mini-chart-view drew (4px 8px, 1px --border, radius 4px, --accent, font: inherit) — and the wrapper draws none, so the design is unchanged — with a :focus-visible ring",
      sheets.header !== null && wrapRule !== null && !/border|padding/.test(wrapRule[1])
        && /\.mcv-trigger \{[^}]*padding: 4px 8px;[^}]*border: 1px solid var\(--border\);[^}]*border-radius: 4px;[^}]*background: transparent;[^}]*color: var\(--accent\);[^}]*font: inherit;/.test(sheets.header)
        && /\.mcv-trigger:focus-visible \{ outline: 2px solid var\(--accent\); outline-offset: 2px; \}/.test(sheets.header));
    check("header.css: .mcv-item is a reset button (full-width, border 0, transparent, font: inherit, left-aligned) styled alike on :hover and :focus-visible, plus an inset ring the clipping menu cannot cut off",
      sheets.header !== null
        && /\.mcv-item \{[^}]*width: 100%;[^}]*border: 0;[^}]*background: transparent;[^}]*font: inherit;[^}]*text-align: left;/.test(sheets.header)
        && /\.mcv-item:hover, \.mcv-item:focus-visible \{ background: var\(--bg-hover\); color: var\(--text\); \}/.test(sheets.header)
        && /\.mcv-item:focus-visible \{ outline: 2px solid var\(--accent\); outline-offset: -2px; \}/.test(sheets.header));
    check("index.html: #chart-overlay claims aria-modal=\"true\" — a dialog Tab cannot leave",
      html !== null && /<div id="chart-overlay"[^>]*\baria-modal="true"[^>]*>/.test(html));
    const trap = funcBody(src, "function trapChartOverlayFocus(");
    check("trapChartOverlayFocus collects the overlay's RENDERED focusable controls, wraps Tab from the last to the first and Shift+Tab from the first (or from the overlay itself) to the last, and pulls focus that fell to the body back inside",
      trap !== null && /overlay\.querySelectorAll\(/.test(trap) && /getClientRects\(\)\.length > 0/.test(trap)
        && /const inside = active !== overlay && overlay\.contains\(active\)/.test(trap)
        && /if \(e\.shiftKey\) \{\s*if \(!inside \|\| active === first\) \{ e\.preventDefault\(\); last\.focus\(\); \}/.test(trap)
        && /else if \(!inside \|\| active === last\) \{\s*e\.preventDefault\(\); first\.focus\(\);/.test(trap));
    check("the document keydown listener routes Tab to the trap while the overlay is shown — beside the Escape line, same guard",
      /if \(e\.key === "Tab" && document\.getElementById\("chart-overlay"\)\.style\.display !== "none"\) trapChartOverlayFocus\(e\);/.test(src));

    // E4c — the page's OTHER dropdowns take the same pattern (1793506246).
    // The order book's price-grouping menus (Markets and Swap), the market
    // selector, the price/stats popup (mobile and the compact desktop
    // header) and the desktop header's overflow popup were divs with click
    // handlers — no tab stop, no role, no keys. Now each is a real <button>
    // trigger whose aria-expanded is mirrored from the wrapper's .open by
    // ONE setter (makeDropdown) that the outside-click closer and
    // selectMarket's close-all use too, so the two cannot drift. The three
    // that are lists of choices are menu buttons — aria-haspopup=menu,
    // aria-controls, a role=menu of role=menuitem buttons at tabindex=-1,
    // E4b's keys through ONE shared router (wireMenuButton); the two that
    // are rows to read are disclosures — aria-expanded / aria-controls,
    // Enter / Space toggle, Escape closes (wireDisclosure). The overflow
    // trigger is re-minted by the layout code, so its keyboard half is one
    // shared <button> updateMarketHeaderMode parks beside the popup: the
    // semantics survive every re-layout. The polls rebuild the item lists,
    // so a rebuild keeps the keyboard's item (setMenuItems). The visual
    // design is unchanged: each trigger draws what its wrapper drew, the
    // items are reset buttons.
    const obCss = read("src/frontend/src/styles/orderbook.css");
    for (const [wrap, trig, menuId, name] of [["ob-granularity", "ob-gran-trigger", "ob-gran-menu", "Markets"], ["swap-ob-granularity", "swap-ob-gran-trigger", "swap-ob-gran-menu", "Swap"]]) {
      check(`index.html: the ${name} book's price-grouping trigger is a real <button> (aria-haspopup=menu, aria-expanded=false at load, aria-controls=${menuId}) inside the #${wrap} wrapper the closer keys on, its chevron aria-hidden, over a role=menu with a name`,
        html !== null && new RegExp(`<div class="ob-granularity" id="${wrap}">\\s*<button type="button" class="ob-gran-trigger" id="${trig}" aria-haspopup="menu" aria-expanded="false" aria-controls="${menuId}">[\\s\\S]*?aria-hidden="true"[\\s\\S]*?</button>\\s*<div class="ob-gran-menu" id="${menuId}" role="menu" aria-label="[^"]+"></div>`).test(html),
        "a div with a click handler is not a menu button");
    }
    check("index.html: the market selector's trigger is a real <button> inside the h2 (the title keeps its heading; #market-title is the text span inside) — aria-haspopup=menu, aria-expanded=false, aria-controls=market-dropdown — over a role=menu whose two sections are named groups",
      html !== null && /<div class="market-selector" id="market-selector">\s*<h2>\s*<button type="button" class="market-selector-trigger" id="market-selector-trigger" aria-haspopup="menu" aria-expanded="false" aria-controls="market-dropdown">\s*<span id="market-title">/.test(html)
        && /<div class="market-dropdown" id="market-dropdown" role="menu" aria-label="[^"]+">/.test(html)
        && /id="market-dropdown-recent" class="market-dropdown-section" role="group" aria-labelledby="market-dropdown-recent-label"/.test(html)
        && /<div class="market-dropdown-section" role="group" aria-labelledby="market-dropdown-all-label">/.test(html));
    check("index.html: the price/stats popup's trigger is a real <button> (a disclosure: aria-expanded=false, aria-controls=market-stats-dropdown) wrapping the summary, inside #market-stats-toggle",
      html !== null && /<div class="market-stats-mobile" id="market-stats-toggle">\s*<button type="button" class="msm-trigger" id="market-stats-trigger" aria-expanded="false" aria-controls="market-stats-dropdown">\s*<span class="msm-summary">/.test(html));
    check("index.html: the overflow popup has a keyboard trigger — the shared <button id=\"market-stats-more\"> (aria-label, aria-expanded=false, aria-controls=market-stats-overflow) beside #market-stats-overflow in the 24h Change cell",
      html !== null && /<button type="button" class="ms-more-btn" id="market-stats-more" aria-label="[^"]+" aria-expanded="false" aria-controls="market-stats-overflow"><\/button>\s*<div class="market-stats-dropdown" id="market-stats-overflow"><\/div>/.test(html));
    const mkDrop = funcBody(src, "function makeDropdown(");
    check("makeDropdown mints ONE setter per dropdown: setOpen toggles the wrapper's .open and the trigger's aria-expanded from one boolean, and registers the dropdown in DROPDOWNS for the closer",
      mkDrop !== null && /classList\.toggle\("open", on\)/.test(mkDrop) && /setAttribute\("aria-expanded", on \? "true" : "false"\)/.test(mkDrop) && /DROPDOWNS\.push\(d\)/.test(mkDrop));
    check("the five dropdowns are made with makeDropdown — the two granularity menus (parked above their trigger as they open), the market selector, the price/stats popup, and the overflow popup whose wrapper is whichever cell is .market-stat-more",
      /const obGranMenu = makeDropdown\(\{\s*wrap: \(\) => document\.getElementById\("ob-granularity"\),\s*trigger: \(\) => document\.getElementById\("ob-gran-trigger"\),\s*onOpen: \(\) => placeGranMenu\("ob-gran-menu", "ob-gran-trigger"\)/.test(src)
        && /const swapObGranMenu = makeDropdown\(\{\s*wrap: \(\) => document\.getElementById\("swap-ob-granularity"\),\s*trigger: \(\) => document\.getElementById\("swap-ob-gran-trigger"\),\s*onOpen: \(\) => placeGranMenu\("swap-ob-gran-menu", "swap-ob-gran-trigger"\)/.test(src)
        && /const marketSelectorMenu = makeDropdown\(\{\s*wrap: \(\) => document\.getElementById\("market-selector"\),\s*trigger: \(\) => document\.getElementById\("market-selector-trigger"\)/.test(src)
        && /const marketStatsPopup = makeDropdown\(\{\s*wrap: \(\) => document\.getElementById\("market-stats-toggle"\),\s*trigger: \(\) => document\.getElementById\("market-stats-trigger"\)/.test(src)
        && /const marketStatMorePopup = makeDropdown\(\{\s*wrap: \(\) => document\.querySelector\("\.market-stat-more"\),\s*trigger: \(\) => document\.getElementById\("market-stats-more"\)/.test(src));
    const wireMenu = funcBody(src, "function wireMenuButton(");
    check("wireMenuButton — trigger keydown: Enter / Space / ArrowDown open onto the first item, ArrowUp onto the last, Escape closes an open menu back to the trigger; the trigger's click toggles (an assistive-tech click lands on the first item)",
      wireMenu !== null && /trigger\.addEventListener\("keydown"/.test(wireMenu)
        && /e\.key === "ArrowDown" \|\| e\.key === "Enter" \|\| e\.key === " "\) \{ e\.preventDefault\(\); open\(0\); \}/.test(wireMenu)
        && /e\.key === "ArrowUp"\) \{ e\.preventDefault\(\); open\(-1\); \}/.test(wireMenu)
        && /e\.key === "Escape" && d\.isOpen\(\)\) \{[^}]*close\(true\)/.test(wireMenu)
        && /if \(d\.isOpen\(\)\) close\(false\);[\s\S]*?else open\(e\.detail === 0 \? 0 : undefined\);/.test(wireMenu),
      "Enter / Space are preventDefault-ed so the key path owns the open (no double toggle through the native click)");
    check("wireMenuButton — menu keydown: ArrowDown / ArrowUp move with wrap, Home / End jump, Escape closes back to the trigger (and stops propagating), Tab closes; an item's click activates then returns focus to the trigger",
      wireMenu !== null && /menu\.addEventListener\("keydown"/.test(wireMenu)
        && /"ArrowDown"\) \{ e\.preventDefault\(\); list\[\(at \+ 1\) % list\.length\]\?\.focus\(\); \}/.test(wireMenu)
        && /"ArrowUp"\) \{ e\.preventDefault\(\); list\[\(at - 1 \+ list\.length\) % list\.length\]\?\.focus\(\); \}/.test(wireMenu)
        && /"Home"\) \{ e\.preventDefault\(\); list\[0\]\?\.focus\(\); \}/.test(wireMenu)
        && /"End"\) \{ e\.preventDefault\(\); list\[list\.length - 1\]\?\.focus\(\); \}/.test(wireMenu)
        && /"Escape"\) \{ e\.preventDefault\(\); e\.stopPropagation\(\); close\(true\); \}/.test(wireMenu)
        && /"Tab"\) \{ close\(true\);/.test(wireMenu)
        && /onActivate\(item\);\s*close\(true\);/.test(wireMenu));
    check("wireMenuButton's open / close go through the dropdown's setter, and close(true) returns focus to the trigger",
      wireMenu !== null && /const open = \(focusIndex\) => \{\s*d\.setOpen\(true\);/.test(wireMenu) && /const close = \(refocus\) => \{\s*d\.setOpen\(false\);\s*if \(refocus\) trigger\.focus\(\);/.test(wireMenu));
    const wireDisc = funcBody(src, "function wireDisclosure(");
    check("wireDisclosure: the trigger's own click toggles through the setter and Escape closes — listeners on the trigger element, so the overflow trigger keeps them as it moves",
      wireDisc !== null && /trigger\.addEventListener\("click", \(\) => d\.setOpen\(!d\.isOpen\(\)\)\)/.test(wireDisc) && /e\.key === "Escape" && d\.isOpen\(\)\) \{[^}]*d\.setOpen\(false\)/.test(wireDisc));
    const setup = funcBody(src, "function setupEventListeners()");
    check("setupEventListeners wires the three menus through wireMenuButton (the Markets and Swap granularity menus on .ob-gran-option, the market selector on .market-dropdown-item) and the two popups through wireDisclosure",
      setup !== null && /wireMenuButton\(obGranMenu, \{\s*menu: document\.getElementById\("ob-gran-menu"\),\s*itemSelector: "\.ob-gran-option"/.test(setup)
        && /wireMenuButton\(swapObGranMenu, \{\s*menu: document\.getElementById\("swap-ob-gran-menu"\),\s*itemSelector: "\.ob-gran-option"/.test(setup)
        && /wireMenuButton\(marketSelectorMenu, \{\s*menu: document\.getElementById\("market-dropdown"\),\s*itemSelector: "\.market-dropdown-item"/.test(setup)
        && /wireDisclosure\(marketStatsPopup\);\s*wireDisclosure\(marketStatMorePopup\);/.test(setup));
    check("the outside-click closer walks DROPDOWNS through each setter, no bare .open toggle survives for these dropdowns (so aria-expanded cannot drift), and selectMarket's close-all uses the setters too",
      setup !== null && /for \(const d of DROPDOWNS\) \{\s*const wrap = d\.wrapEl\(\);\s*if \(wrap && d\.isOpen\(\) && !wrap\.contains\(e\.target\)\) d\.setOpen\(false\);/.test(setup)
        && !/getElementById\("market-selector"\)\.classList/.test(src) && !/getElementById\("market-stats-toggle"\)\?\.classList/.test(src)
        && !/market-stat-more\.open"\)\?\.classList\.remove/.test(src) && !/granEl\b/.test(src) && !/swapGranEl\b/.test(src)
        && /marketSelectorMenu\.setOpen\(false\);\s*marketStatsPopup\.setOpen\(false\);\s*marketStatMorePopup\.setOpen\(false\);/.test(src));
    const fillGran = funcBody(src, "function fillGranMenu(");
    check("fillGranMenu renders the steps as role=menuitem buttons at tabindex=-1 through setMenuItems (keyed by value), and leaves an unchanged option set alone (the book re-renders every poll)",
      fillGran !== null && /setMenuItems\(menu, options\.map\(\(o\) =>\s*`<button type="button" class="ob-gran-option\$\{o\.value === currentG \? " active" : ""\}" role="menuitem" tabindex="-1" data-value="\$\{o\.value\}">\$\{o\.label\}<\/button>`/.test(fillGran)
        && /if \(menu\.dataset\.sig === sig\) return;/.test(fillGran),
      "div items cannot take focus or activate on Enter / Space; a rebuild every 2 s would drop focus mid-walk");
    const renderDrop = funcBody(src, "function renderMarketDropdown()");
    check("renderMarketDropdown renders the markets as role=menuitem buttons at tabindex=-1 through setMenuItems (keyed by market) and attaches no per-item listener (activation is delegated from the menu)",
      renderDrop !== null && /setMenuItems\(container, list\s*\.map\(\(m\) => `<button type="button" class="market-dropdown-item \$\{selectedMarket === m\.id \? "active" : ""\}" role="menuitem" tabindex="-1" data-market="\$\{escH\(m\.id\)\}">/.test(renderDrop)
        && /\.join\(""\), "market"\)/.test(renderDrop) && !/addEventListener/.test(renderDrop));
    const setItems = funcBody(src, "function setMenuItems(");
    check("setMenuItems rebuilds a menu's items and gives focus back to the item the keyboard was on — by its data key, else by position",
      setItems !== null && /container\.innerHTML = html;/.test(setItems) && /items\.find\(\(it\) => it\.dataset\[key\] === want\) \|\| items\[Math\.min\(at, items\.length - 1\)\]\)\?\.focus\(\)/.test(setItems));
    const mode = funcBody(src, "function updateMarketHeaderMode()");
    check("updateMarketHeaderMode parks the shared keyboard trigger in the trigger cell with the popup (handing focus back if it had it), restores .open through the setter, and its reset() closes through the setter — the semantics survive re-layout",
      mode !== null && /if \(more\) trigger\.appendChild\(more\);\s*trigger\.appendChild\(overflow\);\s*if \(hadFocus\) more\.focus\(\);/.test(mode)
        && /marketStatMorePopup\.setOpen\(openBefore === trigger\);/.test(mode) && /c\.classList\.remove\("market-stat-more", "open"\); \}\s*marketStatMorePopup\.setOpen\(false\);/.test(mode)
        && !/trigger\.classList\.add\("open"\)/.test(mode));
    const obWrap = obCss === null ? null : /\.ob-granularity \{([^}]*)\}/.exec(stripCss(obCss));
    check("orderbook.css: .ob-gran-trigger draws the box .ob-granularity drew (--bg-input, 1px --border, 5px 10px, radius 4px, 13px, font: inherit) and the wrapper draws none, with a :focus-visible ring; .ob-gran-option is a reset button styled alike on :hover and :focus-visible plus an inset ring the scrolling menu cannot cut off",
      obCss !== null && obWrap !== null && !/border|padding|background/.test(obWrap[1])
        && /\.ob-gran-trigger \{[^}]*padding: 5px 10px;[^}]*background: var\(--bg-input\);[^}]*border: 1px solid var\(--border\);[^}]*border-radius: 4px;[^}]*color: var\(--text-dim\);[^}]*font: inherit;[^}]*font-size: 13px;/.test(obCss)
        && /\.ob-gran-trigger:focus-visible \{ outline: 2px solid var\(--accent\); outline-offset: 2px; \}/.test(obCss)
        && /\.ob-gran-option \{[^}]*width: 100%;[^}]*border: 0;[^}]*background: transparent;[^}]*font: inherit;[^}]*text-align: left;/.test(obCss)
        && /\.ob-gran-option:hover, \.ob-gran-option:focus-visible \{ background: var\(--bg-hover\); color: var\(--text\); \}/.test(obCss)
        && /\.ob-gran-option:focus-visible \{ outline: 2px solid var\(--accent\); outline-offset: -2px; \}/.test(obCss));
    check("responsive.css: the mobile size of the granularity control sits on .ob-gran-trigger (the box) — not on the wrapper",
      sheets.responsive !== null && /\.ob-gran-trigger \{ font-size: 12px; padding: 4px 8px; \}/.test(sheets.responsive) && !/\.ob-granularity \{/.test(stripCss(sheets.responsive)));
    const mkCss = sheets.markets === null ? null : stripCss(sheets.markets);
    const selWrap = mkCss === null ? null : /\.market-selector \{([^}]*)\}/.exec(mkCss);
    check("markets.css: .market-selector-trigger is a reset button (padding 0, border 0, transparent, color / font / letter-spacing inherited, pointer) with a :focus-visible ring, the wrapper keeps only its layout, and the desktop title size sits on the h2 (two classes deep) so the heading's line box is unchanged",
      mkCss !== null && selWrap !== null && !/cursor|gap|user-select/.test(selWrap[1])
        && /\.market-selector-trigger \{[^}]*padding: 0;[^}]*border: 0;[^}]*background: transparent;[^}]*color: inherit;[^}]*font: inherit;[^}]*letter-spacing: inherit;[^}]*cursor: pointer;/.test(mkCss)
        && /\.market-selector-trigger:focus-visible \{ outline: 2px solid var\(--accent\);/.test(mkCss)
        && /@media \(min-width: 901px\) \{\s*\.market-header \.market-selector h2 \{ font-size: 19px; font-weight: 600; \}/.test(mkCss) && !/#market-title/.test(mkCss));
    check("markets.css: .market-dropdown-item is a reset button (full-width, border 0, transparent, font: inherit, left-aligned) styled alike on :hover and :focus-visible, plus an inset ring the scrolling list cannot cut off",
      mkCss !== null && /\.market-dropdown-item \{[^}]*width: 100%;[^}]*border: 0;[^}]*background: transparent;[^}]*color: inherit;[^}]*font: inherit;[^}]*text-align: left;/.test(mkCss)
        && /\.market-dropdown-item:hover, \.market-dropdown-item:focus-visible \{\s*background: var\(--bg-hover\);\s*\}/.test(mkCss)
        && /\.market-dropdown-item:focus-visible \{ outline: 2px solid var\(--accent\); outline-offset: -2px; \}/.test(mkCss));
    const msmWrap = mkCss === null ? null : /\.market-stats-mobile \{([^}]*)\}/.exec(mkCss);
    check("markets.css: .msm-trigger is a reset button stretched across its wrapper (flex: 1 — the tap target is the strip it was) with a :focus-visible ring, and the wrapper no longer claims the pointer",
      mkCss !== null && msmWrap !== null && !/cursor/.test(msmWrap[1])
        && /\.msm-trigger \{[^}]*flex: 1;[^}]*padding: 0;[^}]*border: 0;[^}]*background: transparent;[^}]*color: inherit;[^}]*font: inherit;[^}]*cursor: pointer;/.test(mkCss)
        && /\.msm-trigger:focus-visible \{ outline: 2px solid var\(--accent\);/.test(mkCss));
    check("markets.css: .ms-more-btn is hidden in a plain stat cell and, in the trigger cell, a transparent absolute overlay (inset: 0) with a :focus-visible ring — Tab reaches exactly the cell that is the trigger",
      mkCss !== null && /\.market-stat \.ms-more-btn \{ display: none; \}/.test(mkCss)
        && /\.market-stat-more \.ms-more-btn \{[^}]*display: block;[^}]*position: absolute;[^}]*inset: 0;[^}]*border: 0;[^}]*background: transparent;[^}]*cursor: pointer;/.test(mkCss)
        && /\.market-stat-more \.ms-more-btn:focus-visible \{ outline: 2px solid var\(--accent\);/.test(mkCss));

    // E4d — the dropdown machinery's follow-ups (1793509280). The user menu
    // is a makeDropdown instance too: closeUserMenu used to run on EVERY
    // document click from the shared closer and rewrite #user-menu-trigger's
    // aria-expanded each time (a same-value setAttribute is still a mutation
    // record — MutationObserver noise, and assistive tech may announce it);
    // now the closer touches only open dropdowns, the trigger toggles through
    // the setter, and the setter writes .open and aria-expanded only on a
    // change. The granularity menus open scrolled to the top: the browser
    // keeps a scroller's offset across the display flip, so a list the
    // keyboard had walked to its end (End / ArrowUp) re-opened showing its
    // bottom instead of Exact; the reset sits in placeGranMenu, which the
    // setter now runs AFTER the class flip (a display:none element cannot
    // take a scrollTop).
    check("the user menu is a makeDropdown instance (userMenu over #user-menu / #user-menu-trigger), closeUserMenu closes through its setter, and no bare write of #user-menu-trigger's aria-expanded or #user-menu's .open survives",
      /const userMenu = makeDropdown\(\{\s*wrap: \(\) => document\.getElementById\("user-menu"\),\s*trigger: \(\) => document\.getElementById\("user-menu-trigger"\),\s*\}\);/.test(src)
        && /function closeUserMenu\(\) \{ userMenu\.setOpen\(false\); \}/.test(src)
        && !/getElementById\("user-menu-trigger"\)\?\.setAttribute/.test(src) && !/getElementById\("user-menu"\)\?\.classList\.(remove|toggle)\("open"/.test(src)
        && !/menu\.classList\.toggle\("open"\)/.test(src),
      "a bare write beside the setter is the drift makeDropdown exists to close");
    // Re-pointed by 1793511304: the user menu is a MENU BUTTON now — the
    // hand-wired trigger toggle and the per-item click listeners (each
    // closing through closeUserMenu) are gone; wireMenuButton wires the
    // trigger and the menu, routes the activated item's data-useraction, and
    // closes + refocuses the trigger itself. The trigger's click still
    // bubbles to the closer (the router never stops it), so a menu open
    // elsewhere closes. closeUserMenu stays for renderProfileChip's sign-out
    // path — its one caller. The markup carries the E4b/E4c contract: the
    // trigger is a real menu button (aria-haspopup=menu, aria-controls), the
    // dropdown a named role=menu of role=menuitem buttons at tabindex=-1.
    check("index.html: #user-menu-trigger is a menu button — type=button, aria-haspopup=menu, aria-expanded=false at load, aria-controls=user-menu-dropdown — with its caret aria-hidden, over #user-menu-dropdown as a role=menu with a name",
      html !== null && /<button type="button" id="user-menu-trigger" class="user-menu-trigger" aria-haspopup="menu" aria-expanded="false" aria-controls="user-menu-dropdown">[\s\S]*?<svg class="user-menu-caret"[^>]*aria-hidden="true">[\s\S]*?<\/button>\s*<div class="user-menu-dropdown" id="user-menu-dropdown" role="menu" aria-label="[^"]+">/.test(html),
      "aria-haspopup=\"true\" with no aria-controls over a bare div was the pre-1793511304 markup");
    const userItems = html === null ? [] : Array.from(html.matchAll(/<button[^>]*class="user-menu-item"[^>]*>/g), (m) => m[0]);
    check("index.html: every .user-menu-item is a type=button role=menuitem at tabindex=-1 (the trigger is the one tab stop) carrying a data-useraction, and the separator keeps role=separator",
      userItems.length >= 2 && userItems.every((tag) => /type="button"/.test(tag) && /role="menuitem"/.test(tag) && /tabindex="-1"/.test(tag) && /data-useraction="[^"]+"/.test(tag))
        && html !== null && /<div class="user-menu-sep" role="separator"><\/div>/.test(html),
      "a plain button is a tab stop of its own and announces no menu");
    check("setupEventListeners wires the user menu through wireMenuButton(userMenu, …) — #user-menu-dropdown, .user-menu-item, onActivate routing data-useraction (acct:<section> → #account/<section>, signout → logout) — with no hand-wired trigger toggle, no per-item listener and no closeUserMenu call left in it",
      setup !== null && /wireMenuButton\(userMenu, \{\s*menu: document\.getElementById\("user-menu-dropdown"\),\s*itemSelector: "\.user-menu-item",\s*onActivate: \(item\) => \{\s*const action = item\.dataset\.useraction;[\s\S]*?window\.location\.hash = "account\/" \+ action\.slice\(5\);[\s\S]*?else if \(action === "signout"\) \{\s*logout\(\);\s*\}\s*\},\s*\}\);/.test(setup)
        && !/userTrigger/.test(setup) && !/querySelectorAll\("\.user-menu-item"\)/.test(setup) && !/closeUserMenu/.test(setup),
      "a hand-wired toggle or a per-item close beside the router is the drift E4c closed");
    const chip = funcBody(src, "function renderProfileChip()");
    check("closeUserMenu survives for renderProfileChip's sign-out path alone — its one call site",
      chip !== null && /closeUserMenu\(\);/.test(chip) && (src.match(/closeUserMenu\(\);/g) || []).length === 1);
    check("header.css: .user-menu-item is styled alike on :hover and :focus-visible, plus an inset ring the 6px-padded dropdown cannot cut off — the keyboard's walk is visible",
      sheets.header !== null && /\.user-menu-item:hover, \.user-menu-item:focus-visible \{ background: var\(--bg-input\); color: var\(--accent\); \}/.test(sheets.header)
        && /\.user-menu-item:focus-visible \{ outline: 2px solid var\(--accent\); outline-offset: -2px; \}/.test(sheets.header));
    check("the outside-click closer is the DROPDOWNS walk and nothing else — no closeUserMenu, no user-menu or mini-chart-view lookup after the loop — so a document click writes nothing while every dropdown is closed",
      setup !== null && /document\.addEventListener\("click", \(e\) => \{\s*for \(const d of DROPDOWNS\) \{\s*const wrap = d\.wrapEl\(\);\s*if \(wrap && d\.isOpen\(\) && !wrap\.contains\(e\.target\)\) d\.setOpen\(false\);\s*\}\s*\}\);/.test(setup));
    check("makeDropdown's setter writes .open only on a change (beside the aria-expanded guard) and runs onOpen AFTER the class flip, so the popup has its box when placeGranMenu resets its scroll position",
      mkDrop !== null && /if \(on !== isOpen\(\)\) w\?\.classList\.toggle\("open", on\);/.test(mkDrop)
        && (() => { const flip = mkDrop.indexOf('classList.toggle("open", on)'); const hook = mkDrop.indexOf("if (on && onOpen) onOpen(w);"); return flip >= 0 && hook >= 0 && flip < hook; })(),
      "onOpen before the flip hands placeGranMenu a display:none menu, whose scrollTop write is dropped");
    const place = funcBody(src, "function placeGranMenu(");
    check("placeGranMenu resets the menu's scrollTop to 0 as it opens (after positioning it), so an End / ArrowUp walk does not leave the next open at the bottom of the list",
      place !== null && /menu\.style\.bottom = [^\n]*;\s*menu\.scrollTop = 0;/.test(place));

    // E4e — the last two ad-hoc document-level closers, audited (1793511304).
    // The select replacement under Wallet / Swap / Earn (enhanceSelectDropdown
    // — a DOM menu over a visually-hidden native <select>) kept its own
    // document-level click closer and an unscoped Escape listener per
    // instance, showed the menu by an inline display toggle, and its button
    // announced nothing. It is a list of choices, so it is a menu button now:
    // a makeDropdown instance (wrap = its .dd wrapper, trigger = its button,
    // the options re-rendered in onOpen because the native list can change
    // under it) wired by wireMenuButton, the menu shown off the wrapper's
    // .open by stats.css. The oracle error popover was audited and left OUT
    // by design: N triggers re-minted by every renderStatsOracle share one
    // body-level fixed popover opened on hover and pinned on tap / Enter /
    // Space — no wrapper, no single trigger, nothing to pick — so it keeps
    // its own document-level closers, which exempt the popover itself; the
    // ruling is pinned so the next audit reads it instead of re-deriving it.
    const enh = funcBody(src, "function enhanceSelectDropdown(");
    check("enhanceSelectDropdown is a makeDropdown instance — wrap, trigger: btn, onOpen: renderMenu — wired by wireMenuButton on .dd-opt (activation writes the native select and dispatches change), with no document-level closer, no Escape listener, no inline display toggle and no dd-open class of its own",
      enh !== null && /const dd = makeDropdown\(\{ wrap, trigger: btn, onOpen: renderMenu \}\);/.test(enh)
        && /wireMenuButton\(dd, \{\s*menu,\s*itemSelector: "\.dd-opt",\s*onActivate: \(opt\) => \{\s*if \(sel\.value !== opt\.dataset\.v\) \{ sel\.value = opt\.dataset\.v; renderBtn\(\); sel\.dispatchEvent\(new Event\("change", \{ bubbles: true \}\)\); \}\s*\},\s*\}\);/.test(enh)
        && !/document\.addEventListener/.test(enh) && !/style\.display/.test(enh) && !/dd-open/.test(enh),
      "a closer of its own beside the DROPDOWNS walk is the pre-1793506246 shape");
    check("enhanceSelectDropdown: the button is a menu button (aria-haspopup=menu, aria-expanded=false at build, aria-controls naming the menu) over a role=menu named by cfg.label, its options role=menuitem buttons at tabindex=-1 — and the four call sites name their menus",
      enh !== null && /btn\.setAttribute\("aria-haspopup", "menu"\);\s*btn\.setAttribute\("aria-expanded", "false"\);\s*btn\.setAttribute\("aria-controls", menuId\);/.test(enh)
        && /menu\.id = menuId;\s*menu\.setAttribute\("role", "menu"\);\s*menu\.setAttribute\("aria-label", cfg\.label \|\| "Options"\);/.test(enh)
        && /class="dd-opt\$\{o\.value === sel\.value \? " dd-opt-active" : ""\}" role="menuitem" tabindex="-1" data-v="\$\{o\.value\}"/.test(enh)
        && /enhanceSelectDropdown\("wallet-token", \{ label: "[^"]+" \}\)/.test(src) && /enhanceSelectDropdown\("swap-from-token", \{ icons: true, label: "[^"]+" \}\)/.test(src)
        && /enhanceSelectDropdown\("swap-to-token", \{ icons: true, label: "[^"]+" \}\)/.test(src) && /enhanceSelectDropdown\("earn-vault-deposit-token", \{ label: "[^"]+" \}\)/.test(src),
      "a button that announces nothing over an unnamed list is what the audit found");
    const statsCss = read("src/frontend/src/styles/stats.css");
    const statsRules = statsCss === null ? null : stripCss(statsCss);
    check("stats.css: the .dd menu shows off the wrapper's .open (the setter's class) — .dd-menu display:none at rest, .dd.open .dd-menu block, the chevron turns on .dd.open, no dd-open rule survives — and .dd-opt is styled alike on :hover and :focus-visible plus an inset ring the scrolling menu cannot cut off",
      statsRules !== null && /\.dd-menu \{\s*display: none;/.test(statsRules) && /\.dd\.open \.dd-menu \{ display: block; \}/.test(statsRules)
        && /\.dd\.open \.dd-chevron \{ transform: rotate\(180deg\); \}/.test(statsRules) && !/dd-open/.test(statsRules)
        && /\.dd-opt:hover, \.dd-opt:focus-visible \{ background: var\(--bg-hover\); \}/.test(statsRules)
        && /\.dd-opt:focus-visible \{ outline: 2px solid var\(--accent\); outline-offset: -2px; \}/.test(statsRules));
    const oraclePop = funcBody(src, "function setupOracleErrPopover(");
    check("the oracle error popover stays outside DROPDOWNS by design — its triggers are role=button tabindex=0 spans with an aria-label, Enter / Space pin the popover, Escape hides it, its outside-click closer exempts the trigger AND the popover — and the site says why",
      oraclePop !== null && /class="oracle-err-trigger" tabindex="0" role="button" aria-label="[^"]+"/.test(src)
        && /t && \(e\.key === "Enter" \|\| e\.key === " "\)\) \{ e\.preventDefault\(\); showOracleErrPop\(t, true\); \}/.test(oraclePop)
        && /if \(e\.target\.closest\("\.oracle-err-trigger"\) \|\| e\.target\.closest\("\.oracle-err-pop"\)\) return;\s*hideOracleErrPop\(true\);/.test(oraclePop)
        && /e\.key === "Escape"\) hideOracleErrPop\(true\);/.test(oraclePop)
        && rawMain !== null && /NOT a makeDropdown instance, by design \(audited under 1793511304\)/.test(rawMain),
      "a popover with N re-rendered triggers has no wrapper for the DROPDOWNS walk to key on");
    // 1793512901 — the pinned popover survives the 5 s stats tick, and the
    // select button says which select it is. Every renderStatsOracle
    // re-mints the triggers, so pop._for was a DETACHED node after the first
    // re-render: the next click compared `_for === t` false and re-showed a
    // pinned popover instead of toggling it off, and the popover sat at the
    // old row's position when the rows reordered. Now the trigger carries
    // its (asset, source) key — one source fails under several assets, so
    // the source id alone is ambiguous — and reanchorOracleErrPop, run right
    // after EVERY innerHTML write of the container, re-anchors an open
    // popover on the fresh trigger for that key (pin state and any pending
    // mouseout hide untouched; message and position refreshed) or hides it
    // when the source recovered. Placement is ONE helper (placeOracleErrPop)
    // shared with showOracleErrPop, so the first show and the re-anchor
    // cannot drift. And enhanceSelectDropdown's button, whose name was its
    // bare value ("BTC, menu button"), is named `${cfg.label}: ${value}`.
    const statsOracleBody = funcBody(src, "function renderStatsOracle(");
    const oracleReanchor = funcBody(src, "function reanchorOracleErrPop(");
    const showOraclePop = funcBody(src, "function showOracleErrPop(");
    const placeOraclePop = funcBody(src, "function placeOracleErrPop(");
    check("renderStatsOracle: the error trigger carries its (asset, source) key — data-asset=\"${asset}\" data-src=\"${escapeAttr(r.sourceId)}\" beside its aria-label and data-err",
      statsOracleBody !== null && /class="oracle-err-trigger" tabindex="0" role="button" aria-label="Show \$\{r\.sourceId\} oracle error" data-asset="\$\{asset\}" data-src="\$\{escapeAttr\(r\.sourceId\)\}" data-err="\$\{escapeAttr\(/.test(statsOracleBody),
      "without a key on the trigger a re-render has nothing to re-anchor by (one source fails under several assets)");
    check("reanchorOracleErrPop acts only on an OPEN popover whose trigger is detached, finds the fresh trigger by its (asset, source) key through oracleErrTriggerFor (the one lookup, since 1793514706), refreshes the message, re-points _for and re-places through placeOracleErrPop — and never touches the pinned class, the hide timer or showOracleErrPop",
      oracleReanchor !== null && /if \(!pop \|\| pop\.style\.display !== "block" \|\| !pop\._for \|\| pop\._for\.isConnected\) return;/.test(oracleReanchor)
        && /const \{ asset, src \} = pop\._for\.dataset;\s*const next = oracleErrTriggerFor\(container, asset, src\);/.test(oracleReanchor)
        && /\.textContent = next\.dataset\.err \|\| "\(no message reported\)";\s*pop\._for = next;\s*placeOracleErrPop\(pop, next\);/.test(oracleReanchor)
        && !/pinned/.test(oracleReanchor) && !/cancelHideOraclePop|scheduleHideOraclePop|showOracleErrPop/.test(oracleReanchor),
      "re-showing through showOracleErrPop would cancel a pending mouseout hide; touching 'pinned' would unpin, or pin a hover popover");
    check("reanchorOracleErrPop hides (force) when no fresh trigger carries the key — that source recovered, so there is nothing to anchor to",
      oracleReanchor !== null && /if \(!next\) \{ hideOracleErrPop\(true\); return; \}/.test(oracleReanchor),
      "a popover left open for a recovered source floats at a stale position");
    check("renderStatsOracle runs reanchorOracleErrPop(container) right after EVERY container.innerHTML write — the empty-state branch included",
      statsOracleBody !== null && (statsOracleBody.match(/container\.innerHTML = /g) || []).length >= 2
        && (statsOracleBody.match(/container\.innerHTML = [^\n]*;\s*reanchorOracleErrPop\(container\);/g) || []).length === (statsOracleBody.match(/container\.innerHTML = /g) || []).length,
      "a re-render without the re-anchor leaves pop._for detached until the next click");
    check("showOracleErrPop places through the same placeOracleErrPop(pop, trigger) — the one helper that measures (getBoundingClientRect) — so the first show and the re-anchor cannot drift",
      showOraclePop !== null && /pop\.style\.display = "block";\s*placeOracleErrPop\(pop, trigger\);/.test(showOraclePop) && !/getBoundingClientRect/.test(showOraclePop)
        && placeOraclePop !== null && /const r = trigger\.getBoundingClientRect\(\);/.test(placeOraclePop) && (src.match(/getBoundingClientRect\(\)/g) || []).length >= 1
        && !/getBoundingClientRect/.test(oracleReanchor || ""),
      "two copies of the placement arithmetic is the drift one helper exists to prevent");
    check("enhanceSelectDropdown: renderBtn names the button `${cfg.label}: ${value}` (\"Sell token: BTC\") through aria-label on every render — the bare value only when no label was given",
      enh !== null && /const renderBtn = \(\) => \{\s*btn\.innerHTML = `[^`]*`;\s*const text = labelFor\(sel\.value\);\s*btn\.querySelector\("\.dd-label"\)\.textContent = text;\s*btn\.setAttribute\("aria-label", cfg\.label \? `\$\{cfg\.label\}: \$\{text\}` : text\);\s*\};/.test(enh),
      "a button named by its value alone tells AT 'BTC, menu button' and nothing about which select it is");
    // 1793514706 — the two leftovers of 1793512901. (1) FOCUS: the same 5 s
    // re-render replaced the focused trigger under a keyboard user, who landed
    // on <body> within a tick. renderStatsOracle reads the focused trigger's
    // (asset, source) key BEFORE its innerHTML write (afterwards activeElement
    // is already <body>) and refocuses the re-minted trigger after EVERY write
    // — preventScroll, nothing when the row recovered. The lookup by key is
    // ONE helper (oracleErrTriggerFor) shared with reanchorOracleErrPop, so
    // the popover and the focus cannot land on different triggers. (2) FOLLOW:
    // the fixed popover sat where show time placed it while the page scrolled
    // under it, up to 5 s from its trigger; setupOracleErrPopover now
    // re-places it on scroll (capture: inner scrollers count; passive) and
    // resize, coalesced through one rAF, only while shown and its trigger is
    // connected — local to the popover, never a third copy of the placement.
    const triggerFor = funcBody(src, "function oracleErrTriggerFor(");
    const focusedKey = funcBody(src, "function focusedOracleErrKey(");
    const refocus = funcBody(src, "function refocusOracleErrTrigger(");
    check("oracleErrTriggerFor(container, asset, src) is the ONE lookup of a trigger by its (asset, source) key — the find on data-asset + data-src lives there and nowhere else in main.js",
      triggerFor !== null && /\.find\(\(t\) => t\.dataset\.asset === asset && t\.dataset\.src === src\) \|\| null;/.test(triggerFor)
        && (src.match(/t\.dataset\.asset === asset && t\.dataset\.src === src/g) || []).length === 1,
      "a second copy of the key comparison is how the popover and the focus come to land on different triggers");
    check("focusedOracleErrKey returns document.activeElement's (asset, src) key only when it is an .oracle-err-trigger INSIDE the container — null otherwise",
      focusedKey !== null && /const a = document\.activeElement;/.test(focusedKey)
        && /if \(!container \|\| !a \|\| !container\.contains\(a\) \|\| !a\.classList\.contains\("oracle-err-trigger"\)\) return null;/.test(focusedKey)
        && /return \{ asset: a\.dataset\.asset, src: a\.dataset\.src \};/.test(focusedKey),
      "without the container guard any focused element with a dataset would be refocused into the stats table");
    check("refocusOracleErrTrigger finds the re-minted trigger through oracleErrTriggerFor and focuses it with { preventScroll: true } — nothing when no trigger carries the key, and it never shows, hides or scrolls",
      refocus !== null && /if \(!key\) return;/.test(refocus)
        && /const next = oracleErrTriggerFor\(container, key\.asset, key\.src\);\s*if \(next\) next\.focus\(\{ preventScroll: true \}\);/.test(refocus)
        && !/showOracleErrPop|hideOracleErrPop|scrollIntoView/.test(refocus),
      "a plain focus() scrolls the page to the trigger the re-anchor just placed the popover from; a recovered row has nothing to focus");
    check("renderStatsOracle reads focusedOracleErrKey(container) BEFORE its first container.innerHTML write and runs refocusOracleErrTrigger(container, focusKey) right after EVERY reanchorOracleErrPop(container) — the empty-state branch included",
      statsOracleBody !== null && (() => {
        const read = statsOracleBody.indexOf("const focusKey = focusedOracleErrKey(container);");
        const write = statsOracleBody.indexOf("container.innerHTML = ");
        return read >= 0 && write >= 0 && read < write;
      })()
        && (statsOracleBody.match(/reanchorOracleErrPop\(container\);/g) || []).length >= 2
        && (statsOracleBody.match(/reanchorOracleErrPop\(container\);\s*refocusOracleErrTrigger\(container, focusKey\);/g) || []).length === (statsOracleBody.match(/reanchorOracleErrPop\(container\);/g) || []).length,
      "a read after the write sees <body>; a write without the refocus drops a keyboard user on <body> within 5 s");
    check("setupOracleErrPopover follows the trigger between ticks: a passive CAPTURE scroll listener and a passive resize listener on window share one rAF-coalesced follower that re-places through placeOracleErrPop(pop, pop._for) only while the popover is shown and pop._for.isConnected — re-checked inside the frame — and skips scrolls inside the popover itself",
      oraclePop !== null && /let followQueued = false;/.test(oraclePop)
        && /const followTrigger = \(e\) => \{\s*const pop = _oracleErrPop;\s*if \(!pop \|\| pop\.style\.display !== "block" \|\| !pop\._for\?\.isConnected\) return;\s*if \(e\.target instanceof Node && pop\.contains\(e\.target\)\) return;\s*if \(followQueued\) return;\s*followQueued = true;\s*requestAnimationFrame\(\(\) => \{\s*followQueued = false;\s*if \(pop\.style\.display === "block" && pop\._for\?\.isConnected\) placeOracleErrPop\(pop, pop\._for\);\s*\}\);\s*\};/.test(oraclePop)
        && /window\.addEventListener\("scroll", followTrigger, \{ capture: true, passive: true \}\);\s*window\.addEventListener\("resize", followTrigger, \{ passive: true \}\);/.test(oraclePop),
      "placing a hidden popover or a detached trigger throws or paints at 0,0; without capture an inner scroller's scroll never reaches window; without the rAF guard a wheel burst measures layout per event");
    check("placeOracleErrPop stays the ONE placer — exactly three call sites (showOracleErrPop, reanchorOracleErrPop, the follower in setupOracleErrPopover) — and the follower's scroll listener is main.js's only one",
      (src.match(/(?<!function )placeOracleErrPop\(pop, /g) || []).length === 3 && /placeOracleErrPop\(pop, pop\._for\)/.test(oraclePop)
        && (src.match(/addEventListener\("scroll"/g) || []).length === 1,
      "a fourth placer, or a second scroll follower, is the drift the one helper exists to prevent");

    // E5 — the time axis honours the tick's KIND (1793498838). lightweight-
    // charts classifies every tick (TickMarkType: Year / Month / DayOfMonth /
    // Time / TimeWithSeconds) before it calls timeScale.tickMarkFormatter;
    // both charts' formatters printed HH:MM regardless, so a 1H chart zoomed
    // out across a day boundary read "01:00 01:00 01:00" and nothing on the
    // axis said which day was on screen. ONE helper serves both option blocks
    // so they cannot drift — the pin is on the helper AND on both call sites.
    const tickLabel = funcBody(src, "function chartTickMarkLabel(");
    check("chartTickMarkLabel(time, tickMarkType) exists and switches on tickMarkType",
      tickLabel !== null && /function chartTickMarkLabel\(time, tickMarkType\)/.test(src) && /switch\s*\(\s*tickMarkType\s*\)/.test(tickLabel),
      "the formatter's second argument is the tick's kind; a helper that ignores it is the old behaviour under a new name");
    check("TickMarkType is imported from lightweight-charts and the helper names its members — no bare case 0..4 (the numbers are the library's to renumber)",
      /import \{[^}]*\bTickMarkType\b[^}]*\} from "lightweight-charts"/.test(src)
        && tickLabel !== null && !/case\s+\d+\s*:/.test(tickLabel));
    check("the helper branches: Year → the year, Month → the short month, DayOfMonth → day + short month, TimeWithSeconds → HH:MM:SS, Time (and the default) → HH:MM",
      tickLabel !== null
        && /case TickMarkType\.Year:\s*return d\.toLocaleDateString\(undefined, \{ year: "numeric" \}\)/.test(tickLabel)
        && /case TickMarkType\.Month:\s*return d\.toLocaleDateString\(undefined, \{ month: "short" \}\)/.test(tickLabel)
        && /case TickMarkType\.DayOfMonth:\s*return d\.toLocaleDateString\(undefined, \{ day: "numeric", month: "short" \}\)/.test(tickLabel)
        && /case TickMarkType\.TimeWithSeconds:\s*return d\.toLocaleTimeString\(undefined, \{ hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false \}\)/.test(tickLabel)
        && /case TickMarkType\.Time:\s*default:\s*return d\.toLocaleTimeString\(undefined, \{ hour: "2-digit", minute: "2-digit", hour12: false \}\)/.test(tickLabel));
    check("the helper keeps the charts' Date path — UTC seconds → new Date(time * 1000), rendered in the browser's zone with the default locale (no timeZone override, no hard-coded locale)",
      tickLabel !== null && /const d = new Date\(time \* 1000\)/.test(tickLabel) && !/timeZone/.test(tickLabel) && !/toLocale\w+\("/.test(tickLabel));
    const overlayChart = funcBody(src, "function renderChartData()");
    const miniChart = funcBody(src, "async function renderMiniChart()");
    const tickSites = src.match(/tickMarkFormatter\s*:[^\n]*/g) || [];
    check("BOTH chart option blocks hand the time scale the ONE helper — tickMarkFormatter: chartTickMarkLabel in renderChartData and in renderMiniChart; exactly two tickMarkFormatter sites in main.js and neither is an inline arrow",
      overlayChart !== null && miniChart !== null
        && /tickMarkFormatter: chartTickMarkLabel,/.test(overlayChart) && /tickMarkFormatter: chartTickMarkLabel,/.test(miniChart)
        && tickSites.length === 2 && !/tickMarkFormatter\s*:\s*\(/.test(src),
      `tickMarkFormatter sites: ${tickSites.join(" | ") || "(none)"}`);

    // E6 — the lazy older-page load fires on a USER pan only (1793502035).
    // lightweight-charts reports every change of the visible range, its own
    // included, and the chart's own changes all land at or left of the first
    // bar — where the subscribers read "the user reached the left edge" — so
    // every interval switch and overlay open bought a wasted older-page query
    // (seen on the seat venue: 100 -> 200 held with no pan). The programmatic
    // sources differ in timing: setData fires synchronously before the
    // re-anchor; fitContent is deferred to the widget's next animation frame
    // (minutes later in a hidden tab, where rAF is suspended); scrollToRealTime
    // animates over 400 ms (no longer run by showLastCandles — E7). A flag
    // cleared on the first event is therefore
    // wrong both ways (none may come; several may), so the gate is a flag with
    // a FRAME bound and a TIME bound, armed ahead of each programmatic motion.
    const settleMs = /const CHART_REANCHOR_SETTLE_MS = (\d+);/.exec(src);
    check("CHART_REANCHOR_SETTLE_MS is declared and keeps its >= 500 ms margin (sized to outlast lightweight-charts' 400 ms scrollToRealTime slide, which showLastCandles no longer runs — E7 — and kept for a slow frame and any trailing programmatic event)",
      settleMs !== null && Number(settleMs[1]) >= 500, settleMs ? `${settleMs[1]} ms` : "constant missing");
    check("the gate's state is per chart — a WeakMap keyed by the chart object, so the overlay and the mini chart share one helper and a removed chart leaks nothing",
      /const chartReanchors = new WeakMap\(\);/.test(src));
    const arm = funcBody(src, "function armChartReanchor(");
    const settling = funcBody(src, "function chartReanchorSettling(");
    check("armChartReanchor(chart) records the time bound (performance.now() + CHART_REANCHOR_SETTLE_MS) AND arms the frame bound (a requestAnimationFrame that marks the frame run)",
      arm !== null && /performance\.now\(\) \+ CHART_REANCHOR_SETTLE_MS/.test(arm) && /framed: false/.test(arm)
        && /requestAnimationFrame\(\(\) => \{ s\.framed = true; \}\);/.test(arm) && /chartReanchors\.set\(chart, s\)/.test(arm),
      arm === null ? "body not found" : "expected both bounds: a frame bound alone cannot span the 400 ms slide, a time bound alone misses the fit a hidden tab defers");
    check("chartReanchorSettling(chart) holds while EITHER bound is open — no frame yet OR inside the time window — and is false for a chart never armed",
      settling !== null && /chartReanchors\.get\(chart\)/.test(settling) && /s !== undefined && \(!s\.framed \|\| performance\.now\(\) < s\.until\)/.test(settling),
      settling === null ? "body not found" : settling);
    const showLast = funcBody(src, "function showLastCandles(");
    check("showLastCandles arms the gate FIRST — every re-anchor (fitContent / setVisibleLogicalRange) goes through it, the mini chart's first-resize re-anchor included",
      showLast !== null && /^\{\s*armChartReanchor\(chart\);/.test(showLast)
        && showLast.indexOf("armChartReanchor(chart)") < showLast.indexOf("fitContent(") && showLast.indexOf("armChartReanchor(chart)") < showLast.indexOf("setVisibleLogicalRange("),
      showLast === null ? "body not found" : "expected armChartReanchor(chart) as the first statement");
    const subscribers = [...src.matchAll(/subscribeVisibleLogicalRangeChange\(\(range\) => \{([\s\S]*?)\n  \}\);/g)].map((m) => m[1]);
    check("exactly two subscribeVisibleLogicalRangeChange subscribers in main.js (the overlay's and the mini chart's) and BOTH return while the gate is settling, before the range.from < 5 edge test",
      subscribers.length === 2 && subscribers.every((b) => /if \(chartReanchorSettling\((chartInstance|miniChartInstance)\)\) return;/.test(b)
        && b.indexOf("chartReanchorSettling(") < b.indexOf("range.from < 5")),
      `subscribers found: ${subscribers.length}; gated: ${subscribers.filter((b) => /chartReanchorSettling\(/.test(b)).length}`);
    check("the overlay's gate names the overlay chart and the mini chart's names the mini chart",
      subscribers.length === 2 && /chartReanchorSettling\(chartInstance\)/.test(subscribers[0]) && /chartReanchorSettling\(miniChartInstance\)/.test(subscribers[1]));
    check("changeChartInterval arms the gate BEFORE the setData that replaces the overlay's series — that setData fires a range event of its own, synchronously, ahead of showLastCandles",
      interval !== null && /armChartReanchor\(chartInstance\);\s*chartCandleSeries\.setData\(chartCandleData\.candles\);/.test(interval),
      "expected armChartReanchor(chartInstance) immediately before chartCandleSeries.setData(chartCandleData.candles)");
    check("the mini chart arms the gate before BOTH series replacements — the interval switch and the first load (the default 6 px bar spacing puts `from` below 5 on any chart wider than 600 px)",
      (src.match(/armChartReanchor\(miniChartInstance\);\s*miniChartSeries\.setData\(miniAllCandles\);\s*showLastCandles\(miniChartInstance, miniAllCandles\.length\);/g) || []).length === 2,
      `sites: ${(src.match(/armChartReanchor\(miniChartInstance\);/g) || []).length}`);
    check("the refresh paths never arm the gate — a page-0 merge is not a re-anchor, and a gate armed every 5 s would swallow a real pan (refreshChartData, miniChartMerge, loadOlderCandles, the mini lazy load)",
      refresh !== null && !/armChartReanchor\(/.test(refresh) && miniMerge !== null && !/armChartReanchor\(/.test(miniMerge[1])
        && older !== null && !/armChartReanchor\(/.test(older) && subscribers.length === 2 && subscribers.every((b) => !/armChartReanchor\(/.test(b)),
      "only the re-anchor paths arm: showLastCandles and the setData sites that precede it");
    // Exercised: the helpers are pure over the clock and rAF they are handed,
    // so their bodies are lifted out of main.js and driven through the truth
    // table a browser would — no frame yet, frame but inside the window,
    // both bounds spent, re-armed, and a chart that was never armed.
    if (arm && settling && settleMs) {
      let gate = null;
      const clock = { now: 1000 };
      const frames = [];
      try {
        gate = new Function("requestAnimationFrame", "performance",
          `const CHART_REANCHOR_SETTLE_MS = ${settleMs[1]}; const chartReanchors = new WeakMap();`
          + ` function armChartReanchor(chart) ${arm} function chartReanchorSettling(chart) ${settling}`
          + " return { armChartReanchor, chartReanchorSettling };")((cb) => frames.push(cb), { now: () => clock.now });
      } catch (e) { bad("the gate helpers evaluate", e.message); }
      if (gate) {
        const chart = {}; const other = {};
        check("gate: a chart that was never armed is not settling — the plain range.from < 5 rule governs it",
          gate.chartReanchorSettling(chart) === false);
        gate.armChartReanchor(chart);
        check("gate: armed, no frame run yet — settling, and still settling 10 s later with no frame (the deferred fit of a hidden tab lands when the tab shows, not when the clock says)",
          gate.chartReanchorSettling(chart) === true && frames.length === 1 && ((clock.now += 10000), gate.chartReanchorSettling(chart) === true));
        frames.shift()();
        check("gate: frame run AND the window spent — open (the first user pan past the window loads as before)",
          gate.chartReanchorSettling(chart) === false);
        gate.armChartReanchor(chart);
        frames.shift()();
        check("gate: re-armed and the frame run, but inside the time window — still settling (a 400 ms slide, were one run, is a stream of range events left of the fit; a slow frame's fit lands here too)",
          gate.chartReanchorSettling(chart) === true && ((clock.now += Number(settleMs[1]) - 1), gate.chartReanchorSettling(chart) === true));
        clock.now += 1;
        check("gate: the window closes exactly at until — open again",
          gate.chartReanchorSettling(chart) === false);
        check("gate: arming one chart leaves another's state alone (per-chart WeakMap, not a module flag)",
          (gate.armChartReanchor(other), gate.chartReanchorSettling(chart) === false && gate.chartReanchorSettling(other) === true));
      }
    }

    // E7 — the re-anchor lands EXACTLY at real time (1793510573). After a pan,
    // showLastCandles used to follow the fit with timeScale().scrollToRealTime().
    // Both re-anchors already leave the right offset at options.rightOffset
    // (setVisibleLogicalRange: `to - baseIndex` = 0; fitContent passes
    // applyDefaultOffset), so the slide added motion and nothing else — and
    // lightweight-charts 5.1.0 never finishes it: scrollToOffsetAnimated reads
    // its start from the PRE-fit offset (the fit is a deferred invalidation,
    // applied in the widget's next frame), and the widget's draw pass applies
    // the animation only while !finished(time) — `finished` and getPosition's
    // `finishAnimation` are the same predicate over the same frame time, so
    // the `offset` branch is unreachable from the draw and the LAST applied
    // position has progress < 1 (at 60 fps, up to ~4% of the slide short of
    // real time; worse at lower frame rates). Seen on the seat venue under a
    // frozen frame clock: a 48-bar pan on the mini chart, then an interval
    // switch, rested at scrollPosition -7.14 (progress 0.958 of the -171
    // pre-fit offset the series replacement carried over) and stayed there
    // through the finished frame; the fit alone reads exactly 0 from the first
    // frame on. The animated scrollToPosition(x, true) is the same code path
    // (a 1000 ms slide). The pin: the fit IS the re-anchor, and nothing
    // follows it.
    const showLast7 = funcBody(src, "function showLastCandles(");
    check("showLastCandles re-anchors with the fit alone — setVisibleLogicalRange for a long series, fitContent for a short one — and no scrollToRealTime() after it (the slide never applies its finished frame, so after a pan the view rested short of real time)",
      showLast7 !== null && /setVisibleLogicalRange\(/.test(showLast7) && /fitContent\(/.test(showLast7) && !/scrollToRealTime\(/.test(showLast7),
      showLast7 === null ? "body not found" : showLast7);
    check("the fit is the LAST statement of showLastCandles — nothing after it moves the view (scrollToRealTime, an animated scrollToPosition, a setRightOffset: each lands somewhere other than the fit's exact real-time offset)",
      showLast7 !== null && /fitContent\(\);\s*\}\s*\}$/.test(showLast7.trim()),
      showLast7 === null ? "body not found" : showLast7);
    check("main.js never calls timeScale().scrollToRealTime() — to move a chart to real time, land it: the fit, or scrollToPosition(timeScale().options().rightOffset, false); lightweight-charts 5.1.0's animated scroll leaves its last frame unapplied",
      !/scrollToRealTime\(/.test(src),
      "scrollToRealTime( found in comment-stripped main.js");
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
    const mktStaged = outcomeFn("placeMarketOrder", { trades: [], remainingQty: 1, totalFilled: 0, avgPrice: 0 });
    check("a fill-nothing market order reports STAGED, not bare OK", /STAGED/i.test(mktStaged), mktStaged);
    const mktFilled = outcomeFn("placeMarketOrder", { trades: [], remainingQty: 0, totalFilled: 2, avgPrice: 65000 });
    check("a filled market order reports fill quantity + avg price",
      /filled 2\b/.test(mktFilled) && mktFilled.includes("65000"), mktFilled);
    const lim = outcomeFn("placeLimitOrder", { order: { id: 42n } });
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

    // G3 — the instant-liquidity disclosure (task 1788465539, which replaced
    // the #50.1 haircut note): every share now redeems at NAV but is paid in
    // kind from what the vault HOLDS, capped by the LP's pro-rata share of
    // it, so the Earn card shows "withdrawable now / total" and how much of
    // the vault is lent out — from getMaxInstantWithdraw, never derived from
    // debt/NAV client-side — BEFORE a deposit (the pre-deposit note, F6) as
    // well as after. The old renderer must be gone, not merely bypassed: a
    // haircut note beside a NAV redemption would be a confident wrong number.
    const body = funcBody(src, "function renderVaultLiquidity(");
    check("renderVaultLiquidity exists", body !== null,
      "the instant-liquidity renderer was removed or renamed");
    check("the pre-NAV haircut renderer (renderVaultHaircut) is gone",
      funcBody(src, "function renderVaultHaircut(") === null,
      "withdrawLp redeems at NAV now — the utilisation haircut note contradicts it");
    if (body) {
      check("the liquidity note reads the cap from getMaxInstantWithdraw's fields",
        /withdrawableNowUsd/.test(body) && /totalNavUsd/.test(body)
          && /lentOutFraction/.test(body) && /withdrawableNowLp/.test(body),
        "withdrawable-now must be the backend's quote, not a client-side estimate");
      check("the liquidity note fills the withdrawable-now and lent-out tiles",
        /earn-vault-now/.test(body) && /earn-vault-lent/.test(body));
      check("the pre-deposit note (F6) is rendered from the vault-level figures",
        /earn-vault-deposit-liquidity/.test(body) && /vaultHoldingsUsd/.test(body)
          && /vaultNavUsd/.test(body),
        "a depositor must see the instantly-withdrawable fraction BEFORE depositing");
      // G3b — the caller's LOCKED shares (task 1788727875; model 1788475756,
      // docs/amm-vault-design.md §5 "Locked shares"): after a max exit the
      // LP's retained shares are locked (cap 0) until margin loans repay,
      // and the card must SAY so — "N of your M LP shares are locked …" in
      // the note, and the locked count in the withdraw placeholder. N and M
      // are the quote's lockedLp / lpBalance, read, never derived (a
      // client-side lock estimate beside the backend's lock state would be
      // a confident wrong number). Behaviour (N/M, zero-lock silence) is
      // exercised over the fake document in section M2.
      check("the liquidity note reads the caller's locked shares from the quote (liq.lockedLp), never derives them",
        /const lockedLp\s*=\s*Number\(liq\.lockedLp/.test(body),
        "lockedLp must be the backend's lock state, not NAV/cap arithmetic");
      check("the locked-share sentence's M is the quote's lpBalance, formatted like the LP tile (formatNum)",
        /const myLp\s*=\s*Number\(liq\.lpBalance/.test(body)
          && /\$\{formatNum\(lockedLp\)\} of your \$\{formatNum\(myLp\)\} LP shares are locked/.test(body),
        "the sentence must print N of M with the card's LP-share formatter");
      check("the locked-share sentence says what the shares carry and what unlocks them (§5 semantics)",
        /locked from your earlier withdrawal\(s\); they carry loan-book value only and unlock as the vault's margin loans repay \(a partial repayment unlocks them pro rata\)/.test(body),
        "wording drifted from the §5 model: loan-book value only, unlock pro rata as loans repay");
      check("the locked-share sentence is gated on lockedLp > 0 (an unlocked LP sees nothing extra)",
        /lockedLp > 0\s*\?\s*` \$\{formatNum\(lockedLp\)\} of your/.test(body),
        "the sentence must be conditional on a non-zero lock");
      check("the withdraw placeholder names the locked count (\"max now X …; Y locked\") from the quote",
        /LP to withdraw \(\$\{maxNow\}; \$\{formatNum\(lockedLp\)\} locked\)/.test(body),
        "the placeholder must carry both the instant cap and the locked count");
      // G3c — "max now" UNDER-ASKS (task 1788746837, operator policy (a),
      // 2026-11-01). The quote is exact at its instant and the settlement
      // check is the same exact inequality, but the request is staged and
      // the loan book accrues (and marks move) before it settles, so a
      // request for EXACTLY withdrawableNowLp is refused whenever a tick
      // lands in between. The backend stays exact; the card fills the quote
      // × (1 − LP_WITHDRAW_DRIFT_ALLOWANCE) floored to the LP base unit and
      // names the allowance beside the figure. Pinned here: ONE constant at
      // 1e-4; one fill helper every quote→field path goes through; the
      // placeholder's figure is the helper's, never formatNum(nowLp); the text
      // derives its percent from the constant. Behaviour (exact floor, never
      // over the quote, base-unit grid) is exercised by lifting the REAL
      // helper over money.js's toE8/fromE8, with a negative control: the same
      // helper with the allowance at 0 fills the exact quote.
      const allowanceDefs = [...src.matchAll(/const LP_WITHDRAW_DRIFT_ALLOWANCE\s*=\s*([0-9.e+-]+)\s*;/g)];
      const ALLOWANCE = allowanceDefs.length === 1 ? Number(allowanceDefs[0][1]) : NaN;
      check("ONE named drift-allowance constant: LP_WITHDRAW_DRIFT_ALLOWANCE = 1e-4 (0.01 %)",
        allowanceDefs.length === 1 && ALLOWANCE === 1e-4,
        allowanceDefs.length === 1 ? `value ${allowanceDefs[0][1]}` : `${allowanceDefs.length} definitions`);
      const fillBody = funcBody(src, "function lpWithdrawMaxFill(");
      check("lpWithdrawMaxFill exists (the one fill helper)", fillBody !== null,
        "helper missing or renamed — the placeholder fills the raw quote again");
      if (fillBody) {
        check("lpWithdrawMaxFill applies the constant in LP base units (toE8 → bigint ratio → fromE8), no float × 0.9999",
          /LP_WITHDRAW_DRIFT_ALLOWANCE/.test(fillBody) && /toE8\(/.test(fillBody) && /fromE8\(/.test(fillBody) && !/0\.9999/.test(fillBody),
          "the floor to the LP unit must be exact integer arithmetic on the e8 figure");
      }
      check("the placeholder's figure is the under-asked fill (fillLp = lpWithdrawMaxFill(nowLp)) — the exact quote fills nothing",
        /const fillLp\s*=\s*lpWithdrawMaxFill\(nowLp\)/.test(body) && /max now \$\{formatNum\(fillLp\)\}/.test(body) && !/max now \$\{formatNum\(nowLp\)\}/.test(body),
        "a `max now ${formatNum(nowLp)}` is the pre-policy fill of the exact quote");
      check("the placeholder names the allowance in user terms, the percent DERIVED from the constant (\"after a 0.01% drift allowance\")",
        /const pct\s*=\s*\(LP_WITHDRAW_DRIFT_ALLOWANCE \* 100\)\.toFixed\(2\)/.test(body) && /after a \$\{pct\}% drift allowance/.test(body),
        "the text and the arithmetic must read one constant");
      check("the liquidity note explains the allowance (why the box is a hair under the tile) and the field's title repeats it",
        /drift allowance: the maximum moves by a hair/.test(body) && /wIn\.title\s*=\s*fillLp > 0/.test(body),
        "the user must be told why the suggested figure is under the quote");
      check("no Earn-card statement writes the quote (withdrawableNowLp / nowLp) into the withdraw field's value outside lpWithdrawMaxFill",
        readSiteStatements(src, "earn-vault-withdraw-input").filter((t) => /\.value\s*=/.test(t) && /nowLp|withdrawableNowLp/.test(t) && !/lpWithdrawMaxFill\(/.test(t)).length === 0,
        "a second fill path would reintroduce the exact-quote race");
      if (fillBody && money && ALLOWANCE === 1e-4) {
        let fill = null, fillExact = null;
        try {
          const lift = (a) => new Function("LP_WITHDRAW_DRIFT_ALLOWANCE", "toE8", "fromE8",
            "return function lpWithdrawMaxFill(nowLp) " + fillBody)(a, money.toE8, money.fromE8);
          fill = lift(ALLOWANCE); fillExact = lift(0);
        } catch (e) { bad("lpWithdrawMaxFill is liftable over money.js", e.message); }
        if (fill) {
          // The reference, independent of the helper's ratio: floor(units × (1 − 1e-4))
          // = units − ceil(units / 10_000), in BigInt.
          const expectUnits = (q) => { const u = money.toE8(q); return u - (u + 9999n) / 10000n; };
          const cases = [990, 1500, 84991.49915231, 100000, 0.00000001, 0.00000002, 0.0001, 0.33333333, 123456.78912345, 1e6, 99999.99999999, 7];
          const wrong = cases.filter((q) => money.toE8(fill(q)) !== expectUnits(q));
          check("fill == quote × (1 − 1e-4) floored to the LP base unit, exactly, across the cases",
            wrong.length === 0, wrong.map((q) => `${q} → ${fill(q)} (expected ${money.fromE8(expectUnits(q))})`).join("; "));
          check("fill never exceeds the quote — strictly under for every positive quote",
            cases.every((q) => money.toE8(fill(q)) < money.toE8(q)), cases.map((q) => `${q}→${fill(q)}`).join(" "));
          check("fill sits on the LP base-unit grid (toE8 round-trips it exactly)",
            cases.every((q) => money.fromE8(money.toE8(fill(q))) === fill(q)));
          check("100,000 LP quoted → 99,990 fills (the allowance is 10 LP on a 100k position)", fill(100000) === 99990, `got ${fill(100000)}`);
          check("no quote (0, negative, NaN, undefined) → fill 0, never NaN",
            fill(0) === 0 && fill(-1) === 0 && fill(NaN) === 0 && fill(undefined) === 0);
          check("negative control: the same helper with the allowance at 0 fills the exact quote — the under-ask pins above distinguish policy from no policy",
            fillExact !== null && fillExact(990) === 990 && money.toE8(fillExact(990)) === money.toE8(990), fillExact && `got ${fillExact(990)}`);
        }
      }
      // G3d — the one-tap "Max" (task 1793553361). Before it the PLACEHOLDER
      // was the whole Max control: the user read "max now 84,991.49 …" and
      // retyped it, commas and all, into a number input that rejects them.
      // Now a button beside the field fills it: ONE handler
      // (onVaultWithdrawMax) whose one write is String(lpWithdrawMaxFill(nowLp))
      // — the helper applied AT THE TAP to the latest quote, which
      // renderVaultLiquidity stashes on the field (data-max-now-lp) through
      // applyWithdrawMax, the one writer of the button's disabled/title — as
      // a plain String(), never formatNum (commas). Disabled while the fill is
      // 0 and while the submit is paused (the same `paused` the latch reads;
      // the submit's own `disabled` stays applyWithdrawPause's). Wired beside
      // the submit in renderEarnCard's once-only block; the markup is a real
      // <button type="button"> (keyboard-reachable, labelled, disabled until
      // the first quote). The handler's write names no element id, so G3c's
      // id-scoped "no fill outside the helper" pin above cannot see it — the
      // write pin below is scoped to the handler's body instead. Behaviour
      // (990 → "989.901", cap 0 → disabled, the pause, no quote, the logout
      // drop) and the negative control (a copy whose handler writes nowLp
      // fills "990") run over the fake document in section M2d.
      const maxBody = funcBody(src, "function onVaultWithdrawMax(");
      check("onVaultWithdrawMax exists (the one Max handler)", maxBody !== null,
        "handler missing or renamed — the placeholder is the whole Max control again");
      if (maxBody) {
        const writes = maxBody.split(";").map((t) => t.replace(/\s+/g, " ").trim()).filter((t) => /\.value\s*=/.test(t));
        check("onVaultWithdrawMax writes the field's value ONCE, as String(lpWithdrawMaxFill(nowLp)) — the helper at the tap, a plain number, no formatNum",
          writes.length === 1 && /\.value\s*=\s*String\(lpWithdrawMaxFill\(nowLp\)\)/.test(writes[0]) && !/formatNum/.test(writes[0]),
          writes.join("\n") || "no .value write");
        check("onVaultWithdrawMax reads the quote from the field's stash (dataset.maxNowLp) — no query, no NAV/cap arithmetic",
          /const nowLp\s*=\s*Number\(wIn\.dataset\.maxNowLp/.test(maxBody)
            && !/getMaxInstantWithdraw|totalNavUsd|vaultNavUsd|withdrawableNowUsd|appState/.test(maxBody),
          "the fill must be the stashed quote through the helper, never re-derived or re-fetched");
        check("onVaultWithdrawMax fills nothing at a zero fill (the belt under the disabled button)",
          /if \(!\(lpWithdrawMaxFill\(nowLp\) > 0\)\) return/.test(maxBody));
      }
      const maxState = funcBody(src, "function applyWithdrawMax(");
      check("applyWithdrawMax exists (the one writer of the Max button's disabled/title and of the field's quote stash)",
        maxState !== null, "helper missing or renamed");
      if (maxState) {
        check("applyWithdrawMax stashes the QUOTE (String(nowLp)) on the field while the fill is positive and deletes it otherwise",
          /wIn\.dataset\.maxNowLp\s*=\s*String\(nowLp\)/.test(maxState) && /delete wIn\.dataset\.maxNowLp/.test(maxState),
          "the stash must be the exact quote (the helper runs at the tap), dropped when there is nothing to fill");
        check("applyWithdrawMax disables the button at a zero fill OR a paused submit, and never names the submit",
          /mBtn\.disabled\s*=\s*!\(fill > 0\) \|\| !!paused/.test(maxState) && !/earn-vault-withdraw-btn|wBtn/.test(maxState),
          "the two buttons must agree on the pause without a second writer of the submit's disabled");
        check("applyWithdrawMax's title carries the pause text when paused, else the fill it would write",
          /mBtn\.title\s*=\s*paused \? paused/.test(maxState) && /formatNum\(fill\)/.test(maxState));
      }
      check("renderVaultLiquidity feeds applyWithdrawMax the quote and the SAME `paused` the latch reads",
        /applyWithdrawPause\(wBtn,\s*paused\)/.test(body) && /applyWithdrawMax\(wIn,\s*mBtn,\s*nowLp,\s*paused\)/.test(body),
        "the Max button must follow the submit's pause from the same field");
      check("renderVaultLiquidity on NO quote keeps the last stash fillable with the pause dropped (the submit's never-stuck rule) — disabled only while no quote ever landed",
        /applyWithdrawMax\(wIn,\s*mBtn,\s*Number\(wIn\?\.dataset\.maxNowLp \|\| 0\),\s*null\)/.test(body),
        "a lost query must neither strand the button disabled nor invent a fill");
      const maxDisabledWrites = src.split(";").map((t) => t.replace(/\s+/g, " ").trim())
        .filter((t) => /(^|[^A-Za-z0-9_$])mBtn\.disabled\s*=/.test(t) || /earn-vault-withdraw-max"\)(\?\.)?\.disabled\s*=/.test(t));
      check("the Max button's `disabled` is written in exactly one statement — applyWithdrawMax's",
        maxDisabledWrites.length === 1 && maxState !== null && maxState.replace(/\s+/g, " ").includes(maxDisabledWrites[0]),
        maxDisabledWrites.map((t) => t.slice(0, 120)).join("\n") || "no write found");
      // The money fields arrive pre-normalised; exitFeeBps is NOT in
      // MONEY_KEYS. A stray e8 downscale here would print $0.00 forever.
      check("the liquidity note does not e8-downscale the pre-normalised fields",
        !DOWNSCALES_E8.test(body));
      // lentOutFraction crosses the boundary as a 0..1 fraction (G1's rule
      // for sharePercent): the render owns the ×100.
      const lentStmts = readSiteStatements(src, "lentOutFraction");
      check("lentOutFraction is rendered as a percent (×100) [structure pin]",
        lentStmts.length > 0 && lentStmts.some((t) => /\*\s*100\b/.test(t)),
        lentStmts.map((t) => t.slice(0, 120)).join("\n"));
    }
    const earnBody = funcBody(src, "async function renderEarnCard(") || "";
    check("renderEarnCard queries getMaxInstantWithdraw and invokes the liquidity disclosure",
      /getMaxInstantWithdraw/.test(earnBody) && /renderVaultLiquidity\s*\(/.test(earnBody),
      "the disclosure renderer is defined but never fed from the Earn card");
    // G3d — the Max button is wired beside the submit INSIDE the once-only
    // block (task 1793553361): a listener added on every render would fill
    // on every tap as many times as the card has rendered.
    const wiredBlock = (earnBody.match(/if \(!card\.dataset\.wired\) \{[\s\S]*?\n\s*\}/) || [""])[0];
    check("renderEarnCard wires #earn-vault-withdraw-max → onVaultWithdrawMax in its once-only (card.dataset.wired) block, right after the withdraw submit's listener",
      /document\.getElementById\("earn-vault-withdraw-btn"\)\?\.addEventListener\("click",\s*onVaultWithdraw\);\s*document\.getElementById\("earn-vault-withdraw-max"\)\?\.addEventListener\("click",\s*onVaultWithdrawMax\)/.test(wiredBlock),
      wiredBlock.slice(0, 400) || "no wired block");
    const html = must("src/frontend/index.html");
    check("index.html carries the withdrawable-now tile, the lent-out tile and the pre-deposit note",
      html !== null && /id="earn-vault-now"/.test(html) && /id="earn-vault-lent"/.test(html)
        && /id="earn-vault-deposit-liquidity"/.test(html),
      "the render targets are missing — the note would render into nothing");
    check("index.html no longer carries the haircut note target",
      html !== null && !/earn-vault-haircut/.test(html));
    // G3d — the markup (task 1793553361): a real <button> (keyboard-reachable,
    // labelled "Max"; type="button", so it can never submit anything) between
    // the field and its submit in the same row, disabled until the first quote.
    if (html) {
      const inAt = html.indexOf('id="earn-vault-withdraw-input"');
      const mxAt = html.indexOf('id="earn-vault-withdraw-max"');
      const btAt = html.indexOf('id="earn-vault-withdraw-btn"');
      check("index.html: #earn-vault-withdraw-max is a <button type=\"button\"> labelled Max — .btn .btn-sm, a title, disabled until the first quote",
        /<button type="button" id="earn-vault-withdraw-max" class="btn [^"]*\bbtn-sm\b[^"]*" title="[^"]+" disabled>Max<\/button>/.test(html),
        (html.match(/<button[^>]*earn-vault-withdraw-max[^>]*>[^<]*<\/button>/) || ["no Max button"])[0]);
      check("index.html: the Max button sits between the withdraw field and its submit (field < Max < Withdraw, one row)",
        inAt >= 0 && mxAt > inAt && btAt > mxAt && !/<\/div>/.test(html.slice(inAt, btAt)), `input@${inAt} max@${mxAt} btn@${btAt}`);
      check("index.html: exactly one Max button", (html.match(/id="earn-vault-withdraw-max"/g) || []).length === 1);
    }
  }
  // G3b (behavioural) — the quote's money fields normalise like every other
  // USD field; lentOutFraction like sharePercent.
  if (money) {
    const { MONEY_KEYS, normMoney } = money;
    for (const k of ["withdrawableNowUsd", "withdrawableNowLp", "totalNavUsd",
                     "lentOutFraction", "vaultHoldingsUsd", "vaultLentOutUsd", "vaultNavUsd"]) {
      check(`${k} is in MONEY_KEYS`, MONEY_KEYS.has(k), "normMoney would hand the render a raw e8 bigint");
    }
    check("exitFeeBps is NOT in MONEY_KEYS (it is bps, not e8)", !MONEY_KEYS.has("exitFeeBps"));
    const q = normMoney({ withdrawableNowUsd: 12_345_000_000n, lentOutFraction: 25_000_000n, exitFeeBps: 40n });
    check("withdrawableNowUsd 123.45 normalises to 123.45", q.withdrawableNowUsd === 123.45, `got ${q.withdrawableNowUsd}`);
    check("lentOutFraction 25% normalises to the fraction 0.25", q.lentOutFraction === 0.25, `got ${q.lentOutFraction}`);
  }

  // G4 — the LP docs carry the matching redemption model: shares redeem at
  // full vault value, paid in kind, instantly up to the LP's share of what
  // the vault holds ("withdrawable now"), the rest as loans repay.
  const docs = must("src/frontend/src/docs.js");
  check("docs.js Earn section states the NAV redemption + instant-liquidity model",
    docs !== null && /redeem at full vault value/.test(docs)
      && /paid in kind/.test(docs) && /withdrawable now/.test(docs)
      && /as the loans repay/.test(docs),
    "the Earn docs redemption bullet is gone or reverted to the upper-bound model");
  check("docs.js Earn section no longer calls the displayed value an upper bound",
    docs !== null && !/upper bound while the vault is lending/.test(docs),
    "withdrawLp redeems at NAV — the upper-bound sentence is now false");

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

// ════════════════════════════════════════════════════════════════════
console.log("\nI. swap preview — the reserve clamp beside the estimate (#55 preview half)");
{
  // quoteSwap's walk is a FULL-amount market estimate (a logged-out or
  // unfunded preview stays a real quote), but swap() stages min(amount,
  // available): funds reserved by open orders never convert. Task 1788478363
  // added availableFrom + clampedByReserve to the reply so the preview says
  // "only $399.40 of this $1,000 is available" while the user types — before
  // the staging toast. Each hand-copy of the contract is held to the backend.
  const rawMain = must("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);
  const did = must("candid/backend.did");
  const html = must("src/frontend/index.html");
  const rawBackend = must("src/backend/main.mo");

  // I1 — the backend's reply record carries both fields (the source of truth).
  if (rawBackend) {
    const at = rawBackend.indexOf("public query (msg) func quoteSwap(");
    const blk = at < 0 ? "" : rawBackend.slice(at, at + 4000);
    check("quoteSwap's reply type declares availableFrom : Nat and clampedByReserve : Bool",
      /availableFrom\s*:\s*Nat/.test(blk) && /clampedByReserve\s*:\s*Bool/.test(blk),
      "the reply record lost the #55 preview fields");
    check("clampedByReserve is true only when a RESERVATION shortens the amount (unfunded callers are not 'clamped')",
      /clampedByReserve\s*=\s*getReserved\(msg\.caller,\s*fromToken\)\s*>\s*0\s*and\s*availableFrom\s*<\s*amount/.test(blk),
      "the doctrine: a caller with nothing reserved keeps an unclamped market estimate");
  }

  // I2 — the published contract: candid/backend.did carries the fields on
  // quoteSwap's ok record (additive; bots decode yesterday's shape otherwise).
  if (did) {
    const at = did.indexOf("quoteSwap:");
    const blk = at < 0 ? "" : did.slice(at, at + 600);
    check("candid/backend.did publishes availableFrom: nat + clampedByReserve: bool on quoteSwap",
      /availableFrom\s*:\s*nat/.test(blk) && /clampedByReserve\s*:\s*bool/.test(blk),
      "gen-did.sh was not re-run after the backend change");
  }

  if (src) {
    // I3 — the IDL half: the frontend's hand-written quoteSwap record decodes
    // both fields (a Record missing them silently drops them; declaring them
    // against an older backend throws — so the IDL and the backend move together).
    const idlAt = src.indexOf("quoteSwap: IDL.Func(");
    const idl = idlAt < 0 ? "" : src.slice(idlAt, idlAt + 500);
    check("the frontend IDL's quoteSwap ok record decodes availableFrom: IDL.Nat and clampedByReserve: IDL.Bool",
      /availableFrom\s*:\s*IDL\.Nat/.test(idl) && /clampedByReserve\s*:\s*IDL\.Bool/.test(idl),
      "IDL record drifted from candid/backend.did");

    // I4 — the render: updateSwapPreview reads q.availableFrom as raw e8
    // (÷1e8, a name kept out of MONEY_KEYS — the outAmount lesson), gates the
    // line on q.clampedByReserve, and names BOTH the available and the
    // reserved figure so the user knows what will convert and why.
    const body = funcBody(src, "async function updateSwapPreview(");
    check("updateSwapPreview body is extractable", body !== null, "function header moved?");
    if (body) {
      check("the preview divides q.availableFrom by 1e8 exactly once (raw e8 in, display units out)",
        /Number\(q\.availableFrom[^)]*\)\s*\/\s*1e8/.test(body),
        "availableFrom is raw e8 — the preview must normalise it itself");
      check("the clamp line is gated on q.clampedByReserve (an unfunded/anonymous preview shows no clamp)",
        /q\.clampedByReserve/.test(body) && /swap-preview-avail/.test(body),
        "the line must render only when a reservation clamps the amount");
      check("the clamp line says how much is AVAILABLE and how much is RESERVED by open orders",
        /Only \$\{formatNum\(availableFrom\)\} of \$\{formatNum\(fromAmount\)\}/.test(body)
          && /is reserved by your open orders/.test(body),
        "the toast-era wording — the preview must name both figures");
      check("lastSwapEstimate carries availableFrom + clampedByReserve (the tap-to-fill handler reads them)",
        /lastSwapEstimate\s*=\s*\{[^}]*availableFrom[^}]*clampedByReserve[^}]*\}/.test(body),
        "the click handler fills From with availableFrom from lastSwapEstimate");
    }
    check("the clamp line's tap-to-fill copies availableFrom into the From field",
      /swap-preview-avail[\s\S]{0,600}lastSwapEstimate\.availableFrom[\s\S]{0,300}swap-from-amount/.test(src),
      "the click handler must fill From with the spendable amount, like the partial-fill rate warning");
  }

  // I5 — the markup: the element the render writes into exists, hidden by default.
  check("index.html carries #swap-preview-avail (hidden until a reservation clamps the amount)",
    html !== null && /id="swap-preview-avail"[^>]*style="display:none"/.test(html),
    "the render writes into an element the page must ship");
}

// ── #54.8: liquidation-distance surfaces take their direction from the ──
// canister's own algebra, and "already past" from the health verdict.
// MarginPools.liqPrice returns {price, dir} with dir read off the SAME A the
// price derives from (a net-long pool with heldLtv < M·debtBase liquidates on
// a RISING mark); the Positions row and the Markets bar used to take the
// sign from the side (net size) — "Long Liq −0.0%" on a healthy pool,
// "−9.9%" on a liquidatable one. Both surfaces now print the word
// "liquidatable" on the pool's isLiquidatable and sign the distance by the
// canister's direction. Structure pins: main.js only runs in a browser.
{
  console.log("\n── #54.8 liquidation direction + 'liquidatable' surfaces ──");
  const raw = must("src/frontend/src/main.js");
  const src = raw === null ? "" : stripJsComments(raw);
  const rows = funcBody(src, "function positionsTableHTML(");
  check("positionsTableHTML exists", rows !== null, "the positions row renderer was renamed or removed");
  if (rows) {
    check("the Positions row prints 'liquidatable' from the pool's isLiquidatable verdict",
      /p\.isLiquidatable/.test(rows) && /liquidatable<\/span>/.test(rows),
      "the row must read PositionView.isLiquidatable and print the word, not a distance");
    check("the row's distance sign comes from liqDir (the health slope), not from the side pill",
      /p\.liqDir/.test(rows) && /"up" in liqDirOpt\[0\]/.test(rows),
      "sign must be read off the canister's direction — a net-long pool can liquidate on a rising mark");
    check("a liq price of exactly 0 is no longer mapped to the 'no practical liquidation' glyph",
      /liq === 0/.test(rows) && !/liq > 0 && mark > 0/.test(rows),
      "?0 is liqPrice's 'liquidatable at every price' answer, not a dust artefact");
  }
  const tele = funcBody(src, "async function refreshMarketTele(");
  check("refreshMarketTele exists", tele !== null, "the Markets bar refresher was renamed or removed");
  if (tele) {
    check("the Markets bar prints 'liquidatable' from the side's liquidatable flag",
      /tele\.longLiquidatable/.test(tele) && /tele\.shortLiquidatable/.test(tele) && /return "liquidatable"/.test(tele),
      "Long/Short Liq must print the word on getMarketTele.{long,short}Liquidatable");
    check("the Markets bar signs the distance by the canister's liq direction",
      /tele\.longNearLiqDir/.test(tele) && /tele\.shortNearLiqDir/.test(tele) && !/liq\(tele\.longNearLiqBps, "-"\)/.test(tele),
      "the fixed per-side sign is the #54.8 defect");
  }
  const idl = src;
  check("the PositionView IDL carries liqDir + isLiquidatable",
    /liqDir:\s*IDL\.Opt\(IDL\.Variant\(\{\s*down:\s*IDL\.Null,\s*up:\s*IDL\.Null\s*\}\)\),\s*isLiquidatable:\s*IDL\.Bool/.test(idl),
    "the hand-written IDL must decode the additive fields");
  const did = must("candid/backend.did");
  if (did) {
    const pv = did.match(/type PositionView\s*=\s*record \{[\s\S]*?\};/);
    check("candid/backend.did publishes PositionView.isLiquidatable + liqDir (additive)",
      pv !== null && /isLiquidatable: bool/.test(pv[0]) && /liqDir: opt/.test(pv[0]),
      pv ? pv[0] : "no PositionView record in the did");
    const mt = did.match(/type MarketTele\s*=\s*record \{[\s\S]*?\};/);
    check("candid/backend.did publishes MarketTele.{long,short}Liquidatable + NearLiqDir (additive)",
      mt !== null && /longLiquidatable: bool/.test(mt[0]) && /shortLiquidatable: bool/.test(mt[0])
        && /longNearLiqDir: opt/.test(mt[0]) && /shortNearLiqDir: opt/.test(mt[0]),
      mt ? mt[0] : "no MarketTele record in the did");
  }
}

// ── J. the archive spawn slot (getCanisterInfo.pendingSpawn) is LISTED ──
// Task 1788465033 (#55 "orphan slot overwritten") made the backend publish
// the W4-16 spawn slot — a canister main CREATED whose install never
// completed or whose continuation was lost. Non-null for more than a few
// seconds is an ops signal (every spawn is refused until the reconciler
// reaps it at 5 min), and the complaint was that the orphan was "listed
// nowhere". Task 1788485540: the frontend's hand-written IDL decodes the
// field and the History Archive card renders it beside the archive id —
// principal + age, amber past 60 s, red past 5 min with "reconciler
// overdue". Structure pins over the source (main.js only runs in a browser)
// plus one BEHAVIOURAL pin: the threshold classifier is small and pure, so
// it is extracted and exercised.
console.log("\nJ. archive spawn slot — getCanisterInfo.pendingSpawn is decoded and rendered");
{
  const rawMain = must("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);
  const did = must("candid/backend.did");
  const html = must("src/frontend/index.html");
  const demo = must("src/frontend/src/demo-mode.js");
  const css = must("src/frontend/src/styles/stats.css");

  // J1 — the published contract: getCanisterInfo carries the slot.
  if (did) {
    const at = did.indexOf("getCanisterInfo:");
    const blk = at < 0 ? "" : did.slice(at, did.indexOf("query;", at) + 6);
    check("candid/backend.did publishes pendingSpawn: opt record { atNs: int; cid: text } on getCanisterInfo",
      /pendingSpawn\s*:\s*opt\s+record\s*\{\s*atNs\s*:\s*int\s*;\s*cid\s*:\s*text\s*;\s*\}/.test(blk),
      "the backend's spawn slot left getCanisterInfo (or gen-did.sh was not re-run)");
  }

  if (src) {
    // J2 — the IDL half: an Opt record so a pre-slot backend decodes as null
    // instead of failing the whole record (the appVersion lesson).
    const idlAt = src.indexOf("getCanisterInfo: IDL.Func(");
    const idlEnd = idlAt < 0 ? -1 : src.indexOf('["query"])', idlAt);
    const idl = idlAt < 0 ? "" : src.slice(idlAt, idlEnd);
    check("the frontend IDL's getCanisterInfo record decodes pendingSpawn as IDL.Opt(IDL.Record({ cid: IDL.Text, atNs: IDL.Int }))",
      /pendingSpawn\s*:\s*IDL\.Opt\(IDL\.Record\(\{\s*(cid\s*:\s*IDL\.Text\s*,\s*atNs\s*:\s*IDL\.Int|atNs\s*:\s*IDL\.Int\s*,\s*cid\s*:\s*IDL\.Text)\s*,?\s*\}\)\)/.test(idl),
      "IDL record drifted from candid/backend.did (a missing field is silently dropped; a wrong type throws at decode)");

    // J3 — the render: renderSpawnSlot reads the slot, writes principal +
    // age into the card, and takes the age from the CANISTER's clock
    // (nowNs − atNs, like the fuelPendingNotify latch) so a skewed browser
    // clock cannot fake an overdue slot.
    const body = funcBody(src, "function renderSpawnSlot(");
    check("renderSpawnSlot body is extractable", body !== null, "function header moved?");
    if (body) {
      check("renderSpawnSlot hides the row when the slot is empty and shows it when a spawn is pending",
        /spawnSlotOf\(info\)/.test(body) && /archive-spawn-slot/.test(body) && /style\.display\s*=\s*"none"/.test(body),
        "the row must exist hidden and flip on the slot, not render permanently");
      check("renderSpawnSlot prints the pending canister's principal into #archive-spawn-id",
        /archive-spawn-id/.test(body) && /textContent\s*=\s*ps\.cid/.test(body),
        "the orphan must be listed by principal — the #55 complaint");
      check("the slot age is (nowNs − atNs) / 1e9 from the canister's own clock",
        /\(Number\(info\.nowNs\)\s*-\s*Number\(ps\.atNs\)\)\s*\/\s*1e9/.test(body),
        "age must come from the canister clock pair, not Date.now()");
      check("the age line writes into #archive-spawn-age and carries the health class",
        /archive-spawn-age/.test(body) && /className\s*=\s*"spawn-slot-age "\s*\+\s*cls/.test(body),
        "colour rides the health-* class on the age element");
      check("the red state names the reconciler as overdue (and the 5-minute reap)",
        /health-bad/.test(body) && /reconciler overdue/.test(body),
        "past 5 min the reconciler itself is late — say so");
    }

    // J4 — BEHAVIOURAL: the classifier and its thresholds. The two consts
    // and the pure function are lifted out of the source and run.
    const warn = src.match(/const SPAWN_SLOT_WARN_SEC\s*=\s*(\d+)/);
    const over = src.match(/const SPAWN_SLOT_OVERDUE_SEC\s*=\s*(\d+)/);
    check("thresholds are named constants: SPAWN_SLOT_WARN_SEC = 60, SPAWN_SLOT_OVERDUE_SEC = 300",
      warn !== null && over !== null && warn[1] === "60" && over[1] === "300",
      `warn=${warn && warn[1]} overdue=${over && over[1]} — the backend's reconciler reaps at 5 min`);
    const clsBody = funcBody(src, "function spawnSlotClass(");
    check("spawnSlotClass body is extractable", clsBody !== null, "function header moved?");
    if (clsBody && warn && over) {
      let fn = null;
      try {
        fn = new Function("SPAWN_SLOT_WARN_SEC", "SPAWN_SLOT_OVERDUE_SEC",
          "return function spawnSlotClass(ageS) " + clsBody)(Number(warn[1]), Number(over[1]));
      } catch (e) { bad("spawnSlotClass is a pure function of the age (extractable and runnable)", e.message); }
      if (fn) {
        const table = [[0, "health-ok"], [59, "health-ok"], [60, "health-warn"], [299, "health-warn"], [300, "health-bad"], [3600, "health-bad"]];
        const got = table.map(([s]) => fn(s));
        check("spawnSlotClass: 0s/59s → ok, 60s/299s → amber (health-warn), 300s+ → red (health-bad)",
          table.every(([, want], i) => got[i] === want),
          `got ${JSON.stringify(got)} for ages ${JSON.stringify(table.map(([s]) => s))}`);
      }
    }

    // J5 — wiring: the health poll renders the slot every tick, and the
    // History Archive section is not hidden while a spawn is pending even
    // before the first archive exists (the first-ever spawn is the one an
    // operator most wants to see).
    const poll = funcBody(src, "async function refreshCanisterInfo(");
    check("refreshCanisterInfo renders the spawn slot on every successful poll",
      poll !== null && /renderSpawnSlot\(info\)/.test(poll),
      "the slot must refresh with the rest of the canister info");
    const arch = funcBody(src, "async function renderArchiveStats(");
    check("renderArchiveStats keeps the section visible while a spawn is pending with no archive yet",
      arch !== null && /spawnSlotOf\(info\)/.test(arch) && /!archiveId\s*&&\s*!/.test(arch),
      "hiding the whole section on !archiveId would hide the first-ever orphan");
  }

  // J6 — the markup: the row lives in the Archive Canister ID card, hidden
  // by default, between the archive id and the chain table.
  if (html) {
    const idAt = html.indexOf('id="archive-id-value"');
    const slotAt = html.indexOf('id="archive-spawn-slot"');
    const chainAt = html.indexOf("archive-chain-head");
    check("index.html carries #archive-spawn-slot (hidden until a spawn is pending) beside the archive id",
      slotAt > 0 && /id="archive-spawn-slot"[^>]*style="display:none"/.test(html) && idAt > 0 && idAt < slotAt && (chainAt < 0 || slotAt < chainAt),
      "the render writes into a row the page must ship, in the Archive Canister ID card");
    check("index.html carries #archive-spawn-id and #archive-spawn-age",
      /id="archive-spawn-id"/.test(html) && /id="archive-spawn-age"/.test(html),
      "principal + age elements");
  }

  // J7 — the demo stub stays in step: a shape the render can read without
  // throwing (an empty Opt, i.e. no spawn pending).
  if (demo) {
    const at = demo.indexOf("getCanisterInfo: async () => ({");
    const blk = at < 0 ? "" : demo.slice(at, demo.indexOf("})", at));
    check("demo-mode.js's getCanisterInfo stub carries pendingSpawn: [] beside archiveCanisterId",
      /archiveCanisterId\s*:/.test(blk) && /pendingSpawn\s*:\s*\[\]/.test(blk),
      "the demo actor must decode-shape the new field like the real one");
  }

  // J8 — the colours: health-warn/health-bad are defined only on .kpi-value
  // and the margin selectors, so the age element needs its own rule.
  if (css) {
    check("stats.css colours .spawn-slot-age.health-warn amber (var(--cta-ink) — Uplands Amber as TEXT: the fill amber in dark, deepened on white in light) and .health-bad red",
      /\.spawn-slot-age\.health-warn\s*\{[^}]*var\(--cta-ink\)/.test(css) && /\.spawn-slot-age\.health-bad\s*\{[^}]*var\(--red\)/.test(css),
      "without a rule the class is inert and the flip is invisible; --accent is cyan, not the amber the slot promises (and the fill token --cta is 1.9:1 on white — amber text is --cta-ink, task 1793489931)");
  }
}

// ════════════════════════════════════════════════════════════════════
// K. the hand-written backend IDL names every field candid/backend.did
//    publishes — @dfinity/candid DROPS wire fields the IDL record does not
//    list, silently (task 3088499384)
// ════════════════════════════════════════════════════════════════════
//
// main.js hand-writes its Candid IDL (getIdlFactory — and, since task
// 1788510196, the archive and bridge factories are held to candid/archive.did
// and candid/bridge.did the same way, plus an intra-file twin pin, K5 below).
// The decoder keeps only
// the fields the IDL record names: a backend field the frontend READS but
// never LISTED decodes as `undefined` with no error, so the render falls
// through to its fallback with a straight face. PriceFeedStats did exactly
// that from Phase 6 to task 1788471187 — suspendedCount, panicCancels,
// jumpThresholdBps and maxRefPriceAgeSec were served and dropped, so the
// AMM-SIDELINED threshold was always the 300 s fallback and the suspended
// count always 0. Sections H/I/J pin single fields after the fact; this
// section pins the RULE: for every IDL container with a same-named
// `type X = ...` in candid/backend.did, and for every service method whose
// return both sides shape inline, the IDL's field set is a SUPERSET of the
// published one (additive backend fields then fail here until the IDL lists
// them). Variants get the same rule — a tag missing from the IDL variant
// throws at decode the first time the backend emits it. The reverse
// direction is pinned too, aggregated: an IDL RECORD field the .did lacks
// must be IDL.Opt (decodes as null against an older backend — the appVersion
// / pendingSpawn pattern); a required one fails the whole decode.
//
// The two parsers are deliberately small — brace-matched containers with
// depth-0 splitting, string literals skipped (the `"null"` keys) — and they
// handle: multi-line bodies, trailing commas, quoted names, `opt`/`vec` and
// `IDL.Opt`/`IDL.Vec` wrappers (stripped, any depth), named types resolved
// on BOTH sides (a .did `MarginAccount` against an inline
// `IDL.Record({ openedAt })` still compares), and inline nested
// record/variant descent to a fixed depth. They do NOT handle: positional
// (tuple) records — `record { text; nat }` / `IDL.Tuple` — which are skipped
// as "not a named container"; `func`/`service` types; type comparison
// (a wrong TYPE throws loudly at decode, which is not the silent class this
// section exists for); and methods only one side declares (the .did
// publishes ~250, the frontend calls a subset — a method the IDL omits is
// simply not callable, not silently wrong).

// Text inside the delimiter pair opening at src[open] (`{`, `(` or `[`), and
// the index just past its closer. String literals are skipped.
function matchedBody(src, open) {
  const closeOf = { "{": "}", "(": ")", "[": "]" };
  if (!(src[open] in closeOf)) return null;
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    const c = src[i];
    if (c === '"' || c === "'") {
      const q = c; i++;
      while (i < src.length && src[i] !== q) { if (src[i] === "\\") i++; i++; }
      continue;
    }
    if (c === "{" || c === "(" || c === "[") depth++;
    else if (c === "}" || c === ")" || c === "]") {
      depth--;
      if (depth === 0) return { body: src.slice(open + 1, i), end: i + 1 };
    }
  }
  return null;
}
// A container body split into its depth-0 segments on `sep`; empty segments
// (a trailing comma/semicolon) are dropped.
function topLevelSplit(body, sep) {
  const out = [];
  let depth = 0, cur = "";
  for (let i = 0; i < body.length; i++) {
    const c = body[i];
    if (c === '"' || c === "'") {
      const q = c; cur += c; i++;
      while (i < body.length && body[i] !== q) { if (body[i] === "\\") { cur += body[i]; i++; } cur += body[i]; i++; }
      cur += body[i] ?? "";
      continue;
    }
    if (c === "{" || c === "(" || c === "[") depth++;
    else if (c === "}" || c === ")" || c === "]") depth--;
    if (c === sep && depth === 0) { out.push(cur); cur = ""; } else cur += c;
  }
  out.push(cur);
  return out.map((s) => s.trim()).filter(Boolean);
}

// ── the .did side ──
// { types: Map<name, typeExprText>, methods: Map<name, firstReturnTypeText> }
function parseDid(did) {
  const types = new Map();
  const re = /^type\s+(\w+)\s*=/gm;
  let m;
  while ((m = re.exec(did))) {
    // the expression runs to the first `;` at depth 0 after the `=`
    const start = m.index + m[0].length;
    let depth = 0, i = start;
    for (; i < did.length; i++) {
      const c = did[i];
      if (c === '"') { i++; while (i < did.length && did[i] !== '"') i++; continue; }
      if (c === "{" || c === "(") depth++;
      else if (c === "}" || c === ")") depth--;
      else if (c === ";" && depth === 0) break;
    }
    types.set(m[1], did.slice(start, i).trim());
  }
  const methods = new Map();
  const svcAt = did.search(/^service\s*:\s*\{/m);
  let svc = svcAt < 0 ? null : matchedBody(did, did.indexOf("{", svcAt));
  if (!svc) {
    // the ACTOR-CLASS form (candid/archive.did): `service : (init args) ->
    // Name` with the methods under `type Name = service { ... }`
    const cls = /^service\s*:\s*\([^)]*\)\s*->\s*(\w+)/m.exec(did);
    const def = cls && new RegExp(`^type\\s+${cls[1]}\\s*=\\s*service\\s*\\{`, "m").exec(did);
    if (def) svc = matchedBody(did, did.indexOf("{", def.index));
  }
  if (svc) {
    for (const seg of topLevelSplit(svc.body, ";")) {
      const mm = /^(\w+)\s*:\s*([\s\S]*)$/.exec(seg);
      if (!mm) continue;
      const arrow = mm[2].indexOf("->");
      if (arrow < 0) continue;
      let ret = mm[2].slice(arrow + 2).replace(/\b(composite_query|query|oneway)\s*$/, "").trim();
      const rb = ret.startsWith("(") ? matchedBody(ret, 0) : null;
      if (!rb) continue;
      const first = topLevelSplit(rb.body, ",")[0] || "";
      // a NAMED return (`(x: nat)`) carries its label before the type
      methods.set(mm[1], first.replace(/^\w+\s*:\s*(?=\S)/, "").trim());
    }
  }
  return { types, methods };
}
// Resolve a .did type expression to { kind: "record"|"variant", fields } or
// null (primitive, tuple, func, unknown name). opt/vec wrappers are stripped.
function didContainer(expr, types, depth = 0) {
  let t = (expr || "").trim();
  for (;;) {
    const w = /^(opt|vec)\s+([\s\S]*)$/.exec(t);
    if (!w) break;
    t = w[2].trim();
  }
  const inl = /^(record|variant)\s*\{/.exec(t);
  if (inl) {
    const mb = matchedBody(t, t.indexOf("{"));
    if (!mb) return null;
    const fields = new Map();
    for (const seg of topLevelSplit(mb.body, ";")) {
      const f = /^"?(\w+)"?\s*(?::\s*([\s\S]*))?$/.exec(seg);
      if (!f) return null;
      if (inl[1] === "record" && f[2] === undefined) return null;   // positional (tuple) record
      fields.set(f[1], (f[2] || "").trim());
    }
    return { kind: inl[1], fields, name: null };
  }
  if (/^\w+$/.test(t) && types.has(t) && depth < 8) {
    const c = didContainer(types.get(t), types, depth + 1);
    return c ? { ...c, name: c.name || t } : null;
  }
  return null;
}

// ── the IDL side (getIdlFactory's arrow body, comments already stripped) ──
// { consts: Map<name, exprText>, methods: Map<name, firstReturnExprText> }
function parseIdl(factoryBody) {
  const consts = new Map();
  const methods = new Map();
  const arrowAt = factoryBody.indexOf("=>");
  const inner = arrowAt < 0 ? null : matchedBody(factoryBody, factoryBody.indexOf("{", arrowAt));
  if (!inner) return { consts, methods };
  for (const stmt of topLevelSplit(inner.body, ";")) {
    const cm = /^const\s+(\w+)\s*=\s*([\s\S]*)$/.exec(stmt);
    if (cm) { consts.set(cm[1], cm[2].trim()); continue; }
    const sm = /^return\s+IDL\.Service\s*\(/.exec(stmt);
    if (!sm) continue;
    const svc = matchedBody(stmt, stmt.indexOf("(", sm.index));
    const obj = svc && matchedBody(svc.body, svc.body.indexOf("{"));
    if (!obj) continue;
    for (const seg of topLevelSplit(obj.body, ",")) {
      const mm = /^(\w+)\s*:\s*IDL\.Func\s*\(/.exec(seg);
      if (!mm) continue;
      const args = matchedBody(seg, seg.indexOf("(", mm[0].length - 1));
      if (!args) continue;
      const parts = topLevelSplit(args.body, ",");
      const rets = parts[1] ? matchedBody(parts[1], parts[1].indexOf("[")) : null;
      if (!rets) continue;
      methods.set(mm[1], (topLevelSplit(rets.body, ",")[0] || "").trim());
    }
  }
  return { consts, methods };
}
// Resolve an IDL type expression the same way. Field values keep their
// expression text so the caller can see IDL.Opt(...) on them.
function idlContainer(expr, consts, depth = 0) {
  let t = (expr || "").trim();
  for (;;) {
    const w = /^IDL\.(Opt|Vec)\s*\(/.exec(t);
    if (!w) break;
    const mb = matchedBody(t, t.indexOf("("));
    if (!mb) return null;
    t = mb.body.trim();
  }
  const inl = /^IDL\.(Record|Variant)\s*\(\s*\{/.exec(t);
  if (inl) {
    const mb = matchedBody(t, t.indexOf("{"));
    if (!mb) return null;
    const fields = new Map();
    for (const seg of topLevelSplit(mb.body, ",")) {
      const f = /^"?(\w+)"?\s*:\s*([\s\S]*)$/.exec(seg);
      if (!f) return null;
      fields.set(f[1], f[2].trim());
    }
    return { kind: inl[1].toLowerCase(), fields, name: null };
  }
  if (/^\w+$/.test(t) && consts.has(t) && depth < 8) {
    const c = idlContainer(consts.get(t), consts, depth + 1);
    return c ? { ...c, name: c.name || t } : null;
  }
  return null;
}
// The bare type name an expression refers to once opt/vec wrappers are gone
// (null when inline) — used to skip re-comparing a NAMED pair reached
// through a field, which the named-pair loop already covers.
function didRefName(expr) { return (/^(?:(?:opt|vec)\s+)*(\w+)$/.exec((expr || "").trim()) || [])[1] || null; }
function idlRefName(expr) {
  let t = (expr || "").trim();
  for (;;) {
    const w = /^IDL\.(Opt|Vec)\s*\(/.exec(t);
    if (!w) break;
    const mb = matchedBody(t, t.indexOf("("));
    if (!mb) return null;
    t = mb.body.trim();
  }
  return /^\w+$/.test(t) && !/^IDL\./.test(t) ? t : null;
}
// Walk both containers in step. `out.missing` collects .did fields/tags the
// IDL does not name (the silent-drop class); `out.required` collects IDL
// record fields the .did lacks that are NOT IDL.Opt (the decode-throw class);
// `out.kind` collects record-vs-variant disagreements.
function compareContainers(path, idl, did, ctx, out, depth = 0) {
  if (idl.kind !== did.kind) { out.kind.push(`${path}: IDL ${idl.kind} vs .did ${did.kind}`); return; }
  for (const [name, didType] of did.fields) {
    const idlType = idl.fields.get(name);
    if (idlType === undefined) { out.missing.push(`${path}.${name}`); continue; }
    if (depth >= 6) continue;
    const dn = didRefName(didType), inn = idlRefName(idlType);
    if (dn && inn && dn === inn && ctx.pairs.has(dn)) continue;  // the named-pair loop covers it
    const sub = idlContainer(idlType, ctx.consts), dsub = didContainer(didType, ctx.types);
    if (sub && dsub) compareContainers(`${path}.${name}`, sub, dsub, ctx, out, depth + 1);
  }
  if (idl.kind === "record") {
    for (const [name, t] of idl.fields) {
      if (!did.fields.has(name) && !/^IDL\.Opt\s*\(/.test(t)) out.required.push(`${path}.${name}`);
    }
  }
}

console.log("\nK. hand-written IDL ⊇ candid/*.did — every published field is named (the decoder drops unlisted ones)");
{
  const rawMain = must("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);

  // One (hand-written factory, published .did) pair held to the superset
  // rule — K1 parser floors, K2 named pairs, K3 method returns, K4 coverage
  // floors + the reverse direction. main.js carries THREE such factories
  // (task 1788510196): getIdlFactory ↔ candid/backend.did,
  // getArchiveIdlFactory ↔ candid/archive.did (the sidecar actor class —
  // its comment says the copy "must match the backend UserEvent Candid
  // exactly, or decode fails silently"; nothing pinned that before) and
  // getBridgeIdlFactory ↔ candid/bridge.did. Their const names COLLIDE
  // (each declares its own Side/UserEvent/...), so each factory body is
  // parsed on its own. Returns the parsed sides, or null when a side is
  // unreadable (already reported).
  function holdFactory(label, header, didPath, floors) {
    const did = must(didPath);
    const fac = src === null ? null : funcBody(src, header);
    check(`${label}: ${header.slice("function ".length, -1)} is extractable from main.js`, fac !== null,
      `the ${label} IDL factory was renamed — this pair is then asserting nothing`);
    if (!fac || !did) return null;
    const D = parseDid(did);
    const I = parseIdl(fac);
    // K1 — the parsers see the shapes they claim to (a silent parse failure
    // would otherwise pass every pair by finding none).
    check(`parser: ${didPath} yields ≥ ${floors.didTypes} named types and ≥ ${floors.didMethods} service methods`,
      D.types.size >= floors.didTypes && D.methods.size >= floors.didMethods, `types=${D.types.size} methods=${D.methods.size}`);
    check(`parser: the ${label} factory yields ≥ ${floors.consts} named consts and ≥ ${floors.methods} service methods`,
      I.consts.size >= floors.consts && I.methods.size >= floors.methods, `consts=${I.consts.size} methods=${I.methods.size}`);

    // K2 — the named pairs: every IDL const with a same-named .did type where
    // both resolve to a record or variant.
    const pairs = new Map();
    for (const name of I.consts.keys()) {
      if (!D.types.has(name)) continue;
      const ic = idlContainer(name, I.consts), dc = didContainer(name, D.types);
      if (ic && dc) pairs.set(name, { ic, dc });
    }
    const ctx = { consts: I.consts, types: D.types, pairs };
    const out = { required: [] };
    let comparedPairs = 0;
    for (const [name, { ic, dc }] of [...pairs].sort(([a], [b]) => a.localeCompare(b))) {
      const local = { missing: [], required: [], kind: [] };
      compareContainers(name, ic, dc, ctx, local);
      comparedPairs++;
      check(`${label} ${name}: the IDL ${ic.kind} names every field ${didPath} publishes`,
        local.missing.length === 0 && local.kind.length === 0,
        [...local.missing.map((f) => `MISSING from the IDL (silently dropped at decode): ${f}`), ...local.kind].join("\n"));
      out.required.push(...local.required);
    }

    // K3 — the method returns: every service method both sides declare whose
    // return resolves to a container on both sides, unless both sides name
    // the SAME type (then K2 already covered it).
    let comparedMethods = 0;
    for (const method of [...I.methods.keys()].sort()) {
      if (!D.methods.has(method)) continue;
      const ie = I.methods.get(method), de = D.methods.get(method);
      const inn = idlRefName(ie), dn = didRefName(de);
      if (inn && dn && inn === dn && pairs.has(inn)) continue;
      const ic = idlContainer(ie, I.consts), dc = didContainer(de, D.types);
      if (!ic || !dc) continue;
      const local = { missing: [], required: [], kind: [] };
      compareContainers(`${method}()`, ic, dc, ctx, local);
      comparedMethods++;
      check(`${label} ${method}(): the IDL return ${ic.kind} names every field ${didPath} publishes`,
        local.missing.length === 0 && local.kind.length === 0,
        [...local.missing.map((f) => `MISSING from the IDL (silently dropped at decode): ${f}`), ...local.kind].join("\n"));
      out.required.push(...local.required);
    }

    // K4 — coverage floors, so a parser regression cannot pass by comparing
    // nothing; and the reverse direction, aggregated.
    check(`${label} coverage: ≥ ${floors.pairs} named pairs and ≥ ${floors.returns} method returns compared (got ${comparedPairs} + ${comparedMethods})`,
      comparedPairs >= floors.pairs && comparedMethods >= floors.returns);
    check(`${label}: no IDL record names a REQUIRED (non-Opt) field ${didPath} lacks — such a field fails the whole decode`,
      out.required.length === 0,
      out.required.map((f) => `IDL-only and not IDL.Opt: ${f}`).join("\n"));
    return { D, I, pairs };
  }

  const backend = holdFactory("backend", "function getIdlFactory(", "candid/backend.did",
    { didTypes: 60, didMethods: 100, consts: 40, methods: 100, pairs: 45, returns: 25 });
  if (backend) {
    const { D, I, pairs } = backend;
    check("parser: PriceFeedStats parses as a record on both sides with quoteSignals on each",
      didContainer("PriceFeedStats", D.types)?.fields.has("quoteSignals") === true
        && idlContainer("PriceFeedStats", I.consts)?.fields.has("quoteSignals") === true);
    check("parser: the OQL Cell's quoted \"null\" tag survives on both sides (Value variant / OqlRows cell)",
      didContainer("Value", D.types)?.fields.has("null") === true
        && idlContainer("OqlRows", I.consts)?.fields.get("value")?.includes('"null"') === true,
      "quoted keys are how Motoko's #null_ reaches the wire — the parsers must keep them");
    check("the task's three anchors are compared: PriceFeedStats + Aggregate as named pairs, getCanisterInfo as a method return",
      pairs.has("PriceFeedStats") && pairs.has("Aggregate") && I.methods.has("getCanisterInfo") && D.methods.has("getCanisterInfo"),
      `named pairs: ${[...pairs.keys()].join(", ")}`);
  }
  // The archive .did is an ACTOR-CLASS interface (`service : (owner :
  // principal) -> Archive` + `type Archive = service { ... }`) — parseDid
  // resolves that form to the same method map (pinned by the didMethods
  // floor: 0 methods would mean the form regressed).
  const archive = holdFactory("archive", "function getArchiveIdlFactory(", "candid/archive.did",
    { didTypes: 8, didMethods: 9, consts: 8, methods: 5, pairs: 7, returns: 3 });
  if (archive) {
    check("parser: candid/archive.did's actor-class service resolves (stats + getCertifiedHead are methods; UserEvent/UserEventKind are pairs)",
      archive.D.methods.has("stats") && archive.D.methods.has("getCertifiedHead")
        && archive.pairs.has("UserEvent") && archive.pairs.has("UserEventKind"),
      `methods: ${[...archive.D.methods.keys()].join(", ")}; pairs: ${[...archive.pairs.keys()].join(", ")}`);
  }
  const bridge = holdFactory("bridge", "function getBridgeIdlFactory(", "candid/bridge.did",
    { didTypes: 2, didMethods: 15, consts: 2, methods: 6, pairs: 2, returns: 2 });

  // K5 — the INTRA-FILE twin pin (task 1788510196, half 1): the archive
  // factory re-declares the backend factory's UserEvent family by hand
  // (Side, OrderType, OrderStatus, DepositRecord, ClosedOrderRecord,
  // LiquidationEvent, UserEventKind, UserEvent). The archive ships the
  // backend's UserEvent VERBATIM, so every const the two factories share by
  // name must have an IDENTICAL field/tag set, recursively — a divergence
  // is a defect on one side whichever way it points, which is why this is
  // an equality and not the superset rule above (K2 already holds each copy
  // ⊇ its own .did; this catches a field one copy carries as IDL.Opt that
  // the other lacks, which K2/K4 tolerate). Both sides are IDL syntax, so
  // the walk resolves through each factory's own const map.
  function compareIdlTwins(path, a, b, A, B, shared, out, depth = 0) {
    if (a.kind !== b.kind) { out.push(`${path}: ${a.kind} in the first copy vs ${b.kind} in the second`); return; }
    for (const [name, at] of a.fields) {
      const bt = b.fields.get(name);
      if (bt === undefined) { out.push(`${path}.${name}: only in the first copy`); continue; }
      if (depth >= 6) continue;
      const an = idlRefName(at), bn = idlRefName(bt);
      if (an && bn && an === bn && shared.has(an)) continue;   // the shared-name loop covers it
      const sa = idlContainer(at, A), sb = idlContainer(bt, B);
      if (sa && sb) compareIdlTwins(`${path}.${name}`, sa, sb, A, B, shared, out, depth + 1);
    }
    for (const name of b.fields.keys()) if (!a.fields.has(name)) out.push(`${path}.${name}: only in the second copy`);
  }
  function holdTwins(first, second, minShared) {
    if (!first.side || !second.side) return;
    const A = first.side.I.consts, B = second.side.I.consts;
    const shared = new Map();
    for (const name of B.keys()) {
      if (!A.has(name)) continue;
      const a = idlContainer(name, A), b = idlContainer(name, B);
      if (a && b) shared.set(name, { a, b });
    }
    if (minShared > 0) {
      check(`twins: the ${second.label} factory shares ≥ ${minShared} container consts by name with the ${first.label} factory (got ${shared.size})`,
        shared.size >= minShared, [...shared.keys()].join(", "));
    } else {
      ok(`twins: the ${second.label} factory shares ${shared.size} container consts by name with the ${first.label} factory (no floor)`);
    }
    for (const [name, { a, b }] of [...shared].sort(([x], [y]) => x.localeCompare(y))) {
      const out = [];
      compareIdlTwins(name, a, b, A, B, shared, out);
      check(`twins ${name}: the ${first.label} and ${second.label} factories' copies have an IDENTICAL field/tag set`,
        out.length === 0,
        out.map((d) => d.replace("the first copy", `the ${first.label} factory`).replace("the second copy", `the ${second.label} factory`)).join("\n"));
    }
  }
  holdTwins({ label: "backend", side: backend }, { label: "archive", side: archive }, 8);
  holdTwins({ label: "backend", side: backend }, { label: "bridge", side: bridge }, 0);
}

// ── L. #55 round-18 display batch ───────────────────────────────────
// Three small claims a person or a bot reads and believes (task 1788465041):
//   L1 the Ledger page renders a #config tape row (the six-odd admin setters
//      — setBridge, setAutoFuel, setFuelRoute, ... — emit `#config { setter;
//      value }`); before the fix kindCell fell through to ["event", ""] and
//      the row showed a blank detail. Behavioural: ledger.js is importable in
//      node (side-effect-free at module level — eventchain_equivalence and
//      frontend_security already rely on that), so kindCell is exercised.
//   L2 docs.js's changelog said "apiVersion is now 2.0.0" while MM_API_VERSION
//      is several majors on. The historical bump stays; the CURRENT version
//      stated beside it is pinned to the constant in main.mo (drift pin).
//   L3 getApiDoc's Swaps section documents quoteSwap's slippage default and
//      the accepted maxSlippage range — and those numbers are checked AGAINST
//      the code (quoteSwap's `maxSlippage == 0` default, swap's #marketOrder
//      refusal bounds), so the doc cannot drift from the behaviour it claims.
console.log("\nL. #55 round-18 display batch — Ledger #config rows, docs.js apiVersion drift, getApiDoc slippage claims vs the code");
{
  // L1 — kindCell renders #config with BOTH fields escaped.
  let ledgerMod = null;
  try {
    ledgerMod = await import(pathToFileURL(path("src/frontend/src/ledger.js")).href);
  } catch (e) {
    bad("ledger.js imports cleanly for the kindCell behavioural case", e);
  }
  check("ledger.js exports kindCell (the Ledger page's tape-row renderer)",
    ledgerMod !== null && typeof ledgerMod.kindCell === "function",
    "kindCell is module-private or renamed — export it; this section is then asserting nothing");
  if (ledgerMod && typeof ledgerMod.kindCell === "function") {
    const setter = 'setBridge<b onclick="x">';
    const value = 'aaaaa-aa" & \'<script>';
    const out = ledgerMod.kindCell({ kind: { config: { setter, value } } });
    const tag = Array.isArray(out) ? out[0] : null;
    const detail = Array.isArray(out) ? String(out[1]) : "";
    check("a #config event renders under its own kind tag, not the generic 'event'", tag === "config", `tag=${tag}`);
    check("the #config detail names the setter", detail.includes("setBridge"), `detail=${detail}`);
    check("the #config detail carries the value", detail.includes("aaaaa-aa"), `detail=${detail}`);
    check("BOTH fields pass through escH — no raw '<', '\"', \"'\" or bare '&' reaches innerHTML",
      !/<|"|'|&(?!(amp|lt|gt|quot|#39);)/.test(detail) && detail.includes("&lt;b") && detail.includes("&lt;script"),
      `detail=${detail}`);
    const fb = ledgerMod.kindCell({ kind: { somethingNew: {} } });
    check("an unknown kind still falls back to the bare 'event' row (the safety net is unchanged)",
      Array.isArray(fb) && fb[0] === "event" && fb[1] === "", `got ${JSON.stringify(fb)}`);
  }

  // L2 — docs.js's stated CURRENT apiVersion == MM_API_VERSION.
  const mo = must("src/backend/main.mo");
  const docs = must("src/frontend/src/docs.js");
  if (mo && docs) {
    const mv = mo.match(/MM_API_VERSION\s*:\s*Text\s*=\s*"([^"]+)"/);
    check("main.mo declares MM_API_VERSION as a string literal", mv !== null,
      "constant renamed or no longer literal — this pin is then asserting nothing");
    const dv = docs.match(/current apiVersion is <b>([^<]+)<\/b>/);
    check("docs.js states the CURRENT apiVersion beside the historical 2.0.0 bump ('the current apiVersion is <b>X</b>')",
      dv !== null, "the changelog presents an old apiVersion as current — state the real one");
    if (mv && dv) {
      check(`docs.js's stated current apiVersion (${dv[1]}) matches MM_API_VERSION (${mv[1]})`, dv[1] === mv[1],
        "bump the docs.js changelog line to the constant's value");
    }
    check("docs.js no longer says 'apiVersion is now 2.0.0' (three majors stale)",
      !/apiVersion is now <b>2\.0\.0<\/b>/.test(docs));
  }

  // L3 — getApiDoc's Swaps section vs the code it describes.
  if (mo) {
    const doc = funcBody(mo, "func getApiDoc(");
    check("getApiDoc's body is extractable from main.mo", doc !== null,
      "getApiDoc renamed — this pin is then asserting nothing");
    const dflt = mo.match(/let slip = if \(maxSlippage == 0\) \{ (\d[\d_]*) \}/);
    check("quoteSwap still defaults maxSlippage = 0 to a literal fraction (W4-04)", dflt !== null);
    const bounds = mo.match(/case \(#marketOrder\(\{ maxSlippage \}\)\) \{\s*if \(maxSlippage < (\d[\d_]*) or maxSlippage > (\d[\d_]*)\)/);
    check("swap's #marketOrder still range-checks maxSlippage with literal bounds", bounds !== null);
    if (doc && dflt && bounds) {
      const pct = (s) => String(Number(s.replace(/_/g, "")) / 1_000_000);
      const dPct = pct(dflt[1]), lo = pct(bounds[1]), hi = pct(bounds[2]);
      const at = doc.indexOf("## Swaps");
      const next = doc.indexOf("## ", at + 8);
      const swaps = at < 0 ? "" : doc.slice(at, next < 0 ? doc.length : next);
      check("getApiDoc has a '## Swaps' section", at >= 0);
      check(`getApiDoc's Swaps section states quoteSwap's slippage DEFAULT as ${dPct}% (the code's ${dflt[1]})`,
        /quoteSwap/.test(swaps) && /default/i.test(swaps) && swaps.includes(`${dPct}%`),
        swaps.slice(0, 400));
      check(`getApiDoc's Swaps section states the accepted maxSlippage RANGE as ${lo}%–${hi}% (the code's ${bounds[1]}..${bounds[2]})`,
        swaps.includes(`${lo}%–${hi}%`) || swaps.includes(`${lo}%-${hi}%`),
        swaps.slice(0, 400));
      check("getApiDoc's Swaps section says swap REFUSES an out-of-range maxSlippage (the quote-accepts-0 / swap-refuses-it asymmetry)",
        /refuse/i.test(swaps) && /maxSlippage = 0|maxSlippage=0|zero/i.test(swaps),
        swaps.slice(0, 400));
    }
  }
}

// ── M. Earn card: the LP withdraw submit is gated on withdrawalPaused ──
// Task 1788515292. 1788513125 added `withdrawalPaused : opt text` to
// getMaxInstantWithdraw — the exact "LP withdrawal paused: …" refusal
// withdrawLp would return RIGHT NOW (a held leg breaker-pended / stale /
// unpriced while the loan book is non-zero), null otherwise — and the Earn
// card only PREFIXED it to the liquidity prose: the submit stayed live and the
// user could click straight into the refusal. Now:
//   M1 renderVaultLiquidity disables #earn-vault-withdraw-btn with the pause
//      text as its tooltip through applyWithdrawPause, and re-enables it on a
//      quote where the field is null — and on NO quote at all (an older
//      backend / a failed query must never leave the button stuck).
//   M2 BEHAVIOURAL: applyWithdrawPause and renderVaultLiquidity are lifted out
//      of main.js and run over a fake document (nodes carry {disabled, title,
//      dataset, style, textContent}); paused → disabled + title; unpaused →
//      live + no title; a button somebody ELSE disabled (no gate latch) is left
//      alone by an unpaused quote — the gate composes, it does not fight.
//   M3 cadence: the pause clears on a market-wide price restamp, which bumps
//      NO user version, so pollChanges would never re-render the Earn card for
//      it. refreshVaultLiquidity re-quotes on the slow (10 s) ticker while the
//      Earn pane is on screen, so a cleared pend re-enables within one tick.
//   M4 no other path leaves it stuck: logout drops the gate with the other
//      identity-scoped state, and nothing outside applyWithdrawPause writes
//      the button's `disabled`.
//   M5 the markup and the deposit side: the button sits beside the input
//      (the one-tap Max between them since task 1793553361); the deposit
//      submit carries no pause wiring (its gate is server-side and has no
//      query surface); the demo stub, if it ever stubs the quote, carries
//      the field.
//   M2d (task 1793553361) the one-tap Max over the same fake document: a
//      quote enables it and stashes the QUOTE on the field; the lifted
//      handler fills "989.901" for the 990 fixture (a plain number); the
//      pause disables it with the pause text; cap 0 disables it and drops the
//      stash; NO quote keeps the last stash live (the submit's rule); the
//      logout call drops it; the pre-policy handler (nowLp) fills "990".
console.log("\nM. Earn card — the LP withdraw submit is disabled while getMaxInstantWithdraw.withdrawalPaused is set");
{
  const rawMain = must("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);
  const PAUSE_TEXT = "LP withdrawal paused: a ICP price move is awaiting circuit-breaker confirmation";
  // A minimal fake DOM: one node per id, remembered so a later lookup sees
  // what an earlier render wrote (exactly what the browser does).
  function fakeDocument() {
    const nodes = new Map();
    return {
      nodes,
      getElementById(id) {
        if (!nodes.has(id)) nodes.set(id, { id, style: {}, dataset: {}, textContent: "", title: "", disabled: false, placeholder: "", value: "" });
        return nodes.get(id);
      },
    };
  }
  // A quote as the render sees it: money fields pre-normalised (money.js),
  // lentOutFraction a 0..1 fraction, exitFeeBps raw, withdrawalPaused an
  // `opt text` in its Candid-decoded array shape. lockedLp (task 1788727875)
  // defaults to 0 — no locks — so the pause cases below read exactly as
  // before; the locked-share cases pass a non-zero count.
  const quote = (paused, lockedLp = 0) => ({
    withdrawableNowUsd: 1000, totalNavUsd: 1500, withdrawableNowLp: 990, lentOutFraction: 0.33,
    vaultHoldingsUsd: 2000, vaultNavUsd: 3000, vaultLentOutUsd: 1000, exitFeeBps: 40,
    vaultImpairmentReserveUsd: 0, provisionedLossUsd: 0, lpBalance: 1500,
    withdrawalPaused: paused === null ? [] : [paused],
    lockedLp, vaultLockedLp: lockedLp, vaultLockedNavUsd: 0,
  });

  if (src) {
    // M1 — the gate helper and the render wiring (source pins).
    const gate = funcBody(src, "function applyWithdrawPause(");
    check("applyWithdrawPause exists (the one place the withdraw submit's disabled/title are written)",
      gate !== null, "helper missing or renamed — the pause is prose only again");
    if (gate) {
      check("applyWithdrawPause disables the button and puts the pause text in its title",
        /disabled\s*=\s*true/.test(gate) && /title\s*=\s*paused/.test(gate),
        "the tooltip must carry the backend's exact refusal text");
      check("applyWithdrawPause re-enables (disabled = false, title cleared) on a null pause",
        /disabled\s*=\s*false/.test(gate) && /title\s*=\s*""/.test(gate));
      check("applyWithdrawPause latches what it disabled (dataset.paused) so it only re-enables its own gate",
        /dataset\.paused/.test(gate),
        "without the latch an unpaused quote would override any other disabler");
    }
    const body = funcBody(src, "function renderVaultLiquidity(");
    check("renderVaultLiquidity is extractable", body !== null, "function header moved?");
    if (body) {
      check("renderVaultLiquidity looks up #earn-vault-withdraw-btn",
        /getElementById\("earn-vault-withdraw-btn"\)/.test(body),
        "the render must reach the submit, not just the note");
      check("renderVaultLiquidity derives `paused` from liq.withdrawalPaused (opt text) and gates the submit with it",
        /const paused\s*=\s*Array\.isArray\(liq\.withdrawalPaused\)/.test(body) && /applyWithdrawPause\(wBtn,\s*paused\)/.test(body),
        "the gate must be fed the same field the prose reads");
      check("renderVaultLiquidity clears the gate when there is NO quote (older backend / failed query)",
        /applyWithdrawPause\(wBtn,\s*null\)/.test(body),
        "a missing quote must never leave the button stuck disabled");
      check("the pause text still prefixes the liquidity prose (1788513125's disclosure is kept)",
        /pausedNote/.test(body) && /paused\s*\?\s*`\$\{paused\}\.\s*`/.test(body));
      check("the deposit submit carries no pause wiring in the render (its gate is server-side, no query surface)",
        !/earn-vault-deposit-btn/.test(body));
    }

    // M2 — BEHAVIOURAL: lift the helper and the render, run them over the fake DOM.
    let applyFn = null;
    if (gate) {
      try { applyFn = new Function("return function applyWithdrawPause(btn, paused) " + gate)(); }
      catch (e) { bad("applyWithdrawPause is liftable and runnable", e.message); }
    }
    if (applyFn) {
      const btn = { disabled: false, title: "", dataset: {} };
      applyFn(btn, PAUSE_TEXT);
      check("applyWithdrawPause(paused): disabled === true and title === the pause text",
        btn.disabled === true && btn.title === PAUSE_TEXT, JSON.stringify(btn));
      applyFn(btn, null);
      check("applyWithdrawPause(null) after a pause: disabled === false and title === ''",
        btn.disabled === false && btn.title === "", JSON.stringify(btn));
      const other = { disabled: true, title: "amount required", dataset: {} };
      applyFn(other, null);
      check("applyWithdrawPause(null) leaves a button it did NOT disable alone (composes with any other disabler)",
        other.disabled === true && other.title === "amount required", JSON.stringify(other));
      check("applyWithdrawPause tolerates a missing button", (() => { try { applyFn(null, PAUSE_TEXT); return true; } catch { return false; } })());
    }
    let renderFn = null;
    let maxStateFn = null;
    let maxTapFn = null;
    // The render reads LP_WITHDRAW_DRIFT_ALLOWANCE and lpWithdrawMaxFill (task
    // 1788746837) and applyWithdrawMax (task 1793553361): lift the REAL
    // helpers over money.js's toE8/fromE8 and bind them all, so the
    // placeholder and the Max fill below are the production arithmetic, not a
    // stub. `renderBody` / `tapBody` let the negative controls lift a mutated
    // copy; the Max handler is lifted beside the render over the same document.
    const fillBodyM = funcBody(src, "function lpWithdrawMaxFill(");
    const allowM = (src.match(/const LP_WITHDRAW_DRIFT_ALLOWANCE\s*=\s*([0-9.e+-]+)\s*;/) || [])[1];
    const maxStateBodyM = funcBody(src, "function applyWithdrawMax(");
    const maxTapBodyM = funcBody(src, "function onVaultWithdrawMax(");
    if (body && applyFn && fillBodyM && allowM && money && maxStateBodyM && maxTapBodyM) {
      try {
        const fillM = new Function("LP_WITHDRAW_DRIFT_ALLOWANCE", "toE8", "fromE8",
          "return function lpWithdrawMaxFill(nowLp) " + fillBodyM)(Number(allowM), money.toE8, money.fromE8);
        maxStateFn = new Function("lpWithdrawMaxFill", "formatNum",
          "return function applyWithdrawMax(wIn, mBtn, nowLp, paused) " + maxStateBodyM)(fillM, (n) => String(n));
        renderFn = (doc, renderBody = body) => new Function("document", "formatNum", "applyWithdrawPause", "applyWithdrawMax", "lpWithdrawMaxFill", "LP_WITHDRAW_DRIFT_ALLOWANCE",
          "return function renderVaultLiquidity(liq) " + renderBody)(doc, (n) => String(n), applyFn, maxStateFn, fillM, Number(allowM));
        maxTapFn = (doc, tapBody = maxTapBodyM) => new Function("document", "lpWithdrawMaxFill",
          "return function onVaultWithdrawMax() " + tapBody)(doc, fillM);
      } catch (e) { bad("renderVaultLiquidity, applyWithdrawMax and onVaultWithdrawMax are liftable over a fake document", e.message); }
    } else if (body && applyFn) {
      bad("renderVaultLiquidity's lift needs lpWithdrawMaxFill + LP_WITHDRAW_DRIFT_ALLOWANCE (task 1788746837), applyWithdrawMax + onVaultWithdrawMax (task 1793553361) and money.js",
        `fill helper=${fillBodyM !== null} allowance=${allowM} max state=${maxStateBodyM !== null} max tap=${maxTapBodyM !== null} money=${money !== null}`);
    }
    if (renderFn) {
      const doc = fakeDocument();
      const render = renderFn(doc);
      const btn = doc.getElementById("earn-vault-withdraw-btn");
      let threw = null;
      try { render(quote(PAUSE_TEXT)); } catch (e) { threw = e; }
      check("renderVaultLiquidity runs over the fake document (paused quote)", threw === null, threw && threw.message);
      check("paused quote → the withdraw submit is disabled with the pause text as its title",
        btn.disabled === true && btn.title === PAUSE_TEXT, JSON.stringify({ disabled: btn.disabled, title: btn.title }));
      check("paused quote → the liquidity note still opens with the pause text",
        doc.getElementById("earn-vault-liquidity").textContent.startsWith(PAUSE_TEXT + ". "),
        doc.getElementById("earn-vault-liquidity").textContent.slice(0, 120));
      try { render(quote(null)); } catch (e) { threw = e; }
      check("next quote with withdrawalPaused = null → the submit is live again, title cleared",
        threw === null && btn.disabled === false && btn.title === "", JSON.stringify({ disabled: btn.disabled, title: btn.title }));
      try { render(quote(PAUSE_TEXT)); render(null); } catch (e) { threw = e; }
      check("a pause followed by NO quote (render(null)) → the submit is live (never stuck on a lost query)",
        threw === null && btn.disabled === false && btn.title === "", JSON.stringify({ disabled: btn.disabled, title: btn.title }));
      const dep = doc.nodes.get("earn-vault-deposit-btn");
      check("the deposit submit was never touched by the render", dep === undefined, "render looked up #earn-vault-deposit-btn");

      // M2b — the caller's LOCKED shares (task 1788727875; section G3b pins
      // the source shape). formatNum is stubbed as String(n), so the figures
      // read back verbatim.
      const LOCKED_SENTENCE = (n, m) => `${n} of your ${m} LP shares are locked from your earlier withdrawal(s); they carry loan-book value only and unlock as the vault's margin loans repay (a partial repayment unlocks them pro rata).`;
      const note = () => doc.getElementById("earn-vault-liquidity").textContent;
      const ph = () => doc.getElementById("earn-vault-withdraw-input").placeholder;
      try { render(quote(null, 300)); } catch (e) { threw = e; }
      check("lockedLp = 300 of lpBalance 1500 → the note ends with \"300 of your 1500 LP shares are locked …\" (N and M from the quote)",
        threw === null && note().endsWith(" " + LOCKED_SENTENCE(300, 1500)), threw ? threw.message : note().slice(-220));
      check("lockedLp = 300 → the locked sentence is APPENDED to the liquidity prose, not substituted for it",
        note().startsWith("Every LP share redeems at full vault value (NAV)"), note().slice(0, 120));
      // The fixture's cap is 990 LP; the box suggests the cap less the 0.01 %
      // drift allowance (task 1788746837): 990 × 0.9999 = 989.901, on the LP
      // base-unit grid, and names the allowance.
      const MAX_NOW_990 = "max now 989.901 after a 0.01% drift allowance";
      check(`lockedLp = 300 → the withdraw placeholder reads "LP to withdraw (${MAX_NOW_990}; 300 locked)"`,
        ph() === `LP to withdraw (${MAX_NOW_990}; 300 locked)`, ph());
      // The max-exit shape (test_vault_lp §7 F1 before the allowance; still a
      // real state — an LP who typed the exact cap and settled): cap 0, every
      // retained share locked — the placeholder must still say so, "max now 0"
      // and all, and with nothing to under-ask it names no allowance.
      try { render({ ...quote(null, 1500), withdrawableNowUsd: 0, withdrawableNowLp: 0 }); } catch (e) { threw = e; }
      check("max exit (cap 0, all 1500 shares locked) → the note says \"1500 of your 1500 LP shares are locked …\"",
        threw === null && note().endsWith(" " + LOCKED_SENTENCE(1500, 1500)), threw ? threw.message : note().slice(-220));
      check("max exit → the placeholder reads \"LP to withdraw (max now 0; 1500 locked)\" (the honest cap, and where the rest is)",
        ph() === "LP to withdraw (max now 0; 1500 locked)", ph());
      // Zero locks: nothing extra — the pre-1788727875 prose and placeholder, byte for byte.
      try { render(quote(null, 0)); } catch (e) { threw = e; }
      check("lockedLp = 0 → the note carries NO locked-share sentence",
        threw === null && !/locked from your earlier withdrawal/.test(note()), note().slice(-220));
      check(`lockedLp = 0 → the placeholder is the plain "LP to withdraw (${MAX_NOW_990})"`,
        ph() === `LP to withdraw (${MAX_NOW_990})`, ph());
      // An older backend without the field: same as zero locks (`?? 0`), never NaN.
      const legacy = quote(null, 0); delete legacy.lockedLp; delete legacy.vaultLockedLp; delete legacy.vaultLockedNavUsd;
      try { render(legacy); } catch (e) { threw = e; }
      check("a quote WITHOUT lockedLp (older backend) → no locked sentence, no NaN in the placeholder",
        threw === null && !/locked from your earlier withdrawal/.test(note()) && !/NaN/.test(note()) && ph() === `LP to withdraw (${MAX_NOW_990})`,
        threw ? threw.message : ph());

      // M2c — the drift allowance (task 1788746837, operator policy (a)): the
      // box's figure is the quote less 0.01 % (G3c pins the arithmetic), the
      // note says WHY — before the locked sentence, which stays last — and the
      // field's title repeats it; a cap of 0 names no allowance. Negative
      // control in the house style: the pre-policy render (the exact quote in
      // the box) is lifted from a mutated copy and reads "max now 990", so the
      // placeholder pins above tell the two apart.
      const title = () => doc.getElementById("earn-vault-withdraw-input").title;
      try { render(quote(null, 300)); } catch (e) { threw = e; }
      check("quote 990 → the note explains the allowance (\"your instant maximum less a 0.01% drift allowance\") and why (interest accrues, marks update, before settlement)",
        threw === null && /"max now" is your instant maximum less a 0\.01% drift allowance: the maximum moves by a hair as margin interest accrues and marks update between a quote and your request's settlement/.test(note()),
        threw ? threw.message : note().slice(-420));
      check("quote 990 → the allowance sentence precedes the locked sentence (the locked sentence stays last)",
        note().indexOf("drift allowance") < note().indexOf(" of your 1500 LP shares are locked") && note().endsWith(" " + LOCKED_SENTENCE(300, 1500)),
        note().slice(-420));
      check("quote 990 → the field's title names the fill and the allowance",
        title() === "Max now 989.901 LP is your instant maximum less a 0.01% drift allowance, so the figure settles even if the vault re-prices between this quote and your request's settlement.",
        title());
      try { render({ ...quote(null, 1500), withdrawableNowUsd: 0, withdrawableNowLp: 0 }); } catch (e) { threw = e; }
      check("cap 0 → no allowance sentence in the note and no title (nothing to under-ask)",
        threw === null && !/drift allowance/.test(note()) && title() === "", `${title()} :: ${note().slice(-200)}`);
      let prePh = null;
      try {
        const doc2 = fakeDocument();
        renderFn(doc2, body.replace("lpWithdrawMaxFill(nowLp)", "nowLp"))(quote(null, 0));
        prePh = doc2.getElementById("earn-vault-withdraw-input").placeholder;
      } catch (e) { bad("the pre-policy render (mutated copy) lifts", e.message); }
      check("negative control: the pre-policy render (the exact quote in the box) reads \"max now 990 …\" — the fill pins above red on it",
        prePh !== null && /^LP to withdraw \(max now 990 /.test(prePh) && prePh !== `LP to withdraw (${MAX_NOW_990})`, prePh);

      // M2d — the one-tap Max (task 1793553361; section G3d pins the source
      // shape). Over the same fake document: the render stashes the QUOTE on
      // the field and enables the button; the lifted handler fills
      // String(lpWithdrawMaxFill(stash)) — "989.901" for the 990 fixture, a
      // plain number, no commas, no prose; the pause disables it with the
      // pause text; a cap of 0 disables it and drops the stash; NO quote keeps
      // the last stash live with the pause dropped (the submit's rule); the
      // logout call (applyWithdrawMax(…, 0, null)) disables it and drops the
      // stash. Negative control in the house style: the pre-policy handler —
      // the lifted copy with String(nowLp) for String(lpWithdrawMaxFill(nowLp))
      // — fills "990", which the tap pin tells apart.
      const mBtn = doc.getElementById("earn-vault-withdraw-max");
      const field = doc.getElementById("earn-vault-withdraw-input");
      const tap = maxTapFn ? maxTapFn(doc) : null;
      check("onVaultWithdrawMax lifts over the fake document", tap !== null);
      if (tap) {
        field.value = "";
        try { render(quote(null, 0)); } catch (e) { threw = e; }
        check("quote 990, no pause → Max is live, its title names the fill (989.901), and the field stashes the QUOTE (data-max-now-lp = \"990\"), not the fill",
          threw === null && mBtn.disabled === false && /989\.901/.test(mBtn.title) && field.dataset.maxNowLp === "990",
          threw ? threw.message : JSON.stringify({ disabled: mBtn.disabled, title: mBtn.title, stash: field.dataset.maxNowLp }));
        tap();
        check("tap → the field's value is \"989.901\": the helper's fill as a plain number (no commas, no \"after …\" prose)",
          field.value === "989.901" && Number(field.value) === 989.901, JSON.stringify(field.value));
        field.value = "12"; tap();
        check("a second tap overwrites what the user typed with the fill again", field.value === "989.901", JSON.stringify(field.value));
        try { render({ ...quote(null, 0), withdrawableNowLp: 100000 }); } catch (e) { threw = e; }
        tap();
        check("a fresh quote of 100,000 → the next tap fills \"99990\" (10 LP of allowance; the stash is the LATEST quote)",
          threw === null && field.dataset.maxNowLp === "100000" && field.value === "99990", threw ? threw.message : JSON.stringify({ stash: field.dataset.maxNowLp, value: field.value }));
        try { render(quote(PAUSE_TEXT)); } catch (e) { threw = e; }
        check("paused quote → Max is disabled with the pause text as its title (the two buttons agree); the stash stays",
          threw === null && mBtn.disabled === true && mBtn.title === PAUSE_TEXT && field.dataset.maxNowLp === "990",
          threw ? threw.message : JSON.stringify({ disabled: mBtn.disabled, title: mBtn.title, stash: field.dataset.maxNowLp }));
        try { render(quote(null)); } catch (e) { threw = e; }
        check("the next unpaused quote → Max is live again with the fill's title, and the submit's own latch is live too",
          threw === null && mBtn.disabled === false && /989\.901/.test(mBtn.title) && btn.disabled === false,
          threw ? threw.message : JSON.stringify({ disabled: mBtn.disabled, title: mBtn.title, submit: btn.disabled }));
        field.value = "";
        try { render({ ...quote(null, 1500), withdrawableNowUsd: 0, withdrawableNowLp: 0 }); } catch (e) { threw = e; }
        tap();
        check("cap 0 (max exit) → Max is disabled, the stash is dropped, its title says why, and a tap fills nothing",
          threw === null && mBtn.disabled === true && field.dataset.maxNowLp === undefined && /Nothing is withdrawable/.test(mBtn.title) && field.value === "",
          threw ? threw.message : JSON.stringify({ disabled: mBtn.disabled, title: mBtn.title, stash: field.dataset.maxNowLp, value: field.value }));
        try { render(quote(null)); render(null); } catch (e) { threw = e; }
        check("a quote followed by NO quote (render(null)) → Max stays live on the last quote's stash — never stuck on a lost query, like the submit",
          threw === null && mBtn.disabled === false && field.dataset.maxNowLp === "990",
          threw ? threw.message : JSON.stringify({ disabled: mBtn.disabled, stash: field.dataset.maxNowLp }));
        try { render(quote(PAUSE_TEXT)); render(null); } catch (e) { threw = e; }
        check("a pause followed by NO quote → Max is live again (its pause drops with the submit's latch)",
          threw === null && mBtn.disabled === false && mBtn.title !== PAUSE_TEXT,
          threw ? threw.message : JSON.stringify({ disabled: mBtn.disabled, title: mBtn.title }));
        // The logout call: the stash was the old identity's quote.
        field.value = "";
        maxStateFn(field, mBtn, 0, null); tap();
        check("logout's applyWithdrawMax(field, button, 0, null) → disabled, stash dropped, a tap fills nothing (the old identity's figure never survives a sign-out)",
          mBtn.disabled === true && field.dataset.maxNowLp === undefined && field.value === "",
          JSON.stringify({ disabled: mBtn.disabled, stash: field.dataset.maxNowLp, value: field.value }));
        // Never quoted: a fresh document, a tap, nothing — and no NaN.
        const docF = fakeDocument(); maxTapFn(docF)();
        check("never quoted (no stash) → a tap fills nothing", docF.getElementById("earn-vault-withdraw-input").value === "",
          JSON.stringify(docF.getElementById("earn-vault-withdraw-input").value));
        check("applyWithdrawMax tolerates a missing field and a missing button",
          (() => { try { maxStateFn(null, null, 990, null); maxStateFn(null, { disabled: false, title: "" }, 990, null); return true; } catch { return false; } })());
        // Negative control: the pre-policy handler (the exact quote in the field).
        let preVal = null;
        try {
          const docN = fakeDocument();
          const fieldN = docN.getElementById("earn-vault-withdraw-input");
          renderFn(docN)(quote(null, 0));
          maxTapFn(docN, maxTapBodyM.replace("String(lpWithdrawMaxFill(nowLp))", "String(nowLp)"))();
          preVal = fieldN.value;
        } catch (e) { bad("the pre-policy handler (mutated copy) lifts", e.message); }
        check("negative control: the pre-policy handler (String(nowLp) in the field) fills \"990\" — the tap pin above reds on it, and G3d's write pin reds on its source",
          preVal === "990" && preVal !== "989.901", JSON.stringify(preVal));
      }
    }

    // M3 — cadence: the quote-only re-poll on the slow ticker while the Earn pane is on screen.
    const poll = funcBody(src, "async function refreshVaultLiquidity(");
    check("refreshVaultLiquidity exists (the quote-only re-poll)", poll !== null,
      "a cleared pend would re-enable only on a user-version bump or a tab re-entry");
    if (poll) {
      check("refreshVaultLiquidity is scoped to the signed-in Earn pane (currentTab === \"account\" && acctTab === \"earn\")",
        /currentTab\s*!==\s*"account"/.test(poll) && /acctTab\s*!==\s*"earn"/.test(poll) && /isAuthenticated/.test(poll),
        "an unguarded re-poll would query on every page for every viewer");
      check("refreshVaultLiquidity re-quotes getMaxInstantWithdraw and re-renders the disclosure + gate",
        /getMaxInstantWithdraw\(\)/.test(poll) && /renderVaultLiquidity\(liq\)/.test(poll));
      check("refreshVaultLiquidity keeps the last render on a failed re-quote (no blanking, no gate flap)",
        /if \(liq\) renderVaultLiquidity\(liq\)/.test(poll) && /catch/.test(poll));
      check("refreshVaultLiquidity cannot overlap itself (in-flight guard)",
        /_liqPollInFlight/.test(poll) && /finally/.test(poll));
    }
    const auto = funcBody(src, "function startAutoRefresh(");
    check("startAutoRefresh is extractable", auto !== null);
    if (auto) {
      const tick = auto.match(/setInterval\(\(\)\s*=>\s*\{[^}]*refreshVaultLiquidity\(\)[^}]*\},\s*(\d+)\)/);
      check("the slow ticker in startAutoRefresh calls refreshVaultLiquidity", tick !== null,
        "the re-poll is defined but never scheduled");
      if (tick) {
        check(`the ticker period is at most 10 s (got ${tick[1]} ms) — a cleared pend re-enables within one tick`,
          Number(tick[1]) <= 10000);
      }
    }

    // M4 — nothing else leaves it stuck.
    const lo = funcBody(src, "async function logout(");
    check("logout clears the gate with the rest of the identity-scoped state",
      lo !== null && /applyWithdrawPause\(document\.getElementById\("earn-vault-withdraw-btn"\),\s*null\)/.test(lo),
      "a pause belongs to the old identity's quote; the next sign-in must not inherit it");
    check("logout drops the Max button's stash with the gate (applyWithdrawMax(field, button, 0, null)) — the next sign-in must not fill the old identity's figure (task 1793553361)",
      lo !== null && /applyWithdrawMax\(document\.getElementById\("earn-vault-withdraw-input"\),\s*document\.getElementById\("earn-vault-withdraw-max"\),\s*0,\s*null\)/.test(lo),
      "the stash is identity-scoped state");
    const sites = readSiteStatements(src, "earn-vault-withdraw-btn");
    check("no statement that names the withdraw button writes `.disabled` directly (only applyWithdrawPause does)",
      sites.length > 0 && sites.every((t) => !/\.disabled\s*=/.test(t)),
      sites.filter((t) => /\.disabled\s*=/.test(t)).map((t) => t.slice(0, 120)).join("\n"));
    const withdraw = funcBody(src, "async function onVaultWithdraw(");
    check("onVaultWithdraw validates the amount on click (showEarnHint) rather than toggling the button — nothing to reconcile with the gate",
      withdraw !== null && /showEarnHint/.test(withdraw) && !/\.disabled/.test(withdraw));
  }

  // M5 — the markup, the demo stub, the contract.
  const html = must("src/frontend/index.html");
  if (html) {
    const iAt = html.indexOf('id="earn-vault-withdraw-input"');
    const mAt = html.indexOf('id="earn-vault-withdraw-max"');
    const bAt = html.indexOf('id="earn-vault-withdraw-btn"');
    check("index.html carries #earn-vault-withdraw-btn right after #earn-vault-withdraw-input, the one-tap Max between them (task 1793553361)",
      iAt >= 0 && mAt > iAt && bAt > mAt && bAt - iAt < 400, `input@${iAt} max@${mAt} btn@${bAt}`);
  }
  const demo = read("src/frontend/src/demo-mode.js");
  check("demo-mode.js either leaves getMaxInstantWithdraw unstubbed (the ?.() degrade applies) or stubs it WITH withdrawalPaused",
    demo !== null && (!/getMaxInstantWithdraw/.test(demo) || /withdrawalPaused/.test(demo)));
  const did = must("candid/backend.did");
  check("candid/backend.did: MaxInstantWithdraw carries withdrawalPaused : opt text",
    did !== null && /withdrawalPaused:\s*opt text;/.test(did));
}

// ── §N: the oracle card's staging window (1788636325) ───────────────────
// 1788558580 published PriceFeedStats.stagingWindowSec (the DEFERRED_EXPIRY
// window the fan-out deadline protects). §K pins that the IDL names it; this
// pins that the Status page's oracle stat block actually RENDERS it, beside
// the deadline it bounds, and only inside the fan-out-guarded stat (an older
// backend without the fan-out census renders neither).
{
  const rawMain = must("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);
  if (src) {
    // The header destructures its parameter (`({ feedStats, ... })`) — the
    // pre-1788637309 funcBody() returned that parameter list as the "body",
    // which is why this pin first shipped on a column-0 `\n}\n` slice. The
    // scanner now skips the parameter list, and section O's self-check
    // confirms the slice IS the body, so this is the one destructured-header
    // caller that keeps the fix honest in the live battery.
    const body = funcBody(src, "function renderStatsOracle(");
    check("renderStatsOracle's body is extractable from main.js", body !== null,
      "renderStatsOracle renamed — the two pins below are then asserting nothing");
    const quorumStat = body && (/<span class="oracle-k">Quorum<\/span>[^\n]*/.exec(body) || [])[0];
    check("renderStatsOracle's Quorum stat renders stagingWindowSec as '<n>s staging window' beside the '<n>s deadline'",
      !!quorumStat && /fanoutDeadlineSec\)\}s deadline/.test(quorumStat)
        && /Number\(feedStats\.stagingWindowSec\)\}s staging window/.test(quorumStat),
      quorumStat ? quorumStat.slice(0, 200) : "no Quorum stat found in renderStatsOracle");
    check("the staging-window fragment degrades to nothing when the field is absent (guarded on !== undefined, not rendered as 'NaNs')",
      !!quorumStat && /feedStats\.stagingWindowSec !== undefined \?/.test(quorumStat));
  }
}

// ── M2e (task 1793558036): the staged-LP poll finds a settled request, and a
// lingering "still staged" hint clears on the next render ────────────────────
// Observed on a seat venue (1793553361's smoke): a 1,000 ICPUSD Earn deposit
// minted within ~3 s, yet awaitStagedLp ran its twelve rounds and left "Your
// deposit is still staged …" under the minted position. Root cause: money.js's
// wrapActor listed depositLp in OK_MONEY — the 5.x immediate door's `#ok(nat)`
// — while since apiVersion 6.0.0 (task 1788731608) the door returns
// #ok(StagedLpRequest). fromE8 of a record is NaN, so onVaultDeposit read
// `Number(r.ok.id)` as NaN and the poll's `Number(o.id) === id` could never
// match; withdrawLp was never in the set, so only deposits lingered. And
// nothing ever cleared the hint. This block runs the REAL money boundary
// (money.js's wrapActor) and the lifted card functions over a fake document
// and a fake Candid-shaped actor:
//   - money.js: depositLp is NOT in OK_MONEY (source); wrapActor hands the
//     staged reply back with its id intact and its money legs scaled;
//   - awaitStagedLp: a `recent` entry carrying the awaited id → the settled
//     report, no hint; the window closing on a pending request → the hint,
//     carrying its request id as data-staged-lp-id on #earn-msg;
//   - renderVaultStaged: the id in `recent` → the settled report, the hint
//     gone; still pending → kept; in neither list → cleared silently; no
//     marker → the slot untouched; a plain hint or an action result drops it;
//   - onVaultDeposit end to end: 1,000 ICPUSD → "Settled: minted …";
//     negative control in the house style: a scratch money.js with depositLp
//     back in OK_MONEY runs the same leg into the "still staged" hint.
console.log("\nM2e. Earn card — a settled staged deposit is reported settled; a lingering \"still staged\" hint resolves on the next render (1793558036)");
{
  const rawMain = must("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);
  const rawMoney = must("src/frontend/src/money.js");
  const STILL_STAGED = /^Your deposit is still staged — it settles at the next fresh mark, and is cancelled and refunded automatically if none arrives within 5 minutes\.$/;
  const SETTLED_999 = "Settled: minted 999 LP at the post-request NAV.";

  // M2e.1 — the money boundary (source + the real module).
  const okSet = rawMoney === null ? null : /const OK_MONEY = new Set\(\[([^\]]*)\]\)/.exec(rawMoney);
  check("money.js: OK_MONEY is extractable", okSet !== null);
  if (okSet) {
    check("money.js: depositLp is NOT in OK_MONEY — since apiVersion 6.0.0 it returns #ok(StagedLpRequest), a record normMoney walks, not #ok(nat)",
      !/depositLp/.test(okSet[1]), okSet[1]);
    check("money.js: OK_MONEY still carries the two insurance doors (stakeInsurance, unstakeInsurance → #ok(nat))",
      /"stakeInsurance"/.test(okSet[1]) && /"unstakeInsurance"/.test(okSet[1]), okSet[1]);
    check("money.js: withdrawLp is not in OK_MONEY either (it was never the failure, and must not become one)", !/withdrawLp/.test(okSet[1]));
  }
  // Candid-decoded shapes, as the agent hands them to the wrapper: bigint
  // money and ids, `opt text` as [], the kind as a one-key variant object.
  const REQ = (id) => ({ id: BigInt(id), ts: 1n, expiresAt: 2n, waitingOn: ["BTC-ICPUSD"], cancelRefusal: [],
    kind: { deposit: { marketId: "BTC-ICPUSD", baseAmount: 0n, quoteAmount: 100_000_000_000n } } });
  const OUT = (id, outcome = { minted: 99_900_000_000n }) => ({ id: BigInt(id), kind: REQ(id).kind, ts: 1n, settledNs: 3n, outcome });
  const VIEW = (pending, recent) => ({ pending, recent });
  // A raw actor whose staged view ANSWERS IN SEQUENCE (the last answer
  // repeats); every answer is a fresh clone because normMoney scales in place.
  function rawActor(views, calls = []) {
    let i = 0;
    return {
      async depositLp(...args) { calls.push(["depositLp", ...args]); return { ok: REQ(7) }; },
      async getMyStagedLpRequests() { const v = views[Math.min(i++, views.length - 1)]; calls.push(["getMyStagedLpRequests"]); return structuredClone(v); },
    };
  }
  if (money) {
    const wrapped = money.wrapActor(rawActor([VIEW([], [OUT(7)])]));
    let reply = null, threw = null;
    try { reply = await wrapped.depositLp("BTC-ICPUSD", 0n, 100_000_000_000n); } catch (e) { threw = e; }
    check("the REAL wrapActor hands depositLp's #ok(StagedLpRequest) back as a record: ok.id is 7n and Number(ok.id) === 7",
      threw === null && reply && typeof reply.ok === "object" && reply.ok.id === 7n && Number(reply.ok.id) === 7,
      threw ? threw.message : JSON.stringify(reply, (k, v) => typeof v === "bigint" ? `${v}n` : v));
    check("… with the request's money legs scaled to human units (quoteAmount 1000) and its clock fields left bigint (ts, expiresAt)",
      reply && reply.ok && reply.ok.kind.deposit.quoteAmount === 1000 && reply.ok.kind.deposit.baseAmount === 0 && reply.ok.ts === 1n && reply.ok.expiresAt === 2n,
      reply && JSON.stringify(reply.ok, (k, v) => typeof v === "bigint" ? `${v}n` : v));
    let view = null;
    try { view = await wrapped.getMyStagedLpRequests(); } catch (e) { threw = e; }
    check("the wrapped staged view keeps recent[].id bigint (7n → Number 7) and scales outcome.minted to 999 LP",
      threw === null && view && view.recent[0].id === 7n && Number(view.recent[0].id) === 7 && view.recent[0].outcome.minted === 999,
      threw ? threw.message : JSON.stringify(view, (k, v) => typeof v === "bigint" ? `${v}n` : v));
    check("so the poll's lookup — recent.find(o => Number(o.id) === Number(reply.ok.id)) — finds the settled request",
      view && reply && view.recent.find((o) => Number(o.id) === Number(reply.ok.id)) !== undefined);
  } else {
    bad("money.js importable for the wrapActor cases", "money module missing");
  }

  // M2e.2 — the card functions, lifted over a fake document + the fake actor.
  // Nodes carry what the functions read and write ({style, dataset, textContent,
  // className, value, children}); createElement serves renderVaultStaged's
  // pending lines.
  function fakeDoc() {
    const nodes = new Map();
    const mk = (id) => {
      const n = { id, style: {}, dataset: {}, className: "", title: "", disabled: false, value: "", children: [], _text: "",
        appendChild(c) { this.children.push(c); return c; }, addEventListener() {} };
      // Writing textContent replaces every child, as the DOM does — renderVaultStaged clears its lines that way.
      Object.defineProperty(n, "textContent", { enumerable: true, get() { return this._text; }, set(v) { this._text = String(v); this.children.length = 0; } });
      return n;
    };
    return { nodes, getElementById(id) { if (!nodes.has(id)) nodes.set(id, mk(id)); return nodes.get(id); }, createElement(tag) { return mk(tag); } };
  }
  const bodies = src === null ? null : {
    await: funcBody(src, "async function awaitStagedLp("),
    report: funcBody(src, "function reportStagedLpOutcome("),
    settle: funcBody(src, "function settleStagedLpHint("),
    render: funcBody(src, "function renderVaultStaged("),
    msg: funcBody(src, "function showEarnMsg("),
    hint: funcBody(src, "function showEarnHint("),
    deposit: funcBody(src, "async function onVaultDeposit("),
  };
  check("awaitStagedLp, reportStagedLpOutcome, settleStagedLpHint, renderVaultStaged, showEarnMsg, showEarnHint and onVaultDeposit are extractable",
    bodies !== null && Object.values(bodies).every((b) => b !== null),
    bodies && Object.entries(bodies).filter(([, b]) => b === null).map(([k]) => k).join(", "));
  if (src) {
    check("showEarnHint's signature carries the marker: (text, stagedLpId = null, verb = \"\")",
      /function showEarnHint\(text, stagedLpId = null, verb = ""\)/.test(src));
    check("renderVaultStaged resolves a lingering hint FIRST (settleStagedLpHint(view) before the staged lines render)",
      bodies.render !== null && /^\{\s*settleStagedLpHint\(view\);/.test(bodies.render), bodies.render && bodies.render.slice(0, 80));
    check("awaitStagedLp's give-up hint carries the request id and verb (showEarnHint(`…still staged…`, id, verb))",
      bodies.await !== null && /showEarnHint\(`Your \$\{verb\} is still staged[^`]*`,\s*id,\s*verb\)/.test(bodies.await));
    check("awaitStagedLp reports a found outcome through reportStagedLpOutcome (one report path for the poll and the render)",
      bodies.await !== null && /reportStagedLpOutcome\(done,\s*verb\)/.test(bodies.await) && bodies.settle !== null && /reportStagedLpOutcome\(done,\s*verb\)/.test(bodies.settle));
    check("showEarnMsg drops the staged-hint marker with the slot it hides (delete el.dataset.stagedLpId)",
      bodies.msg !== null && /delete el\.dataset\.stagedLpId/.test(bodies.msg) && /display = "none"/.test(bodies.msg));
    const consts = /const STAGED_LP_POLL_MS = (\d+), STAGED_LP_POLL_ROUNDS = (\d+);/.exec(src);
    check("the poll window is at least 10 s (STAGED_LP_POLL_MS × STAGED_LP_POLL_ROUNDS) — settlement measured ~3 s on a ticking venue; the window was never the fault",
      consts !== null && Number(consts[1]) * Number(consts[2]) >= 10_000, consts && consts[0]);
    const dep = bodies.deposit;
    check("onVaultDeposit reads the awaited id from the staged reply (stagedId = Number(r.ok.id)) and hands it to awaitStagedLp(stagedId, \"deposit\")",
      dep !== null && /stagedId = Number\(r\.ok\.id\)/.test(dep) && /awaitStagedLp\(stagedId, "deposit"\)/.test(dep));
  }
  // The lift: every module-level name a body reads is injected by name, so
  // the behaviour under test is main.js's own text. `moneyMod` is the money
  // module whose wrapActor the leg runs through (the real one, or the scratch
  // copy of the negative control); toasts/hints record what the user sees.
  function lift(doc, moneyMod, { rounds = 3, pollMs = 1 } = {}) {
    const toasts = [], hints = [];
    const formatNum = (n) => String(n);
    const showEarnMsg = new Function("showToast", "document", "return function showEarnMsg(text, kind) " + bodies.msg)((t, k) => toasts.push([t, k]), doc);
    const hintRaw = new Function("document", 'return function showEarnHint(text, stagedLpId = null, verb = "") ' + bodies.hint)(doc);
    const showEarnHint = (...a) => { hints.push(a); return hintRaw(...a); };
    const report = new Function("showEarnMsg", "formatNum", "return function reportStagedLpOutcome(done, verb) " + bodies.report)(showEarnMsg, formatNum);
    const settle = new Function("document", "reportStagedLpOutcome", "return function settleStagedLpHint(view) " + bodies.settle)(doc, report);
    const render = new Function("document", "settleStagedLpHint", "onCancelStagedLp", "scheduleStagedLpRepoll",
      "return function renderVaultStaged(view) " + bodies.render)(doc, settle, () => {}, () => {});
    const appState = { actor: null };
    const awaitFn = new Function("appState", "STAGED_LP_POLL_MS", "STAGED_LP_POLL_ROUNDS", "reportStagedLpOutcome", "renderVaultStaged", "showEarnHint",
      "return async function awaitStagedLp(id, verb) " + bodies.await)(appState, pollMs, rounds, report, render, showEarnHint);
    const refreshes = { n: 0 };
    const deposit = new Function("document", "appState", "toE8", "showEarnMsg", "showEarnHint", "formatNum", "refreshAccountEarn", "awaitStagedLp",
      "return async function onVaultDeposit() " + bodies.deposit)(doc, appState, moneyMod.toE8, showEarnMsg, showEarnHint, formatNum, async () => { refreshes.n++; }, awaitFn);
    const slot = doc.getElementById("earn-msg");
    return { toasts, hints, appState, awaitFn, render, deposit, showEarnMsg, showEarnHint, slot, refreshes };
  }
  const liftable = bodies !== null && Object.values(bodies).every((b) => b !== null) && money !== null;
  if (liftable) {
    // (a) the poll finds the settled request.
    {
      const doc = fakeDoc();
      const L = lift(doc, money);
      const reads = [];
      L.appState.actor = money.wrapActor(rawActor([VIEW([REQ(7)], []), VIEW([], [OUT(7)])], reads));
      let threw = null;
      try { await L.awaitFn(7, "deposit"); } catch (e) { threw = e; }
      check("(a) awaitStagedLp(7): a `recent` entry carrying id 7 resolves the loop to the settled report — toast \"Settled: minted 999 LP at the post-request NAV.\"",
        threw === null && L.toasts.length === 1 && L.toasts[0][0] === SETTLED_999 && L.toasts[0][1] === "success",
        threw ? threw.message : JSON.stringify(L.toasts));
      check("(a) … and no \"still staged\" hint: showEarnHint was never called, the slot is hidden, no marker",
        L.hints.length === 0 && L.slot.style.display === "none" && L.slot.dataset.stagedLpId === undefined,
        JSON.stringify({ hints: L.hints, slot: L.slot }));
      check("(a) the loop stopped at the round that found the outcome (two staged-view reads, not twelve)",
        reads.filter((c) => c[0] === "getMyStagedLpRequests").length === 2, JSON.stringify(reads));
      check("(a) the staged line is empty after the outcome (the settled request is no longer pending)",
        doc.getElementById("earn-vault-staged").style.display === "none" && doc.getElementById("earn-vault-staged").children.length === 0);
    }
    // (a') a cancelled outcome and a redeemed outcome report as such (the two other arms).
    {
      const doc = fakeDoc();
      const L = lift(doc, money);
      L.appState.actor = money.wrapActor(rawActor([VIEW([], [OUT(7, { cancelled: "no fresh marks for BTC-ICPUSD within 300 s — the price feed stalled; nothing settled, funds released" })])]));
      await L.awaitFn(7, "deposit");
      check("(a') a #cancelled outcome → the error toast \"Staged deposit cancelled: no fresh marks … funds released\" (the fail-closed refund is still reported)",
        L.toasts.length === 1 && L.toasts[0][1] === "error" && /^Staged deposit cancelled: no fresh marks for BTC-ICPUSD within 300 s/.test(L.toasts[0][0]) && /funds released$/.test(L.toasts[0][0]),
        JSON.stringify(L.toasts));
      const L2 = lift(fakeDoc(), money);
      L2.appState.actor = money.wrapActor(rawActor([VIEW([], [OUT(8, { redeemed: { btc: 0n, eth: 0n, sol: 0n, icp: 0n, icpusd: 100_000_000_000n } })])]));
      await L2.awaitFn(8, "withdrawal");
      check("(a') a #redeemed outcome → \"Settled: redeemed at the post-request NAV for your basket share.\"",
        L2.toasts.length === 1 && L2.toasts[0][0] === "Settled: redeemed at the post-request NAV for your basket share." && L2.toasts[0][1] === "success", JSON.stringify(L2.toasts));
    }
    // (b) the window closes on a pending request → the hint, marked; a later render resolves it.
    const closeWindow = async () => {
      const doc = fakeDoc();
      const L = lift(doc, money, { rounds: 3 });
      L.appState.actor = money.wrapActor(rawActor([VIEW([REQ(7)], [])]));
      await L.awaitFn(7, "deposit");
      return { doc, L };
    };
    {
      const { doc, L } = await closeWindow();
      check("(b) three rounds of a still-pending request → exactly one hint, the fail-closed text verbatim, shown in #earn-msg",
        L.hints.length === 1 && STILL_STAGED.test(L.hints[0][0]) && L.slot.style.display === "block" && STILL_STAGED.test(L.slot.textContent) && L.toasts.length === 0,
        JSON.stringify({ hints: L.hints, slot: L.slot.textContent, toasts: L.toasts }));
      check("(b) the hint carries its request: data-staged-lp-id = \"7\", data-staged-lp-verb = \"deposit\"",
        L.slot.dataset.stagedLpId === "7" && L.slot.dataset.stagedLpVerb === "deposit", JSON.stringify(L.slot.dataset));
      check("(b) the staged line shows the pending request while the hint stands (\"Staged deposit #7 — settles at the next fresh mark (waiting on BTC-ICPUSD). \")",
        doc.getElementById("earn-vault-staged").children.length === 1 && doc.getElementById("earn-vault-staged").children[0].children[0].textContent === "Staged deposit #7 — settles at the next fresh mark (waiting on BTC-ICPUSD). ",
        JSON.stringify(doc.getElementById("earn-vault-staged").children.map((c) => c.children.map((g) => g.textContent))));
      // The later render: the Earn refresh / the user-version poll / the cancel re-poll all land here.
      let threw = null;
      try { L.render({ pending: [], recent: [{ id: 7n, kind: REQ(7).kind, ts: 1n, settledNs: 3n, outcome: { minted: 999 } }] }); } catch (e) { threw = e; }
      check("(b) a later renderVaultStaged with id 7 settled in `recent` → the settled toast, the hint hidden, the marker dropped",
        threw === null && L.toasts.length === 1 && L.toasts[0][0] === SETTLED_999 && L.slot.style.display === "none" && L.slot.dataset.stagedLpId === undefined && L.slot.dataset.stagedLpVerb === undefined,
        threw ? threw.message : JSON.stringify({ toasts: L.toasts, slot: L.slot }));
      L.render({ pending: [], recent: [{ id: 7n, kind: REQ(7).kind, ts: 1n, settledNs: 3n, outcome: { minted: 999 } }] });
      check("(b) the outcome is reported ONCE — a second render of the same view adds no toast", L.toasts.length === 1, JSON.stringify(L.toasts));
    }
    {
      const { L } = await closeWindow();
      L.render({ pending: [{ ...REQ(7), waitingOn: ["ETH-ICPUSD"] }], recent: [] });
      check("(b) a later render with id 7 STILL pending keeps the hint (shown, text intact, marker intact) and adds no toast",
        L.slot.style.display === "block" && STILL_STAGED.test(L.slot.textContent) && L.slot.dataset.stagedLpId === "7" && L.toasts.length === 0,
        JSON.stringify({ slot: L.slot, toasts: L.toasts }));
      L.render({ pending: [], recent: [{ id: 9n, kind: REQ(9).kind, ts: 1n, settledNs: 3n, outcome: { minted: 1 } }] });
      check("(b) a later render with id 7 in NEITHER list (evicted / another identity's view) clears the hint silently — hidden, emptied, marker dropped, no toast",
        L.slot.style.display === "none" && L.slot.textContent === "" && L.slot.dataset.stagedLpId === undefined && L.toasts.length === 0,
        JSON.stringify({ slot: L.slot, toasts: L.toasts }));
    }
    {
      const { L } = await closeWindow();
      L.render(null);
      check("(b) a render with NO view (a failed staged query) leaves the hint and its marker alone",
        L.slot.style.display === "block" && L.slot.dataset.stagedLpId === "7" && L.toasts.length === 0, JSON.stringify(L.slot));
      L.showEarnHint("Enter an LP amount to withdraw.");
      check("(b) a plain validation hint replaces the text and drops the marker (the slot no longer shows the staged hint)",
        L.slot.textContent === "Enter an LP amount to withdraw." && L.slot.dataset.stagedLpId === undefined && L.slot.dataset.stagedLpVerb === undefined, JSON.stringify(L.slot));
      L.render({ pending: [], recent: [{ id: 7n, kind: REQ(7).kind, ts: 1n, settledNs: 3n, outcome: { minted: 999 } }] });
      check("(b) … and a settled render then leaves that validation prompt untouched (no toast, prompt still shown)",
        L.slot.textContent === "Enter an LP amount to withdraw." && L.slot.style.display === "block" && L.toasts.length === 0, JSON.stringify({ slot: L.slot, toasts: L.toasts }));
    }
    {
      const { L } = await closeWindow();
      L.showEarnMsg("Withdrawal of 5 LP staged — settles at the next fresh mark.", "ok");
      check("(b) an action result (showEarnMsg) hides the slot AND drops the marker — a cancel's own toast is never followed by a second report",
        L.slot.style.display === "none" && L.slot.dataset.stagedLpId === undefined && L.toasts.length === 1, JSON.stringify({ slot: L.slot, toasts: L.toasts }));
      L.render({ pending: [], recent: [{ id: 7n, kind: REQ(7).kind, ts: 1n, settledNs: 3n, outcome: { cancelled: "cancelled by owner" } }] });
      check("(b) … so the render that follows adds nothing", L.toasts.length === 1, JSON.stringify(L.toasts));
    }
    {
      const doc = fakeDoc();
      const L = lift(doc, money);
      L.render({ pending: [], recent: [{ id: 7n, kind: REQ(7).kind, ts: 1n, settledNs: 3n, outcome: { minted: 999 } }] });
      check("(b) with no marker at all a settled render touches neither the slot nor the toasts (a fresh card)",
        doc.nodes.get("earn-msg").style.display === undefined && L.toasts.length === 0, JSON.stringify({ slot: doc.nodes.get("earn-msg"), toasts: L.toasts }));
    }
    // (c) end to end: onVaultDeposit through the REAL money boundary.
    {
      const doc = fakeDoc();
      const L = lift(doc, money);
      doc.getElementById("earn-vault-deposit-input").value = "1000";
      doc.getElementById("earn-vault-deposit-token").value = "ICPUSD";
      const calls = [];
      L.appState.actor = money.wrapActor(rawActor([VIEW([REQ(7)], []), VIEW([], [OUT(7)])], calls));
      let threw = null;
      try { await L.deposit(); } catch (e) { threw = e; }
      const dl = calls.find((c) => c[0] === "depositLp");
      check("(c) onVaultDeposit(1000 ICPUSD) through the real wrapActor: depositLp(\"BTC-ICPUSD\", 0n, 100000000000n) — the quote leg in base units",
        threw === null && dl !== undefined && dl[1] === "BTC-ICPUSD" && dl[2] === 0n && dl[3] === 100_000_000_000n,
        threw ? threw.message : JSON.stringify(calls, (k, v) => typeof v === "bigint" ? `${v}n` : v));
      check("(c) the leg ends in the settled report: toasts = [staged, \"Settled: minted 999 LP at the post-request NAV.\"], no hint, field cleared, the card refreshed twice (after staging and after the outcome)",
        L.toasts.length === 2 && L.toasts[0][0] === "Deposit of 1000 ICPUSD staged — settles at the next fresh mark." && L.toasts[1][0] === SETTLED_999 && L.hints.length === 0
          && doc.getElementById("earn-vault-deposit-input").value === "" && L.refreshes.n === 2,
        JSON.stringify({ toasts: L.toasts, hints: L.hints, refreshes: L.refreshes.n }));
    }
    // Negative control (house style): the pre-fix money boundary — depositLp
    // back in OK_MONEY — lifted from a scratch copy of money.js (a data: URL
    // import; nothing is written to the tree). The identical leg lingers.
    {
      const mutated = rawMoney.replace(/const OK_MONEY = new Set\(\[/, 'const OK_MONEY = new Set(["depositLp", ');
      check("negative control: the scratch money.js differs (depositLp re-listed in OK_MONEY)", mutated !== rawMoney && /OK_MONEY = new Set\(\["depositLp", /.test(mutated));
      let oldMoney = null;
      try { oldMoney = await import("data:text/javascript;base64," + Buffer.from(mutated).toString("base64")); }
      catch (e) { bad("negative control: the scratch money.js imports", e.message); }
      if (oldMoney) {
        const reply = await oldMoney.wrapActor(rawActor([])).depositLp("BTC-ICPUSD", 0n, 100_000_000_000n);
        check("negative control: the pre-fix wrapActor collapses the staged reply to { ok: NaN } — Number(reply.ok.id) is NaN (the M2e.1 pins above red on it)",
          typeof reply.ok === "number" && Number.isNaN(reply.ok) && Number.isNaN(Number(reply.ok?.id)), JSON.stringify(reply));
        const doc = fakeDoc();
        const L = lift(doc, oldMoney, { rounds: 3 });
        doc.getElementById("earn-vault-deposit-input").value = "1000";
        doc.getElementById("earn-vault-deposit-token").value = "ICPUSD";
        L.appState.actor = oldMoney.wrapActor(rawActor([VIEW([REQ(7)], []), VIEW([], [OUT(7)])]));
        await L.deposit();
        check("negative control: the same 1,000 ICPUSD leg through the pre-fix boundary runs every round past a SETTLED request and ends in the \"still staged\" hint — the (c) pin above tells the two apart",
          L.toasts.length === 1 && L.hints.length === 1 && STILL_STAGED.test(L.hints[0][0]) && Number.isNaN(L.hints[0][1]),
          JSON.stringify({ toasts: L.toasts, hints: L.hints }));
      }
    }
  }

  // M2f (task 1793560085) — a render generation: the newest renderEarnCard owns
  // the paint. Seen on a seat venue (1793558036's smoke): the card painted the
  // minted 999.01 LP at +5.5 s, then at +9.5 s REPAINTED LP 0.00 / $0.00 with
  // the pending "Staged deposit #111" line back — a render started BEFORE the
  // settlement (onVaultDeposit's first refreshAccountEarn, or pollChanges on the
  // staging bump) whose eight answers resolved AFTER the render started on the
  // settlement bump; renderEarnCard had no sequence guard, so the older paint
  // won. Now `let _earnRenderSeq = 0;` beside it, `const seq = ++_earnRenderSeq;`
  // as its first statement, and after the Promise.all `if (seq !==
  // _earnRenderSeq) return;` before any setText / renderVaultStaged. Starts are
  // never coalesced — a render started before a bump must never suppress the
  // one started after it — and refreshVaultLiquidity (the quote only, its own
  // in-flight latch) is untouched. Source pins, then the race run over the fake
  // document with a fake actor whose answers are DEFERRED per render: the first
  // render's set resolves after the second's and the card shows the second
  // render's LP and staged line; in the other order the earlier render paints
  // nothing either (a newer start exists — no stale flash) and the newer one
  // paints; a render started after both paints whatever it answers. Negative
  // control in the house style: the same race over a scratch copy of the body
  // with the guard line removed paints the first render's LP.
  console.log("\nM2f. Earn card — a slower, EARLIER renderEarnCard never overwrites a newer one (1793560085)");
  {
    const earnBody = src === null ? null : funcBody(src, "async function renderEarnCard(");
    check("renderEarnCard is extractable (M2f)", earnBody !== null, "function header moved?");
    const GUARD = /\n[ \t]*if \(seq !== _earnRenderSeq\) return;[^\n]*/;
    const DECL = "let _earnRenderSeq = 0;";
    if (src && earnBody) {
      const declAt = src.indexOf(DECL), fnAt = src.indexOf("async function renderEarnCard(");
      check("main.js declares the render generation ONCE, beside renderEarnCard: `let _earnRenderSeq = 0;` directly above `async function renderEarnCard(`",
        declAt >= 0 && src.indexOf(DECL, declAt + 1) < 0 && fnAt > declAt && /^\s*$/.test(src.slice(declAt + DECL.length, fnAt)),
        `decl@${declAt} fn@${fnAt}`);
      check("renderEarnCard takes its generation as its FIRST statement (const seq = ++_earnRenderSeq;) — before the early returns, before the queries",
        /^\{\s*const seq = \+\+_earnRenderSeq;/.test(earnBody), earnBody.slice(0, 120));
      const pa = earnBody.indexOf("await Promise.all([");
      const paEnd = pa < 0 ? -1 : earnBody.indexOf("]);", pa);
      const g = earnBody.search(GUARD);
      const paints = ["renderMarginRisk(", "renderVaultStaged(", "setText(", "renderVaultLiquidity("].map((s) => earnBody.indexOf(s)).filter((i) => i >= 0);
      check("after the Promise.all, BEFORE any paint (renderMarginRisk / renderVaultStaged / setText / renderVaultLiquidity): `if (seq !== _earnRenderSeq) return;` — a newer render has started, its answers are fresher",
        pa >= 0 && paEnd > pa && g > paEnd && paints.length === 4 && paints.every((i) => i > g),
        `Promise.all@${pa}..${paEnd} guard@${g} paints@${paints.join(",")}`);
      check("the guard appears exactly once, and the generation is TAKEN, never tested, before the queries go out (no coalescing — a start never suppresses a later start)",
        (earnBody.match(/_earnRenderSeq/g) || []).length === 2 && pa >= 0 && !/_earnRenderSeq/.test(earnBody.slice(earnBody.indexOf(";") + 1, pa)),
        (earnBody.match(/[^\n]*_earnRenderSeq[^\n]*/g) || ["no _earnRenderSeq in renderEarnCard"]).join("\n"));
      const liqBody = funcBody(src, "async function refreshVaultLiquidity(");
      check("refreshVaultLiquidity is untouched — the quote-only re-poll keeps its own in-flight latch (_liqPollInFlight) and never reads the render generation",
        liqBody !== null && /_liqPollInFlight/.test(liqBody) && !/_earnRenderSeq/.test(liqBody));
      check("_earnRenderSeq is referenced exactly three times in main.js: the declaration, the take, the compare",
        (src.match(/\b_earnRenderSeq\b/g) || []).length === 3, (src.match(/[^\n]*\b_earnRenderSeq\b[^\n]*/g) || ["none"]).join("\n"));

      // The lift: the real renderEarnCard over the fake document, painting
      // through the real setText / renderVaultStaged / settleStagedLpHint; the
      // generation lives in the factory's scope — ONE `let` the lifted function
      // closes over, as the module-level one is — so every call shares it. The
      // sub-renders not under test record their argument; console.warn (the
      // catch-all in renderEarnCard's try) is recorded so a lift fault cannot
      // pass as a quiet render.
      const setTextSrc = (/function setText\(id, txt\) (\{[^\n]*\})/.exec(src) || [])[1] || null;
      check("setText is extractable (the one-liner the card paints its figures through)", setTextSrc !== null);
      const EARN_QUERIES = ["getMyVaultPosition", "getVaultValue", "getMyInsuranceStake", "getInsuranceFund", "getVaultWeights", "getMarginRiskSummary", "getMaxInstantWithdraw", "getMyStagedLpRequests"];
      function liftRender(doc, body) {
        const calls = { risk: [], liq: [], warns: [] };
        const noop = () => {};
        const setText = new Function("document", "return function setText(id, txt) " + setTextSrc)(doc);
        const settle = new Function("document", "reportStagedLpOutcome", "return function settleStagedLpHint(view) " + bodies.settle)(doc, noop);
        const renderStaged = new Function("document", "settleStagedLpHint", "onCancelStagedLp", "scheduleStagedLpRepoll",
          "return function renderVaultStaged(view) " + bodies.render)(doc, settle, noop, noop);
        const appState = { actor: null };
        const render = new Function("document", "appState", "onVaultDeposit", "onVaultWithdraw", "onVaultWithdrawMax", "onInsuranceStake", "onInsuranceUnstake",
          "renderMarginRisk", "renderVaultStaged", "setText", "formatNum", "renderVaultLiquidity", "fmtUsd", "console",
          "let _earnRenderSeq = 0; return async function renderEarnCard() " + body)(
          doc, appState, noop, noop, noop, noop, noop,
          (r) => calls.risk.push(r), renderStaged, setText, (n) => String(n), (l) => calls.liq.push(l), (n) => "$" + n,
          { warn: (...a) => calls.warns.push(a.map(String).join(" ")) });
        return { render, appState, calls };
      }
      // An actor whose answers are DEFERRED: every query parks a resolver in the
      // set the test opened with begin(); settle(i, answers) resolves set i from
      // a table keyed by method — so the test chooses whose answers land first.
      function deferredActor() {
        const sets = []; let cur = -1; const actor = {};
        for (const name of EARN_QUERIES) actor[name] = () => new Promise((resolve) => sets[cur].push({ name, resolve }));
        return { actor, sets, begin() { cur = sets.length; sets.push([]); }, settle(i, answers) { for (const d of sets[i]) d.resolve(answers[d.name]); } };
      }
      // The two views as the render sees them past the money boundary: the
      // settled position (the newer render's answers — request #111 in `recent`)
      // and the pre-settlement one (the earlier, slower render's — LP 0, #111
      // still pending).
      const common = { getVaultValue: { valuePerLP: 1.0009 }, getMyInsuranceStake: { shares: 0, valueUsd: 0, unlockAtNs: 0n },
        getInsuranceFund: { shareValueUsd: 1, bufferUsd: 5000, pendingYieldUsd: 0 }, getVaultWeights: [], getMarginRiskSummary: null, getMaxInstantWithdraw: null };
      const SETTLED = { ...common, getMyVaultPosition: { lpBalance: 999.01, estimatedValue: 999.92, sharePercent: 0.0123 }, getMyStagedLpRequests: VIEW([], [OUT(111)]) };
      const STALE = { ...common, getMyVaultPosition: { lpBalance: 0, estimatedValue: 0, sharePercent: 0 }, getMyStagedLpRequests: VIEW([REQ(111)], []) };
      const PENDING_111 = "Staged deposit #111 — settles at the next fresh mark (waiting on BTC-ICPUSD). ";
      const card = (doc) => {
        const st = doc.getElementById("earn-vault-staged");
        return { lp: doc.getElementById("earn-vault-lp").textContent, value: doc.getElementById("earn-vault-value").textContent,
          stagedShown: st.style.display !== "none", staged: st.children.map((c) => c.children[0]?.textContent).join("|") };
      };
      // Two renders in flight; the first's answers land LAST.
      async function race(body) {
        const doc = fakeDoc(), L = liftRender(doc, body), D = deferredActor();
        L.appState.actor = D.actor;
        D.begin(); const first = L.render();    // started on the staging bump — pre-settlement answers, slow
        D.begin(); const second = L.render();   // started on the settlement bump — fresh answers, fast
        D.settle(1, SETTLED); await second;
        const afterSecond = card(doc);
        D.settle(0, STALE); await first;
        return { doc, L, D, afterSecond, afterFirst: card(doc) };
      }
      if (setTextSrc && bodies && bodies.settle && bodies.render) {
        const R = await race(earnBody);
        check("(race) both renders issued all eight queries — the second start was never skipped (no coalescing)",
          R.D.sets.length === 2 && R.D.sets[0].length === 8 && R.D.sets[1].length === 8, JSON.stringify(R.D.sets.map((s) => s.map((d) => d.name))));
        check("(race) the second render's answers land first: the card paints LP 999.01 / $999.92 and the staged line is hidden (request #111 settled)",
          R.afterSecond.lp === "999.01" && R.afterSecond.value === "$999.92" && !R.afterSecond.stagedShown && R.afterSecond.staged === "",
          JSON.stringify(R.afterSecond));
        check("(race) then the FIRST render's pre-settlement answers land — and the card is UNTOUCHED: LP still 999.01 / $999.92, staged line still hidden, no \"Staged deposit #111\" line",
          R.afterFirst.lp === "999.01" && R.afterFirst.value === "$999.92" && !R.afterFirst.stagedShown && R.afterFirst.staged === "",
          JSON.stringify(R.afterFirst));
        check("(race) the bailed render painted nothing at all — renderMarginRisk and renderVaultLiquidity ran once (for the newest), and renderEarnCard's catch logged nothing",
          R.L.calls.risk.length === 1 && R.L.calls.liq.length === 1 && R.L.calls.warns.length === 0, JSON.stringify(R.L.calls));
        // The other order — the earlier render's answers land FIRST while the
        // newer start is in flight: it paints nothing either. The newest START
        // owns the paint whichever order the answers land, so the card waits
        // for the newer render's answers instead of flashing the stale figures
        // and correcting; a render started after both finished is the newest,
        // whatever it answers — the guard compares starts, never figures.
        {
          const doc = fakeDoc(), L = liftRender(doc, earnBody), D = deferredActor();
          L.appState.actor = D.actor;
          D.begin(); const first = L.render();
          D.begin(); const second = L.render();
          D.settle(0, STALE); await first;
          const mid = card(doc);
          check("(order) the earlier render's answers land FIRST while the newer start is in flight: it paints nothing either — the card is left for the newer render (no stale flash, no correction), nothing warned",
            mid.lp === "" && mid.value === "" && mid.staged === "" && L.calls.risk.length === 0 && L.calls.warns.length === 0, JSON.stringify({ mid, calls: L.calls }));
          D.settle(1, SETTLED); await second;
          const end = card(doc);
          check("(order) … and the newer render then paints: LP 999.01 / $999.92, staged line hidden, the sub-renders run once",
            end.lp === "999.01" && end.value === "$999.92" && !end.stagedShown && end.staged === "" && L.calls.risk.length === 1 && L.calls.liq.length === 1, JSON.stringify({ end, calls: L.calls }));
          D.begin(); const third = L.render(); D.settle(2, STALE); await third;
          const later = card(doc);
          check("(order) a render started AFTER both finished is the newest and paints whatever it answers (here the pre-settlement view again): the rule is newest START wins, not largest figure",
            later.lp === "0" && later.stagedShown && later.staged === PENDING_111 && L.calls.warns.length === 0, JSON.stringify({ later, warns: L.calls.warns }));
        }
        // Negative control (house style): the same race over a scratch copy of
        // renderEarnCard's body with the guard line removed — nothing is written
        // to the tree. The slower, earlier render repaints the card.
        {
          const unguarded = earnBody.replace(GUARD, "");
          check("negative control: the scratch body differs (the guard line removed, the generation still taken)",
            unguarded !== earnBody && !GUARD.test(unguarded) && /const seq = \+\+_earnRenderSeq;/.test(unguarded));
          const N = await race(unguarded);
          check("negative control: without the guard the slower, EARLIER render repaints the card — LP 0 / $0 and the pending \"Staged deposit #111\" line back over the minted 999.01 (the (race) pins above tell the two apart)",
            N.afterSecond.lp === "999.01" && N.afterFirst.lp === "0" && N.afterFirst.value === "$0" && N.afterFirst.stagedShown && N.afterFirst.staged === PENDING_111 && N.L.calls.warns.length === 0,
            JSON.stringify({ afterSecond: N.afterSecond, afterFirst: N.afterFirst, warns: N.L.calls.warns }));
        }
      }
    }
  }
}

// ── §N2: the pools card's Repay control (1788533844, operator decision (i)) ──
// runLiquidationBatch does NOT reconcile idle pool debt; the owner's
// repayPoolDebt(poolId, token, amount) is the whole answer — it pays
// min(amount, debt, free) in kind (free = available − the resting-order
// earmark). So the pools UI carries a Repay row, rendered only while the
// pool owes anything: the figures (debt, free ICPUSD), an amount + a token,
// the min(amount, debt, free) preview, and a submit that is DISABLED while
// the preview is zero. Static pins on the render + handler statements and a
// behavioural pin on the pure preview function (liftable — no DOM).
// Task 1788730982: the figures are PER TOKEN from the view's `loans` /
// `repayable` (vec { token; amount } — accrued debt, and available − the
// resting earmark, per owed token: exactly repayPoolDebt's min() legs), so
// the preview is the backend's answer to the unit for a short's base debt
// too; the selector lists exactly the owed tokens; the older-backend
// fallback (fields absent) keeps the previous debtUsd/freeQuote shape.
console.log("\n§N2. Pools card — the owner's Repay control over repayPoolDebt");
{
  const rawMain = must("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);
  // N2.0 — the boundary: the nested vec-of-record `amount`s are MONEY_KEYS
  // leaves, so normMoney scales them like every sibling figure (behavioural,
  // through the real normaliser — §A's import).
  if (money) {
    const { E8: E, normMoney: nm } = money;
    const view = nm({
      id: 37n, freeQuote: 5n * BigInt(E), createdAt: 1_788_730_533_102_523_000n,
      health: { debtUsd: 10n * BigInt(E) },
      loans: [{ token: "ICPUSD", amount: 10n * BigInt(E) }, { token: "BTC", amount: 2n * BigInt(E) }],
      repayable: [{ token: "ICPUSD", amount: 3n * BigInt(E) }, { token: "BTC", amount: 50_000_000n }],
    });
    check("normMoney scales MarginPoolView.loans[].amount to human units (nested vec of records)",
      view.loans[0].amount === 10 && view.loans[1].amount === 2,
      `got ${String(view.loans[0].amount)} / ${String(view.loans[1].amount)}`);
    check("normMoney scales MarginPoolView.repayable[].amount too (3 ICPUSD, 0.5 BTC)",
      view.repayable[0].amount === 3 && view.repayable[1].amount === 0.5,
      `got ${String(view.repayable[0].amount)} / ${String(view.repayable[1].amount)}`);
    check("the token labels and the non-money ids survive untouched",
      view.loans[1].token === "BTC" && view.repayable[0].token === "ICPUSD" && view.id === 37n && view.createdAt === 1_788_730_533_102_523_000n);
    check("the sibling figures still normalise beside them (freeQuote, health.debtUsd)",
      view.freeQuote === 5 && view.health.debtUsd === 10);
  }
  if (src) {
    // N2.1 — the IDL names the method with (poolId, token, amount) and the
    // ok: Nat payload (the amount paid). §K holds the record shapes; this
    // holds the method the button drives, which §K would pass by silence
    // if it were missing (a method absent from the IDL is simply not called).
    const idlLines = src.split("\n").map((t, i) => ({ ln: i + 1, text: t.trim() })).filter((l) => /repayPoolDebt:/.test(l.text));
    check("the hand-written IDL declares repayPoolDebt(Nat, Text, Nat) -> variant { ok: Nat; err: Text }",
      /repayPoolDebt:\s*IDL\.Func\(\[IDL\.Nat, IDL\.Text, IDL\.Nat\], \[IDL\.Variant\(\{ ok: IDL\.Nat, err: IDL\.Text \}\)\], \[\]\)/.test(src),
      idlLines.map((l) => `${l.ln}: ${l.text.slice(0, 120)}`).join("\n") || "no repayPoolDebt in getIdlFactory");

    // N2.2 — the pool block renders the control only while the pool owes.
    const rows = funcBody(src, "function renderPoolsRows(");
    check("renderPoolsRows is extractable", rows !== null, "renamed — the Repay pins below assert nothing");
    if (rows) {
      check("renderPoolsRows figures the Repay row from the view (poolRepayFigures over loans/repayable, debtUsd/freeQuote as the fallback) and renders it only while a token is owed",
        /poolRepayFigures\(p, debt, free, list\)/.test(rows) && /repay\.tokens\.length \? poolRepayControlHTML\(id, repay\) : ""/.test(rows),
        "the Repay row must be gated on the pool owing something, figured per token");
    }
    // N2.2a — the figure resolver (1788730982): per owed token from the
    // view's loans/repayable; the older-backend fallback when absent. Pure —
    // lifted and run.
    const figsFn = funcBody(src, "function poolRepayFigures(");
    check("poolRepayFigures is extractable", figsFn !== null);
    if (figsFn) {
      check("poolRepayFigures reads the view's loans (owed tokens, amount > 0) and repayable (per token) — the exact figures",
        /Array\.isArray\(p\.loans\)/.test(figsFn) && /Number\(l\.amount\) > 0/.test(figsFn) && /rep\.get\(String\(l\.token\)\)/.test(figsFn));
      check("the older-backend fallback keeps ICPUSD from debtUsd/freeQuote plus the base of every SHORT (no figure)",
        /token: "ICPUSD", debt: debtUsd, free: freeQuote/.test(figsFn) && /Number\(x\.size\) < 0/.test(figsFn) && /debt: null, free: null/.test(figsFn));
      let ff = null;
      try { ff = new Function("return function poolRepayFigures(p, debtUsd, freeQuote, positions) " + figsFn)(); }
      catch (e) { bad("poolRepayFigures is liftable", e.message); }
      if (ff) {
        // Figures arrive pre-normalised (human Numbers) — as the wrapped actor hands them over.
        const long = ff({ loans: [{ token: "ICPUSD", amount: 9852.1 }], repayable: [{ token: "ICPUSD", amount: 3000 }] }, 9852.1, 3000, []);
        check("exact: a long's ICPUSD debt → one token, debt 9852.1, free 3000 (the view's repayable, not freeQuote)",
          long.exact === true && long.tokens.length === 1 && long.tokens[0].token === "ICPUSD" && long.tokens[0].debt === 9852.1 && long.tokens[0].free === 3000,
          JSON.stringify(long));
        const short = ff({ loans: [{ token: "BTC", amount: 2.0000004 }], repayable: [{ token: "BTC", amount: 0.5 }] }, 5010, 20000, [{ size: -2, baseToken: "BTC" }]);
        check("exact: a short lists its BASE token with the base figures — debtUsd/freeQuote are NOT consulted",
          short.exact === true && short.tokens.length === 1 && short.tokens[0].token === "BTC" && short.tokens[0].debt === 2.0000004 && short.tokens[0].free === 0.5,
          JSON.stringify(short));
        const two = ff({ loans: [{ token: "BTC", amount: 1 }, { token: "ICPUSD", amount: 400 }], repayable: [{ token: "BTC", amount: 0 }, { token: "ICPUSD", amount: 400 }] }, 0, 0, []);
        check("exact: two owed tokens → exactly those two, in the view's order, free 0 when nothing is free",
          two.tokens.map((t) => t.token).join(",") === "BTC,ICPUSD" && two.tokens[0].free === 0 && two.tokens[1].free === 400, JSON.stringify(two));
        const none = ff({ loans: [], repayable: [] }, 0, 5000, [{ size: -1, baseToken: "ETH" }]);
        check("exact: a debt-free pool → no tokens → no Repay row (even with a short's position listed)", none.tokens.length === 0, JSON.stringify(none));
        const zeroEntry = ff({ loans: [{ token: "ICPUSD", amount: 0 }], repayable: [{ token: "ICPUSD", amount: 100 }] }, 0, 100, []);
        check("exact: a zero-amount loan entry is not a debt (filtered)", zeroEntry.tokens.length === 0, JSON.stringify(zeroEntry));
        const missingRep = ff({ loans: [{ token: "ICPUSD", amount: 10 }] }, 10, 10, []);
        check("exact: a token absent from repayable reads as free 0 (never freeQuote)", missingRep.tokens[0].free === 0, JSON.stringify(missingRep));
        const old = ff({ health: { debtUsd: 500 }, freeQuote: 80 }, 500, 80, [{ size: -1, baseToken: "BTC" }, { size: 2, baseToken: "ETH" }]);
        check("fallback (fields absent): ICPUSD from debtUsd/freeQuote + the short's BTC with null figures; the long's ETH is not offered",
          old.exact === false && old.tokens.length === 2 && old.tokens[0].token === "ICPUSD" && old.tokens[0].debt === 500 && old.tokens[0].free === 80
            && old.tokens[1].token === "BTC" && old.tokens[1].debt === null, JSON.stringify(old));
        const oldFree = ff({ freeQuote: 80 }, 0, 80, []);
        check("fallback: no debt → no tokens", oldFree.tokens.length === 0, JSON.stringify(oldFree));
      }
    }
    const ctl = funcBody(src, "function poolRepayControlHTML(");
    check("poolRepayControlHTML is extractable", ctl !== null);
    const figsHtml = funcBody(src, "function poolRepayFigsHTML(");
    check("poolRepayFigsHTML is extractable", figsHtml !== null);
    if (figsHtml) {
      check("the figures line shows the selected token's Debt and Free, in that token's units (poolRepayFmt: fmtUsd for ICPUSD, fmtQty + token otherwise)",
        /pool-repay-debt/.test(figsHtml) && /pool-repay-free/.test(figsHtml) && /poolRepayFmt\(debt, token\)/.test(figsHtml) && /poolRepayFmt\(free, token\)/.test(figsHtml)
          && /function poolRepayFmt\(v, token\) \{ return token === "ICPUSD" \? fmtUsd\(v\) : `\$\{fmtQty\(v, token\)\} \$\{token\}`; \}/.test(src));
      check("a token without a figure (fallback base) shows a dash, never a zero that reads as 'nothing owed'", /has \? poolRepayFmt\(debt, token\) : "—"/.test(figsHtml));
    }
    if (ctl) {
      check("the Repay row renders the first owed token's figures (poolRepayFigsHTML over figs.tokens[0])",
        /pool-repay-figs/.test(ctl) && /poolRepayFigsHTML\(first\.token, first\.debt, first\.free\)/.test(ctl) && /const first = figs\.tokens\[0\]/.test(ctl));
      check("the Repay row carries an amount input, a token select, a preview and the submit",
        /pool-repay-amt/.test(ctl) && /pool-repay-token/.test(ctl) && /pool-repay-preview/.test(ctl) && /pool-repay-btn/.test(ctl));
      check("the submit renders DISABLED (the preview starts at zero)",
        /pool-repay-btn" data-pool="\$\{id\}" type="button" disabled>Repay</.test(ctl));
      check("the token select lists exactly the figured (owed) tokens, each option carrying ITS debt/free from the view",
        /figs\.tokens\.map\(\(t\) => `<option value="\$\{escH\(t\.token\)\}"/.test(ctl) && /data-debt="\$\{t\.debt\}" data-free="\$\{t\.free\}"/.test(ctl)
          && /t\.debt == null \? "" :/.test(ctl));
      check("the row tells the owner the doctrine (the liquidation pass never repays; Fund is margin, not repayment; min(amount, debt, free))",
        /the liquidation pass never repays it/.test(ctl) && /Fund is margin, not repayment/.test(ctl) && /min\(amount, debt, free\)/.test(ctl));
      // loans/repayable/debtUsd/freeQuote arrive pre-normalised (MONEY_KEYS): no e8 math here.
      check("the Repay row does not e8-downscale the pre-normalised figures", !DOWNSCALES_E8.test(ctl) && !(figsFn && DOWNSCALES_E8.test(figsFn)));
    }

    // N2.3 — the preview is min(amount, debt, free), zero when any leg is
    // missing; lifted out of main.js and run (it is pure).
    const pv = funcBody(src, "function poolRepayPreview(");
    check("poolRepayPreview is extractable", pv !== null);
    if (pv) {
      let fn = null;
      try { fn = new Function("return function poolRepayPreview(amount, debt, free) " + pv)(); }
      catch (e) { bad("poolRepayPreview is liftable", e.message); }
      if (fn) {
        check("preview: amount below debt and free pays the amount (50, 1000, 1000) → 50", fn(50, 1000, 1000) === 50, `got ${fn(50, 1000, 1000)}`);
        check("preview: capped by the debt (500, 200, 1000) → 200", fn(500, 200, 1000) === 200, `got ${fn(500, 200, 1000)}`);
        check("preview: capped by the free cash (500, 1000, 100) → 100", fn(500, 1000, 100) === 100, `got ${fn(500, 1000, 100)}`);
        check("preview: nothing free pays nothing (500, 1000, 0) → 0", fn(500, 1000, 0) === 0, `got ${fn(500, 1000, 0)}`);
        check("preview: no amount pays nothing (0, 1000, 1000) → 0 and NaN → 0", fn(0, 1000, 1000) === 0 && fn(NaN, 1000, 1000) === 0);
        check("preview: a negative amount pays nothing", fn(-5, 1000, 1000) === 0);
      }
    }
    const upd = funcBody(src, "function updatePoolRepayPreview(");
    check("updatePoolRepayPreview is extractable", upd !== null);
    if (upd) {
      check("the preview is poolRepayPreview(amount, debt, free) over the SELECTED option's per-token figures (any owed token, not only ICPUSD)",
        /poolRepayPreview\(amt, debt, free\)/.test(upd) && /opt\.dataset\.debt/.test(upd) && /opt\.dataset\.free/.test(upd)
          && /sel\.options\[sel\.selectedIndex\]/.test(upd) && /poolRepayFmt\(pay, token\)/.test(upd));
      check("switching the token re-renders the figures line for that token (poolRepayFigsHTML)",
        /figs\.innerHTML = poolRepayFigsHTML\(token, hasFigs \? debt : null, hasFigs \? free : null\)/.test(upd));
      check("the submit is disabled while the preview is zero [structure pin]",
        /btn\.disabled = !\(pay > 0\)/.test(upd),
        "a click must never reach the backend with nothing to pay");
      check("a token without a figure (older backend, a short's base) still degrades honestly ('up to' + the backend's min)",
        /Will pay up to/.test(upd) && /min\(amount, debt, free\) at the backend/.test(upd) && /btn\.disabled = !\(amt > 0\)/.test(upd));
    }

    // N2.4 — the handler: the call site is repayPoolDebt(poolId, token,
    // amount) in that order, #err is surfaced verbatim, and a success
    // refreshes the pool view + balances (the debt figure must move).
    const h = funcBody(src, "async function onRepayPoolDebt(");
    check("onRepayPoolDebt is extractable", h !== null);
    if (h) {
      check("the call site is repayPoolDebt(BigInt(poolId), String(token), toE8(amount)) — (poolId, token, amount)",
        /appState\.actor\.repayPoolDebt\(BigInt\(Number\(p\.id\)\), String\(token\), toE8\(amt\)\)/.test(h));
      check("the #err text is surfaced verbatim as the refusal", /if \("err" in res\) return posMsg\(res\.err, "err"\)/.test(h));
      check("the ok payload (raw e8 amount paid) is scaled with fromE8, not left as e8", /fromE8\(res\.ok\)/.test(h));
      check("a success re-renders the pools card and the balances", /renderPositions\(\)/.test(h) && /refreshBalances\(\)/.test(h));
      check("a zero amount is refused client-side too", /if \(!\(amt > 0\)\) return posMsg/.test(h));
    }
    // The delegated wiring on the stable container (rows re-render).
    const wire = funcBody(src, "function wirePositionActions(");
    check("wirePositionActions is extractable", wire !== null);
    if (wire) {
      check("the Repay click is delegated on #pools-rows and reads amount + token from the row",
        /closest\("\.pool-repay-btn"\)/.test(wire) && /onRepayPoolDebt\(rp\.dataset\.pool, token, amt\)/.test(wire));
      check("input/change on a Repay row recomputes the preview + gate",
        /\["input", "change"\]/.test(wire) && /updatePoolRepayPreview\(row\)/.test(wire));
    }
  }
  // N2.5 — the doctrine reaches the help text and the assistant's tool list.
  const docs = must("src/frontend/src/docs.js");
  check("docs.js margin page explains the Repay row (owner retires idle debt; the liquidation pass never repays; Fund is margin, not repayment)",
    docs !== null && /Idle debt is yours to retire/.test(docs) && /liquidation pass never repays/.test(docs)
      && /<i>Fund<\/i> is margin, not repayment/.test(docs) && /<code>repayPoolDebt<\/code>/.test(docs)
      && /min\(amount, debt, free\)/.test(docs));
  const asst = must("src/frontend/src/assistant.js");
  check("assistant.js exposes repayPoolDebt(poolId, token, amount) as a tool",
    asst !== null && /repayPoolDebt: \{/.test(asst) && /appState\.actor\.repayPoolDebt\(BigInt\(a\.poolId\), String\(a\.token \|\| "ICPUSD"\), toE8\(a\.amount\)\)/.test(asst));
  const css = must("src/frontend/src/styles/stats.css");
  check("stats.css styles the Repay row (.pool-repay + its preview/note)",
    css !== null && /\.pool-repay \{/.test(css) && /\.pool-repay-preview/.test(css) && /\.pool-repay-note/.test(css));
  // The frontend's story matches the backend's published one.
  const did = must("candid/backend.did");
  check("candid/backend.did publishes repayPoolDebt(poolId: nat, token: TokenId, amount: nat) -> variant { err: text; ok: nat }",
    did !== null && /repayPoolDebt: \(poolId: nat, token: TokenId, amount: nat\) ->\s*\(variant \{\s*err: text;\s*ok: nat;\s*\}\)/.test(did));
  // 1788730982: the view publishes the per-token figures the row reads
  // (§K holds that the IDL names them; this holds that the .did HAS them).
  const mpv = did === null ? null : /type MarginPoolView =\s*record \{([\s\S]*?)\};/.exec(did);
  check("candid/backend.did MarginPoolView publishes loans: vec TokenAmount and repayable: vec TokenAmount (TokenAmount = record { amount: nat; token: TokenId })",
    mpv !== null && /loans: vec TokenAmount;/.test(mpv[1]) && /repayable: vec TokenAmount;/.test(mpv[1])
      && /type TokenAmount =\s*record \{\s*amount: nat;\s*token: TokenId;\s*\};/.test(did),
    mpv ? mpv[1].trim().slice(0, 300) : "MarginPoolView not found in the .did");
  check("docs.js says the figures are per token and the selector lists exactly what the pool owes",
    docs !== null && /Debt and Free figures are per token/.test(docs) && /a short's debt is its base token/.test(docs));
}

// ── §N3: the Earn card's staged-LP Cancel affordance (1788731609) ────────
// A staged LP request may be withdrawn by its owner only under the
// staged-order commit rule (3 s commit + the fetch-bound lock). The backend
// publishes the verdict on the request view as `cancelRefusal : opt text`
// (null = cancellable now); the card renders one Cancel button per pending
// request, DISABLED with that exact text while it holds, and the click
// drives cancelStagedLpRequest. §K holds the IDL to the .did; this holds
// that the affordance exists, follows the published verdict rather than a
// re-derived rule, and that the contract carries both halves.
{
  const rawMain = must("src/frontend/src/main.js");
  const src = rawMain === null ? null : stripJsComments(rawMain);
  if (src) {
    const body = funcBody(src, "function renderVaultStaged(");
    check("renderVaultStaged's body is extractable from main.js", body !== null,
      "renderVaultStaged renamed — the pins below are then asserting nothing");
    if (body) {
      check("renderVaultStaged renders a Cancel button per pending request (class earn-staged-cancel, data-staged-id)",
        /createElement\("button"\)/.test(body) && /earn-staged-cancel/.test(body) && /dataset\.stagedId\s*=\s*String\(p\.id\)/.test(body));
      check("the button's disabled state is the backend's cancelRefusal (opt text → [] | [text]), never a client-side clock",
        /Array\.isArray\(p\.cancelRefusal\)\s*\?\s*\(p\.cancelRefusal\[0\]\s*\?\?\s*null\)\s*:\s*null/.test(body)
          && /btn\.disabled\s*=\s*refusal\s*!==\s*null/.test(body)
          && !/Date\.now\(\)|\.ts\b/.test(body),
        "the rule lives in stagedLpCancelReason; the UI must follow the published verdict");
      check("the refusal text is shown while the button is disabled (title + an earn-staged-refusal span)",
        /btn\.title\s*=\s*refusal\s*\?\?/.test(body) && /earn-staged-refusal/.test(body) && /why\.textContent\s*=\s*` \$\{refusal\}`/.test(body));
      check("a showing refusal arms one re-poll so the button unlocks without a manual refresh",
        /if \(locked\) scheduleStagedLpRepoll\(\)/.test(body));
      check("the click drives onCancelStagedLp with the request id", /onCancelStagedLp\(Number\(p\.id\),\s*kind\)/.test(body));
    }
    const handler = funcBody(src, "async function onCancelStagedLp(");
    check("onCancelStagedLp calls actor.cancelStagedLpRequest(id) and surfaces ok / err on the card, then refreshes",
      handler !== null && /appState\.actor\.cancelStagedLpRequest\(id\)/.test(handler)
        && /"ok" in r/.test(handler) && /showEarnMsg\(r\.err, "err"\)/.test(handler) && /refreshAccountEarn\(\)/.test(handler));
    const repoll = funcBody(src, "function scheduleStagedLpRepoll(");
    check("scheduleStagedLpRepoll re-reads getMyStagedLpRequests once (deduplicated timer, ≤ 3 s)",
      repoll !== null && /getMyStagedLpRequests\(\)/.test(repoll) && /if \(stagedLpRepollTimer\) return/.test(repoll)
        && (() => { const m = /\},\s*(\d+)\);/.exec(repoll); return m !== null && Number(m[1]) <= 3000; })());
    check("the IDL names cancelStagedLpRequest(nat) -> variant { ok; err: text } and StagedLpRequest.cancelRefusal: opt text",
      /cancelStagedLpRequest:\s*IDL\.Func\(\[IDL\.Nat\],\s*\[IDL\.Variant\(\{\s*ok:\s*IDL\.Null,\s*err:\s*IDL\.Text\s*\}\)\],\s*\[\]\)/.test(src)
        && /cancelRefusal:\s*IDL\.Opt\(IDL\.Text\)/.test(src));
  }
  const did = must("candid/backend.did");
  check("candid/backend.did publishes cancelStagedLpRequest: (requestId: nat) -> (variant { err: text; ok })",
    did !== null && /cancelStagedLpRequest: \(requestId: nat\) ->\s*\(variant \{\s*err: text;\s*ok;\s*\}\)/.test(did));
  const slr = did === null ? null : /type StagedLpRequest =\s*record \{([\s\S]*?)\};/.exec(did);
  check("candid/backend.did StagedLpRequest carries cancelRefusal: opt text (additive)",
    slr !== null && /cancelRefusal: opt text;/.test(slr[1]), slr ? slr[1].trim().slice(0, 200) : "StagedLpRequest not found in the .did");
  const docs = read("src/frontend/src/docs.js");
  check("docs.js (Earn) says a staged request can be cancelled under the same commit rule as a staged order",
    docs !== null && /cancel a staged request/.test(docs) && /not in its first\s+3 seconds/.test(docs) && /price fetch started after your request/.test(docs));
}

// ── §N3: Intelligence tabs — "Agent Chat" + the canonical #ai/agent-chat slug (1793489927) ──
// Operator instruction 2026-11-01: the AI → Assistant sub-tab is "Agent Chat".
// The URL slug moved with the label — `agent-chat` is canonical, the spelling
// the app WRITES (the nav click via TAB_DEFAULT_SUB, syncHashToState via
// INTELLI_TOKEN_TO_SLUG, the explorer's Ask-AI jump, a tab click via the
// button's data-intelli) — and `assistant` stays accepted as a LEGACY ALIAS:
// deep links in posted public comments and older docs name it, and a rename
// that dropped it would hand every one of them to the Memory Explorer (or the
// section default) without a word. The three routing maps are object
// literals, so they are EVALUATED here: the alias pin is a statement about
// the routing table, not a regex over a comment that could outlive the code.
console.log("\n§N3. Intelligence tabs — the Agent Chat label, the canonical #ai/agent-chat slug, the legacy assistant alias");
{
  const stripHtml = (s) => s.replace(/<!--[\s\S]*?-->/g, "");
  const rawHtml = must("src/frontend/index.html");
  const html = rawHtml === null ? null : stripHtml(rawHtml);
  const rawMain = must("src/frontend/src/main.js");
  const main = rawMain === null ? null : stripJsComments(rawMain);
  const rawExp = must("src/frontend/src/explorer.js");
  const exp = rawExp === null ? null : stripJsComments(rawExp);
  const docs = must("src/frontend/src/docs.js");

  // N3.1 — the label, and the button's slug attribute (a tab click writes
  // #ai/<data-intelli>, so the attribute IS the slug the user ends up on).
  let btnSlug = null;
  if (html) {
    const m = /<button class="intelli-tab[^"]*" data-intelli="([^"]+)">Agent Chat<\/button>/.exec(html);
    check("index.html: the chat tab button is labelled \"Agent Chat\"", m !== null);
    btnSlug = m ? m[1] : null;
    check("index.html: the chat tab's data-intelli is the canonical slug agent-chat (a tab click writes #ai/<data-intelli>)",
      btnSlug === "agent-chat", `data-intelli="${btnSlug}"`);
    check("index.html: no tab button still carries data-intelli=\"assistant\" or the old \"Assistant\" label",
      !/data-intelli="assistant"/.test(html) && !/>Assistant<\/button>/.test(html));
    check("index.html: the Memory Explorer tab is untouched (data-intelli=\"memory\")",
      /<button class="intelli-tab[^"]*" data-intelli="memory">Memory Explorer<\/button>/.test(html));
    // N3.2 — the user-facing copy names the feature by its new name.
    const at = (id) => { const i = html.indexOf(`id="${id}"`); return i < 0 ? "" : html.slice(i, i + 700); };
    check("index.html: the Account → AI usage intro reads \"Agent Chat\" (not \"AI Assistant\")",
      /Agent Chat/.test(at("acct-pane-ai")) && !/AI Assistant/.test(at("acct-pane-ai")));
    check("index.html: the signed-out gate says Agent Chat and the memory explorer answer as you",
      /Agent Chat and the memory explorer answer as <em>you<\/em>/.test(at("intelli-signin-prompt")));
    check("index.html: the explorer's Ask AI button title sends the query to Agent Chat",
      /id="dx-ask-ai"[^>]*title="Send this query to Agent Chat to run and interpret"/.test(html));
    check("index.html: no user-facing \"AI Assistant\" remains (comments stripped; the AI usage tab label stays \"AI usage\")",
      !/AI Assistant/.test(html));
  }

  // N3.3 — the routing table, evaluated.
  const lit = (name) => {
    if (!main) return null;
    const m = new RegExp(`const ${name} = (\\{[^}]*\\});`).exec(main);
    if (!m) return null;
    try { return new Function(`return ${m[1]};`)(); } catch { return null; }
  };
  const DEF = lit("TAB_DEFAULT_SUB"), S2T = lit("INTELLI_SLUG_TO_TOKEN"), T2S = lit("INTELLI_TOKEN_TO_SLUG");
  check("main.js: TAB_DEFAULT_SUB / INTELLI_SLUG_TO_TOKEN / INTELLI_TOKEN_TO_SLUG are extractable object literals",
    DEF !== null && S2T !== null && T2S !== null);
  if (DEF && S2T && T2S) {
    check("the nav click lands on #ai/agent-chat (TAB_DEFAULT_SUB.intelli is the canonical slug)",
      DEF.intelli === "agent-chat", `intelli: ${DEF.intelli}`);
    check("the app writes the canonical slug for the chat (INTELLI_TOKEN_TO_SLUG.ai === \"agent-chat\")",
      T2S.ai === "agent-chat", `ai: ${T2S.ai}`);
    check("the canonical slug resolves to the chat (INTELLI_SLUG_TO_TOKEN[\"agent-chat\"] === \"ai\")", S2T["agent-chat"] === "ai");
    check("LEGACY ALIAS: #ai/assistant still resolves to the chat (INTELLI_SLUG_TO_TOKEN.assistant === \"ai\")", S2T.assistant === "ai",
      "deep links in posted public comments and older docs name #ai/assistant — the alias must stay");
    check("the memory slug is untouched both ways", S2T.memory === "explorer" && T2S.explorer === "memory");
    check("every slug the app writes resolves back to the token it was written for (round trip)",
      Object.entries(T2S).every(([tok, slug]) => S2T[slug] === tok));
    check("the legacy alias is never WRITTEN (no INTELLI_TOKEN_TO_SLUG value is \"assistant\")",
      !Object.values(T2S).includes("assistant"));
    check("the button's data-intelli is a slug the routing table resolves to the chat", btnSlug !== null && S2T[btnSlug] === "ai");
  }
  if (main) {
    // N3.4 — the alias is normalised on the way in, and the gate's selector
    // moved with the button attribute.
    const act = funcBody(main, "function activateTab(");
    check("activateTab is extractable", act !== null);
    if (act) {
      check("activateTab rewrites a legacy sub-slug to the canonical spelling in place (replaceState — no hashchange, no history entry)",
        /const canon = INTELLI_TOKEN_TO_SLUG\[tok\]/.test(act)
          && /INTELLI_SLUG_TO_TOKEN\[subpath\] === tok && subpath !== canon/.test(act)
          && /window\.history\.replaceState\(null, "", `#ai\/\$\{canon\}`\)/.test(act));
    }
    const gate = funcBody(main, "async function refreshAiGate(");
    check("refreshAiGate is extractable", gate !== null);
    if (gate) {
      check("refreshAiGate shows/hides the button by the SAME data-intelli the markup carries (agent-chat)",
        btnSlug !== null && gate.includes(`.intelli-tab[data-intelli="${btnSlug}"]`) && gate.includes('.intelli-tab[data-intelli="agent-chat"]'),
        "the gate selector and the button attribute move together — a mismatch hides nothing, and the chat tab shows with no key configured");
    }
    check("main.js: no code path still writes or matches the literal \"ai/assistant\"", !/["'`]ai\/assistant["'`]/.test(main));
  }
  if (exp) {
    const ask = funcBody(exp, "function dxAskAi(");
    check("dxAskAi is extractable", ask !== null);
    if (ask) check("explorer.js: the Ask-AI jump writes the canonical #ai/agent-chat", /window\.location\.hash = "ai\/agent-chat"/.test(ask));
    const setup = funcBody(exp, "export function setupIntelli(");
    check("setupIntelli is extractable", setup !== null);
    if (setup) check("explorer.js: a tab click writes #ai/<data-intelli> (so the button attribute IS the slug)",
      /window\.location\.hash = "ai\/" \+ b\.dataset\.intelli/.test(setup));
    check("explorer.js: no code path still writes the literal \"ai/assistant\"", !/["'`]ai\/assistant["'`]/.test(exp));
  }
  check("docs.js: the docs name the feature Agent Chat (\"<b>Agent Chat</b> drives that same query surface\"), never \"<b>AI Assistant</b>\"",
    docs !== null && /<b>Agent Chat<\/b> drives that same query surface/.test(docs) && !/<b>AI Assistant<\/b>/.test(docs));
}

// ── §P: the light theme — two token tables, the pre-paint bootstrap, the toggle, no literal outside base.css (1793489931) ──
// Operator instruction 2026-11-01: "Add a light mode, and put the light/dark
// theme icon top/right." The architecture these pins hold in place: base.css
// carries TWO token tables (the bare :root is the dark set — the app is
// dark-first — and :root[data-theme="light"] the light set, each declaring
// its color-scheme); every other stylesheet and every JS colour reader (the
// lightweight-charts options, the depth bars, the liquidation heat map, the
// identicon) consumes TOKENS only; /theme-boot.js — a classic, render-
// blocking <head> script ahead of the stylesheet, because the CSP's
// script-src 'self' forbids an inline block — stamps data-theme on <html>
// before the first paint; theme.js owns the sun/moon toggle, localStorage
// "mdx.theme", and following prefers-color-scheme until the user picks.
// None of the drifts pinned here throws: a literal cyan in a stylesheet
// renders perfectly on the dark theme and only reads wrong on the light
// one, a chart skinned at creation simply stays dark after a toggle, and a
// bootstrap moved below the stylesheet "works" with a flash on every reload.
console.log("\n§P. light theme — two token tables, the pre-paint bootstrap, the toggle, no colour literal outside base.css");
{
  const stripCss = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "");
  const stripHtml = (s) => s.replace(/<!--[\s\S]*?-->/g, "");
  const base = must("src/frontend/src/styles/base.css");
  const rawHtml = must("src/frontend/index.html");
  const html = rawHtml === null ? null : stripHtml(rawHtml);
  const boot = must("src/frontend/public/theme-boot.js");
  const rawTheme = must("src/frontend/src/theme.js");
  const theme = rawTheme === null ? null : stripJsComments(rawTheme);
  const rawMain = must("src/frontend/src/main.js");
  const main = rawMain === null ? null : stripJsComments(rawMain);
  const rawIdent = must("src/frontend/src/identicon.js");
  const ident = rawIdent === null ? null : stripJsComments(rawIdent);
  const headerCss = must("src/frontend/src/styles/header.css");
  const respCss = must("src/frontend/src/styles/responsive.css");
  const barrel = must("src/frontend/src/styles.css");
  const docs = must("src/frontend/src/docs.js");

  // P1 — the two token tables. A table has no nested braces, so the first
  // `}` after its opener closes it.
  const block = (css, opener) => {
    const at = css.indexOf(opener);
    if (at < 0) return null;
    const end = css.indexOf("}", at);
    return end < 0 ? null : css.slice(at + opener.length, end);
  };
  const baseCss = base === null ? null : stripCss(base);
  const dark = baseCss && block(baseCss, ":root {");
  const light = baseCss && block(baseCss, ':root[data-theme="light"] {');
  const token = (blk, name) => {
    if (!blk) return null;
    const m = new RegExp(`(^|\\s)${name}:\\s*([^;]+);`).exec(blk);
    if (!m) return null;
    const v = m[2].trim();
    const ref = /^var\((--[\w-]+)\)$/.exec(v);           // one level of indirection (--cta-ink: var(--cta))
    return ref ? token(blk, ref[1]) : v;
  };
  check("base.css: the bare :root block is the dark token table (--bg #10151D) and declares color-scheme: dark",
    !!dark && /color-scheme:\s*dark;/.test(dark) && /^#10151D$/i.test(token(dark, "--bg") || ""));
  check("base.css: :root[data-theme=\"light\"] is the light token table and declares color-scheme: light",
    !!light && /color-scheme:\s*light;/.test(light));
  const MUST_RESTATE = ["--bg", "--bg-card", "--bg-input", "--bg-hover", "--border", "--accent", "--accent-hover",
    "--accent-text", "--cta-ink", "--text", "--text-dim", "--text-muted", "--green", "--green-text", "--red", "--red-text",
    "--glacier", "--glacier-text", "--heather", "--shadow", "--chart-text", "--chart-grid", "--chart-border", "--chart-up",
    "--chart-down", "--chart-track", "--depth-bid-edge", "--depth-ask-edge", "--heat-0", "--heat-7", "--heat-mark"];
  const missing = MUST_RESTATE.filter((n) => !token(light, n));
  check("base.css: the light table restates every surface, text, accent, semantic, shadow, chart, depth and heat token",
    missing.length === 0, `missing: ${missing.join(", ")}`);

  // P2 — the contrast bars the dark set documents (primary ~13:1, secondary
  // ~5.7:1, tertiary ~4.5:1 on --bg-card), applied to BOTH tables, plus
  // every colour the stylesheets use as TEXT, plus each filled control's ink.
  const lum = (hex) => {
    const h = hex.replace("#", "");
    const full = h.length === 3 ? h.split("").map((c) => c + c).join("") : h;
    const c = [0, 2, 4].map((i) => parseInt(full.slice(i, i + 2), 16) / 255)
      .map((v) => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)));
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  };
  const contrast = (a, b) => {
    if (!a || !b || !/^#[0-9a-f]{3}([0-9a-f]{3})?$/i.test(a) || !/^#[0-9a-f]{3}([0-9a-f]{3})?$/i.test(b)) return 0;
    const [l1, l2] = [lum(a), lum(b)].sort((x, y) => y - x);
    return (l1 + 0.05) / (l2 + 0.05);
  };
  for (const [label, blk] of [["dark", dark], ["light", light]]) {
    if (!blk) { bad(`base.css ${label}: table present for the contrast check`); continue; }
    const card = token(blk, "--bg-card");
    const bars = [["--text", 13], ["--text-dim", 5.7], ["--text-muted", 4.5], ["--accent", 4.5], ["--green", 4.5],
      ["--red", 4.5], ["--cta-ink", 4.5], ["--glacier", 4.5], ["--heather", 4.5]];
    const failing = bars.filter(([n, bar]) => contrast(token(blk, n), card) < bar)
      .map(([n, bar]) => `${n}=${token(blk, n)} ${contrast(token(blk, n), card).toFixed(2)}:1 < ${bar}`);
    check(`base.css ${label}: the text tiers (13 / 5.7 / 4.5) and every colour used as text (accent, mint, clay, amber ink, glacier, heather ≥ 4.5) clear their bars on --bg-card ${card}`,
      failing.length === 0, failing.join("; "));
    const inks = [["--accent", "--accent-text"], ["--green", "--green-text"], ["--red", "--red-text"], ["--cta", "--cta-text"], ["--glacier", "--glacier-text"]];
    const dim = inks.filter(([fill, ink]) => contrast(token(blk, fill), token(blk, ink)) < 4.5)
      .map(([fill, ink]) => `${ink} on ${fill}: ${contrast(token(blk, fill), token(blk, ink)).toFixed(2)}:1`);
    check(`base.css ${label}: every filled control's ink reads ≥ 4.5:1 on its fill (accent / mint / clay / amber / glacier)`, dim.length === 0, dim.join("; "));
  }

  // P3 — tokens JS reads must be concrete: lightweight-charts and the canvas
  // parse colour strings themselves and do not understand color-mix().
  const JS_READ = ["--chart-text", "--chart-grid", "--chart-border", "--chart-separator-hover", "--chart-crosshair",
    "--chart-up", "--chart-down", "--chart-up-vol", "--chart-down-vol", "--chart-track", "--depth-bid-edge",
    "--depth-bid-tip", "--depth-ask-edge", "--depth-ask-tip", "--heat-0", "--heat-1", "--heat-2", "--heat-3", "--heat-4",
    "--heat-5", "--heat-6", "--heat-7", "--heat-mark", "--heat-mark-glow", "--heat-grid", "--text-muted"];
  const CONCRETE = /^(#[0-9a-f]{3,8}|rgba?\([\d\s.,%]+\))$/i;
  for (const [label, blk] of [["dark", dark], ["light", light]]) {
    const off = JS_READ.filter((n) => !CONCRETE.test(token(blk, n) || ""));
    check(`base.css ${label}: every token JS reads (chart, depth bars, heat map) is a concrete hex/rgba value`, off.length === 0,
      off.map((n) => `${n}=${token(blk, n)}`).join(", "));
  }

  // P4 — no colour literal outside base.css's two tables. The scan walks the
  // barrel's @import list (what ships); the allowlist is pure black (shadows,
  // scrims, a darkening over a coloured banner — dark in both themes) and the
  // four brand marks of the vault-mix bar, which belong to oracle.css alone.
  const sheets = barrel ? [...barrel.matchAll(/@import "\.\/styles\/([\w-]+\.css)"/g)].map((m) => m[1]) : [];
  check("styles.css: the barrel lists the stylesheets the literal scan walks", sheets.length >= 20, `${sheets.length} sheets`);
  const LITERAL = /(?<![\w-])#[0-9a-f]{3,8}(?![\w-])|rgba?\(/gi;
  const PURE_BLACK = /^rgba?\(\s*0\s*,\s*0\s*,\s*0\s*[,)]/i;
  const BRAND = /^#(f7931a|627eea|9945ff|29abe2)$/i;
  const offenders = [];
  for (const f of sheets) {
    const raw = read(`src/frontend/src/styles/${f}`);
    if (raw === null) { offenders.push(`${f}: missing`); continue; }
    let css = stripCss(raw);
    if (f === "base.css") {
      for (const opener of [":root {", ':root[data-theme="light"] {']) {
        const at = css.indexOf(opener);
        const end = at < 0 ? -1 : css.indexOf("}", at);
        if (at >= 0 && end >= 0) css = css.slice(0, at) + css.slice(end + 1);
      }
    }
    css.split("\n").forEach((line, i) => {
      for (const m of line.matchAll(LITERAL)) {
        const lit = m[0].endsWith("(") ? line.slice(m.index, line.indexOf(")", m.index) + 1) : m[0];
        const allowed = PURE_BLACK.test(lit) || (f === "oracle.css" && BRAND.test(lit));
        if (!allowed) offenders.push(`${f}:${i + 1} ${lit}`);
      }
    });
  }
  check("no rgba()/hex colour literal survives outside base.css's two token tables (allowlist: pure-black shadows/scrims, the four brand marks in oracle.css)",
    offenders.length === 0, offenders.slice(0, 12).join("\n"));

  // P5 — index.html: the metas, the bootstrap's place, the two toggles.
  if (html) {
    check("index.html: <meta name=\"color-scheme\" content=\"dark light\"> declares both schemes",
      /<meta name="color-scheme" content="dark light"\s*\/?>/.test(html));
    check("index.html: a theme-color meta exists for the browser chrome (restamped per theme)",
      /<meta name="theme-color" content="#[0-9a-fA-F]{6}"\s*\/?>/.test(html));
    const bootAt = html.indexOf('<script src="/theme-boot.js"></script>');
    const cssAt = html.indexOf('<link rel="stylesheet"');
    check("index.html: /theme-boot.js is a classic <head> script placed BEFORE the stylesheet link — render-blocking, so data-theme is on <html> before the first paint",
      bootAt >= 0 && cssAt > bootAt && html.indexOf("</head>") > cssAt, `boot@${bootAt} css@${cssAt}`);
    check("index.html: the bootstrap is not a module (modules are deferred past the first paint)",
      !/<script[^>]*type="module"[^>]*theme-boot/.test(html));
    const hr = html.slice(html.indexOf('<div class="header-right">'), html.indexOf("</header>"));
    const tog = /<button id="theme-toggle" class="theme-toggle" type="button" data-theme-toggle aria-label="Switch to light mode" aria-pressed="false"[^>]*>/.exec(hr);
    check("index.html: #theme-toggle sits in .header-right with data-theme-toggle, aria-label=\"Switch to light mode\" and aria-pressed", tog !== null);
    const rest = tog ? hr.slice(tog.index + tog[0].length).replace(/^[\s\S]*?<\/button>/, "") : "x";
    check("index.html: the toggle is the LAST control in .header-right, after Sign In / the user menu — the far right of the header",
      tog !== null && hr.indexOf('id="auth-btn"') < tog.index && /^\s*<\/div>\s*$/.test(rest), rest.trim().slice(0, 80));
    check("index.html: both toggles carry a sun and a moon glyph (the one shown is the destination)",
      (html.match(/class="theme-icon theme-icon-sun"/g) || []).length === 2 && (html.match(/class="theme-icon theme-icon-moon"/g) || []).length === 2);
    const nav = html.slice(html.indexOf('<nav class="tabs">'), html.indexOf("</nav>"));
    const row = nav.indexOf('id="theme-toggle-mobile"');
    check("index.html: the drawer row #theme-toggle-mobile heads the nav list (ahead of Swap) and is NOT a .tab (the tab handler routes by data-tab)",
      row >= 0 && nav.indexOf('data-tab="swap"') > row && /class="drawer-theme" id="theme-toggle-mobile" type="button" data-theme-toggle/.test(nav)
        && !/class="[^"]*\btab\b[^"]*" id="theme-toggle-mobile"/.test(nav));
  }

  // P6 — theme-boot.js: the pre-paint half of the precedence rule.
  if (boot) {
    const b = stripJsComments(boot);
    check("theme-boot.js: reads localStorage \"mdx.theme\" inside try/catch (private windows throw; a theme must never take the page down)",
      /var KEY = "mdx\.theme"/.test(b) && /try \{ saved = window\.localStorage\.getItem\(KEY\); \} catch/.test(b));
    check("theme-boot.js: no saved choice → prefers-color-scheme, else dark",
      /matchMedia\("\(prefers-color-scheme: light\)"\)\.matches\) system = "light"/.test(b) && /var system = "dark"/.test(b) && /var theme = choice \|\| system/.test(b));
    check("theme-boot.js: stamps data-theme on <html> and the theme-color meta",
      /root\.setAttribute\("data-theme", theme\)/.test(b) && /meta\[name="theme-color"\]/.test(b));
  }

  // P7 — theme.js: the toggle, persistence, following the system, the event.
  if (theme) {
    check("theme.js: the saved choice is read inside try/catch and only \"dark\" | \"light\" count",
      /const KEY = "mdx\.theme"/.test(theme) && /try \{\s*const v = localStorage\.getItem\(KEY\);\s*return THEMES\.includes\(v\) \? v : null;\s*\} catch/.test(theme));
    check("theme.js: a click persists the pick; the system preference is followed ONLY while nothing is saved",
      /persist: true/.test(theme) && /if \(!savedChoice\(\)\) applyTheme\(mq\.matches \? "light" : "dark"\)/.test(theme)
        && /matchMedia\("\(prefers-color-scheme: light\)"\)/.test(theme));
    check("theme.js: aria-pressed / aria-label / title are re-stamped on every change (\"Switch to <next> mode\")",
      /setAttribute\("aria-pressed", theme === "light" \? "true" : "false"\)/.test(theme) && /setAttribute\("aria-label", label\)/.test(theme) && /Switch to \$\{next\} mode/.test(theme));
    check("theme.js: an actual change dispatches mdx:theme — what the charts, the heat map and the identicons re-skin on",
      /const EVENT = "mdx:theme"/.test(theme) && /if \(before !== t\) document\.dispatchEvent\(new CustomEvent\(EVENT/.test(theme));
    check("theme.js: the chart skins read the --chart-* tokens (dark fallbacks only) and the theme-color meta follows --bg-card",
      /themeToken\("--chart-text"/.test(theme) && /themeToken\("--chart-up"/.test(theme) && /themeToken\("--chart-track"/.test(theme)
        && /meta\.setAttribute\("content", themeToken\("--bg-card"/.test(theme));
  }

  // P8 — main.js: the readers that take colours as strings.
  if (main) {
    check("main.js: imports theme.js and calls setupTheme() first thing in init() — the toggle works even when nothing else boots",
      /import \{[^}]*setupTheme[^}]*\} from "\.\/theme\.js"/.test(main) && /async function init\(\) \{\s*setupTheme\(\);\s*setupEventListeners\(\);/.test(main));
    for (const anchor of ["chartInstance = createChart(container, {", "miniChartInstance = createChart(canvasEl, {", "swapGraphChart = createChart(el, {"]) {
      const at = main.indexOf(anchor);
      const end = at < 0 ? -1 : main.indexOf("\n  });", at);
      const blk = at < 0 || end < 0 ? "" : main.slice(at, end);
      const before = at < 0 ? "" : main.slice(Math.max(0, at - 240), at);
      check(`main.js: ${anchor.split(" = ")[0]} takes its chrome from chartThemeOptions() — no rgba()/hex literal in the option block`,
        blk.length > 0 && !/rgba?\(|#[0-9a-fA-F]{3,8}/.test(blk) && /const skin = chartThemeOptions\(\);/.test(before),
        blk.length ? (blk.match(/rgba?\([^)]*\)|#[0-9a-fA-F]{3,8}/g) || ["skin read missing"]).join(", ") : "block not found");
    }
    check("main.js: candle series are skinned by candleThemeOptions() (both charts); the swap rate line by chartTrackColor()",
      (main.match(/candleThemeOptions\(\)/g) || []).length >= 2 && /\{ color: chartTrackColor\(\), lineWidth: 2/.test(main));
    check("main.js: volume bars and oracle-tracking candles carry up/synthetic markers with a token colour, re-coloured by reskinChartData()",
      /up: close >= open, color: volumeBarColor\(close >= open\)/.test(main) && /synthetic: true, color: track/.test(main) && /function reskinChartData\(data\)/.test(main));
    check("main.js: the mdx:theme subscriber re-applies the skins to the live chart, the mini chart and the swap graph, and repaints the heat map",
      /onThemeChange\(\(\) => \{[\s\S]*?chartInstance\.applyOptions\(chartThemeOptions\(\)\)[\s\S]*?miniChartReskin\(\)[\s\S]*?swapGraphChart\.applyOptions\(chartThemeOptions\(\)\)[\s\S]*?renderHeatmap\(selectedMarket\)[\s\S]*?\}\);/.test(main));
    check("main.js: depth bars take the --depth-* tokens via var() in the inline gradient (both books)",
      (main.match(/var\(--depth-(ask|bid)-(edge|tip)\)/g) || []).length >= 8 && !/rgba\(240,122,108,0\.32\)|rgba\(94,230,180,0\.32\)/.test(main));
    const heat = funcBody(main, "function drawHeatSurface(");
    check("main.js: drawHeatSurface reads the ramp, grid and mark tokens and carries no colour literal",
      heat !== null && /heatStops\(\)/.test(heat) && /themeToken\("--heat-mark"\)/.test(heat) && /themeToken\("--heat-grid"/.test(heat)
        && !/rgba?\(\d/.test(heat) && !/#[0-9a-fA-F]{3,8}\b/.test(heat),
      heat ? (heat.match(/rgba?\([^)]*\)|#[0-9a-fA-F]{3,8}/g) || []).join(", ") : "body not found");
    check("main.js: the heat ramp is the --heat-0…7 tokens parsed at draw time — the literal RGB table is gone",
      /themeToken\(`--heat-\$\{i\}`\)/.test(main) && !/const HEAT_STOPS = \[/.test(main));

    // P8b — the re-skin never moves the view (1793494438). lightweight-charts
    // keeps the right offset and the bar spacing across a setData whose times
    // are unchanged, so a toggle on a chart the user has scrolled or zoomed is
    // invisible to the time scale — measured live on the seat venue at 375 px
    // (2026-11-01): the mini chart held scrollPos -4.422 / barSpacing 2.94 and
    // the overlay chart its logical range 83.108–182.108 / scrollPos -16.892 /
    // barSpacing 2.96 across light→dark→light, crosshair included. What WOULD
    // reset them is a re-anchor (showLastCandles / fitContent / scrollToRealTime
    // / setVisibleLogicalRange), a refetch (getCandles — a different data set
    // under the same offset), or a re-create (createChart / renderChartData /
    // renderMiniChart) inside the re-skin path: none may appear in the
    // subscriber or in the miniChartReskin closure, and the re-feed must be the
    // arrays the chart already holds.
    const reskinSub = /onThemeChange\(\(\) => \{([\s\S]*?)\n\}\);/.exec(main);
    const miniReskin = /miniChartReskin = \(\) => \{([\s\S]*?)\n  \};/.exec(main);
    const reanchor = /showLastCandles\(|fitContent\(|scrollToRealTime\(|setVisibleLogicalRange\(|setVisibleRange\(|scrollToPosition\(|createChart\(|getCandles\(|renderChartData\(|renderMiniChart\(/g;
    check("main.js: the mdx:theme re-skin re-feeds the arrays the charts already hold and never re-anchors, refetches or re-creates (the scrolled/zoomed view and the crosshair survive a toggle)",
      reskinSub !== null && miniReskin !== null && !reanchor.test(reskinSub[1]) && !reanchor.test(miniReskin[1])
        && /chartCandleSeries\.setData\(chartCandleData\.candles\)/.test(reskinSub[1]) && /miniChartSeries\.setData\(miniAllCandles\)/.test(miniReskin[1]),
      reskinSub && miniReskin ? ((reskinSub[1] + miniReskin[1]).match(reanchor) || ["re-feed of chartCandleData.candles / miniAllCandles missing"]).join(", ") : "subscriber or miniChartReskin block not found");
  }

  // P9 — identicon.js: lightness per theme, refreshed on change.
  if (ident) {
    check("identicon.js: lightness is per theme (lifted on dark tiles, pulled down on light) and the cache is keyed by theme",
      /LIGHTNESS\s*=\s*\{ dark: \d+, light: \d+ \}/.test(ident) && /`\$\{theme\}\|\$\{seed\}`/.test(ident));
    check("identicon.js: refreshIdenticons re-renders every mounted glyph on mdx:theme (the seed rides data-identicon-seed)",
      /export function refreshIdenticons/.test(ident) && /addEventListener\("mdx:theme"/.test(ident) && /dataset\.identiconSeed = seed/.test(ident));
  }

  // P10 — the toggle's CSS contract.
  if (headerCss) {
    const t = /\.theme-toggle \{([^}]*)\}/.exec(stripCss(headerCss));
    const px = (prop) => { const m = t && new RegExp(`${prop}:\\s*(\\d+)px`).exec(t[1]); return m ? Number(m[1]) : 0; };
    check("header.css: .theme-toggle is a 32–36px hit target", t !== null && px("width") >= 32 && px("width") <= 36 && px("height") >= 32 && px("height") <= 36,
      t ? `${px("width")}x${px("height")}` : "rule missing");
    check("header.css: the glyph shown is the destination (moon hidden by a two-class rule that out-ranks '.theme-toggle svg', swapped under [data-theme=\"light\"]); the drawer row is desktop-hidden",
      /\.theme-toggle \.theme-icon-moon, \.drawer-theme \.theme-icon-moon \{ display: none; \}/.test(headerCss) && /:root\[data-theme="light"\] \.theme-icon-sun \{ display: none; \}/.test(headerCss)
        && /\.drawer-theme \{ display: none; \}/.test(headerCss));
  }
  if (respCss) {
    check("responsive.css: the open drawer shows the theme row styled like the nav rows and hides the round header toggle",
      /\.header\.menu-open \.tabs \.drawer-theme \{ display: flex;/.test(respCss) && /\.header\.menu-open \.header-right \.theme-toggle \{ display: none; \}/.test(respCss)
        && /\.header\.menu-open \.tabs \.drawer-theme,/.test(respCss));
  }

  // P11 — the change log names the feature.
  if (docs) {
    check("docs.js: the change log carries the light-mode entry (the sun/moon toggle, remembered per browser, system default)",
      /<li><b>Light mode\.<\/b>[\s\S]{0,400}sun\/moon[\s\S]{0,400}remembered/.test(docs));
  }
}

// ── §Q: the Docs aurora fades at its edges — the clip is masked, the box is belted (1793490294) ──
// Operator report 2026-11-01: the aurora behind The launch / What is
// MULTI/DEX? / Prizes ended in a HARD vertical line at page-right + 60px.
// .docs-aurora's overflow: hidden sliced its 70px-blurred right blob 60px
// past the page edge, and the slice moved as the blob drifted. The fix keeps
// the clip and masks it away: a mask-image fading the box's outer 200px on
// both sides (the whole run-off, so the page column is untouched), its top
// 40px and its bottom 200px, intersected across the two axes; the box
// reaches 200px past the page so the blur has room to die; the blobs keep
// their old page positions; and #docs-view clips sideways — the box ITSELF
// was never clipped (overflow: hidden clips children), so even at -60px it
// widened the docs page to 423px at a 375px viewport. None of this throws
// when it regresses: a dropped mask line renders as a hard edge again, a
// dropped clip as a sideways-scrolling docs page, a blob offset left at its
// old value as a blob 140px off its hero.
console.log("\n§Q. docs aurora — masked run-off on every edge, the blobs where they were, the view clipped sideways");
{
  const stripCss = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "");
  const rawCss = must("src/frontend/src/styles/docs.css");
  const css = rawCss === null ? null : stripCss(rawCss);
  const docs = must("src/frontend/src/docs.js");
  const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const rule = (sel) => { const m = css && new RegExp(`(^|\\n)${esc(sel)} \\{([^}]*)\\}`).exec(css); return m ? m[2] : null; };
  const prop = (blk, name) => { const m = blk && new RegExp(`(^|[\\s;])${esc(name)}:\\s*([^;]+);`).exec(blk); return m ? m[2].replace(/\s+/g, " ").trim() : null; };
  const box = rule(".docs-aurora");
  const first = rule(".docs-aurora i:first-child");
  const last = rule(".docs-aurora i:last-child");
  const H = "linear-gradient(to right, transparent, black 200px, black calc(100% - 200px), transparent)";
  const V = "linear-gradient(to bottom, transparent, black 40px, black calc(100% - 200px), transparent)";

  check("docs.css: .docs-aurora keeps the decoration contract — overflow: hidden (the clip), pointer-events: none, z-index: -1",
    prop(box, "overflow") === "hidden" && prop(box, "pointer-events") === "none" && prop(box, "z-index") === "-1", box || "rule missing");
  check("docs.css: .docs-aurora's mask fades the outer 200px left and right and the top 40px / bottom 200px — standard and -webkit- (alpha-only black/transparent, no theme colour)",
    prop(box, "mask-image") === `${H}, ${V}` && prop(box, "-webkit-mask-image") === `${H}, ${V}`,
    `mask-image: ${prop(box, "mask-image")}\n-webkit-mask-image: ${prop(box, "-webkit-mask-image")}`);
  check("docs.css: the two mask axes are intersected (mask-composite: intersect; -webkit-mask-composite: source-in) — a single axis leaves the other edge hard",
    prop(box, "mask-composite") === "intersect" && prop(box, "-webkit-mask-composite") === "source-in",
    `mask-composite: ${prop(box, "mask-composite")}; -webkit-mask-composite: ${prop(box, "-webkit-mask-composite")}`);
  check("docs.css: the box reaches 200px past the page column on each side (the run-off the mask fades) and is 500px deep, 40px above the page",
    prop(box, "inset") === "-40px -200px auto -200px" && prop(box, "height") === "500px",
    `inset: ${prop(box, "inset")}; height: ${prop(box, "height")}`);
  check("docs.css: the blobs keep their page positions — offsets grew by the 140px the box grew (first-child left: 80px, last-child right: 100px)",
    prop(first, "left") === "80px" && prop(last, "right") === "100px", `left: ${prop(first, "left")}; right: ${prop(last, "right")}`);
  check("docs.css: the blobs are 70px-blurred token tints — accent-tint-3 and heather-tint, no literal (§P's scan covers the rest of the sheet)",
    /var\(--accent-tint-3\)/.test(first || "") && /var\(--heather-tint\)/.test(last || "") && prop(rule(".docs-aurora i"), "filter") === "blur(70px)");
  const kf = (name) => { const m = css && new RegExp(`@keyframes ${name} \\{([\\s\\S]*?)\\n\\}`).exec(css); return m ? m[1] : null; };
  const transformOnly = (body) => body !== null && body.trim().split("\n").every((l) => /^\s*(from|to)\s*\{\s*transform: [^;]+;\s*\}\s*$/.test(l));
  check("docs.css: aurora-a / aurora-b stay transform-only (compositor animations; a mask on the parent must not tempt a filter/opacity tween), and reduced motion freezes them",
    transformOnly(kf("aurora-a")) && transformOnly(kf("aurora-b"))
      && /@media \(prefers-reduced-motion: reduce\) \{\s*\.docs-aurora i \{ animation: none; \}/.test(css || ""));
  check("docs.css: #docs-view clips sideways with overflow-x: clip — not hidden, which would make the view a scroll container — so the run-off never widens the document",
    /(^|\n)#docs-view \{ overflow-x: clip; \}/.test(css || ""));
  if (docs) {
    const DIV = '<div class="docs-aurora" aria-hidden="true"><i></i><i></i></div>';
    const pageHas = (slug) => { const i = docs.indexOf(`slug: "${slug}"`); if (i < 0) return false; const j = docs.indexOf('\n    slug: "', i + 1); return docs.slice(i, j < 0 ? docs.length : j).includes(DIV); };
    check("docs.js: the aurora div ships on the three hero pages the mask serves — launch, welcome (What is MULTI/DEX?), prizes",
      ["launch", "welcome", "prizes"].every(pageHas));
  }
}

// ════════════════════════════════════════════════════════════════════
// §R. Fuel banner (task 1793572114, operator instruction 2026-11-01): the
//     "MULTI/DEX will run out of fuel in ~…" countdown paints app-wide only
//     inside 24h of the predicted freeze — BANNER_FREEZE_WARN_SEC → fuelState's
//     `freezeSoon` — while TIME_WARN_SEC stays 72h for the System card and
//     every other `timeWarn` consumer; the warn chain checks each tier's own
//     predicate and HIDES on no match (the old final `else` assumed `low`);
//     the countdown's treasury sentence is posture-aware — play/dev read
//     "While in demo mode, the self-funding treasury does not hold real
//     assets, …", production (or an UNANSWERED posture: state.js's "dev"
//     default is a placeholder, never knowledge) keeps the original sentence.
//     Lifted run: fuelState + updateFuelBanner over a stubbed document with a
//     crafted getCanisterInfo at 20h / 48h / 100h to the freeze, low=false →
//     shown / hidden / hidden; the sentence by posture; and the #dev-only
//     console handle (window.__mdxFuelBanner) that lets a seat smoke the
//     tiers on a venue that is nowhere near a freeze.
//     Task 1793575028: the startup race — the first fuel paint can land
//     before getDeployMode answers; resolveDeployModeAndBanner repaints once
//     from the cached info when the answer settles (static pin + lifted run).
//     Recorded, not gated (the brief's operator note): between 24h and 72h
//     the BALANCE tier (`low`, liquid < 5T) still paints its countdown-less
//     banner — one pin names that fall-through so a later change is deliberate.
// ════════════════════════════════════════════════════════════════════
console.log("\n§R. fuel banner — the 24h countdown gate, the hide-on-no-match warn chain, the posture-aware treasury sentence");
{
  const rawR = must("src/frontend/src/main.js");
  const mainR = rawR === null ? null : stripJsComments(rawR);
  if (mainR) {
    const H = 3600;
    // ── static pins ──
    check("R: BANNER_FREEZE_WARN_SEC is declared at module scope as 24 * 3600 (the banner's own window)",
      /^const BANNER_FREEZE_WARN_SEC = 24 \* 3600;/m.test(mainR));
    check("R: TIME_WARN_SEC stays 72 * 3600 — the System card's 3-day heads-up is untouched",
      /const TIME_WARN_SEC\s+= 72 \* 3600;/.test(mainR));
    check("R: the System card still keys its \"Exchange fuel runs out in ~…\" card on fs.timeWarn (the heads-up lives there)",
      /if \(fs\.timeWarn\) \{\s*card\(1, `Exchange fuel runs out in ~\$\{fmtDuration\(fs\.secsToFreeze\)\}`/.test(mainR));
    const fsBody = funcBody(mainR, "function fuelState(info)");
    check("R: fuelState derives freezeSoon = timeWarn && secsToFreeze < BANNER_FREEZE_WARN_SEC and returns it beside timeWarn",
      fsBody !== null && /const freezeSoon\s*= timeWarn && secsToFreeze < BANNER_FREEZE_WARN_SEC;/.test(fsBody)
      && /secsToFreeze, timeWarn, freezeSoon,/.test(fsBody.slice(fsBody.lastIndexOf("return {"))));
    const ubBody = funcBody(mainR, "function updateFuelBanner(info)");
    check("R: the warn tier's entry still admits timeWarn || low || memHigh (the self-funding info note keeps its reach)",
      ubBody !== null && /else if \(s\.timeWarn \|\| s\.low \|\| s\.memHigh\) \{/.test(ubBody));
    check("R: the countdown branch (warn:freeze) is gated on s.freezeSoon — never on bare s.timeWarn",
      ubBody !== null && /\} else if \(s\.freezeSoon\) \{\s*sig = "warn:freeze";/.test(ubBody)
      && !/else if \(s\.timeWarn\) \{\s*sig = "warn:freeze"/.test(ubBody));
    check("R: warn:low is reached only when s.low — no bare `else` assumes the balance tier",
      ubBody !== null && /\} else if \(s\.low\) \{\s*sig = "warn:low";/.test(ubBody));
    check("R: the warn chain's no-match case HIDES the banner (`} else { show = false; }` closes the chain)",
      ubBody !== null && /sig = "warn:low";[\s\S]*?\$\{info\.canisterId\}<\/code>`;\s*\} else \{\s*show = false;\s*\}/.test(ubBody));
    // ── mobile mode (task 1793575742, operator instruction 2026-11-02) ──
    // "In mobile mode, the banner that announces that multidex will run out
    // of fuel without a donation should not appear." The two donation-asking
    // tiers (warn:freeze, warn:low) carry `asks-cycles`, and stats.css hides
    // that class at the app's OWN mobile breakpoint (≤ 900px: isMobile() and
    // uomMobileMQ) — by stylesheet, so the show path's `display = ""` leaves
    // the cascade in charge and the ✕'s inline none still wins. The frozen/
    // critical tier, the memory warning and the self-funding note keep their
    // class strings and stay on every width (the operator's recorded note: the
    // frozen tier is the only thing telling a phone visitor why every action
    // fails). A matchMedia change listener recomputes --chrome-h on the
    // crossing itself — a resize re-renders no banner.
    const ASKS = "fuel-banner warn asks-cycles";
    check("R: the countdown branch (warn:freeze) marks the banner `fuel-banner warn asks-cycles` right after its signature",
      ubBody !== null && /\} else if \(s\.freezeSoon\) \{\s*sig = "warn:freeze";\s*el\.className = "fuel-banner warn asks-cycles";/.test(ubBody));
    check("R: the balance branch (warn:low) marks it likewise",
      ubBody !== null && /\} else if \(s\.low\) \{\s*sig = "warn:low";\s*el\.className = "fuel-banner warn asks-cycles";/.test(ubBody));
    check("R: `asks-cycles` is spelled exactly twice in updateFuelBanner and nowhere else in main.js (comments stripped) — no third tier carries it",
      ubBody !== null && ubBody.split("asks-cycles").length - 1 === 2 && mainR.split("asks-cycles").length - 1 === 2);
    check("R: the frozen/critical tier keeps `fuel-banner critical` — spelled once, right after its critical:* signature, never with asks-cycles",
      ubBody !== null && /if \(s\.dead\) \{\s*sig = `critical:\$\{s\.cause \|\| "stall"\}`;\s*el\.className = "fuel-banner critical";/.test(ubBody)
      && ubBody.split('el.className = "fuel-banner critical";').length - 1 === 1 && !/fuel-banner critical asks-cycles/.test(ubBody));
    check("R: the memory warning keeps `fuel-banner warn` (warn:mem — the only bare warn left) and the self-funding note `fuel-banner info` (info:topup)",
      ubBody !== null && /sig = "warn:mem";\s*el\.className = "fuel-banner warn";/.test(ubBody)
      && /sig = "info:topup";\s*el\.className = "fuel-banner info";/.test(ubBody)
      && ubBody.split('el.className = "fuel-banner warn";').length - 1 === 1
      && ubBody.split('el.className = "fuel-banner info";').length - 1 === 1);
    // stats.css: the hide rule, read per @media block (brace-matched, so a
    // nested rule cannot end the scan early).
    const statsRawR = must("src/frontend/src/styles/stats.css");
    const statsCssR = statsRawR === null ? null : statsRawR.replace(/\/\*[\s\S]*?\*\//g, "");
    const mediaBlocks = (css) => {
      const out = [];
      const re = /@media\s*([^{]+)\{/g;
      let m;
      while ((m = re.exec(css)) !== null) {
        const open = m.index + m[0].length - 1;        // the block's `{`
        const end = skipBraces(css, open);
        if (end < 0) break;
        out.push({ query: m[1].trim(), body: css.slice(open + 1, end - 1) });
        re.lastIndex = end;
      }
      return out;
    };
    const blocksR = statsCssR === null ? [] : mediaBlocks(statsCssR);
    const MOBILE_Q = /^\(max-width:\s*900px\)$/;
    const hideRule = /\.fuel-banner\.asks-cycles\s*\{\s*display:\s*none;\s*\}/;
    const mobileBlocksR = blocksR.filter((b) => MOBILE_Q.test(b.query));
    check("R: stats.css hides `.fuel-banner.asks-cycles { display: none; }` inside a `@media (max-width: 900px)` block — the mobile breakpoint, by stylesheet not by JS",
      mobileBlocksR.some((b) => hideRule.test(b.body)), `media queries: ${blocksR.map((b) => b.query).join(" | ")}`);
    check("R: `asks-cycles` is spelled once in stats.css, inside that block only — no base rule, no other breakpoint",
      statsCssR !== null && statsCssR.split("asks-cycles").length - 1 === 1
      && blocksR.filter((b) => /asks-cycles/.test(b.body)).length === 1 && blocksR.every((b) => MOBILE_Q.test(b.query) || !/asks-cycles/.test(b.body)));
    const hiddenFuelSelectors = blocksR.flatMap((b) => [...b.body.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
      .filter((r) => /\.fuel-banner/.test(r[1]) && /display\s*:\s*none/.test(r[2])).map((r) => r[1].trim()));
    const criticalRules = statsCssR === null ? [] : [...statsCssR.matchAll(/\.fuel-banner\.critical[^{}]*\{([^{}]*)\}/g)];
    check("R: nothing in stats.css hides `.fuel-banner.critical` — it appears in no @media block and its own rule carries no display: none (the frozen tier stays on every width)",
      statsCssR !== null && blocksR.every((b) => !/\.fuel-banner\.critical/.test(b.body))
      && criticalRules.length >= 1 && criticalRules.every((r) => !/display\s*:\s*none/.test(r[1])));
    check("R: `.fuel-banner.asks-cycles` is the ONLY fuel-banner selector hidden under any breakpoint in stats.css",
      hiddenFuelSelectors.length === 1 && hiddenFuelSelectors[0] === ".fuel-banner.asks-cycles",
      `hidden fuel selectors under @media: ${hiddenFuelSelectors.join(", ") || "(none)"}`);
    // The breakpoint, read from every source and compared — never a new number.
    const isMobilePx = Number((/^function isMobile\(\) \{ return window\.innerWidth <= (\d+); \}/m.exec(mainR) || [])[1]);
    const mqPx = Number((/^const uomMobileMQ = window\.matchMedia\("\(max-width: (\d+)px\)"\);/m.exec(mainR) || [])[1]);
    const hideBlock = mobileBlocksR.find((b) => hideRule.test(b.body));
    const cssPx = hideBlock ? Number((/\(max-width:\s*(\d+)px\)/.exec(hideBlock.query) || [])[1]) : null;
    check("R: the hide rule's breakpoint equals isMobile()'s `window.innerWidth <= 900` and uomMobileMQ's `(max-width: 900px)` — the app's one mobile breakpoint, read from all three sources",
      isMobilePx === 900 && mqPx === 900 && cssPx === 900, `isMobile=${isMobilePx} uomMobileMQ=${mqPx} stats.css=${cssPx}`);
    // --chrome-h across the breakpoint: the stylesheet moves #top-chrome's
    // height with no renderer running, so the crossing itself recomputes.
    const LISTENER = 'uomMobileMQ.addEventListener("change", updateChromeHeight);';
    const setupBodyR = funcBody(mainR, "function setupEventListeners()");
    check("R: `uomMobileMQ.addEventListener(\"change\", updateChromeHeight);` is registered exactly once — in setupEventListeners, right after the #top-chrome ResizeObserver block (both bindings in scope; runs once at init)",
      mainR.split(LISTENER).length - 1 === 1 && setupBodyR !== null && setupBodyR.split(LISTENER).length - 1 === 1
      && /new ResizeObserver\(updateChromeHeight\)\.observe\(topChrome\);\s*updateChromeHeight\(\);\s*\}\s*uomMobileMQ\.addEventListener\("change", updateChromeHeight\);/.test(setupBodyR));
    check("R: the listener is the hoisted updateChromeHeight itself and the codebase's uomMobileMQ idiom is addEventListener — no addListener fallback anywhere",
      !/uomMobileMQ\.addListener\(/.test(mainR) && !/uomMobileMQ\.addEventListener\("change", \(\) => \{?\s*updateChromeHeight\(\)/.test(mainR));
    // ── the two sentences ──
    const DEMO = "While in demo mode, the self-funding treasury does not hold real assets, so a top-up must come from outside — send cycles to ";
    const PROD = "The self-funding treasury is empty, so a top-up must come from outside — send cycles to ";
    check("R: the play/dev sentence is the operator's text VERBATIM, spelled once in main.js (code, comments stripped)",
      mainR.split(DEMO).length - 1 === 1);
    check("R: the production sentence survives, spelled once",
      mainR.split(PROD).length - 1 === 1);
    check("R: the sentence is chosen by the backend's ANSWERED posture — _deployModeAnswered && (play || dev) → demo; the state.js placeholder is never knowledge",
      ubBody !== null && /const demoPosture = _deployModeAnswered && \(appState\.deployMode === "play" \|\| appState\.deployMode === "dev"\);/.test(ubBody)
      && /const treasuryNote = demoPosture\s*\?/.test(ubBody) && /\+\s*treasuryNote \+\s*`<code class="fuel-banner-id">\$\{info\.canisterId\}<\/code>`/.test(ubBody));
    // ── the #dev console handle ──
    const smokeBody = funcBody(mainR, "function fuelBannerSmoke(info, opts = {})");
    check("R: fuelBannerSmoke exists and is the window.__mdxFuelBanner console spelling",
      smokeBody !== null && /^window\.__mdxFuelBanner = fuelBannerSmoke;/m.test(mainR));
    check("R: the handle is gated on the ANSWERED #dev posture (as devLogin is) — one console line and false anywhere else",
      smokeBody !== null && /if \(!_deployModeAnswered \|\| appState\.deployMode !== "dev"\) \{\s*console\.info\([^)]*\);\s*return false;\s*\}/.test(smokeBody));
    check("R: the handle paints through updateFuelBanner and restores the posture it stood in for (try/finally)",
      smokeBody !== null && /try \{ updateFuelBanner\(info\); \} finally \{ appState\.deployMode = saved; \}/.test(smokeBody));
    check("R: the handle touches no DOM of its own",
      smokeBody !== null && !/\bdocument\b|innerHTML|classList|\.style\b/.test(smokeBody));
    // ── the lifted run ──
    // The core lift stands on its own (so a pre-change tree reds the
    // behavioural pins below, not merely the handle's); the handle's own run
    // is gated separately on its body.
    const bodies = {
      fuelState: fsBody, banner: ubBody,
      fmtDuration: funcBody(mainR, "function fmtDuration(sec)"),
      fmtCycles: funcBody(mainR, "function fmtCycles(nat)"),
    };
    const liftable = Object.values(bodies).every((b) => b !== null);
    check("R: fuelState, updateFuelBanner, fmtDuration and fmtCycles are extractable",
      liftable, Object.entries(bodies).filter(([, b]) => b === null).map(([k]) => k).join(", "));
    if (liftable) {
      const fmtDuration = new Function("return function fmtDuration(sec) " + bodies.fmtDuration)();
      const fmtCycles = new Function("return function fmtCycles(nat) " + bodies.fmtCycles)();
      // CLOUD_ENGINE false: the on-chain gates are the ones under test.
      const fuelStateFn = new Function("CLOUD_ENGINE", "BANNER_FREEZE_WARN_SEC",
        "return function fuelState(info) " + bodies.fuelState)(false, 24 * H);
      // A crafted getCanisterInfo: 10T liquid above a 1.5T freezing limit (so
      // `low` — liquid < 5T — is FALSE and nothing is critical), a heartbeat 1s
      // old, memory a third full, no self-funding (auto-fuel off, route
      // unwired, dust treasury), and a burn rate chosen so liquid ÷ burn lands
      // on the hours asked. `over` adjusts a case (the low-balance variant).
      const infoAt = (hoursToFreeze, over = {}) => {
        const liquid = 10e12;
        return {
          canisterId: "aaaaa-aa", cycles: liquid + 1.5e12, freezingLimitCycles: 1.5e12,
          nowNs: 1e12, lastHeartbeatNs: 1e12 - 1e9, timersPaused: false,
          burnPerDay: liquid * 86400 / (hoursToFreeze * H), idleBurnPerDay: 1e11,
          memorySizeBytes: 2 ** 30, wasmMemoryLimitBytes: 3 * 2 ** 30,
          autoFuelEnabled: false, fuelRouteWired: false, treasuryUsdE8s: 0, treasuryIcpE8s: 0,
          ...over,
        };
      };
      const s20 = fuelStateFn(infoAt(20)), s48 = fuelStateFn(infoAt(48)), s100 = fuelStateFn(infoAt(100));
      check("R: fuelState at 20h → timeWarn AND freezeSoon, not low, not dead",
        Math.abs(s20.secsToFreeze - 20 * H) < 1 && s20.timeWarn === true && s20.freezeSoon === true && !s20.low && !s20.dead, JSON.stringify(s20));
      check("R: fuelState at 48h → timeWarn (the System card's lead) but freezeSoon === false",
        Math.abs(s48.secsToFreeze - 48 * H) < 1 && s48.timeWarn === true && s48.freezeSoon === false && !s48.low, JSON.stringify(s48));
      check("R: fuelState at 100h → neither flag",
        Math.abs(s100.secsToFreeze - 100 * H) < 1 && s100.timeWarn === false && s100.freezeSoon === false && !s100.low, JSON.stringify(s100));
      // updateFuelBanner over a stubbed document: one #fuel-banner element,
      // the dismiss helper a recorder (its sessionStorage + button are not
      // the subject), the chrome-height hook a no-op.
      const run = (info, { deployMode = "dev", answered = true } = {}) => {
        const el = { id: "fuel-banner", className: "", innerHTML: "", style: { display: "none" } };
        const doc = { getElementById: (id) => (id === "fuel-banner" ? el : null) };
        const dismiss = [];
        const appState = { deployMode };
        const fn = new Function("document", "fuelState", "fmtBytes", "fmtAgeSec", "fmtDuration", "fmtCycles",
          "applyBannerDismiss", "updateChromeHeight", "appState", "_deployModeAnswered",
          "return function updateFuelBanner(info) " + bodies.banner)(
          doc, fuelStateFn, (n) => `${n}B`, (s) => `${s}s ago`, fmtDuration, fmtCycles,
          (e, key, sig) => { dismiss.push([key, sig]); return false; }, () => {}, appState, answered);
        fn(info);
        return { el, dismiss, shown: el.style.display !== "none" };
      };
      const r20 = run(infoAt(20)), r48 = run(infoAt(48)), r100 = run(infoAt(100));
      check("R: 20h to the freeze, low=false → the countdown banner SHOWS (fuel-banner warn asks-cycles, sig warn:freeze, \"will run out of fuel in ~20 hours\")",
        r20.shown && r20.el.className === "fuel-banner warn asks-cycles" && r20.dismiss.length === 1 && r20.dismiss[0][0] === "dismiss.fuel" && r20.dismiss[0][1] === "warn:freeze"
        && /<strong>⚠ MULTI\/DEX will run out of fuel in ~20 hours\.<\/strong>/.test(r20.el.innerHTML), r20.el.innerHTML);
      check("R: 48h to the freeze, low=false → HIDDEN (timeWarn alone no longer paints the app-wide banner; no dismiss signature recorded)",
        !r48.shown && r48.dismiss.length === 0, `display=${r48.el.style.display} html=${r48.el.innerHTML}`);
      check("R: 100h to the freeze, low=false → HIDDEN",
        !r100.shown && r100.dismiss.length === 0, `display=${r100.el.style.display}`);
      // The recorded fall-through: 48h out with 3T liquid (low) still paints
      // the BALANCE tier's banner — countdown-less, sig warn:low. Not a gate of
      // this task; the operator decides whether `low` should wait for 24h too.
      const r48low = run(infoAt(48, { cycles: 3e12 + 1.5e12, burnPerDay: 3e12 * 86400 / (48 * H) }));
      check("R: 48h to the freeze with 3T liquid (low=true) → the balance tier's warn:low banner still shows, without a countdown (the fall-through recorded for the operator)",
        r48low.shown && r48low.dismiss.length === 1 && r48low.dismiss[0][1] === "warn:low" && /low on spendable fuel/.test(r48low.el.innerHTML) && !/will run out of fuel in/.test(r48low.el.innerHTML), r48low.el.innerHTML);
      // Mobile mode (task 1793575742): the two donation tiers carry the class
      // stats.css hides at ≤ 900px; the critical, memory and self-funding
      // tiers do not — the frozen tier stays on a phone.
      check("R: lifted — 20h to the freeze (warn:freeze) paints `fuel-banner warn asks-cycles`",
        r20.shown && r20.el.className === ASKS && r20.dismiss[0]?.[1] === "warn:freeze", r20.el.className);
      check("R: lifted — 3T liquid at 48h (warn:low) paints `fuel-banner warn asks-cycles` too",
        r48low.shown && r48low.el.className === ASKS && r48low.dismiss[0]?.[1] === "warn:low", r48low.el.className);
      // 0.1T liquid above the 1.5T freezing limit → critical (cause cycles) → the dead tier.
      const rCrit = run(infoAt(20, { cycles: 1.6e12 }));
      check("R: lifted — 0.1T liquid (critical, cause cycles) paints `fuel-banner critical` — no asks-cycles, the frozen tier's class untouched",
        rCrit.shown && rCrit.el.className === "fuel-banner critical" && rCrit.dismiss[0]?.[1] === "critical:cycles"
        && /out of fuel — trading is halted/.test(rCrit.el.innerHTML), `${rCrit.el.className} ${rCrit.dismiss.map((d) => d[1]).join()}`);
      // Memory at 90% of its limit, 10T liquid, 100h of burn → warn:mem alone.
      const rMem = run(infoAt(100, { memorySizeBytes: 0.9 * 3 * 2 ** 30 }));
      check("R: lifted — memory at 90% (warn:mem) paints bare `fuel-banner warn` — an ops warning, never hidden on mobile",
        rMem.shown && rMem.el.className === "fuel-banner warn" && rMem.dismiss[0]?.[1] === "warn:mem", `${rMem.el.className} ${rMem.dismiss.map((d) => d[1]).join()}`);
      // Self-funding (auto-fuel armed, route wired, $100 treasury) with the
      // top-up under an hour out: 10T liquid over a 9.8T/day burn → info:topup.
      const rTopup = run(infoAt(20, { autoFuelEnabled: true, fuelRouteWired: true, treasuryUsdE8s: 100e8, burnPerDay: 9.8e12 }));
      check("R: lifted — self-funding with the top-up under an hour out (info:topup) paints `fuel-banner info` — no asks-cycles",
        rTopup.shown && rTopup.el.className === "fuel-banner info" && rTopup.dismiss[0]?.[1] === "info:topup", `${rTopup.el.className} ${rTopup.dismiss.map((d) => d[1]).join()}`);
      // The sentence by posture — the continuation and the canister id intact.
      const DEMO_RE = /While in demo mode, the self-funding treasury does not hold real assets, so a top-up must come from outside — send cycles to <code class="fuel-banner-id">aaaaa-aa<\/code>$/;
      const PROD_RE = /The self-funding treasury is empty, so a top-up must come from outside — send cycles to <code class="fuel-banner-id">aaaaa-aa<\/code>$/;
      const onDev = run(infoAt(20), { deployMode: "dev" }), onPlay = run(infoAt(20), { deployMode: "play" });
      check("R: on a dev venue the countdown's treasury sentence reads \"While in demo mode, …\" (the continuation and the id follow it)",
        onDev.shown && DEMO_RE.test(onDev.el.innerHTML) && !/treasury is empty/.test(onDev.el.innerHTML), onDev.el.innerHTML);
      check("R: on a play venue likewise",
        onPlay.shown && DEMO_RE.test(onPlay.el.innerHTML), onPlay.el.innerHTML);
      const onProd = run(infoAt(20), { deployMode: "production" });
      check("R: on production the original sentence, and never the demo one",
        onProd.shown && PROD_RE.test(onProd.el.innerHTML) && !/demo mode/.test(onProd.el.innerHTML), onProd.el.innerHTML);
      const unanswered = run(infoAt(20), { deployMode: "dev", answered: false });
      check("R: an UNANSWERED posture read (state.js's \"dev\" placeholder still in appState) keeps the production sentence — the conservative default",
        unanswered.shown && PROD_RE.test(unanswered.el.innerHTML), unanswered.el.innerHTML);
      check("R: an unrecognised answer keeps the production sentence too",
        PROD_RE.test(run(infoAt(20), { deployMode: "staging" }).el.innerHTML));
    }
    // The console handle, lifted: refused off-#dev with nothing painted; on
    // #dev it paints, and a stand-in posture is restored afterwards.
    if (smokeBody !== null) {
      const infoAt = () => ({ canisterId: "aaaaa-aa" });   // the paint is a recorder here; the shape is immaterial
      const liftSmoke = ({ deployMode, answered }) => {
        const paints = [], logs = [];
        const appState = { deployMode };
        const fn = new Function("_deployModeAnswered", "appState", "updateFuelBanner", "console",
          "return function fuelBannerSmoke(info, opts = {}) " + smokeBody)(
          answered, appState, (info) => paints.push(appState.deployMode), { info: (m) => logs.push(m) });
        return { fn, paints, logs, appState };
      };
      const offPlay = liftSmoke({ deployMode: "play", answered: true });
      check("R: __mdxFuelBanner on a play venue → false, one console line, nothing painted",
        offPlay.fn(infoAt(20)) === false && offPlay.paints.length === 0 && offPlay.logs.length === 1 && /not a #dev venue/.test(offPlay.logs[0]));
      const unansweredDev = liftSmoke({ deployMode: "dev", answered: false });
      check("R: __mdxFuelBanner with the posture unanswered (placeholder \"dev\") → false, nothing painted",
        unansweredDev.fn(infoAt(20)) === false && unansweredDev.paints.length === 0);
      const onDevSmoke = liftSmoke({ deployMode: "dev", answered: true });
      check("R: __mdxFuelBanner on a #dev venue paints once as dev, and with { deployMode: \"production\" } paints as production then restores \"dev\"",
        onDevSmoke.fn(infoAt(20)) === true && onDevSmoke.fn(infoAt(20), { deployMode: "production" }) === true
        && onDevSmoke.paints.join(",") === "dev,production" && onDevSmoke.appState.deployMode === "dev" && onDevSmoke.logs.length === 0,
        `paints=${onDevSmoke.paints.join(",")} after=${onDevSmoke.appState.deployMode}`);
    }
    // ── the startup race (task 1793575028) ──
    // refreshCanisterInfo's first paint can land before getDeployMode answers,
    // and updateFuelBanner chooses the treasury sentence PER PAINT — so a
    // play/dev venue showed the PRODUCTION sentence until the next poll
    // (seat-3's 400px frame, 2026-11-02). The cure is ONE repaint from the
    // cached getCanisterInfo once the posture is answered, placed AFTER
    // renderHomePostureBadge() so the pinned order (_deployModeSettle →
    // renderLaunchBanner → renderHomePostureBadge; frontend_security O2 and
    // this file's main.js section) stands. Lifted below: the read is a stub
    // actor, every renderer a recorder; the function ASSIGNS
    // _deployModeAnswered, so that binding is a parameter the closure owns and
    // its value reaches us through the recording _deployModeSettle.
    const resolveBody = funcBody(mainR, "async function resolveDeployModeAndBanner()");
    const refreshBody = funcBody(mainR, "async function refreshCanisterInfo()");
    check("R: lastCanisterInfo is the module-level cache (`let lastCanisterInfo = null;`) that refreshCanisterInfo writes right before its first paint — the repaint's guard is honest (null until the first poll answers)",
      /^let lastCanisterInfo = null;/m.test(mainR) && refreshBody !== null
      && /const info = await a\.getCanisterInfo\(\);\s*lastCanisterInfo = info;\s*canisterInfoFailures = 0;\s*updateFuelBanner\(info\);/.test(refreshBody));
    check("R: resolveDeployModeAndBanner repaints the fuel banner from lastCanisterInfo once the posture is ANSWERED — `if (_deployModeAnswered && lastCanisterInfo) updateFuelBanner(lastCanisterInfo);` right after renderHomePostureBadge(), the pinned call order untouched",
      resolveBody !== null
      && /_deployModeSettle\(_deployModeAnswered\);\s*renderLaunchBanner\(\);\s*renderHomePostureBadge\(\);\s*if \(_deployModeAnswered && lastCanisterInfo\) updateFuelBanner\(lastCanisterInfo\);\s*\}$/.test(resolveBody),
      resolveBody === null ? "resolveDeployModeAndBanner not found" : resolveBody);
    check("R: that repaint is the ONLY updateFuelBanner call in resolveDeployModeAndBanner (one repaint per answer, nothing periodic)",
      resolveBody !== null && (resolveBody.match(/updateFuelBanner\(/g) || []).length === 1);
    if (resolveBody !== null) {
      const liftResolve = async ({ answer, cached }) => {
        const calls = [], settled = [];
        const appState = {
          deployMode: "dev",   // state.js's placeholder — never knowledge
          publicActor: answer === undefined ? null
            : { getDeployMode: async () => { if (answer instanceof Error) throw answer; return answer; } },
          actor: null,
        };
        const fn = new Function("appState", "_deployModeAnswered", "_deployModeSettle", "renderLaunchBanner",
          "renderHomePostureBadge", "updateFuelBanner", "lastCanisterInfo",
          "return async function resolveDeployModeAndBanner() " + resolveBody)(
          appState, false, (v) => settled.push(v), () => calls.push("launch"), () => calls.push("badge"),
          (info) => calls.push(["fuel", info]), cached);
        await fn();
        return { calls, names: calls.map((c) => (Array.isArray(c) ? c[0] : c)), fuel: calls.filter(Array.isArray), settled, appState };
      };
      const INFO = { canisterId: "aaaaa-aa", cycles: 1 };   // the paint is a recorder: identity matters, shape does not
      const devHit = await liftResolve({ answer: "dev", cached: INFO });
      check("R: answered \"dev\" with a cached getCanisterInfo → launch notice, Home badge, then ONE fuel repaint with that very object (the pinned order first; _deployModeKnown settles true)",
        devHit.names.join(",") === "launch,badge,fuel" && devHit.fuel[0][1] === INFO
        && devHit.settled.join() === "true" && devHit.appState.deployMode === "dev", JSON.stringify(devHit.names));
      const playHit = await liftResolve({ answer: "play", cached: INFO });
      check("R: answered \"play\" likewise — exactly one repaint",
        playHit.names.join(",") === "launch,badge,fuel" && playHit.appState.deployMode === "play", JSON.stringify(playHit.names));
      const prodHit = await liftResolve({ answer: "production", cached: INFO });
      check("R: answered \"production\" repaints too — the guard is the ANSWER plus the cache, never the demo posture (updateFuelBanner owns the sentence; on production both paints read the same)",
        prodHit.fuel.length === 1, JSON.stringify(prodHit.names));
      const noCache = await liftResolve({ answer: "dev", cached: null });
      check("R: answered but NO cached info (the posture read won the race; the first fuel paint is still to come and will read the answer itself) → no repaint",
        noCache.names.join(",") === "launch,badge" && noCache.settled.join() === "true", JSON.stringify(noCache.names));
      const rejected = await liftResolve({ answer: new Error("transient reject"), cached: INFO });
      check("R: the read REJECTED (posture unanswered) with cached info → no repaint; launch + badge still render and _deployModeKnown settles false",
        rejected.names.join(",") === "launch,badge" && rejected.settled.join() === "false", JSON.stringify(rejected.names));
      const noActor = await liftResolve({ answer: undefined, cached: INFO });
      check("R: no actor yet (unanswered) with cached info → no repaint, settles false",
        noActor.names.join(",") === "launch,badge" && noActor.settled.join() === "false", JSON.stringify(noActor.names));
    }
  }
}

// ── O. funcBody self-check — every extracted body is a body ────────────
// Task 1788637309. Every section above that scopes a pin by funcBody() has
// been recorded; one assertion per call says the slice it got is a function
// body and not the 41-char parameter list a destructured header used to
// yield. A pin over the wrong slice fails on the wrong evidence — or, for
// the `!/x/.test(body)` shape most pins use, passes on it — and nothing
// else in this file would notice. Runs LAST so the per-section counts of
// A–N are unchanged by it.
console.log("\nO. funcBody self-check — every extracted body is a body, not a parameter list");
{
  check("funcBody() was exercised by the sections above (the ledger is non-empty)", FUNC_BODY_CALLS.length > 0,
    "no funcBody() call reached the ledger — the wrapper was bypassed or the sections were skipped");
  for (const c of FUNC_BODY_CALLS) {
    check(`funcBody(${JSON.stringify(c.header)}) returned a body (${c.length} chars, not followed by ')')`,
      c.length >= FUNC_BODY_MIN_CHARS && !c.paramShaped,
      c.paramShaped
        ? "the slice is followed by ')' — it is the parameter list, not the body (destructured-parameter header)"
        : `only ${c.length} chars — shorter than any body this battery pins (min ${FUNC_BODY_MIN_CHARS})`);
  }
}

// ── §N4: the Home page at #home (1793490812) ────────────────────────────
// Operator instruction 2026-11-01: the logo does something — it returns the
// visitor to a designed landing page. The pins are the brief's: `home` is a
// routed tab; the LOGO is an anchor to #home (keyboard-reachable, no click
// handler); the EMPTY hash lands on Home (it is the landing page, so the bare
// URL must not fall into the Swap box); exactly ONE h1 on the Home view; every
// GitHub link on it is the PUBLIC repository (never the private one) and every
// external link opens in a new tab with rel="noopener noreferrer"; the mobile
// drawer carries a Home row (the lockup is small there); the Swap strap moved
// to a Swap-specific line so the two pages do not repeat each other; and the
// proof strip ships "—" placeholders, never a number (#54.9).
console.log("\n§N4. Home page — #home routed, the logo is its anchor, the empty hash lands there, one h1, public repo only");
{
  const stripHtml = (s) => s.replace(/<!--[\s\S]*?-->/g, "");
  const rawHtml = must("src/frontend/index.html");
  const html = rawHtml === null ? null : stripHtml(rawHtml);
  const rawMain = must("src/frontend/src/main.js");
  const main = rawMain === null ? null : stripJsComments(rawMain);
  const barrel = must("src/frontend/src/styles.css");
  const homeCss = must("src/frontend/src/styles/home.css");

  // N4.1 — the routing table, evaluated: VALID_TABS is a Set literal.
  if (main) {
    const m = /const VALID_TABS = new Set\((\[[^\]]*\])\);/.exec(main);
    let tabs = null;
    try { tabs = m ? new Function(`return ${m[1]};`)() : null; } catch { tabs = null; }
    check("main.js: VALID_TABS is an extractable array literal", Array.isArray(tabs));
    if (tabs) {
      check("main.js: VALID_TABS lists \"home\"", tabs.includes("home"), tabs.join(","));
      check("main.js: VALID_TABS still lists swap, markets, docs, account (nothing dropped)",
        ["swap", "markets", "docs", "account"].every((t) => tabs.includes(t)));
    }
    const route = funcBody(main, "function routeFromHash(");
    check("main.js: routeFromHash is extractable", route !== null);
    if (route) {
      check("main.js: the EMPTY hash lands on Home (`if (!raw) return { tab: \"home\"`)",
        /if \(!raw\) return \{ tab: "home", subpath: null \};/.test(route));
      check("main.js: an unknown tab falls back to Home, not into the Swap box",
        /VALID_TABS\.has\(tab\) \? tab : "home"/.test(route) && !/: "swap"/.test(route));
    }
    const act = funcBody(main, "function activateTab(");
    check("main.js: activateTab's defensive fallback is Home too",
      act !== null && /if \(!VALID_TABS\.has\(tabName\)\) tabName = "home";/.test(act));
    check("main.js: Home fills its proof strip on entry (refreshHomeFigures on the view switch)",
      act !== null && /tabName === "home" && isSwitchingView[\s\S]{0,80}refreshHomeFigures\(\)/.test(act));
    const sync = funcBody(main, "function syncHashToState(");
    check("main.js: syncHashToState never rewrites the hash while on Home (the bare URL IS Home)",
      sync !== null && /currentTab !== "swap" && currentTab !== "home"/.test(sync));
    // The proof strip reads what the System KPI row reads — no new endpoint.
    const fig = funcBody(main, "async function refreshHomeFigures(");
    check("main.js: refreshHomeFigures exists and reads getVaultValue (the System page's TVL source) + markets[].volume24h",
      fig !== null && /getVaultValue\(\)/.test(fig) && /volume24h/.test(fig) && /fmtUsd\(/.test(fig));
    check("main.js: refreshHomeFigures calls no endpoint the System page does not (getVaultValue only)",
      fig !== null && (fig.match(/\ba\.[a-zA-Z]+\(/g) || []).every((c) => c === "a.getVaultValue("),
      fig && (fig.match(/\ba\.[a-zA-Z]+\(/g) || []).join(" "));
    // The honesty badge is corrected from the posture read, never invented.
    const badge = funcBody(main, "function renderHomePostureBadge(");
    check("main.js: renderHomePostureBadge reads appState.deployMode and hides the badge on an unknown posture",
      badge !== null && /appState\.deployMode/.test(badge) && /display = "none"/.test(badge));
    check("main.js: resolveDeployModeAndBanner also renders the Home badge (one posture read, two consumers)",
      /renderLaunchBanner\(\);\s*renderHomePostureBadge\(\);/.test(main));

    // ── The launch notice (task 1793573913, operator instruction 2026-11-01) ──
    // The first-visit play-mode banner carries the operator's new text
    // VERBATIM; the dismiss key is bumped to v2 so a visitor who dismissed v1
    // sees the new story once; the #dev-only preview handle lets a seat venue
    // show a #play-only notice for a layout smoke. The template is a run of
    // `+`-joined backtick literals, so it is joined the way the browser sees it
    // (literal boundaries dropped) before whole sentences are matched — robust
    // to where the source breaks its lines.
    const lb = funcBody(main, "function renderLaunchBanner(");
    check("main.js: renderLaunchBanner is extractable", lb !== null);
    const LAUNCH_SENTENCES = [
      "<strong>You're early!</strong> MULTI/DEX is written and maintained by AI, while the world's biggest DAO gates its upgrades.",
      "It has no owner, and it runs 100% onchain without any backdoors.",
      "Today, MULTI/DEX is running in \"<strong>Play Mode</strong>\" with dummy assets.",
      "Join, trade, and climb the leaderboard to win prizes.",
      "Production is coming soon…",
    ];
    // Task 1793575027 (operator decision 2026-11-02, option B): on phones the
    // strip collapses to the mark + sentence 1 + the link, and "Read more"
    // discloses sentences 2–5 in place — so the template wraps those four in
    // ONE <span class="launch-rest"> (a structural wrapper the exact-text pin
    // learns; the sentences themselves stay verbatim).
    const LAUNCH_REST = LAUNCH_SENTENCES.slice(1).join(" ");
    const LAUNCH_TEXT = `<span class="launch-mark">✦</span>` + LAUNCH_SENTENCES[0]
      + ` <span class="launch-rest">` + LAUNCH_REST + `</span>`
      + ` <a class="launch-more" href="#docs/launch">Read the story →</a>`;
    let tpl = null;
    if (lb) {
      const m = /el\.innerHTML =\s*(`[\s\S]*?`);\s*const \w+ = document\.createElement\("button"\)/.exec(lb);
      if (m) tpl = m[1].replace(/`\s*\+\s*`/g, "").slice(1, -1);
    }
    check("main.js: renderLaunchBanner's innerHTML is one run of joined template literals (no ${} holes), ending at the first control's creation",
      tpl !== null && !/\$\{/.test(tpl), lb && lb.slice(0, 200));
    if (tpl !== null) {
      for (const s of LAUNCH_SENTENCES) {
        check(`main.js: the launch notice carries the operator's sentence verbatim — "${s.replace(/<\/?strong>/g, "").slice(0, 60)}${s.length > 60 ? "…" : ""}"`, tpl.includes(s), tpl);
      }
      check("main.js: the launch notice is EXACTLY the ✦ mark, sentence 1, sentences 2–5 inside one <span class=\"launch-rest\"> (the operator's order, single-spaced), then the #docs/launch link — nothing added, nothing dropped",
        tpl === LAUNCH_TEXT, tpl);
      check("main.js: .launch-rest wraps sentences 2–5 and ONLY them — one opening tag, one closing tag, sentence 1 and the link outside it",
        (tpl.match(/<span class="launch-rest">/g) || []).length === 1 && (tpl.match(/<\/span>/g) || []).length === 2
        && tpl.includes(`<span class="launch-rest">${LAUNCH_REST}</span>`) && tpl.indexOf(LAUNCH_SENTENCES[0]) < tpl.indexOf(`<span class="launch-rest">`)
        && tpl.indexOf("</span> <a class=\"launch-more\"") > tpl.indexOf(`<span class="launch-rest">`));
      check("main.js: the ✦ mark opens the notice and the 'Read the story →' link to #docs/launch closes it",
        /^<span class="launch-mark">✦<\/span>/.test(tpl) && /<a class="launch-more" href="#docs\/launch">Read the story →<\/a>$/.test(tpl));
      check("main.js: exactly two <strong>s — the opening \"You're early!\" and \"Play Mode\" inside the operator's quotation marks",
        (tpl.match(/<strong>/g) || []).length === 2 && /^<span[^>]*>✦<\/span><strong>You're early!<\/strong> /.test(tpl) && /"<strong>Play Mode<\/strong>"/.test(tpl));
      check("main.js: \"Production is coming soon…\" uses the single ellipsis glyph the codebase uses (never three full stops), and 'onchain' is one word",
        /coming soon…(?:<\/span>)? /.test(tpl) && !/\.\.\./.test(tpl) && /100% onchain/.test(tpl) && !/on-chain/.test(tpl));
      check("main.js: no doubled space anywhere in the notice (the operator's draft carried one before \"100%\")",
        !/  /.test(tpl));
    }
    check("main.js: the pre-2026-11-01 story is gone from renderLaunchBanner — no 'owned by the world', 'ready for the NNS', 'You're early.' (full stop), 'written entirely by AI', lower-case 'play mode'",
      lb !== null && !/owned by the world|ready for the NNS|You're early\.|written entirely by AI|<strong>play mode<\/strong>/.test(lb));
    check("main.js: the notice still shows only when appState.deployMode === \"play\" and not dismissed, hides otherwise, and the ✕ writes \"1\" under LAUNCH_NOTICE_KEY",
      lb !== null && /if \(appState\.deployMode !== "play" \|\| dismissed\) \{\s*el\.style\.display = "none";/.test(lb)
      && /localStorage\.getItem\(LAUNCH_NOTICE_KEY\) === "1"/.test(lb) && /localStorage\.setItem\(LAUNCH_NOTICE_KEY, "1"\)/.test(lb));
    check("main.js: LAUNCH_NOTICE_KEY is the v2 string — a v1 dismissal no longer hides the notice, so returning visitors see the new story once",
      /^const LAUNCH_NOTICE_KEY = "mdx\.launchNoticeHidden\.v2";/m.test(main));
    check("main.js: the key's comment says why it moved (one line: 'v2 2026-11-01: the story changed') right above the const",
      rawMain !== null && /^\/\/ v2 2026-11-01: the story changed\.?\s*\nconst LAUNCH_NOTICE_KEY = /m.test(rawMain));
    check("main.js: the v1 key is spelled nowhere — nothing clears it, nothing reads it (the brief: do not clear the v1 key)",
      !/launchNoticeHidden\.v1/.test(main) && (rawMain === null || !/launchNoticeHidden\.v1/.test(rawMain)));
    // The expand control (task 1793575027): a real <button type="button"> with
    // aria-expanded, appended BEFORE the ✕; its click toggles .expanded on the
    // strip, flips aria-expanded + the label (Read more ↔ Show less) and
    // recomputes --chrome-h; nothing is stored (per visit).
    check("main.js: the expand control is a real button — type=\"button\", class launch-expand, created after the template and appended before the ✕ (banner-dismiss)",
      lb !== null && /const more = document\.createElement\("button"\);\s*more\.type = "button";\s*more\.className = "launch-expand";/.test(lb)
      && lb.indexOf("el.appendChild(more);") > -1 && lb.indexOf("el.appendChild(more);") < lb.indexOf("el.appendChild(b);"));
    check("main.js: the control carries aria-expanded (\"true\"/\"false\" strings) and its label reads \"Read more\" collapsed / \"Show less\" expanded — one setter, applied at paint from the strip's own class",
      lb !== null && /more\.setAttribute\("aria-expanded", on \? "true" : "false"\);\s*more\.textContent = on \? "Show less" : "Read more";/.test(lb)
      && /setExpanded\(el\.classList\.contains\("expanded"\)\);/.test(lb));
    check("main.js: the click toggles .expanded on #launch-banner, re-applies the setter from the toggle's answer and recomputes --chrome-h (updateChromeHeight) — in that order",
      lb !== null && /more\.addEventListener\("click", \(\) => \{\s*setExpanded\(el\.classList\.toggle\("expanded"\)\);\s*updateChromeHeight\(\);\s*\}\);/.test(lb));
    check("main.js: the expanded state is per visit — renderLaunchBanner's only storage write is the ✕'s LAUNCH_NOTICE_KEY flag (no sessionStorage, one localStorage.setItem, 'expanded' reaches no storage call)",
      lb !== null && !/sessionStorage/.test(lb) && (lb.match(/localStorage\.setItem\(/g) || []).length === 1 && !/Storage\.[gs]etItem\([^)]*expanded/.test(lb));
    // The lifted render over a stubbed document: the banner paints the text,
    // the expand control and the ✕ on an un-dismissed #play, hides on a
    // dismissed #play, on #dev and on #production; the control's click is
    // driven (expand, repaint-keeps-state, collapse) and the ✕ still dismisses.
    if (lb !== null) {
      const stubEl = () => {
        const classes = new Set();
        let html = "";
        return {
          get innerHTML() { return html; }, set innerHTML(v) { html = v; this.children.length = 0; },
          style: { display: "none" }, children: [],
          appendChild(c) { this.children.push(c); },
          classList: { contains: (c) => classes.has(c), toggle(c) { if (classes.has(c)) { classes.delete(c); return false; } classes.add(c); return true; } },
        };
      };
      const stubButton = (tag) => ({
        tag, className: "", title: "", textContent: "", attrs: {}, handlers: {},
        setAttribute(k, v) { this.attrs[k] = v; },
        addEventListener(ev, fn) { this.handlers[ev] = fn; },
      });
      const runBanner = ({ deployMode, dismissed = false, el = stubEl() }) => {
        const doc = { getElementById: (id) => (id === "launch-banner" ? el : null), createElement: stubButton };
        const chrome = [], stored = [];
        const fn = new Function("document", "appState", "localStorage", "LAUNCH_NOTICE_KEY", "updateChromeHeight",
          "return function renderLaunchBanner() " + lb)(
          doc, { deployMode }, { getItem: (k) => (k === "K" && dismissed ? "1" : null), setItem: (k, v) => stored.push(`${k}=${v}`) }, "K", () => chrome.push(1));
        fn();
        return { el, chrome, stored, shown: el.style.display === "block" };
      };
      const onPlay = runBanner({ deployMode: "play" });
      const [more, x] = onPlay.el.children;
      check("main.js (lifted): on #play, un-dismissed → the notice paints the operator's text and appends the expand control THEN the ✕ (banner-dismiss), display block, --chrome-h recomputed once",
        onPlay.shown && onPlay.el.innerHTML === LAUNCH_TEXT && onPlay.el.children.length === 2
        && more?.className === "launch-expand" && more?.type === "button" && x?.className === "banner-dismiss" && x?.textContent === "✕" && onPlay.chrome.length === 1,
        onPlay.el.innerHTML);
      check("main.js (lifted): the control paints collapsed — aria-expanded=\"false\", label \"Read more\", the strip without .expanded",
        more?.attrs["aria-expanded"] === "false" && more?.textContent === "Read more" && !onPlay.el.classList.contains("expanded"));
      if (more?.handlers.click) {
        more.handlers.click();
        check("main.js (lifted): one click → .expanded on the strip, aria-expanded=\"true\", label \"Show less\", --chrome-h recomputed again",
          onPlay.el.classList.contains("expanded") && more.attrs["aria-expanded"] === "true" && more.textContent === "Show less" && onPlay.chrome.length === 2);
        const repaint = runBanner({ deployMode: "play", el: onPlay.el });
        check("main.js (lifted): a repaint while expanded (sign-in re-renders) keeps it expanded — the fresh control reads aria-expanded=\"true\" / \"Show less\"; nothing was stored",
          repaint.shown && repaint.el.children.length === 2 && repaint.el.children[0].attrs["aria-expanded"] === "true" && repaint.el.children[0].textContent === "Show less" && repaint.stored.length === 0);
        more.handlers.click();
        check("main.js (lifted): a second click collapses — .expanded gone, aria-expanded=\"false\", \"Read more\", --chrome-h recomputed a third time",
          !onPlay.el.classList.contains("expanded") && more.attrs["aria-expanded"] === "false" && more.textContent === "Read more" && onPlay.chrome.length === 3);
      } else {
        bad("main.js (lifted): the expand control has a click handler", "no click listener on children[0]");
      }
      if (x?.handlers.click) {
        x.handlers.click();
        check("main.js (lifted): the ✕ still writes \"1\" under LAUNCH_NOTICE_KEY, hides the strip and recomputes --chrome-h — the expand control changed none of it",
          onPlay.stored.join(",") === "K=1" && onPlay.el.style.display === "none" && onPlay.chrome.length === 4);
      } else {
        bad("main.js (lifted): the ✕ has a click handler", "no click listener on children[1]");
      }
      const dismissedPlay = runBanner({ deployMode: "play", dismissed: true });
      check("main.js (lifted): on #play, dismissed under the current key → hidden, nothing painted",
        !dismissedPlay.shown && dismissedPlay.el.innerHTML === "");
      check("main.js (lifted): on #dev and on #production → hidden",
        !runBanner({ deployMode: "dev" }).shown && !runBanner({ deployMode: "production" }).shown);
    }
    // The stylesheet half (stats.css, task 1793575027): the control is hidden
    // on desktop; ONE ≤480px block hides .launch-rest, shows the control and
    // lets .expanded bring the rest back — the desktop .launch-banner rules
    // untouched, tokens only.
    const statsCssN4 = must("src/frontend/src/styles/stats.css");
    if (statsCssN4) {
      const body = statsCssN4.replace(/\/\*[\s\S]*?\*\//g, "");
      const mq = /@media \(max-width: 480px\) \{\n([\s\S]*?)\n\}/.exec(body);
      check("stats.css: the launch notice's desktop rules are untouched — .launch-banner keeps padding 9px 16px / 13px / 1.45 / centred, a.launch-more keeps nowrap + margin-left 4px, and .launch-rest is styled ONLY inside the media query (an unstyled inline span on desktop, so desktop renders as before)",
        /\.launch-banner \{\n  padding: 9px 16px;\n  font-size: 13px;\n  line-height: 1\.45;\n  text-align: center;/.test(body)
        && /\.launch-banner a\.launch-more \{[^}]*white-space: nowrap;[^}]*margin-left: 4px;[^}]*\}/.test(body)
        && (body.match(/\.launch-rest\b/g) || []).length === 2 && !/^\.launch-banner(\.expanded)? \.launch-rest/m.test(body));
      check("stats.css: the expand control is display: none outside any media query (desktop never sees it)",
        /^\.launch-banner \.launch-expand \{ display: none; \}$/m.test(body));
      check("stats.css: ONE @media (max-width: 480px) block carries the collapse — .launch-rest display none, .launch-banner.expanded .launch-rest display inline, .launch-expand display inline-block — and NO clearfix: the 1793575027 .launch-banner::after is gone (the ✕ no longer floats on phones, so there is nothing to contain), no clear: both, no flow-root",
        mq !== null && (body.match(/@media \(max-width: 480px\)/g) || []).length === 1
        && !/::after|clear: both|flow-root/.test(mq[1])
        && /^  \.launch-banner \.launch-rest \{ display: none; \}$/m.test(mq[1])
        && /^  \.launch-banner\.expanded \.launch-rest \{ display: inline; \}$/m.test(mq[1])
        && /^  \.launch-banner \.launch-expand \{\n(?:    [^\n]*\n)*    display: inline-block;/m.test(mq[1]));
      // Task 1793577015 (operator option 1, 2026-11-02): on phones the ✕ sits in
      // the strip's top-right corner. The strip is the positioning context with
      // SYMMETRIC 32px side padding (the centred text stays centred; the text
      // column narrows to 336px at 400px) and the control is absolutely placed
      // at top 7px / right 10px, float and margin cleared — the floated ✕ took a
      // 7th line of its own when the strip was expanded at 400px. Phones only:
      // desktop and the fuel/oracle banners keep the shared end-of-text float.
      check("stats.css: inside the ≤480px block the strip is the positioning context with SYMMETRIC 32px side padding — .launch-banner { position: relative; padding-right: 32px; padding-left: 32px; } (one line; the centred text stays centred)",
        mq !== null && /^  \.launch-banner \{ position: relative; padding-right: 32px; padding-left: 32px; \}$/m.test(mq[1]));
      check("stats.css: inside the ≤480px block the ✕ is absolutely placed in the strip's top-right corner — .launch-banner .banner-dismiss { position: absolute; top: 7px; right: 10px; float: none; margin: 0; } (one line)",
        mq !== null && /^  \.launch-banner \.banner-dismiss \{ position: absolute; top: 7px; right: 10px; float: none; margin: 0; \}$/m.test(mq[1]));
      check("stats.css: the corner ✕ is phones-only — .launch-banner .banner-dismiss is spelled ONCE in the file, inside the media query; the desktop .launch-banner rule carries no position; the shared .banner-dismiss rule (the fuel/oracle banners' end-of-text ✕) still opens with float: right outside any media query",
        mq !== null && (body.match(/\.launch-banner \.banner-dismiss\b/g) || []).length === 1 && /\.launch-banner \.banner-dismiss\b/.test(mq[1])
        && !/^\.launch-banner \{[^}]*position:/m.test(body)
        && /^\.banner-dismiss \{\n  float: right;/m.test(body));
      check("stats.css: the control is a text button in the accent — background none, border none, font inherit, color var(--accent), cursor pointer, nowrap — with a :focus-visible ring in the accent (keyboard operable, visibly)",
        mq !== null && /\.launch-banner \.launch-expand \{[^}]*background: none;[^}]*border: none;[^}]*font: inherit;[^}]*color: var\(--accent\);[^}]*cursor: pointer;[^}]*white-space: nowrap;[^}]*\}/.test(mq[1])
        && /\.launch-banner \.launch-expand:focus-visible \{ outline: 2px solid var\(--accent\); outline-offset: 2px; \}/.test(mq[1]));
      check("stats.css: the ≤480px block adds no colour literal — tokens only",
        mq !== null && (mq[1].match(/#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|hsla?\([^)]*\)/g) || []).length === 0);
    }
    // The #dev-only preview handle — a #play-only notice, seen on a seat venue.
    const pv = funcBody(main, "function launchBannerPreview()");
    check("main.js: launchBannerPreview exists and is the window.__mdxLaunchBannerPreview console spelling",
      pv !== null && /^window\.__mdxLaunchBannerPreview = launchBannerPreview;/m.test(main));
    check("main.js: the preview is gated on the ANSWERED #dev posture (as fuelBannerSmoke and devLogin are) — one console line and false anywhere else",
      pv !== null && /if \(!_deployModeAnswered \|\| appState\.deployMode !== "dev"\) \{\s*console\.info\([^)]*\);\s*return false;\s*\}/.test(pv));
    check("main.js: the preview sets the dismissal flag aside, stands the posture in as \"play\" for ONE renderLaunchBanner paint and restores it (try/finally)",
      pv !== null && /localStorage\.removeItem\(LAUNCH_NOTICE_KEY\)/.test(pv)
      && /const saved = appState\.deployMode;\s*appState\.deployMode = "play";\s*try \{ renderLaunchBanner\(\); \} finally \{ appState\.deployMode = saved; \}/.test(pv));
    check("main.js: the preview touches no DOM of its own", pv !== null && !/\bdocument\b|innerHTML|classList|\.style\b/.test(pv));
    if (pv !== null) {
      const lift = ({ deployMode, answered }) => {
        const paints = [], logs = [], removed = [];
        const appState = { deployMode };
        const fn = new Function("_deployModeAnswered", "appState", "renderLaunchBanner", "localStorage", "LAUNCH_NOTICE_KEY", "console",
          "return function launchBannerPreview() " + pv)(
          answered, appState, () => paints.push(appState.deployMode), { removeItem: (k) => removed.push(k) }, "K", { info: (m) => logs.push(m) });
        return { fn, paints, logs, removed, appState };
      };
      const offPlay = lift({ deployMode: "play", answered: true });
      check("main.js (lifted): __mdxLaunchBannerPreview on a play venue → false, one console line, nothing painted, the flag untouched",
        offPlay.fn() === false && offPlay.paints.length === 0 && offPlay.removed.length === 0 && offPlay.logs.length === 1 && /not a #dev venue/.test(offPlay.logs[0]));
      check("main.js (lifted): __mdxLaunchBannerPreview on production → false, nothing painted",
        lift({ deployMode: "production", answered: true }).fn() === false);
      const unanswered = lift({ deployMode: "dev", answered: false });
      check("main.js (lifted): __mdxLaunchBannerPreview with the posture unanswered (state.js's \"dev\" placeholder) → false, nothing painted",
        unanswered.fn() === false && unanswered.paints.length === 0);
      const onDev = lift({ deployMode: "dev", answered: true });
      check("main.js (lifted): __mdxLaunchBannerPreview on a #dev venue clears the flag, paints ONCE as \"play\" and restores \"dev\"",
        onDev.fn() === true && onDev.paints.join(",") === "play" && onDev.removed.join(",") === "K" && onDev.appState.deployMode === "dev" && onDev.logs.length === 0,
        `paints=${onDev.paints.join(",")} removed=${onDev.removed.join(",")} after=${onDev.appState.deployMode}`);
    }
  }

  // N4.2 — the markup.
  if (html) {
    check("index.html: the logo is an anchor to #home with an aria-label (keyboard-reachable Home control)",
      /<a class="logo" href="#home" aria-label="MULTI\/DEX home">/.test(html));
    check("index.html: no <div class=\"logo\"> remains (the lockup is the Home control)",
      !/<div class="logo">/.test(html));
    check("index.html: the logo anchor still wraps the one-shot .logo-shimmer span",
      /<a class="logo" href="#home"[^>]*>\s*<span class="logo-shimmer">/.test(html));
    // The drawer's theme-toggle row (1793489931) heads the list and is deliberately
    // not a .tab; Home is the FIRST .tab — right under it, ahead of Swap.
    const navHome = html.slice(html.indexOf('<nav class="tabs">'), html.indexOf("</nav>"));
    const firstTab = /<button class="tab[^"]*" data-tab="([^"]+)">/.exec(navHome);
    check("index.html: the mobile drawer carries a Home row as the FIRST .tab of the nav (desktop-hidden via .tab-mobile-only), ahead of Swap",
      firstTab !== null && firstTab[1] === "home" && /<button class="tab tab-mobile-only" data-tab="home">Home<\/button>\s*<button class="tab" data-tab="swap">Swap<\/button>/.test(navHome),
      firstTab ? `first .tab: ${firstTab[1]}` : "no .tab found in the nav");
    check("index.html: no nav tab is statically active (activateTab lights the routed one; Home lights none)",
      !/<button class="tab active"/.test(html));
    const start = html.indexOf('<main id="home-view" class="view">');
    check("index.html: a <main id=\"home-view\" class=\"view\"> exists (the same switch as every other view, so the loader clears)", start >= 0);
    if (start >= 0) {
      const end = html.indexOf("<main id=", start + 10);
      const home = html.slice(start, end < 0 ? undefined : end);
      const h1s = home.match(/<h1\b/g) || [];
      check("index.html: exactly one h1 on the Home view", h1s.length === 1, `${h1s.length} h1s`);
      check("index.html: the Home h1 is the shared .strap with the hero line and the Newsreader pay-off word",
        /<h1 class="strap home-strap">Actually decentralized\. Secure\. <span class="strap-accent">Yours\.<\/span><\/h1>/.test(home));
      // 1793553989 — the hero sub-paragraph is the operator's text (2026-11-01), verbatim: the
      // three sentences with their punctuation and Oxford commas as given. Matched on
      // whitespace-collapsed text so the source wrap stays free. The Docs launch blurb (docs.js) is
      // different copy and is NOT pinned here; the "What is MULTI/DEX?" lead that sat below the hero
      // is gone (1793554905 — pinned absent right after this check).
      const heroSubM = /<p class="home-hero-sub">([\s\S]*?)<\/p>/.exec(home);
      const heroSub = heroSubM ? heroSubM[1].replace(/\s+/g, " ").trim() : "";
      check("index.html: the hero sub-paragraph is the operator's paragraph (2026-11-01), verbatim on whitespace-collapsed text — MULTI/DEX isn't owned by a company, involves no servers, and uses no custodian. + the on-chain list updated through NNS votes + nothing to hack but the chain itself",
        heroSubM !== null
          && heroSub.includes("MULTI/DEX isn't owned by a company, involves no servers, and uses no custodian.")
          && heroSub.includes("Everything, including matching engine, order books, AMM, margin, vaults, your trade history, and this very page, is tamperproof code on the Internet Computer that is updated through votes by its autonomous Network Nervous System governance framework.")
          && heroSub.includes("Everything is decentralized, including the multichain asset technology used, there is no one to trust, and nothing to hack but the chain itself."),
        heroSubM ? heroSub : "no .home-hero-sub paragraph on the Home view");
      // 1793554905 — the "What is MULTI/DEX?" intro (eyebrow + lead paragraph) that sat between the
      // hero and the feature boxes is GONE (operator instruction 2026-11-01: too much text), with its
      // .home-intro / .home-intro-lead rules and their ≤900px steps. Read on the Home <main> only: the
      // Docs sidebar and docs.js keep that title for the welcome page, and .home-eyebrow itself stays
      // (the open-source box uses it). The hero's </section> is now followed directly by .home-features.
      check("index.html + home.css: no .home-intro section and no \"What is MULTI/DEX?\" text inside the Home view, the hero section followed directly by <section class=\"home-features\">, and no home-intro rule in home.css (the intro left with 1793554905; the Docs keep the title, .home-eyebrow stays for the open-source box)",
        !/home-intro/.test(home) && !/What is MULTI\/DEX\?/.test(home)
          && /<section\b[^>]*class="home-hero[^"]*"[^>]*>[\s\S]*?<\/section>\s*<section class="home-features"/.test(home)
          && homeCss !== null && !/home-intro/.test(homeCss),
        `home-intro on Home: ${(home.match(/home-intro/g) || []).length}, "What is MULTI/DEX?" on Home: ${(home.match(/What is MULTI\/DEX\?/g) || []).length}, hero → features adjacent: ${/<section\b[^>]*class="home-hero[^"]*"[^>]*>[\s\S]*?<\/section>\s*<section class="home-features"/.test(home)}, home-intro in home.css: ${homeCss ? (homeCss.match(/home-intro/g) || []).length : "unreadable"}`);
      const gh = home.match(/https?:\/\/github\.com\/[^"'\s<)]+/g) || [];
      check("index.html: the Home view links GitHub at least once", gh.length >= 1);
      check("index.html: every GitHub URL on Home is the PUBLIC repository (dfinity/public-multidex) — never the private one",
        gh.length >= 1 && gh.every((u) => /^https:\/\/github\.com\/dfinity\/public-multidex(\/|$|#)/.test(u)), gh.join("\n"));
      const ext = [...home.matchAll(/<a\b[^>]*href="https?:\/\/[^"]*"[^>]*>/g)].map((m) => m[0]);
      check("index.html: every external link on Home opens in a new tab with rel=\"noopener noreferrer\"",
        ext.length >= 1 && ext.every((a) => /target="_blank"/.test(a) && /rel="noopener noreferrer"/.test(a)), ext.join("\n"));
      const ctas = [...home.matchAll(/<a\b[^>]*href="(#[^"]*)"/g)].map((m) => m[1]);
      for (const want of ["#swap", "#docs/welcome", "#markets", "#account/earn", "#ledger", "#system/overview"]) {
        check(`index.html: Home carries a CTA to ${want} (a hash anchor the router handles)`, ctas.includes(want));
      }
      // 1793554039 — the operator's target (2026-11-01): "Read how it works" opens Docs → What is
      // MULTI/DEX? (#docs/welcome), not The Launch. The Home view carries NO #docs/launch CTA at all,
      // so a future edit cannot quietly point the button back; the Docs sidebar, the drawer and the
      // docs.js cross-links keep their own #docs/launch links — this pin reads the Home <main> only.
      check("index.html: Home carries NO CTA to #docs/launch (\"Read how it works\" opens #docs/welcome — What is MULTI/DEX?; the Launch page is linked from the Docs, not the hero)",
        !ctas.includes("#docs/launch") && !/#docs\/launch/.test(home),
        `docs CTAs on Home: ${ctas.filter((h) => h.startsWith("#docs/")).join(" ") || "(none)"}`);
      // 1793554852 — the open-source box carries the operator's copy (2026-11-01), verbatim. The
      // eyebrow "Open source and verifiable" (the CSS uppercases it) is now the section's accessible
      // name through aria-labelledby — the intro section's pattern — and the h2 "Read every line.
      // Then verify the tape." is gone; the three paragraphs became the operator's two, matched on
      // tag-stripped, whitespace-collapsed text so the source wrap stays free. The first paragraph's
      // repo link keeps the full https:// href (the public-repo and external-link pins above read it)
      // with the bare host path as its display text, as the operator wrote it. The issues paragraph's
      // mailto: and its #docs/prizes bounties link left Home with the copy (the Docs keep theirs; the
      // Account view's mailto: is another <main> and is not read here — hence "#docs/prizes" left the
      // CTA list above). The two .stats-cta actions are not copy and stay.
      const openM = /<section class="home-open" aria-labelledby="home-open-head">([\s\S]*?)<\/section>/.exec(home);
      const open = openM ? openM[1] : "";
      check("index.html: the open-source section exists and is labelled by #home-open-head (aria-labelledby kept)", openM !== null);
      check("index.html: the open-source section opens with the eyebrow carrying id=\"home-open-head\" and the text \"Open source and verifiable\" (the eyebrow IS the accessible name now)",
        /^\s*<div class="home-open-text">\s*<div class="home-eyebrow" id="home-open-head">Open source and verifiable<\/div>/.test(open),
        open.replace(/\s+/g, " ").trim().slice(0, 160) || "(no section)");
      check("index.html: no home-open-title element remains on Home (the h2 \"Read every line. Then verify the tape.\" is gone; exactly one element carries id=\"home-open-head\")",
        !/home-open-title/.test(home) && !/Read every line\. Then verify the tape\./.test(home) && (home.match(/id="home-open-head"/g) || []).length === 1,
        `home-open-title: ${(home.match(/home-open-title/g) || []).length}, id="home-open-head": ${(home.match(/id="home-open-head"/g) || []).length}`);
      const openText = (s) => s.replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();
      const openPs = [...open.matchAll(/<p\b[^>]*>([\s\S]*?)<\/p>/g)].map((m) => openText(m[1]));
      check("index.html: the open-source text column carries exactly TWO paragraphs (the issues/bounties paragraph and the hash-chain paragraph are gone)",
        openPs.length === 2, `${openPs.length} paragraphs`);
      check("index.html: open-source paragraph 1 is the operator's sentence, verbatim — MULTI/DEX is the world's only order book exchange whose software code is open source. Access its latest onchain code at github.com/dfinity/public-multidex.",
        openPs[0] === "MULTI/DEX is the world's only order book exchange whose software code is open source. Access its latest onchain code at github.com/dfinity/public-multidex.",
        openPs[0] || "(no first paragraph)");
      check("index.html: open-source paragraph 2 is the operator's sentence, verbatim — It's also the only exchange whose actions and balances are truly verifiable because it's fully onchain and tamperproof, and maintains a tape of everything that happens.",
        openPs[1] === "It's also the only exchange whose actions and balances are truly verifiable because it's fully onchain and tamperproof, and maintains a tape of everything that happens.",
        openPs[1] || "(no second paragraph)");
      const openP1 = /<p\b[^>]*>([\s\S]*?)<\/p>/.exec(open);
      check("index.html: the first paragraph's repo anchor is its ONLY anchor — full https:// href, target=\"_blank\" rel=\"noopener noreferrer\", display text the bare host path github.com/dfinity/public-multidex",
        openP1 !== null && (openP1[1].match(/<a\b/g) || []).length === 1
          && /<a href="https:\/\/github\.com\/dfinity\/public-multidex" target="_blank" rel="noopener noreferrer">github\.com\/dfinity\/public-multidex<\/a>/.test(openP1[1]),
        openP1 ? openP1[1].replace(/\s+/g, " ").trim() : "(no first paragraph)");
      check("index.html: no mailto: anywhere inside the Home view (the issues paragraph left with the copy; the Docs and the Account view keep their own)",
        !/mailto:/.test(home), `mailto: ${(home.match(/mailto:/g) || []).length}`);
      check("index.html: the open-source actions stay — exactly two .stats-cta: \"The repository ↗\" (external) and \"Verify the tape yourself →\" (#ledger)",
        (open.match(/class="stats-cta"/g) || []).length === 2
          && /<a class="stats-cta" href="https:\/\/github\.com\/dfinity\/public-multidex" target="_blank" rel="noopener noreferrer">The repository /.test(open)
          && /<a class="stats-cta" href="#ledger">Verify the tape yourself /.test(open),
        `${(open.match(/class="stats-cta"/g) || []).length} .stats-cta`);
      check("home.css: no .home-open-title rule remains (the base rule and the ≤640px step went with the h2)",
        homeCss !== null && !/home-open-title/.test(homeCss),
        homeCss ? `home-open-title: ${(homeCss.match(/home-open-title/g) || []).length}` : "home.css unreadable");
      check("index.html: no inline click handlers on Home (the router handles every CTA)", !/\son[a-z]+=/i.test(home));
      check("index.html: the proof-strip tiles ship \"—\" (never a placeholder number)",
        ["home-kpi-tvl", "home-kpi-24vol", "home-kpi-markets"].every((id) => new RegExp(`id="${id}">—<`).test(home)));
      check("index.html: the honesty badge carries the Docs' play-mode wording",
        /id="home-posture-badge"[^>]*>[\s\S]{0,120}Live in play mode — trade with free dummy crypto</.test(home));
      // 1793554661 — the three feature boxes (operator instruction 2026-11-01). Each card is ONE
      // shape: a .home-card-thumb figure first, then the title, one paragraph, the CTA. Swap and
      // Markets carry the operator's product screenshots as 800px-wide WebP thumbnails served from
      // /assets/home/ (width/height written so the slot is reserved before the bytes arrive — no
      // CLS; lazy because the boxes sit below the phone fold; a descriptive alt). Earn carries an
      // inline rising-value SVG (aria-hidden, currentColor only, no number anywhere). The copy is
      // the operator's, verbatim on whitespace-collapsed text. The Earn sub-rows are gone — the
      // sentence names the AMM vault and the Insurance Fund itself — and so is the 44px icon.
      const webpDims = (buf) => {
        // RIFF....WEBP + the first chunk's fourcc: "VP8 " (lossy: 3-byte frame tag, the 9d 01 2a
        // start code, then 14-bit width/height), "VP8L" (lossless: 0x2f, then 14-bit w-1/h-1 bit-
        // packed), "VP8X" (extended: 24-bit canvas w-1/h-1 at 24/27). 30 bytes cover all three.
        if (buf.length < 30 || buf.toString("latin1", 0, 4) !== "RIFF" || buf.toString("latin1", 8, 12) !== "WEBP") return null;
        const chunk = buf.toString("latin1", 12, 16);
        if (chunk === "VP8 ") {
          if (buf[23] !== 0x9d || buf[24] !== 0x01 || buf[25] !== 0x2a) return null;
          return { chunk, width: buf.readUInt16LE(26) & 0x3fff, height: buf.readUInt16LE(28) & 0x3fff };
        }
        if (chunk === "VP8L") {
          if (buf[20] !== 0x2f) return null;
          const b = buf.readUInt32LE(21);
          return { chunk, width: (b & 0x3fff) + 1, height: ((b >>> 14) & 0x3fff) + 1 };
        }
        if (chunk === "VP8X") return { chunk, width: buf.readUIntLE(24, 3) + 1, height: buf.readUIntLE(27, 3) + 1 };
        return null;
      };
      const cards = [...home.matchAll(/<article class="home-card[^"]*">([\s\S]*?)<\/article>/g)].map((m) => m[1]);
      check("index.html: the Home features section carries exactly three .home-card articles — Swap, Markets, Earn, in that order",
        cards.length === 3 && /home-card-title">Swap</.test(cards[0] || "") && /home-card-title">Markets</.test(cards[1] || "") && /home-card-title">Earn</.test(cards[2] || ""),
        `${cards.length} cards`);
      check("index.html: every card opens with a .home-card-thumb figure (its FIRST element), then .home-card-title, exactly one .home-card-copy, then the .stats-cta — one shape for all three",
        cards.length === 3 && cards.every((c) => /^\s*<div class="home-card-thumb">/.test(c)
          && c.indexOf('class="home-card-thumb"') < c.indexOf('class="home-card-title"')
          && c.indexOf('class="home-card-title"') < c.indexOf('class="home-card-copy"')
          && c.indexOf('class="home-card-copy"') < c.indexOf('class="stats-cta"')
          && (c.match(/class="home-card-copy"/g) || []).length === 1));
      check("index.html: three .home-card-thumb figures on Home, and no .home-card-icon / .home-earn-row remains (the 44px icon and the Earn sub-rows are gone)",
        (home.match(/class="home-card-thumb"/g) || []).length === 3 && !/home-card-icon/.test(home) && !/home-earn-row/.test(home));
      // The two screenshots: the <img> inside the thumb, parsed attribute by attribute.
      const thumbImg = (file) => {
        const m = new RegExp(`<img\\b[^>]*\\bsrc="/assets/home/${file}"[^>]*>`).exec(home);
        if (!m) return null;
        const tag = m[0];
        const attr = (n) => { const a = new RegExp(`\\b${n}="([^"]*)"`).exec(tag); return a ? a[1] : null; };
        return { tag, width: attr("width"), height: attr("height"), alt: attr("alt"), loading: attr("loading"), decoding: attr("decoding") };
      };
      const thumbs = { "swap.webp": thumbImg("swap.webp"), "markets.webp": thumbImg("markets.webp") };
      for (const [file, img] of Object.entries(thumbs)) {
        check(`index.html: the ${file} thumbnail is an <img src="/assets/home/${file}"> first inside a .home-card-thumb, with numeric width/height, a descriptive alt (≥ 40 chars), loading="lazy" and decoding="async"`,
          img !== null && /^\d+$/.test(img.width || "") && /^\d+$/.test(img.height || "") && (img.alt || "").trim().length >= 40
            && img.loading === "lazy" && img.decoding === "async"
            && new RegExp(`<div class="home-card-thumb">\\s*<img\\b[^>]*\\bsrc="/assets/home/${file}"`).test(home),
          img ? img.tag : `no <img src="/assets/home/${file}"> on Home`);
      }
      check("index.html: the Swap alt names the price chart and the order book; the Markets alt names the candles, the order book and the order form",
        /chart/i.test(thumbs["swap.webp"]?.alt || "") && /order book/i.test(thumbs["swap.webp"]?.alt || "")
          && /candle/i.test(thumbs["markets.webp"]?.alt || "") && /order book/i.test(thumbs["markets.webp"]?.alt || "")
          && /order form|place order/i.test(thumbs["markets.webp"]?.alt || ""));
      // The files themselves: under the public dir (vite root src/frontend — they ship at
      // /assets/home/…), each ≤ 80 KB (the target was ≤ 60), and their pixel size IS what the
      // markup declares — the WebP header is parsed, so a re-export that changes shape without
      // the attributes following it fails here, not as layout shift in a browser.
      for (const [file, img] of Object.entries(thumbs)) {
        const p = path(`src/frontend/public/assets/home/${file}`);
        const exists = existsSync(p);
        const size = exists ? statSync(p).size : -1;
        check(`public/assets/home/${file}: exists and is ≤ 80 KB`, exists && size > 0 && size <= 80 * 1024, exists ? `${size} bytes` : "missing");
        const dims = exists ? webpDims(readFileSync(p)) : null;
        check(`public/assets/home/${file}: a well-formed WebP (VP8 / VP8L / VP8X header parsed) whose pixel size equals the <img> width/height attributes`,
          dims !== null && img !== null && String(dims.width) === img.width && String(dims.height) === img.height,
          `${dims ? `${dims.chunk} ${dims.width}x${dims.height}` : "header not parsed"} vs attributes ${img ? `${img.width}x${img.height}` : "none"}`);
        check(`public/assets/home/${file}: 800px wide (2x the ~350px desktop slot) with the source's own aspect kept (height between 400 and 800)`,
          dims !== null && dims.width === 800 && dims.height >= 400 && dims.height <= 800, dims ? `${dims.width}x${dims.height}` : "no dims");
      }
      // The Earn graphic: an inline SVG in the same thumb box, aspect-matched to the screenshots,
      // decorative (aria-hidden), themed through currentColor only, carrying nothing readable.
      const earnThumb = cards.length === 3 ? /<div class="home-card-thumb">([\s\S]*?)<\/div>/.exec(cards[2]) : null;
      const earnSvg = earnThumb ? /<svg\b[\s\S]*?<\/svg>/.exec(earnThumb[1]) : null;
      check("index.html: the Earn thumb holds an inline <svg aria-hidden=\"true\"> (no <img>) with viewBox=\"0 0 800 459\" — the screenshots' aspect, so the three card tops align",
        earnSvg !== null && /<svg\b[^>]*\baria-hidden="true"/.test(earnSvg[0]) && /<svg\b[^>]*\bviewBox="0 0 800 459"/.test(earnSvg[0]) && !/<img\b/.test(earnThumb[1]));
      if (earnSvg) {
        const svg = earnSvg[0];
        const paints = [...svg.matchAll(/\b(?:fill|stroke|stop-color|color)="([^"]*)"/g)].map((m) => m[1]);
        check("index.html: every paint on the Earn SVG is currentColor, none, a var(--…) token or a url(#…) gradient of those — no colour literal (hex, rgb/hsl, named)",
          paints.length >= 2 && paints.every((v) => v === "currentColor" || v === "none" || /^var\(--[\w-]+\)$/.test(v) || /^url\(#[\w-]+\)$/.test(v)),
          paints.join(" "));
        check("index.html: the Earn SVG carries no style attribute and no colour literal anywhere in its markup",
          !/\bstyle="/.test(svg) && !/#[0-9a-fA-F]{3,8}\b/.test(svg.replace(/url\(#[\w-]+\)/g, "").replace(/id="[^"]*"/g, "")) && !/rgba?\(|hsla?\(/.test(svg));
        check("index.html: the Earn SVG is drawn with paths (a rising line) and has NO text content at all — no <text>, no number, nothing readable as a yield figure",
          /<path\b/.test(svg) && !/<text\b/.test(svg) && svg.replace(/<[^>]+>/g, "").trim() === "");
        check("index.html: the Earn SVG stays under 1.5 KB of markup", svg.length <= 1536, `${svg.length} bytes`);
      }
      // The copy — the operator's three sentences (2026-11-01), verbatim on whitespace-collapsed text.
      const copyOf = (c) => { const m = /<p class="home-card-copy">([\s\S]*?)<\/p>/.exec(c); return m ? m[1].replace(/\s+/g, " ").trim() : null; };
      const COPY = [
        "Directly swap digital asset tokens you own for others, without the hassle of first selling into a currency token, then using that to buy the other.",
        "Powerful traditional order book markets where you can instantly trade at spot, or automatically create short and long positions using leverage.",
        "If you don't want to trade, you can earn yield on your assets by depositing them into the Automated Market Maker's vault, or the Insurance Fund.",
      ];
      ["Swap", "Markets", "Earn"].forEach((title, i) => {
        check(`index.html: the ${title} card's copy is the operator's sentence (2026-11-01), verbatim on whitespace-collapsed text`,
          cards.length === 3 && copyOf(cards[i]) === COPY[i], cards[i] ? copyOf(cards[i]) : "no card");
      });
      check("index.html: the old Earn sub-row copy is gone — no fee-split quote, no .home-earn-name rows (the operator's sentence names both the vault and the Insurance Fund itself)",
        !/half of\s+every trading fee/.test(home) && !/home-earn-name/.test(home));
      check("index.html: Home quotes nothing the UI does not offer (no post-only claim; the order form has Limit/Market)",
        !/post-only/i.test(home));
    }
    // The Swap strap is Swap-specific again — the two pages do not repeat.
    check("index.html: the Swap h1 is the shared .strap carrying the operator's Swap line 'Directly swap digital assets. No middleman.' (2026-11-01; not the Home hero line)",
      /<h1 class="strap swap-strap">Directly swap digital assets\. <span class="strap-accent">No middleman\.<\/span><\/h1>/.test(html));
    check("index.html: the hero line appears exactly once (Home), not on Swap too",
      (html.match(/Actually decentralized\. Secure\./g) || []).length === 1);
  }

  // N4.3 — the stylesheet: wired in, tokens only, the strap shared.
  check("styles.css: the barrel imports home.css", barrel !== null && /@import "\.\/styles\/home\.css";/.test(barrel));
  if (homeCss) {
    const body = homeCss.replace(/\/\*[\s\S]*?\*\//g, "");
    const literals = body.match(/#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|hsla?\([^)]*\)/g) || [];
    check("home.css: no new colour literals — tokens (var(--…)) and color-mix() of tokens only", literals.length === 0, literals.join(" "));
    // 1793554661 — one aspect box for all three cards; tokens only (the literal pin above stays).
    check("home.css: .home-card-thumb is the one aspect box for all three cards — aspect-ratio 800 / 459, overflow hidden, var(--radius-sm), a 1px var(--border) frame, a panel token background, color var(--accent) (the Earn SVG paints in currentColor)",
      /\.home-card-thumb \{[^}]*aspect-ratio: 800 \/ 459;[^}]*overflow: hidden;[^}]*border-radius: var\(--radius-sm\);[^}]*border: 1px solid var\(--border\);[^}]*background: var\(--bg-[\w-]+\);[^}]*color: var\(--accent\);[^}]*\}/.test(body));
    check("home.css: .home-card-thumb img and svg fill the box — width/height 100%, object-fit cover, object-position top left (the Swap card / Markets chart stay in frame when the taller capture is cropped), display block",
      /\.home-card-thumb img, \.home-card-thumb svg \{[^}]*width: 100%;[^}]*height: 100%;[^}]*object-fit: cover;[^}]*object-position: top left;[^}]*display: block;[^}]*\}/.test(body));
    check("home.css: the .home-card-icon and .home-earn-rows/-row/-name/-copy rules are gone (nothing on Home uses them any more)",
      !/\.home-card-icon\b/.test(body) && !/\.home-earn-(rows|row|name|copy)\b/.test(body));
    check("home.css: opens with a design note recording the strap's move, the badge and why no nav tab",
      /DESIGN NOTE/.test(homeCss) && /MOVED here from Swap/.test(homeCss) && /badge/.test(homeCss) && /No nav tab/.test(homeCss));
    check("home.css: the feature boxes stack on narrow screens (a max-width ≤ 768px rule sets one column)",
      /@media \(max-width: 768px\)[\s\S]{0,200}\.home-features \{ grid-template-columns: 1fr/.test(body));
    check("home.css: does not redefine the shared .strap base (it lives in swap.css; .home-strap only sizes up)",
      !/^\.strap\s*\{/m.test(body) && /\.home-strap\s*\{/.test(body));
  }
  const swapCss = must("src/frontend/src/styles/swap.css");
  check("swap.css: the strap is the SHARED .strap (+ .strap .strap-accent), not a Swap-only selector",
    swapCss !== null && /^\.strap \{/m.test(swapCss) && /^\.strap \.strap-accent \{/m.test(swapCss) && !/^\.swap-strap/m.test(swapCss));
}


// ════════════════════════════════════════════════════════════════════
// O. The #dev-login pill (task 1793497426): the header reads LOCAL DEV
//    IDENTITY while a seat venue's throwaway identity is signed in — through
//    the ordinary renderProfileChip path, the label spelled once, in the hook
// ════════════════════════════════════════════════════════════════════
{
  const rawMainO = must("src/frontend/src/main.js");
  const mainO = rawMainO === null ? null : stripJsComments(rawMainO);
  const headerCssO = must("src/frontend/src/styles/header.css");
  const htmlO = must("src/frontend/index.html");
  if (mainO) {
    const chip = funcBody(mainO, "function renderProfileChip()");
    check("O: renderProfileChip is extractable", chip !== null);
    if (chip) {
      check("O: the desktop pill's name reads devLoginPillName() first, then the username, then the dash",
        /const pillName = devLoginPillName\(\);/.test(chip) && /nameEl\.textContent = pillName \|\| userProfile\.username \|\| "—"/.test(chip));
      check("O: the drawer pill mirrors it (pillName || username || \"Account\")",
        /dNameEl\.textContent = pillName \|\| userProfile\.username \|\| "Account"/.test(chip));
      check("O: both name slots toggle the dev-identity class with the label, and drop it on the signed-out path",
        /nameEl\.classList\.toggle\("dev-identity", !!pillName\)/.test(chip) && /dNameEl\.classList\.toggle\("dev-identity", !!pillName\)/.test(chip)
        && /nameEl\.classList\.remove\("dev-identity"\)/.test(chip) && /dNameEl\.classList\.remove\("dev-identity"\)/.test(chip));
      check("O: the identicon still seeds from the USERNAME — the label never reaches setIdenticon",
        /setIdenticon\(avatarEl, userProfile\.username, initial\)/.test(chip) && /setIdenticon\(dAvatarEl, userProfile\.username, initial\)/.test(chip)
        && !/setIdenticon\([^)]*pillName/.test(chip));
      check("O: the label is not spelled in renderProfileChip (it comes from the hook's one constant)", !/LOCAL DEV IDENTITY/.test(chip));
      check("O: the chip still gates on isAuthenticated && userProfile and flips .header.authed (the dev identity shows the pill the way any sign-in does)",
        /const authed = !!\(appState\.isAuthenticated && userProfile\);/.test(chip) && /header\.classList\.toggle\("authed", authed\)/.test(chip));
    }
    const pill = funcBody(mainO, "function devLoginPillName()");
    check("O: devLoginPillName answers the label only while the dev identity is active, null otherwise",
      pill !== null && /devIdentityActive \? DEV_LOGIN_PILL : null/.test(pill));
    check("O: DEV_LOGIN_PILL is the ONE place the label is spelled in main.js, and it reads LOCAL DEV IDENTITY",
      (mainO.match(/LOCAL DEV IDENTITY/g) || []).length === 1 && /const DEV_LOGIN_PILL = "LOCAL DEV IDENTITY";/.test(mainO));
  }
  if (headerCssO) {
    const body = headerCssO.replace(/\/\*[\s\S]*?\*\//g, "");
    check("O: header.css lifts the 140px username cap for .user-menu-name.dev-identity and the drawer's #drawer-acct-name.dev-identity (the label is never clipped), amber ink via the --cta-ink token",
      /\.user-menu-name\.dev-identity, #drawer-acct-name\.dev-identity \{ max-width: none; color: var\(--cta-ink\);/.test(body));
    const devRules = body.match(/\.dev-identity[^{]*\{[^}]*\}/g) || [];
    check("O: the dev-identity rule uses tokens only — no colour literal", devRules.length === 1 && !/#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\(/.test(devRules[0]), devRules.join(" "));
    check("O: the username cap itself is unchanged (140px, ellipsis)",
      /\.user-menu-name \{ max-width: 140px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; \}/.test(body));
  }
  if (htmlO) {
    check("O: index.html carries neither the dev-identity class nor the label — the pill is only ever set by renderProfileChip",
      !/dev-identity|LOCAL DEV IDENTITY/.test(htmlO.replace(/<!--[\s\S]*?-->/g, "")));
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
