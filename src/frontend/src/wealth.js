// MULTI/DEX — the account value, opened (task: the header figure as a control).
//
// The header's "$26,793" is the whole account marked to market and net of debt
// (getMyAccountSummary.netAccountValueUsd). Clicking it opens a compact ledger
// of how that wealth is constituted — the wallet's assets, the margin pools,
// the AMM Vault and the Insurance Fund, each row a link into its Account tab —
// with what changed since the user last looked.
//
// This module is the PURE half: no DOM, no actor, no app state. main.js
// gathers FACTS from its caches and the four pool / Earn queries and hands
// them here; this turns them into a SNAPSHOT (what is held, at what marks),
// DIFFS two snapshots exactly, and renders the ledger as an HTML string.
// Node can import it, so tests/frontend_display_integrity §S exercises the
// arithmetic directly instead of pinning it by regex.
//
// The decomposition is exact by construction: for a held asset
//   qty_now × px_now − qty_base × px_base = qty_now × (px_now − px_base)   [the market]
//                                         + (qty_now − qty_base) × px_base  [a flow]
// and the same shape for pool equity (unrealised P&L vs collateral basis),
// vault LP (value per LP vs LP moved) and insurance shares (share value vs
// shares moved). The parts sum to the headline change to the cent.
//
// The venue palette is ONE hue in four lightness steps, in the Overview's
// order (wallet, pools, vault, insurance): the app's hue tokens do not survive
// as a four-colour categorical set (accent and heather collapse under
// deuteranopia), so identity rides on order, the row swatches and the share
// labels, never on hue alone. The steps are header.css's --wealth-1..4.

const EPS = 0.005;   // half a cent: below it a delta reads "—"
const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
const esc = (s) => String(s).replace(/[<>&"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" }[c]));
const grp = (n, d) => n.toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });

// Money, the app's rounding (fmtUsd: whole dollars from $1k, cents above a
// dollar, four places below) with the sign in FRONT of the dollar sign.
export function wealthUsd(n) {
  const a = Math.abs(num(n)), s = num(n) < 0 ? "−" : "";
  if (a >= 1000) return `${s}$${grp(Math.round(a), 0)}`;
  if (a >= 1) return `${s}$${grp(a, 2)}`;
  return `${s}$${a.toFixed(4)}`;
}
// Money with cents, always — the total and the headline change.
export function wealthUsdCents(n) { return `${num(n) < 0 ? "−" : ""}$${grp(Math.abs(num(n)), 2)}`; }
// A signed change: "—" inside half a cent, cents below $1k, whole dollars above.
export function wealthDelta(n) {
  const v = num(n), a = Math.abs(v);
  if (a < EPS) return "—";
  return (v > 0 ? "+" : "−") + (a >= 1000 ? grp(Math.round(a), 0) : grp(a, 2));
}
const dcls = (n) => (Math.abs(num(n)) < EPS ? "flat" : num(n) > 0 ? "up" : "dn");
const pct = (x, d) => `${(num(x) * 100).toFixed(d)}%`;

// The venues, in the Overview's order. `go` / `goHref` are the empty row's
// invitation (a spot-only account still sees what the figure could be made of).
export const WEALTH_VENUES = [
  { k: "wallet", nm: "Wallet", href: "#account/wallet", go: "Deposit →", goHref: "#account/deposit" },
  { k: "pools", nm: "Margin pools", href: "#account/positions", go: "Trade →", goHref: "#markets" },
  { k: "vault", nm: "AMM Vault", href: "#account/earn", go: "Earn →", goHref: "#account/earn" },
  { k: "ins", nm: "Insurance Fund", href: "#account/earn", go: "Earn →", goHref: "#account/earn" },
];

