# Seat venue bring-up — the `icp network start` launcher wedge

Ops note for the worktree-parallel local venues the software factory runs
(one PocketIC per seat worktree, own `ICP_HOME`, own gateway port; the
canonical bring-up recipe is step 4 of "Seat venue - bring-up" in
`.claude/skills/mdex-software-factory/SKILL.md`). This note records the one
start-time failure that recipe cannot wait out, how to recognise it in ten
seconds with `scripts/replica-doctor.sh --start-wedge`, and when to stop
retrying. Filed from task 1788580163 (observed 2026-09-05 on the
steady-brattain seat; the doctor landed with that task). The last section,
"Browser smoke on a seat venue", is the post-bring-up companion: the
frontend-only deploy, the host to open and its cookie jar, the
Chrome-extension notes, and the proxy harness for undisturbed smokes.

## How a healthy start looks (what the doctor calls HEALTHY)

`icp network start --background` (icp CLI 1.2.0) forks
`icp-cli-network-launcher --interface-version 1.1.0 --state-dir
<worktree>/.icp/cache/networks/local/state --bind 127.0.0.1 --status-dir
<tmp>/.tmpXXXXXX --domain=localhost` (ppid 1 once the CLI returns). The
launcher creates a second temp dir, spawns
`pocket-ic --ttl 2592000 --port-file <tmp2>/pocketic.port --log-levels error`,
waits for pocket-ic to write its config port into that file, READS AND
DELETES the file, creates the instance and the HTTP gateway, and writes
`status.json` (+ `custom-domains.txt`) into `--status-dir`. The CLI reads
`status.json`, writes `<worktree>/.icp/cache/networks/local/descriptor.json`
(gateway port, `child-locator.pid` = the launcher's pid, the status dir)
and prints `Network started on port N`. ~20-40s on this machine under load.
The CLI's own log for a background start is
`<worktree>/.icp/cache/networks/local/network-launcher/{stdout,stderr}.log`
(stderr carries `pocket-ic instance running with gateway port N`; the files
outlive a stop, so they are not a liveness marker - the descriptor is).

## The wedge signature (what the doctor calls WEDGED)

Observed 2026-09-05 05:17-05:50: FIVE consecutive starts on one seat, after
a clean `icp network stop`, all identical (the day before: one wedge, first
retry worked). Load average 15-18, ~13 pocket-ic mains / ~300 pocket-ic
processes machine-wide.

- the CLI prints only its two "output will be redirected" lines, never
  `Network started on port`;
- the launcher is alive at 0% CPU with an EMPTY `--status-dir`; `sample`
  shows every thread parked (`__psynch_cvwait` / kevent / an idle CFRunLoop
  helper) - it awaits a future that never resolves; it holds NO TCP
  connection to pocket-ic;
- its pocket-ic child listens on one port and answers `GET /instances`
  with `[]` (a served instance answers `["Available"]` or `["Busy(...)"]`),
  and its `--port-file <tmp2>/pocketic.port` STILL EXISTS with the port in
  it - the launcher never read it; touching or rewriting the file does not
  wake the launcher;
- the worktree's `.icp/cache/networks/local/state` is empty, its `lock` is
  held by the CLI, no `descriptor.json`;
- ruled out: launcher version (v15.0.0-2026-08-06 and v16.0.0 both wedged
  while other seats run both fine), env differences, DNS, port-descriptor
  lock holders, stray pocket-ic from earlier attempts, proc/file limits,
  proxy env. A manual launcher run with `RUST_LOG=debug` prints only
  pocket-ic's "listening on port" line.

It is NOT a transient: five blind retries did not clear it. The skill's
"~90s, kill both halves, retry" rule is right for ONE retry; after that the
retries only burn the seat's hour.

## Root cause (confirmed against the launcher source; reported upstream as https://github.com/dfinity/icp-cli-network-launcher/issues/95)

Strings in `icp-cli-network-launcher` (v15.0.0-2026-08-13 - the same code
runs in every version seen here) show how the port file is awaited:
`notify-8.2.0/src/fsevent.rs`, `fsevent-sys-4.1.0`, `failed to create file
watcher`, `failed to watch temporary directory`, `failed to receive port
from watcher`, `Unable to send runloop to watcher`, `notify-rs fsevents
loop`, `Failed to read port file`. The launcher watches the port-file's temp
directory with a notify-rs FSEvents watcher and awaits the create event -
there is no polling fallback and no timeout on that await (the one
"Timed out waiting for PocketIC server" string belongs to pocket-ic's client
library, a later phase). FSEvents is a best-effort, coalescing, daemon-mediated
notification: on this machine `fseventsd` is under chronic churn pressure
(the fleets' file churn; ~29% CPU at rest, once 50GB of logs), and an event
dropped or delivered before the stream is armed is simply never delivered
again. That matches every observed fact: the parked CFRunLoop helper thread
IS the fsevents loop, the port file is present and unread, no TCP was ever
opened to pocket-ic, and a touch does not help because the wedge is in the
event delivery, not the file. Correlates with a wedge-prone seat being one
whose temp dirs sit beside hundreds of other launchers' temp dirs under
`$TMPDIR` (1158 entries at the time) - more fseventsd work per event.

The fix belongs upstream (icp-cli's network-launcher: poll the port file
with a deadline as the watcher's fallback, the way pocket-ic's own client
library polls). The launcher source is public
(`dfinity/icp-cli-network-launcher`, `src/main.rs`): the port is received
ONLY through the notify watcher's callback (`rx.recv().await` with no
polling fallback and no deadline), and the code is unchanged in every
release seen here (v15.0.0-2026-08-06 through v16.0.0-2026-09-10). Reported
2026-09-17 as https://github.com/dfinity/icp-cli-network-launcher/issues/95
(no prior report existed; task 1788581043).

## The recipe

From the seat's worktree root, `ICP_HOME` exported, immediately after a
start that has not printed `Network started on port` within ~90s:

```
bash scripts/replica-doctor.sh --start-wedge "$PWD"
```

Read-only: `ps`/`lsof`/`ls`/`cat` plus `curl` to 127.0.0.1 only, NO icp
calls, so it cannot wedge behind the CLI's locks and is safe from any seat
at any time. It finds the worktree's launcher by the `--state-dir` path in
its argv (a `ps` snapshot filtered afterwards, so the filter never matches
itself; relative-argv launchers are attributed through open fds), then
prints one report and one verdict line:

| verdict (last line) | exit | meaning | do |
|---|---|---|---|
| `HEALTHY (launcher <pid> serving: ...)` | 0 | status dir has `status.json` / descriptor names this launcher; gateway probed | nothing |
| `STARTING (<n>s)` | 4 | launcher younger than the grace (`REPLICA_START_GRACE_S`, default 90) | wait, re-run; touch nothing |
| `WEDGED (launcher parked, port file unread)` | 5 | past the grace with the signature above (child found, its port file still present) | `kill <launcher-pid> <child-pid>` (the PIDs it prints, never a pattern), `rm -f <worktree>/.icp/cache/networks/local/lock`, retry ONCE |
| `WEDGED (launcher parked, status dir empty past the grace; ...)` | 5 | past the grace, status dir empty, but the child/port file are not in the classic shape | same remedy; paste the report into the escalation |
| `NO LAUNCHER for <worktree>` | 6 | no launcher names this worktree: the start never ran, or its process group died with the shell that launched it | relaunch, see below |
| usage error | 2 | not a directory / bad env | - |

Each report also carries: launcher version, elapsed, CPU%, TCP-connection
count, status-dir file count, the pocket-ic child's pid/elapsed/CPU%, its
`--port-file` state (present-with-contents vs consumed), the ports it
listens on and the `GET /instances` answer, `descriptor.json` (gateway
port, child pid, `GET /api/v2/status` code), the lock, and the last three
lines of the CLI's `stderr.log`/`stdout.log`.

**WEDGED twice in a row -> stop retrying, escalate to the operator (HUMAN
NEEDED).** One retry is the skill's rule; a second identical verdict means
the machine is in the state above and the seat cannot fix it from inside
(the operator's options are machine-level: quiet the churn, reduce the
pocket-ic population, reboot fseventsd). Include both doctor reports in the
signal.

**NO LAUNCHER is a different, self-inflicted shape** (seat-1, 2026-09-04):
`icp network start --background &` launched INSIDE a harness Bash call that
then timed out was killed with the call's process group - the network
never came up and no launcher for the worktree existed afterwards. Relaunch
in a SHORT call, `nohup icp network start --background > <log> 2>&1 &`, then
check `icp network status` in a SEPARATE call (~40s). Do not confuse it with
WEDGED: there is nothing to kill.

## Process-safety notes for the cleanup

- Identify by the `--state-dir` path in `ps -eo pid,ppid,etime,command`;
  never `pkill`/`pgrep -f` a name (the live fleets share this machine).
- A `$(pgrep -P <launcher>)` capture can carry a trailing space that makes
  zsh `kill` fail with `illegal pid: NNN ` and leaves the orphan - trim
  (`tr -d ' '`) before killing, and `kill -0` afterwards to prove it is gone.
- bash 3.2 on this machine; zsh has no `timeout`; `echo ====` inside `&&`
  chains errors - use `printf`.
- The doctor's `--rss` / `--rss-all` contract (factory.sh's claim gate
  parses it) is untouched by `--start-wedge`; exit 3 stays the recycle
  verdict, the start doctor uses 4/5/6.

