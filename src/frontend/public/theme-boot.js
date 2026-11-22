// ── Theme bootstrap (runs BEFORE the stylesheet, before any paint) ──────
// Stamps <html data-theme="dark|light"> so the very first paint is already
// the right theme — no flash of dark on a light-mode reload or vice versa.
// Loaded from index.html's <head> as a classic, render-blocking script that
// sits ABOVE the stylesheet <link>: the parser cannot reach <body> (nothing
// to paint) until this has run, and the CSS that keys on data-theme arrives
// after it. Served from public/ at the stable path /theme-boot.js — the CSP
// is script-src 'self' (public/_headers), which forbids an inline
// block, and tests/frontend_security.test.mjs pins that index.html carries
// none. Nothing here is bundled, so it must stay plain ES5-ish and
// self-contained.
//
// Precedence (the same rule theme.js applies afterwards, with the toggle):
//   1. the saved choice — localStorage "mdx.theme" ("dark" | "light")
//   2. else the system preference, prefers-color-scheme (followed live by
//      theme.js until the user picks)
//   3. else dark (the app is dark-first; the bare :root tokens are dark)
// localStorage access is wrapped: private windows and some embedded
// browsers throw on it, and a theme must never take the page down.
(function () {
  var KEY = "mdx.theme";
  var saved = null;
  try { saved = window.localStorage.getItem(KEY); } catch (e) { saved = null; }
  var choice = (saved === "light" || saved === "dark") ? saved : null;
  var system = "dark";
  try {
    if (window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches) system = "light";
  } catch (e) { system = "dark"; }
  var theme = choice || system;
  var root = document.documentElement;
  root.setAttribute("data-theme", theme);
  // Browser chrome colour (the mobile address bar) — the theme's --bg-card;
  // theme.js re-stamps it from the computed token once the stylesheet is in.
  var meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute("content", theme === "light" ? "#FFFFFF" : "#151B24");
})();