// facts → snapshot. facts:
//   tokens: [{ t, qty, px, held }]           wallet balances at the market's last price; held = reserved in open orders
//   pools:  [{ id, name, label, equity, upnl, usage, hasPos }]   getMyMarginPools × getMyPositions
//   vault:  { lp, value, share, staged }     getMyVaultPosition (+ staged withdrawals)
//   ins:    { shares, value, unlockMs }      getMyInsuranceStake
//   net:    the backend's netAccountValueUsd (null until the summary lands)
// Everything is a plain number; a snapshot is JSON-safe (localStorage keeps the baseline).
export function wealthSnapshot(f, t = Date.now()) {
  const tokens = (f?.tokens || []).map((x) => ({ t: String(x.t), qty: num(x.qty), px: num(x.px), held: num(x.held) }));
  const pools = (f?.pools || []).map((p) => ({
    id: String(p.id), name: String(p.name ?? ""), label: String(p.label ?? p.name ?? ""),
    equity: num(p.equity), upnl: num(p.upnl), usage: num(p.usage), hasPos: !!p.hasPos,
  }));
  const lp = num(f?.vault?.lp), vaultUsd = num(f?.vault?.value);
  const shares = num(f?.ins?.shares), insUsd = num(f?.ins?.value);
  return {
    t,
    tokens,
    pools,
    vault: { lp, value: vaultUsd, vplp: lp > 0 ? vaultUsd / lp : 0, share: num(f?.vault?.share), staged: num(f?.vault?.staged) },
    ins: { shares, value: insUsd, sv: shares > 0 ? insUsd / shares : 0, unlockMs: num(f?.ins?.unlockMs) },
    net: f?.net == null ? null : num(f.net),
  };
}

// The four venue figures, the computed total and each venue's share of the
// positive mass (an underwater pool is a negative figure, not a negative bar).
export function wealthDerive(s) {
  const walletUsd = s.tokens.reduce((a, x) => a + x.qty * x.px, 0);
  const poolsUsd = s.pools.reduce((a, p) => a + p.equity, 0);
  const v = { wallet: walletUsd, pools: poolsUsd, vault: s.vault.value, ins: s.ins.value };
  const total = walletUsd + poolsUsd + v.vault + v.ins;
  const mass = Object.values(v).reduce((a, x) => a + Math.max(0, x), 0);
  const share = {};
  for (const k in v) share[k] = mass > 0 ? Math.max(0, v[k]) / mass : 0;
  return { v, total, share, walletUsd, poolsUsd };
}

// now − base, exactly. With no base (the first look) every delta is 0 and
// `none` is true, so the ledger reads "first look" instead of "no change".
export function wealthDiff(now, base) {
  const d = wealthDerive(now);
  const zero = { wallet: 0, pools: 0, vault: 0, ins: 0 };
  if (!base) return { d, e: null, none: true, total: 0, rows: zero, perToken: {}, perPool: {}, pxPct: {}, parts: { prices: 0, flows: 0, positions: 0, basis: 0, yield: 0, earnFlows: 0 } };
  const e = wealthDerive(base);
  const bt = Object.fromEntries(base.tokens.map((x) => [x.t, x]));
  const nt = Object.fromEntries(now.tokens.map((x) => [x.t, x]));
  const perToken = {}, pxPct = {};
  let prices = 0, flows = 0;
  for (const t of new Set([...Object.keys(nt), ...Object.keys(bt)])) {
    const n = nt[t] || { qty: 0, px: bt[t].px }, b = bt[t] || { qty: 0, px: n.px };
    const pe = n.qty * (n.px - b.px), fe = (n.qty - b.qty) * b.px;
    perToken[t] = pe + fe; prices += pe; flows += fe;
    pxPct[t] = b.px > 0 ? n.px / b.px - 1 : 0;
  }
  const bp = Object.fromEntries(base.pools.map((p) => [p.id, p]));
  const np = Object.fromEntries(now.pools.map((p) => [p.id, p]));
  const perPool = {};
  let positions = 0, basis = 0;
  for (const id of new Set([...Object.keys(np), ...Object.keys(bp)])) {
    const n = np[id] || { equity: 0, upnl: 0 }, b = bp[id] || { equity: 0, upnl: 0 };
    perPool[id] = n.equity - b.equity;
    positions += n.upnl - b.upnl;
    basis += (n.equity - n.upnl) - (b.equity - b.upnl);
  }
  const vplpBase = base.vault.lp > 0 ? base.vault.vplp : now.vault.vplp;
  const vaultYield = base.vault.lp > 0 && now.vault.lp > 0 ? now.vault.lp * (now.vault.vplp - base.vault.vplp) : 0;
  const lpFlow = (now.vault.lp - base.vault.lp) * vplpBase;
  const svBase = base.ins.shares > 0 ? base.ins.sv : now.ins.sv;
  const insYield = base.ins.shares > 0 && now.ins.shares > 0 ? now.ins.shares * (now.ins.sv - base.ins.sv) : 0;
  const insFlow = (now.ins.shares - base.ins.shares) * svBase;
  const rows = { wallet: d.walletUsd - e.walletUsd, pools: d.poolsUsd - e.poolsUsd, vault: now.vault.value - base.vault.value, ins: now.ins.value - base.ins.value };
  return {
    d, e, none: false, total: d.total - e.total, rows, perToken, perPool, pxPct,
    parts: { prices, flows, positions, basis, yield: vaultYield + insYield, earnFlows: lpFlow + insFlow },
  };
}

