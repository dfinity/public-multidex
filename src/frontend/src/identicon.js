// ── User avatar / ident icon ───────────────────────────────────────
// Turns a stable identity string — the signed-in user's IC principal — into a
// deterministic little SVG glyph via minidenticons
// (https://github.com/laurentpayot/minidenticons, MIT). Same principal ⇒ same
// icon, so the header chip and the Account card always match, and the glyph is
// tied to the cryptographic identity rather than the (regenerable) username.
import { minidenticon } from "minidenticons";

// The library defaults are 95% saturation / 45% lightness. Saturation eases
// off neon for both themes; LIGHTNESS is per theme: lifted on the dark
// "glacier" tiles (--bg-hover, base.css) so the coloured squares stay vivid,
// pulled down on the light theme's pale tile so they keep their saturation
// instead of washing into pastel. The hue is the hash's, so the SAME principal
// keeps the same colour family in both themes — only its depth changes.
const SATURATION = 82;
const LIGHTNESS  = { dark: 60, light: 42 };

function themeKey() {
  return document.documentElement.getAttribute("data-theme") === "light" ? "light" : "dark";
}

// Both render sites re-ask for the same seed on every re-render; memoise the
// generated SVG so we hash + build the markup once per principal AND theme.
const _cache = new Map();

export function identiconSvg(seed = "") {
  const theme = themeKey();
  const key = `${theme}|${seed}`;
  let svg = _cache.get(key);
  if (svg === undefined) {
    svg = minidenticon(seed, SATURATION, LIGHTNESS[theme]);
    _cache.set(key, svg);
  }
  return svg;
}

// Fill `el` with the identicon for `seed`, tagging it `.has-identicon` so the
// CSS swaps the solid tile for the glyph. With no seed (e.g. mid-sign-in,
// before whoami() resolves the principal) it falls back to a plain initial so
// the tile is never blank. The glyph is decorative — the username beside it is
// the accessible label — so the injected <svg> is marked aria-hidden. The seed
// is kept on the element (data-identicon-seed) so refreshIdenticons() can
// re-render every mounted glyph when the theme changes.
export function setIdenticon(el, seed, fallbackText = "?") {
  if (!el) return;
  if (seed) {
    el.innerHTML = identiconSvg(seed);
    el.classList.add("has-identicon");
    el.dataset.identiconSeed = seed;
    el.firstElementChild?.setAttribute("aria-hidden", "true");
  } else {
    el.textContent = fallbackText;
    el.classList.remove("has-identicon");
    delete el.dataset.identiconSeed;
  }
}

// Re-render every mounted identicon for the theme now in force. Wired to
// theme.js's mdx:theme event (fired after <html data-theme> has flipped), so
// the header chip, the Account card and the leaderboard avatars re-colour
// with the rest of the page rather than at their next data refresh.
export function refreshIdenticons(root = document) {
  root.querySelectorAll("[data-identicon-seed]").forEach((el) => setIdenticon(el, el.dataset.identiconSeed));
}
document.addEventListener("mdx:theme", () => refreshIdenticons());
