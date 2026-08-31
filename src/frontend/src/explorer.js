// ── Data Explorer (Intelli → "Data explorer" tab) ────────────────────
// The OQL query builder UI: entity rail, column + edge-expansion picker,
// filters (AND/OR/NOT), aggregations, multi/clickable-header sort, presets,
// drill-through, shareable links, CSV/JSON export. Extracted from main.js —
// reads shared singletons via appState (state.js) and OQL display helpers
// via oql.js.
import { appState } from "./state.js";
import { E8 } from "./money.js";
import { oqlRowsToObjects, oqlFormatCell, oqlErrorMessage, dxEsc } from "./oql.js";

let _dxCanister = "exchange";   // "exchange" (live state) | "history" (your archived events)
let _dxSchemaByCanister = {};   // canister → entities array (cached per canister)
let _dxSchemaPromise = {};      // canister → in-flight load promise (dedupe concurrent callers)
let _dxOffset = 0;
let _dxRows = [];               // accumulated rows (for Load more)
let _dxSelect = [];             // projection (`select`): field/dotted-path names; [] = all columns
let _dxResultEntity = "";       // `start` entity of the rows currently in the table (for drill-through)
let _dxGroupBy = [];            // groupBy fields (chips)
let _dxCombinator = "and";      // how filters combine: "and" (match ALL) | "or" (match ANY)
let _dxExpandedEdge = null;     // which edge column has its joined-fields panel open (or null)
let _dxAutoBrowsed = false;     // first explorer open runs a default browse ONCE (never over a shared link / preset)
const DX_OPS = ["eq", "ne", "lt", "le", "gt", "ge", "in", "contains", "icontains", "startsWith", "endsWith"];
const DX_AGG_FNS = ["count", "sum", "avg", "min", "max"];


// Ready-made queries that show off the OQL engine: joins (dotted paths through
// declared edges), groupBy+aggregate, text search, and per-user scoping. `c` is
// the canister ("exchange" default; "history" = archive). Selecting one loads it
// into the raw box and runs it — instant, copy-and-tweak documentation.
const DX_PRESETS = [
  { g: "Browse", label: "All markets", q: { start: "market", orderBy: [{ field: "id", dir: "asc" }], limit: 25 } },
  { g: "Browse", label: "Open orders — largest first", q: { start: "order", orderBy: [{ field: "quantity", dir: "desc" }], limit: 25 } },
  { g: "Browse", label: "Open BTC sell orders, cheapest first", q: { start: "order", where: { and: [{ eq: { field: "marketId", value: "BTC-ICPUSD" } }, { eq: { field: "side", value: "sell" } }] }, orderBy: [{ field: "price", dir: "asc" }], limit: 25 } },
  { g: "🔗 Joins (dotted paths)", label: "Open orders + market last price", q: { start: "order", select: ["id", "marketId", "side", "price", "quantity", "marketId.lastPrice"], orderBy: [{ field: "placedAt", dir: "desc" }], limit: 25 } },
  { g: "🔗 Joins (dotted paths)", label: "Events + the market they concern", q: { start: "event", where: { ne: { field: "market", value: "" } }, select: ["id", "severity", "category", "market", "market.base", "market.quote", "message"], orderBy: [{ field: "id", dir: "desc" }], limit: 25 } },
  { g: "🔗 Joins (dotted paths)", label: "My positions + pool name + market  (sign in)", q: { start: "position", select: ["ownerName", "poolId.name", "marketId", "marketId.base", "side", "size", "entryPrice", "realizedPnl"], limit: 25 } },
  // Joins aren't just projection: dotted paths work in where / orderBy /
  // groupBy too (≤4 hops). One preset per placement, so each is discoverable.
  { g: "🔗 Joins (dotted paths)", label: "Orders in BTC markets (join in where)", q: { start: "order", where: { eq: { field: "marketId.base", value: "BTC" } }, select: ["id", "side", "price", "quantity", "marketId", "marketId.lastPrice"], orderBy: [{ field: "price", dir: "desc" }], limit: 25 } },
  { g: "🔗 Joins (dotted paths)", label: "Orders by their market's price (orderBy join)", q: { start: "order", select: ["id", "marketId", "side", "price", "quantity", "marketId.lastPrice"], orderBy: [{ field: "marketId.lastPrice", dir: "desc" }, { field: "price", dir: "desc" }], limit: 25 } },
  { g: "📊 Aggregates", label: "Open order count by market", q: { start: "order", groupBy: ["marketId"], aggregate: [{ fn: "count" }], orderBy: [{ field: "count", dir: "desc" }] } },
  { g: "📊 Aggregates", label: "Book depth by base asset (groupBy join)", q: { start: "order", groupBy: ["marketId.base"], aggregate: [{ fn: "count" }, { fn: "sum", field: "quantity", as: "depth" }], orderBy: [{ field: "depth", dir: "desc" }] } },
  { g: "📊 Aggregates", label: "Open orders: count + total qty by side", q: { start: "order", groupBy: ["side"], aggregate: [{ fn: "count" }, { fn: "sum", field: "quantity", as: "totalQty" }], orderBy: [{ field: "totalQty", dir: "desc" }] } },
  { g: "📊 Aggregates", label: "Open orders: avg price + depth by market", q: { start: "order", groupBy: ["marketId"], aggregate: [{ fn: "count" }, { fn: "avg", field: "price", as: "avgPrice" }, { fn: "sum", field: "quantity", as: "depth" }], orderBy: [{ field: "depth", dir: "desc" }] } },
  { g: "🔍 Text search", label: 'Events mentioning "oracle"', q: { start: "event", where: { icontains: { field: "message", value: "oracle" } }, orderBy: [{ field: "id", dir: "desc" }], limit: 25 } },
  { g: "🔍 Text search", label: 'Markets starting with "BTC"', q: { start: "market", where: { startsWith: { field: "id", value: "BTC" } } } },
  // OQL compares numbers exactly as the backend projects them, and `order.price`
  // is projected raw — e8 base units, the same integer the results table prints.
  // A threshold therefore has to be written in base units: a bare 1000 is a
  // filter at $0.00001, which matches every resting bid and reads as a working
  // example while doing nothing. This is the explorer's only numeric-filter
  // preset, so it is also where anyone writing one by hand learns the unit.
  { g: "🔍 Text search", label: "Buy orders above $1,000, priciest first", q: { start: "order", where: { and: [{ eq: { field: "side", value: "buy" } }, { gt: { field: "price", value: 1000 * E8 } }] }, orderBy: [{ field: "price", dir: "desc" }], limit: 25 } },
  { g: "🔒 Your data (sign in)", label: "My pools", q: { start: "pool", limit: 25 } },
  { g: "🔒 Your data (sign in)", label: "My positions — newest", q: { start: "position", orderBy: [{ field: "openedAt", dir: "desc" }], limit: 25 } },
  { g: "🔒 Your data (sign in)", label: "My wallet balances", q: { start: "balance", orderBy: [{ field: "amount", dir: "desc" }], limit: 25 } },
  { g: "🔒 Your data (sign in)", label: "My recently closed orders", q: { start: "closedOrder", orderBy: [{ field: "closedAt", dir: "desc" }], limit: 25 } },
  { g: "📜 History (sign in)", label: "My archived events — newest", c: "history", q: { start: "userEvent", orderBy: [{ field: "seq", dir: "desc" }], limit: 25 } },
  { g: "📜 History (sign in)", label: "My fills (archive)", c: "history", q: { start: "userEvent", where: { eq: { field: "kind", value: "fill" } }, orderBy: [{ field: "seq", dir: "desc" }], limit: 25 } },
];

