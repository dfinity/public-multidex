import { appState } from "./state.js";
import { oqlRowsToObjects, oqlFormatCell } from "./oql.js";
import { toE8 } from "./money.js";

// `markets` is injected (it doubles as a route string in main.js, so it wasn't
// moved to appState); set by setupAssistant(deps).
let _getMarkets = () => [];
let _ensureActor = null;   // injected by main.js — rebuilds appState.actor after a failed session restore
let _refreshAccount = null; // injected by main.js — refreshes the Account view after a confirmed action
                            // (#46.2 §3: the old bare `refreshAccountData` was not in this module's
                            // scope, so `typeof` resolved "undefined" and the refresh never ran)

// ── In-app AI Assistant (Open HR pattern) ──────────────────────────
// A chat that turns natural language into OQL reads (answered with live data)
// and into proposed ACTIONS (mutations). The agent loop runs client-side: it
// builds a prompt from the cached OQL schema + an action catalog + the running
// transcript, calls the backend aiComplete() proxy, and parses a strict
// one-JSON-object protocol. Reads run via execute() and feed back to the model;
// every state-changing action is shown as a CONFIRM CARD and only executed when
// the user clicks Confirm. The same backend surface (schema/execute + the shared
// methods) is what Claude Desktop drives via the IC Connector.
let _oqlSchema = null;     // cached schema() text (stable between deploys)
let _asstTurns = [];       // running transcript: {role:"user"|"assistant"|"tool", text}
let _asstBusy = false;
let _asstSeeded = false;
// The intermediate tool outputs of the CURRENT turn — the "workings" (query
// result tables, the account snapshot, price-history candles, and any tool
// errors the agent recovered from). Collected here instead of dumped into the
// chat, then offered behind a "Show workings" link under the answer. Reassigned
// (never mutated) at each turn start, so a link's captured buffer stays intact.
let _asstWorkings = [];
const ASSIST_MAX_STEPS = 6; // agent-loop guard (reads + one final reply/action)
// Feed-back bounds (public issue #46.1). The transcript is resent on EVERY
// agent step, and the backend's aiComplete guard refuses prompts over
// AI_MAX_PROMPT_BYTES (32,768 — GHSA-c6g7), so ONE oversized OQL read used to
// wedge the assistant for the rest of the page load: every later prompt
// carried the giant tool turn and was refused. Rows fed back to the model are
// capped like the candles tool's 48 (plus a character clamp for wide rows —
// the full rows still reach the user via the Workings dialog), and
// assistantFullPrompt trims what it sends so the rebuilt prompt always fits.
const ASSIST_MAX_RESULT_ROWS = 48;      // mirrors the candles feed-back cap
const ASSIST_MAX_RESULT_CHARS = 16000;  // one tool turn's serialisation clamp
const ASSIST_PROMPT_BUDGET = 30000;     // UTF-8 BYTES — < backend AI_MAX_PROMPT_BYTES (32768)

// BigInt-safe JSON (Candid Nats decode to BigInt).
function asstJson(x) { return JSON.stringify(x, (_k, v) => (typeof v === "bigint" ? Number(v) : v)); }
// Side parsing FAILS CLOSED (GHSA-6qpg item 2): anything that is not exactly
// "buy"/"sell" (case/whitespace-insensitive) returns null and the action is
// refused BEFORE a confirm card exists — the old fail-open form encoded
// side:"short" as a buy while the card's summary showed the raw token, so the
// user confirmed SHORT and submitted a buy. Exported for the behavioural
// battery in tests/frontend_security.test.mjs.
export function asstSide(s) {
  const t = String(s).trim().toLowerCase();
  if (t === "sell") return { sell: null };
  if (t === "buy") return { buy: null };
  return null;
}
// Confirm-card labels derive from the RESOLVED variant, never the raw token,
// so what the card says and what run() submits cannot diverge.
function asstSideLabel(s, buyWord, sellWord) {
  const v = asstSide(s);
  return v === null ? "INVALID SIDE" : ("sell" in v ? sellWord : buyWord);
}
function asstOptE8(x) { return (x === null || x === undefined || x === "") ? [] : [toE8(x)]; }

// Describe a successful action's PAYLOAD instead of collapsing every record
// to the two chars "OK" (#46.2 §1): a STAGED swap and a fill-nothing market
// order used to both print "→ OK", telling neither the user nor the model
// what actually happened. Staged detection mirrors the manual paths (main.js
// swap/place-order handlers): sealed-until-GEPTOR means a swap that "filled
// nothing" but carries a staged order id, or a market order with totalFilled
// 0, is a NORMAL staged outcome that clears at the next price update — not a
// silent no-op. Values arrive wrapActor-normalized (human units, not e8).
// Exported for the behavioural battery in tests/frontend_display_integrity.test.mjs.
export function asstActionOutcome(method, ok) {
  if (ok === null || ok === undefined) return "OK";
  if (typeof ok === "bigint" || typeof ok === "number") return "OK (#" + Number(ok) + ")";
  if (method === "swap") {
    const staged = Number(ok.fromAmount) < 0.0000001 && (ok.swapOrderId || []).length > 0;
    if (staged) return "OK — swap STAGED as order #" + Number(ok.swapOrderId[0]) + "; clears at the next price update (~1s)";
    return "OK — swapped " + Number(ok.fromAmount) + " for " + Number(ok.toAmount)
      + (ok.fullyFilled ? "" : " (partial fill)");
  }
  if (method === "placeMarketOrder") {
    const filled = Number(ok.totalFilled);
    if (filled > 0) return "OK — filled " + filled + " @ avg " + Number(ok.avgPrice);
    return "OK — order STAGED; clears at the next price update (~1s)";
  }
  if (method === "placeLimitOrder" && ok.order) {
    return "OK — order #" + Number(ok.order.id) + " STAGED; matches or rests at the next price update (~1s)";
  }
  // Any other record-valued ok: show the payload rather than swallowing it.
  return "OK " + asstJson(ok);
}

