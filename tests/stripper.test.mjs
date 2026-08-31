#!/usr/bin/env node
// tests/stripper.test.mjs — the shared JS stripper is itself an oracle for
// BOTH node suites, so it gets its own fixtures (OhShii #38.3 / W5-11).
//
// The defect class: a template literal whose ${…} interpolation contains
// ANOTHER template used to close at the INNER backtick — from there the
// scanner was out of phase (code scanned as string, string as code) and
// every needle fed from that window failed open, silently weakening
// whichever assertions read through it.

import { stripJsComments } from "./_lib.mjs";

let passed = 0, failed = 0;
function check(name, cond, detail) {
  if (cond) { passed++; console.log(`✓ ${name}`); }
  else { failed++; console.log(`✗ ${name}`); if (detail) console.log(`    ${detail}`); }
}

// ── Baseline sanity (the behaviour the suites already rely on) ──────
{
  const s = stripJsComments(`const a = 1; // gone\nconst b = "https://kept";`);
  check("line comment stripped", !s.includes("gone"));
  check("// inside a string survives", s.includes("https://kept"));
  const t = stripJsComments(`/* gone */ const c = 2;`);
  check("block comment stripped", !t.includes("gone") && t.includes("const c"));
}

// ── The finding: nested template must not desynchronise ─────────────
{
  // outer template ─ interpolation ─ inner template ─ then real CODE with a
  // comment. Pre-fix: the outer "closes" at the inner backtick, the scanner
  // re-enters "code" inside what is really template text, and the trailing
  // comment (real code!) is mis-scanned as string — the banned pattern
  // inside it is NOT stripped and phase-dependent needles invert.
  const src = 'const msg = `outer ${ `inner` } tail`;\n'
            + 'dangerous_call(); // BANNED_IN_COMMENT\n';
  const s = stripJsComments(src);
  check("nested template: trailing code still scanned as code",
    s.includes("dangerous_call"), `got: ${JSON.stringify(s)}`);
  check("nested template: comment after the template is stripped",
    !s.includes("BANNED_IN_COMMENT"), `got: ${JSON.stringify(s)}`);
  check("nested template: template text kept (needles may pin it)",
    s.includes("outer") && s.includes("inner") && s.includes("tail"));
}

// ── A banned pattern placed after a nested template is still caught ─
{
  // The consuming suites match needles against the STRIPPED text; a real
  // call after the template must be present, a commented one absent.
  const src = 'const a = `x ${ cond ? `y${deep}` : "z" } w`;\n'
            + 'element.innerHTML = user;  // was onerror=… once\n';
  const s = stripJsComments(src);
  check("needle after deep nesting: live innerHTML visible",
    s.includes("element.innerHTML = user"), `got: ${JSON.stringify(s)}`);
  check("needle after deep nesting: the comment's decoy is stripped",
    !s.includes("onerror"));
}

// ── Desync inverts BOTH directions; pin each ────────────────────────
{
  // Inner-template TEXT is string content; "//" inside it is literal text.
  // Pre-fix the scanner was in CODE phase there and stripped it — an
  // assertion pinning that text would fail open.
  const src = 'const u = `o ${ `path //keep-me` } t`;';
  const s = stripJsComments(src);
  check("'//' inside nested template TEXT survives (it is string, not comment)",
    s.includes("//keep-me"), `got: ${JSON.stringify(s)}`);
}

// ── Interpolation CODE is scanned as code (comments in it stripped) ─
{
  const src = 'const q = `a ${ f(/* dead */ x) } b`;';
  const s = stripJsComments(src);
  check("comment inside an interpolation is stripped", !s.includes("dead"));
  check("interpolation code kept", s.includes("f(") && s.includes("x)"));
}

// ── Braces inside an interpolation do not pop it early ──────────────
{
  const src = 'const r = `n ${ JSON.stringify({ k: `v` }) } m`;\nlive();// note\n';
  const s = stripJsComments(src);
  check("object literal inside ${} does not end the template early",
    s.includes("live()") && !s.includes("note"), `got: ${JSON.stringify(s)}`);
}

console.log("");
if (failed === 0) { console.log(`PASS — ${passed} assertions`); process.exit(0); }
else { console.log(`FAIL — ${failed} of ${passed + failed}`); process.exit(1); }