// Populate the Examples dropdown, grouped by category (one optgroup per `g`).
function dxPopulatePresets() {
  const sel = document.getElementById("dx-presets");
  if (!sel || sel.dataset.filled) return;
  sel.dataset.filled = "1";
  const groups = [];
  for (const p of DX_PRESETS) { let grp = groups.find((x) => x.g === p.g); if (!grp) { grp = { g: p.g, items: [] }; groups.push(grp); } grp.items.push(p); }
  sel.innerHTML = '<option value="">— pick a query —</option>'
    + groups.map((grp) => `<optgroup label="${dxEsc(grp.g)}">`
        + grp.items.map((p) => `<option value="${DX_PRESETS.indexOf(p)}">${dxEsc(p.label)}</option>`).join("")
      + `</optgroup>`).join("");
}

// Load a preset (or any explicit query) into the explorer and run it. The raw
// box is authoritative on Run, so we set the entity/columns for display, write
// the exact query to the raw box, reveal it, and execute. `reveal: false`
// (rail browses, the first-open auto-browse) skips opening the raw box —
// presets open it deliberately (copy-and-tweak documentation), but a plain
// "show me this entity" click shouldn't push JSON in the user's face.
async function dxApplyQuery(q, canister, { reveal = true } = {}) {
  _dxAutoBrowsed = true;   // any explicit query supersedes the first-open auto-browse
  const want = canister === "history" ? "history" : "exchange";
  const canSel = document.getElementById("dx-canister");
  if (canSel) canSel.value = want;
  _dxCanister = want;
  _dxOffset = 0; _dxRows = [];
  await dxEnsureSchema();                       // loads + lists the entities for this canister
  const entSel = document.getElementById("dx-entity");
  if (entSel && q.start) entSel.value = q.start;
  dxSelectEntity();                             // refresh meta + columns + filters for the new entity
  _dxSelect = Array.isArray(q.select) ? q.select.slice() : [];
  dxRenderCols();
  // Reflect the query's shaping controls into the builder so they're visible and
  // tweakable (the raw box still carries any complex `where`).
  _dxGroupBy = Array.isArray(q.groupBy) ? q.groupBy.slice() : [];
  dxRenderGroupBy();
  document.getElementById("dx-aggs").innerHTML = "";
  if (Array.isArray(q.aggregate)) q.aggregate.forEach((a) => dxAddAgg({ fn: a.fn, field: a.field, as: a.as }));
  document.getElementById("dx-sorts").innerHTML = "";
  if (Array.isArray(q.orderBy)) q.orderBy.forEach((s) => dxAddSort(s.field, s.dir));
  dxSetCombinator(q.where && q.where.or ? "or" : "and");
  const raw = document.getElementById("dx-raw");
  if (raw) raw.value = JSON.stringify(q, null, 2);
  if (reveal) dxShowRaw(true);
  dxRun(true);
}

// Drill through an edge: pivot to the related entity, keyed by the cell value.
// Coerce the value to the target primary key's type — a Nat pk compared against
// a string never matches.
function dxDrillTo(target, raw) {
  const t = dxSchemaEntity(target);
  if (!t) return;
  const pk = t.fields.find((f) => f.name === t.primaryKey);
  let value = raw;
  if (pk && (pk.typeName === "Nat" || pk.typeName === "Int" || pk.typeName === "Float")) { const n = Number(raw); if (!isNaN(n)) value = n; }
  dxApplyQuery({ start: target, where: { eq: { field: t.primaryKey, value } }, limit: 25 }, _dxCanister);
}

// Column chips for the selected entity: click to toggle a field in `select`
// (projection). Edge fields are marked — picking one shows the raw foreign key;
// reach the joined value with a dotted path (e.g. marketId.lastPrice) in a
// preset or the raw editor. Empty selection = all columns.
function dxRenderCols() {
  const wrap = document.getElementById("dx-cols");
  if (!wrap) return;
  const ent = dxCurrentEntity();
  if (!ent) { wrap.innerHTML = ""; dxRenderEdgePanel(); return; }
  const sel = new Set(_dxSelect);
  wrap.innerHTML = ent.fields.map((f) => {
    const on = sel.has(f.name);
    const isEdge = !!(f.role && typeof f.role === "object" && f.role.edge);
    const isPk = f.name === ent.primaryKey;
    const tip = (f.typeName || "") + (isPk ? " · primary key" : "") + (f.values ? ` · ${f.values.join("/")}` : "");
    if (!isEdge) {
      return `<button type="button" class="dx-col${on ? " on" : ""}" data-f="${dxEsc(f.name)}" title="${dxEsc(tip)}">${isPk ? "🔑 " : ""}${dxEsc(f.name)}</button>`;
    }
    // Edge fields render as a SPLIT chip: the body toggles the raw FK column,
    // the →target tail opens/closes the joined-fields panel. Naming the target
    // entity on the chip makes the data graph legible at a glance — the old
    // bare ↗ glyph made joins the explorer's least discoverable feature.
    const open = _dxExpandedEdge === f.name;
    return `<span class="dx-col dx-col-edge${on ? " on" : ""}${open ? " open" : ""}">`
      + `<button type="button" class="dx-col-body" data-f="${dxEsc(f.name)}" title="${dxEsc(tip + " · foreign-key column")}">${isPk ? "🔑 " : ""}${dxEsc(f.name)}</button>`
      + `<button type="button" class="dx-col-tail" data-edge="${dxEsc(f.name)}" title="Join fields from ${dxEsc(f.role.edge.to)}">→ ${dxEsc(f.role.edge.to)}</button>`
      + `</span>`;
  }).join("") + `<span class="dx-cols-hint">${_dxSelect.length ? `${_dxSelect.length} selected` : "all columns"}</span>`;
  wrap.querySelectorAll("[data-f]").forEach((b) => { b.onclick = () => dxToggleCol(b.dataset.f); });
  wrap.querySelectorAll("[data-edge]").forEach((s) => { s.onclick = () => dxToggleEdgeExpand(s.dataset.edge); });
  dxRenderEdgePanel();
}
function dxToggleCol(name) {
  const i = _dxSelect.indexOf(name);
  if (i >= 0) _dxSelect.splice(i, 1); else _dxSelect.push(name);
  dxRenderCols();
  dxRenderGroupBy();   // dotted selections double as offered group keys
  dxSyncRaw();
}
// Edge-expansion: show the open edge's target entity fields as `edge.field`
// chips that toggle joined columns into the projection.
function dxToggleEdgeExpand(name) {
  _dxExpandedEdge = _dxExpandedEdge === name ? null : name;
  dxRenderCols();   // re-render: the split chip carries an `open` state, and it calls dxRenderEdgePanel
}
function dxRenderEdgePanel() {
  const panel = document.getElementById("dx-edge-panel");
  if (!panel) return;
  const ent = dxCurrentEntity();
  const ef = ent && _dxExpandedEdge ? ent.fields.find((f) => f.name === _dxExpandedEdge && f.role && f.role.edge) : null;
  const target = ef ? dxSchemaEntity(ef.role.edge.to) : null;
  if (!ef || !target) { panel.style.display = "none"; panel.innerHTML = ""; return; }
  const sel = new Set(_dxSelect);
  panel.style.display = "";
  panel.innerHTML = `<span class="dx-edge-panel-label">↗ ${dxEsc(ef.name)} → ${dxEsc(target.name)}:</span>`
    + target.fields.map((tf) => {
        const path = `${ef.name}.${tf.name}`;
        // A target field that is itself an edge can be chained (≤4 hops) —
        // mark it and say how, since the panel only builds one hop of UI.
        const nested = tf.role && typeof tf.role === "object" && tf.role.edge ? tf.role.edge.to : null;
        const tip = (tf.typeName || "") + (nested ? ` · edge → ${nested} — chain deeper by typing ${path}.field in the query box` : "");
        return `<button type="button" class="dx-subcol${sel.has(path) ? " on" : ""}" data-sub="${dxEsc(path)}" title="${dxEsc(tip)}">${dxEsc(tf.name)}${nested ? " →" : ""}</button>`;
      }).join("");
  panel.querySelectorAll(".dx-subcol").forEach((b) => { b.onclick = () => dxToggleCol(b.dataset.sub); });
}