// Posture gate for the action catalog (#46.2, optional half): the `deposit`
// entry is the dev faucet (addTestTokens), which the backend traps on outside
// #dev (W6-02) — so don't OFFER it in the prompt on #play/#production, and
// refuse a proposal for it with a message the model can act on.
function asstActionAvailable(name) {
  if (name === "deposit") return appState.deployMode === "dev";
  return true;
}

// Action catalog — the ONLY mutations the assistant may propose. Each runs the
// real shared method; every one is gated behind a confirm card. Adding swap /
// deposit / withdraw later is one more entry here (+ the IDL already has them).
const ASSISTANT_ACTIONS = {
  placeMarketOrder: {
    sig: 'placeMarketOrder(marketId:text, side:"buy"|"sell", quantity:float, maxSlippage:float 0.01-0.25, noPartialFill:bool)',
    summary: (a) => `Spot MARKET ${asstSideLabel(a.side, "BUY", "SELL")} ${a.quantity} on ${a.marketId} · max slippage ${(Number(a.maxSlippage) * 100).toFixed(1)}%`,
    run: (a) => appState.actor.placeMarketOrder(a.marketId, asstSide(a.side), toE8(a.quantity), toE8(a.maxSlippage), !!a.noPartialFill),
  },
  placeLimitOrder: {
    sig: 'placeLimitOrder(marketId:text, side:"buy"|"sell", price:float, quantity:float)',
    summary: (a) => `Spot LIMIT ${asstSideLabel(a.side, "BUY", "SELL")} ${a.quantity} on ${a.marketId} @ ${a.price}`,
    run: (a) => appState.actor.placeLimitOrder(a.marketId, asstSide(a.side), toE8(a.price), toE8(a.quantity)),
  },
  cancelMyOrder: {
    sig: "cancelMyOrder(orderId:nat)",
    summary: (a) => `Cancel order #${a.orderId}`,
    run: (a) => appState.actor.cancelMyOrder(BigInt(a.orderId)),
  },
  createMarginPool: {
    sig: "createMarginPool(name:text, isolated:bool)",
    summary: (a) => `Create ${a.isolated ? "isolated" : "cross"} margin pool "${a.name}"`,
    run: (a) => appState.actor.createMarginPool(String(a.name), !!a.isolated),
  },
  fundMarginPool: {
    sig: "fundMarginPool(poolId:nat, amount:float ICPUSD)",
    summary: (a) => `Fund margin pool #${a.poolId} with ${a.amount} ICPUSD`,
    run: (a) => appState.actor.fundMarginPool(BigInt(a.poolId), toE8(a.amount)),
  },
  withdrawMarginPool: {
    sig: "withdrawMarginPool(poolId:nat, amount:float ICPUSD)",
    summary: (a) => `Withdraw ${a.amount} ICPUSD from margin pool #${a.poolId}`,
    run: (a) => appState.actor.withdrawMarginPool(BigInt(a.poolId), toE8(a.amount)),
  },
  openPosition: {
    sig: 'openPosition(poolId:nat, marketId:text, side:"buy"=long|"sell"=short, size:float base units, maxSlippage:float 0.01-0.25, limitPrice:float|null)',
    summary: (a) => `OPEN ${asstSideLabel(a.side, "LONG", "SHORT")} ${a.size} on ${a.marketId} in pool #${a.poolId}${a.limitPrice ? ` (limit ${a.limitPrice})` : ""}`,
    run: (a) => appState.actor.openPosition(BigInt(a.poolId), a.marketId, asstSide(a.side), toE8(a.size), toE8(a.maxSlippage), asstOptE8(a.limitPrice)),
  },
  closePosition: {
    sig: "closePosition(poolId:nat, marketId:text, maxSlippage:float 0.01-0.25, limitPrice:float|null)",
    summary: (a) => `CLOSE position on ${a.marketId} in pool #${a.poolId}`,
    run: (a) => appState.actor.closePosition(BigInt(a.poolId), a.marketId, toE8(a.maxSlippage), asstOptE8(a.limitPrice)),
  },
  swap: {
    sig: 'swap(fromToken:text, toToken:text, amount:float, maxSlippage:float 0.01-0.25, noPartialFill:bool)',
    summary: (a) => `SWAP ${a.amount} ${a.fromToken} → ${a.toToken} · max slippage ${(Number(a.maxSlippage) * 100).toFixed(1)}%`,
    run: (a) => appState.actor.swap({
      fromToken: String(a.fromToken), toToken: String(a.toToken), amount: toE8(a.amount),
      mode: { marketOrder: { maxSlippage: toE8(a.maxSlippage) } }, noPartialFill: !!a.noPartialFill,
    }),
  },
  deposit: {
    // Dev faucet — mints test tokens into the user's wallet. (On mainnet a
    // deposit is an ICRC ledger transfer in; this faucet is the sim stand-in.)
    sig: "deposit(token:text, amount:float)  [dev faucet]",
    summary: (a) => `Deposit (faucet) ${a.amount} ${a.token}`,
    run: (a) => appState.actor.addTestTokens(String(a.token), toE8(a.amount)).then(() => ({ ok: null })),
  },
  withdraw: {
    sig: "withdraw(token:text, amount:float, destination:text — account/principal)",
    summary: (a) => `WITHDRAW ${a.amount} ${a.token} → ${a.destination}`,
    run: (a) => appState.actor.withdraw(String(a.token), toE8(a.amount), String(a.destination)),
  },
};

