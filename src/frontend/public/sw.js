// ── MULTI/DEX session janitor (belt-and-braces layer) ───────────────
// Deletes the on-disk auth session ~8s after the LAST app tab closes.
//
// This is the prompt-hygiene layer on top of the AUTHORITATIVE mechanism —
// the localStorage heartbeat + boot stale-check in main.js, which signs a
// stale session out at the next visit and also covers browser quit/crash
// (where any service worker dies instantly and no in-page trick survives).
//
// Design: rolling census, NOT a pagehide ping. A message sent while the last
// tab is being torn down races the teardown and is often lost — that failure
// was observed in production. Instead every open tab pings {type:"alive"}
// every second; EACH ping opens an event.waitUntil timer that, 8s later,
// counts live app tabs (clients.matchAll). While tabs live, every census sees
// one and no-ops. When the last tab closes, the most recent routine ping —
// delivered up to ~1s BEFORE the close, no race — is still pending; its
// census then finds zero tabs and deletes the session. An in-flight waitUntil
// keeps a worker alive after its last client is gone (Chromium allows ~5min;
// WebKit/Gecko enough seconds for this), which is what makes the post-close
// firing legitimate rather than lucky.
//
// Standard SW API only (message, waitUntil, clients.matchAll, IndexedDB) — no
// Background Sync/push — so this runs on Android Chrome/Firefox and iOS
// Safari (all iOS browsers are WebKit), not just desktop Chromium. Mobile
// caveats: background-tab timer throttling stretches the ping cadence, so a
// tab closed after long backgrounding may have no pending census (falls back
// to the boot check), and swiping the whole browser app away kills the worker
// like a desktop browser quit — boot check again.

const GRACE_MS = 8000;             // ping → census delay; a reload re-appears well within it
const AUTH_DB  = "auth-client-db"; // @icp-sdk/auth's IdbCredentialStorage DB (client/db.ts: AUTH_DB_NAME,
                                   // unchanged 8.x → 11.x; store `ic-keyval`, slots `session` + `app`:
                                   // each a key pair and its delegation chain). Deleting it removes every
                                   // credential = the credential half of signOut(). The who-is-signed-in
                                   // record (localStorage `ic-session-state`) is out of a worker's reach:
                                   // the next load's restore finds no credential behind it and drops it,
                                   // and the boot stale-check (main.js) signs out anyway.

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("message", (event) => {
  if (!event.data || event.data.type !== "alive") return;
  event.waitUntil((async () => {
    await new Promise((r) => setTimeout(r, GRACE_MS));
    // includeUncontrolled: a freshly-reloaded page may not be controlled yet.
    const tabs = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    if (tabs.length > 0) return;   // some app tab lives (or a reload came back) — keep the session
    await new Promise((resolve) => {
      const req = indexedDB.deleteDatabase(AUTH_DB);
      req.onsuccess = req.onerror = req.onblocked = () => resolve();
    });
  })());
});