// Toggle the raw-query box + its operator help (and keep them in sync). `show`
// forces visible; omit to flip. Used by the Show/Hide button and presets.
function dxShowRaw(show) {
  const raw = document.getElementById("dx-raw");
  const help = document.getElementById("dx-help");
  const btn = document.getElementById("dx-raw-toggle");
  if (!raw) return;
  const vis = show === undefined ? raw.style.display === "none" : show;
  raw.style.display = vis ? "" : "none";
  if (help) help.style.display = vis ? "" : "none";
  if (btn) btn.textContent = vis ? "Hide query" : "Show query";
}

function dxStatus(msg, err) {
  const el = document.getElementById("dx-status");
  if (el) { el.textContent = msg || ""; el.classList.toggle("dx-status-err", !!err); }
}
function dxEntities() { return _dxSchemaByCanister[_dxCanister] || []; }
function dxCurrentEntity() {
  const v = document.getElementById("dx-entity")?.value;
  return dxEntities().find((e) => e.name === v) || null;
}
// The whole History canister is per-caller (the proxy fetches only the caller's
// own archived events), so signed-out it has nothing to show — gate it like a
// scoped entity. On Exchange, only the owner-scoped entities (pool/position/...)
// are gated.
function dxNeedsSignIn(ent) { return _dxCanister === "history" || dxEntityIsScoped(ent); }

// Fetch the active canister's schema (Exchange → schema(); History →
// archiveSchema()) and populate the entity dropdown. Cached per canister.
export async function dxEnsureSchema() {
  const c = _dxCanister;
  if (!_dxSchemaByCanister[c]) {
    // Dedupe concurrent callers (e.g. showIntelliTab + a shared-link apply both
    // fire this on load) onto one fetch.
    if (!_dxSchemaPromise[c]) {
      _dxSchemaPromise[c] = (async () => {
        // A direct #ai/memory load reaches here before init has built the
        // anonymous actor — wait briefly for one instead of failing the whole
        // pane on a cold start (it used to show "Could not load schema:
        // Cannot read properties of null" until the tab was re-opened).
        let a = appState.actor || appState.publicActor;
        for (let i = 0; !a && i < 50; i++) { await new Promise((r) => setTimeout(r, 100)); a = appState.actor || appState.publicActor; }
        if (!a) throw new Error("backend connection not ready — reopen this tab");
        const txt = c === "history" ? await a.archiveSchema() : await a.schema([]);
        _dxSchemaByCanister[c] = (JSON.parse(txt).entities) || [];
      })();
    }
    try { await _dxSchemaPromise[c]; }
    catch (e) { _dxSchemaPromise[c] = null; dxStatus("Could not load schema: " + oqlErrorMessage(e), true); return; }   // clear → retry next time
  }
  // Populate the dropdown + default-select the first entity only ONCE per canister
  // (guarded by dataset.canister) — re-running would reset a selection a caller
  // (preset / shared link) just made.
  const sel = document.getElementById("dx-entity");
  if (sel && sel.dataset.canister !== c) {
    sel.dataset.canister = c;
    sel.innerHTML = dxEntities().map((e) => `<option value="${e.name}">${e.name}</option>`).join("");
    dxSelectEntity();
  }
  dxRenderRail();
  dxRenderStats();
  // First open: browse the markets, so the pane greets with live rows instead
  // of an empty table (public entity — safe for any caller). A shared link or
  // preset applied during load sets _dxAutoBrowsed synchronously before this
  // post-await check runs, so an explicit query is never raced or overwritten.
  if (!_dxAutoBrowsed && c === "exchange") {
    dxApplyQuery({ start: "market", orderBy: [{ field: "id", dir: "asc" }], limit: 25 }, "exchange", { reveal: false });
  }
}

// The schema-in-one-glance strip: how much surface this canister exposes, and
// the reminder that these are not exports — the rows come straight out of the
// canister's persistent heap (orthogonal persistence), so what you query is
// the authoritative record, not a synced copy.
function dxRenderStats() {
  const el = document.getElementById("dx-stats");
  if (!el) return;
  const ents = dxEntities();
  if (!ents.length) { el.style.display = "none"; return; }
  const fields = ents.reduce((s, e) => s + e.fields.length, 0);
  const edges = ents.reduce((s, e) => s + e.fields.filter((f) => f.role && typeof f.role === "object" && f.role.edge).length, 0);
  const where = _dxCanister === "history" ? "the archive canister's" : "the exchange canister's";
  el.style.display = "";
  el.innerHTML = `<span class="dx-stat"><strong>${ents.length}</strong> entities</span>`
    + `<span class="dx-stat"><strong>${fields}</strong> fields</span>`
    + `<span class="dx-stat"><strong>${edges}</strong> joins</span>`
    + `<span class="dx-stats-note">no database behind this — every row is read live from ${where} persistent memory</span>`;
}