function assistantSystemPrompt(schemaText) {
  const mkts = (_getMarkets() || []).map((m) => m.id).join(", ");
  const actionLines = Object.entries(ASSISTANT_ACTIONS)
    .filter(([name]) => asstActionAvailable(name))
    .map(([, v]) => "  - " + v.sig).join("\n");
  return `You are the MULTI/DEX trading assistant, embedded in a decentralized exchange on the Internet Computer. You help the signed-in user understand the exchange and, ONLY with their explicit confirmation, take actions.

Signed-in user principal: ${appState.myPrincipalText || "(unknown)"}
Available markets: ${mkts || "(loading)"}

TOOLS
1) OQL QUERY (read-only). Run a JSON query over TWO canisters — the EXCHANGE (live state: pools, positions, orders, markets, events, balances) and the HISTORY canister (the user's permanent archived events: fills, deposits, closed orders, liquidations…). Pick which with the "canister" field (default "exchange"). Schema for both (entities/fields/edges):
${schemaText}
   Query: {"start":"<entity>","where":<pred>,"orderBy":[{"field":"f","dir":"asc|desc"}],"limit":N,"select":["f",...]}
   Predicates: {"eq|ne|lt|le|gt|ge":{"field":"f","value":v}} | {"in":{"field":"f","value":[...]}} | {"contains|icontains|startsWith|endsWith":{"field":"f","value":"t"}} | {"and|or":[...]} | {"not":...}
   SELF-SCOPED entities (pool, position, balance, closedOrder — marked in the schema — and everything on the history canister) return ONLY the signed-in user's rows automatically. Query them BARE: the user's positions = {"start":"position"} with no owner filter. Never filter by owner/ownerName.
   Edges: traverse a dotted path in select/orderBy/where, e.g. select "marketId.lastPrice" on a position to pull the market's live price alongside it.
2) ACCOUNT SNAPSHOT (read-only). {"type":"account"} returns the signed-in user's FULL account value breakdown in HUMAN USD (already scaled — do NOT divide): accountValueUsd (the total), walletUsd (free wallet net of debt), positionsUnrealizedPnlUsd, poolsUsd (margin-pool collateral, uPnL excluded), ammVaultUsd, insuranceUsd, plus openPositions/pools counts. USE THIS for any "account value / net worth / how much do I have" question — the OQL \`balance\` entity is ONLY the free wallet and misses pools, the AMM vault, and insurance.
3) PRICE HISTORY (read-only). {"type":"candles","marketId":"<id>","intervalMs":<ms>,"page":<n>} returns OHLC candles for a market — fields t (UTC time), o,h,l,c (prices, ALREADY human units), v (volume; 0 = no trades that bucket, price tracked the oracle). intervalMs must be one of 60000 (1m), 300000 (5m), 900000 (15m), 3600000 (1h), 14400000 (4h), 86400000 (1D), 604800000 (1W). page 0 = the most recent ~48 candles; page+1 goes further back. USE THIS for ANY past-price question ("price 12 hours ago", "yesterday's high") — pick the interval that covers the window (12h ago → 1h candles) and read the row nearest the target time. NEVER try to dig prices out of the event log.
4) ACTIONS (state-changing). Propose ONE of these; it ALWAYS requires user confirmation before running — never assume it's confirmed:
${actionLines}

UNITS — READ CAREFULLY
- DEFAULT: a money/price/quantity/*Usd value in query results is a FIXED-POINT INTEGER scaled by 10^8 (e8) — divide by 100,000,000 before showing a human number: 3604200000000 ICPUSD = $36,042.00; 100000000 BTC = 1 BTC. That covers order.price/quantity/filled, closedOrder.price/quantity/filled, position.entryPrice, position.realizedPnl, balance.amount and the leaderboard's profitUsd/capitalUsd/equityUsd. returnBps is basis points (divide by 100 for %). ts/*At fields are NANOSECONDS since epoch.
- EXCEPTIONS — the backend converts these before projecting them, so they arrive ALREADY IN HUMAN UNITS and dividing them is an eight-orders-of-magnitude error: position.size (its own row's entryPrice is NOT — a single position carries both scales), market.lastPrice and market.refPrice, and on the HISTORY canister every userEvent money field (amount, price, qty). The account snapshot (TOOL 2) and candles (TOOL 3) are human units too, as stated there.
- Action args are the OPPOSITE: plain floats (price 65000.5, quantity 0.25), never e8.
- Format numbers in replies like the venue's order book: thousands separators; 2 decimals for values ≥ 1000; at most 5 significant digits otherwise; strip trailing zeros (write $1,775 not $1774.999999999; 0.1 ETH not 0.10000000).

VENUE SEMANTICS (how this exchange actually works — ground explanations in these):
- Matching is sealed/staged: every new order (market or limit) first STAGES for a short delay (~0.5–2s) and only then matches or rests in the book. A just-placed order with no fills yet is NORMAL — explain the staging delay and re-query a moment later rather than calling it failed.
- Margin liquidations trigger off the external multi-source oracle price (the market's \`refPrice\`), NOT the local order-book price — pushing the local book around cannot by itself liquidate anyone.
- Trading fees are maker/taker on the quote leg of each fill, set by the user's earned 30-day activity level: 5.0 maker / 10.0 taker bps at L0, improving to 0 / 6.0 bps at L4. The user's live level and exact rates are on the Account → Status tab.${appState.deployMode === "play" ? `
- PLAY MODE: all balances are play money at real market prices. Funds come ONLY from the Deposit page (unlocked by a quick Google verification), capped at $100,000 lifetime per player.` : ""}

ANALYSIS YOU CAN DO (estimate from data — do NOT decline for "lack of data"):
- "Who is top of the leaderboard?" → query the PUBLIC \`leaderboard\` entity (rank 1 = top; profit = equity − HODL baseline, so holders score $0). NEVER rank users by wallet balances — balances are scoped to the caller and are not the competition ranking.
- The \`order\` entity IS the live order book (open + partially-filled resting orders, including the AMM's own quotes). You can gauge depth and estimate the approximate slippage of a market order by querying the relevant side sorted by price and walking it: a BUY consumes the lowest-priced \`sell\` orders (asks, orderBy price asc); a SELL hits the highest-priced \`buy\` orders (bids, orderBy price desc). Select \`price\`, \`quantity\` AND \`filled\`: a row's RESTING size is \`quantity - filled\` (a partially-filled row keeps its placed \`quantity\`, so \`quantity\` alone overstates depth). Accumulate (quantity - filled)×price across rows until the order's notional (e.g. $1000) is filled, take the volume-weighted average fill price, and compare it to the best (first) price — that deviation is the approximate slippage.
- The \`market\` entity gives \`lastPrice\` and the AMM \`refPrice\` (mid) per pair; use refPrice as fair value.
- It's fine to caveat ("rough; ignores AMM re-quoting between fills and fees") — but give the number. Always attempt the calculation rather than saying the data is unavailable.

PROTOCOL — reply with EXACTLY ONE JSON object, no prose, no markdown fences. One of:
  {"type":"query","canister":"exchange"|"history","oql":<query object>}  run a read on that canister (default "exchange"); you get the rows back, then continue.
  {"type":"account"}                                the signed-in user's full account-value breakdown (see TOOLS 2).
  {"type":"candles","marketId":"<id>","intervalMs":<ms>,"page":<n>}  OHLC price history (see TOOLS 3).
  {"type":"action","method":"<name>","args":{...}}  propose one action for the user to confirm.
  {"type":"reply","text":"<answer>"}                your final answer to the user.

RULES
- Query real data before answering; never invent numbers, ids, or prices.
- Field and edge names differ per entity — copy them EXACTLY from that entity's schema line above (one entity may link via "marketId" while another links via "market"; never carry a name across entities). If a query errors, CHANGE the query — don't resend it unchanged.
- Before any action, make sure you have exact args (query first if unsure, e.g. to find a poolId). Propose only one action at a time.
- ids are integers; quantities/prices are plain floats; slippage is a fraction (0.05 = 5%, allowed 0.01-0.25).
- Be concise and factual.`;
}

