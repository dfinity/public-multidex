// tests/smoke/fuel-banner-breakpoint.mjs — the first AUTO-MODE smoke script
// for scripts/smoke-harness.mjs (task 1793577865): --chrome-h follows the
// fuel banner across the app's 900px mobile breakpoint. It reproduces task
// 1793575742's readings, measured 2026-11-02 on a #dev seat venue in a fresh
// Chrome window (header 56px; the warn:freeze banner 57px at 1100px; the
// critical banner 130px at 390px):
//
//   1100px, warn:freeze painted   --chrome-h 113px, banner display block
//    390px, NO repaint            --chrome-h  56px, banner display none
//                                 (stats.css hides .asks-cycles under 900px;
//                                 main.js's MQ change listener + ResizeObserver
//                                 recompute --chrome-h on the crossing)
//   1100px, NO repaint            --chrome-h 113px again
//    390px, critical painted      --chrome-h 186px (the frozen tier is never hidden)
//
// Run, on a seat venue in #dev with dist built (npm run build):
//   node scripts/smoke-harness.mjs --gateway <port> --open --script fuel-banner-breakpoint
// Every reading carries the page's visibilityState, a rAF probe and the
// harness's MQ/RO control counters: in a hidden document (the extension's
// occluded tab) the controls stay flat and --chrome-h reads stale — the
// failure 1793575742 ran into, and the reason this runs in a fresh window.
//
// The paint: window.__mdxFuelBanner(info) — the #dev-only console handle
// (main.js fuelBannerSmoke) paints the banner from a crafted
// getCanisterInfo-shaped `info`; it answers false until the backend's posture
// answer has landed, so the first wait is on a true. The api this receives is
// the harness's (scripts/smoke-harness.mjs, "AUTO MODE").

const EXPECT = { warnDesktop: 113, mobileHidden: 56, warnDesktopAgain: 113, criticalMobile: 186 };

// A 27-character id, the shape every venue's backend id has — the appeal's
// text wraps around it, so its length is part of the measurement.
const CANISTER_ID = "ryjl3-tyaaa-aaaaa-aaaba-cai";
const NOW_NS = 1.7e18;
const BASE = {
  canisterId: CANISTER_ID,
  nowNs: NOW_NS,
  lastHeartbeatNs: NOW_NS - 1e9,        // a beat 1 s ago: not frozen
  timersPaused: false,
  memorySizeBytes: 1e8,                 // 3.3% of the limit: no memory tier
  wasmMemoryLimitBytes: 3e9,
  autoFuelEnabled: false,               // not self-funding: the appeal shows
  fuelRouteWired: false,
  treasuryUsdE8s: 0,
  treasuryIcpE8s: 0,
  idleBurnPerDay: 0,
  oracleDivergence: [],
};
// warn:freeze — 2T liquid (3T over a 1T freezing limit) burning 4T/day: ~12 h
// to the freeze, inside the banner's 24 h window (fuelState: freezeSoon).
const WARN_FREEZE = { ...BASE, cycles: 3e12, freezingLimitCycles: 1e12, burnPerDay: 4e12 };
// critical — 0.1T liquid (< 0.25T): the dead tier, cause "cycles".
const CRITICAL = { ...BASE, cycles: 1.1e12, freezingLimitCycles: 1e12, burnPerDay: 4e12 };

const px = (s) => parseInt(String(s), 10);
const fmt = (r) => `visibility ${r.visibility.page}/${r.visibility.frame} raf ${r.raf} --chrome-h ${r.chromeH} top-chrome ${r.topChromeH} header ${r.headerH} banner ${r.banner ? `${JSON.stringify(r.banner.class)} ${r.banner.display} ${r.banner.h}px` : "none"} controls mq:${r.controls.mq} ro:${r.controls.ro} frame ${r.frameW}px`;

export default async function run({ frame, waitFor, setWidth, read, log }) {
  const fails = [];
  const check = (label, got, want) => {
    const ok = got === want;
    if (!ok) fails.push(label);
    log(`check ${ok ? "ok  " : "FAIL"} ${label}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
    return ok;
  };

  const r0 = await read();
  log(`visibility ${r0.visibility.page} (frame ${r0.visibility.frame}); raf ${r0.raf}; frame ${r0.frameW}px`);
  await waitFor(() => typeof frame.__mdxFuelBanner === "function", 30000);
  await waitFor(() => frame.__mdxFuelBanner(WARN_FREEZE) === true, 30000);   // false until the #dev posture answer lands
  log("painted warn:freeze — the #dev handle answered true");

  // 1. desktop, the appeal showing
  await setWidth(1100);
  frame.__mdxFuelBanner(WARN_FREEZE);
  const a = await read();
  log(`1100px warn:freeze: ${fmt(a)}`);
  check("1100px warn:freeze --chrome-h", px(a.chromeH), EXPECT.warnDesktop);
  check("1100px banner class", a.banner && a.banner.class, "fuel-banner warn asks-cycles");
  check("1100px banner display", a.banner && a.banner.display, "block");
  check("1100px --chrome-h equals #top-chrome's height", px(a.chromeH), a.topChromeH);
  check("1100px --chrome-h equals header + banner", px(a.chromeH), a.headerH + a.banner.h);

  // 2. across the breakpoint with NO repaint: the stylesheet hides the appeal;
  //    main.js's MQ change listener / ResizeObserver must recompute --chrome-h.
  const b = await setWidth(390);
  log(`390px (no repaint): ${fmt(b)}`);
  check("390px --chrome-h", px(b.chromeH), EXPECT.mobileHidden);
  check("390px banner display (stats.css hides .asks-cycles under 900px)", b.banner && b.banner.display, "none");
  check("390px --chrome-h equals the header alone", px(b.chromeH), b.headerH);
  check("the MQ control fired on the crossing", b.controls.mq > a.controls.mq, true);
  check("the RO control fired on the crossing", b.controls.ro > a.controls.ro, true);

  // 3. back across, still no repaint
  const c = await setWidth(1100);
  log(`1100px (no repaint): ${fmt(c)}`);
  check("1100px again --chrome-h", px(c.chromeH), EXPECT.warnDesktopAgain);
  check("1100px again banner display", c.banner && c.banner.display, "block");
  check("the MQ control fired again", c.controls.mq > b.controls.mq, true);
  check("the RO control fired again", c.controls.ro > b.controls.ro, true);

  // 4. the frozen tier at phone width: never hidden
  await setWidth(390);
  frame.__mdxFuelBanner(CRITICAL);
  const d = await read();
  log(`390px critical: ${fmt(d)}`);
  check("390px critical --chrome-h", px(d.chromeH), EXPECT.criticalMobile);
  check("390px critical class", d.banner && d.banner.class, "fuel-banner critical");
  check("390px critical display", d.banner && d.banner.display, "block");
  check("390px critical --chrome-h equals header + banner", px(d.chromeH), d.headerH + d.banner.h);

  log(`summary --chrome-h ${px(a.chromeH)} / ${px(b.chromeH)} / ${px(c.chromeH)} / ${px(d.chromeH)} at 1100 / 390 / 1100 / 390-critical (want ${EXPECT.warnDesktop} / ${EXPECT.mobileHidden} / ${EXPECT.warnDesktopAgain} / ${EXPECT.criticalMobile}); ${fails.length === 0 ? "all checks passed" : `${fails.length} check(s) failed: ${fails.join("; ")}`}`);
  return fails.length;
}