// The entity rail (sidebar): one item per entity, with field-count / join /
// scoped badges. The hidden <select id="dx-entity"> stays the source of truth;
// the rail just drives it (click → set value + dispatch change → dxSelectEntity).
function dxRenderRail() {
  const rail = document.getElementById("dx-rail");
  if (!rail) return;
  const cur = document.getElementById("dx-entity")?.value;
  rail.innerHTML = dxEntities().map((e) => {
    const nf = e.fields.length;
    const ne = e.fields.filter((f) => f.role && typeof f.role === "object" && f.role.edge).length;
    const scoped = dxEntityIsScoped(e);
    return `<button type="button" class="dx-rail-item${e.name === cur ? " active" : ""}" data-e="${dxEsc(e.name)}">`
      + `<span class="dx-rail-name">${dxEsc(e.name)}</span>`
      + `<span class="dx-rail-badges"><span class="dx-rail-badge" title="${nf} fields">${nf}f</span>`
      + `${ne ? `<span class="dx-rail-badge dx-rail-badge-edge" title="${ne} join${ne === 1 ? "" : "s"}">${ne}↗</span>` : ""}`
      + `${scoped ? `<span class="dx-rail-badge dx-rail-badge-lock" title="your rows only (owner-scoped)">●</span>` : ""}`
      + `</span></button>`;
  }).join("");
  rail.querySelectorAll(".dx-rail-item").forEach((b) => { b.onclick = () => dxPickEntity(b.dataset.e); });
}
// Rail click = browse: select the entity AND run its default query, so a
// click answers "what's in here?" immediately instead of leaving an empty
// table waiting for a manual Run. (Re-clicking the active entity re-browses —
// a cheap refresh.) The builder resets to a clean slate via dxApplyQuery.
function dxPickEntity(name) {
  const sel = document.getElementById("dx-entity");
  if (!sel) return;
  dxApplyQuery({ start: name, limit: 25 }, _dxCanister, { reveal: false });
}

// Switch between the Exchange and History canisters: reset results and load the
// selected canister's schema + entity list.
function dxSelectCanister() {
  _dxCanister = document.getElementById("dx-canister")?.value === "history" ? "history" : "exchange";
  _dxOffset = 0; _dxRows = [];
  document.getElementById("dx-results").innerHTML = "";
  document.getElementById("dx-more").style.display = "none";
  dxStatus("");
  dxEnsureSchema();
}

function dxSelectEntity() {
  const ent = dxCurrentEntity();
  _dxSelect = []; _dxGroupBy = []; _dxExpandedEdge = null;   // new entity → reset projection + grouping + edge panel
  const meta = document.getElementById("dx-entity-meta");
  if (meta) meta.innerHTML = ent ? `<strong>${dxEsc(ent.name)}</strong> · pk: ${dxEsc(ent.primaryKey)} · ${ent.fields.length} fields${ent.fields.some((f) => f.role && typeof f.role === "object" && f.role.edge) ? " · joins ↗" : ""}` : "";
  document.getElementById("dx-filters").innerHTML = "";
  document.getElementById("dx-aggs").innerHTML = "";
  document.getElementById("dx-sorts").innerHTML = "";
  dxRenderCols();
  dxRenderGroupBy();
  dxRenderRail();
  dxUpdateCombinator();
  document.getElementById("dx-results").innerHTML = "";
  document.getElementById("dx-more").style.display = "none";
  dxStatus("");
  dxUpdateFilterMe();
  dxUpdateSearch();
  dxSyncRaw();
  // Selecting a private entity (or any History entity) while signed out: show
  // the sign-in prompt up front rather than waiting for a Run that returns nothing.
  if (!appState.isAuthenticated && dxNeedsSignIn(ent)) {
    dxRenderSignInPrompt(ent ? ent.name : "history");
    dxStatus("Sign in to see your own rows.");
  }
}

// React to sign-in/out while the Data explorer is open. Without this, the
// "Sign in to view…" gate is left stale after the user authenticates (the
// header button updates but #dx-results doesn't). On sign-in: clear the gate
// and show the user's rows; on sign-out: re-show the gate.
export function dxOnAuthChange() {
  const view = document.getElementById("intelli-view");
  if (!view || !view.classList.contains("active") || appState.intelliTab !== "explorer") return;
  if (!dxEntities().length) return;   // explorer not opened / schema not loaded yet
  dxUpdateIdentity();
  const ent = dxCurrentEntity();
  const gateShowing = !!document.querySelector("#dx-results .dx-signin");
  if (appState.isAuthenticated && gateShowing && dxNeedsSignIn(ent)) {
    dxRun(true);        // signed in while gated → replace the gate with the user's rows
  } else if (!appState.isAuthenticated && dxNeedsSignIn(ent) && !gateShowing) {
    dxSelectEntity();   // signed out while viewing a now-private entity → re-show the gate
  }
  // otherwise no gate transition is needed — leave any existing results untouched
}

// Show the signed-in identity line (friendly name + raw principal) above the
// query builder, so the user can read/copy the exact principal their rows are
// keyed by and one-click "Filter to me".
export function dxUpdateIdentity() {
  const row = document.getElementById("dx-identity");
  if (!row) return;
  if (appState.isAuthenticated && appState.myPrincipalText) {
    row.style.display = "";
    const nameEl = document.getElementById("dx-identity-name");
    const prinEl = document.getElementById("dx-identity-principal");
    const prof = appState.getUserProfile ? appState.getUserProfile() : null;
    if (nameEl) nameEl.textContent = (prof && prof.username) ? prof.username : "(no name yet)";
    if (prinEl) prinEl.textContent = appState.myPrincipalText;
  } else {
    row.style.display = "none";
  }
  // The Ask-AI handoff only exists where the Assistant does (backend AI key set).
  const askBtn = document.getElementById("dx-ask-ai");
  if (askBtn) askBtn.style.display = appState.aiConfigured ? "" : "none";
  dxUpdateFilterMe();
}

// "Filter to me" only makes sense for entities that carry an owner principal
// (pool, position, order). Disable it otherwise, or when not signed in.
function dxUpdateFilterMe() {
  const btn = document.getElementById("dx-filter-me");
  if (!btn) return;
  const ent = dxCurrentEntity();
  const hasOwner = !!(ent && ent.fields.some((f) => f.name === "owner"));
  btn.disabled = !(appState.isAuthenticated && appState.myPrincipalText && hasOwner);
  btn.title = !appState.isAuthenticated ? "Sign in to filter to your own rows"
    : !hasOwner ? "This entity has no owner field"
    : "Filter the current entity to rows you own";
}