function assistantFullPrompt(schemaText) {
  const sys = assistantSystemPrompt(schemaText);
  const render = (turns) => sys + "\n\n=== CONVERSATION ===\n"
    + turns.map((t) => t.role.toUpperCase() + ": " + t.text).join("\n\n")
    + "\n\nASSISTANT (one JSON object only):";
  let turns = _asstTurns.slice();
  let prompt = render(turns);
  // Keep the rebuilt prompt under the backend's aiComplete size guard
  // (AI_MAX_PROMPT_BYTES, GHSA-c6g7): an oversized transcript trips it on
  // every later call, wedging the pane until reload (#46.1). Trim per call —
  // elide the OLDEST tool feed-backs (the bulk) first, then drop the oldest
  // turns outright, always keeping the newest turn. _asstTurns itself stays
  // intact, so the chat and the Workings keep the full history.
  const ELIDED = "(older tool output elided to fit the prompt — re-run the query if needed)";
  // Measure what the wire sees: the backend guard counts UTF-8 BYTES
  // (Text.encodeUtf8), not UTF-16 code units — a CJK/emoji-heavy transcript
  // sits under 30,000 units yet serialises past 32,768 bytes and gets a hard
  // "Prompt too long" instead of the silent eliding this loop exists for.
  // Transcripts are small, so a straight re-encode per iteration is fine.
  const utf8Bytes = (s) => new TextEncoder().encode(s).length;
  while (utf8Bytes(prompt) > ASSIST_PROMPT_BUDGET) {
    const i = turns.findIndex((t) => t.role === "tool" && t.text.length > ELIDED.length);
    if (i >= 0) turns[i] = { role: "tool", text: ELIDED };
    else if (turns.length > 1) turns = turns.slice(1);
    else break;   // a single enormous turn — nothing left to trim client-side
    prompt = render(turns);
  }
  return prompt;
}

// Extract the first JSON object from the model's text (tolerates ``` fences / prose).
function assistantParse(raw) {
  if (!raw) return null;
  let s = String(raw).trim();
  const fence = s.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (fence) s = fence[1].trim();
  const start = s.indexOf("{");
  const end = s.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try { return JSON.parse(s.slice(start, end + 1)); } catch (_) {}
  try { return JSON.parse(s); } catch (_) {}
  return null;
}


