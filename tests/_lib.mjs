// tests/_lib.mjs — shared helpers for the plain-node frontend suites
// (frontend_security.test.mjs, frontend_display_integrity.test.mjs).
//
// Same doctrine as _lib.sh: no dependencies, no build step, importable by any
// suite that needs it. Kept out of the `*.test.mjs` glob that run_all.sh
// discovers by the leading underscore — this file asserts nothing itself.

// ── Comment stripping ───────────────────────────────────────────────
// Every assertion in these suites is about CODE. The frontend files are
// heavily commented, and the comments necessarily quote the very patterns
// being banned ("this used to be `onerror=…`", "a bare 1000 is $0.00001"), so
// scanning raw text would make a suite fail on its own documentation — and,
// worse, would let someone silence a real failure by rewording a comment.
// Strip first, then match.
//
// String- and regex-aware: `//` inside "https://…" is not a comment, and a
// regex literal may contain a slash. Regex-vs-divide is resolved by the usual
// "previous significant token" heuristic, which is sufficient for these files.
export function stripJsComments(src) {
  let out = "";
  let i = 0;
  let prev = "";                       // last significant char emitted
  let inTmpl = false;                  // scanning template TEXT (W5-11)
  const tmplDepth = [];                // brace depth per open ${…}
  const REGEX_OK = "(,=:[!&|?{};+-*%~^<>\n";
  while (i < src.length) {
    const c = src[i];
    const d = src[i + 1];
    if (c === "/" && d === "/") { while (i < src.length && src[i] !== "\n") i++; continue; }
    if (c === "/" && d === "*") {
      i += 2;
      while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) i++;
      i += 2;
      continue;
    }
    if (c === '"' || c === "'") {
      const quote = c;
      out += c; i++;
      while (i < src.length) {
        if (src[i] === "\\") { out += src.slice(i, i + 2); i += 2; continue; }
        out += src[i];
        if (src[i] === quote) { i++; break; }
        i++;
      }
      prev = quote;
      continue;
    }
    // Template literals nest through their interpolations (W5-11): `a ${ `b` } c`
    // used to close at the INNER backtick, and from there the scanner was out
    // of phase — code scanned as string, string as code — until it happened to
    // re-synchronise, with every needle fed from that window failing open.
    // `tmplDepth` stacks one brace counter per open ${…}; a backtick in code
    // enters template TEXT, `${` re-enters code, and the `}` that zeroes the
    // top counter returns to the enclosing template's text.
    if (c === "`") {
      out += c; i++;
      inTmpl = true;
      // scan template TEXT inline (below) via the inTmpl flag
      while (i < src.length && inTmpl) {
        if (src[i] === "\\") { out += src.slice(i, i + 2); i += 2; continue; }
        if (src[i] === "`") { out += "`"; i++; inTmpl = false; break; }
        if (src[i] === "$" && src[i + 1] === "{") {
          out += "${"; i += 2; tmplDepth.push(1); inTmpl = false; break;
        }
        out += src[i]; i++;
      }
      prev = "`";
      continue;
    }
    if (tmplDepth.length > 0 && c === "{") { tmplDepth[tmplDepth.length - 1]++; }
    if (tmplDepth.length > 0 && c === "}") {
      tmplDepth[tmplDepth.length - 1]--;
      if (tmplDepth[tmplDepth.length - 1] === 0) {
        // interpolation over — back into the enclosing template's TEXT
        tmplDepth.pop();
        out += c; i++;
        while (i < src.length) {
          if (src[i] === "\\") { out += src.slice(i, i + 2); i += 2; continue; }
          if (src[i] === "`") { out += "`"; i++; break; }
          if (src[i] === "$" && src[i + 1] === "{") { out += "${"; i += 2; tmplDepth.push(1); break; }
          out += src[i]; i++;
        }
        prev = "`";
        continue;
      }
    }
    if (c === "/" && REGEX_OK.includes(prev)) {           // regex literal
      out += c; i++;
      while (i < src.length) {
        if (src[i] === "\\") { out += src.slice(i, i + 2); i += 2; continue; }
        if (src[i] === "[") { while (i < src.length && src[i] !== "]") { out += src[i]; i++; } }
        out += src[i];
        if (src[i] === "/") { i++; break; }
        i++;
      }
      prev = "/";
      continue;
    }
    out += c;
    if (!/\s/.test(c)) prev = c;
    i++;
  }
  return out;
}