// Replace the filter set with a single owner == (my principal) filter and run.
// For pool/position this just confirms the server-side scoping; for the public
// order book it narrows the global book down to your own resting orders.
function dxFilterToMe() {
  const ent = dxCurrentEntity();
  if (!ent || !appState.myPrincipalText) return;
  if (!ent.fields.some((f) => f.name === "owner")) { dxStatus("This entity has no owner field to filter on.", true); return; }
  document.getElementById("dx-filters").innerHTML = "";
  dxAddFilter();
  const f = document.querySelector("#dx-filters .dx-filter");
  f.querySelector(".dx-f-field").value = "owner";
  f.querySelector(".dx-f-op").value = "eq";
  f.querySelector(".dx-f-val").value = appState.myPrincipalText;
  dxSyncRaw();
  dxRun(true);
}

// ── Quick search: a one-box icontains over the entity's most human-readable
// text field (message for events, name for pools, marketId for orders, …).
// Same contract as a preset: the query goes straight to the raw box and runs;
// the builder is left alone. An empty term browses the entity plain.
function dxLabelField(ent) {
  if (!ent) return null;
  for (const p of ["message", "name", "username", "title", "marketId", "token", "baseToken"]) {
    const f = ent.fields.find((x) => x.name === p && x.typeName === "Text");
    if (f) return f.name;
  }
  // Any text field beats the primary key (a search box over ids reads odd,
  // but it's better than no search at all). Edge FKs count — their text IS
  // meaningful (e.g. "BTC-ICPUSD").
  const t = ent.fields.find((f) => f.typeName === "Text" && f.name !== ent.primaryKey);
  return t ? t.name : (ent.fields.some((f) => f.name === ent.primaryKey && f.typeName === "Text") ? ent.primaryKey : null);
}
function dxRunSearch() {
  const ent = dxCurrentEntity();
  const field = dxLabelField(ent);
  const input = document.getElementById("dx-search");
  if (!ent || !field || !input) return;
  const term = input.value.trim();
  const q = term
    ? { start: ent.name, where: { icontains: { field, value: term } }, limit: 25 }
    : { start: ent.name, limit: 25 };
  const raw = document.getElementById("dx-raw");
  if (raw) raw.value = JSON.stringify(q, null, 2);
  dxRun(true);
}
// New entity → clear the term and re-aim the placeholder at its label field
// (or disable the box for the rare entity with nothing text-y to search).
function dxUpdateSearch() {
  const input = document.getElementById("dx-search");
  if (!input) return;
  const ent = dxCurrentEntity();
  const f = dxLabelField(ent);
  input.value = "";
  input.disabled = !f;
  input.placeholder = f ? `Search ${ent.name} by ${f} — case-insensitive, ↵ runs` : "No text field to search";
}

function dxAddFilter() {
  const ent = dxCurrentEntity();
  if (!ent) return;
  const row = document.createElement("div");
  row.className = "dx-filter";
  row.innerHTML = `<button type="button" class="dx-f-not" title="Negate this condition (NOT)">not</button>`
    + `<select class="dx-select dx-f-field">${dxFieldOptionsHtml(ent)}</select>`
    + `<select class="dx-select dx-f-op">${DX_OPS.map((o) => `<option value="${o}">${o}</option>`).join("")}</select>`
    + `<input class="dx-input dx-f-val" placeholder="value">`
    + `<button class="dx-f-rm" title="Remove filter">✕</button>`;
  const opSel = row.querySelector(".dx-f-op"), valEl = row.querySelector(".dx-f-val");
  opSel.addEventListener("change", () => { valEl.placeholder = opSel.value === "in" ? "a, b, c" : "value"; });
  row.querySelector(".dx-f-not").onclick = (e) => { e.currentTarget.classList.toggle("on"); dxSyncRaw(); };
  row.querySelector(".dx-f-rm").onclick = () => { row.remove(); dxUpdateCombinator(); dxSyncRaw(); };
  row.querySelectorAll("select,input").forEach((el) => el.addEventListener("input", dxSyncRaw));
  document.getElementById("dx-filters").appendChild(row);
  dxUpdateCombinator();
  dxSyncRaw();
}

// Show the AND/OR combinator toggle only when there are ≥2 filters to combine.
function dxUpdateCombinator() {
  const c = document.getElementById("dx-combinator");
  if (c) c.style.display = document.querySelectorAll("#dx-filters .dx-filter").length >= 2 ? "" : "none";
}
function dxSetCombinator(mode) {
  _dxCombinator = mode === "or" ? "or" : "and";
  document.querySelectorAll("#dx-combinator .dx-comb-btn").forEach((b) => b.classList.toggle("active", b.dataset.comb === _dxCombinator));
  dxSyncRaw();
}