// ── UI helpers ──
function asstEl() { return document.getElementById("asst-messages"); }
// Render the SAFE markdown subset the model actually emits — bold, italic,
// inline code, http(s) links, headings (flattened to bold), dashed bullets,
// line breaks. LLM output is never trusted as HTML: escape EVERYTHING first,
// then apply formatting on the escaped text.
function asstMarkdown(text) {
  let s = String(text)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  s = s.replace(/`([^`\n]+)`/g, "<code>$1</code>");
  s = s.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/(^|[\s(])\*([^*\n]+)\*(?=[\s).,;:!?]|$)/g, "$1<em>$2</em>");
  s = s.replace(/\[([^\]\n]+)\]\((https?:\/\/[^)\s"]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
  s = s.replace(/^#{1,4}\s+(.+)$/gm, "<strong>$1</strong>");
  s = s.replace(/^\s*[-*]\s+/gm, "• ");
  return s.replace(/\n/g, "<br>");
}

function assistantAddMsg(role, text) {
  const list = asstEl(); if (!list) return;
  const d = document.createElement("div");
  d.className = "asst-msg asst-" + role;
  // Assistant messages render the markdown subset; the user's own text (and
  // anything else) stays literal.
  if (role === "assistant") d.innerHTML = asstMarkdown(text);
  else d.textContent = text;
  list.appendChild(d); list.scrollTop = list.scrollHeight;
}
function assistantAddNote(text) {
  const list = asstEl(); if (!list) return;
  const d = document.createElement("div");
  d.className = "asst-note"; d.textContent = text;
  list.appendChild(d); list.scrollTop = list.scrollHeight;
}

// Errors render as ONE friendly line + a "Show details" link; the raw trace
// (replica rejections run to pages) only appears in a scrollable dialog on
// demand. The full text still goes back to the model so it can self-correct.
function asstErrSummary(raw) {
  const s = String(raw);
  const m = s.match(/Reject text: ([^\n]+)/) || s.match(/trap[^']*'([^']+)'/) || null;
  let t = (m ? m[1] : s.split("\n")[0]).trim();
  if (t.length > 160) t = t.slice(0, 157) + "…";
  return t;
}

function asstShowErrorDialog(details) {
  let ov = document.getElementById("asst-err-overlay");
  if (!ov) {
    ov = document.createElement("div");
    ov.id = "asst-err-overlay"; ov.className = "asst-err-overlay";
    ov.innerHTML = `<div class="asst-err-dialog" role="dialog" aria-modal="true" aria-label="Error details">
        <div class="asst-err-head"><span>Error details</span>
          <button class="asst-err-copy" type="button">Copy</button>
          <button class="asst-err-close" type="button" aria-label="Close">✕</button></div>
        <pre class="asst-err-body"></pre></div>`;
    ov.addEventListener("click", (e) => { if (e.target === ov) ov.style.display = "none"; });
    ov.querySelector(".asst-err-close").addEventListener("click", () => { ov.style.display = "none"; });
    ov.querySelector(".asst-err-copy").addEventListener("click", async () => {
      const b = ov.querySelector(".asst-err-copy");
      try { await navigator.clipboard.writeText(ov.querySelector(".asst-err-body").textContent); b.textContent = "Copied"; setTimeout(() => (b.textContent = "Copy"), 1200); } catch (_) {}
    });
    document.addEventListener("keydown", (e) => { if (e.key === "Escape" && ov.style.display !== "none") ov.style.display = "none"; });
    document.body.appendChild(ov);
  }
  ov.querySelector(".asst-err-body").textContent = details;
  ov.style.display = "flex";
}

function assistantAddErrorNote(headline, details) {
  const list = asstEl(); if (!list) return;
  const d = document.createElement("div");
  d.className = "asst-note asst-err-note";
  d.textContent = "⚠ " + headline + " ";
  const a = document.createElement("a");
  a.href = "#"; a.className = "asst-err-more"; a.textContent = "Show details";
  a.addEventListener("click", (e) => { e.preventDefault(); asstShowErrorDialog(details); });
  d.appendChild(a);
  list.appendChild(d); list.scrollTop = list.scrollHeight;
}
// A row-object array → the same compact HTML table the chat used to show
// inline. Now it feeds the Workings dialog (see asstShowWorkingsDialog); the
// cell HTML from oqlFormatCell is already escaped.
function assistantTableMarkup(objs) {
  if (!objs || !objs.length) return "";
  const cols = Object.keys(objs[0]);
  const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const head = cols.map((c) => `<th>${esc(c)}</th>`).join("");
  const body = objs.slice(0, 20).map((o) => "<tr>" + cols.map((c) => {
    const f = oqlFormatCell(c, o[c]);   // {html,title} — html is already escaped
    return `<td${f.title ? ` title="${esc(f.title)}"` : ""}>${f.html}</td>`;
  }).join("") + "</tr>").join("");
  return `<table class="asst-table"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`
    + (objs.length > 20 ? `<div class="asst-note">…${objs.length - 20} more rows</div>` : "");
}

// Record a step's output as a "working" for THIS turn instead of showing it
// inline. Tables (query/account/candles results) and recovered tool errors
// both land here; the answer then carries a "Show workings" link.
function assistantRecordWorking(label, objs) {
  if (!objs || !objs.length) return;
  _asstWorkings.push({ kind: "table", label, objs });
}
function assistantRecordWorkingError(label, details) {
  _asstWorkings.push({ kind: "error", label, details });
}

// Modal listing this turn's workings, one labelled step at a time. Mirrors the
// error dialog's shell/backdrop/Escape handling; built once and reused.
function asstShowWorkingsDialog(workings) {
  let ov = document.getElementById("asst-workings-overlay");
  if (!ov) {
    ov = document.createElement("div");
    ov.id = "asst-workings-overlay"; ov.className = "asst-err-overlay";
    ov.innerHTML = `<div class="asst-err-dialog asst-workings-dialog" role="dialog" aria-modal="true" aria-label="Workings">
        <div class="asst-err-head"><span>Workings</span>
          <button class="asst-workings-close" type="button" aria-label="Close">✕</button></div>
        <div class="asst-workings-body"></div></div>`;
    ov.addEventListener("click", (e) => { if (e.target === ov) ov.style.display = "none"; });
    ov.querySelector(".asst-workings-close").addEventListener("click", () => { ov.style.display = "none"; });
    document.addEventListener("keydown", (e) => { if (e.key === "Escape" && ov.style.display !== "none") ov.style.display = "none"; });
    document.body.appendChild(ov);
  }
  const body = ov.querySelector(".asst-workings-body");
  body.innerHTML = "";
  workings.forEach((w, i) => {
    const step = document.createElement("div");
    step.className = "asst-workings-step";
    const lab = document.createElement("div");
    lab.className = "asst-workings-label";
    lab.textContent = `${i + 1}. ${w.label}`;   // labels are our own strings, but textContent keeps it safe
    step.appendChild(lab);
    if (w.kind === "table") {
      const wrap = document.createElement("div");
      wrap.className = "asst-table-wrap";
      wrap.innerHTML = assistantTableMarkup(w.objs);
      step.appendChild(wrap);
    } else {
      const pre = document.createElement("pre");
      pre.className = "asst-workings-err";
      pre.textContent = w.details;
      step.appendChild(pre);
    }
    body.appendChild(step);
  });
  ov.style.display = "flex";
}

// The affordance under an answer: "Show workings (N steps)". `workings` is the
// turn's buffer captured by value, so it survives the next turn's reset.
function assistantAddWorkingsLink(workings) {
  const list = asstEl(); if (!list || !workings.length) return;
  const d = document.createElement("div");
  d.className = "asst-note asst-workings-note";
  const a = document.createElement("a");
  a.href = "#"; a.className = "asst-err-more asst-workings-more";
  const n = workings.length;
  a.textContent = `Show workings (${n} step${n === 1 ? "" : "s"})`;
  a.addEventListener("click", (e) => { e.preventDefault(); asstShowWorkingsDialog(workings); });
  d.appendChild(a);
  list.appendChild(d); list.scrollTop = list.scrollHeight;
}
function assistantSetThinking(on) {
  // visibility keeps the line's layout space when hidden — a display toggle
  // shrinks the flex-sized message list and clips the last bubble.
  const t = document.getElementById("asst-thinking");
  if (t) t.style.visibility = on ? "visible" : "hidden";
  const send = document.getElementById("asst-send");
  if (send) send.disabled = on;
}

// Confirm card — resolves true (Confirm) / false (Cancel). This is the gate the
// product requires before any consequential action runs.
function assistantConfirm(method, args, summary) {
  return new Promise((resolve) => {
    const list = asstEl();
    const card = document.createElement("div");
    card.className = "asst-confirm";
    card.innerHTML = `<div class="asst-confirm-title">Confirm action</div>
      <div class="asst-confirm-summary"></div>
      <pre class="asst-confirm-args"></pre>
      <div class="asst-confirm-btns"><button class="asst-btn-cancel">Cancel</button><button class="asst-btn-confirm">Confirm</button></div>`;
    card.querySelector(".asst-confirm-summary").textContent = summary;
    card.querySelector(".asst-confirm-args").textContent = method + "(" + asstJson(args || {}) + ")";
    const done = (v) => {
      card.querySelectorAll("button").forEach((b) => (b.disabled = true));
      card.classList.add(v ? "asst-confirmed" : "asst-cancelled");
      resolve(v);
    };
    card.querySelector(".asst-btn-confirm").onclick = () => done(true);
    card.querySelector(".asst-btn-cancel").onclick = () => done(false);
    if (list) { list.appendChild(card); list.scrollTop = list.scrollHeight; }
  });
}

// Render an OQL schema() JSON document as a compact one-line-per-entity form,
// e.g. "pool(id:Nat, owner, ownerName, mode[isolated|cross], createdAt:Int)".
// Far smaller than the raw JSON (which we resend on EVERY agent step), while
// keeping what the model needs to write queries: field names, non-Text types,
// domain values, and edge targets. Falls back to the raw text if parsing fails.
function oqlSchemaCompact(jsonText) {
  try {
    const doc = JSON.parse(jsonText);
    return (doc.entities || []).map((e) => {
      const fields = (e.fields || []).map((f) => {
        let s = f.name;
        if (f.typeName && f.typeName !== "Text") s += ":" + f.typeName;
        if (Array.isArray(f.values) && f.values.length) s += "[" + f.values.join("|") + "]";
        if (f.role && typeof f.role === "object" && f.role.edge) s += "→" + f.role.edge.to;
        return s;
      }).join(", ");
      // An owner-role field marks a SELF-SCOPED entity: the backend already
      // filters rows to the caller. Say so in the schema line the model reads,
      // or it invents owner filters (which are redundant at best).
      const scoped = (e.fields || []).some((f) => f.role === "owner");
      return e.name + "(" + fields + ")" + (scoped ? "  ← SELF-SCOPED: returns only YOUR rows; query bare, never filter by owner" : "");
    }).join("\n");
  } catch (_) { return jsonText; }
}

async function assistantRun() {
  if (_asstBusy) return;
  _asstBusy = true; assistantSetThinking(true);
  _asstWorkings = [];   // fresh buffer for this turn (reassign, don't mutate — prior links keep theirs)
  try {
    if (!_oqlSchema) {
      const a = appState.actor || appState.publicActor;
      let exch = "(unavailable)", hist = "(unavailable)";
      try { exch = oqlSchemaCompact(await a.schema([])); } catch (_) {}
      try { hist = oqlSchemaCompact(await a.archiveSchema()); } catch (_) {}
      // Compact schemas — this prompt is re-sent on every agent step, so keeping
      // it small reduces per-call latency (and the chance of an LLM-outcall timeout).
      _oqlSchema = "EXCHANGE canister (live state — query with \"canister\":\"exchange\"):\n" + exch
        + "\n\nHISTORY canister (query with \"canister\":\"history\") — the signed-in user's own archived events (all kinds) PLUS every user's deposits & withdrawals (a public money-flow ledger; other users' trades/positions are NOT visible):\n" + hist;
    }
    for (let step = 0; step < ASSIST_MAX_STEPS; step++) {
      const prompt = assistantFullPrompt(_oqlSchema);
      // The LLM HTTPS outcall can time out transiently (slow Gemini response on
      // the non-replicated sim outcall). Retry once before surfacing the error;
      // genuine errors (bad key, quota, parse) fall through immediately.
      let r = null;
      for (let attempt = 0; attempt < 2; attempt++) {
        try { r = await appState.actor.aiComplete(prompt); }
        catch (e) { r = { err: "outcall: " + (e.message || String(e)) }; }
        if (!("err" in r) || !/timeout|outcall|http 5|http 429|deadline/i.test(r.err)) break;
        if (attempt === 0) assistantAddNote("⟳ LLM call timed out — retrying once…");
      }
      if (!r) { assistantAddMsg("assistant", "⚠ AI call failed"); break; }
      if ("err" in r) {
        // Short errors (rate limit, not configured) read fine inline; long
        // ones (HTTP bodies, outcall traces) go behind the details dialog.
        if (r.err.length > 180) {
          assistantAddErrorNote("The AI call failed (" + asstErrSummary(r.err) + ").", r.err);
        } else {
          assistantAddMsg("assistant", "⚠ " + r.err);
        }
        break;
      }
      const obj = assistantParse(r.ok);
      if (!obj || !obj.type) { assistantAddMsg("assistant", r.ok); _asstTurns.push({ role: "assistant", text: r.ok }); break; }

      if (obj.type === "reply") {
        assistantAddMsg("assistant", obj.text || "");
        _asstTurns.push({ role: "assistant", text: obj.text || "" });
        break;
      }
      if (obj.type === "query") {
        const oql = asstJson(obj.oql);
        const qcan = obj.canister === "history" ? "history" : "exchange";
        // The raw OQL is deliberately NOT echoed into the chat (it read as
        // noise before every answer); it still lives in _asstTurns for the
        // model, and failures surface it via the error note's details dialog.
        let resultText;
        try {
          const a = appState.actor || appState.publicActor;
          const res = qcan === "history" ? await a.archiveExecute(oql) : await a.execute(oql);
          const objs = oqlRowsToObjects(res);
          assistantRecordWorking("Query" + (obj.oql && obj.oql.start ? " · " + obj.oql.start : "") + " (" + qcan + ")", objs);
          // History: tell the model when segments were unreachable, so it
          // qualifies its answer instead of presenting a partial read as
          // complete history (W1-03).
          const degradedNote = res.degraded && res.degraded.length
            ? " (WARNING: " + res.degraded.length + " archive segment(s) unreachable — rows may be incomplete)"
            : "";
          // Cap what feeds back to the model (#46.1) the way the candles tool
          // does: first N rows, halved further while wide rows keep the
          // serialisation over the character clamp (never below one row). The
          // note tells the model to narrow the query instead of paging blind.
          let fed = objs.slice(0, ASSIST_MAX_RESULT_ROWS);
          let body = asstJson(fed);
          while (fed.length > 1 && body.length > ASSIST_MAX_RESULT_CHARS) {
            fed = fed.slice(0, Math.ceil(fed.length / 2));
            body = asstJson(fed);
          }
          if (body.length > ASSIST_MAX_RESULT_CHARS) {
            body = body.slice(0, ASSIST_MAX_RESULT_CHARS) + "…(row truncated)";
          }
          const capNote = fed.length < objs.length
            ? " (first " + fed.length + " of " + objs.length + " rows — narrow the query with where/limit)"
            : "";
          resultText = body + capNote + (res.hasMore ? " (truncated)" : "") + degradedNote;
        } catch (e) {
          const raw = e.message || String(e);
          resultText = "QUERY ERROR (trap = fix query): " + raw;
          // The failed query + trace go into the workings, not the chat — the
          // agent adjusts and its eventual answer is what the user sees.
          assistantRecordWorkingError("Query failed — adjusting", "[" + qcan + "] " + oql + "\n\n" + raw);
        }
        _asstTurns.push({ role: "assistant", text: asstJson(obj) });
        _asstTurns.push({ role: "tool", text: "QUERY RESULT: " + resultText });
        continue;
      }
      if (obj.type === "account") {
        // Client-side read tool: the SAME composition the Account → All tab
        // renders (summary + positions + pools + vault + insurance). OQL can't
        // see pool/vault/insurance sub-principal balances, so the assistant
        // reads the authoritative snapshot directly. Values arrive
        // wrapActor-normalized: HUMAN USD floats, not e8.
        let resultText;
        try {
          const a = appState.actor;
          const [summary, positions, pools, vaultPos, insStake] = await Promise.all([
            a.getMyAccountSummary(), a.getMyPositions(), a.getMyMarginPools(),
            a.getMyVaultPosition(), a.getMyInsuranceStake(),
          ]);
          const uPnl = (positions || []).reduce((s, p) => s + Number(p.unrealizedPnl), 0);
          const poolsEquity = (pools || []).reduce((s, p) => s + (Number(p.valueUsd) || 0), 0);
          const acct = {
            accountValueUsd: Number(summary.netAccountValueUsd),
            walletUsd: Number(summary.freeWalletValueUsd) - Number(summary.wholeWalletDebtUsd),
            positionsUnrealizedPnlUsd: uPnl,
            poolsUsd: poolsEquity - uPnl,
            ammVaultUsd: Number(vaultPos.estimatedValue) || 0,
            insuranceUsd: Number(insStake.valueUsd) || 0,
            openPositions: (positions || []).length,
            pools: (pools || []).length,
          };
          assistantRecordWorking("Account snapshot", [acct]);
          resultText = "ACCOUNT SUMMARY (USD, ALREADY human units — do NOT divide): " + asstJson(acct);
        } catch (e) {
          const raw = e.message || String(e);
          resultText = "ACCOUNT ERROR: " + raw;
          assistantRecordWorkingError("Account read failed", raw);
        }
        _asstTurns.push({ role: "assistant", text: asstJson(obj) });
        _asstTurns.push({ role: "tool", text: resultText });
        continue;
      }
      if (obj.type === "candles") {
        // Client-side read tool over the SAME getCandles the chart uses.
        // Candle.time arrives in ns; o/h/l/c/volume arrive wrapActor-normalized
        // (human units). Only the last 48 rows are fed back — the conversation
        // is resent on every agent step, so a full 100-candle page would bloat
        // every subsequent LLM call.
        // Must mirror OrderBook.mo's CANDLE_INTERVALS (the backend has no
        // public query exposing them — #46.4): a bucket the backend never
        // materialises (e.g. the old 12h/43200000 entry) returns an EMPTY
        // candle response, which reads as "no price history" to the model.
        const ALLOWED_IVS = [60000, 300000, 900000, 3600000, 14400000, 86400000, 604800000];
        let resultText;
        try {
          const want = Number(obj.intervalMs) || 3600000;
          const iv = ALLOWED_IVS.reduce((b, x) => Math.abs(x - want) < Math.abs(b - want) ? x : b, ALLOWED_IVS[0]);
          const page = Math.max(0, Number(obj.page) || 0);
          const mkt = String(obj.marketId || "");
          const a = appState.actor || appState.publicActor;
          const resp = await a.getCandles(mkt, iv, page);
          const rows = (resp.candles || []).slice(-48).map((c) => ({
            t: new Date(Number(c.time) / 1e6).toISOString().slice(0, 16) + "Z",
            o: Number(c.open), h: Number(c.high), l: Number(c.low), c: Number(c.close),
            v: Number(c.volume),
          }));
          resultText = rows.length
            ? "CANDLES " + mkt + " @" + iv + "ms page " + page + " (oldest→newest; t=UTC; o/h/l/c ALREADY human units; v=0 means no trades — price tracked the oracle): "
              + asstJson(rows) + (resp.hasMore ? " (older: page+1)" : "")
            : "CANDLES: none — check marketId (see Available markets) and intervalMs.";
          if (rows.length) assistantRecordWorking("Price history · " + mkt, rows.slice(-8));
        } catch (e) {
          const raw = e.message || String(e);
          resultText = "CANDLES ERROR: " + raw;
          assistantRecordWorkingError("Price-history read failed", raw);
        }
        _asstTurns.push({ role: "assistant", text: asstJson(obj) });
        _asstTurns.push({ role: "tool", text: resultText });
        continue;
      }
      if (obj.type === "action") {
        const act = ASSISTANT_ACTIONS[obj.method];
        _asstTurns.push({ role: "assistant", text: asstJson(obj) });
        if (!act) { _asstTurns.push({ role: "tool", text: "ERROR: unknown action '" + obj.method + "'" }); continue; }
        if (!asstActionAvailable(obj.method)) {
          _asstTurns.push({ role: "tool", text: "ERROR: action '" + obj.method + "' is not available on this venue (the dev faucet exists only on #dev deployments) — tell the user instead of retrying." });
          continue;
        }
        // Fail CLOSED on an ambiguous side (GHSA-6qpg item 2): a proposal
        // whose side is not exactly buy/sell never reaches a confirm card —
        // the model gets an ERROR tool message and must re-propose.
        const actArgs = obj.args || {};
        if ("side" in actArgs && asstSide(actArgs.side) === null) {
          _asstTurns.push({ role: "tool", text: "ERROR: invalid side " + asstJson(String(actArgs.side)) + " for '" + obj.method + "' — side must be exactly \"buy\" or \"sell\"; re-propose with a valid side." });
          continue;
        }
        const ok = await assistantConfirm(obj.method, actArgs, act.summary(actArgs));
        if (!ok) { assistantAddNote("Action cancelled."); _asstTurns.push({ role: "tool", text: "User DECLINED the action." }); continue; }
        let outcome;
        try {
          const res = await act.run(obj.args || {});
          outcome = ("ok" in res) ? asstActionOutcome(obj.method, res.ok) : ("ERR " + res.err);
          // Usage stats (Account → AI): report the confirmed, successful run.
          // Fire-and-forget — a lost report only under-counts a stat.
          if ("ok" in res) { try { appState.actor.aiActionExecuted(String(obj.method)); } catch (_) {} }
        } catch (e) { outcome = "EXCEPTION " + (e.message || String(e)); }
        assistantAddNote("→ " + outcome);
        _asstTurns.push({ role: "tool", text: "ACTION RESULT: " + outcome });
        try { if (_refreshAccount) _refreshAccount(); } catch (_) {}
        continue;
      }
      if (obj.type === "refused") {
        // The backend's guard preamble makes the model refuse harmful or
        // jailbreak prompts with this marker; the proxy counts them and
        // repeated trips suspend AI access for 24h (see Account → AI).
        assistantAddNote("⛔ Request refused: " + (obj.reason || "policy violation")
          + ". Repeated policy refusals suspend AI access for 24 hours.");
        break;
      }
      // Unknown type — surface raw and stop.
      assistantAddMsg("assistant", r.ok); break;
    }
  } finally {
    // The turn's intermediate tables/errors were kept out of the chat; offer
    // them behind one link under the answer instead.
    assistantAddWorkingsLink(_asstWorkings);
    _asstBusy = false; assistantSetThinking(false);
  }
}

async function assistantSubmit() {
  const inp = document.getElementById("asst-input");
  if (!inp) return;
  const text = (inp.value || "").trim();
  if (!text || _asstBusy) return;
  if (!appState.isAuthenticated) { assistantAddMsg("assistant", "Please sign in to use the assistant."); return; }
  // Signed in but the actor is missing (a failed/incomplete session restore)
  // → try to rebuild it once before refusing, and say what actually happened
  // rather than a misleading "please sign in".
  if (!appState.actor && _ensureActor) { try { await _ensureActor(); } catch (_) {} }
  if (!appState.actor) {
    console.warn("assistant: signed in but no actor (session restore incomplete?)");
    assistantAddMsg("assistant", "Your session didn't finish connecting — please refresh the page and try again.");
    return;
  }
  inp.value = "";
  assistantAddMsg("user", text);
  _asstTurns.push({ role: "user", text });
  assistantRun();
}

export function setupAssistant(deps) {
  if (deps && deps.getMarkets) _getMarkets = deps.getMarkets;
  if (deps && deps.ensureActor) _ensureActor = deps.ensureActor;
  if (deps && deps.refreshAccountData) _refreshAccount = deps.refreshAccountData;
  // The chat now lives in the Intelli → AI Assistant tab (not a floating panel).
  document.getElementById("asst-send")?.addEventListener("click", assistantSubmit);
  document.getElementById("asst-input")?.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); assistantSubmit(); }
  });
}

// Identity-boundary reset (GHSA-6qpg item 1): called by main.js's logout() so
// the transcript, the rendered chat, and the per-identity caches never survive
// a sign-out — without this, the next sign-in on a shared browser splices the
// previous user's turns (account snapshots, positions) into ITS prompt and
// relays them over the new identity's authenticated aiComplete outcall.
export function resetAssistant() {
  _asstTurns = [];
  _asstWorkings = [];   // prior turns' query tables/account snapshots are transcript too
  _asstSeeded = false;  // the next user gets a fresh greeting
  _oqlSchema = null;    // refetched lazily; harmless, but identity-adjacent state stays out
  _asstBusy = false;    // an in-flight turn's writes land in a cleared, ownerless chat at worst
  const list = asstEl();
  if (list) list.innerHTML = "";
}

// Shown when the Ask-AI tab opens: focus the input and seed the greeting once.
export function assistantOnShow() {
  document.getElementById("asst-input")?.focus();
  if (!_asstSeeded) {
    assistantAddMsg("assistant", "Hi — I can query the exchange (pools, positions, the order book, events) and, with your confirmation, place orders or manage positions. Try: “show my positions” or “approximately how much slippage to market-buy $1000 of ICP?”");
    _asstSeeded = true;
  }
}