## Browser smoke on a seat venue

Four Chrome smokes on seat venues, a two-venue cookie repro and a live-data
smoke at 375 px, all 2026-11-01 (seat-4's tasks 1793489927 / 1793494438;
seat-2's 1793489928 / 1793489949 / 1793490812 / 1793497680). Four things not
to re-derive:

1. **Frontend-only deploy**: `npm run build`, THEN `bash scripts/deploy.sh
   local frontend` (= `icp deploy frontend -e local --identity anonymous`
   under the seat's `ICP_HOME`; ~20s; backend, bridge and seed untouched).
   Build first every time - icp.yaml's recipe `build:` steps have been seen
   both re-running and skipped (2026-08-01) - and `curl` the origin for the
   new `index-*.js` hash before any browser (`icp network status` prints the
   gateway port). A stale page after that is the browser's cached
   `index.html` (served `max-age=0, must-revalidate`): hard-reload once;
   `public/sw.js` has no fetch handler and caches nothing.
   Since task 1793503326 the frontend is the **static-site (certified-assets)
   canister** (`@dfinity/static-site` in icp.yaml), configured by
   `src/frontend/public/_headers` + `_redirects` (NOT `.ic-assets.json5`,
   which it never reads). A venue whose `frontend` still runs the legacy
   asset-canister wasm cannot be UPGRADED to it (unrelated Candid
   interfaces: icp refuses the deploy as BREAKING before installing
   anything, and `--yes` would push the upgrade onto stable memory the new
   wasm cannot read) - `deploy.sh local frontend` and `cold_start.sh` detect
   that wasm (the legacy-only `api_version` query) and run the one-time
   `icp deploy frontend --mode reinstall` themselves (the frontend holds no
   state; ~30s; the venue's canister ids are unchanged). On a FRESH venue
   the recipe's first build runs before any canister id exists, so
   `/.well-known/ic-app.json` and the `mdx:frontend-canister-id` stamp
   (item 2) appear only from the next frontend deploy (play_start's
   follow-up `icp deploy frontend`, or this item) - as before the switch.
2. **`ic_env` is ONE COOKIE JAR PER HOST NAME, and both host forms are
   shared names.** Every HTML 200 from the frontend canister sets the
   host-only session cookie `ic_env` (root key + every canister id). The
   static-site canister (since task 1793503326) sets ONE value as TWO rows -
   `Path=/; Secure; SameSite=Lax` and `Path=/; Secure; SameSite=None;
   Partitioned` (captured 2026-11-01: `cookieStore.getAll({name:"ic_env"})`
   = `[{partitioned:false, sameSite:"lax", secure:true, path:"/"},
   {partitioned:true, sameSite:"none", secure:true, path:"/"}]`, the same
   order in `document.cookie`; a venue's fresh 200 rewrites BOTH); the
   legacy asset canister set one `SameSite=Lax` row (not Secure). main.js
   reads `PUBLIC_CANISTER_ID:backend` through `readCanisterEnv`
   (src/frontend/src/canister-env.js, below); the SDK's own
   `safeGetCanisterEnv()` took the FIRST `ic_env=` in `document.cookie`
   (core 5.x; since core 6.1.1 it refuses a jar whose copies disagree and
   answers nothing — no better for the app). Cookies ignore the port, every local replica draws
   the same six ids in a per-venue permutation (`.icp/cache/mappings/
   local.ids.json`; seat-3 and seat-4 both drew frontend `4xhad…`), and
   `frontend.local.localhost` is every venue's friendly name. The two-venue
   repro (task 1793497680, seats 3 / 4 read-only) found two flavours, and
   the recipe switch (task 1793503326, a scratch probe beside this seat's
   legacy venue under one unique host name) a third:
   - id host `4xhad….localhost`: `cookieStore.getAll({name:"ic_env"})` held
     TWO rows - an open-saas venue's `Secure; SameSite=None; Partitioned`
     twin (its static-site canister sets both variants; its frontend drew
     the same id) FIRST, ours second - so on seat-3 AND seat-4 every query
     went to its backend `6r7so…`: IC0301 `Canister not found`, banner
     "MULTI/DEX is unreachable". Our fresh 200 rewrites only our row, so no
     reload heals it.
   - name host: venue A, then B in the same tab, then Back: Chrome served A
     from cache (`deliveryType: cache`, no Set-Cookie), A's JS re-ran on
     B's cookie and queried `4fbx2…` = A's xrc-mock: IC0536 `no query
     method` on every call. A second tab at the same host name rewrites the
     jar under the first too (actors bind at load; sign-in and Bridge
     re-read lazily) - and that tab can be ANOTHER SEAT's smoke in the same
     Chrome profile: last writer wins across seats and the primary,
     mid-run, with no navigation of yours (task 1793494438). A plain reload
     heals this flavour, so reload the venue's own page RIGHT BEFORE the
     smoke (a fresh 200 re-sets the jar), then read the ids the bundle
     actually called - `performance.getEntriesByType('resource').map(e =>
     e.name).filter(n => n.includes('/api/v'))` lists the
     `/api/v3/canister/<id>/query` URLs (the extension redacts raw cookie
     strings in `javascript_tool` output).
   - **the MIXED FLEET at the name host** (2026-11-01, Chrome): a venue on
     the static-site canister visited first, then a venue still on the
     LEGACY canister at the same host name - the legacy row REPLACED the
     static-site `Lax` row (same name, host and path) but cannot touch the
     `Partitioned` one, which then lists FIRST in `cookieStore.getAll` and
     in `document.cookie` (`[{partitioned:true, <venue S's ids>},
     {partitioned:false, secure:false, <venue L's ids>}]`). Both rows carry
     our key set, so the legacy venue's page (its old bundle picks by key
     set, then cookie order) runs on venue S's ids; S's own page is fine
     (its 200 rewrites both rows). Only a FRONTEND DEPLOY of the legacy
     venue (which moves it to static-site, item 1) ends the shape; the
     cure line below clears it meanwhile.
   Rule: the name host stays the default; after the switch OUR canisters
   write the `Partitioned` row too, so a twin can land at the name host as
   well as at an id host (the open-saas gateway still answers 400 at
   friendly names; the twins at a name host are OTHER MULTI/DEX venues -
   the mixed fleet above). ONE venue per host name per browser profile;
   a second venue gets the OTHER host form (different host, different
   jar); a smoke that must not be disturbed gets item 4's unique host.
   Signature: the console's `Canister ID:` is not the venue's backend.
   Cure, in that tab's console: `document.cookie = "ic_env=; Max-Age=0;
   Path=/; Secure; SameSite=None; Partitioned"` (the plain `Max-Age=0;
   Path=/` form deletes only the Lax row) - or DevTools > Application >
   Cookies > that host, delete the row with a Partition Key - then reload
   (Cmd+R is a fresh 200: the HTML carries no validators).
   Since task 1793499221 the app defends itself: main.js reads the jar
   through `readCanisterEnv` (src/frontend/src/canister-env.js), which
   parses EVERY `ic_env` row with the SDK's semantics and prefers the row
   carrying our key set (backend/bridge/frontend/arb - the four every
   environment deploys) and then the row whose `frontend` is the canister
   that SERVED the page - at an id host the host name says which; at a
   friendly name or a custom domain the build's stamp does
   (`<meta name="mdx:frontend-canister-id">`, stamped into index.html by
   vite.config.mjs from the deploy's id mapping since task 1793503326; the
   host id wins when both exist) - so a twin's row, Partitioned or not,
   no longer wins on any page that carries the new bundle; the SDK's
   cookie order is the last resort; and on the first IC0301/IC0536
   reject (health poll or markets fetch) it re-fetches the page ONCE
   (`cache: "reload"`, which applies the fresh Set-Cookie), re-reads the
   jar and rebuilds the actors when the backend id changed - one
   `console.info` names old -> new, and the fuel banner names the cookie
   ("this page read another venue's ic_env cookie (backend <id>)") instead
   of "a network or replica issue". The cure lines above remain for what
   that cannot resolve; tests/frontend_canister_env.test.mjs pins it.
3. **claude-in-chrome**: `127.0.0.1` is outside its domain allowlist - use
   `localhost` hosts (any `*.localhost` name is accepted). The AI / Agent
   Chat tab stays reachable keyless in help-only mode (task 1793489932;
   `refreshAiGate` badges it HELP ONLY) - a model call needs a key:
   `echo y | icp canister call backend setGoogleApiKey
   '("placeholder")' --identity anonymous` flips it, `'("")'` clears it -
   dev venues only. Its viewport is pinned PER SESSION (~370x731 CSS px in
   one, 1024 wide in another) and `resize_window` / `window.resizeTo`
   no-op - check `innerWidth`; for another width, `window.open(url,
   '_blank', 'popup,width=1400,height=850')` from javascript_tool and
   measure through the popup, or item 4 - the venue itself refuses framing
   (`x-frame-options: DENY` + CSP `frame-ancestors 'none'`).
4. **Undisturbed smokes at any width, with live data** (task 1793494438,
   Markets at 375 px in both themes): serve the built bundle yourself at a
   host name nobody else uses. `scripts/smoke-harness.mjs` is that server,
   tracked (task 1793500998; Node 22, `node:http` only):
   `node scripts/smoke-harness.mjs --gateway <gateway port>` (foreground,
   Ctrl-C stops it; `--dist dist`, `--port 0`, `--name <label>`, `--charts`
   optional; `tests/smoke_harness.test.mjs` drives it against a stub). It
   serves `dist/`, proxies `/api/*` to `127.0.0.1:<gateway port>` (agents
   use `host: window.location.origin`, so queries follow the page; the Host
   header is rewritten - the gateway answers 400 to a foreign one) and
   re-sets the venue's own `ic_env` on each HTML response - at start it
   HEADs `http://frontend.local.localhost:<gateway port>/` and copies the
   `set-cookie:` line (since task 1793503326 the static-site canister
   answers with TWO - the Lax row and the Partitioned row, one value - and
   the harness re-sets the first, the Lax row, which is all a page needs),
   refusing to start without one ("frontend not deployed on <port>"). It
   prints the URL to open,
   `http://<name>-smoke.local.localhost:<port>/` (`<name>` defaults to the
   seat's `.factory-worker` pin): any `*.localhost` name resolves to
   loopback, `host.js` counts it local, and a unique name is a jar nobody
   else writes. The same server serves `/__harness.html?w=375&h=780`, a
   same-origin page whose `<iframe>` of `/?nocache=1#<route>` is sized by
   the query and routed by it: `&route=swap` frames the Swap view directly
   (any slug the app routes, its tab lowercase - `docs/launch`,
   `ai/agent-chat`, `account/deposit` - and the market deep link
   `markets/BTC-ICPUSD`, whose id keeps its case; default `markets`;
   anything else is a 400 with the usage), so a smoke of another view needs
   no post-load hash flip (task 1793555363; no XFO / CSP from it, so framing
   works; script the frame via its `contentWindow`).
   For COOKIE physics rather than layout, a transparent
   reverse proxy of the whole gateway is the faithful tool (every request
   forwarded with the gateway's own Host header, the response relayed as is
   - the canister's real Set-Cookie lines included; a few lines of scratch
   `node:http`, not tracked): two such proxies on two ports under ONE unique
   name share one jar, which is how item 2's mixed fleet was reproduced
   without touching any shared host (task 1793503326). Exact chart state
   without editing the tree:
   `--charts` builds and serves a scratch dist first - a generated Vite
   config spreading the repo's `vite.config.mjs` with an ABSOLUTE scratch
   `build.outDir` under `os.tmpdir()` plus one `transform` plugin appending
   a `window.__mdxCharts = () => ({...})` accessor to
   `src/frontend/src/main.js` (module-scope `chartInstance` /
   `miniChartInstance` / `chartCandleData` are in reach); `vite build
   --config <scratch>` from the repo root (`root: "src/frontend"` resolves
   against the cwd; 0.3 s). The base plugins' `closeBundle` hooks would
   re-stamp the repo's gitignored `dist/version.json` /
   `dist/.well-known/ic-app.json` from that build (harmless, but a smoke
   must not write into the tree it smokes), so the scratch config strips
   them by name and emits the scratch dist's own `version.json`.
   **A hidden tab cannot drive a render-driven smoke - use the AUTO mode**
   (task 1793577865; the physics from 1793575742). When
   `document.visibilityState` reads `hidden` in the extension's tab (its
   tab-group window occluded behind another), Chrome defers EVERY rendering
   callback in that document: a ResizeObserver, a `matchMedia(...)` change
   listener and `requestAnimationFrame` never fire (after ~5 min hidden,
   chained timers run once a minute too - a sleep loop trips the
   `javascript_tool`'s 45 s CDP wall), while read-only probes -
   `offsetHeight`, `getComputedStyle`, an inline paint such as
   `__mdxFuelBanner(info)` - still answer, so `--chrome-h` across the 900px
   breakpoint reads STALE there and nothing from a seat can raise the
   window (`window.open` is popup-blocked; Chrome's AppleScript dictionary
   times out; no assistive access). The harness runs such a smoke in a
   FRESH, visible window on the page's own timers:
   `node scripts/smoke-harness.mjs --gateway <gateway port> --open --script
   fuel-banner-breakpoint`. It serves
   `/__auto.html?w=&h=&route=&script=<name>` - generated in memory around
   `tests/smoke/<name>.mjs` (a slug, like `route`; an ES module,
   `export default async function (api) {}`, whose `api` is `frame`,
   `waitFor(pred, ms)`, `setWidth(px)`, `await read()` - visibility, a rAF
   probe, `--chrome-h`, `#top-chrome` / header heights, the fuel banner's
   class + computed display, the page's own MQ / RO control counters inside
   the frame - and `log(line)`), opens it through `open -na "Google Chrome"
   --args --new-window <url>` (macOS; elsewhere the URL is printed), prints
   every line the page POSTs to `/__result/<name>` as `[<name>] <line>`,
   serves them at `GET /__result/<name>` (text/plain - curl, no extension),
   and exits 0 on `done ok`, 1 on `done FAIL …` or when `--result-timeout
   <s>` (default 120) passes without a `done` line; the page closes its own
   window on done, error and timeout, and the harness prints `closed` when
   the window's pagehide beacon arrives (or names a lingering window on
   stderr) - the seat never has to look at the desktop. The first script,
   `tests/smoke/fuel-banner-breakpoint.mjs`, reproduces 1793575742's
   readings (1100px warn:freeze `--chrome-h` 113px, 390px 56px, 1100px
   113px, critical at 390px 186px). Measured 2026-11-02 from this
   recipe: `visibility visible`, the rAF probe answering, the MQ and RO
   controls incrementing on each crossing.

5. **The SIGNED-IN smoke - the `#dev-login` hook** (task 1793497426; the
   operator's shape (b), 2026-11-01). On a `#dev` venue a tab signs in as a
   throwaway Ed25519 identity by navigating to `#dev-login` (or calling
   `window.__mdxDevLogin()` in the console). Nothing renders for it on any
   posture; the gate is the backend's `getDeployMode` ANSWER (awaited -
   never state.js's "dev" placeholder): anywhere else the hook prints ONE
   console line, `dev-login: not a #dev venue`, and does nothing. Signed in,
   the header pill reads `LOCAL DEV IDENTITY`; the 32-byte seed lives in
   `sessionStorage` (`mdx.devlogin.seed.v1`), so a reload - the boot hook -
   restores the SAME principal in that tab (a new tab is a new principal);
   Sign out drops the seed through the ordinary `logout()` (the GHSA-6qpg
   `resetAssistant` included). The recipe seat-3 ran with the operator's key
   (the transcript is in the task's archive note):
   - the key goes on BEFORE the sign-in (`setAnthropicApiKey`, cold_start's
     block) - the page probes `aiConfigured` at load and at sign-in only;
   - load `http://frontend.local.localhost:<gateway>/?r=N`, then
     `location.hash = "#dev-login"` from `javascript_tool`; the console names
     the principal (`dev-login: signed in as <principal> (hash)`; the
     extension's console buffer re-lists old lines on later reads - the
     first read of each line is the count);
   - the Deposit tab GATES on the play binding even on `#dev`
     (`getMyVerification().required` is `DEPLOY_MODE != #production`), so
     bind the principal from the CLI the way the suites do -
     `icp canister call backend setTestEmailBinding '(principal "<p>",
     "<label>@example.com")' --identity anonymous` - then re-enter
     `#account/deposit`: Create deposit address -> ICPUSD + amount -> "1.
     Deposit amount" -> "2. Simulate finality" -> Claim. The claim REGISTERS
     the caller (`aiComplete` sits behind the admission gate until then);
   - `#ai/agent-chat`: the presets; "buy 10 ICP" (the live model may first
     ask spot-vs-margin and the slippage - answer and the card follows) ->
     Decline / Confirm; the market order stages and fills at the next price
     update (~1 s on a ticking venue; re-stamp the ref price on a cold one);
     `refreshTradeView` repaints the order/trade tables and balances
     without a reload (read the hidden `#account-open-orders-body` before
     and after to attribute it);
   - per-call prompt bytes, from the browser: the agent binds
     `globalThis.fetch` at CONSTRUCTION and passes a `URL` object, so wrap
     `window.fetch` BEFORE the sign-in (`String(input.href ?? input)`) and
     read the candid text length after the `DIDL 00 01 71` header of any
     POST body whose CBOR names `aiComplete`. A reload re-runs the boot
     sign-in before any injection: stash the seed in `window.name`, remove
     it, reload, install the tap, restore the seed, then `#dev-login` - same
     principal, fresh transcript (drop `mdx.agentchat.v1:<principal>` too
     for a true first call). Measured 2026-11-01: 13,473 bytes on the first
     call with the real venue schema, 16,691 after a confirm -> verify turn
     (the client trims at 30,000; the backend guard is 32,768);
   - key off (`setAnthropicApiKey '("")'`): an open tab keeps believing the
     key is on until its next probe - a how-do-I question still answers from
     the Docs through the model-down floor, with the no-key note; a reload
     re-probes and badges the tab HELP ONLY. A reload that LANDS on
     `#ai/agent-chat` seeds the greeting before the session restores; since
     task 1793551778 the sign-in edge (`assistantOnAuthChange`, called from
     `onLogin` once whoami has named the principal) replays the transcript
     snapshot there too (tests/agent_chat_protocol.test.mjs 8b pins it); since
     task 1793554545 the same edge RE-SEEDS the greeting when a sign-out on
     the AI tab reset the pane and the next sign-in shows it again without a
     sub-tab click (8c pins it). The browser repro is `window.__mdxDevLogin()`
     while on `#ai/agent-chat` (the `#dev-login` HASH lands on Home and
     re-enters the view, which seeds anyway); clicking the already-selected
     Agent Chat sub-tab fires no hashchange and seeds nothing - only Memory
     Explorer and back did, before the fix.
   The `#play` negative control cannot be driven in a browser without a
   `#play` backend (`appState` is a module binding) -
   `tests/frontend_security.test.mjs` §O6 is the proof.

## Verify-with-Google (play deposits) on a seat venue

The backend admits a play deposit only for a Google-verified Internet Identity, and
the sign-in finish accepts only the origins in its `frontend_origins` canister env var.
`icp.yaml` lists the primary's `http://frontend.local.localhost:8000` and vite's
`http://localhost:3100`, and every install re-stamps that list - so a seat venue,
served from its own OS-assigned gateway port, refused verification with
`#FrontendOriginMismatch` and the Deposit page's unlock card read "operator: add
http://frontend.local.localhost:<port> to frontend_origins" (2026-11-03; before
that no seat venue could fund a play account through the browser).

Since that date `cold_start.sh`'s deploy phase appends the venue's own origin
(`stamp_local_frontend_origin`: `icp canister settings update backend
--add-environment-variable "frontend_origins=<yaml list>,http://frontend.local.localhost:<port>"
--identity anonymous`) after every deploy - the re-stamp is why it must ride the deploy
and not a hand edit. Read it back with `icp canister status backend --identity anonymous
| grep frontend_origins`. The `WARN ... overridden on next settings sync` the CLI prints
is the expected shape: the next deploy re-stamps the yaml list and the next cold_start
re-appends. A venue deployed before this landed needs one cold_start (or the settings
update above by hand) before "Sign in using Google" works on it.