// Group-by chips (toggle a field into `groupBy`) and aggregate/sort row builders.
function dxRenderGroupBy() {
  const wrap = document.getElementById("dx-groupby");
  if (!wrap) return;
  const ent = dxCurrentEntity();
  if (!ent) { wrap.innerHTML = ""; return; }
  const sel = new Set(_dxGroupBy);
  // Groupable keys: the entity's own fields, plus any dotted (joined) paths
  // already in play — picked as columns or set by a preset's groupBy. Joined
  // group keys are engine-supported; offering exactly the in-play ones keeps
  // the chip row from exploding with every edge's every field.
  const names = ent.fields.map((f) => f.name);
  for (const p of [..._dxSelect, ..._dxGroupBy]) if (p.includes(".") && !names.includes(p)) names.push(p);
  wrap.innerHTML = names.map((n) => `<button type="button" class="dx-col${sel.has(n) ? " on" : ""}" data-g="${dxEsc(n)}">${dxEsc(n)}</button>`).join("")
    + `<span class="dx-cols-hint">${_dxGroupBy.length ? `grouping by ${_dxGroupBy.length}` : "no grouping"}</span>`;
  wrap.querySelectorAll(".dx-col").forEach((b) => { b.onclick = () => dxToggleGroup(b.dataset.g); });
}
function dxToggleGroup(name) {
  const i = _dxGroupBy.indexOf(name);
  if (i >= 0) _dxGroupBy.splice(i, 1); else _dxGroupBy.push(name);
  dxRenderGroupBy();
  dxSyncRaw();
}
function dxAddAgg(init) {
  const ent = dxCurrentEntity();
  if (!ent) return null;
  const row = document.createElement("div");
  row.className = "dx-filter dx-agg";
  row.innerHTML = `<select class="dx-select dx-a-fn">${DX_AGG_FNS.map((f) => `<option value="${f}">${f}</option>`).join("")}</select>`
    + `<select class="dx-select dx-a-field"><option value="">— field —</option>${ent.fields.map((f) => `<option value="${f.name}">${f.name}</option>`).join("")}</select>`
    + `<input class="dx-input dx-a-as" placeholder="as (optional)">`
    + `<button class="dx-f-rm" title="Remove aggregate">✕</button>`;
  const fnSel = row.querySelector(".dx-a-fn"), fieldSel = row.querySelector(".dx-a-field");
  const sync = () => { fieldSel.disabled = fnSel.value === "count"; };
  fnSel.addEventListener("change", sync);
  if (init) { fnSel.value = init.fn || "count"; if (init.field) fieldSel.value = init.field; if (init.as) row.querySelector(".dx-a-as").value = init.as; }
  sync();
  row.querySelector(".dx-f-rm").onclick = () => { row.remove(); dxSyncRaw(); };
  row.querySelectorAll("select,input").forEach((el) => el.addEventListener("input", dxSyncRaw));
  document.getElementById("dx-aggs").appendChild(row);
  dxSyncRaw();
  return row;
}
function dxAddSort(field, dir) {
  const ent = dxCurrentEntity();
  if (!ent) return null;
  // A field outside the schema options (an agg alias like `depth`, a >1-hop
  // dotted path) prepends as its own option so any preset sort is representable.
  const known = !!(field && (ent.fields.some((f) => f.name === field) || dxFieldByPath(ent, field)));
  const row = document.createElement("div");
  row.className = "dx-filter dx-sort";
  row.innerHTML = `<select class="dx-select dx-s-field">`
    + (field && !known ? `<option value="${dxEsc(field)}" selected>${dxEsc(field)}</option>` : "")
    + dxFieldOptionsHtml(ent, field) + `</select>`
    + `<select class="dx-select dx-s-dir"><option value="asc">asc</option><option value="desc"${dir === "desc" ? " selected" : ""}>desc</option></select>`
    + `<button class="dx-f-rm" title="Remove sort">✕</button>`;
  row.querySelector(".dx-f-rm").onclick = () => { row.remove(); dxSyncRaw(); };
  row.querySelectorAll("select").forEach((el) => el.addEventListener("input", dxSyncRaw));
  document.getElementById("dx-sorts").appendChild(row);
  dxSyncRaw();
  return row;
}
// Click a result-column header to sort by it: asc → desc → off (cycle).
function dxSortByColumn(col) {
  const wrap = document.getElementById("dx-sorts");
  const rows = [...wrap.querySelectorAll(".dx-sort")];
  const cur = rows.find((r) => r.querySelector(".dx-s-field").value === col);
  if (cur && rows.length === 1) {
    const dir = cur.querySelector(".dx-s-dir");
    if (dir.value === "asc") dir.value = "desc";
    else { wrap.innerHTML = ""; dxSyncRaw(); dxRun(true); return; }
  } else {
    wrap.innerHTML = "";
    dxAddSort(col, "asc");
  }
  dxSyncRaw();
  dxRun(true);
}

// Resolve a (possibly dotted) path against the schema: "marketId.lastPrice"
// walks the marketId edge into market and returns lastPrice's field decl.
// null when any segment is unknown (agg aliases, mistyped paths).
function dxFieldByPath(ent, path) {
  let cur = ent;
  const segs = String(path).split(".");
  for (let i = 0; i < segs.length; i++) {
    const f = cur && cur.fields ? cur.fields.find((x) => x.name === segs[i]) : null;
    if (!f) return null;
    if (i === segs.length - 1) return f;
    const to = f.role && typeof f.role === "object" && f.role.edge ? f.role.edge.to : null;
    cur = to ? dxSchemaEntity(to) : null;
  }
  return null;
}

// Options for the filter/sort field selects: the entity's own fields, then one
// optgroup per edge listing its joined fields as dotted paths — so "orders
// where marketId.base = BTC" or "sort by marketId.lastPrice" is reachable from
// the builder, not raw-box-only. Deeper hops stay typed (the engine takes ≤4).
function dxFieldOptionsHtml(ent, selectedName) {
  if (!ent) return "";
  const opt = (n) => `<option value="${dxEsc(n)}"${n === selectedName ? " selected" : ""}>${dxEsc(n)}</option>`;
  let html = ent.fields.map((f) => opt(f.name)).join("");
  for (const f of ent.fields) {
    const to = f.role && typeof f.role === "object" && f.role.edge ? f.role.edge.to : null;
    const target = to ? dxSchemaEntity(to) : null;
    if (!target) continue;
    html += `<optgroup label="${dxEsc(f.name + " → " + to)}">` + target.fields.map((tf) => opt(`${f.name}.${tf.name}`)).join("") + `</optgroup>`;
  }
  return html;
}

// Coerce the filter value to the JSON type OQL expects for that field —
// resolving dotted paths through their edges, so a joined Float/Nat filter
// compares numerically instead of never matching as text.
function dxCoerce(fieldName, raw) {
  if (raw === "") return "";
  const f = dxFieldByPath(dxCurrentEntity(), fieldName);
  const t = f && f.typeName;
  if (t === "Nat" || t === "Int" || t === "Float") { const n = Number(raw); return isNaN(n) ? raw : n; }
  if (t === "Bool") return raw === "true" || raw === "1";
  return raw;
}

function dxBuildQuery() {
  const start = document.getElementById("dx-entity")?.value || "";
  const q = { start };
  // Filters → predicates (each optionally negated with `not`, `in` takes a
  // comma list), combined by AND (match ALL) or OR (match ANY).
  const filters = [...document.querySelectorAll("#dx-filters .dx-filter")].map((r) => {
    const field = r.querySelector(".dx-f-field").value;
    const op = r.querySelector(".dx-f-op").value;
    const rawv = r.querySelector(".dx-f-val").value;
    let pred = op === "in"
      ? { in: { field, value: rawv.split(",").map((s) => dxCoerce(field, s.trim())) } }
      : { [op]: { field, value: dxCoerce(field, rawv) } };
    if (r.querySelector(".dx-f-not")?.classList.contains("on")) pred = { not: pred };
    return pred;
  });
  if (filters.length === 1) q.where = filters[0];
  else if (filters.length > 1) q.where = { [_dxCombinator]: filters };
  // Group by + aggregate.
  if (_dxGroupBy.length) q.groupBy = _dxGroupBy.slice();
  const aggs = [...document.querySelectorAll("#dx-aggs .dx-agg")].map((r) => {
    const fn = r.querySelector(".dx-a-fn").value;
    const a = { fn };
    const field = r.querySelector(".dx-a-field").value;
    if (fn !== "count" && field) a.field = field;
    const as_ = r.querySelector(".dx-a-as").value.trim();
    if (as_) a.as = as_;
    return a;
  });
  if (aggs.length) q.aggregate = aggs;
  // Sort — multi-field.
  const sorts = [...document.querySelectorAll("#dx-sorts .dx-sort")]
    .map((r) => ({ field: r.querySelector(".dx-s-field").value, dir: r.querySelector(".dx-s-dir").value }))
    .filter((s) => s.field);
  if (sorts.length) q.orderBy = sorts;
  if (_dxSelect.length) q.select = _dxSelect.slice();
  const lim = parseInt(document.getElementById("dx-limit")?.value, 10);
  if (lim > 0) q.limit = lim;
  return q;
}