// The footer's sentence: what the change was made of, non-zero parts only.
export function wealthAttribution(x) {
  if (x.none) return "First look — the next open says what changed.";
  const parts = [];
  const add = (k, v) => { if (Math.abs(v) >= EPS) parts.push(`${k} <b class="${dcls(v)}">${wealthDelta(v)}</b>`); };
  const p = x.parts;
  add("Prices", p.prices);
  add("Positions", p.positions);
  add("Yield", p.yield);
  add(p.flows + p.basis > 0 ? "Deposits &amp; trades" : "Trades &amp; fees", p.flows + p.basis);
  add("Earn flows", p.earnFlows);
  return parts.length ? parts.join(" · ") : "Nothing has moved since then.";
}

// The ledger. opts: { now, base, since, fmt: { qty }, mobile, nowMs }
//   since  — the baseline's label ("since you last looked · 6 min ago")
//   fmt.qty — the app's quantity formatter (formatNum)
//   mobile — adds the sheet's full-width "Open Account" CTA
// Rows carry data-key (what they are) and data-usd (their figure) so the
// caller can flash the ones that moved between two paints.
export function wealthHtml({ now, base, since, fmt, mobile = false, nowMs = Date.now() }) {
  const qty = (n) => (fmt && fmt.qty ? fmt.qty(n) : grp(num(n), 2));
  const x = wealthDiff(now, base), d = x.d, t = x.total, moved = Math.abs(t) >= EPS;
  const total = now.net != null ? now.net : d.total;   // the backend's figure (the header's) when it has one
  const rel = moved && x.e && Math.abs(x.e.total) > 0 ? `<small>${(Math.abs(t) / Math.abs(x.e.total) * 100).toFixed(2)}%</small>` : "";
  const headline = x.none ? "first look" : moved ? `${t > 0 ? "▲ " : "▼ "}${wealthUsdCents(Math.abs(t))}` : "no change";
  const head = `<div class="wealth-head"><div><div class="wealth-label">Account value</div><div class="wealth-total${total < 0 ? " neg" : ""}">${wealthUsdCents(total)}</div></div>`
    + `<div class="wealth-change"><div class="wealth-delta ${x.none ? "flat" : dcls(t)}">${headline}${rel}</div><div class="wealth-since">${esc(since || "")}</div></div></div>`;
  const bar = `<div class="wealth-bar" aria-hidden="true">`
    + WEALTH_VENUES.map((v) => `<i data-v="${v.k}" style="--w:${d.share[v.k].toFixed(4)}" title="${v.nm} · ${pct(d.share[v.k], 0)} · ${wealthUsd(d.v[v.k])}"></i>`).join("")
    + `</div>`;
  const sw = (k) => `<i class="wealth-sw" data-v="${k}"></i>`;
  const row = (cls, key, href, lead, nm, sub, usd, dlt) =>
    `<a class="wealth-row ${cls}" data-key="${key}" data-usd="${num(usd).toFixed(2)}" href="${href}">${lead}<span class="wealth-nm">${nm}${sub ? `<small>${sub}</small>` : ""}</span>`
    + `<span class="wealth-amt">${wealthUsd(usd)}</span><span class="wealth-dl ${dcls(dlt)}">${wealthDelta(dlt)}</span></a>`;
  const empty = (v) => `<a class="wealth-row sec empty" data-key="${v.k}" data-usd="0.00" href="${v.goHref}">${sw(v.k)}<span class="wealth-nm">${v.nm}<small>nothing yet</small></span><span class="wealth-amt">—</span><span class="wealth-dl go">${v.go}</span></a>`;
  let rows = "";
  // Wallet, opened to its assets
  const held = now.tokens.filter((a) => a.qty > 0);
  if (held.length) {
    rows += row("sec", "wallet", "#account/wallet", sw("wallet"), "Wallet", pct(d.share.wallet, 0), d.walletUsd, x.rows.wallet);
    for (const a of held) {
      rows += row("sub", `asset:${a.t}`, "#account/wallet", `<img class="wealth-ico" src="/assets/${esc(a.t)}.svg" alt="" data-hide-on-error>`, esc(a.t), qty(a.qty), a.qty * a.px, x.perToken[a.t] || 0);
    }
    const inOrders = held.filter((a) => a.held > 0).map((a) => `${qty(a.held)} ${esc(a.t)}`);
    if (inOrders.length) rows += `<a class="wealth-note lnk" href="#account/spot">${inOrders.join(" · ")} resting in open orders →</a>`;
  } else rows += empty(WEALTH_VENUES[0]);
  // Margin pools, one line each with its own distance to liquidation
  if (now.pools.length) {
    rows += row("sec", "pools", "#account/positions", sw("pools"), "Margin pools", pct(d.share.pools, 0), d.poolsUsd, x.rows.pools);
    for (const p of now.pools) {
      const toLiq = Math.max(0, 1 - p.usage);
      const sub = p.hasPos ? `${pct(toLiq, 0)} to liq` : "no position";
      rows += row(`sub${p.hasPos && toLiq < 0.2 ? " risk" : ""}`, `pool:${esc(p.id)}`, "#account/positions", `<i class="wealth-sw dot"></i>`, esc(p.label || p.name), sub, p.equity, x.perPool[p.id] || 0);
    }
  } else rows += empty(WEALTH_VENUES[1]);
  // AMM Vault
  if (now.vault.lp > 0) {
    rows += row("sec", "vault", "#account/earn", sw("vault"), "AMM Vault", pct(d.share.vault, 0), now.vault.value, x.rows.vault);
    rows += `<span class="wealth-note">${qty(now.vault.lp)} LP · ${pct(now.vault.share, 2)} of the vault${now.vault.staged > 0 ? ` · <em>withdrawal of ${qty(now.vault.staged)} LP staged</em>` : ""}</span>`;
  } else rows += empty(WEALTH_VENUES[2]);
  // Insurance Fund
  if (now.ins.shares > 0) {
    rows += row("sec", "ins", "#account/earn", sw("ins"), "Insurance Fund", pct(d.share.ins, 0), now.ins.value, x.rows.ins);
    const unlock = now.ins.unlockMs > nowMs ? ` · unstake opens ${new Date(now.ins.unlockMs).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}` : "";
    rows += `<span class="wealth-note">${qty(now.ins.shares)} shares${unlock}</span>`;
  } else rows += empty(WEALTH_VENUES[3]);
  const foot = `<div class="wealth-foot"><span class="wealth-attr">${wealthAttribution(x)}</span><a href="#account/overview">Overview →</a></div>`
    + (mobile ? `<a class="wealth-cta" href="#account/overview">Open Account</a>` : "");
  return head + bar + `<div class="wealth-rows">${rows}</div>` + foot;
}
