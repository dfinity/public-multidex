// ── Theme: dark / light ────────────────────────────────────────────
// The app is dark-first: base.css's bare :root is the dark token table and
// :root[data-theme="light"] re-states every token for the light theme. This
// module owns everything that CHOOSES between them after the first paint:
//
//   · the sun/moon toggle buttons ([data-theme-toggle] — the round one at the
//     far right of the header and the row at the top of the mobile drawer),
//     their aria-label / aria-pressed / title, kept in step on every change;
//   · persistence — a click saves "dark" | "light" under localStorage
//     "mdx.theme" (wrapped: private windows and some embedded browsers throw
//     on storage, and a theme must never take the page down);
//   · following the system preference (prefers-color-scheme) LIVE until the
//     user has picked — the saved choice, once made, wins over the system
//     and over later system flips;
//   · the <meta name="theme-color"> (mobile browser chrome), stamped from the
//     theme's computed --bg-card;
//   · the `mdx:theme` document event, fired on every actual change, which the
//     lightweight-charts instances, the liquidation heat map and the
//     identicons re-skin on — none of them watch CSS, so each re-reads the
//     tokens through themeToken() below.
//
// The FIRST paint is not this module's job: /theme-boot.js (public/, a
// classic render-blocking script in <head> ahead of the stylesheet) applies
// the same precedence before any CSS arrives, so a light-mode reload never
// flashes dark. setupTheme() reconciles with what it stamped and only decides
// itself when that script failed to run.

const KEY = "mdx.theme";
const EVENT = "mdx:theme";
const THEMES = ["dark", "light"];

function savedChoice() {
  try {
    const v = localStorage.getItem(KEY);
    return THEMES.includes(v) ? v : null;
  } catch { return null; }
}
function saveChoice(theme) {
  try { localStorage.setItem(KEY, theme); } catch { /* storage unavailable — the choice lives for this page only */ }
}

export function systemTheme() {
  try { return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark"; }
  catch { return "dark"; }
}

export function currentTheme() {
  return document.documentElement.getAttribute("data-theme") === "light" ? "light" : "dark";
}

// A design token's CURRENT value — the theme in force decides which block of
// base.css answers. Chart/canvas tokens are authored as concrete rgba()/hex
// strings there precisely so this returns something lightweight-charts and
// the canvas can parse (they do not understand color-mix()).
export function themeToken(name, fallback = "") {
  try {
    const v = getComputedStyle(document.documentElement).getPropertyValue(name);
    return (v && v.trim()) || fallback;
  } catch { return fallback; }
}

function syncToggles(theme) {
  const next = theme === "light" ? "dark" : "light";
  const label = `Switch to ${next} mode`;
  document.querySelectorAll("[data-theme-toggle]").forEach((btn) => {
    // aria-pressed answers "is light mode on?" — the toggle is a switch
    // between two states, and the label names the action a press performs.
    btn.setAttribute("aria-pressed", theme === "light" ? "true" : "false");
    btn.setAttribute("aria-label", label);
    btn.setAttribute("title", label);
    const text = btn.querySelector(".theme-toggle-label");
    if (text) text.textContent = label;
  });
}

function syncMeta(theme) {
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute("content", themeToken("--bg-card", theme === "light" ? "#FFFFFF" : "#151B24"));
}

// Apply a theme now. `persist` is the user's own pick (the toggle); the
// system-following path and the reconcile at boot leave storage alone, so
// "no saved choice" keeps meaning "follow the system".
export function applyTheme(theme, { persist = false } = {}) {
  const t = THEMES.includes(theme) ? theme : "dark";
  const before = currentTheme();
  document.documentElement.setAttribute("data-theme", t);
  if (persist) saveChoice(t);
  syncToggles(t);
  syncMeta(t);
  if (before !== t) document.dispatchEvent(new CustomEvent(EVENT, { detail: { theme: t } }));
}

export function toggleTheme() {
  applyTheme(currentTheme() === "light" ? "dark" : "light", { persist: true });
}

// Subscribe to theme changes; returns the unsubscribe.
export function onThemeChange(fn) {
  const handler = (e) => fn(e.detail && e.detail.theme ? e.detail.theme : currentTheme());
  document.addEventListener(EVENT, handler);
  return () => document.removeEventListener(EVENT, handler);
}

export function setupTheme() {
  const root = document.documentElement;
  // Reconcile with the pre-paint stamp; decide ourselves only if it is missing
  // (theme-boot.js blocked or failed) — same precedence, just later.
  if (!root.getAttribute("data-theme")) root.setAttribute("data-theme", savedChoice() || systemTheme());
  syncToggles(currentTheme());
  syncMeta(currentTheme());

  document.querySelectorAll("[data-theme-toggle]").forEach((btn) => {
    btn.addEventListener("click", toggleTheme);
  });

  // Follow the OS while the user has not chosen. (Safari < 14 only has the
  // deprecated addListener; harmless to support.)
  try {
    const mq = window.matchMedia("(prefers-color-scheme: light)");
    const follow = () => { if (!savedChoice()) applyTheme(mq.matches ? "light" : "dark"); };
    if (typeof mq.addEventListener === "function") mq.addEventListener("change", follow);
    else if (typeof mq.addListener === "function") mq.addListener(follow);
  } catch { /* no matchMedia — stay as stamped */ }

  // A choice made in another tab of this origin reaches this one (storage
  // events fire cross-tab only), so every open tab agrees.
  window.addEventListener("storage", (e) => {
    if (e.key === KEY || e.key === null) applyTheme(savedChoice() || systemTheme());
  });
}

// ── Chart skins (lightweight-charts) ─────────────────────────────
// The chart library takes colours as plain strings at createChart / addSeries
// and never looks at CSS again, so main.js applies these at creation AND
// re-applies them from an onThemeChange subscriber. Every value is a token
// from base.css's chart block; the fallbacks are the dark set, so a chart
// created before the stylesheet has resolved (it cannot, in practice) still
// reads as the dark app.
export function chartThemeOptions() {
  const grid = themeToken("--chart-grid", "rgba(34,46,64,0.5)");
  const border = themeToken("--chart-border", "rgba(34,46,64,0.7)");
  const cross = themeToken("--chart-crosshair", "rgba(59,184,212,0.5)");
  return {
    layout: {
      textColor: themeToken("--chart-text", "#7A8699"),
      panes: {
        separatorColor: border,
        separatorHoverColor: themeToken("--chart-separator-hover", "rgba(59,184,212,0.35)"),
      },
    },
    grid: { vertLines: { color: grid }, horzLines: { color: grid } },
    crosshair: { vertLine: { color: cross }, horzLine: { color: cross } },
    timeScale: { borderColor: border },
    rightPriceScale: { borderColor: border },
  };
}

export function candleThemeOptions() {
  const up = themeToken("--chart-up", "#5EE6B4");
  const down = themeToken("--chart-down", "#F07A6C");
  return { upColor: up, downColor: down, borderUpColor: up, borderDownColor: down, wickUpColor: up, wickDownColor: down };
}

// Per-bar volume colour (histogram items carry their own colour).
export function volumeBarColor(up) {
  return up ? themeToken("--chart-up-vol", "rgba(94,230,180,0.4)") : themeToken("--chart-down-vol", "rgba(240,122,108,0.4)");
}

// The oracle-tracking accent: clock-fill candles and the Swap page's rate line.
export function chartTrackColor() {
  return themeToken("--chart-track", "rgba(56,189,240,0.9)");
}