// Keep the raw-JSON box in sync with the builder, unless the user is editing it.
function dxSyncRaw() {
  const raw = document.getElementById("dx-raw");
  if (raw && document.activeElement !== raw) raw.value = JSON.stringify(dxBuildQuery(), null, 2);
}

function dxRenderTable(objs) {
  const el = document.getElementById("dx-results");
  if (!el) return;
  if (!objs.length) { el.innerHTML = '<div class="dx-empty">No matching rows — loosen or drop the filters to confirm the entity has data.</div>'; return; }
  const cols = [...new Set(objs.flatMap((o) => Object.keys(o)))];
  // Type/edge metadata for the entity these rows came from (drives formatting +
  // drill-through). Dotted (joined) columns aren't direct fields, so they format
  // by value and never drill.
  const ent = dxSchemaEntity(_dxResultEntity);
  const fieldOf = (c) => (ent && ent.fields.find((f) => f.name === c)) || null;
  const edgeOf = (c) => { const f = fieldOf(c); return f && f.role && typeof f.role === "object" && f.role.edge ? f.role.edge.to : null; };
  // Current sort direction per column, to mark the header (and click cycles it).
  const sortMap = {};
  document.querySelectorAll("#dx-sorts .dx-sort").forEach((r) => { sortMap[r.querySelector(".dx-s-field").value] = r.querySelector(".dx-s-dir").value; });
  const sortMark = (c) => sortMap[c] ? ` <span class="dx-th-sortmark">${sortMap[c] === "desc" ? "▼" : "▲"}</span>` : "";
  const head = cols.map((c) => `<th class="dx-th-sort" data-col="${dxEsc(c)}" title="Sort by ${dxEsc(c)}">${dxEsc(c)}${edgeOf(c) ? ' <span class="dx-th-edge" title="links to ' + dxEsc(edgeOf(c)) + '">↗</span>' : ""}${sortMark(c)}</th>`).join("");
  const body = objs.map((o) => "<tr>" + cols.map((c) => {
    const cell = oqlFormatCell(c, o[c], fieldOf(c));
    const to = edgeOf(c);
    const inner = (to && o[c] !== "" && o[c] != null)
      ? `<a class="dx-link" data-to="${dxEsc(to)}" data-v="${dxEsc(String(o[c]))}" title="Follow → ${dxEsc(to)}">${cell.html}</a>`
      : cell.html;
    return `<td${cell.title ? ` title="${dxEsc(cell.title)}"` : ""}>${inner}</td>`;
  }).join("") + "</tr>").join("");
  el.innerHTML = `<div class="dx-table-wrap"><table class="dx-table"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
  el.querySelectorAll(".dx-link").forEach((a) => { a.onclick = (e) => { e.preventDefault(); dxDrillTo(a.dataset.to, a.dataset.v); }; });
  el.querySelectorAll(".dx-th-sort").forEach((th) => { th.onclick = (e) => { if (e.target.closest(".dx-link")) return; dxSortByColumn(th.dataset.col); }; });
}

// Look an entity up in the cached schema, and decide whether it is owner-scoped
// (private per-user). The schema tags the owning field with role "owner" — only
// entities that called .ownedBy(...) on the backend have one. pool/position are
// scoped; market/order/event are public (their owner column, if any, is a plain
// payload). We gate scoped entities behind sign-in: signed out you'd see ZERO
// rows server-side anyway, so show a "sign in" prompt rather than an empty table
// that misleadingly implies there's nothing there.
function dxSchemaEntity(name) { return dxEntities().find((e) => e.name === name) || null; }
function dxEntityIsScoped(ent) { return !!(ent && ent.fields && ent.fields.some((f) => f.role === "owner")); }

function dxRenderSignInPrompt(entityName) {
  const el = document.getElementById("dx-results");
  if (!el) return;
  const noun = entityName === "pool" ? "your pools"
    : entityName === "position" ? "your positions"
    : "your " + entityName + " rows";
  el.innerHTML = `<div class="dx-signin">
    <div class="dx-signin-title">Sign in to view ${noun}</div>
    <div class="dx-signin-body">The <code>${entityName}</code> entity is private — each user can only see their own rows. Sign in to query it as yourself. Public data (markets, the order book, events) stays browsable without signing in.</div>
    <button id="dx-signin-btn" class="btn btn-primary">Sign In</button>
  </div>`;
  document.getElementById("dx-signin-btn")?.addEventListener("click", () => appState.login?.());
  document.getElementById("dx-more").style.display = "none";
}

async function dxRun(reset) {
  const raw = document.getElementById("dx-raw");
  let q;
  try { q = JSON.parse((raw && raw.value) || "{}"); }
  catch (e) { dxStatus("Invalid query JSON: " + e.message, true); return; }
  if (!q.start) { dxStatus("Pick an entity (\"start\") first.", true); return; }
  // Don't fire a scoped/History query for a signed-out visitor: prompt to sign in.
  if (!appState.isAuthenticated && (_dxCanister === "history" || dxEntityIsScoped(dxSchemaEntity(q.start)))) {
    dxRenderSignInPrompt(_dxCanister === "history" ? "history" : q.start);
    dxStatus("Sign in to see your own rows.");
    return;
  }
  _dxResultEntity = q.start;
  if (reset) { _dxOffset = 0; _dxRows = []; }
  q.offset = _dxOffset;
  if (!q.limit) q.limit = parseInt(document.getElementById("dx-limit")?.value, 10) || 25;
  dxStatus(_dxCanister === "history" ? "Querying the archive…" : "Running…");
  let res; const _t0 = performance.now();
  try {
    const a = appState.actor || appState.publicActor;
    res = _dxCanister === "history"
      ? await a.archiveExecute(JSON.stringify(q))      // composite query: federates to the archive sidecar
      : await a.execute(JSON.stringify(q));
  }
  catch (e) { dxStatus("Query failed: " + oqlErrorMessage(e), true); return; }   // the engine's traps are self-describing
  const ms = Math.round(performance.now() - _t0);
  const objs = oqlRowsToObjects(res);
  _dxRows = reset ? objs : _dxRows.concat(objs);
  _dxOffset += objs.length;
  dxRenderTable(_dxRows);
  // History only: name any archive segment the fan-out could not read, so a
  // partial read never renders as complete history (W1-03).
  const degraded = res.degraded && res.degraded.length
    ? ` · ⚠ archive segment${res.degraded.length === 1 ? "" : "s"} unavailable (${res.degraded.join(", ")}) — history may be incomplete`
    : "";
  dxStatus(`${_dxRows.length} row${_dxRows.length === 1 ? "" : "s"} · ${ms} ms${res.hasMore ? " · more available" : ""}${degraded}`);
  const more = document.getElementById("dx-more");
  if (more) more.style.display = res.hasMore ? "" : "none";
}

// ── Export: download the current result rows as CSV or JSON ──
function dxDownload(filename, content, mime) {
  const blob = new Blob([content], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url; a.download = filename;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}
function dxToCsv(rows) {
  if (!rows.length) return "";
  const cols = Object.keys(rows[0]);
  const cell = (v) => {
    const s = v == null ? "" : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;   // RFC-4180 quoting
  };
  return [cols.join(","), ...rows.map((r) => cols.map((c) => cell(r[c])).join(","))].join("\n");
}
function dxExport(kind) {
  if (!_dxRows.length) { dxStatus("Run a query first — there are no rows to export.", true); return; }
  const base = `${_dxResultEntity || "query"}-${_dxRows.length}rows`;
  if (kind === "json") dxDownload(`${base}.json`, JSON.stringify(_dxRows, null, 2), "application/json");
  else dxDownload(`${base}.csv`, dxToCsv(_dxRows), "text/csv");
}

// ── Share: encode the current query into a link (?dxq=…) and back ──
function dxEncodeShare(obj) {
  return btoa(unescape(encodeURIComponent(JSON.stringify(obj))))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");   // base64url
}
function dxDecodeShare(s) {
  return JSON.parse(decodeURIComponent(escape(atob(s.replace(/-/g, "+").replace(/_/g, "/")))));
}
async function dxCopyShareLink() {
  const raw = document.getElementById("dx-raw");
  let q;
  try { q = JSON.parse((raw && raw.value) || "{}"); } catch { q = dxBuildQuery(); }
  if (!q || !q.start) { dxStatus("Pick an entity first, then copy a link.", true); return; }
  const url = `${location.origin}${location.pathname}?dxq=${dxEncodeShare({ c: _dxCanister, q })}#ai/memory`;
  const btn = document.getElementById("dx-share");
  try {
    await navigator.clipboard.writeText(url);
    if (btn) { btn.textContent = "Link copied!"; setTimeout(() => { btn.textContent = "Copy link"; }, 1500); }
  } catch {
    // Clipboard blocked (insecure context): surface the link in the raw box so it can be copied manually.
    if (raw) { raw.value = url; dxShowRaw(true); }
    dxStatus("Clipboard unavailable — link placed in the query box.");
  }
}
// On load: if the URL carries a shared query, open the explorer and run it,
// then strip the param so the address bar stays clean.
export function dxApplyShareLink() {
  const enc = new URLSearchParams(location.search).get("dxq");
  if (!enc) return;
  let shared;
  try { shared = dxDecodeShare(enc); } catch { return; }
  if (!shared || !shared.q) return;
  if (location.hash.slice(1).toLowerCase() !== "ai/memory") location.hash = "ai/memory";
  dxApplyQuery(shared.q, shared.c);
  history.replaceState(null, "", `${location.pathname}#ai/memory`);
}

// Hand the current query to the AI Assistant: prefill its input with a
// run-and-interpret prompt and switch tabs. Deliberately does NOT send — the
// user reviews and fires the turn; the explorer never spends an AI call itself.
function dxAskAi() {
  let q;
  try { q = JSON.parse(document.getElementById("dx-raw")?.value || "{}"); } catch { q = dxBuildQuery(); }
  if (!q || !q.start) { dxStatus("Pick an entity first, then ask the AI about the query.", true); return; }
  const input = document.getElementById("asst-input");
  if (input) {
    const where = _dxCanister === "history" ? " against the History archive" : "";
    input.value = `Run this OQL query${where} and interpret what the results say about the exchange right now: ${JSON.stringify(q)}`;
    input.dispatchEvent(new Event("input", { bubbles: true }));   // let any autosize listener react
  }
  window.location.hash = "ai/assistant";   // → Assistant tab; assistantOnShow focuses the input
}

export function setupIntelli() {
  document.querySelectorAll(".intelli-tab").forEach((b) =>
    b.addEventListener("click", () => { window.location.hash = "ai/" + b.dataset.intelli; }));
  // Quick search: ↵ runs (or re-browses when emptied); ✕ clears and re-browses.
  document.getElementById("dx-search")?.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); dxRunSearch(); }
  });
  document.getElementById("dx-search-clear")?.addEventListener("click", () => {
    const s = document.getElementById("dx-search");
    if (s && s.value) { s.value = ""; dxRunSearch(); }
  });
  document.getElementById("dx-ask-ai")?.addEventListener("click", dxAskAi);
  document.getElementById("dx-canister")?.addEventListener("change", dxSelectCanister);
  document.getElementById("dx-entity")?.addEventListener("change", dxSelectEntity);
  document.getElementById("dx-add-filter")?.addEventListener("click", dxAddFilter);
  document.getElementById("dx-filter-me")?.addEventListener("click", dxFilterToMe);
  document.getElementById("dx-identity-copy")?.addEventListener("click", async () => {
    const btn = document.getElementById("dx-identity-copy");
    if (!appState.myPrincipalText) return;
    try {
      await navigator.clipboard.writeText(appState.myPrincipalText);
      btn.textContent = "Copied!";
      setTimeout(() => { btn.textContent = "Copy"; }, 1500);
    } catch { /* clipboard blocked (insecure context) — no-op */ }
  });
  document.getElementById("dx-add-agg")?.addEventListener("click", () => dxAddAgg());
  document.getElementById("dx-add-sort")?.addEventListener("click", () => dxAddSort());
  document.querySelectorAll("#dx-combinator .dx-comb-btn").forEach((b) => b.addEventListener("click", () => dxSetCombinator(b.dataset.comb)));
  document.getElementById("dx-limit")?.addEventListener("input", dxSyncRaw);
  document.getElementById("dx-run")?.addEventListener("click", () => dxRun(true));
  document.getElementById("dx-more")?.addEventListener("click", () => dxRun(false));
  document.getElementById("dx-share")?.addEventListener("click", dxCopyShareLink);
  document.getElementById("dx-export-csv")?.addEventListener("click", () => dxExport("csv"));
  document.getElementById("dx-export-json")?.addEventListener("click", () => dxExport("json"));
  document.getElementById("dx-raw-toggle")?.addEventListener("click", () => {
    dxShowRaw();
    if (document.getElementById("dx-raw").style.display !== "none") dxSyncRaw();
  });
  // ⌘↵ / Ctrl+↵ in the raw box runs the query.
  document.getElementById("dx-raw")?.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); dxRun(true); }
  });
  // Example queries: load + run, then reset the picker so re-choosing re-runs.
  dxPopulatePresets();
  document.getElementById("dx-presets")?.addEventListener("change", (e) => {
    const i = e.target.value;
    e.target.value = "";
    if (i === "") return;
    const p = DX_PRESETS[Number(i)];
    if (p) dxApplyQuery(p.q, p.c);
  });
}
