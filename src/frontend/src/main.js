// ── UPLANDS DEX Frontend ─────────────────────────────────────────

// Inter (self-hosted, variable wght + opsz) — the single bundled typeface for
// all site text and numbers (the logo wordmark is an outlined SVG, no font). Its
// optical-size axis + tabular figures keep small numbers crisp and aligned.
// Declares font-family "Inter Variable".
import "@fontsource-variable/inter";
// Newsreader italic (opsz+wght variable) — ONLY for the Swap strap's pay-off
// word; bundled like Inter so the app makes no external font requests.
import "@fontsource-variable/newsreader/opsz-italic.css";

// Lightweight Charts v5 (native multi-pane: candles in pane 0, volume
// histogram in pane 1). BUNDLED as an npm dependency, deliberately: this used
// to be a bare <script src="https://unpkg.com/…"> in index.html with no
// integrity attribute and no lockfile entry, so a compromised (or merely
// re-published) CDN artefact would execute with full DOM access on the trading
// page. An import is content-hashed into our own bundle and pinned by
// package-lock.json, and it lets the app ship a real CSP with `script-src 'self'`.
import { createChart, CandlestickSeries, HistogramSeries, LineSeries } from "lightweight-charts";

// Pure formatting/display helpers (number/price/time/quantity, price flash).
import { formatQty, priceDecimals, formatBookPrice, formatBookQty, uniformDecimals, formatNum, formatPrice, formatTime, flashPriceEl } from "./format.js";
import { wrapActor, toE8, fromE8 } from "./money.js";

// Shared app state (actors, auth flag, principal) — read by feature modules too.
import { appState } from "./state.js";

// OQL display helpers (shared with the data explorer) + the feature modules.
import { oqlRowsToObjects, oqlFormatCell, dxEsc } from "./oql.js";
import { setupIntelli, dxApplyShareLink, dxEnsureSchema, dxOnAuthChange, dxUpdateIdentity } from "./explorer.js";
import { setupAssistant, assistantOnShow, resetAssistant } from "./assistant.js";
import { setIdenticon } from "./identicon.js";
import { DOCS_PARTS, DOCS_PAGES, docsPage } from "./docs.js";
import { setupLedger } from "./ledger.js";
import { startUpdateCheck } from "./update-check.js";
// Exact-hostname local-replica test — gates fetchRootKey() (see host.js).
import { isLocalReplicaOrigin } from "./host.js";

// ── Missing-asset images ─────────────────────────────────────────
// Token logos are rendered from markup templates and a token may simply have
// no /assets/<SYM>.svg; a broken-image glyph in a price row looks like a bug.
// This used to be an inline error-handler attribute on each of eight <img>
// templates, which a Content-Security-Policy worth having ('unsafe-inline'-free
// — the asset canister's `standard` policy) refuses to run, silently restoring
// the broken glyphs. One delegated listener replaces all of them: `error` does
// not bubble, but it DOES propagate down the capture path, so a capture-phase
// listener on `document` sees every element's failure. Registered at module
// scope, before any rendering, so no image can fail ahead of it.
document.addEventListener("error", (ev) => {
  const el = ev.target;
  if (el && el.tagName === "IMG" && el.hasAttribute("data-hide-on-error")) {
    el.style.display = "none";
  }
}, true);

// App version, baked at build (vite define, single-sourced from package.json).
// Stamps the footer badge and drives the self-update check. Guarded like
// __CLOUD_ENGINE__ so a build without the define stays harmless.
const APP_VERSION = (() => { try { return __APP_VERSION__; } catch { return ""; } })();

// Cloud-engine mode (baked at build time via vite.config.js __CLOUD_ENGINE__,
// set by scripts/deploy.sh). On a cloud engine the engine pays for compute, so
// the canister's own cycles read ~0 — suppress the "low/out of cycles" warning
// (memory warnings still apply). Guarded so it's harmless if define is absent.
const CLOUD_ENGINE = (typeof __CLOUD_ENGINE__ !== "undefined") ? __CLOUD_ENGINE__ : false;

let AuthClient, HttpAgent, Actor, IDL, Principal;
let authClient = null;
let identity = null;
let icAgent = null;       // the authenticated HttpAgent, reused to build the archive appState.actor
// appState.actor, appState.publicActor, appState.archiveActor, appState.isAuthenticated, appState.myPrincipalText now live on
// appState (state.js) so the feature modules can share them — see import above.

// ── State ────────────────────────────────────────────────────────
let currentTab = "swap";
let selectedMarket = null;
let recentMarkets = [];            // last 3 viewed market IDs (most recent first)
let lastMarket = null;             // last selected market ID (persisted as default)
let maxSlippage = 0.05;
let orderType = "limit";
let orderSide = "buy";
let orderMode = "spot";            // "spot" (wallet trade) | "margin" (open a pool position)
let savedOrderPrices = { buy: "", sell: "" }; // remembered prices per side
let userBalances = {};       // TOTALS (getBalances) — display
let userAvailBalances = {};  // AVAILABLE (getMyAvailableBalances) — order-form gating
// Latest margin-account snapshot from getMyBidHeadroom — used by the
// Balances card to render the free / locked / total breakdown on tokens
// that have margin commitments. Null when the user has no margin account.
let cachedMarginAccount = null;
let cachedMarginHealth = null;  // latest getMyMarginHealth (debt/collateral/health) — net value + Borrow&Buy gate
let cachedAcctSummary = null;   // latest getMyAccountSummary — header pill + Account→All overview
let ledgerCtl = null;           // setupLedger() handle — activateTab("ledger") triggers its first load
// (No client-side margin constants: LTVs / health ratios / liq math live
// ONLY in the canister — previewOpenPosition is the pre-flight oracle.)
let markets = [];
let refreshInterval = null;      // slow ticker: balances, order book caches
let marketTickInterval = null;   // fast ticker: order book + trades for current market
let chartRefreshInterval = null; // live refresh interval while chart is open
let tradeTimeTickInterval = null; // 1s ticker to update relative trade times
let orderBookCache = {};        // marketId → OrderBookSnapshot
let marketDataCache = {};       // marketId → { orderBook, trades, timestamp } for instant switching
let swapPreviewDebounce = null; // debounce timer for preview updates
// Last swap preview outcome, used to derive Swap-button state. Shape:
//   { filled, consumedFrom, fromAmount, fromToken, toAmount, toToken } | null
let lastSwapEstimate = null;
let _swapQuoteTimer = null;
let _swapQuoteSeq = 0;
let userProfile = null;         // UserProfile from backend
let chartInstance = null;       // lightweight-charts chart object
let chartCandleSeries = null;   // candlestick series
let chartVolumeSeries = null;   // volume histogram series
let chartTrades = [];           // raw trades for current market chart (legacy, used by mini chart fallback)
let chartInterval = 3600000;    // current chart interval in ms (default 1h)
let chartCandleData = null;     // { candles, volumes } from backend getCandles API
let chartCurrentPage = 0;       // current highest page loaded for full chart
let chartHasMore = false;       // whether older pages exist
let chartLoadingMore = false;   // prevent concurrent page loads
const CHART_VISIBLE_CANDLES = 120; // default candles on screen — more history + thinner candles (auto-fit to width)
let lastTradeIds = new Set();   // IDs of trades rendered in last renderTrades call
let renderedTrades = [];        // most recent rendered trades (newest-first) for time tick updates
let lastOrderBookSnapshot = null; // cached raw snapshot for re-rendering on setting change
let obGranularity = 0;          // 0 = exact, otherwise bucket size in price units
let obCumulative = true;        // cumulative (aggregation) depth mode — on by default
let obGranularityByMarket = {}; // marketId → last-used granularity
let obPrevAsk = {};             // price → qty from last render (for change-flash)
let obPrevBid = {};
let prevMarketPrice = null;     // last lastPrice seen (selector-bar price flash)
let uomTab = "open";            // activity panel tab: "open" | "history" (spot) | "positions" | "poshistory"
// Panel-level market scope (all four tabs). Default OFF = all markets, the
// venue norm; persisted locally so the preference survives reloads.
let uomScopeCurrent = false;
try { uomScopeCurrent = localStorage.getItem("uplandsUomScopeCurrent") === "1"; } catch {}
// Mobile (≤900px, the responsive.css breakpoint) hides the checkbox, so the
// filter must not apply there either — a preference ticked on desktop would
// otherwise hide rows behind a control the user can't see.
const uomMobileMQ = window.matchMedia("(max-width: 900px)");
function uomScopeActive() { return uomScopeCurrent && !uomMobileMQ.matches; }
// Render-time filter for the activity panel: identity when unscoped.
function uomScoped(arr, marketOf = (x) => x.marketId) {
  return (uomScopeActive() && selectedMarket) ? arr.filter((x) => marketOf(x) === selectedMarket) : arr;
}
const uomCoin = (marketId) => (marketId || "").split("-")[0];
// One visual language for the activity panel's leading columns: an "Asset"
// cell (token icon + symbol) followed by a "Side" pill — Buy/Sell for spot
// flow, Long/Short for margin flow (Long/Short itself signals a margin row).
function assetCellHTML(base) {
  return `<img class="market-logo market-logo-sm" src="/assets/${base}.svg" alt="" data-hide-on-error>${base}`;
}
function sidePillHTML(sideWord) {
  const up = sideWord === "Buy" || sideWord === "Long";
  return `<span class="pos-side ${up ? "pos-long" : "pos-short"}">${sideWord}</span>`;
}
// Fully-qualified pool label — name plus its isolation mode — resolved from
// the shared pool cache (renderPositions / renderUomPositions keep it
// fresh). Falls back to the raw id if unknown. One renderer, so Positions
// and Positions History show pools identically.
function poolLabelHTML(poolId) {
  const pl = (_poolsCache || []).find((x) => Number(x.id) === Number(poolId));
  if (!pl) return `Pool ${Number(poolId)}`;
  return `${escH(pl.name)} <span class="pos-roe">· ${pl.isolated ? "isolated" : "cross"}</span>`;
}
// "When" rendering: 24h hh:mm for today's entries, "+N day(s)" for older.
function whenLabel(ms) {
  const d = new Date(ms), now = new Date();
  const dayStart = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const days = Math.round((dayStart(now) - dayStart(d)) / 86400000);
  if (days <= 0) return d.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", hour12: false });
  return `+${days} day${days === 1 ? "" : "s"}`;
}
let uomPage = 0;                // current pagination page
let uomOpenOrders = [];         // cached SPOT open orders for current market
let uomPoolOrders = [];         // cached resting MARGIN orders for current market (owned by pool principals)
let stagedOrderIds = new Set(); // ids of STAGED (off-book, awaiting-GEPTOR) orders
let uomPendingMatches = [];     // cached pending matches for current market (taker side)
// appState.myPrincipalText now lives on appState (state.js).
// Per-market trade history: marketId → newest-first trades[]. Replaces the
// old single-market `uomTradeHistory` so cross-market trades arriving via
// pollChanges don't get dropped when the user is on a different market.
let uomTradeHistoryByMarket = {};
const UOM_PAGE_SIZE = 10;
let cachedUserStatus = null;       // { version, lastTradeTime, openOrderCount } from getUserStatus
let statusPollInterval = null;     // interval for getUserStatus polling
let cachedMarketStatus = {};       // marketId → last-seen { version, lastTradeId }
let cachedMarketTrades = {};       // marketId → array of PublicTrades (newest last, chronological)
let orderBookState = {};           // marketId → { asks: Map<price, level>, bids: Map<price, level> } for delta merging
let miniChartInstance = null;    // lightweight-charts instance for the Markets-page mini chart
let miniChartSeries = null;      // candlestick series for mini chart
let miniChartVolumeSeries = null;// volume histogram series for mini chart
let miniChartRefreshInterval = null; // refresh interval for mini chart
let miniChartCandleInterval = 3600000; // current candle interval for mini chart (default 1h)

// ── IndexedDB Preferences ────────────────────────────────────────
function openPrefsDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open("uplands-prefs", 1);
    req.onupgradeneeded = () => req.result.createObjectStore("prefs");
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function loadLocalPrefs() {
  try {
    const db = await openPrefsDB();
    return new Promise((resolve) => {
      const tx = db.transaction("prefs", "readonly");
      const store = tx.objectStore("prefs");
      const req = store.get("marketPrefs");
      req.onsuccess = () => resolve(req.result || { recentMarkets: [], lastMarket: null });
      req.onerror = () => resolve({ recentMarkets: [], lastMarket: null });
    });
  } catch {
    return { recentMarkets: [], lastMarket: null };
  }
}

async function saveLocalPrefs(prefs) {
  try {
    const db = await openPrefsDB();
    const tx = db.transaction("prefs", "readwrite");
    tx.objectStore("prefs").put(prefs, "marketPrefs");
  } catch {
    // Silently fail — IndexedDB may be unavailable in some contexts
  }
}

// ── IDL Factory for the backend canister ─────────────────────────
function getIdlFactory() {
  return ({ IDL }) => {
    const Side = IDL.Variant({ buy: IDL.Null, sell: IDL.Null });
    const OrderType = IDL.Variant({ market: IDL.Null, limit: IDL.Null });
    const OrderStatus = IDL.Variant({
      open: IDL.Null,
      partiallyFilled: IDL.Null,
      filled: IDL.Null,
      cancelled: IDL.Null,
    });
    const Order = IDL.Record({
      id: IDL.Nat,
      marketId: IDL.Text,
      owner: IDL.Principal,
      side: Side,
      orderType: OrderType,
      price: IDL.Nat,
      quantity: IDL.Nat,
      filled: IDL.Nat,
      status: OrderStatus,
      timestamp: IDL.Int,
      originalQuantity: IDL.Nat,
    });
    const Trade = IDL.Record({
      id: IDL.Nat,
      marketId: IDL.Text,
      buyOrderId: IDL.Nat,
      sellOrderId: IDL.Nat,
      buyer: IDL.Principal,
      seller: IDL.Principal,
      price: IDL.Nat,
      quantity: IDL.Nat,
      timestamp: IDL.Int,
      takerOrderType: IDL.Opt(OrderType),
    });
    const MarketInfo = IDL.Record({
      id: IDL.Text,
      baseToken: IDL.Text,
      quoteToken: IDL.Text,
      lastPrice: IDL.Nat,
      volume24h: IDL.Nat,
      priceChange24hAbs: IDL.Int,
      markPrice: IDL.Nat,
    });
    const OrderBookLevel = IDL.Record({
      price: IDL.Nat,
      quantity: IDL.Nat,
      orderCount: IDL.Nat,
    });
    const OrderBookSnapshot = IDL.Record({
      bids: IDL.Vec(OrderBookLevel),
      asks: IDL.Vec(OrderBookLevel),
      spread: IDL.Nat,
    });
    const OrderBookDelta = IDL.Record({
      asks: IDL.Vec(OrderBookLevel),
      bids: IDL.Vec(OrderBookLevel),
    });
    const SwapMode = IDL.Variant({
      marketOrder: IDL.Record({ maxSlippage: IDL.Nat }),
      limitOrder: IDL.Record({ limitPrice: IDL.Nat }),
    });
    const SwapRequest = IDL.Record({
      fromToken: IDL.Text,
      toToken: IDL.Text,
      amount: IDL.Nat,
      mode: SwapMode,
      noPartialFill: IDL.Bool,
    });
    const SwapResult = IDL.Record({
      fromAmount: IDL.Nat,
      toAmount: IDL.Nat,
      fullyFilled: IDL.Bool,
      swapOrderId: IDL.Opt(IDL.Nat),
    });
    const PendingMatch = IDL.Record({
      id:               IDL.Nat,
      marketId:         IDL.Text,
      makerOrderId:     IDL.Nat,
      makerPrincipal:   IDL.Principal,
      takerPrincipal:   IDL.Principal,
      takerSide:        Side,
      takerOrderType:   OrderType,
      price:            IDL.Nat,
      quantity:         IDL.Nat,
      takerDebitToken:  IDL.Text,
      takerDebitAmount: IDL.Nat,
      makerDebitToken:  IDL.Text,
      makerDebitAmount: IDL.Nat,
      createdAtNs:      IDL.Int,
      expiryNs:         IDL.Int,
      status: IDL.Variant({ pending: IDL.Null, finalized: IDL.Null, voided: IDL.Null }),
    });
    const MatchResult = IDL.Record({
      trades: IDL.Vec(Trade),
      pendingMatches: IDL.Vec(PendingMatch),
      remainingQty: IDL.Nat,
      totalFilled: IDL.Nat,
      avgPrice: IDL.Nat,
      affectedUsers: IDL.Vec(IDL.Principal),
    });
    // Principal-level margin health (collateral / debt / ratio), still read for
    // net-value/debt display via getMyMarginHealth.
    const MarginHealth = IDL.Record({
      collateralUsd:    IDL.Nat,
      debtUsd:          IDL.Nat,
      equityUsd:        IDL.Int,
      healthRatio:      IDL.Nat,
      maintenanceRatio: IDL.Nat,
      isLiquidatable:   IDL.Bool,
    });
    // ── Margin Pools (first-class segregated positions) ──
    const MarginPoolView = IDL.Record({
      id: IDL.Nat, name: IDL.Text, isolated: IDL.Bool, principal: IDL.Text,
      health: MarginHealth, marginUsage: IDL.Nat, freeQuote: IDL.Nat,
      valueUsd: IDL.Int, createdAt: IDL.Int,
    });
    // Position/pool history (episodes = one row per open→flat lifetime).
    const PositionEpisode = IDL.Record({
      poolId: IDL.Nat, poolName: IDL.Text, marketId: IDL.Text, baseToken: IDL.Text,
      side: IDL.Variant({ long: IDL.Null, short: IDL.Null }),
      qty: IDL.Nat, avgEntry: IDL.Nat, avgExit: IDL.Nat,
      realizedPnl: IDL.Int, openedAt: IDL.Int, closedAt: IDL.Int,
      liquidated: IDL.Bool,
    });
    const PoolTransfer = IDL.Record({
      poolId: IDL.Nat, poolName: IDL.Text, amount: IDL.Nat,
      kind: IDL.Variant({ fund: IDL.Null, withdraw: IDL.Null }),
      timestamp: IDL.Int,
    });
    const LiquidationEvent = IDL.Record({
      user: IDL.Principal,
      debtToken: IDL.Text, debtRepaid: IDL.Nat, debtRepaidUsd: IDL.Nat,
      collateralToken: IDL.Text, collateralSeized: IDL.Nat,
      proceedsUsd: IDL.Nat, penaltyUsd: IDL.Nat,
      healthBefore: IDL.Nat, healthAfter: IDL.Nat, timestamp: IDL.Int,
    });
    // Release-time order rejections/reductions (never-silent kills/clamps).
    const ReleaseRejection = IDL.Record({
      marketId: IDL.Text, side: Side, qty: IDL.Nat,
      clampedTo: IDL.Opt(IDL.Nat), price: IDL.Nat,
      poolName: IDL.Opt(IDL.Text), reason: IDL.Text, timestamp: IDL.Int,
    });
    const PositionView = IDL.Record({
      poolId: IDL.Nat, marketId: IDL.Text, baseToken: IDL.Text,
      size: IDL.Int, entryPrice: IDL.Nat, markPrice: IDL.Nat,
      notionalUsd: IDL.Nat, unrealizedPnl: IDL.Int, realizedPnl: IDL.Int,
      liqPrice: IDL.Opt(IDL.Nat), pctToLiq: IDL.Opt(IDL.Nat),
    });
    const AccountSummary = IDL.Record({
      netAccountValueUsd: IDL.Int, freeWalletValueUsd: IDL.Nat,
      wholeWalletDebtUsd: IDL.Nat, poolCount: IDL.Nat,
      worstMarginUsage: IDL.Nat, pctToLiquidation: IDL.Nat,
    });
    const PlaceLimitResult = IDL.Record({
      order: Order,
      pendingMatches: IDL.Vec(PendingMatch),
    });
    const UserProfile = IDL.Record({
      userId: IDL.Text,
      username: IDL.Text,
      regenCount: IDL.Nat,
      createdAt: IDL.Int,
    });
    const AdjustmentReason = IDL.Variant({
      balanceShrank: IDL.Null,
      marketCapExceeded: IDL.Null,
      crossMarketCapExceeded: IDL.Null,
    });
    const OrderAdjustment = IDL.Record({
      orderId: IDL.Nat,
      marketId: IDL.Text,
      side: Side,
      oldQuantity: IDL.Nat,
      newQuantity: IDL.Nat,
      cancelled: IDL.Bool,
      timestamp: IDL.Int,
      reason: IDL.Opt(AdjustmentReason), // null: recorded before reasons existed
    });
    const DepositRecord = IDL.Record({
      token: IDL.Text,
      amount: IDL.Nat,
      timestamp: IDL.Int,
      kind: IDL.Variant({ deposit: IDL.Null, withdrawal: IDL.Null }),
    });
    // Permanent user-history event (archive sidecar + the app's unshipped tail).
    const ClosedOrderRecord = IDL.Record({
      id: IDL.Nat, marketId: IDL.Text, side: Side, orderType: OrderType,
      price: IDL.Nat, quantity: IDL.Nat, filled: IDL.Nat,
      status: OrderStatus, placedAt: IDL.Int, closedAt: IDL.Int,
    });
    const UserEventKind = IDL.Variant({
      fill: IDL.Record({ marketId: IDL.Text, side: Side, price: IDL.Nat, qty: IDL.Nat, orderId: IDL.Nat, tradeId: IDL.Nat }),
      deposit: DepositRecord,
      orderClosed: ClosedOrderRecord,
      liquidation: LiquidationEvent,
      borrow: IDL.Record({ token: IDL.Text, amount: IDL.Nat }),
      repay: IDL.Record({ token: IDL.Text, amount: IDL.Nat }),
      lpDeposit: IDL.Record({ marketId: IDL.Text, baseAmount: IDL.Nat, quoteAmount: IDL.Nat, lpMinted: IDL.Nat }),
      lpWithdraw: IDL.Record({ lpBurned: IDL.Nat, basket: IDL.Vec(IDL.Tuple(IDL.Text, IDL.Nat)) }),
      insuranceStake: IDL.Record({ amountUsd: IDL.Nat, shares: IDL.Nat }),
      insuranceUnstake: IDL.Record({ shares: IDL.Nat, payoutUsd: IDL.Nat }),
      // Ledger-of-record rows (one signed delta per balance mutation) —
      // machine records for replay/PoR; the timeline view skips them.
      delta: IDL.Record({ token: IDL.Text, amount: IDL.Int }),
      debtDelta: IDL.Record({ token: IDL.Text, amount: IDL.Int }),
      lpShareDelta: IDL.Record({ marketId: IDL.Text, amount: IDL.Int }),
      insShareDelta: IDL.Record({ amount: IDL.Int }),
      gap: IDL.Record({ fromSeq: IDL.Nat, toSeq: IDL.Nat }),
      config: IDL.Record({ setter: IDL.Text, value: IDL.Text }),
    });
    const UserEvent = IDL.Record({
      seq: IDL.Nat, ts: IDL.Int, user: IDL.Principal,
      counterparty: IDL.Opt(IDL.Principal), kind: UserEventKind,
      prevHash: IDL.Opt(IDL.Vec(IDL.Nat8)),
    });
    const UserPreferences = IDL.Record({
      recentMarkets: IDL.Vec(IDL.Text),
      lastMarket: IDL.Opt(IDL.Text),
    });
    const Candle = IDL.Record({
      time: IDL.Int,
      open: IDL.Nat,
      high: IDL.Nat,
      low: IDL.Nat,
      close: IDL.Nat,
      volume: IDL.Nat,
    });
    const CandleResponse = IDL.Record({
      candles: IDL.Vec(Candle),
      hasMore: IDL.Bool,
    });
    const UserStatus = IDL.Record({
      version: IDL.Nat,
      lastTradeTime: IDL.Int,
      openOrderCount: IDL.Nat,
    });
    const PublicTrade = IDL.Record({
      id: IDL.Nat,
      price: IDL.Nat,
      quantity: IDL.Nat,
      timestamp: IDL.Int,
    });
    const MarketStatus = IDL.Record({
      version: IDL.Nat,
      lastTradeId: IDL.Nat,
    });
    const MarketChangesRequest = IDL.Record({
      marketId: IDL.Opt(IDL.Text),
      lastMarketVersion: IDL.Nat,
      lastTradeId: IDL.Nat,
      lastUserVersion: IDL.Nat,
      lastUserTradeTime: IDL.Int,
    });
    const MarketChangesResponse = IDL.Record({
      marketStatus: IDL.Opt(MarketStatus),
      orderBook: IDL.Opt(OrderBookSnapshot),
      orderBookDelta: IDL.Opt(OrderBookDelta),
      newTrades: IDL.Vec(PublicTrade),
      userStatus: IDL.Opt(UserStatus),
      userOpenOrders: IDL.Opt(IDL.Vec(Order)),
      userBalances: IDL.Opt(IDL.Vec(IDL.Tuple(IDL.Text, IDL.Nat))),
      newUserTrades: IDL.Vec(Trade),
    });

    // ── Leaderboard (trading profit vs HODL — precomputed snapshot) ──
    // No principal: the board publishes names, the tape publishes principals,
    // and nothing joins the two (backend PublicLeaderRow). `isMe` is computed
    // per-caller so your own row still highlights.
    const LeaderRow = IDL.Record({
      rank: IDL.Nat, username: IDL.Text,
      profitUsd: IDL.Int, capitalUsd: IDL.Nat, equityUsd: IDL.Int,
      returnBps: IDL.Int, feeLevel: IDL.Nat, badgeCount: IDL.Nat,
      isMe: IDL.Bool,
    });

    // ── AMM + price-feed types (Phase 2/3/4/5) ──
    const Pool = IDL.Record({
      marketId: IDL.Text,
      baseToken: IDL.Text,
      spreadBps: IDL.Nat,
      quoteDepthBase: IDL.Nat,
      numLevels: IDL.Nat,
      levelSpacingBps: IDL.Nat,
      protectionWindowSec: IDL.Nat,
      enabled: IDL.Bool,
      inventoryTargetBase: IDL.Nat,
      skewIntensityBps: IDL.Nat,
      refPrice: IDL.Nat,
      refPriceUpdatedNs: IDL.Int,
      activeBidIds: IDL.Vec(IDL.Nat),
      activeAskIds: IDL.Vec(IDL.Nat),
      lastRequoteNs: IDL.Int,
      totalLPSupply: IDL.Nat,
      volRegime: IDL.Float64,
      lastVolSamplePrice: IDL.Nat,
      lastVolSampleNs: IDL.Int,
      lastRebalanceNs: IDL.Int,
    });
    const PoolValueInfo = IDL.Record({
      marketId: IDL.Text,
      baseHeld: IDL.Nat,
      quoteHeld: IDL.Nat,
      refPrice: IDL.Nat,
      totalLPSupply: IDL.Nat,
      poolQuoteValue: IDL.Nat,
      volRegime: IDL.Float64,
    });
    // `kind` is a Text tag (not a variant) so the backend can add price
    // providers without a breaking interface change — see PriceSourceInfo
    // in main.mo.
    const PriceSource = IDL.Record({
      id: IDL.Text,
      urlTemplate: IDL.Text,
      kind: IDL.Text,
    });
    const Reading = IDL.Record({
      sourceId: IDL.Text,
      asset: IDL.Text,
      price: IDL.Float64,
      fetchedAtNs: IDL.Int,
      ok: IDL.Bool,
      errMessage: IDL.Opt(IDL.Text),
    });
    const Aggregate = IDL.Record({
      asset: IDL.Text,
      price: IDL.Float64,
      sourceCount: IDL.Nat,
      stddevBps: IDL.Float64,
      timestamp: IDL.Int,
      readings: IDL.Vec(Reading),
    });
    const PriceFeedStats = IDL.Record({
      successCount: IDL.Nat,
      failureCount: IDL.Nat,
      refreshInFlight: IDL.Bool,
      intervalSec: IDL.Nat,
      minSources: IDL.Nat,
      maxStddevBps: IDL.Float64,
    });
    const PoolSnapshot = IDL.Record({
      timestamp: IDL.Int,
      baseHeld: IDL.Nat,
      quoteHeld: IDL.Nat,
      refPrice: IDL.Nat,
      poolValue: IDL.Nat,
      totalLPSupply: IDL.Nat,
      valuePerLP: IDL.Nat,
    });
    const VaultBasket = IDL.Record({
      btc: IDL.Nat,
      eth: IDL.Nat,
      sol: IDL.Nat,
      icp: IDL.Nat,
      icpusd: IDL.Nat,
    });
    const VaultPrices = IDL.Record({
      btc: IDL.Nat,
      eth: IDL.Nat,
      sol: IDL.Nat,
      icp: IDL.Nat,
    });
    const VaultValue = IDL.Record({
      basket: VaultBasket,
      prices: VaultPrices,
      totalQuoteValue: IDL.Nat,
      lpSupply: IDL.Nat,
      valuePerLP: IDL.Nat,
    });
    const VaultSnapshot = IDL.Record({
      timestamp: IDL.Int,
      basket: VaultBasket,
      prices: VaultPrices,
      totalQuoteValue: IDL.Nat,
      lpSupply: IDL.Nat,
      valuePerLP: IDL.Nat,
    });
    // One liquidation snapshot (exact 1% bands) — a single COLUMN of the
    // heat surface. Shared by the latest-value query and the history ring.
    // Columns computed before 2026-08-01 carry the old k-anonymous shape
    // (merged/side-wide bands) and linger in the ring for ~4h.
    const MarginHeatmapRec = IDL.Record({
      marketId: IDL.Text, markPrice: IDL.Nat, tier: IDL.Text,
      buckets: IDL.Vec(IDL.Record({
        bandLowBps: IDL.Int, bandHighBps: IDL.Int,
        longNotionalUsd: IDL.Nat, shortNotionalUsd: IDL.Nat, positions: IDL.Nat,
      })),
      totalLongNotionalUsd: IDL.Nat, totalShortNotionalUsd: IDL.Nat,
      positionsTotal: IDL.Nat, truncated: IDL.Bool, computedNs: IDL.Int,
    });
    const AmmBookShare = IDL.Record({
      marketId:     IDL.Text,
      ammAskQty:    IDL.Nat,
      ammAskValue:  IDL.Nat,
      ammBidQty:    IDL.Nat,
      ammBidValue:  IDL.Nat,
      bookAskQty:   IDL.Nat,
      bookAskValue: IDL.Nat,
      bookBidQty:   IDL.Nat,
      bookBidValue: IDL.Nat,
    });

    // OQL result rows — shared by execute (Exchange) and archiveExecute (History).
    const OqlRows = IDL.Vec(IDL.Vec(IDL.Record({
      name: IDL.Text,
      // Wire name is "null" (not "null_"): Motoko escapes the reserved word
      // as #null_ in SOURCE but exports the candid field as null — declaring
      // null_ here hashes differently and made every null-valued OQL cell
      // fail to decode in the browser.
      value: IDL.Variant({ "null": IDL.Null, bool: IDL.Bool, nat: IDL.Nat, int: IDL.Int, float: IDL.Float64, text: IDL.Text }),
    })));
    const OqlResult = IDL.Record({ rows: OqlRows, hasMore: IDL.Bool });
    // History adds `degraded`: archive segments (canister ids) this pass could
    // not read — one stopped/frozen segment degrades the page instead of
    // failing it (W1-03). Empty ⇒ the read was complete.
    const ArchiveOqlResult = IDL.Record({ rows: OqlRows, hasMore: IDL.Bool, degraded: IDL.Vec(IDL.Text) });

    return IDL.Service({
      addTestTokens: IDL.Func([IDL.Text, IDL.Nat], [], []),
      getDeployMode: IDL.Func([], [IDL.Text], ["query"]),
      // Whether the AI assistant is configured (a key is set). Gates the AI Assistant tab.
      aiConfigured: IDL.Func([], [IDL.Bool], ["query"]),
      // Play-mode lifetime deposit allowance (null when no cap is active).
      getPlayDepositAllowance: IDL.Func([], [IDL.Opt(IDL.Record({
        capUsd: IDL.Nat, usedUsd: IDL.Nat, remainingUsd: IDL.Nat,
      }))], ["query"]),
      // Play anti-Sybil (docs/play-anti-sybil-design.md): II attribute
      // handshake (mo:identity-attributes mixin) + the binding status the
      // Deposit-page gate renders from.
      _internet_identity_sign_in_start: IDL.Func([], [IDL.Vec(IDL.Nat8)], []),
      _internet_identity_sign_in_finish: IDL.Func([], [IDL.Variant({
        ok: IDL.Null,
        err: IDL.Variant({
          NoAttributes: IDL.Null,
          MalformedCandid: IDL.Null,
          MissingField: IDL.Text,
          FrontendOriginsNotConfigured: IDL.Null,
          FrontendOriginMismatch: IDL.Record({ expected: IDL.Vec(IDL.Text), got: IDL.Text }),
          Stale: IDL.Record({ ageNs: IDL.Nat }),
          UnknownNonce: IDL.Null,
          AmbiguousAttribute: IDL.Record({ field: IDL.Text, sources: IDL.Vec(IDL.Text) }),
          UntrustedSsoSource: IDL.Record({ domain: IDL.Text }),
          MixedSsoSources: IDL.Record({ ssoKeys: IDL.Vec(IDL.Text), otherKeys: IDL.Vec(IDL.Text) }),
        }),
      })], []),
      getMyVerification: IDL.Func([], [IDL.Record({
        bound: IDL.Bool, required: IDL.Bool, lastError: IDL.Opt(IDL.Text),
      })], ["query"]),
      // Archive routing table (Phase B): sealed archives + the active one.
      getArchives: IDL.Func([], [IDL.Vec(IDL.Record({
        canisterId: IDL.Text, firstSeq: IDL.Nat, lastSeq: IDL.Opt(IDL.Nat),
      }))], ["query"]),
      // Recorded gaps in the durable tape (L2 archive-failover sheds): dropped
      // seq ranges (fromSeq, toSeqExcl, ts). The client verifier consults these
      // to accept a cross-archive discontinuity at a gap as documented rather
      // than tampering (docs/archive-design.md §8b).
      getLedgerGaps: IDL.Func([], [IDL.Vec(IDL.Tuple(IDL.Nat, IDL.Nat, IDL.Int))], ["query"]),
      // Shed re-baselines [fromSeq, toSeqExcl): absolute re-attestation of
      // every balance emitted after each L2 shed — replay resets there and
      // reconstructs balances from the tape alone (docs/archive-design.md §8b).
      getShedBaselines: IDL.Func([], [IDL.Vec(IDL.Tuple(IDL.Nat, IDL.Nat))], ["query"]),
      // Owner-gated archive history, federated through the exchange (the raw
      // archive method is no longer callable from the browser). One archive per
      // call — the caller keeps chain paging via getArchives.
      getMyArchivedEvents: IDL.Func([IDL.Principal, IDL.Nat, IDL.Nat],
        [IDL.Record({ events: IDL.Vec(UserEvent), total: IDL.Nat })], ["composite_query"]),
      getBalances: IDL.Func([], [IDL.Vec(IDL.Tuple(IDL.Text, IDL.Nat))], ["query"]),
      getBalance: IDL.Func([IDL.Text], [IDL.Nat], ["query"]),
      getDepositAddress: IDL.Func([IDL.Text], [IDL.Text], ["query"]),
      withdraw: IDL.Func([IDL.Text, IDL.Nat, IDL.Text], [IDL.Variant({ ok: IDL.Null, err: IDL.Text })], []),
      getMarkets: IDL.Func([], [IDL.Vec(MarketInfo)], ["query"]),
      getOrderBook: IDL.Func([IDL.Text], [OrderBookSnapshot], ["query"]),
      getOrderBookDepth: IDL.Func([IDL.Text, IDL.Opt(IDL.Nat)], [OrderBookSnapshot], ["query"]),
      // De-identified as of API v-next: these return PublicTrade (no buyer/
      // seller principals). The renderers only use id/price/quantity/timestamp.
      getRecentTrades: IDL.Func([IDL.Text], [IDL.Vec(PublicTrade)], ["query"]),
      getAllTrades: IDL.Func([IDL.Text], [IDL.Vec(PublicTrade)], ["query"]),
      // ── OQL (generic query layer) + AI assistant proxy ──
      // auth-tokens OQL: schema/execute take a trailing optional bearer token
      // (pass [] = none; the caller is scoped by its own principal). Result shape
      // unchanged. Row-level per-user scoping is enforced canister-side.
      schema: IDL.Func([IDL.Opt(IDL.Text)], [IDL.Text], ["query"]),
      execute: IDL.Func([IDL.Text], [OqlResult], ["query"]),   // upstream OQL main: bearer-token arg removed
      // History (archive) OQL surface — federated by the Exchange canister.
      // archiveSchema is a plain query; archiveExecute is a COMPOSITE query
      // (it calls the archive sidecars), scoped to the caller's own archived
      // history plus the public money-flow ledger. Its result carries
      // `degraded` — segments the fan-out could not read this pass.
      archiveSchema: IDL.Func([], [IDL.Text], ["query"]),
      archiveExecute: IDL.Func([IDL.Text], [ArchiveOqlResult], ["composite_query"]),
      aiComplete: IDL.Func([IDL.Text], [IDL.Variant({ ok: IDL.Text, err: IDL.Text })], []),
      // Stats-only self-report: a confirmed assistant action actually ran.
      aiActionExecuted: IDL.Func([IDL.Text], [], []),
      // Caller-scoped usage for Account → AI (windows, classification, guard).
      getMyAiUsage: IDL.Func([], [IDL.Record({
        steps: IDL.Nat, replies: IDL.Nat, reads: IDL.Nat,
        actionsProposed: IDL.Nat, actionsExecuted: IDL.Nat,
        refused: IDL.Nat, rateLimited: IDL.Nat,
        usedMinute: IDL.Nat, usedHour: IDL.Nat, usedDay: IDL.Nat,
        limitMinute: IDL.Nat, limitHour: IDL.Nat, limitDay: IDL.Nat,
        refusals24h: IDL.Nat, refusalLimit24h: IDL.Nat,
        suspendedUntilNs: IDL.Opt(IDL.Int),
      })], ["query"]),
      placeLimitOrder: IDL.Func(
        [IDL.Text, Side, IDL.Nat, IDL.Nat],
        [IDL.Variant({ ok: PlaceLimitResult, err: IDL.Text })],
        []
      ),
      placeLimitOrderExp: IDL.Func(
        [IDL.Text, Side, IDL.Nat, IDL.Nat, IDL.Opt(IDL.Nat)],
        [IDL.Variant({ ok: PlaceLimitResult, err: IDL.Text })],
        []
      ),
      getMyPendingMatches: IDL.Func([], [IDL.Vec(PendingMatch)], ["query"]),
      placeMarketOrder: IDL.Func(
        [IDL.Text, Side, IDL.Nat, IDL.Nat, IDL.Bool],
        [IDL.Variant({ ok: MatchResult, err: IDL.Text })],
        []
      ),
      swap: IDL.Func(
        [SwapRequest],
        [IDL.Variant({ ok: SwapResult, err: IDL.Text })],
        []
      ),
      cancelMyOrder: IDL.Func(
        [IDL.Nat],
        [IDL.Variant({ ok: IDL.Null, err: IDL.Text })],
        []
      ),
      getMyOrders: IDL.Func([], [IDL.Vec(Order)], ["query"]),
      getMyClosedOrders: IDL.Func([], [IDL.Vec(IDL.Record({
        id: IDL.Nat, marketId: IDL.Text,
        side: IDL.Variant({ buy: IDL.Null, sell: IDL.Null }),
        orderType: IDL.Variant({ market: IDL.Null, limit: IDL.Null }),
        price: IDL.Nat, quantity: IDL.Nat, filled: IDL.Nat,
        status: IDL.Variant({ open: IDL.Null, partiallyFilled: IDL.Null, filled: IDL.Null, cancelled: IDL.Null }),
        placedAt: IDL.Int, closedAt: IDL.Int,
      }))], ["query"]),
      getMyOrdersOnMarket: IDL.Func([IDL.Text], [IDL.Vec(Order)], ["query"]),
      getMyStagedOrderIds: IDL.Func([], [IDL.Vec(IDL.Nat)], ["query"]),
      getMyRecentSwap: IDL.Func([], [IDL.Opt(IDL.Record({
        id: IDL.Nat, ts: IDL.Int,
        fromToken: IDL.Text, fromAmount: IDL.Nat,
        toToken: IDL.Text, toAmount: IDL.Nat,
        filled: IDL.Bool, note: IDL.Text,
      }))], ["query"]),
      getRecentEvents: IDL.Func([IDL.Nat], [IDL.Vec(IDL.Record({
        id: IDL.Nat, ts: IDL.Int, severity: IDL.Text,
        category: IDL.Text, message: IDL.Text, market: IDL.Opt(IDL.Text),
      }))], ["query"]),
      resetExchange: IDL.Func([], [], []),
      setTestBalance: IDL.Func([IDL.Principal, IDL.Text, IDL.Nat], [], []),
      getTestBalance: IDL.Func([IDL.Principal, IDL.Text], [IDL.Nat], ["query"]),
      whoami: IDL.Func([], [IDL.Principal], ["query"]),
      getMyProfile: IDL.Func([], [UserProfile], []),
      regenerateUsername: IDL.Func([], [IDL.Variant({ ok: UserProfile, err: IDL.Text })], []),
      getMyTradeHistory: IDL.Func([], [IDL.Vec(Trade)], ["query"]),
      getMyAdjustments: IDL.Func([], [IDL.Vec(OrderAdjustment)], ["query"]),
      getMyDeposits: IDL.Func([], [IDL.Vec(DepositRecord)], ["query"]),
      getUserPreferences: IDL.Func([], [UserPreferences], []),
      setUserPreferences: IDL.Func([UserPreferences], [], []),
      getCandles: IDL.Func([IDL.Text, IDL.Nat, IDL.Nat], [CandleResponse], ["query"]),
      getTradesSince: IDL.Func([IDL.Text, IDL.Int], [IDL.Vec(PublicTrade)], ["query"]),
      getUserStatus: IDL.Func([], [UserStatus], ["query"]),
      // Cross-margin: bid headroom + whole-portfolio collateral surface
      getMyBidHeadroom: IDL.Func([], [IDL.Record({
        cashBalance:   IDL.Nat,
        totalBalance:  IDL.Nat,
        grossBidValue: IDL.Nat,
        maxAllowed:    IDL.Nat,
        headroom:      IDL.Int,
        factor:        IDL.Nat,
        marginAccount: IDL.Opt(IDL.Record({ openedAt: IDL.Int })),
        collateralBreakdown: IDL.Vec(IDL.Record({
          token:      IDL.Text,
          balance:    IDL.Nat,
          refPrice:   IDL.Nat,
          ltv:        IDL.Nat,
          contribUsd: IDL.Nat,
        })),
        collateralValueUsd: IDL.Nat,
      })], ["query"]),
      // The whole-wallet cross-margin surface was retired in the model-2 pivot —
      // mutations (openMarginAccount/borrowAsset/repayAsset) and the per-principal
      // reads (getMyMarginAccount/getMyDebt/getMyLiquidationHistory) are gone;
      // leverage now lives only in margin pools (createMarginPool / openPosition
      // below). getMyMarginHealth stays — it populates cachedMarginHealth for
      // net-value/debt display; getNettedVolumeUsd is a protocol-wide stat still
      // shown on the Stats → Insurance Fund pane.
      getMyMarginHealth: IDL.Func([], [MarginHealth], ["query"]),
      getNettedVolumeUsd: IDL.Func([], [IDL.Nat], ["query"]),
      // ── Margin Pools: segregated positions (long/short) ──
      createMarginPool:   IDL.Func([IDL.Text, IDL.Bool], [IDL.Variant({ ok: IDL.Nat, err: IDL.Text })], []),
      fundMarginPool:     IDL.Func([IDL.Nat, IDL.Nat], [IDL.Variant({ ok: IDL.Null, err: IDL.Text })], []),
      withdrawMarginPool: IDL.Func([IDL.Nat, IDL.Nat], [IDL.Variant({ ok: IDL.Null, err: IDL.Text })], []),
      openPosition:       IDL.Func([IDL.Nat, IDL.Text, Side, IDL.Nat, IDL.Nat, IDL.Opt(IDL.Nat)], [IDL.Variant({ ok: IDL.Null, err: IDL.Text })], []),
      // Pool-aware pre-flight: the canister runs openPosition's exact gauntlet
      // read-only (single source of truth — no client-side margin math).
      previewOpenPosition: IDL.Func(
        [IDL.Opt(IDL.Nat), IDL.Text, Side, IDL.Nat, IDL.Nat, IDL.Opt(IDL.Nat), IDL.Nat],
        [IDL.Variant({
          ok: IDL.Record({
            canOpen: IDL.Bool, reason: IDL.Opt(IDL.Text), borrowToken: IDL.Text,
            borrowNeeded: IDL.Nat, projHealth: IDL.Opt(IDL.Nat), maxSizeBase: IDL.Nat,
            estLiqPrice: IDL.Opt(IDL.Nat),
          }),
          err: IDL.Text,
        })], ["query"]),
      quoteSwap: IDL.Func(
        [IDL.Text, IDL.Text, IDL.Nat, IDL.Nat],
        [IDL.Variant({
          ok: IDL.Record({ outAmount: IDL.Nat, consumedFrom: IDL.Nat, feeQuote: IDL.Nat, exhausted: IDL.Bool, impactBps: IDL.Nat }),
          err: IDL.Text,
        })], ["query"]),
      getMyAvailableBalances: IDL.Func([], [IDL.Vec(IDL.Tuple(IDL.Text, IDL.Nat))], ["query"]),
      closePosition:      IDL.Func([IDL.Nat, IDL.Text, IDL.Nat, IDL.Opt(IDL.Nat)], [IDL.Variant({ ok: IDL.Null, err: IDL.Text })], []),
      getPoolOrders:      IDL.Func([IDL.Nat], [IDL.Vec(Order)], ["query"]),
      cancelPoolOrder:    IDL.Func([IDL.Nat, IDL.Nat], [IDL.Variant({ ok: IDL.Null, err: IDL.Text })], []),
      getMyMarginPools:   IDL.Func([], [IDL.Vec(MarginPoolView)], ["query"]),
      getMyPositionEpisodes: IDL.Func([], [IDL.Vec(PositionEpisode)], ["query"]),
      getMyPoolTransfers:    IDL.Func([], [IDL.Vec(PoolTransfer)], ["query"]),
      getMyPositionFills:    IDL.Func([], [IDL.Vec(Trade)], ["query"]),
      getMyPoolLiquidations: IDL.Func([], [IDL.Vec(LiquidationEvent)], ["query"]),
      getMyReleaseRejections: IDL.Func([], [IDL.Vec(ReleaseRejection)], ["query"]),
      getMyUnshippedEvents: IDL.Func([], [IDL.Vec(UserEvent)], ["query"]),
      getMyPositions:     IDL.Func([], [IDL.Vec(PositionView)], ["query"]),
      getMyAccountSummary:IDL.Func([], [AccountSummary], ["query"]),
      getMyTradeHistorySince: IDL.Func([IDL.Int], [IDL.Vec(Trade)], ["query"]),
      getMarketStatus: IDL.Func([IDL.Text], [MarketStatus], ["query"]),
      getRecentPublicTrades: IDL.Func([IDL.Text], [IDL.Vec(PublicTrade)], ["query"]),
      getPublicTradesSince: IDL.Func([IDL.Text, IDL.Nat], [IDL.Vec(PublicTrade)], ["query"]),
      getMarketChanges: IDL.Func([MarketChangesRequest], [MarketChangesResponse], ["query"]),
      // AMM + price feed (Stats page)
      getAmmPools: IDL.Func([], [IDL.Vec(Pool)], ["query"]),
      getAmmPool: IDL.Func([IDL.Text], [IDL.Opt(Pool)], ["query"]),
      getPoolValue: IDL.Func([IDL.Text], [IDL.Opt(PoolValueInfo)], ["query"]),
      getAmmPrincipal: IDL.Func([], [IDL.Principal], ["query"]),
      getLastAggregate: IDL.Func([IDL.Text], [IDL.Opt(Aggregate)], ["query"]),
      getPriceSources: IDL.Func([], [IDL.Vec(PriceSource)], ["query"]),
      getPriceFeedStats: IDL.Func([], [PriceFeedStats], ["query"]),
      getPoolValueHistory: IDL.Func([IDL.Text], [IDL.Vec(PoolSnapshot)], ["query"]),
      getVaultValue: IDL.Func([], [VaultValue], ["query"]),
      getMarginHeatmap: IDL.Func([IDL.Text], [IDL.Opt(MarginHeatmapRec)], ["query"]),
      // The surface's time axis: the ring of past snapshots (computedNs >
      // sinceNs, oldest first). Additive — an older backend simply rejects
      // the unknown method and the frontend degrades to the latest snapshot.
      getMarginHeatmapHistory: IDL.Func([IDL.Text, IDL.Int], [IDL.Vec(MarginHeatmapRec)], ["query"]),
      // Markets-page telemetry bar: live book depth + cached per-side
      // position aggregates (notional and merged-book health).
      getMarketTele: IDL.Func([IDL.Text], [IDL.Opt(IDL.Record({
        marketId: IDL.Text, totalDepthUsd: IDL.Nat,
        high24h: IDL.Nat, low24h: IDL.Nat,
        longNotionalUsd: IDL.Nat, shortNotionalUsd: IDL.Nat,
        longHealth: IDL.Opt(IDL.Nat), shortHealth: IDL.Opt(IDL.Nat),
        longNearLiqBps: IDL.Opt(IDL.Nat), shortNearLiqBps: IDL.Opt(IDL.Nat),
        computedNs: IDL.Int,
      }))], ["query"]),
      // Margin disclosure — see docs/margin-heatmap-design.md. The heat map
      // publishes the exact liquidation surface (1% bands; geometry withheld
      // only on "none"-tier markets, where the mark itself is untrustworthy).
      getMarginRiskSummary: IDL.Func([], [IDL.Record({
        positions: IDL.Nat, totalNotionalUsd: IDL.Nat, totalDebtUsd: IDL.Nat,
        vaultValueUsd: IDL.Nat, vaultBorrowCapUsd: IDL.Nat, vaultUtilisationBps: IDL.Nat,
        insuranceValueUsd: IDL.Nat, liquidatablePositions: IDL.Nat,
        liquidatableNotionalUsd: IDL.Nat, worstCaseAbsorbUsd: IDL.Nat,
        truncated: IDL.Bool, computedNs: IDL.Int,
      })], ["query"]),
      getVaultValueHistory: IDL.Func([], [IDL.Vec(VaultSnapshot)], ["query"]),
      getMyVaultLp: IDL.Func([], [IDL.Nat], ["query"]),
      getAmmBookShare: IDL.Func([IDL.Text], [IDL.Opt(AmmBookShare)], ["query"]),
      // ── Earn: AMM vault LP + insurance staking ──
      getMyVaultPosition: IDL.Func([], [IDL.Record({
        lpBalance: IDL.Nat, sharePercent: IDL.Nat,
        estimatedBasket: VaultBasket, estimatedValue: IDL.Nat,
      })], ["query"]),
      getVaultWeights: IDL.Func([], [IDL.Vec(IDL.Record({
        token: IDL.Text, currentWeight: IDL.Nat,
        targetWeight: IDL.Nat, depositMultiplier: IDL.Nat,
      }))], ["query"]),
      depositLp: IDL.Func([IDL.Text, IDL.Nat, IDL.Nat],
        [IDL.Variant({ ok: IDL.Nat, err: IDL.Text })], []),
      withdrawLp: IDL.Func([IDL.Nat],
        [IDL.Variant({ ok: VaultBasket, err: IDL.Text })], []),
      stakeInsurance: IDL.Func([IDL.Nat],
        [IDL.Variant({ ok: IDL.Nat, err: IDL.Text })], []),
      unstakeInsurance: IDL.Func([IDL.Nat],
        [IDL.Variant({ ok: IDL.Nat, err: IDL.Text })], []),
      getMyInsuranceStake: IDL.Func([], [IDL.Record({
        shares: IDL.Nat, valueUsd: IDL.Nat,
      })], ["query"]),
      getInsuranceFund: IDL.Func([], [IDL.Record({
        bufferUsd: IDL.Nat, uncoveredBadDebtUsd: IDL.Nat,
        totalShares: IDL.Nat, shareValueUsd: IDL.Nat,
        // Penalties earned but not yet paid across from the vault. Excluded
        // from bufferUsd/shareValueUsd by design (those stay cash-backed).
        pendingYieldUsd: IDL.Nat,
      })], ["query"]),
      getTreasury: IDL.Func([], [IDL.Record({
        balanceUsd: IDL.Nat, lifetimeFeesUsd: IDL.Nat,
        makerFeeBps: IDL.Nat, takerFeeBps: IDL.Nat, principal: IDL.Text,
        lpFeeShareBps: IDL.Nat, lifetimeVaultFeesUsd: IDL.Nat,
      })], ["query"]),
      getArbStats: IDL.Func([], [IDL.Record({
        wired: IDL.Opt(IDL.Principal),
        balances: IDL.Vec(IDL.Tuple(IDL.Text, IDL.Nat)),
        lifetimeImportUsd: IDL.Nat, lifetimeExportUsd: IDL.Nat,
        hourUsedUsd: IDL.Nat, hourCapUsd: IDL.Nat, perCallCapUsd: IDL.Nat,
        extHaircutBps: IDL.Nat,
      })], ["query"]),
      getAccessPolicy: IDL.Func([], [IDL.Record({
        shedFloor: IDL.Nat,
        myLevel: IDL.Nat, myRank: IDL.Nat,
        myMakerVolUsd: IDL.Nat, myTakerVolUsd: IDL.Nat, myWeightedVolUsd: IDL.Nat,
        myLifetimeVolUsd: IDL.Nat, myLifetimeMakerVolUsd: IDL.Nat,
        myUptimePct: IDL.Opt(IDL.Nat), myUptimeSamples: IDL.Nat,
        myStagedCount: IDL.Nat,
        myMakerFeeTenthBps: IDL.Nat, myTakerFeeTenthBps: IDL.Nat,
        myBadges: IDL.Vec(IDL.Tuple(IDL.Nat, IDL.Int)),
        exchangeVolUsd: IDL.Nat, scaleBps: IDL.Nat,
        levelThresholdsUsd: IDL.Vec(IDL.Nat),
        feeTenthBps: IDL.Vec(IDL.Tuple(IDL.Nat, IDL.Nat)),
        thresholds: IDL.Record({
          makerWeight: IDL.Nat, refExchangeVolUsd: IDL.Nat, scaleMinBps: IDL.Nat,
          mmMaxSpreadBps: IDL.Nat, mmMinDepthUsd: IDL.Nat,
          mmMinUptimePct: IDL.Nat, mmMinSamples: IDL.Nat,
          stagedCapPerOwner: IDL.Nat, minOrderNotionalUsd: IDL.Nat,
          shedSoftStaged: IDL.Nat, shedHardStaged: IDL.Nat,
          badgeVolUsd: IDL.Vec(IDL.Tuple(IDL.Nat, IDL.Nat)),
        }),
      })], ["query"]),
      getLeaderboard: IDL.Func([], [IDL.Record({
        computedAtNs: IDL.Int, totalRanked: IDL.Nat,
        rows: IDL.Vec(LeaderRow), my: IDL.Opt(LeaderRow),
      })], ["query"]),
      getAppVersion: IDL.Func([], [IDL.Text], ["query"]),
      getCanisterInfo: IDL.Func([], [IDL.Record({
        // opt on purpose: a pre-1.51 backend has no appVersion field, and a
        // required record field would fail the WHOLE decode there — opt
        // decodes the missing field as null (and Text coerces into opt Text).
        appVersion: IDL.Opt(IDL.Text),
        canisterId: IDL.Text, cycles: IDL.Nat, freezingLimitCycles: IDL.Nat,
        burnPerDay: IDL.Nat, idleBurnPerDay: IDL.Nat, computeAllocation: IDL.Nat,
        lastHeartbeatNs: IDL.Int, nowNs: IDL.Int, timersPaused: IDL.Bool,
        memorySizeBytes: IDL.Nat, heapLiveBytes: IDL.Nat,
        wasmMemoryLimitBytes: IDL.Nat, lowMemoryAtNs: IDL.Int, ordersRetained: IDL.Nat,
        tradesRetained: IDL.Nat, usersRegistered: IDL.Nat,
        journalUnshipped: IDL.Nat, ledgerJournalPending: IDL.Nat, archivedEvents: IDL.Nat,
        emergencyRolls: IDL.Nat, ledgerGaps: IDL.Nat, shedEvents: IDL.Nat, shipFailStreak: IDL.Nat,
        archiveCanisterId: IDL.Opt(IDL.Text),
        archivesSealed: IDL.Nat,
        archiveCycles: IDL.Nat, archiveLifetimeTopUp: IDL.Nat,
        autoFuelEnabled: IDL.Bool, fuelRouteWired: IDL.Bool, fuelLifetimeCycles: IDL.Nat,
        // opt for the same pre-#47.2-backend reason appVersion is opt above.
        fuelPendingNotify: IDL.Opt(IDL.Record({ blockIndex: IDL.Nat, icpE8s: IDL.Nat, sinceNs: IDL.Int })),
        treasuryUsdE8s: IDL.Nat, treasuryIcpE8s: IDL.Nat,
        oracleDivergence: IDL.Vec(IDL.Tuple(IDL.Text, IDL.Nat, IDL.Int)),
      })], ["query"]),
      // The full archive chain (sealed segments + active tip + pre-spawned
      // successor) with the fuel pass's last observation per canister.
      // Distinct from getArchives (the Ledger pager's routing table above).
      getArchiveChain: IDL.Func([], [IDL.Vec(IDL.Record({
        canisterId: IDL.Text,
        role: IDL.Text,
        firstSeq: IDL.Opt(IDL.Nat), lastSeq: IDL.Opt(IDL.Nat),
        cycles: IDL.Opt(IDL.Nat), freezeLimitCycles: IDL.Opt(IDL.Nat),
        frozen: IDL.Opt(IDL.Bool), observedAtNs: IDL.Opt(IDL.Int),
      }))], ["query"]),
    });
  };
}

// ── Initialization ──────────────────────────────────────────────
async function init() {
  setupEventListeners();
  setupAssistant({
    getMarkets: () => markets,       // inject markets (kept local in main.js)
    ensureActor: setupActor,         // self-heal a missing actor at submit time
    refreshAccountData,              // refresh Account views after a confirmed action (#46.2 §3)
  });
  setupIntelli();
  // The public Ledger page (top-level Ledger tab): raw (non-money-normalized)
  // archive actors — the client-side verifier re-hashes exact candid values.
  {
    let rawAgent = null;
    const rawActors = new Map();
    const getRawAgent = async () => {
      if (rawAgent) return rawAgent;
      let canisterEnv;
      try { const m = await import("@icp-sdk/core/agent/canister-env"); canisterEnv = m.safeGetCanisterEnv?.(); } catch {}
      rawAgent = await HttpAgent.create({ host: window.location.origin, rootKey: canisterEnv?.IC_ROOT_KEY });
      // ROOT KEY — the anchor of the ledger verifier's certificate check.
      //
      // fetchRootKey() asks THIS ORIGIN for the key and installs whatever comes
      // back. On mainnet the IC HTTP gateway proxies /api/v2/status, so calling
      // it unconditionally would take the anchor from the very party the
      // certificate check exists to check: a hostile gateway serves its own
      // key, signs a forged head with the matching secret, and the Ledger page
      // reports "IC certificate VALID". Development replicas mint a per-instance
      // key that cannot be baked in, so they genuinely need the fetch — and
      // nothing else does. Exact hostname match (see host.js), never a
      // substring, so `localhost.evil.example` is NOT taken for a local replica.
      // Mirrors scripts/verify_ledger.mjs:201-221.
      if (isLocalReplicaOrigin()) {
        try { await rawAgent.fetchRootKey(); } catch { /* replica unreachable — keep built-in key */ }
      }
      return rawAgent;
    };
    ledgerCtl = setupLedger({
      listArchives: async () => {
        const a = appState.publicActor || appState.actor;
        return a?.getArchives ? await a.getArchives() : [];
      },
      getLedgerGaps: async () => {
        const a = appState.publicActor || appState.actor;
        return a?.getLedgerGaps ? await a.getLedgerGaps() : [];
      },
      getShedBaselines: async () => {
        const a = appState.publicActor || appState.actor;
        return a?.getShedBaselines ? await a.getShedBaselines() : [];
      },
      makeRawArchiveActor: async (id) => {
        if (rawActors.has(id)) return rawActors.get(id);
        const agent = await getRawAgent();
        const actor = Actor.createActor(getArchiveIdlFactory(), { agent, canisterId: id });
        rawActors.set(id, actor);
        return actor;
      },
      get rootKey() { return rawAgent ? rawAgent.rootKey : null; },
    });
  }
  // Lift the splash the moment the routed view can render (markets loaded,
  // prefs read) — order books, auth, and login state hydrate behind the live
  // page instead of in front of it. Idempotent: the happy path calls it as
  // soon as markets land; the demo fallback reaches the trailing call.
  let uiShown = false;
  const showUI = () => {
    if (uiShown) return;
    uiShown = true;
    updateUI();
    // Apply the initial URL hash AFTER markets have loaded, so that landing
    // on /#markets/BTC-ICPUSD can auto-select the requested market.
    const r = routeFromHash();
    activateTab(r.tab, r.subpath);
    // A shared Data-Explorer link (?dxq=…) overrides the hash: open the
    // explorer and run the encoded query.
    dxApplyShareLink();
  };
  try {
    const authMod = await import("@icp-sdk/auth/client");
    const coreMod = await import("@icp-sdk/core/agent");
    const principalMod = await import("@icp-sdk/core/principal");
    AuthClient = authMod.AuthClient;
    HttpAgent = coreMod.HttpAgent;
    Actor = coreMod.Actor;
    Principal = principalMod.Principal;   // for building the archive principal set

    // Create anonymous public appState.actor for pre-login queries
    await createAnonymousActor();
    await refreshMarkets();
    refreshAiGate();   // show/hide the AI Assistant tab per backend key config (non-blocking)

    // Load persisted preferences from IndexedDB (works for anonymous users)
    const localPrefs = await loadLocalPrefs();
    recentMarkets = localPrefs.recentMarkets || [];
    lastMarket = localPrefs.lastMarket || null;

    showUI();

    // Background hydration: non-selected books (the active market's book is
    // fetched by its own render path) + keep-alive polling.
    refreshAllOrderBookCaches();
    startAutoRefresh();
    startAcctValueClock();   // header account value on the wall-clock 10s grid
    resolveDeployModeAndBanner();   // #play launch notice (posture-gated)

    // Boot client uses default IndexedDB storage so a PERSISTENT (on-disk)
    // session restores across restarts. An in-memory session rebuilds the
    // client with memory storage at sign-in (see doLogin) and never restores.
    // @icp-sdk/auth 8.x: constructor (not create), sync isAuthenticated,
    // ASYNC getIdentity, signOut (not logout). identityProvider is bound at
    // construction; requestAttributes (the play verification flow) is why
    // we're on 7.x+ at all — 8.0 changed its nonce to a callback (doLogin).
    authClient = new AuthClient(authClientOpts());
    registerJanitorSW();
    // Stamp the footer badge from the build's version and start watching the
    // origin for newer deploys (stale tabs refresh themselves — update-check.js).
    if (APP_VERSION) {
      document.querySelectorAll(".app-version").forEach((el) => { el.textContent = "VERSION " + APP_VERSION.replace(/\.0$/, ""); });
      startUpdateCheck(APP_VERSION);
    }
    // Was every tab closed since last load? Read the heartbeat BEFORE this tab
    // restarts it. If so, an on-disk session is stale → end it (a refresh keeps
    // a tiny gap and is spared). Then this tab starts its own heartbeat.
    const tabsWereClosed = tabsAllClosedSinceLastLoad();
    appState.isAuthenticated = authClient.isAuthenticated();
    if (appState.isAuthenticated && tabsWereClosed) {
      await authClient.signOut();
      appState.isAuthenticated = false;
    }
    startSessionHeartbeat();
    if (appState.isAuthenticated) {
      identity = await authClient.getIdentity();
      await setupActor();
      await onLogin();
      // Re-run updateUI: showUI() above ran it while isAuthenticated was still
      // false (auth restores here, after), which left the order panel in its
      // signed-out state — auth overlay up + "Sign in to trade" — even though
      // onLogin() hydrated the pill/orders/positions. Without this, a refresh
      // of a persistent session shows a half-signed-in UI.
      updateUI();
    }
  } catch (e) {
    console.warn("ICP SDK not available, running in demo mode:", e.message);
    setupDemoMode();
    refreshAllOrderBookCaches();
    startAutoRefresh();
  }
  // App-wide canister-health poll (out-of-fuel banner). Runs in both real
  // and demo mode — refreshCanisterInfo picks appState.publicActor or the demo appState.actor.
  startCanisterInfoPoll();
  showUI();
}

function getIdentityProviderUrl() {
  // Use the hosted id.ai in both local dev and production. Since icp-cli
  // 0.2.4 the local network trusts mainnet subnet signatures, so a
  // delegation issued by the real id.ai is accepted by our local
  // replica — no local Internet Identity canister needed.
  //
  // The `/authorize` path is mandatory: the auth client uses the URL
  // verbatim (no auto-append), and a bare `https://id.ai` lands on the
  // home page so authentication silently fails to start.
  return "https://id.ai/authorize";
}

// Internet Identity derives a principal PER ORIGIN, so the same player signing
// in on the custom domain vs. the raw canister URL would land on DIFFERENT
// principals (different accounts, different balances) — and the play anti-Sybil
// gate then rejects the second one as a duplicate Google unlock. To collapse
// them we pin ONE canonical derivationOrigin: every production origin derives
// from the canister's icp.net URL (the origin the venue launched on, so
// existing accounts are preserved). id.ai validates this against the canonical
// origin's /.well-known/ii-alternative-origins, which MUST list every origin
// below (see src/frontend/public/.well-known/ii-alternative-origins).
//
// Only pinned on the known production origins: on localhost / any other host we
// return undefined so local dev keeps deriving from its own origin (it isn't in
// the alternative-origins list, so pinning there would fail the II check).
const II_CANONICAL_ORIGIN = "https://hcv4s-uaaaa-aaabq-qaaba-cai.icp.net";
const II_PINNED_ORIGINS = [
  "https://hcv4s-uaaaa-aaabq-qaaba-cai.icp.net",
  "https://hcv4s-uaaaa-aaabq-qaaba-cai.icp0.io",
  "https://multidex.ai",
];
function getDerivationOrigin() {
  try {
    return II_PINNED_ORIGINS.includes(window.location.origin) ? II_CANONICAL_ORIGIN : undefined;
  } catch { return undefined; }
}

async function getCanisterId() {
  try {
    const envMod = await import("@icp-sdk/core/agent/canister-env");
    const canisterEnv = envMod.safeGetCanisterEnv?.();
    return (
      canisterEnv?.["PUBLIC_CANISTER_ID:backend"] ||
      document.querySelector('meta[name="canister-id"]')?.getAttribute("content")
    );
  } catch {
    return document.querySelector('meta[name="canister-id"]')?.getAttribute("content");
  }
}

async function createAnonymousActor() {
  if (!HttpAgent || !Actor) return;
  try {
    let canisterEnv;
    try {
      const envMod = await import("@icp-sdk/core/agent/canister-env");
      canisterEnv = envMod.safeGetCanisterEnv?.();
    } catch {}

    const agent = await HttpAgent.create({
      host: window.location.origin,
      rootKey: canisterEnv?.IC_ROOT_KEY,
    });

    const canisterId =
      canisterEnv?.["PUBLIC_CANISTER_ID:backend"] ||
      document.querySelector('meta[name="canister-id"]')?.getAttribute("content");

    if (canisterId) {
      appState.publicActor = wrapActor(Actor.createActor(getIdlFactory(), { agent, canisterId }));
    }
  } catch (e) {
    console.warn("Failed to create anonymous actor:", e.message);
  }
}

async function setupActor() {
  if (!identity) return;
  try {
    let canisterEnv;
    try {
      const envMod = await import("@icp-sdk/core/agent/canister-env");
      canisterEnv = envMod.safeGetCanisterEnv?.();
    } catch {}

    const agent = await HttpAgent.create({
      identity,
      host: window.location.origin,
      rootKey: canisterEnv?.IC_ROOT_KEY,
    });
    icAgent = agent;          // reused to build the archive appState.actor on demand
    appState.archiveActor = null;      // rebuild against the new identity
    appState.bridgeActor = null;       // rebuild the Bridge actor against the new identity

    const canisterId =
      canisterEnv?.["PUBLIC_CANISTER_ID:backend"] ||
      document.querySelector('meta[name="canister-id"]')?.getAttribute("content");

    if (canisterId) {
      appState.actor = wrapActor(Actor.createActor(getIdlFactory(), { agent, canisterId }));
    }
  } catch (e) {
    console.warn("Failed to create actor:", e.message);
  }
}

// ── Archive sidecar appState.actor (separate canister) ───────────────────
// The archive holds the durable, shipped half of the user's event history.
// The browser queries it DIRECTLY as the signed-in principal (the archive
// indexes by caller), reusing the same agent. Built lazily from the archive
// canister id reported by getCanisterInfo. Self-contained IDL (must match the
// backend UserEvent Candid exactly, or decode fails silently).
let _archiveId = null;
function getArchiveIdlFactory() {
  return ({ IDL }) => {
    const Side = IDL.Variant({ buy: IDL.Null, sell: IDL.Null });
    const OrderType = IDL.Variant({ market: IDL.Null, limit: IDL.Null });
    const OrderStatus = IDL.Variant({ open: IDL.Null, partiallyFilled: IDL.Null, filled: IDL.Null, cancelled: IDL.Null });
    const DepositRecord = IDL.Record({ token: IDL.Text, amount: IDL.Nat, timestamp: IDL.Int, kind: IDL.Variant({ deposit: IDL.Null, withdrawal: IDL.Null }) });
    const ClosedOrderRecord = IDL.Record({ id: IDL.Nat, marketId: IDL.Text, side: Side, orderType: OrderType, price: IDL.Nat, quantity: IDL.Nat, filled: IDL.Nat, status: OrderStatus, placedAt: IDL.Int, closedAt: IDL.Int });
    const LiquidationEvent = IDL.Record({ user: IDL.Principal, debtToken: IDL.Text, debtRepaid: IDL.Nat, debtRepaidUsd: IDL.Nat, collateralToken: IDL.Text, collateralSeized: IDL.Nat, proceedsUsd: IDL.Nat, penaltyUsd: IDL.Nat, healthBefore: IDL.Nat, healthAfter: IDL.Nat, timestamp: IDL.Int });
    const UserEventKind = IDL.Variant({
      fill: IDL.Record({ marketId: IDL.Text, side: Side, price: IDL.Nat, qty: IDL.Nat, orderId: IDL.Nat, tradeId: IDL.Nat }),
      deposit: DepositRecord,
      orderClosed: ClosedOrderRecord,
      liquidation: LiquidationEvent,
      borrow: IDL.Record({ token: IDL.Text, amount: IDL.Nat }),
      repay: IDL.Record({ token: IDL.Text, amount: IDL.Nat }),
      lpDeposit: IDL.Record({ marketId: IDL.Text, baseAmount: IDL.Nat, quoteAmount: IDL.Nat, lpMinted: IDL.Nat }),
      lpWithdraw: IDL.Record({ lpBurned: IDL.Nat, basket: IDL.Vec(IDL.Tuple(IDL.Text, IDL.Nat)) }),
      insuranceStake: IDL.Record({ amountUsd: IDL.Nat, shares: IDL.Nat }),
      insuranceUnstake: IDL.Record({ shares: IDL.Nat, payoutUsd: IDL.Nat }),
      // Ledger-of-record rows (one signed delta per balance mutation) —
      // machine records for replay/PoR; the timeline view skips them.
      delta: IDL.Record({ token: IDL.Text, amount: IDL.Int }),
      debtDelta: IDL.Record({ token: IDL.Text, amount: IDL.Int }),
      lpShareDelta: IDL.Record({ marketId: IDL.Text, amount: IDL.Int }),
      insShareDelta: IDL.Record({ amount: IDL.Int }),
      gap: IDL.Record({ fromSeq: IDL.Nat, toSeq: IDL.Nat }),
      config: IDL.Record({ setter: IDL.Text, value: IDL.Text }),
    });
    const UserEvent = IDL.Record({ seq: IDL.Nat, ts: IDL.Int, user: IDL.Principal, counterparty: IDL.Opt(IDL.Principal), kind: UserEventKind, prevHash: IDL.Opt(IDL.Vec(IDL.Nat8)) });
    return IDL.Service({
      getMyEvents: IDL.Func([IDL.Nat, IDL.Nat], [IDL.Record({ events: IDL.Vec(UserEvent), total: IDL.Nat })], ["query"]),
      // Events across a SET of principals (the human + their pool principals),
      // newest-first, paged — gives deep margin history that pages back in time
      // (margin fills archive under POOL principals, or under the human for
      // events captured after the owner-remap; both are caught here). Public.
      getEventsForPrincipals: IDL.Func([IDL.Vec(IDL.Principal), IDL.Nat, IDL.Nat], [IDL.Record({ events: IDL.Vec(UserEvent), total: IDL.Nat })], ["query"]),
      stats: IDL.Func([], [IDL.Record({
        firstSeq: IDL.Opt(IDL.Nat), nextSeq: IDL.Nat, eventCount: IDL.Nat, bytes: IDL.Nat64,
        users: IDL.Nat, cycles: IDL.Nat, memorySizeBytes: IDL.Nat, heapLiveBytes: IDL.Nat,
        chainStartSeq: IDL.Opt(IDL.Nat), chainHead: IDL.Opt(IDL.Vec(IDL.Nat8)),
      })], ["query"]),
      // Public tape + the tamper-evidence surface (the Ledger page verifier).
      getEventsRange: IDL.Func([IDL.Nat, IDL.Nat], [IDL.Vec(UserEvent)], ["query"]),
      getCertifiedHead: IDL.Func([], [IDL.Record({
        headHash: IDL.Opt(IDL.Vec(IDL.Nat8)), headSeq: IDL.Opt(IDL.Nat),
        chainStartSeq: IDL.Opt(IDL.Nat), certificate: IDL.Opt(IDL.Vec(IDL.Nat8)),
      })], ["query"]),
    });
  };
}
async function getArchiveActor() {
  if (appState.archiveActor) return appState.archiveActor;
  if (!icAgent || !Actor || !appState.isAuthenticated) return null;
  if (!_archiveId) {
    try {
      const info = await (appState.actor || appState.publicActor).getCanisterInfo();
      _archiveId = (info.archiveCanisterId && info.archiveCanisterId.length) ? info.archiveCanisterId[0] : null;
    } catch (_) { return null; }
  }
  if (!_archiveId) return null;   // sidecar not spawned — caller falls back to the unshipped tail
  try {
    appState.archiveActor = wrapActor(Actor.createActor(getArchiveIdlFactory(), { agent: icAgent, canisterId: _archiveId }));
    return appState.archiveActor;
  } catch (_) { return null; }
}

// ── Bridge canister (deposit custody STUB) ──────────────────────
// Talks to src/bridge/main.mo. Real chain-key custody is a separate team's job;
// the dev-only Simulate/Confirm controls stand in for external-chain deposits.
// See docs/bridge-and-cks-design.md. Amounts on the wire are Nat base units (1e8);
// the Bridge actor is NOT money.js-wrapped (its field names aren't MONEY_KEYS), so
// we ÷1e8 explicitly at the display boundary and ×1e8 on the simulate input.
let _bridgeId = null;
const BRIDGE_LOCAL_FALLBACK = "udzio-3p777-77776-aaata-cai"; // local-replica default; prod resolves from canister-env
const II_BACKEND_PRINCIPAL = "rdmx6-jaaaa-aaaaa-aaadq-cai"; // Internet Identity — the trusted attribute signer (same id on mainnet & local)

function getBridgeIdlFactory() {
  return ({ IDL }) => {
    const ChainAddress = IDL.Record({ chain: IDL.Text, asset: IDL.Text, address: IDL.Text });
    const DepositView = IDL.Record({
      asset: IDL.Text, chain: IDL.Text, address: IDL.Text,
      confirmed: IDL.Nat, pending: IDL.Nat, claimed: IDL.Nat, claimable: IDL.Nat,
    });
    return IDL.Service({
      createDepositAddress: IDL.Func([], [IDL.Vec(ChainAddress)], []),
      getMyDepositAddresses: IDL.Func([], [IDL.Opt(IDL.Vec(ChainAddress))], ["query"]),
      getMyDeposits: IDL.Func([], [IDL.Vec(DepositView)], ["query"]),
      claim: IDL.Func([IDL.Text], [IDL.Variant({ ok: IDL.Nat, err: IDL.Text })], []),
      devSimulateDeposit: IDL.Func([IDL.Text, IDL.Nat], [IDL.Variant({ ok: IDL.Null, err: IDL.Text })], []),
      devConfirmDeposits: IDL.Func([], [], []),
    });
  };
}

async function getBridgeActor() {
  if (appState.bridgeActor) return appState.bridgeActor;
  if (!icAgent || !Actor || !appState.isAuthenticated) return null;
  if (!_bridgeId) {
    try {
      const envMod = await import("@icp-sdk/core/agent/canister-env");
      const env = envMod.safeGetCanisterEnv?.();
      _bridgeId = env?.["PUBLIC_CANISTER_ID:bridge"] || BRIDGE_LOCAL_FALLBACK;
    } catch { _bridgeId = BRIDGE_LOCAL_FALLBACK; }
  }
  if (!_bridgeId) return null;
  try {
    appState.bridgeActor = Actor.createActor(getBridgeIdlFactory(), { agent: icAgent, canisterId: _bridgeId });
    return appState.bridgeActor;
  } catch (e) { console.warn("getBridgeActor:", e.message); return null; }
}

const depFmt = (nat) => (Number(nat) / 1e8).toLocaleString(undefined, { maximumFractionDigits: 8 });

// Play verification (docs/play-anti-sybil-design.md): the ONLY verification
// path is the Google sign-in itself (doLogin with openIdProvider:'google'
// runs signIn + requestAttributes in one II interaction — see below). A
// standalone "verify this identity" attribute request was tried and REMOVED:
// against an II with no Google linked, id.ai renders a BLANK page (no
// response, no error), and users click such buttons no matter the copy.
// Once a user links Google to their II at id.ai, the SAME sign-in button
// keeps their account — an access method unlocks the same identity, so the
// per-dapp principal is unchanged. No sign-out required.
//
// POPUP RULE: the II window may only open synchronously inside the click
// gesture (signer-js channel rule) — so requestAttributes is invoked BEFORE
// any await, with the nonce supplied as a CALLBACK (the auth 8.x contract)
// that the client awaits in flight, after the window is already open,
// and the scoped key is a fixed string (scopedKeys({openIdProvider:'google',
// keys:['verified_email']}) yields exactly this) so no module load sits in
// the gesture path either. Google-scoped ON PURPOSE: the backend keys the
// allowance off ONE Google account per player (Apple's relay would be a
// Sybil faucet).
const GOOGLE_VERIFIED_EMAIL_KEY = "openid:https://accounts.google.com:verified_email";

// Last verification failure for THIS tab. Handshake refusals (origin
// mismatch, stale bundle, consent declined) never reach the backend's
// bindErrors map — that's only written once a bundle verifies — so without
// this the unlock card re-renders with no explanation as soon as the error
// toast fades, and the user just sees the same card after a Google sign-in
// that looked like it worked. Cleared on success and at sign-out.
let lastVerifyMessage = null;

// Present a signed attribute bundle to the backend's finish endpoint and
// report the outcome. Called from the Google sign-in path (doLogin), which
// verifies in the same II interaction as the sign-in.
async function presentAttributesToBackend(attributes) {
  const [identityMod, envMod] = await Promise.all([
    import("@icp-sdk/core/identity"),
    import("@icp-sdk/core/agent/canister-env"),
  ]);
  const canisterEnv = envMod.safeGetCanisterEnv?.();
  const canisterId = canisterEnv?.["PUBLIC_CANISTER_ID:backend"]
    || document.querySelector('meta[name="canister-id"]')?.getAttribute("content");
  // The signed bundle travels as sender_info on the finish call: wrap the
  // session identity, agent, and a RAW actor (no money normalizer — the
  // result carries no e8 fields, and the wrapper must not touch the wire).
  const verifiedAgent = await HttpAgent.create({
    identity: new identityMod.AttributesIdentity({
      inner: identity,
      attributes,
      signer: { canisterId: Principal.fromText(II_BACKEND_PRINCIPAL) },
    }),
    host: window.location.origin,
    rootKey: canisterEnv?.IC_ROOT_KEY,
  });
  const finishActor = Actor.createActor(getIdlFactory(), { agent: verifiedAgent, canisterId });
  const res = await finishActor._internet_identity_sign_in_finish();
  if (res && "err" in res) {
    const tag = Object.keys(res.err)[0];
    let friendly = {
      NoAttributes: "Internet Identity didn't attach the verification — try again.",
      Stale: "The verification took too long — try again.",
      UnknownNonce: "The verification expired — try again.",
      FrontendOriginMismatch: "This app origin isn't authorized for verification yet (operator: add it to frontend_origins).",
      FrontendOriginsNotConfigured: "Verification isn't configured on this deployment yet.",
    }[tag] || ("Verification failed: " + tag);
    // The mismatch variant carries the exact offending origin and the
    // allowlist — surface them, or the operator is left guessing which of
    // the app's several serving origins (gateways, custom domain, www) the
    // user was actually on.
    if (tag === "FrontendOriginMismatch" && res.err[tag]?.got) {
      const m = res.err[tag];
      friendly = `This app origin isn't authorized for verification yet — operator: add ${m.got} to frontend_origins (currently: ${(m.expected || []).join(", ") || "empty"}).`;
    }
    return { ok: false, message: friendly };
  }
  // The bundle verified; the BINDING can still be refused (email already
  // used by another account, relay address, no Google linked) — ask.
  const v = await appState.actor.getMyVerification();
  if (v.bound) { return { ok: true } };
  return {
    ok: false,
    message: (v.lastError && v.lastError.length && v.lastError[0]) || "Verification didn't complete — try again",
  };
}

// Mint a verification nonce BEFORE sign-in completes: inspect refuses
// anonymous ingress, so a throwaway Ed25519 identity makes the call (any
// non-anonymous principal passes the play gate; the nonce is not
// caller-bound — the bundle's own signature/origin checks carry trust).
async function mintNonceEphemeral() {
  const [identityMod, envMod] = await Promise.all([
    import("@icp-sdk/core/identity"),
    import("@icp-sdk/core/agent/canister-env"),
  ]);
  const canisterEnv = envMod.safeGetCanisterEnv?.();
  const canisterId = canisterEnv?.["PUBLIC_CANISTER_ID:backend"]
    || document.querySelector('meta[name="canister-id"]')?.getAttribute("content");
  const agent = await HttpAgent.create({
    identity: identityMod.Ed25519KeyIdentity.generate(),
    host: window.location.origin,
    rootKey: canisterEnv?.IC_ROOT_KEY,
  });
  const a = Actor.createActor(getIdlFactory(), { agent, canisterId });
  const n = await a._internet_identity_sign_in_start();
  return n instanceof Uint8Array ? n : new Uint8Array(n);
}

async function refreshDepositPage() {
  const statusEl = document.getElementById("deposit-status");
  const listEl = document.getElementById("deposit-list");
  const createBtn = document.getElementById("deposit-create");
  const devBox = document.getElementById("deposit-dev");
  if (!listEl) return;
  const bridge = await getBridgeActor();
  const allowEl = document.getElementById("deposit-allowance");
  const onrampBox = document.getElementById("deposit-onramp");   // one border around allowance + simulator
  const verifyEl = document.getElementById("deposit-verify");
  if (!bridge || !appState.isAuthenticated) {
    if (statusEl) statusEl.textContent = "Sign in to view your deposit addresses.";
    if (createBtn) createBtn.style.display = "none";
    if (devBox) devBox.style.display = "none";
    if (allowEl) allowEl.style.display = "none";
    if (onrampBox) onrampBox.style.display = "none";
    if (verifyEl) verifyEl.style.display = "none";
    listEl.innerHTML = "";
    return;
  }
  // Play anti-Sybil gate (docs/play-anti-sybil-design.md): on #play the
  // allowance keys off a verified Google-linked identity, so an unbound
  // account sees the unlock card INSTEAD of the on-ramp — the requirement
  // surfaces exactly where it bites, with the why and the escape hatch.
  try {
    const v = appState.actor?.getMyVerification ? await appState.actor.getMyVerification() : null;
    if (v && v.required && !v.bound) {
      if (statusEl) statusEl.textContent = "";
      if (createBtn) createBtn.style.display = "none";
      if (devBox) devBox.style.display = "none";
      if (allowEl) allowEl.style.display = "none";
      if (onrampBox) onrampBox.style.display = "none";
      listEl.innerHTML = "";
      if (verifyEl) {
        const lastErr = ((v.lastError && v.lastError.length) ? v.lastError[0] : null) || lastVerifyMessage;
        // ONE action. A standalone "verify this identity" button was tried
        // and removed: against an II with no Google linked, id.ai renders a
        // blank page (no response, no error), and users click such buttons
        // no matter the copy. The single sign-in button covers both cases —
        // a Google account that already unlocks an II (incl. one the user
        // just linked at id.ai) lands on THAT identity, same principal, so
        // "keep my current identity" is: link at id.ai, then press the same
        // button. No sign-out needed.
        verifyEl.innerHTML =
          `<div class="deposit-verify-head">Unlock your $100k play balance</div>` +
          `<p class="deposit-verify-why">One funded account per player keeps the competition fair, so ` +
          `you must use an Internet Identity linked to Google. Your current identity isn't linked, ` +
          `but you can:</p>` +
          (lastErr ? `<p class="deposit-verify-err">${lastErr}</p>` : "") +
          `<button id="deposit-verify-signin" class="btn btn-secondary">` +
          `<svg class="google-g" width="15" height="15" viewBox="0 0 48 48" aria-hidden="true">` +
          `<path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/>` +
          `<path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/>` +
          `<path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/>` +
          `<path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/>` +
          `</svg>Sign in using Google</button>` +
          `<p class="deposit-verify-fine">If you use the button above, Internet Identity will create a ` +
          `new identity that uses Google as an access method.</p>` +
          `<p class="deposit-verify-fine"><b>Signing in later, use the same door:</b> your play account ` +
          `lives on the identity Google unlocks. If you signed in above, you can choose "Sign in using Google" again.</p>` +
          `<p class="deposit-verify-fine">Alternatively, go to <a href="https://id.ai" target="_blank" rel="noopener">ID.ai</a> ` +
          `and add Google as an access method to an existing identity.</p> ` +
          `<p class="deposit-verify-fine">Privacy: we keep only a salted fingerprint of your email — ` +
          `the address itself is never stored and never touches the public <a href="#docs/ledger">exchange ledger</a>.</p>`;
        verifyEl.style.display = "";
        document.getElementById("deposit-verify-signin")?.addEventListener("click", () => {
          const min = localStorage.getItem(SIGNIN_TTL_KEY) || "60";
          const inMemory = localStorage.getItem(SIGNIN_MEM_KEY) === "1";
          // No awaits before doLogin — the II window must open inside this
          // gesture (an explicit signOut first would kill it; the new
          // sign-in replaces the session anyway).
          doLogin({ ttlMinutes: parseFloat(min), inMemory, openIdProvider: "google" });
        });
      }
      return;
    }
    if (verifyEl) verifyEl.style.display = "none";
  } catch { if (verifyEl) verifyEl.style.display = "none"; }
  // Play-mode lifetime allowance — null (hidden) everywhere but #play.
  // The opt-wrapped record's e8 fields are out of the money normalizer's
  // reach (the opt-array lesson), so scale here.
  let allowShown = false;
  try {
    const alw = appState.actor?.getPlayDepositAllowance
      ? await appState.actor.getPlayDepositAllowance() : [];
    depositAllowanceSnap = alw && alw.length ? alw[0] : null;
    if (allowEl) {
      if (alw && alw.length) {
        const usd = (v) => `$${(Number(v) / 1e8).toLocaleString(undefined, { maximumFractionDigits: 0 })}`;
        const a = alw[0];
        allowEl.innerHTML =
          `<strong>Your play allowance:</strong> ${usd(a.usedUsd)} of ${usd(a.capUsd)} used · ` +
          `${usd(a.remainingUsd)} remaining. Deposits are valued at mark prices — and count ` +
          `against your allowance — when you make them; claiming later never re-prices them. ` +
          `The allowance is per player for the whole competition.`;
        allowEl.style.display = "";
        allowShown = true;
      } else {
        allowEl.style.display = "none";
      }
    }
  } catch { /* allowance display is best-effort */ }
  try {
    const addrsOpt = await bridge.getMyDepositAddresses(); // [] or [ [ChainAddress] ]
    const onboarded = Array.isArray(addrsOpt) && addrsOpt.length > 0;
    if (createBtn) createBtn.style.display = onboarded ? "none" : "";
    if (devBox) devBox.style.display = onboarded ? "" : "none";
    // The shared box shows when either occupant does.
    if (onrampBox) onrampBox.style.display = (allowShown || onboarded) ? "" : "none";
    if (!onboarded) {
      if (statusEl) statusEl.textContent = "Create your deposit addresses to get started.";
      listEl.innerHTML = "";
      return;
    }
    if (statusEl) statusEl.textContent = "Make simulated deposits with the numbered buttons, then Claim finalized balances into your wallet.";
    const deps = await bridge.getMyDeposits();
    renderDepositList(deps);
    updateDepositFlowButtons(deps);
    updateDepositSimValue();   // allowance/marks may have moved since the last keystroke
  } catch (e) {
    console.warn("refreshDepositPage:", e);
    if (statusEl) statusEl.textContent = "Error loading deposits.";
  }
}

// Last getPlayDepositAllowance record (raw e8 fields — the opt wrapper keeps
// them off the money normalizer), refreshed by refreshDepositPage. Powers the
// value hint's "this would be refused" warning below.
let depositAllowanceSnap = null;
// The two independent reasons "1. Deposit amount" is disabled, kept as module
// state because they're computed by different callers at different times:
// _depositHasPending (from the deposit list, updateDepositFlowButtons) and
// _depositWouldRefuse (from the entered amount vs marks + allowance,
// updateDepositSimValue). syncDepositSimButton() ORs them into the button.
let _depositHasPending = false;
let _depositWouldRefuse = false;
let _depositRefuseReason = "";

// Single source of truth for the "1. Deposit amount" button: disabled while a
// batch is still pending (finalize it first) OR when the entered amount would
// be refused by the backend (over the remaining allowance, or not yet
// priceable), so the user can't press a button that's guaranteed to error.
function syncDepositSimButton() {
  const simBtn = document.getElementById("deposit-sim-btn");
  if (!simBtn) return;
  simBtn.disabled = _depositHasPending || _depositWouldRefuse;
  simBtn.title = _depositHasPending
    ? "Simulate finality on the pending deposit first"
    : (_depositWouldRefuse ? _depositRefuseReason : "");
}

// Live value hint under the simulator: what the entered amount is worth at
// the CURRENT mark — the same pool refPrice the allowance charges when
// "1. Deposit amount" is pressed (getMarkets.markPrice; ICPUSD is 1:1) — and
// whether it still fits the remaining allowance. An estimate, not a quote:
// marks move between keystroke and press, and the backend rounds up in the
// allowance's favor.
function updateDepositSimValue() {
  const el = document.getElementById("deposit-sim-value");
  if (!el) return;
  const asset = document.getElementById("deposit-sim-asset")?.value;
  const amt = parseFloat(document.getElementById("deposit-sim-amount")?.value);
  // Recomputed below; default to "would not be refused" (no valid amount yet).
  _depositWouldRefuse = false; _depositRefuseReason = "";
  if (!asset || !(amt > 0)) { el.style.display = "none"; syncDepositSimButton(); return; }
  el.style.display = "";
  let mark = null;
  if (asset === "ICPUSD") {
    mark = 1;   // the USD stand-in values 1:1, no market needed
  } else {
    if (!markets.length) {
      el.className = "deposit-sim-value";
      el.textContent = "Fetching mark prices…";
      syncDepositSimButton();   // don't disable while we don't yet know the value
      refreshMarkets().then(updateDepositSimValue).catch(() => {});
      return;
    }
    const m = markets.find((x) => x.id === `${asset}-ICPUSD`);
    if (m) mark = m.markPrice > 0 ? m.markPrice : (m.lastPrice > 0 ? m.lastPrice : null);
  }
  if (mark == null) {
    el.className = "deposit-sim-value warn";
    el.textContent = `No mark price for ${asset} yet — this deposit can't be valued or admitted until its market is live.`;
    _depositWouldRefuse = true;
    _depositRefuseReason = `No mark price for ${asset} yet — its market isn't live.`;
    syncDepositSimButton();
    return;
  }
  const value = amt * mark;
  const usd = (v) => `$${v.toLocaleString(undefined, { maximumFractionDigits: 2 })}`;
  const remainingE8 = depositAllowanceSnap ? Number(depositAllowanceSnap.remainingUsd) : null;
  if (remainingE8 != null && value * 1e8 > remainingE8) {
    el.className = "deposit-sim-value warn";
    el.textContent = `${amt} ${asset} ≈ ${usd(value)} at the current mark — over your ` +
      `${usd(remainingE8 / 1e8)} remaining allowance, so this deposit will be refused.`;
    _depositWouldRefuse = true;
    _depositRefuseReason = `${amt} ${asset} (~${usd(value)}) is over your ${usd(remainingE8 / 1e8)} remaining allowance.`;
  } else {
    el.className = "deposit-sim-value";
    el.textContent = `${amt} ${asset} ≈ ${usd(value)} at the current mark` +
      (remainingE8 != null
        ? ` — depositing would leave ${usd(remainingE8 / 1e8 - value)} of your allowance remaining.`
        : ".");
  }
  syncDepositSimButton();
}

// One simulated batch at a time: "1. Deposit amount" stages a pending
// deposit and "2. Simulate finality" finalizes it, so each button is enabled
// exactly when it's the step to take (deposit → finalize → deposit → …) and
// the numbered flow can't be run out of order.
function updateDepositFlowButtons(deps) {
  _depositHasPending = deps.some((d) => Number(d.pending) > 0);
  const confirmBtn = document.getElementById("deposit-confirm-btn");
  if (confirmBtn) {
    confirmBtn.disabled = !_depositHasPending;
    confirmBtn.title = _depositHasPending ? "" : "Nothing is waiting to be finalized";
  }
  // "1. Deposit amount" is gated by pending AND over-allowance together.
  syncDepositSimButton();
}

function renderDepositList(deps) {
  const listEl = document.getElementById("deposit-list");
  if (!listEl) return;
  listEl.innerHTML = deps.map((d) => {
    const claimable = Number(d.claimable);
    const pending = Number(d.pending);
    const claimDisabled = claimable > 0 ? "" : "disabled";
    const pendingHtml = pending > 0
      ? `<span class="dep-pending">${depFmt(d.pending)} pending</span>` : "";
    return `<div class="dep-row">
      <div class="dep-asset">
        <span class="dep-asset-code"><img class="dep-logo" src="/assets/${d.asset}.svg" alt="" data-hide-on-error>${d.asset}</span>
        <span class="dep-chain">${d.chain}</span>
      </div>
      <div class="dep-addr-wrap" title="Simulated ${d.chain} address — a play-mode stand-in. Never send real assets to it; use the numbered buttons to deposit.">
        <span class="dep-addr">${d.address}</span>
        <span class="dep-sim-badge">simulated</span>
      </div>
      <div class="dep-amounts">
        <span class="dep-claimable">${depFmt(d.claimable)} claimable</span>
        ${pendingHtml}
        <span class="dep-claimed">${depFmt(d.claimed)} claimed</span>
      </div>
      <button class="btn btn-sm dep-claim-btn" data-asset="${d.asset}" ${claimDisabled}>Claim</button>
    </div>`;
  }).join("");
  listEl.querySelectorAll(".dep-claim-btn").forEach((b) =>
    b.addEventListener("click", () => handleClaim(b.dataset.asset)));
}

// (The per-row Copy button and its clipboard helpers are GONE, deliberately,
// with the address blur: the stub's faux addresses must not be copyable, or
// someone who missed that this is play mode could send real assets to one.
// A real Bridge serving real addresses should bring the copy affordance back.)

async function handleCreateDepositAddress() {
  const bridge = await getBridgeActor();
  if (!bridge) { showToast("Sign in first", "error"); return; }
  try { await bridge.createDepositAddress(); await refreshDepositPage(); }
  catch (e) { showToast("Failed: " + e.message, "error"); }
}

async function handleSimulateDeposit() {
  const asset = document.getElementById("deposit-sim-asset")?.value;
  const amt = parseFloat(document.getElementById("deposit-sim-amount")?.value);
  if (!asset || !(amt > 0)) { showToast("Enter a positive amount", "error"); return; }
  const bridge = await getBridgeActor();
  if (!bridge) return;
  try {
    // The play allowance is CONSUMED here: the DEX values the deposit at
    // press-time marks, debits the lifetime allowance, and reserves the
    // units — a refused deposit is never created, and an admitted one can
    // always claim (claims settle against the reservation, no re-pricing).
    const r = await bridge.devSimulateDeposit(asset, BigInt(Math.round(amt * 1e8)));
    if (r && "err" in r) { showToast(r.err, "error"); return; }
    // Clear the amount now the allowance it referred to has been consumed —
    // otherwise the resting value re-values against the now-smaller remaining
    // allowance and shows a spurious "would be refused" warning.
    const amtInput = document.getElementById("deposit-sim-amount");
    if (amtInput) amtInput.value = "";
    showToast(`Simulated deposit: ${amt} ${asset} (pending — Confirm to make it claimable)`, "success");
    await refreshDepositPage();
  } catch (e) { showToast("Failed: " + e.message, "error"); }
}

async function handleConfirmDeposits() {
  const bridge = await getBridgeActor();
  if (!bridge) return;
  try { await bridge.devConfirmDeposits(); showToast("Pending deposits confirmed", "success"); await refreshDepositPage(); }
  catch (e) { showToast("Failed: " + e.message, "error"); }
}

async function handleClaim(asset) {
  const bridge = await getBridgeActor();
  if (!bridge) return;
  try {
    const r = await bridge.claim(asset);
    if (r && "ok" in r) {
      showToast(`Claimed ${depFmt(r.ok)} ${asset} into your wallet`, "success");
      await refreshDepositPage();
      try { await refreshBalances(); } catch {}
    } else {
      showToast(r?.err || "Claim failed", "error");
    }
  } catch (e) { showToast("Claim failed: " + e.message, "error"); }
}

function wireDepositPage() {
  document.getElementById("deposit-create")?.addEventListener("click", handleCreateDepositAddress);
  document.getElementById("deposit-sim-btn")?.addEventListener("click", handleSimulateDeposit);
  document.getElementById("deposit-confirm-btn")?.addEventListener("click", handleConfirmDeposits);
  document.getElementById("deposit-sim-amount")?.addEventListener("input", updateDepositSimValue);
  document.getElementById("deposit-sim-asset")?.addEventListener("change", updateDepositSimValue);
}

// ── Demo Mode (when SDK not available) ──────────────────────────
function setupDemoMode() {
  appState.actor = createMockActor();
  appState.publicActor = appState.actor;
  appState.isAuthenticated = false;
}

function createMockActor() {
  const balances = {};
  const orders = [];
  const deposits = [];
  let nextId = 1;

  return {
    addTestTokens: async (token, amount) => {
      balances[token] = (balances[token] || 0) + amount;
      deposits.push({ token, amount, timestamp: Date.now() * 1000000, kind: { deposit: null } });
    },
    getBalances: async () => {
      return Object.entries(balances).filter(([_, v]) => v > 0.0001);
    },
    getBalance: async (token) => balances[token] || 0,
    getMarkets: async () => [
      { id: "BTC-ICPUSD", baseToken: "BTC", quoteToken: "ICPUSD", lastPrice: 67500.0, volume24h: 8_215_000.0, priceChange24hAbs:  1550.00, markPrice: 67510.0 },
      { id: "ETH-ICPUSD", baseToken: "ETH", quoteToken: "ICPUSD", lastPrice:  3450.0, volume24h: 2_110_000.0, priceChange24hAbs:   -39.12, markPrice:  3451.0 },
      { id: "ICP-ICPUSD", baseToken: "ICP", quoteToken: "ICPUSD", lastPrice:    12.5, volume24h:   340_000.0, priceChange24hAbs:     0.0, markPrice:    12.5 },
    ],
    getOrderBook: async () => ({
      bids: [
        { price: 67400, quantity: 0.5, orderCount: 3 },
        { price: 67300, quantity: 1.2, orderCount: 5 },
        { price: 67200, quantity: 0.8, orderCount: 2 },
      ],
      asks: [
        { price: 67600, quantity: 0.3, orderCount: 2 },
        { price: 67700, quantity: 0.9, orderCount: 4 },
        { price: 67800, quantity: 1.5, orderCount: 6 },
      ],
      spread: 200,
    }),
    getRecentTrades: async () => {
      const now = Date.now() * 1000000;
      return [
        { id: 1n, marketId: "BTC-ICPUSD", side: { buy: null },  price: 67010, quantity: 0.12, timestamp: now - 40000000000 },
        { id: 2n, marketId: "BTC-ICPUSD", side: { sell: null }, price: 67120, quantity: 0.08, timestamp: now - 25000000000 },
        { id: 3n, marketId: "BTC-ICPUSD", side: { sell: null }, price: 67080, quantity: 0.21, timestamp: now - 9000000000 },
        { id: 4n, marketId: "BTC-ICPUSD", side: { buy: null },  price: 67200, quantity: 0.05, timestamp: now - 2000000000 },
      ];
    },
    getRecentEvents: async () => {
      const now = Date.now() * 1000000;
      return [
        { id: 4, ts: now - 5000000000,   severity: "info",  category: "swap",   message: "Swap 50.00 ICP → 0.02 BTC", market: ["BTC-ICPUSD"] },
        { id: 3, ts: now - 60000000000,  severity: "warn",  category: "amm",    message: "BTC oracle stale — AMM widening quotes (+1.20% half-spread)", market: ["BTC-ICPUSD"] },
        { id: 2, ts: now - 90000000000,  severity: "warn",  category: "oracle", message: "BTC price feed degraded to 5/6 sources ($67,000.00)", market: ["BTC-ICPUSD"] },
        { id: 1, ts: now - 120000000000, severity: "info",  category: "oracle", message: "BTC price feed recovered to 6/6 sources", market: ["BTC-ICPUSD"] },
      ];
    },
    getAllTrades: async () => [],
    getCandles: async () => ({ candles: [], hasMore: false }),
    getTradesSince: async () => [],
    getUserStatus: async () => ({ version: 0n, lastTradeTime: 0n, openOrderCount: 0n }),
    getMyTradeHistorySince: async () => [],
    getMarketStatus: async () => ({ version: 0n, lastTradeId: 0n }),
    getRecentPublicTrades: async () => [],
    getPublicTradesSince: async () => [],
    getMarketChanges: async () => ({
      marketStatus: [], orderBook: [], orderBookDelta: [], newTrades: [],
      userStatus: [], userOpenOrders: [], userBalances: [], newUserTrades: [],
    }),
    getMyOrders: async () => orders.filter((o) => o.status.open !== undefined || o.status.partiallyFilled !== undefined),
    getMyClosedOrders: async () => [
      {
        id: 9002n, marketId: "BTC-ICPUSD", side: { sell: null }, orderType: { limit: null },
        price: 68120.0, quantity: 0.25, filled: 0.25, status: { filled: null },
        placedAt: (BigInt(Date.now()) - 7_200_000n) * 1_000_000n,
        closedAt: (BigInt(Date.now()) - 3_600_000n) * 1_000_000n,
      },
      {
        id: 9001n, marketId: "ETH-ICPUSD", side: { buy: null }, orderType: { limit: null },
        price: 1580.0, quantity: 2.0, filled: 0.0, status: { cancelled: null },
        placedAt: (BigInt(Date.now()) - 86_400_000n) * 1_000_000n,
        closedAt: (BigInt(Date.now()) - 82_800_000n) * 1_000_000n,
      },
    ],
    getMyOrdersOnMarket: async () => [],
    getMyStagedOrderIds: async () => [],
    getMyRecentSwap: async () => [],
    placeLimitOrder: async (market, side, price, qty) => {
      const o = { id: nextId++, marketId: market, owner: "demo", side, orderType: { limit: null }, price, quantity: qty, filled: 0, status: { open: null }, timestamp: Date.now() * 1000000, originalQuantity: qty };
      orders.push(o);
      return { ok: o };
    },
    placeLimitOrderExp: async (market, side, price, qty) => {
      const o = { id: nextId++, marketId: market, owner: "demo", side, orderType: { limit: null }, price, quantity: qty, filled: 0, status: { open: null }, timestamp: Date.now() * 1000000, originalQuantity: qty };
      orders.push(o);
      return { ok: o };
    },
    placeMarketOrder: async () => ({ ok: { trades: [], remainingQty: 0, totalFilled: 0, avgPrice: 0 } }),
    swap: async () => ({ ok: { fromAmount: 0, toAmount: 0, fullyFilled: false, swapOrderId: [] } }),
    cancelMyOrder: async (id) => {
      const idx = orders.findIndex((o) => Number(o.id) === Number(id));
      if (idx >= 0) orders[idx].status = { cancelled: null };
      return { ok: null };
    },
    whoami: async () => "demo-principal",
    getMyProfile: async () => ({
      userId: "DEMO",
      username: "Swift-Fox-42",
      regenCount: 0,
      createdAt: Date.now() * 1000000,
    }),
    regenerateUsername: async () => ({ ok: { userId: "DEMO", username: "Brave-Hawk-17", regenCount: 1, createdAt: Date.now() * 1000000 } }),
    getMyTradeHistory: async () => [],
    getMyAdjustments: async () => [],
    getMyDeposits: async () => deposits,
    getCanisterInfo: async () => ({
      canisterId: "rdmx6-jaaaa-aaaaa-aaadq-cai", cycles: 500_000_000_000_000n,
      freezingLimitCycles: 1_500_000_000_000n,
      burnPerDay: 4_200_000_000_000n, idleBurnPerDay: 1_400_000_000_000n,
      computeAllocation: 0n,
      lastHeartbeatNs: BigInt(Date.now()) * 1_000_000n,
      nowNs: BigInt(Date.now()) * 1_000_000n, timersPaused: false,
      memorySizeBytes: 268_435_456n, heapLiveBytes: 201_326_592n,
      wasmMemoryLimitBytes: 4_294_967_296n, lowMemoryAtNs: 0n, ordersRetained: 1_204n,
      tradesRetained: 5_877n, usersRegistered: 42n,
      journalUnshipped: 2n, ledgerJournalPending: 0n, archivedEvents: 18_344n,
      archiveCanisterId: ["rrkah-fqaaa-aaaaa-aaaaq-cai"],
      archivesSealed: 0n,
      archiveCycles: 2_000_000_000_000n, archiveLifetimeTopUp: 0n,
      autoFuelEnabled: true, fuelRouteWired: true, fuelLifetimeCycles: 0n,
      fuelPendingNotify: [],
      treasuryUsdE8s: 96_260_607_603_700n, treasuryIcpE8s: 5_000_000_000n,
      oracleDivergence: [],
    }),
  };
}

// ── Auth ─────────────────────────────────────────────────────────

const SIGNIN_TTL_KEY = "mdx.signinTtlMin";   // remembered max-session-length choice (minutes, string)
const SIGNIN_MEM_KEY = "mdx.signinInMemory"; // remembered in-memory-key toggle ("1"/"0")
const IDLE_OPTS = { idleTimeout: 60 * 60 * 1000 };   // 1h idle logout (library default is 10min)

// Session janitor: end an on-disk session when the LAST app tab closes.
//
// A service worker can't do this reliably — when the final tab closes the page
// is torn down before a pagehide→SW message is guaranteed to be delivered, and
// a worker with zero clients isn't kept alive for a deferred check. So instead
// every open tab writes a HEARTBEAT timestamp to localStorage, and on the next
// boot we check it: a refresh reloads within a second (tiny gap → session
// kept), whereas closing every tab freezes the heartbeat (gap grows past
// SESSION_STALE_MS → sign out). All the logic runs at page load, which always
// executes — no dependency on anything running after the tab is gone.
const HEARTBEAT_KEY = "mdx.tabHeartbeat";   // localStorage: ms timestamp, refreshed by every open tab
const HEARTBEAT_MS = 1000;                  // write cadence
const SESSION_STALE_MS = 8000;             // gap beyond this at boot ⇒ every tab was closed (not a refresh)

// Read BEFORE the heartbeat restarts: was NO tab alive within the stale window?
// (Missing key = first-ever load; caller only acts on it when a session exists.)
function tabsAllClosedSinceLastLoad() {
  try {
    const last = Number(localStorage.getItem(HEARTBEAT_KEY) || 0);
    return !last || (Date.now() - last) > SESSION_STALE_MS;
  } catch { return false; }   // storage blocked → don't force a logout
}

// Begin marking this tab alive (and keep it fresh on focus / bfcache restore).
// Each beat also pings the janitor service worker: every ping opens a rolling
// 8s census in the worker (public/sw.js), so when the LAST tab closes, the
// most recent ping — sent BEFORE the close, no teardown race — is still
// pending and its census deletes the on-disk session ~8s later. The worker is
// hygiene only; the boot stale-check above remains the authoritative logout
// (and covers browser quit/crash, which kill the worker outright).
function startSessionHeartbeat() {
  const beat = () => {
    try { localStorage.setItem(HEARTBEAT_KEY, String(Date.now())); } catch {}
    try { navigator.serviceWorker?.controller?.postMessage({ type: "alive" }); } catch {}
  };
  beat();
  setInterval(beat, HEARTBEAT_MS);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) beat(); });
  window.addEventListener("pageshow", beat);
}

// Register the janitor service worker (idempotent; updates in place).
function registerJanitorSW() {
  if (!("serviceWorker" in navigator)) return;
  navigator.serviceWorker.register("/sw.js")
    .catch((e) => console.warn("Session janitor SW unavailable:", e));
}

// AuthClient constructor options (7.x: identityProvider and the optional
// one-click openIdProvider are bound at CONSTRUCTION). Storage too, so the
// in-memory mode is applied by REBUILDING the client (doLogin), not per call.
function authClientOpts(inMemory, openIdProvider) {
  const derivationOrigin = getDerivationOrigin();
  return {
    identityProvider: getIdentityProviderUrl(),
    idleOptions: IDLE_OPTS,
    ...(derivationOrigin ? { derivationOrigin } : {}),
    ...(openIdProvider ? { openIdProvider } : {}),
    ...(inMemory ? { storage: makeInMemoryStorage() } : {}),
  };
}

// In-memory AuthClientStorage: the delegation + base key live only in this JS
// Map — never written to disk (no IndexedDB / localStorage), so there's no
// forensic trace and the session dies on tab close / reload by construction.
// The base key stays a non-extractable CryptoKey (the Map holds the object;
// unlike sessionStorage there's no string-serialization forcing a weaker key).
function makeInMemoryStorage() {
  const m = new Map();
  return {
    get: async (k) => (m.has(k) ? m.get(k) : null),
    set: async (k, v) => { m.set(k, v); },
    remove: async (k) => { m.delete(k); },
  };
}

// Any "Sign in" click opens the options dialog (session length + whether the
// session is written to disk). Demo mode (no II client) signs in directly.
function login() {
  if (!authClient) {   // demo mode
    appState.isAuthenticated = true;
    onLogin().then(updateUI);
    return;
  }
  const modal = document.getElementById("signin-modal");
  if (!modal) { doLogin({ ttlMinutes: 60, inMemory: false }); return; }
  const remembered = localStorage.getItem(SIGNIN_TTL_KEY) || "60";
  const pick = modal.querySelector(`input[name="signin-ttl"][value="${remembered}"]`)
            || modal.querySelector('input[name="signin-ttl"][value="60"]');
  if (pick) pick.checked = true;
  const mem = document.getElementById("signin-inmemory");
  if (mem) mem.checked = localStorage.getItem(SIGNIN_MEM_KEY) === "1";
  modal.style.display = "flex";
}
// The extracted feature modules (explorer.js) reach sign-in and the live
// profile through appState — the shared-singleton seam that exists precisely
// because they cannot import from main.js (main.js imports THEM; a back-import
// would be a cycle). Top-level, so both are set before any UI code runs.
appState.login = login;
appState.getUserProfile = () => userProfile;

// Perform the II login for a chosen posture. Rebuilds the client so the
// storage mode (and the optional one-click Google path) take effect; the
// chosen max-session-length becomes the delegation's maxTimeToLive
// (nanoseconds) — the cap while a tab stays open.
async function doLogin({ ttlMinutes, inMemory, openIdProvider }) {
  authClient = new AuthClient(authClientOpts(inMemory, openIdProvider));
  try {
    // Everything window-bound starts INSIDE the click gesture (signer-js
    // channel rule): the sign-in, and — on the Google path — the attribute
    // request too, so play verification rides the SAME II interaction that
    // signs the player in (docs/play-anti-sybil-design.md). The nonce is a
    // callback the client awaits in flight; a throwaway identity mints it
    // (inspect refuses anonymous).
    const signInPromise = authClient.signIn({
      maxTimeToLive: BigInt(Math.round(ttlMinutes * 60)) * 1_000_000_000n,
    });
    let attributesPromise = null;
    if (openIdProvider === "google") {
      attributesPromise = authClient.requestAttributes({
        keys: [GOOGLE_VERIFIED_EMAIL_KEY],
        nonce: () => mintNonceEphemeral(),
      });
      attributesPromise.catch(() => {});   // handled below — never an unhandled rejection
    }
    identity = await signInPromise;
    appState.isAuthenticated = true;
    await setupActor();
    if (attributesPromise) {
      // Present the bundle only where it matters: a play venue with an
      // unbound account. Elsewhere the consent already happened in-window;
      // dropping the bundle is harmless.
      try {
        const v0 = await appState.actor.getMyVerification();
        if (v0 && v0.required && !v0.bound) {
          const out = await presentAttributesToBackend(await attributesPromise);
          lastVerifyMessage = out.ok ? null : (out.message || "Verification didn't complete — try again.");
          if (out.ok) { showToast("Verified — your play allowance is unlocked", "success"); }
          else { showToast(out.message, "error"); }
        }
      } catch (e) {
        console.warn("google verification at sign-in:", e);
        lastVerifyMessage = "Verification didn't complete — try again.";
      }
    }
    await onLogin();
    updateUI();
  } catch (err) {
    showToast("Login failed: " + (err?.message || err), "error");
    throw err;
  }
}

async function logout() {
  if (authClient) {
    await authClient.signOut();
  }
  identity = null;
  appState.isAuthenticated = false;
  appState.actor = null;
  userBalances = {};
  userProfile = null;
  cachedUserStatus = null;
  cachedAcctSummary = null;
  lastRejectionTs = null;
  appState.archiveActor = null; _archiveId = null; _archRows = []; _archSeen = new Set(); _archTradeIds = new Set();
  appState.bridgeActor = null;   // drop the Bridge actor bound to the old identity
  lastVerifyMessage = null;      // verification errors belong to the old identity too
  resetAssistant();              // the assistant transcript belongs to the old identity — never let it leak across sign-ins (GHSA-6qpg)
  if (statusPollInterval) { clearInterval(statusPollInterval); statusPollInterval = null; }
  renderProfileChip();
  renderAccountPage();
  refreshDepositPage();          // clears addresses → signed-out state (no-op network call when on another tab)
  if (!authClient) setupDemoMode();
  startAutoRefresh(); // restart with public-only tickers
  updateUI();
}

async function onLogin() {
  // Independent endpoints — fetch concurrently instead of serially (this used
  // to be four back-to-back round trips holding up the signed-in first paint).
  await Promise.all([
    refreshBalances(),
    refreshMarkets(),
    refreshProfile(),
    seedReleaseRejections(),   // baseline so historical rejections don't toast on sign-in
  ]);
  refreshAiGate();   // re-probe with the signed-in actor (heals a failed startup probe; non-blocking)
  startAutoRefresh();
  if (currentTab === "account" && acctTab === "deposit") refreshDepositPage();   // re-render in place if already on it

  // Sync preferences from backend (overrides local if backend has data)
  try {
    const backendPrefs = await appState.actor.getUserPreferences();
    if (backendPrefs.recentMarkets.length > 0 || backendPrefs.lastMarket.length > 0) {
      // Backend has prefs — use them
      recentMarkets = backendPrefs.recentMarkets;
      lastMarket = backendPrefs.lastMarket.length > 0 ? backendPrefs.lastMarket[0] : null;
      await saveLocalPrefs({ recentMarkets, lastMarket });
      renderMarketDropdown();
    } else if (recentMarkets.length > 0 || lastMarket) {
      // Backend empty but local has prefs — push to backend
      appState.actor.setUserPreferences({
        recentMarkets,
        lastMarket: lastMarket ? [lastMarket] : [],
      });
    }
  } catch (e) {
    console.warn("Failed to sync preferences:", e);
  }
}

// ── Profile ──────────────────────────────────────────────────────
async function refreshProfile() {
  if (!appState.actor || !appState.isAuthenticated) return;
  try {
    userProfile = await appState.actor.getMyProfile();
    // Cache the principal text so we can tell which side of a pending
    // match the user is on without an extra whoami() round-trip per render.
    try {
      const p = await appState.actor.whoami();
      appState.myPrincipalText = typeof p === "string" ? p : p.toString();
    } catch (e) { /* swallow */ }
    renderProfileChip();
    renderAccountProfile();
    dxUpdateIdentity();   // refresh the explorer identity line if it's open
  } catch (e) {
    console.warn("Failed to fetch profile:", e);
  }
}

function renderProfileChip() {
  // Signed-in identity lives in the far-right user dropdown on desktop
  // (#user-menu → Account / Sign out). Its visibility, and the Sign-In
  // button's, is driven by the `.header.authed` class (see header.css); this
  // just fills the avatar + name and flips the class. The mobile drawer's
  // Account item mirrors the pill (avatar + username; "Account" signed out).
  const header = document.querySelector(".header");
  const avatarEl = document.getElementById("user-menu-avatar");
  const nameEl = document.getElementById("user-menu-name");
  const dAvatarEl = document.getElementById("drawer-acct-avatar");
  const dNameEl = document.getElementById("drawer-acct-name");
  const authed = !!(appState.isAuthenticated && userProfile);
  if (header) header.classList.toggle("authed", authed);
  if (!authed) {
    if (dAvatarEl) dAvatarEl.style.display = "none";
    if (dNameEl) dNameEl.textContent = "Account";
    closeUserMenu();
    return;
  }
  // Ident icon: seed by the USERNAME, so the glyph you see here is the same
  // one the leaderboard shows for you — and so regenerating your username
  // genuinely changes your public appearance. (Seeding by principal would
  // keep the glyph across a regen, quietly re-linking the new name to the
  // old on a public board.) Falls back to the initial before the profile loads.
  const initial = userProfile.username ? userProfile.username[0].toUpperCase() : "?";
  setIdenticon(avatarEl, userProfile.username, initial);
  if (nameEl) nameEl.textContent = userProfile.username || "—";
  if (dAvatarEl) {
    dAvatarEl.style.display = "";
    setIdenticon(dAvatarEl, userProfile.username, initial);
  }
  if (dNameEl) dNameEl.textContent = userProfile.username || "Account";
}

function closeUserMenu() {
  document.getElementById("user-menu")?.classList.remove("open");
  document.getElementById("user-menu-trigger")?.setAttribute("aria-expanded", "false");
}

async function doRegenerateUsername() {
  if (!appState.actor || !appState.isAuthenticated) return;
  const btn = document.getElementById("regen-username-btn");
  btn.disabled = true;
  try {
    const result = await appState.actor.regenerateUsername();
    if (result.ok) {
      userProfile = result.ok;
      renderProfileChip();
      renderAccountProfile();
      showToast("Username updated to " + userProfile.username, "success");
    } else {
      showToast(result.err, "error");
    }
  } catch (e) {
    showToast("Failed: " + e.message, "error");
  } finally {
    btn.disabled = false;
  }
}

// ── Data Fetching ───────────────────────────────────────────────
async function refreshBalances() {
  if (!appState.actor) return;
  try {
    const bals = await appState.actor.getBalances();
    // Available (total − reserved) rides along: the order form gates on THIS.
    // Gating on totals enabled orders the backend's reservation check refused.
    try {
      const avails = await appState.actor.getMyAvailableBalances();
      userAvailBalances = {};
      for (const [t, a] of avails) userAvailBalances[t] = Number(a) / 1e8;
    } catch { /* keep last known */ }
    userBalances = {};
    for (const [token, amount] of bals) {
      userBalances[token] = amount;
    }
    // Margin snapshot (debt/collateral/health) — feeds the header net value and
    // the Borrow & Buy headroom gate. Works with or without a margin account.
    try { cachedMarginHealth = await appState.actor.getMyMarginHealth(); } catch (_) { cachedMarginHealth = null; }
    // Account summary — the header figure and Account-value card show the FULL
    // account value (wallet + each pool's equity), not just wallet holdings.
    try { cachedAcctSummary = await appState.actor.getMyAccountSummary(); } catch (_) { /* keep last */ }
    renderBalances();
    updateSwapBalances();
    renderAccountBalances();
    // Keep the Place Order "Available:" line in sync — otherwise after a
    // deposit/borrow it stays blank/stale until the side toggle is touched.
    updateOrderSideUI();
  } catch (e) {
    console.warn("Failed to fetch balances:", e);
  }
}

// ── Release-rejection watcher ("never silent") ───────────────────
// A staged order can be killed or clamped at GEPTOR release (initial-margin
// re-gate, FOK). Surface EVERY new one as a toast. This is a global, idempotent,
// timestamp-keyed watcher rather than a per-place check, which fixes three bugs
// in the old approach: a length baseline is defeated by the 200-entry cap; a
// single fixed delay misses a resting LIMIT entry that's killed minutes later;
// and "report the latest rejection" misattributes another order's failure. The
// backend bumps the user version on every rejection, so pollChanges drives this
// the moment one lands, on any page.
let lastRejectionTs = null;   // BigInt ns of the newest rejection already surfaced; null until seeded
let _rejCheckInFlight = false; // guard: pollChanges fires checkReleaseRejections un-awaited

async function seedReleaseRejections() {
  if (!appState.actor || !appState.isAuthenticated) { lastRejectionTs = 0n; return; }
  try {
    const rejs = await appState.actor.getMyReleaseRejections();
    lastRejectionTs = rejs.reduce((m, r) => (r.timestamp > m ? r.timestamp : m), 0n);
  } catch (_) { lastRejectionTs = 0n; }
}

async function checkReleaseRejections() {
  if (!appState.actor || !appState.isAuthenticated || _rejCheckInFlight) return;
  if (lastRejectionTs === null) { await seedReleaseRejections(); return; }  // baseline, no toast
  _rejCheckInFlight = true;
  try {
    const rejs = await appState.actor.getMyReleaseRejections();
    let maxTs = lastRejectionTs;
    for (const r of rejs) {
      if (r.timestamp > lastRejectionTs) {
        if (r.timestamp > maxTs) maxTs = r.timestamp;
        const clamped = r.clampedTo && r.clampedTo.length;
        const coin = String(r.marketId).split("-")[0];
        // "size reduced" (not "partially filled") — the excess was BLOCKED by the
        // margin gate, not left resting, so nothing is still working.
        showToast(`${coin} order ${clamped ? "size reduced" : "not filled"}: ${r.reason}`,
          clamped ? "warning" : "error");
      }
    }
    lastRejectionTs = maxTs;
  } catch (_) {}
}

async function refreshMarkets() {
  const src = appState.actor || appState.publicActor;
  if (!src) return;
  try {
    markets = await src.getMarkets();
    renderMarketDropdown();
    // Update header price for selected market
    if (selectedMarket) {
      const m = markets.find((x) => x.id === selectedMarket);
      if (m) updatePriceChange(m);
    }
  } catch (e) {
    console.warn("Failed to fetch markets:", e);
  }
}

async function refreshOrderBook() {
  if (!selectedMarket) return;
  const src = appState.actor || appState.publicActor;
  if (!src) return;
  const marketAtCall = selectedMarket; // capture before await
  try {
    const snapshot = await src.getOrderBookDepth(marketAtCall, [OB_FETCH_DEPTH]);
    orderBookCache[marketAtCall] = snapshot;
    // Update the instant-switch cache
    if (!marketDataCache[marketAtCall]) marketDataCache[marketAtCall] = {};
    marketDataCache[marketAtCall].orderBook = snapshot;
    marketDataCache[marketAtCall].timestamp = Date.now();
    if (selectedMarket !== marketAtCall) return; // market changed while waiting
    renderOrderBook(snapshot);
    setStaleIndicator("orderbook-stale", false);
  } catch (e) {
    console.warn("Failed to fetch order book:", e);
  }
}

// Build an OrderBookSnapshot from the locally-cached orderBookState for a market.
// Sorts asks ascending, bids descending, and computes the spread.
function buildSnapshotFromState(marketId) {
  const state = orderBookState[marketId];
  if (!state) return { asks: [], bids: [], spread: 0 };
  const asks = [...state.asks.values()].sort((a, b) => a.price - b.price);
  const bids = [...state.bids.values()].sort((a, b) => b.price - a.price);
  const spread = asks.length && bids.length ? asks[0].price - bids[0].price : 0;
  return { asks, bids, spread };
}

// Fetch and cache an order book for a market without rendering it
async function fetchOrderBookForMarket(marketId) {
  const src = appState.actor || appState.publicActor;
  if (!src) return null;
  try {
    const snapshot = await src.getOrderBookDepth(marketId, [OB_FETCH_DEPTH]);
    orderBookCache[marketId] = snapshot;
    return snapshot;
  } catch (e) {
    return null;
  }
}

// (estimateSwapOutput is gone: swap estimates come from the canister's
// quoteSwap query — see updateSwapPreview.)

async function updateSwapPreview() {
  const fromToken  = document.getElementById("swap-from-token").value;
  const toToken    = document.getElementById("swap-to-token").value;
  const fromAmount = parseFloat(document.getElementById("swap-from-amount").value);
  const toAmountEl = document.getElementById("swap-to-amount");
  const previewEl  = document.getElementById("swap-preview");
  const rateEl     = document.getElementById("swap-preview-rate");
  const impactEl   = document.getElementById("swap-preview-impact");
  const loadingEl  = document.getElementById("swap-preview-loading");

  if (!fromAmount || fromAmount <= 0 || fromToken === toToken) {
    toAmountEl.value = "";
    toAmountEl.classList.remove("estimated");
    previewEl.style.display = "none";
    lastSwapEstimate = null;
    updateSwapButtonState();
    return;
  }

  // ONE source of truth: the canister's quoteSwap runs the same funded-depth
  // walk the release-time FOK check uses (maker funding, pending locks, both
  // legs for base→base) and charges the caller's actual taker-fee rate — the
  // old client-side book walk had none of that and no base→base path at all.
  // One-pass conservative: the sealed release can fill more via AMM requotes,
  // so partials are phrased as "right now". Debounced + seq-guarded.
  loadingEl.style.display = "inline";
  clearTimeout(_swapQuoteTimer);
  const seq = ++_swapQuoteSeq;
  _swapQuoteTimer = setTimeout(async () => {
    let q = null;
    try {
      const slipE8 = toE8(maxSlippage);
      const res = await appState.actor.quoteSwap(fromToken, toToken, toE8(fromAmount), slipE8);
      if (seq !== _swapQuoteSeq) return;
      if ("ok" in res) q = res.ok;
    } catch { /* q stays null → "No liquidity" */ }
    if (seq !== _swapQuoteSeq) return;
    loadingEl.style.display = "none";

    if (!q || (Number(q.outAmount) === 0 && Number(q.consumedFrom) === 0)) {
      toAmountEl.value = "";
      toAmountEl.classList.remove("estimated");
      rateEl.textContent = "No liquidity available";
      rateEl.style.color = "var(--red)";
      rateEl.classList.remove("clickable");
      impactEl.textContent = "";
      impactEl.className = "swap-preview-impact";
      previewEl.style.display = "flex";
      lastSwapEstimate = { filled: false, consumedFrom: 0, fromAmount, fromToken, toAmount: 0, toToken };
      updateSwapButtonState();
      return;
    }

    const toAmount     = Number(q.outAmount) / 1e8;   // outAmount: raw e8 (name kept out of MONEY_KEYS)
    const consumedFrom = Number(q.consumedFrom) / 1e8;
    const feeQuote     = Number(q.feeQuote) / 1e8;
    const filled       = !q.exhausted;

    // Output decimals follow the trades-feed Size rule: as many as the output
    // asset's price has integer digits (ICPUSD prices at 1 → 1 dp). Thousands
    // separators are fine here — the field is a type="text" display.
    const toMarket = markets.find((m) => m.baseToken === toToken);
    const outPrice = toToken === "ICPUSD" ? 1
      : (toMarket ? (toMarket.markPrice > 0 ? toMarket.markPrice : toMarket.lastPrice) : 1);
    const outDp = outPrice >= 1 ? String(Math.floor(outPrice)).length : 1;
    toAmountEl.value = toAmount.toLocaleString("en-US", { minimumFractionDigits: outDp, maximumFractionDigits: outDp });
    toAmountEl.classList.add("estimated");

    if (filled) {
      // Effective rate NET of fees — what the user actually receives per unit.
      const rate = consumedFrom > 0 ? toAmount / consumedFrom : 0;
      const rateStr = toToken === "ICPUSD" ? formatPrice(rate) : formatNum(rate);
      const feeNote = feeQuote > 0 ? ` · fee ${fmtUsd(feeQuote)}` : "";
      rateEl.textContent = `1 ${fromToken} ≈ ${rateStr} ${toToken}${feeNote}`;
      rateEl.style.color = "";
      rateEl.classList.remove("clickable");
      showImpact(impactEl, Number(q.impactBps) / 10000);
    } else {
      // Partial: one pass of the current book can't absorb it all within
      // slippage. Clickable → auto-fill "From" with the fillable amount.
      rateEl.textContent = `⚠ Only ~${formatNum(consumedFrom)} ${fromToken} fillable right now — tap to fill`;
      rateEl.style.color = "var(--red)";
      rateEl.classList.add("clickable");
      impactEl.textContent = "";
      impactEl.className = "swap-preview-impact";
    }
    previewEl.style.display = "flex";
    lastSwapEstimate = { filled, consumedFrom, fromAmount, fromToken, toAmount, toToken };
    updateSwapButtonState();
  }, 250);
}

// Derive the Swap button's text + disabled state from the last estimate and
// the current "No partial fulfillment" checkbox. Called after every preview
// update and whenever the checkbox flips.
function updateSwapButtonState() {
  const btn = document.getElementById("swap-execute-btn");
  if (!btn) return;

  // Not authenticated → the button is a Sign-In CTA (handled in updateUI).
  if (!appState.isAuthenticated) {
    btn.textContent = "Sign In";
    btn.disabled = false;
    return;
  }

  const fromAmount = parseFloat(document.getElementById("swap-from-amount").value);
  if (!fromAmount || fromAmount <= 0) {
    btn.textContent = "Swap";
    btn.disabled = false;
    return;
  }

  const noPartial = document.getElementById("no-partial-fill").checked;
  const est = lastSwapEstimate;

  if (!est) {
    // Preview hasn't populated yet; let the click handler revalidate.
    btn.textContent = "Swap";
    btn.disabled = false;
    return;
  }

  if (est.filled) {
    btn.textContent = "Swap";
    btn.disabled = false;
  } else if (noPartial) {
    btn.textContent = "Insufficient liquidity";
    btn.disabled = true;
  } else {
    btn.textContent = "Swap (partial)";
    btn.disabled = false;
  }
}

function showImpact(el, priceImpact) {
  const pct = (priceImpact * 100).toFixed(2);
  if (priceImpact < 0.005) {
    el.textContent = `< 0.5% impact`;
    el.className = "swap-preview-impact low";
  } else if (priceImpact < 0.02) {
    el.textContent = `${pct}% impact`;
    el.className = "swap-preview-impact low";
  } else if (priceImpact < 0.05) {
    el.textContent = `${pct}% impact`;
    el.className = "swap-preview-impact medium";
  } else {
    el.textContent = `⚠ ${pct}% impact`;
    el.className = "swap-preview-impact high";
  }
}

function scheduleSwapPreview() {
  clearTimeout(swapPreviewDebounce);
  swapPreviewDebounce = setTimeout(updateSwapPreview, 250);
}

async function refreshTrades() {
  const src = appState.actor || appState.publicActor;
  if (!src || !selectedMarket) return;
  const marketAtCall = selectedMarket; // capture before await
  try {
    const trades = await src.getRecentTrades(marketAtCall);
    // Update the instant-switch cache
    if (!marketDataCache[marketAtCall]) marketDataCache[marketAtCall] = {};
    marketDataCache[marketAtCall].trades = trades;
    marketDataCache[marketAtCall].timestamp = Date.now();
    if (selectedMarket !== marketAtCall) return; // market changed while waiting
    renderTrades(trades);
    // Keep the public liquidation map current. It recomputes canister-side on a
    // 30s heartbeat, so polling it alongside trades is cheap and in step.
    refreshHeatmap(marketAtCall);
    // Header telemetry (Total Depth / Borrowed) rides the same poll — depth
    // moves with every book change, so trade cadence is the right freshness.
    refreshMarketTele(marketAtCall);
    setStaleIndicator("trades-stale", false);
  } catch (e) {
    console.warn("Failed to fetch trades:", e);
  }
}

async function refreshUserOrders() {
  if (!appState.actor || !appState.isAuthenticated) return;
  try {
    const [orders, stagedIds] = await Promise.all([appState.actor.getMyOrders(), appState.actor.getMyStagedOrderIds()]);
    stagedOrderIds = new Set((stagedIds || []).map((n) => Number(n)));
    // getMyOrders() merges wallet-owned SPOT orders with pool-owned MARGIN
    // orders (the backend includes the caller's pools, so the list survives
    // reloads and the consolidated poll keeps it live). Split by owner: pool
    // rows are tagged for the MGN badge; spot rows feed the Swap-page list.
    const { mine, pool } = await splitPoolOrders(orders);
    renderSwapOrders(mine);
    // ALL markets cached; the activity panel applies the market scope (the
    // "This market only" checkbox) at render time.
    const isOpen = (o) => o.status.open !== undefined || o.status.partiallyFilled !== undefined;
    uomOpenOrders = mine.filter(isOpen);
    uomPoolOrders = pool.filter(isOpen);
    renderUserOrdersMobile();
  } catch (e) {
    console.warn("Failed to fetch user orders:", e);
  }
}

// The caller's pools, cached (renderPositions warms it) — maps a pool
// PRINCIPAL back to its id/name for order-row tagging.
async function ensurePoolsCache() {
  if (_poolsCache && _poolsCache.length) return _poolsCache;
  try { _poolsCache = (await appState.actor.getMyMarginPools()) || []; } catch { /* keep whatever we had */ }
  return _poolsCache || [];
}

function myPrincipalTextSafe() {
  if (appState.myPrincipalText) return appState.myPrincipalText;
  try { return identity ? identity.getPrincipal().toText() : null; } catch { return null; }
}

// Split a merged getMyOrders result into the caller's own (spot) orders and
// pool-owned (margin) orders, tagging the latter with {poolId, poolName}.
// Cancel works either way (cancelMyOrder routes pool orders through the
// deleveraging pool-cancel path on the backend); the tags are for display.
async function splitPoolOrders(orders) {
  const me = myPrincipalTextSafe();
  const ownerTxt = (o) => (o.owner && o.owner.toText ? o.owner.toText() : String(o.owner));
  if (me && orders.some((o) => ownerTxt(o) !== me)) await ensurePoolsCache();
  const byPrincipal = new Map((_poolsCache || []).map((p) => [p.principal, p]));
  const mine = [], pool = [];
  for (const o of orders) {
    const ot = ownerTxt(o);
    if (me && ot !== me) {
      const p = byPrincipal.get(ot);
      pool.push({ ...o, poolId: p ? Number(p.id) : null, poolName: p ? p.name : "margin pool" });
    } else {
      mine.push(o);
    }
  }
  return { mine, pool };
}

// Consolidated single-round-trip poll: market status + order book + trades +
// user status + user orders + user balances + user trade history, all in one
// query. Only deltas are returned; everything unchanged is null/empty.
//
// SERIALISED, like checkReleaseRejections above. Every cursor in the request
// is read from the shared cache BEFORE the await, so two calls in flight at
// once send the same lastTradeId/version and both come back with the same
// deltas — and a slow response landing after a newer one puts a stale order
// book back on screen. The 2s interval outruns getMarketChanges on a loaded
// subnet, and pollMarketStatus() is fired straight after placing/cancelling an
// order, so the overlap is not hypothetical. Dropping the call is the right
// response rather than queueing one: the poll already running reads the same
// cursors this one would have, and the interval comes round again in 2s.
let _pollInFlight = false;

async function pollChanges() {
  const src = appState.actor || appState.publicActor;
  if (!src || _pollInFlight) return;

  const marketAtCall = selectedMarket;

  // Build request from cached state
  const marketStatus = marketAtCall ? cachedMarketStatus[marketAtCall] : null;
  const request = {
    marketId: marketAtCall ? [marketAtCall] : [],
    lastMarketVersion: marketStatus ? marketStatus.version : 0n,
    lastTradeId: marketStatus ? marketStatus.lastTradeId : 0n,
    lastUserVersion: cachedUserStatus ? cachedUserStatus.version : 0n,
    lastUserTradeTime: cachedUserStatus ? cachedUserStatus.lastTradeTime : 0n,
  };

  _pollInFlight = true;
  try {
    const resp = await src.getMarketChanges(request);

    // ── Market-level updates ───────────────────────────────────
    if (marketAtCall && selectedMarket === marketAtCall) {
      if (resp.marketStatus.length > 0) {
        cachedMarketStatus[marketAtCall] = resp.marketStatus[0];
      }
      if (resp.orderBook.length > 0) {
        // Full snapshot — replace the local state entirely
        const snapshot = resp.orderBook[0];
        const asks = new Map();
        const bids = new Map();
        for (const lvl of snapshot.asks) asks.set(lvl.price, lvl);
        for (const lvl of snapshot.bids) bids.set(lvl.price, lvl);
        orderBookState[marketAtCall] = { asks, bids };
        const rebuilt = buildSnapshotFromState(marketAtCall);
        // Cache for instant market switching
        if (!marketDataCache[marketAtCall]) marketDataCache[marketAtCall] = {};
        marketDataCache[marketAtCall].orderBook = rebuilt;
        marketDataCache[marketAtCall].timestamp = Date.now();
        renderOrderBook(rebuilt);
        setStaleIndicator("orderbook-stale", false);
      } else if (resp.orderBookDelta.length > 0) {
        // Incremental delta — merge into local state
        const delta = resp.orderBookDelta[0];
        let state = orderBookState[marketAtCall];
        if (!state) {
          // No cached state — can't apply delta; skip and wait for next poll which will get a full snapshot
          // (by resetting cachedMarketStatus version)
          cachedMarketStatus[marketAtCall] = { ...cachedMarketStatus[marketAtCall], version: 0n };
        } else {
          for (const lvl of delta.asks) {
            if (lvl.quantity > 0) state.asks.set(lvl.price, lvl);
            else state.asks.delete(lvl.price);
          }
          for (const lvl of delta.bids) {
            if (lvl.quantity > 0) state.bids.set(lvl.price, lvl);
            else state.bids.delete(lvl.price);
          }
          const rebuilt = buildSnapshotFromState(marketAtCall);
          if (!marketDataCache[marketAtCall]) marketDataCache[marketAtCall] = {};
          marketDataCache[marketAtCall].orderBook = rebuilt;
          marketDataCache[marketAtCall].timestamp = Date.now();
          renderOrderBook(rebuilt);
          setStaleIndicator("orderbook-stale", false);
        }
      }
      if (resp.newTrades.length > 0) {
        // Merge new trades into the per-market cache, keyed by id like the
        // user-trade merge below. This cache has no key of its own, and
        // getPublicTradesSince (refreshTradesIncremental) appends to the same
        // array from a cursor of its own, so the two paths can deliver the same
        // trade twice. A duplicate is not cosmetic: the tape prints the fill
        // twice and the repeated equal price colours the second copy as a
        // zero tick, and it stays until 100 later trades push it out.
        const existing = cachedMarketTrades[marketAtCall] || [];
        const seen = new Set(existing.map((t) => String(t.id)));
        const merged = existing.slice();
        for (const t of resp.newTrades) {
          if (seen.has(String(t.id))) continue;
          seen.add(String(t.id));
          merged.push(t);
        }
        cachedMarketTrades[marketAtCall] = merged.length > 100 ? merged.slice(merged.length - 100) : merged;
        // Cache for instant market switching
        if (!marketDataCache[marketAtCall]) marketDataCache[marketAtCall] = {};
        marketDataCache[marketAtCall].trades = cachedMarketTrades[marketAtCall];
        marketDataCache[marketAtCall].timestamp = Date.now();
        renderTrades(cachedMarketTrades[marketAtCall]);
        setStaleIndicator("trades-stale", false);
      } else if (!cachedMarketTrades[marketAtCall] || !cachedMarketTrades[marketAtCall].length) {
        // First poll for this market with no trades — keep empty cache
      }
    }

    // ── User-level updates ─────────────────────────────────────
    if (appState.isAuthenticated && appState.actor) {
      if (resp.userStatus.length > 0) {
        cachedUserStatus = resp.userStatus[0];
        // The user version bumped — a rejection (kill/clamp) bumps it too, so
        // surface any new one now (idempotent; safe on every change).
        checkReleaseRejections();
      }
      if (resp.userBalances.length > 0) {
        userBalances = {};
        for (const [token, amount] of resp.userBalances[0]) {
          userBalances[token] = fromE8(amount); // nested tuple — outside the boundary walker's reach
        }
        renderBalances();
        updateSwapBalances();
        renderAccountBalances();
        updateOrderSideUI();
      }
      if (resp.userOpenOrders.length > 0) {
        // Merged spot + pool orders (see refreshUserOrders) — split so the
        // margin rows stay LIVE through the poll, not only on manual refresh.
        const { mine, pool } = await splitPoolOrders(resp.userOpenOrders[0]);
        renderSwapOrders(mine);
        const isOpen = (o) => o.status.open !== undefined || o.status.partiallyFilled !== undefined;
        uomOpenOrders = mine.filter(isOpen);
        uomPoolOrders = pool.filter(isOpen);
        renderUserOrdersMobile();
        // Refresh which of these are still STAGED (off-book) so the badge tracks
        // the release. Staging and release both bump the user version, so this
        // only fires on an actual order change.
        if (appState.actor && appState.actor.getMyStagedOrderIds) {
          appState.actor.getMyStagedOrderIds().then((ids) => {
            stagedOrderIds = new Set((ids || []).map((n) => Number(n)));
            renderUserOrdersMobile();
          }).catch(() => {});
        }
      }
      if (resp.newUserTrades.length > 0) {
        // Merge new user trades into per-market history caches (newest-first).
        // Cross-market trades now stick in their own bucket rather than being
        // dropped because they don't match the current selectedMarket — fixes
        // the "Order History incomplete until I refresh" bug.
        const fresh = [...resp.newUserTrades].reverse();
        for (const t of fresh) {
          const bucket = uomTradeHistoryByMarket[t.marketId] || [];
          if (!bucket.some((x) => String(x.id) === String(t.id))) {
            bucket.unshift(t);
            if (bucket.length > 200) bucket.length = 200;
          }
          uomTradeHistoryByMarket[t.marketId] = bucket;
        }
        if (selectedMarket) renderUserOrdersMobile();
      }
      // Always refresh the pending-match list — they finalise on a timer
      // and rendering needs the live countdown. Cheap query call. Filter
      // to taker-side only: maker-side pending matches mean someone else
      // is crossing our resting order, which is already visible in Open
      // Orders, so showing them too is duplicate noise.
      try {
        const pms = await appState.actor.getMyPendingMatches();
        uomPendingMatches = pms.filter((p) => {
          if (!appState.myPrincipalText) return true; // pre-whoami, show all
          return String(p.takerPrincipal) === appState.myPrincipalText;
        });
        renderUserOrdersMobile();
      } catch (e) { /* swallow */ }
    }
  } catch (e) {
    console.warn("Failed to poll changes:", e);
  } finally {
    _pollInFlight = false;
  }
}

// Legacy alias — some code paths still call this
async function pollMarketStatus() {
  return pollChanges();
}

// Fetch new trades since the last seen trade ID, merge into cache, render
async function refreshTradesIncremental(marketId, sinceTradeId) {
  const src = appState.actor || appState.publicActor;
  if (!src) return;

  try {
    let trades;
    if (!cachedMarketTrades[marketId] || !cachedMarketTrades[marketId].length) {
      // No cache — fetch initial set
      trades = await src.getRecentPublicTrades(marketId);
      if (selectedMarket !== marketId) return;
      cachedMarketTrades[marketId] = trades; // chronological (oldest-first)
    } else {
      // Fetch only new trades since last seen ID
      const newTrades = await src.getPublicTradesSince(marketId, sinceTradeId);
      if (selectedMarket !== marketId) return;
      if (newTrades.length === 0) return;
      // Append new trades and trim to last 100
      const existing = cachedMarketTrades[marketId];
      const merged = [...existing, ...newTrades];
      // Trim to last 100
      cachedMarketTrades[marketId] = merged.length > 100 ? merged.slice(merged.length - 100) : merged;
      trades = cachedMarketTrades[marketId];
    }

    // Update cache for instant switching
    if (!marketDataCache[marketId]) marketDataCache[marketId] = {};
    marketDataCache[marketId].trades = trades;
    marketDataCache[marketId].timestamp = Date.now();

    if (selectedMarket === marketId) {
      renderTrades(trades);
      setStaleIndicator("trades-stale", false);
    }
  } catch (e) {
    console.warn("Failed to refresh trades incremental:", e);
  }
}

// Update relative trade-time spans in place: refresh the text and apply the
// newness opacity ramp (<=1s → 10%, <=2s → 20%, …). Shared by the Markets
// Trades list and the Swap page's market box so both age identically. The
// ramp caps at 0.9 — the resting span opacity the rows get from CSS — so
// clearing the inline style at 10s lands exactly on the settled look.
function tickTradeTimes(selector, trades) {
  if (!trades.length) return;
  const now = Date.now();
  document.querySelectorAll(selector).forEach((span, i) => {
    if (i >= trades.length) return;
    const ts = trades[i].timestamp;
    const ms = typeof ts === "bigint" ? Number(ts / 1000000n) : Number(ts) / 1000000;
    const ago = now - ms;
    const next = formatTime(ts);
    if (span.textContent !== next) span.textContent = next;
    if (ago < 10000) {
      span.style.opacity = String(Math.min((Math.floor(ago / 1000) + 1) * 0.1, 0.9));
    } else {
      span.style.opacity = "";   // fall back to the CSS resting 0.9
    }
  });
}

function startAutoRefresh() {
  // Fast ticker (2s): consolidated poll — single round-trip for market + user changes
  if (marketTickInterval) clearInterval(marketTickInterval);
  marketTickInterval = setInterval(pollChanges, 2000);

  // 1s ticker: update relative trade times without re-fetching
  if (tradeTimeTickInterval) clearInterval(tradeTimeTickInterval);
  tradeTimeTickInterval = setInterval(() => {
    tickTradeTimes("#recent-trades .trade-row .time", renderedTrades);
    tickTradeTimes("#swap-market-body .swap-trade-row .t", swapRenderedTrades);
  }, 1000);

  // User status + market status are now both handled by pollChanges (2s).
  // Keep a slow ticker for global public data (markets list + swap caches).
  if (statusPollInterval) { clearInterval(statusPollInterval); statusPollInterval = null; }
  if (refreshInterval) clearInterval(refreshInterval);
  refreshAllOrderBookCaches();
  pollChanges(); // immediate first consolidated poll
  refreshInterval = setInterval(() => {
    refreshAllOrderBookCaches();
    refreshMarkets();
  }, 10000);
}

async function pollUserStatus() {
  if (!appState.actor || !appState.isAuthenticated) return;
  try {
    const status = await appState.actor.getUserStatus();
    const versionChanged = !cachedUserStatus || status.version !== cachedUserStatus.version;

    if (versionChanged) {
      refreshBalances();
      refreshUserOrders();

      // Check if trade history needs incremental update. With per-market
      // caches the "have we cached anything?" check is any-market.
      if (cachedUserStatus && Object.keys(uomTradeHistoryByMarket).length > 0) {
        if (status.lastTradeTime > cachedUserStatus.lastTradeTime) {
          fetchIncrementalTradeHistory();
        }
      }

      cachedUserStatus = status;
    }
  } catch (e) {
    console.warn("Failed to poll user status:", e);
  }
}

async function fetchIncrementalTradeHistory() {
  if (!appState.actor) return;
  try {
    // Use the newest trade across all per-market buckets as the floor.
    // Going back 5s further than that closes the race-condition window
    // where a pending-match finalisation could land between a
    // bumpUserVersionWithTrade and the next poll's lastTradeTime read.
    let newestSeen = 0n;
    for (const bucket of Object.values(uomTradeHistoryByMarket)) {
      if (bucket.length > 0) {
        const ts = typeof bucket[0].timestamp === "bigint" ? bucket[0].timestamp : BigInt(bucket[0].timestamp);
        if (ts > newestSeen) newestSeen = ts;
      }
    }
    const safetyWindowNs = 5_000_000_000n;
    const sinceTimestamp = newestSeen > safetyWindowNs ? newestSeen - safetyWindowNs : 0n;

    const newTrades = await appState.actor.getMyTradeHistorySince(sinceTimestamp);
    if (newTrades.length === 0) return;

    // Route each new trade into its per-market bucket. Deduplicate against
    // whatever's already in that bucket so the safety-window overlap
    // doesn't create duplicates.
    let touched = false;
    for (const t of newTrades) {
      const bucket = uomTradeHistoryByMarket[t.marketId] || [];
      if (!bucket.some((x) => String(x.id) === String(t.id))) {
        bucket.unshift(t);
        if (bucket.length > 200) bucket.length = 200;
        uomTradeHistoryByMarket[t.marketId] = bucket;
        touched = true;
      }
    }
    if (touched && selectedMarket) renderUserOrdersMobile();
  } catch (e) {
    console.warn("Failed to fetch incremental trade history:", e);
  }
}

async function refreshAllOrderBookCaches() {
  const src = appState.actor || appState.publicActor;
  if (!src) return;
  const knownMarkets = markets.length
    ? markets.map((m) => m.id)
    : ["BTC-ICPUSD", "ETH-ICPUSD", "ICP-ICPUSD"];
  await Promise.all(knownMarkets.map((id) => fetchOrderBookForMarket(id)));
}

// ── Chart ────────────────────────────────────────────────────────
function aggregateCandles(trades, intervalMs) {
  if (!trades.length) return { candles: [], volumes: [] };

  // Convert IC nanosecond timestamps to milliseconds and sort chronologically
  const sorted = [...trades]
    .map((t) => {
      const ms = typeof t.timestamp === "bigint"
        ? Number(t.timestamp / 1000000n)
        : Number(t.timestamp) / 1000000;
      return { price: t.price, quantity: t.quantity, time: ms };
    })
    .sort((a, b) => a.time - b.time);

  const candles = [];
  const volumes = [];
  let bucketStart = Math.floor(sorted[0].time / intervalMs) * intervalMs;
  let open = sorted[0].price;
  let high = sorted[0].price;
  let low = sorted[0].price;
  let close = sorted[0].price;
  let vol = 0;

  for (const t of sorted) {
    const bucket = Math.floor(t.time / intervalMs) * intervalMs;
    if (bucket !== bucketStart) {
      // Push completed candle
      const ts = Math.floor(bucketStart / 1000); // lightweight-charts uses Unix seconds
      candles.push({ time: ts, open, high, low, close });
      volumes.push({ time: ts, value: vol, color: close >= open ? "rgba(94,230,180,0.4)" : "rgba(240,122,108,0.4)" });
      // Start new bucket
      bucketStart = bucket;
      open = t.price;
      high = t.price;
      low = t.price;
      close = t.price;
      vol = 0;
    }
    high = Math.max(high, t.price);
    low = Math.min(low, t.price);
    close = t.price;
    vol += t.quantity;
  }
  // Push final candle
  const ts = Math.floor(bucketStart / 1000);
  candles.push({ time: ts, open, high, low, close });
  volumes.push({ time: ts, value: vol, color: close >= open ? "rgba(94,230,180,0.4)" : "rgba(240,122,108,0.4)" });

  return { candles, volumes };
}

// Set chart to show last N candles, scrolled to current time
function showLastCandles(chart, totalCandles) {
  if (totalCandles > CHART_VISIBLE_CANDLES) {
    chart.timeScale().setVisibleLogicalRange({
      from: totalCandles - CHART_VISIBLE_CANDLES,
      to: totalCandles - 1,
    });
  } else {
    chart.timeScale().fitContent();
  }
  chart.timeScale().scrollToRealTime();
}

// Convert backend candles (ns timestamps) to LightweightCharts format.
// Fills gaps between existing candles with whitespace markers so the time axis
// visibly shows periods with no trading activity.
// Timestamps are passed through as real UTC seconds — timezone display is
// handled by the chart's localization.timeFormatter.
function backendCandlesToChart(backendCandles, intervalMs) {
  const candles = [];
  const volumes = [];
  if (!backendCandles.length) return { candles, volumes };

  const intervalSec = intervalMs ? Math.floor(intervalMs / 1000) : 0;

  for (let i = 0; i < backendCandles.length; i++) {
    const c = backendCandles[i];
    const ts = Math.floor(Number(c.time) / 1_000_000_000);

    // Fill gap between previous candle and this one
    if (i > 0 && intervalSec > 0) {
      const prevTs = Math.floor(Number(backendCandles[i - 1].time) / 1_000_000_000);
      let gapTs = prevTs + intervalSec;
      while (gapTs < ts) {
        candles.push({ time: gapTs }); // whitespace marker
        volumes.push({ time: gapTs });
        gapTs += intervalSec;
      }
    }

    // volume === 0 marks a clock-fill candle (no trades that bucket — the
    // backend records the oracle price for continuity). Render in the accent
    // cyan so quiet stretches read as a bright oracle-tracking line, visibly
    // distinct from the green/red of real trading.
    const synthetic = Number(c.volume) === 0;
    const track = "rgba(56, 189, 240, 0.9)";
    candles.push({ time: ts, open: c.open, high: c.high, low: c.low, close: c.close,
      ...(synthetic ? { color: track, borderColor: track, wickColor: track } : {}) });
    volumes.push({ time: ts, value: c.volume, color: c.close >= c.open ? "rgba(94,230,180,0.4)" : "rgba(240,122,108,0.4)" });
  }
  return { candles, volumes };
}

async function openChart() {
  if (!selectedMarket) return;
  const src = appState.actor || appState.publicActor;
  if (!src) return;

  const overlay = document.getElementById("chart-overlay");
  overlay.style.display = "flex";
  document.getElementById("chart-title").textContent = selectedMarket;

  // Fetch candles from backend (server-side aggregation)
  chartCurrentPage = 0;
  chartHasMore = false;
  chartLoadingMore = false;
  try {
    const resp = await src.getCandles(selectedMarket, chartInterval, 0);
    chartCandleData = backendCandlesToChart(resp.candles, chartInterval);
    chartHasMore = resp.hasMore;
  } catch (e) {
    console.warn("Failed to fetch candles for chart:", e);
    chartCandleData = { candles: [], volumes: [] };
  }

  // Set active interval button
  document.querySelectorAll(".chart-interval-btn").forEach((b) => {
    b.classList.toggle("active", Number(b.dataset.interval) === chartInterval);
  });

  renderChartData();

  // Start live-refresh so new trades appear while chart is open
  if (chartRefreshInterval) clearInterval(chartRefreshInterval);
  chartRefreshInterval = setInterval(refreshChartData, 5000);
}

function renderChartData() {
  const container = document.getElementById("chart-container");

  // Destroy previous chart
  if (chartInstance) {
    chartInstance.remove();
    chartInstance = null;
    chartCandleSeries = null;
    chartVolumeSeries = null;
  }

  // (No "chart library not loaded" branch any more: the charting code is
  // imported into this bundle, so if it were missing this module would never
  // have evaluated. It used to arrive from a CDN <script> that could silently
  // fail to load — or silently load something else.)

  if (!chartCandleData || !chartCandleData.candles.length) {
    container.innerHTML = '<div class="empty-state" style="padding:40px">No trade data available</div>';
    return;
  }

  container.innerHTML = "";

  const { candles, volumes } = chartCandleData;

  chartInstance = createChart(container, {
    width: container.clientWidth,
    height: container.clientHeight,
    layout: {
      background: { type: "solid", color: "transparent" },
      textColor: "#7A8699", // Fog
      fontSize: 12,
      panes: {
        separatorColor: "rgba(34,46,64,0.7)",
        separatorHoverColor: "rgba(59,184,212,0.35)",
        enableResize: false,
      },
    },
    grid: {
      // Ridge at low opacity
      vertLines: { color: "rgba(34,46,64,0.5)" },
      horzLines: { color: "rgba(34,46,64,0.5)" },
    },
    crosshair: {
      mode: 0,
      // Glacier at ~50% opacity — dashed crosshair per design spec
      vertLine: { color: "rgba(59,184,212,0.5)", width: 1, style: 2 },
      horzLine: { color: "rgba(59,184,212,0.5)", width: 1, style: 2 },
    },
    localization: {
      timeFormatter: (time) => {
        const d = new Date(time * 1000);
        return d.toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false });
      },
    },
    timeScale: {
      borderColor: "rgba(34,46,64,0.7)",
      timeVisible: true,
      secondsVisible: false,
      tickMarkFormatter: (time) => {
        const d = new Date(time * 1000);
        return d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit", hour12: false });
      },
    },
    rightPriceScale: {
      borderColor: "rgba(34,46,64,0.7)",
    },
  });

  // Candle series → pane 0 (main pane); volume histogram → pane 1 (its
  // own pane below). v5's pane API gives each pane its own right-axis
  // region, so price labels render only in the candle pane and volume
  // labels only in the volume pane — no more shared/overlapping axis.
  chartCandleSeries = chartInstance.addSeries(
    CandlestickSeries,
    {
      upColor: "#5EE6B4",       // Alpine Mint
      downColor: "#F07A6C",     // Ember Clay
      borderUpColor: "#5EE6B4",
      borderDownColor: "#F07A6C",
      wickUpColor: "#5EE6B4",
      wickDownColor: "#F07A6C",
    },
    0,
  );
  chartInstance.priceScale("right").applyOptions({
    scaleMargins: { top: 0.10, bottom: 0.08 },
  });
  chartCandleSeries.setData(candles);

  chartVolumeSeries = chartInstance.addSeries(
    HistogramSeries,
    { priceFormat: { type: "volume" } },
    1,
  );
  chartVolumeSeries.setData(volumes);

  // Size the volume pane to ~20% of total chart height.
  requestAnimationFrame(() => {
    if (!chartInstance) return;
    const panes = chartInstance.panes();
    if (panes.length >= 2) {
      const h = container.clientHeight;
      if (h > 0) panes[1].setHeight(Math.round(h * 0.20));
    }
  });

  showLastCandles(chartInstance, candles.length);

  // Scroll-to-load: when user scrolls near the left edge, load older candles
  chartInstance.timeScale().subscribeVisibleLogicalRangeChange((range) => {
    if (!range || !chartHasMore || chartLoadingMore) return;
    // If the visible range starts near or before index 5, load more
    if (range.from < 5) {
      loadOlderCandles();
    }
  });

  // Resize observer
  const ro = new ResizeObserver(() => {
    if (chartInstance) {
      chartInstance.applyOptions({
        width: container.clientWidth,
        height: container.clientHeight,
      });
    }
  });
  ro.observe(container);
}

async function loadOlderCandles() {
  if (chartLoadingMore || !chartHasMore || !selectedMarket) return;
  chartLoadingMore = true;
  const src = appState.actor || appState.publicActor;
  if (!src) { chartLoadingMore = false; return; }
  try {
    chartCurrentPage += 1;
    const resp = await src.getCandles(selectedMarket, chartInterval, chartCurrentPage);
    chartHasMore = resp.hasMore;
    if (resp.candles.length) {
      const older = backendCandlesToChart(resp.candles, chartInterval);
      // Prepend older candles to existing data
      chartCandleData.candles = [...older.candles, ...chartCandleData.candles];
      chartCandleData.volumes = [...older.volumes, ...chartCandleData.volumes];
      if (chartCandleSeries) chartCandleSeries.setData(chartCandleData.candles);
      if (chartVolumeSeries) chartVolumeSeries.setData(chartCandleData.volumes);
    }
  } catch (e) {
    console.warn("Failed to load older candles:", e);
    chartCurrentPage -= 1; // revert so retry is possible
  } finally {
    chartLoadingMore = false;
  }
}

async function changeChartInterval(intervalMs) {
  chartInterval = intervalMs;
  document.querySelectorAll(".chart-interval-btn").forEach((b) => {
    b.classList.toggle("active", Number(b.dataset.interval) === chartInterval);
  });
  // Re-fetch candles from backend with new interval
  chartCurrentPage = 0;
  chartHasMore = false;
  chartLoadingMore = false;
  const src = appState.actor || appState.publicActor;
  if (src && selectedMarket) {
    try {
      const resp = await src.getCandles(selectedMarket, chartInterval, 0);
      chartCandleData = backendCandlesToChart(resp.candles, chartInterval);
      chartHasMore = resp.hasMore;
      if (chartInstance && chartCandleSeries && chartVolumeSeries && chartCandleData.candles.length) {
        chartCandleSeries.setData(chartCandleData.candles);
        chartVolumeSeries.setData(chartCandleData.volumes);
        showLastCandles(chartInstance, chartCandleData.candles.length);
      } else {
        renderChartData();
      }
    } catch (e) {
      console.warn("Failed to fetch candles:", e);
    }
  }
}

// Refresh chart data — re-fetch page 0 candles from backend
async function refreshChartData() {
  if (!selectedMarket || !chartInstance) return;
  // A page load in flight owns chartCurrentPage and will prepend its result
  // onto whatever is loaded when it lands; replacing the series underneath it
  // would splice an older page straight onto a fresh page 0. Skip the tick —
  // the next one is 5s away.
  if (chartLoadingMore) return;
  const src = appState.actor || appState.publicActor;
  if (!src) return;
  try {
    const resp = await src.getCandles(selectedMarket, chartInterval, 0);
    chartCandleData = backendCandlesToChart(resp.candles, chartInterval);
    // The series is page 0 and nothing else again, so the paging cursor goes
    // back with it, exactly as changeChartInterval does after the same
    // refetch. loadOlderCandles increments the cursor and prepends, so a
    // cursor left at 3 would put page 4 next to page 0 with pages 1-3 missing
    // — a discontinuous price history presented as continuous, and one that
    // never repairs itself because those pages are never refetched.
    chartCurrentPage = 0;
    chartHasMore = resp.hasMore;
    if (chartCandleSeries) chartCandleSeries.setData(chartCandleData.candles);
    if (chartVolumeSeries) chartVolumeSeries.setData(chartCandleData.volumes);
  } catch (e) {
    console.warn("Failed to refresh chart data:", e);
  }
}

function closeChart() {
  if (chartRefreshInterval) {
    clearInterval(chartRefreshInterval);
    chartRefreshInterval = null;
  }
  const overlay = document.getElementById("chart-overlay");
  overlay.style.display = "none";
  if (chartInstance) {
    chartInstance.remove();
    chartInstance = null;
    chartCandleSeries = null;
    chartVolumeSeries = null;
  }
}

// ── Mini Chart (mobile inline) ──────────────────────────────────
function isMobile() { return window.innerWidth <= 900; }

async function renderMiniChart() {
  const container = document.getElementById("mini-chart");
  if (!container || !selectedMarket) return;

  const src = appState.actor || appState.publicActor;
  if (!src) return;

  const marketAtCall = selectedMarket;

  // Destroy previous mini chart
  if (miniChartInstance) {
    miniChartInstance.remove();
    miniChartInstance = null;
    miniChartSeries = null;
    miniChartVolumeSeries = null;
  }

  // Show container and build shell IMMEDIATELY (before data loads)
  container.style.display = '';
  container.classList.remove("mini-chart-collapsed");

  const intervals = [
    { label: "1m", ms: 60000 },
    { label: "5m", ms: 300000 },
    { label: "15m", ms: 900000 },
    { label: "1H", ms: 3600000 },
    { label: "4H", ms: 14400000 },
    { label: "1D", ms: 86400000 },
    { label: "1W", ms: 604800000 },
  ];
  // View dropdown replaces the old Hide toggle: chart | liquidations | hide.
  // The liquidation map SHARES this cell rather than claiming its own slab of
  // page. `hide` drops the current view from the menu (you cannot re-select
  // what you are already looking at, and while hidden there is nothing to
  // hide), which is why the item list is rebuilt on every render.
  container.innerHTML = `<div class="mini-chart-bar">${intervals.map((iv) =>
    `<button class="mini-chart-iv${iv.ms === miniChartCandleInterval ? " active" : ""}" data-ms="${iv.ms}">${iv.label}</button>`
  ).join("")}<div class="mini-chart-view" id="mini-chart-view">`
    + `<span class="mcv-label" id="mcv-label"></span>`
    + `<svg width="10" height="10" viewBox="0 0 10 10" fill="none"><path d="M2.5 4L5 6.5L7.5 4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>`
    + `<div class="mcv-menu" id="mcv-menu"></div></div></div>`
    + `<div class="mini-chart-canvas" id="mini-chart-canvas"></div>`
    + `<div class="mini-chart-heat heatmap" id="mini-chart-heat"></div>`;

  const canvasEl = document.getElementById("mini-chart-canvas");

  // Create empty chart immediately (visible as empty grid).
  // Size to the container's actual rect so it fills a grid cell on desktop.
  const initialH = canvasEl.clientHeight || (isMobile() ? 170 : 260);
  miniChartInstance = createChart(canvasEl, {
    width: canvasEl.clientWidth,
    height: initialH,
    layout: {
      background: { type: "solid", color: "transparent" },
      textColor: "#7A8699",
      fontSize: isMobile() ? 10 : 11,
      // v5 pane separator — the horizontal divider between candle and
      // volume panes. Ridge at ~60% opacity matches other internal borders.
      panes: {
        separatorColor: "rgba(34,46,64,0.6)",
        separatorHoverColor: "rgba(59,184,212,0.35)",
        enableResize: false,
      },
    },
    grid: { vertLines: { color: "rgba(34,46,64,0.4)" }, horzLines: { color: "rgba(34,46,64,0.4)" } },
    crosshair: {
      mode: 0,
      // Glacier at ~50% opacity — dashed crosshair per design spec
      vertLine: { color: "rgba(59,184,212,0.5)", width: 1, style: 2 },
      horzLine: { color: "rgba(59,184,212,0.5)", width: 1, style: 2 },
    },
    localization: {
      timeFormatter: (time) => {
        const d = new Date(time * 1000);
        return d.toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false });
      },
    },
    timeScale: {
      borderColor: "rgba(34,46,64,0.5)",
      timeVisible: true,
      secondsVisible: false,
      tickMarkFormatter: (time) => {
        const d = new Date(time * 1000);
        return d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit", hour12: false });
      },
    },
    // Candle pane's right-axis scale: small top margin leaves a bit of
    // headroom for price labels. The candle pane's size (as a fraction of
    // total chart height) is controlled separately via panes[1].setHeight()
    // below — v5's pane API is what gives us separate right-axis regions
    // for price vs. volume labels.
    rightPriceScale: { borderColor: "rgba(34,46,64,0.5)", scaleMargins: { top: 0.15, bottom: 0.10 } },
    handleScroll: true,
    handleScale: true,
  });

  // Candle series → pane 0 (default main pane)
  miniChartSeries = miniChartInstance.addSeries(
    CandlestickSeries,
    {
      upColor: "#5EE6B4", downColor: "#F07A6C",
      borderUpColor: "#5EE6B4", borderDownColor: "#F07A6C",
      wickUpColor: "#5EE6B4", wickDownColor: "#F07A6C",
    },
    0,
  );

  // Volume histogram → pane 1 (a new pane below the candle pane).
  // In v5 each pane has its own price-axis region, so volume labels
  // (100, 200, 300…) render ONLY in the volume pane's right axis and
  // price labels ONLY in the candle pane's — no more overlap.
  miniChartVolumeSeries = miniChartInstance.addSeries(
    HistogramSeries,
    { priceFormat: { type: "volume" } },
    1,
  );

  // Make the volume pane small (~20% of chart height). Default is even split.
  // Wait a frame so the chart has finalized its initial layout.
  requestAnimationFrame(() => {
    if (!miniChartInstance) return;
    const panes = miniChartInstance.panes();
    if (panes.length >= 2) {
      const h = canvasEl.clientHeight;
      if (h > 0) panes[1].setHeight(Math.round(h * 0.20));
    }
  });

  // Mini chart pagination state (declared before the ResizeObserver so the
  // observer's closure can see the latest candle array on the first resize).
  let miniPage = 0;
  let miniHasMore = false;
  let miniLoadingMore = false;
  let miniAllCandles = [];
  let miniAllVolumes = [];

  // Resize observer — track both width and height so the chart fills its grid cell.
  // The first real layout can happen after chart creation (grid cell was 0×0
  // during the same tick the Markets tab became visible), so re-anchor the
  // visible range on the first meaningful resize.
  let roFirstRealResize = true;
  const ro = new ResizeObserver(() => {
    if (!miniChartInstance) return;
    const w = canvasEl.clientWidth;
    const h = canvasEl.clientHeight;
    if (w > 0 && h > 0) {
      miniChartInstance.applyOptions({ width: w, height: h });
      if (roFirstRealResize && miniAllCandles && miniAllCandles.length) {
        roFirstRealResize = false;
        showLastCandles(miniChartInstance, miniAllCandles.length);
      }
    }
  });
  ro.observe(canvasEl);

  // Scroll-to-load: fetch older candles when user drags near left edge
  miniChartInstance.timeScale().subscribeVisibleLogicalRangeChange((range) => {
    if (!range || !miniHasMore || miniLoadingMore) return;
    if (range.from < 5) {
      miniLoadingMore = true;
      miniPage += 1;
      src.getCandles(selectedMarket, miniChartCandleInterval, miniPage).then((resp) => {
        miniHasMore = resp.hasMore;
        if (resp.candles.length) {
          const older = backendCandlesToChart(resp.candles, miniChartCandleInterval);
          miniAllCandles = [...older.candles, ...miniAllCandles];
          miniAllVolumes = [...older.volumes, ...miniAllVolumes];
          if (miniChartSeries) miniChartSeries.setData(miniAllCandles);
          if (miniChartVolumeSeries) miniChartVolumeSeries.setData(miniAllVolumes);
        }
      }).catch(() => { miniPage -= 1; }).finally(() => { miniLoadingMore = false; });
    }
  });

  // Interval button click handlers
  container.querySelectorAll(".mini-chart-iv").forEach((btn) => {
    btn.addEventListener("click", async () => {
      miniChartCandleInterval = Number(btn.dataset.ms);
      container.querySelectorAll(".mini-chart-iv").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      miniPage = 0;
      miniHasMore = false;
      try {
        const resp = await src.getCandles(selectedMarket, miniChartCandleInterval, 0);
        miniHasMore = resp.hasMore;
        const conv = backendCandlesToChart(resp.candles, miniChartCandleInterval);
        miniAllCandles = conv.candles;
        miniAllVolumes = conv.volumes;
        if (miniChartSeries) { miniChartSeries.setData(miniAllCandles); showLastCandles(miniChartInstance, miniAllCandles.length); }
        if (miniChartVolumeSeries) miniChartVolumeSeries.setData(miniAllVolumes);
      } catch (e) { console.warn("Failed to change mini chart interval:", e); }
    });
  });

  // View dropdown: chart | liquidations | hide
  applyChartView(container);
  const viewEl = container.querySelector("#mini-chart-view");
  viewEl.addEventListener("click", (e) => {
    const item = e.target.closest(".mcv-item");
    if (item) {
      setChartView(item.dataset.view);
      viewEl.classList.remove("open");
      e.stopPropagation();
      return;
    }
    viewEl.classList.toggle("open");
    e.stopPropagation();
  });

  // Now fetch data asynchronously and draw when ready
  try {
    const resp = await src.getCandles(marketAtCall, miniChartCandleInterval, 0);
    if (selectedMarket !== marketAtCall) return; // market changed
    miniHasMore = resp.hasMore;
    const conv = backendCandlesToChart(resp.candles, miniChartCandleInterval);
    miniAllCandles = conv.candles;
    miniAllVolumes = conv.volumes;
    if (miniChartSeries && miniAllCandles.length) {
      miniChartSeries.setData(miniAllCandles);
      showLastCandles(miniChartInstance, miniAllCandles.length);
    }
    if (miniChartVolumeSeries && miniAllVolumes.length) {
      miniChartVolumeSeries.setData(miniAllVolumes);
    }
  } catch (e) {
    console.warn("Failed to fetch candles for mini chart:", e);
  }
}

async function refreshMiniChart() {
  if (!miniChartInstance || !miniChartSeries || !selectedMarket) return;
  const src = appState.actor || appState.publicActor;
  if (!src) return;
  try {
    // Only refresh the latest page — don't reset scroll position
    const resp = await src.getCandles(selectedMarket, miniChartCandleInterval, 0);
    const conv = backendCandlesToChart(resp.candles, miniChartCandleInterval);
    if (conv.candles.length && miniChartSeries) {
      miniChartSeries.setData(conv.candles);
    }
    if (conv.volumes.length && miniChartVolumeSeries) {
      miniChartVolumeSeries.setData(conv.volumes);
    }
  } catch (e) { /* ignore */ }
}

function destroyMiniChart() {
  if (miniChartRefreshInterval) { clearInterval(miniChartRefreshInterval); miniChartRefreshInterval = null; }
  if (miniChartInstance) {
    miniChartInstance.remove();
    miniChartInstance = null;
    miniChartSeries = null;
    miniChartVolumeSeries = null;
  }
  const container = document.getElementById("mini-chart");
  if (container) { container.innerHTML = ""; container.style.display = "none"; }
}

// ── Account Page ─────────────────────────────────────────────────
function renderAccountPage() {
  const signinPrompt  = document.getElementById("account-signin-prompt");
  const profileCard   = document.getElementById("account-profile-card");
  const balancesCard  = document.getElementById("account-balances-card");
  const openOrdersCard = document.getElementById("account-open-orders-card");
  const closedOrdersCard = document.getElementById("account-closed-orders-card");
  const tradesCard    = document.getElementById("account-trades-card");
  const adjCard       = document.getElementById("account-adjustments-card");
  const depositsCard  = document.getElementById("account-deposits-card");

  const tabsEl = document.getElementById("account-tabs");
  const panes = ACCT_TABS.map((t) => document.getElementById("acct-pane-" + t)).filter(Boolean);
  const extraCards = ["all-value-card", "pool-transfers-card", "positions-history-card", "pools-history-card", "earn-vault-card", "earn-insurance-card"]
    .map((id) => document.getElementById(id)).filter(Boolean);
  if (!appState.isAuthenticated) {
    signinPrompt.style.display = "block";
    profileCard.style.display  = "none";
    if (tabsEl) tabsEl.style.display = "none";
    panes.forEach((p) => { p.style.display = "none"; });
    extraCards.forEach((c) => { c.style.display = "none"; });
    balancesCard.style.display = "none";
    if (openOrdersCard) openOrdersCard.style.display = "none";
    if (closedOrdersCard) closedOrdersCard.style.display = "none";
    tradesCard.style.display   = "none";
    adjCard.style.display      = "none";
    depositsCard.style.display = "none";
    return;
  }

  signinPrompt.style.display = "none";
  profileCard.style.display  = "block";
  if (tabsEl) tabsEl.style.display = "flex";
  extraCards.forEach((c) => { c.style.display = "block"; });
  showAccountTab(acctTab);   // reveals the active pane, hides the rest
  balancesCard.style.display = "block";
  if (openOrdersCard) openOrdersCard.style.display = "block";
  if (closedOrdersCard) closedOrdersCard.style.display = "block";
  tradesCard.style.display   = "block";
  adjCard.style.display      = "block";
  depositsCard.style.display = "block";
  const positionsCard = document.getElementById("positions-card");
  if (positionsCard) positionsCard.style.display = "block";
}

function renderAccountProfile() {
  if (!userProfile) return;

  const avatarLarge  = document.getElementById("profile-avatar-large");
  const usernameEl   = document.getElementById("profile-username");
  const useridEl     = document.getElementById("profile-userid");
  const metaEl       = document.getElementById("profile-meta");
  const regenBtn     = document.getElementById("regen-username-btn");
  const regenRemEl   = document.getElementById("regen-remaining");

  const initial = userProfile.username ? userProfile.username[0].toUpperCase() : "?";
  setIdenticon(avatarLarge, userProfile.username, initial);   // username-seeded — see updateUserMenu
  usernameEl.textContent  = userProfile.username || "—";
  useridEl.textContent    = "ID: " + (userProfile.userId || "—");

  // Your full principal — the exact key the exchange scopes your data by, and
  // what you'd filter the public order book on (or hand to an external tool /
  // the IC Connector). Shown here because the friendly username is what appears
  // everywhere else; this is the one place to read & copy the raw principal.
  const principalEl = document.getElementById("profile-principal");
  if (principalEl) principalEl.textContent = appState.myPrincipalText || "—";

  const ts = typeof userProfile.createdAt === "bigint"
    ? Number(userProfile.createdAt / 1000000n)
    : Number(userProfile.createdAt) / 1000000;
  metaEl.textContent = "Member since " + new Date(ts).toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" });

  const remaining = 5 - Number(userProfile.regenCount);
  regenRemEl.textContent = remaining + " regeneration" + (remaining !== 1 ? "s" : "") + " remaining";
  regenBtn.disabled = remaining <= 0;
}

// Render the balance grid in isolation. Pulled out so refreshBidHeadroom
// can re-render the grid after caching the margin account (the first
// renderAccountBalances pass runs BEFORE the headroom fetch resolves, so
// the breakdown wouldn't appear until the next poll without this).
// ── Status tab (Account → Status) ──────────────────────────────────
// Surfaces getAccessPolicy: the caller's EARNED fee level (with progress to the
// next), what the level buys (fees + access rank + quote shield), the rolling
// scorecard, and the badge shelf. Everything is algorithmic — no operator
// grants — and level bars scale down while exchange volume is young.
// All figures are base-unit Nats (not money.js-wrapped) → ÷1e8.
const BADGE_META = [
  { id: 1, icon: "🌱", name: "DeFi 2.0 User", how: "Join — make your first deposit" },
  { id: 2, icon: "⚡", name: "First Fill", how: "Settle your first trade" },
  { id: 3, icon: "🎮", name: "MULTI/DEX Player", how: "$10k lifetime volume" },
  { id: 4, icon: "🔨", name: "Maker Clout", how: "$100k lifetime maker volume" },
  { id: 5, icon: "⚖️", name: "Two-Sided", how: "Pass a quote-uptime sample: a two-sided book within ±1% of mid" },
  { id: 6, icon: "📈", name: "Market Mover", how: "$500k lifetime volume" },
  { id: 7, icon: "🛡️", name: "Iron Quoter", how: "Hold ≥50% quote uptime across a full sampling window" },
  { id: 8, icon: "🐋", name: "Whale", how: "$10M lifetime volume" },
  { id: 9, icon: "🏛️", name: "Market Pillar", how: "$10M lifetime maker volume" },
];

// Per-badge progress in [0,1], or null when it isn't a meter (event badges).
function badgeProgress(id, pol) {
  const n = (x) => Number(x);
  const volBars = new Map((pol.thresholds.badgeVolUsd || []).map(([b, v]) => [Number(b), Number(v)]));
  switch (id) {
    case 1: return null;                                   // join — event
    case 2: return n(pol.myLifetimeVolUsd) > 0 ? 1 : 0;    // first fill
    case 3: case 6: case 8:
      return Math.min(1, n(pol.myLifetimeVolUsd) / (volBars.get(id) || 1));
    case 4: case 9:
      return Math.min(1, n(pol.myLifetimeMakerVolUsd) / (volBars.get(id) || 1));
    case 5: return null;                                   // first passed sample — event
    case 7: {                                              // sustained uptime
      const pct = pol.myUptimePct.length ? n(pol.myUptimePct[0]) : 0;
      const dwell = Math.min(1, n(pol.myUptimeSamples) / n(pol.thresholds.mmMinSamples || 20));
      return Math.min(1, dwell * Math.min(1, pct / n(pol.thresholds.mmMinUptimePct || 50)));
    }
    default: return null;
  }
}

async function refreshStatusTab() {
  const card = document.getElementById("status-card");
  const badgesCard = document.getElementById("badges-card");
  if (!card) return;
  if (!appState.isAuthenticated || !appState.actor) {
    card.style.display = "none";
    if (badgesCard) badgesCard.style.display = "none";
    return;
  }
  let pol;
  try { pol = await appState.actor.getAccessPolicy(); }
  catch (e) { console.warn("getAccessPolicy:", e); card.style.display = "none"; return; }
  card.style.display = "";
  if (badgesCard) badgesCard.style.display = "";

  const usd = (n) => Number(n) / 1e8;
  const fmtUsd = (n) => "$" + usd(n).toLocaleString(undefined, { maximumFractionDigits: 0 });
  const bps = (tenth) => (Number(tenth) / 10).toLocaleString(undefined, { maximumFractionDigits: 1 });
  const lvl = Number(pol.myLevel);
  const th = pol.thresholds;

  // Level badge
  const badge = document.getElementById("status-level-badge");
  badge.textContent = "Level " + lvl + (lvl === 4 ? " · Market Maker" : "");
  badge.className = "tier-badge tier-l" + lvl;

  // Fees now (and the carrot: next level's rates)
  const feesNote = document.getElementById("status-fees-note");
  const sched = pol.feeTenthBps;
  let feesTxt = `maker ${bps(pol.myMakerFeeTenthBps)} bps / taker ${bps(pol.myTakerFeeTenthBps)} bps`;
  if (lvl < 4 && sched[lvl + 1]) {
    feesTxt += ` — next level: ${bps(sched[lvl + 1][0])} / ${bps(sched[lvl + 1][1])}`;
  }
  feesNote.textContent = feesTxt;

  // Next-level progress (weighted volume vs the CURRENT effective bar)
  const nextRow = document.getElementById("status-next-row");
  const w = usd(pol.myWeightedVolUsd);
  if (lvl >= 4) {
    nextRow.style.display = "";
    document.getElementById("status-next-note").textContent =
      `Top level. Keep weighted volume ≥ ${fmtUsd(pol.levelThresholdsUsd[3])} and uptime ≥ ${Number(th.mmMinUptimePct)}% to hold it.`;
    document.getElementById("status-next-bar").style.width = "100%";
  } else {
    nextRow.style.display = "";
    const bar = usd(pol.levelThresholdsUsd[lvl]);
    const pct = Math.min(100, bar > 0 ? (w / bar) * 100 : 0);
    const uptimeNote = lvl === 3 ? " + two-sided quote uptime ≥ " + Number(th.mmMinUptimePct) + "%" : "";
    document.getElementById("status-next-note").textContent =
      `${fmtUsd(pol.myWeightedVolUsd)} of ${fmtUsd(pol.levelThresholdsUsd[lvl])} weighted volume for L${lvl + 1}${uptimeNote}`;
    document.getElementById("status-next-bar").style.width = pct.toFixed(0) + "%";
  }

  // Scorecard row
  document.getElementById("status-vol-note").textContent =
    `maker ${fmtUsd(pol.myMakerVolUsd)} (counts ×${Number(th.makerWeight)}) + taker ${fmtUsd(pol.myTakerVolUsd)} → weighted ${fmtUsd(pol.myWeightedVolUsd)}`;

  // Uptime row
  const upNote = document.getElementById("status-uptime-note");
  const samples = Number(pol.myUptimeSamples);
  if (pol.myUptimePct.length && samples > 0) {
    const pct = Number(pol.myUptimePct[0]);
    upNote.textContent = `${pct}% over ${samples} samples — two-sided within ±${Number(th.mmMaxSpreadBps) / 100}% at ≥ ${fmtUsd(th.mmMinDepthUsd)}/side; L4 needs ≥ ${Number(th.mmMinUptimePct)}% across ${Number(th.mmMinSamples)}+`;
  } else {
    upNote.textContent = `not sampled yet — keep resting orders on both sides of a book (±${Number(th.mmMaxSpreadBps) / 100}% of mid, ≥ ${fmtUsd(th.mmMinDepthUsd)}/side) to build uptime`;
  }

  // Priority meaning
  const rank = Number(pol.myRank);
  document.getElementById("status-rank-note").textContent = rank >= 2
    ? "Highest — your orders release first at every settlement pass" + (lvl === 4 ? ", your fresh quotes are snipe-shielded," : "") + " and you keep access under any load."
    : rank === 1
      ? "Elevated — ahead of level-0 flow at each settlement pass; access kept under moderate load."
      : "Standard — first-come within your rank; under heavy load, this rank is shed first.";

  // Staged slots + min order
  document.getElementById("status-staged-note").textContent =
    `${Number(pol.myStagedCount)} of ${Number(th.stagedCapPerOwner)} slots in use`;
  document.getElementById("status-min-note").textContent =
    `${usd(th.minOrderNotionalUsd)} ICPUSD notional — orders spending your entire remaining balance are exempt`;
  const hint = document.getElementById("min-order-value");
  if (hint) hint.textContent = usd(th.minOrderNotionalUsd).toLocaleString();

  // Threshold-scaling note (the "early participants" mechanic, in numbers)
  const scaleNote = document.getElementById("status-scale-note");
  if (scaleNote) {
    scaleNote.textContent = `currently ${(Number(pol.scaleBps) / 100).toLocaleString(undefined, { maximumFractionDigits: 2 })}% of full — exchange 30-day volume ${fmtUsd(pol.exchangeVolUsd)} vs ${fmtUsd(th.refExchangeVolUsd)} reference`;
  }

  // Load-shed banner
  const bannerEl = document.getElementById("status-shed-banner");
  const floor = Number(pol.shedFloor);
  if (floor > 0) {
    const affected = rank < floor;
    bannerEl.style.display = "";
    bannerEl.className = "access-shed-banner " + (affected ? "shed-affected" : "shed-safe");
    bannerEl.textContent = affected
      ? `⚠ The exchange is under heavy load and your rank is temporarily shed at the gate — orders will be refused until load drops. Queries still work.`
      : `The exchange is under load (rank floor ${floor}) — your level keeps full access.`;
  } else { bannerEl.style.display = "none"; }

  // ── Badge shelf (All tab) — the trophy case: EARNED badges only. Locked
  // ones aren't displayed as greyed goals here; the "next badge" nudge below
  // keeps one visible target and Docs carries the full catalog.
  const shelf = document.getElementById("badge-shelf");
  const nextEl = document.getElementById("badge-next");
  const countEl = document.getElementById("badges-count");
  if (!shelf) return;
  const earned = new Map(pol.myBadges.map(([id, ts]) => [Number(id), Number(ts)]));
  countEl.textContent = `${earned.size} of ${BADGE_META.length}`;
  const chips = BADGE_META.filter((b) => earned.has(b.id)).map((b) => {
    const d = new Date(earned.get(b.id) / 1e6).toLocaleDateString();
    return `<div class="badge-chip badge-earned" title="${b.how}">
      <span class="badge-icon">${b.icon}</span>
      <span class="badge-name">${b.name}</span>
      <span class="badge-sub">earned ${d}</span></div>`;
  });
  shelf.innerHTML = chips.length ? chips.join("")
    : `<div class="empty-state">No badges yet — they mint automatically at lifetime milestones, starting with your first deposit.</div>`;

  // "Next up": the first unearned badge, with its meter spelled out
  const next = BADGE_META.find((b) => !earned.has(b.id));
  if (next && nextEl) {
    const prog = badgeProgress(next.id, pol);
    const pctTxt = prog !== null ? ` — ${(prog * 100).toFixed(0)}% there` : "";
    nextEl.style.display = "";
    nextEl.innerHTML = `<span class="badge-icon">${next.icon}</span> <b>Next badge: ${next.name}</b> — ${next.how}${pctTxt}`;
  } else if (nextEl) {
    nextEl.style.display = earned.size === BADGE_META.length ? "" : "none";
    if (earned.size === BADGE_META.length) nextEl.innerHTML = `🏆 <b>All badges earned.</b>`;
  }
}

function renderBalancesGrid() {
  const grid = document.getElementById("account-balances-grid");
  if (!grid) return;
  const tokens = ["ICPUSD", "BTC", "ETH", "SOL", "ICP"];
  // Cross-margin: there's no hard lock. Balances are plain; a margin
  // user's whole balance is collateral but stays fully spendable, so
  // there's no free/locked split to show here. The margin card's
  // collateral table + health bar carry the margin view.
  // A list (one row per token), not a box-per-token grid — scales cleanly as
  // the number of holdable tokens grows.
  // Each figure is click-to-fill: it selects the asset in the Withdraw row
  // and fills the amount (data-bal carries full precision — the visible text
  // is formatNum'd with commas, which a number input rejects).
  const items = tokens.map((t) => {
    const bal = Number(userBalances[t] || 0);
    return `<div class="balance-row"><span class="balance-row-token"><img class="market-logo market-logo-sm" src="/assets/${t}.svg" alt="" data-hide-on-error>${t}</span><span class="balance-row-amount balance-amount-fill" role="button" tabindex="0" title="Fill the Withdraw form with this balance" data-token="${t}" data-bal="${bal}">${formatNum(bal)}</span></div>`;
  });
  grid.innerHTML = items.join("");
}

function renderAccountBalances() {
  renderBalancesGrid();
  // Phase 0: fetch + render bid headroom alongside balances. The
  // headroom fetch also caches cachedMarginAccount, which renderBalancesGrid
  // will redraw against on the next pass once it resolves.
  refreshBidHeadroom();
}

// Background fetch of the user's cross-market bid-headroom snapshot.
// Renders into #bid-headroom-card (added in index.html). Tolerant of
// being called before login — bails silently if no appState.actor.
async function refreshBidHeadroom() {
  const card = document.getElementById("bid-headroom-card");
  if (!card) return;
  if (!appState.actor || !appState.isAuthenticated) {
    card.style.display = "none";
    return;
  }
  try {
    const h = await appState.actor.getMyBidHeadroom();
    const cap = Number(h.maxAllowed);
    const used = Number(h.grossBidValue);
    const free = Number(h.headroom);
    const factor = Number(h.factor);
    const availCash = Number(h.cashBalance);
    const totalCash = Number(h.totalBalance || h.cashBalance || 0);
    const hasMargin = Array.isArray(h.marginAccount) && h.marginAccount.length > 0;
    // Cache for the Balances card to read on its next render (cheap — the
    // Balances card runs in parallel with this and can't await us).
    cachedMarginAccount = hasMargin ? h.marginAccount[0] : null;
    // Now that we know the margin breakdown, redraw the balances grid
    // so locked tokens show free / locked / total.
    renderBalancesGrid();
    const pctUsed = cap > 0 ? (used / cap) * 100 : 0;
    const cls = pctUsed >= 100 ? "drift-bad" : pctUsed >= 80 ? "drift-warn" : "drift-ok";
    // Bid cap = available cash × factor for everyone (soft-leverage limit
    // on open-order stacking). Real leverage comes from borrowing, shown
    // in the margin card's health section.
    const factorLabel = `cap ${factor.toFixed(1)}× free cash`;
    card.innerHTML = `
      <div class="bid-headroom-head">
        <span class="bid-headroom-title">Bid headroom</span>
        <span class="bid-headroom-factor">${factorLabel}</span>
      </div>
      <div class="bid-headroom-bar-wrap">
        <div class="bid-headroom-bar ${cls}" style="width: ${Math.min(100, pctUsed).toFixed(1)}%"></div>
      </div>
      <div class="bid-headroom-stats">
        <span>${formatNum(used)} used</span>
        <span class="${cls}">${formatNum(free)} free</span>
        <span>of ${formatNum(cap)}</span>
      </div>
    `;
    card.style.display = "block";

    renderEarnCard();
    renderPositions();
    renderAllOverview();
  } catch (e) {
    console.warn("getMyBidHeadroom failed:", e);
  }
}

// ── Earn: AMM Vault LP + Insurance staking ─────────────────────────
// Two ways to contribute capital and profit: provide liquidity to the AMM
// vault (earn the spread; LP value rises with vault P&L) or stake the
// insurance fund (earn liquidation penalties as the junior backstop, bear
// bad-debt losses). Wired to depositLp/withdrawLp + stakeInsurance/
// unstakeInsurance; idempotent, called on every account refresh.
// ── Chart cell view: chart | liquidations | hidden ────────────────────
// The price chart and the liquidation map share one cell instead of each
// taking a slab of the page. Persisted, because it is a viewing preference
// rather than per-market state.
let _chartView = (() => {
  try { return localStorage.getItem("mdx.chartView") || "chart"; } catch { return "chart"; }
})();
const CHART_VIEWS = [
  { id: "chart",        label: "Chart" },
  { id: "liquidations", label: "Liquidations" },
  // Menu items are ACTIONS ("Hide"); the trigger shows the resulting STATE.
  // A control still reading "Hide" once everything is hidden looks broken —
  // it invites the click that does nothing.
  { id: "hidden",       label: "Hide", state: "Hidden" },
];

// Paint the cell for the current view and rebuild the menu. The CURRENT view is
// omitted from the menu (selecting what you already see is a no-op), and while
// hidden "Hide" is omitted too — leaving exactly Chart | Liquidations, which is
// the behaviour asked for.
function applyChartView(container) {
  const root = container || document.getElementById("mini-chart");
  if (!root) return;
  const label = root.querySelector("#mcv-label");
  const menu  = root.querySelector("#mcv-menu");
  root.classList.toggle("mini-chart-collapsed", _chartView === "hidden");
  root.classList.toggle("mcv-showing-heat",     _chartView === "liquidations");
  const current = CHART_VIEWS.find((v) => v.id === _chartView) || CHART_VIEWS[0];
  if (label) label.textContent = current.state || current.label;
  if (menu) {
    menu.innerHTML = CHART_VIEWS
      .filter((v) => v.id !== _chartView && !(_chartView === "hidden" && v.id === "hidden"))
      .map((v) => `<div class="mcv-item" data-view="${v.id}">${escH(v.label)}</div>`)
      .join("");
  }
  // The chart only lays out correctly when its cell is actually visible.
  if (_chartView === "chart" && miniChartInstance) {
    const c = document.getElementById("mini-chart-canvas");
    if (c && c.clientWidth) {
      try { miniChartInstance.resize(c.clientWidth, c.clientHeight || 260); } catch { /* not ready */ }
    }
  }
  if (_chartView === "liquidations") refreshHeatmap(selectedMarket);
}

function setChartView(view) {
  _chartView = view;
  try { localStorage.setItem("mdx.chartView", view); } catch { /* private mode */ }
  applyChartView();
}

// ── Liquidation heat surface ─────────────────────────────────────────
// The classic liquidation heat map: TIME across, PRICE up, colour = notional
// resting at each level, with the mark trace overlaid so you watch price walk
// into (or bounce off) the bright zones. Columns are the backend's 30s exact
// snapshots (1% bands); the ring holds ~4h of them.
//
// Per-market column cache. lastNs is the incremental-poll cursor (bigint,
// raw ns — computedNs is NOT a MONEY_KEYS field, so it survives normMoney).
const _heatHist = new Map();   // marketId -> { cols: [snapshot…], lastNs }
const HEAT_COLS_CAP = 480;     // mirror of the backend ring
const HEAT_MIN_COLS = 48;      // early columns render at plotW/48 so a young
                               // ring still fills the screen honestly

// Fetch + render for a market. Uses the PUBLIC actor so it works signed-out;
// failures are silent (an older backend simply has no such method).
async function refreshHeatmap(marketId) {
  const src = appState.actor || appState.publicActor;
  if (!src || !marketId) return;
  const cache = _heatHist.get(marketId) || { cols: [], lastNs: 0n };
  try {
    const fresh = await src.getMarginHeatmapHistory(marketId, cache.lastNs);
    for (const hm of fresh) {
      if (Number(hm.computedNs) === 0) continue;
      cache.cols.push(hm);
      cache.lastNs = hm.computedNs;
    }
  } catch {
    // Backend without the history method (subnet until the next deploy):
    // degrade to the latest snapshot as a growing series — each poll appends
    // one column, so the surface still builds, just only while watching.
    try {
      const r = await src.getMarginHeatmap?.(marketId);
      const hm = (Array.isArray(r) ? r[0] : r) ?? null;
      if (hm && Number(hm.computedNs) > 0 && hm.computedNs > cache.lastNs) {
        cache.cols.push(hm);
        cache.lastNs = hm.computedNs;
      }
    } catch { /* leave whatever is on screen */ }
  }
  if (cache.cols.length > HEAT_COLS_CAP) cache.cols.splice(0, cache.cols.length - HEAT_COLS_CAP);
  _heatHist.set(marketId, cache);
  if (marketId === (selectedMarket || marketId)) renderHeatmap(marketId);
}

// The thermal ramp. Cold cells sleep near the page background so empty price
// space stays dark; the hot end runs blue → cyan → green → yellow → red →
// white-hot, the palette every liquidation map trains traders on.
const HEAT_STOPS = [
  [0.00,  15,  23,  42],
  [0.16,  29,  78, 156],
  [0.34,   6, 148, 186],
  [0.52,  34, 197,  94],
  [0.70, 234, 179,   8],
  [0.85, 249, 115,  22],
  [0.94, 239,  68,  68],
  [1.00, 254, 228, 220],
];
function heatColor(t) {
  const x = Math.max(0, Math.min(1, t));
  for (let i = 1; i < HEAT_STOPS.length; i++) {
    if (x <= HEAT_STOPS[i][0]) {
      const [t0, r0, g0, b0] = HEAT_STOPS[i - 1];
      const [t1, r1, g1, b1] = HEAT_STOPS[i];
      const f = (x - t0) / (t1 - t0 || 1);
      return `rgb(${Math.round(r0 + (r1 - r0) * f)},${Math.round(g0 + (g1 - g0) * f)},${Math.round(b0 + (b1 - b0) * f)})`;
    }
  }
  return "rgb(254,228,220)";
}

// Paint the surface into the Markets chart cell (its only home — the map is
// PUBLIC and exact: everything in it is derivable from the public tape, so
// hiding or blurring it would only restore the asymmetry publishing it
// removes). Visibility belongs to the chart-view dropdown (CSS).
function renderHeatmap(marketId) {
  const cache = _heatHist.get(marketId);
  const cols = cache ? cache.cols : [];
  const mount = document.getElementById("mini-chart-heat");
  if (!mount) return;
  if (!cols.length) {
    mount.innerHTML = `<div class="heatmap-sub">No liquidation data yet.</div>`;
    return;
  }
  ensureHeatScaffold(mount);
  drawHeatSurface(mount, cols);
}

function ensureHeatScaffold(mount) {
  if (mount.dataset.hm2) return;
  mount.dataset.hm2 = "1";
  mount.innerHTML =
    `<div class="heatmap-head">Liquidation heat map`
    + `<span class="heatmap-sub" id="hm2-totals">where the leveraged book liquidates · exact, from the public ledger</span></div>`
    + `<div class="hm2-wrap"><canvas class="hm2-canvas"></canvas><div class="hm2-tip" hidden></div></div>`
    // The scale now carries its ceiling in DOLLARS. Brightness is meaningless
    // without it: the same colour must not mean $5k on a quiet day and $50M on
    // a busy one, and a viewer's first question is "how much is at risk here?".
    + `<div class="hm2-foot"><span class="hm2-scale"><span class="hm2-scale-bar"></span>`
    + `<span class="hm2-scale-lab">up to <b id="hm2-scale-max">—</b> per 1%</span></span>`
    + `<span class="hm2-note">above the mark line shorts liquidate · below it longs</span></div>`;
  const canvas = mount.querySelector(".hm2-canvas");
  const tip = mount.querySelector(".hm2-tip");
  canvas.addEventListener("mousemove", (e) => heatTooltip(mount, canvas, tip, e));
  canvas.addEventListener("mouseleave", () => { tip.hidden = true; });
  // Touch has no mouseleave — a tap summons the tooltip via the synthesised
  // mousemove, so a touch anywhere OUTSIDE the canvas is the dismissal.
  document.addEventListener("touchstart", (e) => {
    if (!tip.hidden && !canvas.contains(e.target)) tip.hidden = true;
  }, { passive: true });
}

function drawHeatSurface(mount, cols) {
  const wrap = mount.querySelector(".hm2-wrap");
  const canvas = mount.querySelector(".hm2-canvas");
  const W = wrap.clientWidth, H = wrap.clientHeight;
  if (!W || !H) return;
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
  const ctx = canvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, W, H);

  const css = getComputedStyle(document.documentElement);
  const cMuted = (css.getPropertyValue("--text-muted") || "#64748b").trim();
  const AXIS_R = 56, AXIS_B = 16;
  const plotW = W - AXIS_R, plotH = H - AXIS_B;

  // Price domain: the occupied band extents across every column (so the view
  // tightens to where liquidity actually sits), never narrower than ±5%
  // around the mark, padded 4%.
  let pMin = Infinity, pMax = 0;
  for (const c of cols) {
    const m = Number(c.markPrice);
    if (!m) continue;
    pMin = Math.min(pMin, m * 0.95); pMax = Math.max(pMax, m * 1.05);
    for (const b of (c.buckets || [])) {
      pMin = Math.min(pMin, m * (1 + Number(b.bandLowBps) / 10000));
      pMax = Math.max(pMax, m * (1 + Number(b.bandHighBps) / 10000));
    }
  }
  if (!isFinite(pMin) || pMax <= pMin) return;
  const pad = (pMax - pMin) * 0.04;
  pMin -= pad; pMax += pad;
  const yOf = (p) => plotH - ((p - pMin) / (pMax - pMin)) * plotH;

  // Colour scale: $ per 1% of price (density), so a wide k-merged band does
  // not paint hotter than a tight one just for being wide. Log-lifted —
  // notionals are heavy-tailed and a linear ramp would leave one white cell
  // in a dark sea.
  const densityOf = (b) => {
    const widthPct = (Number(b.bandHighBps) - Number(b.bandLowBps)) / 100 || 1;
    return (Number(b.longNotionalUsd) + Number(b.shortNotionalUsd)) / widthPct;
  };
  // LEGACY columns only: before 2026-08-01 the backend k-anonymized the map,
  // and a sub-k side published one bucket spanning the WHOLE side (width =
  // HEAT_RANGE_BPS = 3000) — real magnitude, placement deliberately
  // unresolved, rendered as a diffuse wash. New columns are exact 1% bands
  // and never trip this, but the stable history ring still carries ~4h of
  // old-shape columns after the upgrade, so the wash rendering stays.
  const isAggregate = (b) => (Number(b.bandHighBps) - Number(b.bandLowBps)) >= 3000;
  let dMax = 0;
  for (const c of cols) for (const b of (c.buckets || [])) dMax = Math.max(dMax, densityOf(b));

  // The ramp is anchored to an ABSOLUTE $/1% ladder, not to dMax. Normalising
  // to the busiest visible cell made the scale meaningless across time and
  // across venues: $5k of exposure painted exactly as hot as $50M, so the map
  // could never answer "how much can actually be liquidated here?". Anchoring
  // to a ladder means brightness has a fixed meaning — and because the anchor
  // STEPS UP as the book grows (never below the floor), a young venue reads
  // honestly dim while a deep one saturates, and the legend states the ceiling
  // in dollars so the shift is legible rather than silent.
  const HEAT_STEPS = [250e3, 1e6, 5e6, 25e6, 100e6, 500e6, 2e9];
  const heatAnchor = HEAT_STEPS.find((s) => s >= dMax) || HEAT_STEPS[HEAT_STEPS.length - 1];
  // Aggregate (sub-k) cells are floored to a visible tint: their density is
  // low by construction — the exposure is smeared over a whole 30% side — but
  // "we don't know where yet" must still read as present, not as absent.
  const AGG_MIN_T = 0.20;
  const tOf = (d, isAgg) => {
    const t = heatAnchor > 0 ? Math.log1p((d / heatAnchor) * 60) / Math.log1p(60) : 0;
    return isAgg ? Math.max(t, AGG_MIN_T) : t;
  };

  // Publish the scale ceiling and the live totals, so magnitude is readable
  // as a number and not only as a shade. Both come from the newest column.
  const latest = cols[cols.length - 1] || {};
  const usdShort = (v) => v >= 1e9 ? `$${(v / 1e9).toFixed(1)}B`
    : v >= 1e6 ? `$${(v / 1e6).toFixed(v >= 1e7 ? 0 : 1)}M`
    : v >= 1e3 ? `$${Math.round(v / 1e3)}k` : `$${Math.round(v)}`;
  const elMax = document.getElementById("hm2-scale-max");
  if (elMax) elMax.textContent = usdShort(heatAnchor);
  const elTot = document.getElementById("hm2-totals");
  if (elTot) {
    // Already human units: wrapActor normalises money fields on the way in
    // (the bucket tooltip formats longNotionalUsd directly, same contract).
    const L = Number(latest.totalLongNotionalUsd || 0);
    const S = Number(latest.totalShortNotionalUsd || 0);
    const n = Number(latest.positionsTotal || 0);
    elTot.textContent = n > 0
      ? `${usdShort(L + S)} of leveraged notional can liquidate · ${usdShort(L)} long / ${usdShort(S)} short · ${n} position${n === 1 ? "" : "s"}`
      : "where the leveraged book liquidates · no open leveraged positions yet";
  }

  // Columns, newest at the right edge. A young ring gets wide columns
  // (plotW/HEAT_MIN_COLS) so the first minutes still fill the screen.
  const colW = plotW / Math.max(cols.length, HEAT_MIN_COLS);
  const xOf = (i) => plotW - (cols.length - i) * colW;

  // Faint horizontal gridlines + right-axis price labels.
  ctx.font = "10px 'Inter Variable', system-ui, sans-serif";
  ctx.textBaseline = "middle";
  const ticks = 5;
  for (let k = 0; k <= ticks; k++) {
    const p = pMin + ((pMax - pMin) * k) / ticks;
    const y = yOf(p);
    ctx.fillStyle = "rgba(148,163,184,0.07)";
    ctx.fillRect(0, y, plotW, 1);
    ctx.fillStyle = cMuted;
    ctx.textAlign = "left";
    ctx.fillText("$" + formatNum(p), plotW + 6, Math.min(Math.max(y, 7), plotH - 7));
  }

  // The field itself.
  for (let i = 0; i < cols.length; i++) {
    const c = cols[i];
    const m = Number(c.markPrice);
    if (!m) continue;
    const x = xOf(i);
    for (const b of (c.buckets || [])) {
      const yTop = yOf(m * (1 + Number(b.bandHighBps) / 10000));
      const yBot = yOf(m * (1 + Number(b.bandLowBps) / 10000));
      const h = Math.max(yBot - yTop, 1);
      const isAgg = isAggregate(b);
      ctx.fillStyle = heatColor(tOf(densityOf(b), isAgg));
      if (isAgg) {
        // Sub-k side: real magnitude, unresolved placement. Fade it out
        // towards the mark so it reads as "somewhere out there" rather than
        // as a sharp fault line at a price nobody has actually committed to.
        // (Sharp bands are earned once k positions cluster.)
        const towardMark = Number(b.bandHighBps) <= 0 ? yTop : yBot;  // mark-side edge
        const g = ctx.createLinearGradient(0, towardMark, 0, towardMark === yTop ? yBot : yTop);
        g.addColorStop(0, heatColor(tOf(densityOf(b), true)));
        g.addColorStop(1, "rgba(0,0,0,0)");
        ctx.fillStyle = g;
      }
      // +0.6 overdraw kills the hairline seams between columns.
      ctx.fillRect(x, yTop, colW + 0.6, h);
    }
  }

  // Mark trace — the price walking through the field.
  ctx.beginPath();
  let started = false;
  for (let i = 0; i < cols.length; i++) {
    const m = Number(cols[i].markPrice);
    if (!m) continue;
    const x = xOf(i) + colW / 2, y = yOf(m);
    if (started) ctx.lineTo(x, y); else { ctx.moveTo(x, y); started = true; }
  }
  ctx.strokeStyle = "rgba(255,255,255,0.88)";
  ctx.lineWidth = 1.5;
  ctx.shadowColor = "rgba(255,255,255,0.35)";
  ctx.shadowBlur = 4;
  ctx.stroke();
  ctx.shadowBlur = 0;
  // Label the live mark on the axis, in the axis gutter.
  const lastMark = Number(cols[cols.length - 1].markPrice);
  if (lastMark) {
    const y = Math.min(Math.max(yOf(lastMark), 7), plotH - 7);
    ctx.fillStyle = "rgba(255,255,255,0.92)";
    ctx.textAlign = "left";
    ctx.fillText("$" + formatNum(lastMark), plotW + 6, y);
  }

  // Time labels along the bottom, one per ~110px.
  ctx.fillStyle = cMuted;
  ctx.textAlign = "center";
  const every = Math.max(1, Math.ceil(110 / colW));
  for (let i = cols.length - 1; i >= 0; i -= every) {
    const ms = Number(cols[i].computedNs) / 1e6;
    const d = new Date(ms);
    const label = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
    const x = xOf(i) + colW / 2;
    if (x > 18 && x < plotW - 18) ctx.fillText(label, x, plotH + 9);
  }

  // A young ring says so instead of looking broken.
  if (cols.length < 5) {
    ctx.fillStyle = cMuted;
    ctx.textAlign = "left";
    ctx.fillText("building — a column is added every 30s", 8, 12);
  }
  const lastTier = String(cols[cols.length - 1].tier);
  if (lastTier === "none") {
    ctx.fillStyle = cMuted;
    ctx.textAlign = "left";
    ctx.fillText("band detail withheld — too few independent price sources", 8, plotH - 10);
  }

  // Geometry for the tooltip hit-test.
  mount._hm2 = { cols, colW, plotW, plotH, pMin, pMax };
}

function heatTooltip(mount, canvas, tip, e) {
  const g = mount._hm2;
  if (!g) return;
  const rect = canvas.getBoundingClientRect();
  const x = e.clientX - rect.left, y = e.clientY - rect.top;
  if (x > g.plotW || y > g.plotH) { tip.hidden = true; return; }
  const i = g.cols.length - 1 - Math.floor((g.plotW - x) / g.colW);
  const c = g.cols[i];
  if (!c) { tip.hidden = true; return; }
  const price = g.pMin + (1 - y / g.plotH) * (g.pMax - g.pMin);
  const m = Number(c.markPrice);
  const bps = m ? ((price - m) / m) * 10000 : 0;
  const hit = (c.buckets || []).find((b) => bps >= Number(b.bandLowBps) && bps < Number(b.bandHighBps));
  const d = new Date(Number(c.computedNs) / 1e6);
  const when = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  let body;
  if (hit) {
    const ln = Number(hit.longNotionalUsd), sn = Number(hit.shortNotionalUsd);
    const lo = m * (1 + Number(hit.bandLowBps) / 10000), hi = m * (1 + Number(hit.bandHighBps) / 10000);
    const side = sn > ln ? "shorts" : "longs";
    const dist = ((Number(hit.bandLowBps) + Number(hit.bandHighBps)) / 2 / 100).toFixed(1);
    const nPos = Number(hit.positions);
    // Same derivation as drawHeatSurface's isAggregate: a full-side band
    // (>= HEAT_RANGE_BPS wide) is magnitude-known, placement-unresolved.
    const isHitAggregate = (Number(hit.bandHighBps) - Number(hit.bandLowBps)) >= 3000;
    if (isHitAggregate) {
      // Say plainly that the AMOUNT is known and the PRICE is not — otherwise
      // a 30%-wide wash reads as a precise claim about where the book breaks.
      body = `<b>$${escH(formatNum(ln + sn))}</b> can liquidate ${lo < m ? "below" : "above"} the mark`
        + `<br>${escH(String(nPos))} position${nPos === 1 ? "" : "s"} · exact prices pooled until more traders join`
        + `<br><span>${escH(when)} · mark $${escH(formatNum(m))}</span>`;
    } else {
      body = `<b>$${escH(formatNum(lo))} – $${escH(formatNum(hi))}</b> · ${escH(dist)}% from mark`
        + `<br>$${escH(formatNum(ln + sn))} liquidates (mostly ${side}) · ${escH(String(nPos))} positions`
        + `<br><span>${escH(when)} · mark $${escH(formatNum(m))}</span>`;
    }
  } else {
    body = `<b>$${escH(formatNum(price))}</b> · no liquidation liquidity`
      + `<br><span>${escH(when)} · mark $${escH(formatNum(m))}</span>`;
  }
  tip.innerHTML = body;
  tip.hidden = false;
  const tw = tip.offsetWidth, th = tip.offsetHeight;
  tip.style.left = Math.min(x + 12, g.plotW - tw - 4) + "px";
  tip.style.top = Math.max(y - th - 10, 4) + "px";
}

// The surface must re-fit its cell when the window (or the chart column)
// resizes — canvases don't reflow on their own.
let _heatResizeT = null;
window.addEventListener("resize", () => {
  clearTimeout(_heatResizeT);
  _heatResizeT = setTimeout(() => { if (selectedMarket) renderHeatmap(selectedMarket); }, 150);
});

// What the AMM vault underwrites, shown on the Earn card where an LP actually
// decides whether to deposit. The vault is the margin system's lender AND the
// senior absorber of uncovered bad debt, and liquidation penalties come out of
// its cash leg — so an LP is exposed to every leveraged position on the venue.
// The figures identify nobody (see docs/margin-heatmap-design.md).
function renderMarginRisk(risk) {
  const el = document.getElementById("earn-margin-risk");
  if (!el) return;
  if (!risk || Number(risk.computedNs) === 0) { el.style.display = "none"; return; }
  // Pre-normalised by money.js (MONEY_KEYS) — do NOT divide.
  const usd  = (x) => "$" + formatNum(Number(x));
  const util = Number(risk.vaultUtilisationBps) / 100;          // bps → %
  const liqN = Number(risk.liquidatablePositions);
  // Utilisation is against the borrow CAP (half the vault), not the vault.
  const utilClass = util >= 80 ? "mr-hot" : util >= 50 ? "mr-warm" : "";
  el.style.display = "";
  el.innerHTML =
    `<div class="margin-risk-head">What this vault underwrites`
    + `<span class="margin-risk-sub">the vault lends to every margin pool and absorbs uncovered bad debt</span></div>`
    + `<div class="earn-stats">`
    + `<div class="margin-stat"><div class="margin-stat-label">Open positions</div>`
    + `<div class="margin-stat-value">${escH(String(Number(risk.positions)))}</div></div>`
    + `<div class="margin-stat"><div class="margin-stat-label">Notional</div>`
    + `<div class="margin-stat-value">${escH(usd(risk.totalNotionalUsd))}</div></div>`
    + `<div class="margin-stat"><div class="margin-stat-label">Lent out</div>`
    + `<div class="margin-stat-value">${escH(usd(risk.totalDebtUsd))}</div></div>`
    + `<div class="margin-stat"><div class="margin-stat-label">Of borrow cap</div>`
    + `<div class="margin-stat-value ${utilClass}">${escH(util.toFixed(1))}%</div></div>`
    + `<div class="margin-stat"><div class="margin-stat-label">Insurance first-loss</div>`
    + `<div class="margin-stat-value">${escH(usd(risk.insuranceValueUsd))}</div></div>`
    + `<div class="margin-stat"><div class="margin-stat-label">Below maintenance</div>`
    + `<div class="margin-stat-value ${liqN > 0 ? "mr-hot" : ""}">${escH(String(liqN))}`
    + `${liqN > 0 ? " · " + escH(usd(risk.worstCaseAbsorbUsd)) : ""}</div></div>`
    + `</div>`
    + (risk.truncated ? `<div class="margin-risk-note">Partial scan — more pools than the per-pass cap.</div>` : "");
}

// The loan-book haircut disclosure (#50.1). The "Value" tile is the LP's
// slice of vault NAV, and NAV counts the loan book (what the vault has lent
// to margin pools) as an asset — but withdrawLp pays IN KIND from what the
// vault physically HOLDS, leaving the receivable behind for whoever stays
// (see the PAID FROM HOLDINGS comment in main.mo). While utilisation is
// non-zero the NAV figure is therefore an UPPER BOUND on what a withdrawal
// returns today — reaching ~2× at the 0.50 borrow cap — so the
// physically-backed figure is shown beside it rather than left for the
// withdrawal receipt to reveal.
function renderVaultHaircut(lpValue, risk) {
  const el = document.getElementById("earn-vault-haircut");
  if (!el) return;
  // risk fields are pre-normalised by money.js (MONEY_KEYS) — do NOT divide;
  // vaultUtilisationBps is not a money field and stays in bps.
  const nav  = risk ? Number(risk.vaultValueUsd) : 0;
  const debt = risk ? Number(risk.totalDebtUsd)  : 0;
  if (!(lpValue > 0) || !(nav > 0) || !(debt > 0)) { el.style.display = "none"; return; }
  const backedFrac = Math.max(0, 1 - debt / nav);          // physical holdings / NAV
  const utilPct = Number(risk.vaultUtilisationBps) / 100;  // % of the borrow cap
  el.style.display = "";
  el.textContent =
    `Value marks your slice of vault NAV, which counts $${formatNum(debt)} lent to margin pools as an asset. `
    + `Withdrawals pay in kind from what the vault physically holds — redeemable today ≈ $${formatNum(lpValue * backedFrac)} `
    + `(loan book at ${utilPct.toFixed(1)}% of the borrow cap), before the 0.4% exit fee.`;
}

async function renderEarnCard() {
  // Split cards: AMM Vault + Insurance Fund (one renderer feeds both).
  const card = document.getElementById("earn-vault-card");
  const insCard = document.getElementById("earn-insurance-card");
  if (!card || !appState.actor) return;
  card.style.display = "block";
  if (insCard) insCard.style.display = "block";
  if (!card.dataset.wired) {
    card.dataset.wired = "1";
    document.getElementById("earn-vault-deposit-btn")?.addEventListener("click", onVaultDeposit);
    document.getElementById("earn-vault-withdraw-btn")?.addEventListener("click", onVaultWithdraw);
    document.getElementById("earn-ins-stake-btn")?.addEventListener("click", onInsuranceStake);
    document.getElementById("earn-ins-unstake-btn")?.addEventListener("click", onInsuranceUnstake);
  }
  try {
    const [pos, vault, stake, fund, weights, risk] = await Promise.all([
      appState.actor.getMyVaultPosition(),
      appState.actor.getVaultValue(),
      appState.actor.getMyInsuranceStake(),
      appState.actor.getInsuranceFund(),
      appState.actor.getVaultWeights(),
      // Never fail the whole card if this one query is unavailable (e.g. an
      // older backend that predates it).
      appState.actor.getMarginRiskSummary?.().catch(() => null) ?? null,
    ]);
    renderMarginRisk(risk);
    // AMM vault
    const lp        = Number(pos.lpBalance);
    const lpValue   = Number(pos.estimatedValue);
    // sharePercent crosses the money boundary as a 0..1 FRACTION of the pool
    // (money.js divides the e8 fixed-point by 1e8, nothing more), so the
    // render owns the ×100 — exactly like the weight table below. Without it
    // a 5% holder reads "0.05%" (#50.2).
    const shareFrac = Number(pos.sharePercent);
    const valuePerLP = Number(vault.valuePerLP);
    setText("earn-vault-lp", formatNum(lp));
    setText("earn-vault-value", "$" + formatNum(lpValue));
    setText("earn-vault-share", (shareFrac * 100).toFixed(2) + "%");
    setText("earn-vault-vplp", valuePerLP.toFixed(4));
    renderVaultHaircut(lpValue, risk);
    // Target-weight table: current vs target weight + live deposit bonus/fee.
    const wEl = document.getElementById("earn-vault-weights");
    if (wEl && Array.isArray(weights)) {
      const rows = weights.map((w) => {
        const cur = (Number(w.currentWeight) * 100).toFixed(1);
        const tgt = (Number(w.targetWeight) * 100).toFixed(0);
        const mult = Number(w.depositMultiplier);
        const pct = ((mult - 1) * 100);
        const tag = pct >= 0.05 ? `+${pct.toFixed(1)}% bonus` : (pct <= -0.05 ? `${pct.toFixed(1)}% fee` : "neutral");
        const cls = pct >= 0.05 ? "health-ok" : (pct <= -0.05 ? "health-bad" : "");
        return `<tr><td class="margin-bd-token"><img class="market-logo market-logo-sm" src="/assets/${w.token}.svg" alt="" data-hide-on-error>${w.token}</td><td class="margin-bd-amt">${cur}%</td>
          <td class="margin-bd-px">${tgt}%</td><td class="margin-bd-contrib ${cls}">${tag}</td></tr>`;
      }).join("");
      wEl.innerHTML = `<table class="margin-bd-table"><thead><tr>
        <th>Asset</th><th>Current</th><th>Target</th><th>Deposit now</th></tr></thead>
        <tbody>${rows}</tbody></table>`;
    }
    // Insurance staking
    const shares    = Number(stake.shares);
    const stakeVal  = Number(stake.valueUsd);
    const shareVal  = Number(fund.shareValueUsd);
    const poolUsd   = Number(fund.bufferUsd);
    setText("earn-ins-shares", formatNum(shares));
    setText("earn-ins-value", "$" + formatNum(stakeVal));
    setText("earn-ins-sharevalue", shareVal.toFixed(4));
    setText("earn-ins-pool", "$" + formatNum(poolUsd));
    // Yield in flight — see the tile's comment in index.html.
    const insPending = Number(fund.pendingYieldUsd || 0);
    const pendTile = document.getElementById("earn-ins-pending-tile");
    if (pendTile) pendTile.style.display = insPending > 0.0000001 ? "" : "none";
    setText("earn-ins-pending", "$" + formatNum(insPending));
    // Header figures on the split cards — the two components of Earn, both
    // inside Account value (wallet + pools + earn).
    setText("earn-vault-cardvalue", lpValue > 0.0000001 ? fmtUsd(lpValue) : "—");
    setText("earn-ins-cardvalue",   stakeVal > 0.0000001 ? fmtUsd(stakeVal) : "—");
  } catch (e) {
    console.warn("renderEarnCard failed:", e);
  }
}

function setText(id, txt) { const el = document.getElementById(id); if (el) el.textContent = txt; }

async function onVaultDeposit() {
  const input = document.getElementById("earn-vault-deposit-input");
  const token = document.getElementById("earn-vault-deposit-token")?.value || "ICPUSD";
  const amount = parseFloat(input?.value);
  if (!appState.actor || !(amount > 0)) { showEarnHint(`Enter a ${token} amount to deposit.`); return; }
  try {
    // Unified vault. ICPUSD is the quote leg (any market); a base asset is
    // the base leg of its own X-ICPUSD market.
    const r = (token === "ICPUSD")
      ? await appState.actor.depositLp("BTC-ICPUSD", toE8(0), toE8(amount))
      : await appState.actor.depositLp(`${token}-ICPUSD`, toE8(amount), toE8(0));
    if ("ok" in r) { showEarnMsg(`Deposited ${formatNum(amount)} ${token} — minted ${formatNum(Number(r.ok))} LP.`, "ok"); input.value = ""; }
    else { showEarnMsg(r.err, "err"); }
  } catch (e) { showEarnMsg("Deposit failed: " + e, "err"); }
  await refreshAccountEarn();
}

async function onVaultWithdraw() {
  const input = document.getElementById("earn-vault-withdraw-input");
  const lp = parseFloat(input?.value);
  if (!appState.actor || !(lp > 0)) { showEarnHint("Enter an LP amount to withdraw."); return; }
  try {
    const r = await appState.actor.withdrawLp(toE8(lp));
    if ("ok" in r) { showEarnMsg(`Redeemed ${formatNum(lp)} LP for your basket share.`, "ok"); input.value = ""; }
    else { showEarnMsg(r.err, "err"); }
  } catch (e) { showEarnMsg("Withdraw failed: " + e, "err"); }
  await refreshAccountEarn();
}

async function onInsuranceStake() {
  const input = document.getElementById("earn-ins-stake-input");
  const amount = parseFloat(input?.value);
  if (!appState.actor || !(amount > 0)) { showEarnHint("Enter an ICPUSD amount to stake."); return; }
  try {
    const r = await appState.actor.stakeInsurance(toE8(amount));
    if ("ok" in r) { showEarnMsg(`Staked $${formatNum(amount)} — minted ${formatNum(Number(r.ok))} insurance shares.`, "ok"); input.value = ""; }
    else { showEarnMsg(r.err, "err"); }
  } catch (e) { showEarnMsg("Stake failed: " + e, "err"); }
  await refreshAccountEarn();
}

async function onInsuranceUnstake() {
  const input = document.getElementById("earn-ins-unstake-input");
  const shares = parseFloat(input?.value);
  if (!appState.actor || !(shares > 0)) { showEarnHint("Enter a share amount to unstake."); return; }
  try {
    const r = await appState.actor.unstakeInsurance(toE8(shares));
    if ("ok" in r) { showEarnMsg(`Unstaked ${formatNum(shares)} shares — redeemed $${formatNum(Number(r.ok))}.`, "ok"); input.value = ""; }
    else { showEarnMsg(r.err, "err"); }
  } catch (e) { showEarnMsg("Unstake failed: " + e, "err"); }
  await refreshAccountEarn();
}

// Earn action feedback. The OUTCOME of a vault/insurance action is a toast —
// it belongs with every other action result in the app, and the inline slot
// (#earn-msg) sits at the very bottom of the pane, below the Insurance box,
// so a result reported there reads as a message about Insurance no matter
// which of the four buttons produced it, and is easily missed off-screen.
// VALIDATION prompts ("Enter an amount") stay inline: they belong beside the
// input they're about, and shouldn't fire a toast for a mistyped field.
function showEarnMsg(text, kind) {
  showToast(text, kind === "err" ? "error" : "success");
  const el = document.getElementById("earn-msg");
  if (!el) return;
  el.style.display = "none";   // never leave a stale inline result behind
}
function showEarnHint(text) {
  const el = document.getElementById("earn-msg");
  if (!el) return;
  el.textContent = text;
  el.className = "margin-msg margin-msg-err";
  el.style.display = "block";
}

// After an Earn action: re-FETCH, don't just repaint. renderBalances() reads
// the userBalances / cachedAcctSummary caches, so calling it alone left the
// header pill, Overview and Wallet showing pre-action figures until the next
// poll happened to land — the funds had moved but the app said otherwise.
// refreshBalances() re-queries getBalances + getMyAccountSummary and fans out
// to every dependent surface; the Overview pane is re-rendered explicitly
// because it has its own fetch (renderAllOverview).
async function refreshAccountEarn() {
  await renderEarnCard();
  await refreshBalances();
  renderAllOverview();
}

// ── All tab: account value + venue breakdown ───────────────────────
// The accounting view: total account value decomposed into the venues capital
// can sit in. Rows sum to the total (same marks the backend nets):
//   Wallet    = spot holdings (net of any legacy whole-wallet debt)
//   Positions = Σ unrealized P&L on open positions, at mark
//   Pools     = Σ pool equity − that uPnL → the collateral basis in pools
//   AMM Vault / Insurance = the two Earn stakes
// The total shown is the backend's netAccountValueUsd (authoritative); the
// rows are fetched in the same breath so they agree within rounding.
async function renderAllOverview() {
  const card = document.getElementById("all-value-card");
  if (!card || !appState.actor || !appState.isAuthenticated) return;
  try {
    const [summary, positions, pools, vaultPos, insStake] = await Promise.all([
      appState.actor.getMyAccountSummary(),
      appState.actor.getMyPositions(),
      appState.actor.getMyMarginPools(),
      appState.actor.getMyVaultPosition(),
      appState.actor.getMyInsuranceStake(),
    ]);
    cachedAcctSummary = summary;   // header pill reads the same snapshot
    const hasPos = (positions || []).length > 0;
    const uPnl = (positions || []).reduce((s, p) => s + Number(p.unrealizedPnl), 0);
    const poolsEquity = (pools || []).reduce((s, p) => s + (Number(p.valueUsd) || 0), 0);
    setText("acct-net-value", fmtUsd(Number(summary.netAccountValueUsd)));
    setText("all-val-wallet", fmtUsd(Number(summary.freeWalletValueUsd) - Number(summary.wholeWalletDebtUsd)));
    const posEl = document.getElementById("all-val-positions");
    if (posEl) {
      posEl.textContent = hasPos ? (uPnl >= 0 ? "+" : "") + fmtUsd(uPnl) : fmtUsd(0);
      posEl.classList.toggle("pos-up", hasPos && uPnl >= 0);
      posEl.classList.toggle("pos-down", hasPos && uPnl < 0);
    }
    setText("all-val-pools", fmtUsd(poolsEquity - uPnl));
    setText("all-val-vault", fmtUsd(Number(vaultPos.estimatedValue) || 0));
    setText("all-val-insurance", fmtUsd(Number(insStake.valueUsd) || 0));
  } catch (e) {
    console.warn("renderAllOverview failed:", e);
  }
}

// (Venue-row navigation is plain anchors in the markup — #account/<tab>.)

// Margin Phase 1 (basket): render the account card based on the headroom
// response. Per-token collateral table is built from collateralBreakdown.
// Wires the open / close / post / withdraw buttons. Idempotent — called on
// every account-page refresh.
// Margin Pools: pool-grouped view — one block per pool (value, margin, debt,
// uPnL, its own % to liquidation) with the positions it backs nested beneath.
// Net account value renders into the Wallet card header (account-wide figure);
// the card's pill summarises the worst pool. Reads getMyAccountSummary +
// getMyPositions + getMyMarginPools (live backend).
async function renderPositions() {
  const card = document.getElementById("positions-card");
  if (!card || !appState.actor || !appState.isAuthenticated) return;
  wirePositionActions();
  try {
    const [summary, positions, pools, transfers] = await Promise.all([
      appState.actor.getMyAccountSummary(),
      appState.actor.getMyPositions(),
      appState.actor.getMyMarginPools(),
      appState.actor.getMyPoolTransfers().catch(() => []),
      // Venue-wide heat surface for the selected market — fire-and-forget; it
      // renders into its own mount and an older backend can't break the card.
      refreshHeatmap(selectedMarket || "BTC-ICPUSD"),
    ]);
    // Net capital the user has put into each pool (funds − withdrawals) —
    // drives the "Net funded" chip; VALUE − net funded = lifetime pool P&L.
    _poolNetFunded = new Map();
    for (const t of transfers || []) {
      const id = Number(t.poolId);
      const amt = Number(t.amount) * ("fund" in t.kind ? 1 : -1);
      _poolNetFunded.set(id, (_poolNetFunded.get(id) || 0) + amt);
    }
    const net   = Number(summary.netAccountValueUsd);
    const worst = Number(summary.worstMarginUsage);
    const pct   = Number(summary.pctToLiquidation) * 100;
    const netEl = document.getElementById("acct-net-value");
    if (netEl) netEl.textContent = fmtUsd(net);
    const pill  = document.getElementById("acct-liq-pill");
    if (worst <= 0.0000001) {
      pill.textContent  = "No leverage";
      pill.className    = "margin-status-pill margin-status-off";
    } else {
      const danger = pct < 10, warn = pct < 25;
      pill.textContent  = danger ? "At risk" : warn ? "Watch" : "Healthy";
      pill.className    = "margin-status-pill " + (danger ? "margin-status-danger" : warn ? "margin-status-warn" : "margin-status-on");
    }
    _poolsCache = pools || [];
    // Pools value = Σ pool mark-to-market worth — the same valueUsd shown on
    // each pool block, so the card header visibly sums the rows (and Account
    // value = Wallet value + Pools value).
    const poolsValEl = document.getElementById("pools-value");
    if (poolsValEl) {
      const poolsVal = _poolsCache.reduce((s, p) => s + (Number(p.valueUsd) || 0), 0);
      poolsValEl.textContent = _poolsCache.length ? fmtUsd(poolsVal) : "—";
    }
    renderPoolsRows(positions);
    renderPoolOrders();
    refreshOrderPoolSelect();   // keep the Place Order box's margin pool dropdown in sync
  } catch (e) {
    console.warn("renderPositions failed:", e);
  }
}

// ── Margin Pools: management (create / fund / withdraw) ──
// Positions are OPENED from the Markets page Place Order box (Margin mode);
// this card only manages the pools backing them.
let _poolsCache = [];
let _poolNetFunded = new Map();   // poolId → Σ funds − Σ withdrawals (net capital put in)

// One block per pool: a header strip (value, free margin, debt, uPnL, its own
// distance to liquidation — liquidation is per-pool) with fund/withdraw
// controls, and the positions that pool backs nested beneath (no Pool column —
// the grouping makes it obvious).
function renderPoolsRows(positions) {
  const wrap = document.getElementById("pools-rows");
  if (!wrap) return;
  if (!_poolsCache.length) {
    wrap.innerHTML = `<div class="empty-state">No pools yet — create one below, or just place a Margin order on the Markets page (a default cross pool is created for you).</div>`;
    return;
  }
  const esc = (s) => String(s).replace(/[<>&"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" }[c]));
  const byPool = new Map();
  (positions || []).forEach((p) => {
    const k = Number(p.poolId);
    if (!byPool.has(k)) byPool.set(k, []);
    byPool.get(k).push(p);
  });
  const chip = (label, value, cls) => `<span class="pbs"><span class="pbs-label">${label}</span><span class="pbs-value ${cls || ""}">${value}</span></span>`;
  wrap.innerHTML = _poolsCache.map((p) => {
    const id = Number(p.id);
    const list = byPool.get(id) || [];
    const debt = p.health ? Number(p.health.debtUsd) || 0 : 0;
    const free = Number(p.freeQuote) || 0;
    const equity = Number(p.valueUsd) || 0;
    const usage = Number(p.marginUsage) || 0;
    // Same definition the old header used, per pool: % to liq = 1 − usage.
    const pct = usage > 0.0000001 ? ((1 - usage) * 100) : null;
    const pctCls = pct == null ? "" : pct < 10 ? "pos-down" : pct < 25 ? "pos-warn" : "pos-up";
    const uPnl = list.reduce((s, x) => s + Number(x.unrealizedPnl), 0);
    const pnlTxt = list.length ? `${uPnl >= 0 ? "+" : ""}${fmtUsd(uPnl)}` : "—";
    // Perp-language header: what you put in, what it's worth, what you're
    // exposed to, and how levered that is. The financing plumbing (borrows,
    // free cash) moves to the expandable footer — real, but not the story.
    const exposure = list.reduce((s, x) => s + Math.abs(Number(x.notionalUsd) || 0), 0);
    const lev = list.length && equity > 0.0000001 ? exposure / equity : null;
    return `<div class="pool-block" data-pool="${id}">
      <div class="pool-block-head">
        <span class="pool-block-name">${esc(p.name)} <span class="pos-roe">· ${p.isolated ? "isolated" : "cross"}</span></span>
        ${chip("Equity", fmtUsd(equity))}
        ${chip("Net funded", _poolNetFunded.has(id) ? fmtUsd(_poolNetFunded.get(id)) : "—")}
        ${chip("Exposure", list.length ? fmtUsd(exposure) : "—")}
        ${chip("Leverage", lev != null ? lev.toFixed(1) + "×" : "—")}
        ${chip("uPnL", pnlTxt, list.length ? (uPnl >= 0 ? "pos-up" : "pos-down") : "")}
        ${chip("% to liq", pct != null ? pct.toFixed(1) + "%" : "—", pctCls)}
      </div>
      ${list.length
        ? positionsTableHTML(list, { includePool: false })
        : `<div class="pool-block-empty">No open positions in this pool</div>`}
      <div class="pool-block-foot">
        <button class="pool-fin-toggle" type="button" data-pool="${id}">Financing ▸</button>
        <span class="pool-block-ctl">
          <input class="pos-input pool-amt" type="number" min="0" step="any" placeholder="ICPUSD" />
          <button class="btn btn-secondary btn-sm pool-fund-btn" data-pool="${id}" type="button">Fund</button>
          <button class="btn btn-secondary btn-sm pool-withdraw-btn" data-pool="${id}" type="button">Withdraw</button>
        </span>
        <span class="pool-fin-detail" hidden>Borrowed ${debt > 0.0000001 ? fmtUsd(debt) : "nothing"} · Free cash ${fmtUsd(free)} — interest accrues only on actual borrows; cash-funded positions cost nothing to hold.</span>
      </div>
    </div>`;
  }).join("");
}

// HyperLiquid-style positions table (shared by the Account box and the Markets
// "Positions" tab). Each row carries a Close button (delegated handlers wired
// per container). The Account card nests tables under their pool block and
// passes { includePool: false }; the Markets tab is flat and keeps the column.
function positionsTableHTML(positions, opts) {
  const includePool = !opts || opts.includePool !== false;
  if (!positions || positions.length === 0) {
    return `<div class="empty-state">No open positions yet</div>`;
  }
  const optNum = (o) => (o && o.length ? Number(o[0]) : null);
  const poolLabel = poolLabelHTML;   // shared renderer — Positions History must match
  const rows = positions.map((p) => {
    const size = Number(p.size), isLong = size > 0, base = p.baseToken;
    const entry = Number(p.entryPrice), mark = Number(p.markPrice);
    const uPnl = Number(p.unrealizedPnl), rPnl = Number(p.realizedPnl);
    const notional = Number(p.notionalUsd);
    const roe = notional > 0 ? (uPnl / notional) * 100 : 0;
    // liqPrice/pctToLiq are `opt Nat`: the candid opt wraps the bigint in an
    // array, which puts it out of the money normalizer's key-walker reach
    // (the value sits at an array index, not under its field name) — so both
    // arrive RAW. Scale here: price e8 → USD; pctToLiq e8-fraction → percent.
    // (Unscaled, a $1.21 liq price rendered as 121,000,000 — ~50M× the entry.)
    const liqRaw = optNum(p.liqPrice), ptlRaw = optNum(p.pctToLiq);
    const liq = liqRaw != null ? liqRaw / 1e8 : null;
    const ptl = ptlRaw != null ? ptlRaw / 1e6 : null;
    // A liquidation price absurdly far from the mark (>100× either way)
    // means "no practical liquidation at current equity". A dust first fill
    // backed by a deep cross pool puts it at astronomical values (seen live:
    // a 0.0000026 SOL short showing liq $8.2B and ten-billion % to liq) —
    // mathematically true, meaningless to display. Print — instead, and keep
    // the row itself (its Close button must stay reachable: dust exposure
    // still blocks an isolated pool).
    const liqSane = liq != null && liq > 0 && mark > 0 && liq <= mark * 100 && liq * 100 >= mark;
    const sizeAbs = Math.abs(size);
    const sizeStr = sizeAbs > 0 && sizeAbs < 0.005 ? "&lt;0.01" : fmtQty(sizeAbs, base);
    const pnlCls = uPnl >= 0 ? "pos-up" : "pos-down";
    return `<tr>
      <td>${assetCellHTML(base)}</td>
      <td class="td-side">${sidePillHTML(isLong ? "Long" : "Short")}</td>
      ${includePool ? `<td class="pos-pool">${poolLabel(p.poolId)}</td>` : ""}
      <td>${sizeStr} ${base}</td>
      <td>${fmtUsd(notional)}</td>
      <td>${fmtUsdPrice(entry, mark)}</td>
      <td>${fmtUsdPrice(mark)}</td>
      <td class="${pnlCls}">${uPnl >= 0 ? "+" : ""}${fmtUsd(uPnl)} <span class="pos-roe">(${roe >= 0 ? "+" : ""}${roe.toFixed(1)}%)</span></td>
      <td>${liqSane ? fmtUsdPrice(liq, mark) : "—"}${liqSane && ptl != null ? ` <span class="pos-roe">${ptl.toFixed(1)}%</span>` : ""}</td>
      <td class="${rPnl >= 0 ? "pos-up" : "pos-down"}">${rPnl !== 0 ? (rPnl >= 0 ? "+" : "") + fmtUsd(rPnl) : "—"}</td>
      <td><button class="btn btn-danger btn-sm pos-close-btn" data-pool="${Number(p.poolId)}" data-market="${p.marketId}">Close</button></td>
    </tr>`;
  }).join("");
  return `<table class="positions-table"><thead><tr>
    <th>Asset</th><th class="th-side">Side</th>${includePool ? '<th class="th-pool">Pool</th>' : ""}<th>Size</th><th>Value</th><th>Entry</th><th>Mark</th><th>uPnL (%)</th><th>Liq. price</th><th>Realized</th><th></th>
  </tr></thead><tbody>${rows}</tbody></table>`;
}
function posMsg(text, type) {
  const el = document.getElementById("pos-msg");
  if (el) el.className = "margin-msg " + (type === "err" ? "margin-msg-err" : type === "ok" ? "margin-msg-ok" : "");
  if (el) el.textContent = text;
  if (type) showToast(text, type === "err" ? "error" : "success");
}
// Wire the pool-management controls once (idempotent — dataset.wired guard).
function wirePositionActions() {
  const root = document.getElementById("pos-actions");
  if (!root || root.dataset.wired) return;
  root.dataset.wired = "1";
  document.getElementById("pos-newpool-btn").addEventListener("click", () => {
    const f = document.getElementById("pos-newpool-form");
    f.style.display = f.style.display === "none" ? "flex" : "none";
  });
  document.getElementById("pos-newpool-create").addEventListener("click", onCreatePool);
  // Pool blocks re-render every refresh → delegate fund/withdraw + position
  // Close clicks on the stable container.
  document.getElementById("pools-rows")?.addEventListener("click", (e) => {
    const fw = e.target.closest(".pool-fund-btn, .pool-withdraw-btn");
    if (fw) {
      const amt = parseFloat(fw.closest(".pool-block")?.querySelector(".pool-amt")?.value || "0");
      onFundOrWithdrawPool(fw.dataset.pool, amt, fw.classList.contains("pool-fund-btn"));
      return;
    }
    // Financing disclosure: reveal the borrow/free-cash detail line.
    const fin = e.target.closest(".pool-fin-toggle");
    if (fin) {
      const detail = fin.closest(".pool-block-foot")?.querySelector(".pool-fin-detail");
      if (detail) {
        detail.hidden = !detail.hidden;
        fin.textContent = detail.hidden ? "Financing ▸" : "Financing ▾";
      }
      return;
    }
    const close = e.target.closest(".pos-close-btn");
    if (close) onClosePosition(close.dataset.pool, close.dataset.market);
  });
  document.getElementById("pool-orders-wrap")?.addEventListener("click", (e) => {
    const btn = e.target.closest(".pool-cancel-btn");
    if (btn) onCancelPoolOrder(btn.dataset.pool, btn.dataset.order);
  });
}

async function onCreatePool() {
  if (!appState.actor) return;
  const name = (document.getElementById("pos-newpool-name").value || "").trim() || "Pool";
  const isolated = document.getElementById("pos-newpool-mode").value === "isolated";
  try {
    const res = await appState.actor.createMarginPool(name, isolated);
    if ("err" in res) return posMsg(res.err, "err");
    posMsg(`Pool "${name}" created — fund it below, then open positions from the Markets page (Place Order → Margin).`, "ok");
    document.getElementById("pos-newpool-name").value = "";
    document.getElementById("pos-newpool-form").style.display = "none";
    await renderPositions();
  } catch (e) { posMsg(String(e), "err"); }
}

// Fund or withdraw pool margin from its row in the Pools table.
async function onFundOrWithdrawPool(poolId, amt, isFund) {
  if (!appState.actor) return;
  const p = _poolsCache.find((x) => String(Number(x.id)) === String(poolId));
  if (!p) return posMsg("Pool not found — refresh and try again.", "err");
  if (!(amt > 0)) return posMsg("Enter an amount > 0.", "err");
  try {
    const res = isFund
      ? await appState.actor.fundMarginPool(BigInt(Number(p.id)), toE8(amt))
      : await appState.actor.withdrawMarginPool(BigInt(Number(p.id)), toE8(amt));
    if ("err" in res) return posMsg(res.err, "err");
    posMsg(isFund ? `Funded ${fmtUsd(amt)} into "${p.name}".` : `Withdrew ${fmtUsd(amt)} from "${p.name}".`, "ok");
    await Promise.all([renderPositions(), refreshBalances()]);
  } catch (e) { posMsg(String(e), "err"); }
}

async function onClosePosition(poolId, market) {
  if (!appState.actor) return;
  try {
    const res = await appState.actor.closePosition(BigInt(Number(poolId)), market, toE8(0.05), []);
    if ("err" in res) return posMsg(res.err, "err");
    posMsg(`Closing ${market.split("-")[0]} — settles in ~1–2s.`, "ok");
    await Promise.all([renderPositions(), refreshBalances()]);
    if (uomTab === "positions") renderUserOrdersMobile();
    setTimeout(() => { renderPositions(); if (uomTab === "positions") renderUserOrdersMobile(); }, 2500);
  } catch (e) { posMsg(String(e), "err"); }
}

// ── Pool resting orders (limit entries) + cancel ──
// Lists every pool's resting/staged orders (no pool selector any more), each
// row labeled with its pool and carrying a Cancel button.
async function renderPoolOrders() {
  const wrap = document.getElementById("pool-orders-wrap");
  if (!wrap || !appState.actor || !appState.isAuthenticated) return;
  if (!_poolsCache.length) { wrap.innerHTML = ""; return; }
  try {
    const perPool = await Promise.all(_poolsCache.map((p) =>
      appState.actor.getPoolOrders(BigInt(Number(p.id))).then((orders) => ({ p, orders })).catch(() => ({ p, orders: [] }))
    ));
    const rows = perPool.flatMap(({ p, orders }) => (orders || []).map((o) => {
      const isBuy = "buy" in o.side;
      const base = String(o.marketId).split("-")[0];
      return `<div class="pool-order-row">
        <span class="pos-side ${isBuy ? "pos-long" : "pos-short"}">${isBuy ? "BUY" : "SELL"}</span>
        <span>${fmtQty(Number(o.quantity), base)} ${base} @ ${fmtUsd(Number(o.price))} <span class="pos-roe">· ${escH(p.name)}</span></span>
        <button class="btn btn-danger btn-sm pool-cancel-btn" data-pool="${Number(p.id)}" data-order="${Number(o.id)}">Cancel</button>
      </div>`;
    }));
    wrap.innerHTML = rows.length ? `<div class="margin-subhead">Resting orders</div>${rows.join("")}` : "";
  } catch (e) { console.warn("renderPoolOrders failed:", e); }
}

async function onCancelPoolOrder(poolId, orderId) {
  if (!appState.actor) return;
  try {
    const res = await appState.actor.cancelPoolOrder(BigInt(Number(poolId)), BigInt(Number(orderId)));
    if ("err" in res) return posMsg(res.err, "err");
    posMsg("Order cancelled; the pre-borrow was repaid.", "ok");
    await Promise.all([renderPositions(), refreshBalances()]);
  } catch (e) { posMsg(String(e), "err"); }
}

// ── Wallet: withdraw handler ──
// (Depositing moved to the Deposit page — the bridge claim flow.)
async function onWalletWithdraw() {
  if (!appState.actor) return;
  const token = document.getElementById("wallet-token").value;
  const amt = parseFloat(document.getElementById("wallet-wd-amount").value || "0");
  const dest = (document.getElementById("wallet-wd-dest").value || "").trim();
  if (!(amt > 0)) return walletMsg("Enter an amount > 0.", "err");
  if (!dest) return walletMsg("Enter a destination address.", "err");
  try {
    const res = await appState.actor.withdraw(token, toE8(amt), dest);
    if ("err" in res) return walletMsg(res.err, "err");
    walletMsg(`Withdrew ${amt} ${token} (dev: wallet balance debited; no real transfer yet).`, "ok");
    document.getElementById("wallet-wd-amount").value = "";
    await refreshBalances();
  } catch (e) { walletMsg(String(e), "err"); }
}

function walletMsg(text, type) {
  const el = document.getElementById("wallet-msg");
  if (el) { el.className = "margin-msg " + (type === "err" ? "margin-msg-err" : type === "ok" ? "margin-msg-ok" : ""); el.textContent = text; }
  if (type) showToast(text, type === "err" ? "error" : "success");
}

// Replace a native <select>'s OS-drawn popup (which mispositions in embedded /
// webview browsers — it can appear detached from the control) with a DOM menu
// anchored directly under a button. The native <select> is kept, visually
// hidden, as the value source, so existing reads of `.value` and any `change`
// listeners keep working — selecting an option dispatches `change` on it.
function enhanceSelectDropdown(selectId, cfg = {}) {
  const sel = document.getElementById(selectId);
  if (!sel || sel.dataset.enhanced) return;
  sel.dataset.enhanced = "1";
  const wrap = document.createElement("div");
  wrap.className = cfg.icons ? "dd dd-has-icons" : "dd";
  sel.parentNode.insertBefore(wrap, sel);
  wrap.appendChild(sel);
  sel.classList.add("dd-native");
  sel.tabIndex = -1;

  const opts = () => [...sel.options];
  const labelFor = (v) => { const o = opts().find((x) => x.value === v); return o ? o.textContent : v; };
  // Optional asset icon before the symbol (cfg.icons — the Swap token selects).
  // Sourced from public/assets/<SYM>.svg; hides itself if the file is missing.
  const icon = (v) => cfg.icons ? `<img class="dd-icon" src="/assets/${encodeURIComponent(v)}.svg" alt="" data-hide-on-error>` : "";
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "pos-input dd-btn";
  const menu = document.createElement("div");
  menu.className = "dd-menu";
  menu.style.display = "none";

  const renderBtn = () => { btn.innerHTML = `${icon(sel.value)}<span class="dd-label"></span><span class="dd-chevron">▾</span>`; btn.querySelector(".dd-label").textContent = labelFor(sel.value); };
  const renderMenu = () => {
    menu.innerHTML = opts().map((o) =>
      `<button type="button" class="dd-opt${o.value === sel.value ? " dd-opt-active" : ""}" data-v="${o.value}">${icon(o.value)}<span class="dd-opt-label"></span></button>`).join("");
    menu.querySelectorAll(".dd-opt").forEach((b) => { b.querySelector(".dd-opt-label").textContent = labelFor(b.dataset.v); });
  };
  const close = () => { menu.style.display = "none"; wrap.classList.remove("dd-open"); };
  const open = () => { renderMenu(); menu.style.display = "block"; wrap.classList.add("dd-open"); };

  btn.addEventListener("click", (e) => { e.stopPropagation(); menu.style.display === "block" ? close() : open(); });
  menu.addEventListener("click", (e) => {
    const opt = e.target.closest(".dd-opt"); if (!opt) return;
    if (sel.value !== opt.dataset.v) { sel.value = opt.dataset.v; renderBtn(); sel.dispatchEvent(new Event("change", { bubbles: true })); }
    close();
  });
  document.addEventListener("click", (e) => { if (!wrap.contains(e.target)) close(); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") close(); });
  sel.addEventListener("change", renderBtn); // keep label synced on programmatic changes

  renderBtn();
  wrap.appendChild(btn);
  wrap.appendChild(menu);
}

async function renderAccountTrades() {
  if (!appState.actor || !appState.isAuthenticated) return;
  const tbody = document.getElementById("account-trades-body");
  if (!tbody) return;
  try {
    const trades = await appState.actor.getMyTradeHistory();
    const hotIds = new Set(trades.map((t) => Number(t.id)));
    const hot = trades.map((t) => {
      const ts = typeof t.timestamp === "bigint"
        ? Number(t.timestamp / 1000000n)
        : Number(t.timestamp) / 1000000;
      // Determine the user's role + side:
      //  - if I'm the buyer: side = BUY; I was the taker iff buyOrderId == 0
      //  - if I'm the seller: side = SELL; I was the taker iff sellOrderId == 0
      // Maker side is always Limit by definition (only limit orders rest).
      // Taker side comes from t.takerOrderType (recorded at trade time).
      // Legacy trades from before this field landed return null → "—".
      const buyerStr  = String(t.buyer);
      const sellerStr = String(t.seller);
      const isBuyer   = appState.myPrincipalText && buyerStr  === appState.myPrincipalText;
      const isSeller  = appState.myPrincipalText && sellerStr === appState.myPrincipalText;
      const buyOrderId  = typeof t.buyOrderId  === "bigint" ? t.buyOrderId  : BigInt(t.buyOrderId);
      const sellOrderId = typeof t.sellOrderId === "bigint" ? t.sellOrderId : BigInt(t.sellOrderId);
      let sideLabel = "—", sideCls = "", typeLabel = "—";
      if (isBuyer) {
        sideLabel = "BUY";
        sideCls   = "side-buy";
        if (buyOrderId === 0n) {
          // I was the taker — read takerOrderType (Opt(OrderType) = [] or [{market}|{limit}])
          const tot = Array.isArray(t.takerOrderType) && t.takerOrderType.length > 0 ? t.takerOrderType[0] : null;
          typeLabel = tot && "market" in tot ? "Market" : tot && "limit" in tot ? "Limit" : "—";
        } else {
          typeLabel = "Limit";
        }
      } else if (isSeller) {
        sideLabel = "SELL";
        sideCls   = "side-sell";
        if (sellOrderId === 0n) {
          const tot = Array.isArray(t.takerOrderType) && t.takerOrderType.length > 0 ? t.takerOrderType[0] : null;
          typeLabel = tot && "market" in tot ? "Market" : tot && "limit" in tot ? "Limit" : "—";
        } else {
          typeLabel = "Limit";
        }
      }
      return { tsMs: ts, marketId: t.marketId, typeLabel, sideLabel, sideCls,
        price: t.price, quantity: t.quantity, archived: false };
    });
    // Archived spot fills merge behind the hot rows (dedup by tradeId; see
    // the archived-fills module). Taker/maker role isn't recorded in the
    // archive event, so Type reads "—" like legacy rows.
    const merged = hot.concat(afSpotRows(hotIds).map((r) => ({
      tsMs: r.tsMs, marketId: r.marketId, typeLabel: "—",
      sideLabel: r.side === "buy" ? "BUY" : "SELL",
      sideCls: r.side === "buy" ? "side-buy" : "side-sell",
      price: r.price, quantity: r.quantity, archived: true,
    }))).sort((a, b) => b.tsMs - a.tsMs);
    // First backfill pull happens unprompted (older history streams in);
    // further pages load from the button below. Re-render only when rows
    // landed or the chain finished (afFetchNext caller contract — an
    // unconditional re-render microtask-loops into a page freeze during
    // auth bootstrap).
    if (afMore() && appState.myPrincipalText && (_afSources === null || !merged.length)) {
      afFetchNext().then((added) => { if (added || !afMore()) renderAccountTrades(); });
    }
    if (!merged.length) {
      tbody.innerHTML = `<tr><td colspan="7" class="empty-state">${afMore() ? "Searching the archive for older history…" : "No trades yet"}</td></tr>`;
      return;
    }
    const loadMore = afMore()
      ? '<tr class="af-more-row"><td colspan="7"><button id="account-trades-more" class="btn btn-sm">Load older history</button></td></tr>'
      : "";
    tbody.innerHTML = merged.map((r) => `<tr${r.archived ? ' class="uom-row-archived"' : ""}>
        <td>${new Date(r.tsMs).toLocaleString()}${r.archived ? " " + AF_TAG : ""}</td>
        <td>${r.marketId}</td>
        <td>${r.typeLabel}</td>
        <td class="${r.sideCls}">${r.sideLabel}</td>
        <td>${formatPrice(r.price)}</td>
        <td>${formatNum(r.quantity)}</td>
        <td>${formatNum(typeof r.price === "bigint" ? r.price * r.quantity : Number(r.price) * Number(r.quantity))}</td>
      </tr>`).join("") + loadMore;
    document.getElementById("account-trades-more")?.addEventListener("click", async function () {
      this.disabled = true; this.textContent = "Loading…";
      await afFetchNext();
      renderAccountTrades();
    });
  } catch (e) {
    console.warn("Failed to fetch trade history:", e);
  }
}

// Account-page open orders — list every active order across markets,
// with an inline Cancel button. Distinct from the Markets-page user
// orders panel which is scoped to the current market.
async function renderAccountOpenOrders() {
  if (!appState.actor || !appState.isAuthenticated) return;
  const tbody = document.getElementById("account-open-orders-body");
  if (!tbody) return;
  try {
    const merged = await appState.actor.getMyOrders();
    if (!merged.length) {
      tbody.innerHTML = '<tr><td colspan="8" class="empty-state">No open orders</td></tr>';
      return;
    }
    // Tag pool-owned (margin) rows so the Type column says so — cancel needs
    // no special routing (cancelMyOrder deleverages pool orders backend-side).
    const { mine, pool } = await splitPoolOrders(merged);
    const orders = [...mine, ...pool.map((o) => ({ ...o, _pool: true }))];
    // Newest first.
    const sorted = [...orders].sort((a, b) => {
      const ta = typeof a.timestamp === "bigint" ? a.timestamp : BigInt(a.timestamp);
      const tb = typeof b.timestamp === "bigint" ? b.timestamp : BigInt(b.timestamp);
      return tb > ta ? 1 : tb < ta ? -1 : 0;
    });
    tbody.innerHTML = sorted.map((o) => {
      const ts = typeof o.timestamp === "bigint"
        ? Number(o.timestamp / 1000000n)
        : Number(o.timestamp) / 1000000;
      const isBuy = "buy" in o.side;
      const typeLabel = o._pool ? `Margin (${escH(o.poolName)})` : ("market" in o.orderType ? "Market" : "Limit");
      return `<tr>
        <td>${new Date(ts).toLocaleString()}</td>
        <td>${o.marketId}</td>
        <td>${typeLabel}</td>
        <td class="${isBuy ? "side-buy" : "side-sell"}">${isBuy ? "BUY" : "SELL"}</td>
        <td>${formatPrice(o.price)}</td>
        <td>${formatNum(o.quantity)}</td>
        <td>${formatNum(o.filled)}</td>
        <td><button class="btn btn-danger btn-sm" data-account-cancel="${o.id}">✕</button></td>
      </tr>`;
    }).join("");
    tbody.querySelectorAll("[data-account-cancel]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        await cancelOrder(Number(btn.dataset.accountCancel));
        renderAccountOpenOrders();
      });
    });
  } catch (e) {
    console.warn("Failed to fetch open orders:", e);
  }
}

// Account-page "Recently Closed Orders" — the capped closed-order history
// the backend reaper appends as it frees terminal orders from the hot map
// (newest-first from getMyClosedOrders). The executions themselves are in
// Trade History; this is the order-level outcome view.
async function renderAccountClosedOrders() {
  if (!appState.actor || !appState.isAuthenticated) return;
  const tbody = document.getElementById("account-closed-orders-body");
  if (!tbody) return;
  try {
    const closed = await appState.actor.getMyClosedOrders();
    if (!closed.length) {
      tbody.innerHTML = '<tr><td colspan="8" class="empty-state">No closed orders yet</td></tr>';
      return;
    }
    tbody.innerHTML = closed.map((o) => {
      const ts = typeof o.closedAt === "bigint"
        ? Number(o.closedAt / 1000000n)
        : Number(o.closedAt) / 1000000;
      const isBuy = "buy" in o.side;
      const typeLabel = "market" in o.orderType ? "Market" : "Limit";
      const isFilled = "filled" in o.status;
      return `<tr>
        <td>${new Date(ts).toLocaleString()}</td>
        <td>${o.marketId}</td>
        <td>${typeLabel}</td>
        <td class="${isBuy ? "side-buy" : "side-sell"}">${isBuy ? "BUY" : "SELL"}</td>
        <td>${formatPrice(o.price)}</td>
        <td>${formatNum(o.quantity)}</td>
        <td>${formatNum(o.filled)}</td>
        <td>${isFilled ? "Filled" : "Cancelled"}</td>
      </tr>`;
    }).join("");
  } catch (e) {
    console.warn("Failed to fetch closed orders:", e);
  }
}

// WHY the venue touched the order (opt variant from getMyAdjustments; [] on
// fossil rows recorded before reasons existed — rendered as an em dash).
const ADJ_REASON_LABELS = {
  balanceShrank: "Balance change",
  marketCapExceeded: "Per-market cap",
  crossMarketCapExceeded: "Cross-market cap",
};
function adjReasonLabel(reason) {
  if (!reason || !reason.length) return "—";
  const key = Object.keys(reason[0])[0];
  return ADJ_REASON_LABELS[key] || key;
}

async function renderAccountAdjustments() {
  if (!appState.actor || !appState.isAuthenticated) return;
  const tbody = document.getElementById("account-adj-body");
  if (!tbody) return;
  try {
    const adjs = await appState.actor.getMyAdjustments();
    if (!adjs.length) {
      tbody.innerHTML = '<tr><td colspan="8" class="empty-state">No adjustments</td></tr>';
      return;
    }
    tbody.innerHTML = [...adjs].reverse().map((a) => {
      const ts = typeof a.timestamp === "bigint"
        ? Number(a.timestamp / 1000000n)
        : Number(a.timestamp) / 1000000;
      const sideLabel = a.side.buy !== undefined ? "BUY" : "SELL";
      const sideCls   = a.side.buy !== undefined ? "side-buy" : "side-sell";
      const status    = a.cancelled ? '<span class="badge badge-red">Cancelled</span>' : '<span class="badge badge-yellow">Resized</span>';
      return `<tr>
        <td>${new Date(ts).toLocaleString()}</td>
        <td>#${a.orderId}</td>
        <td>${a.marketId}</td>
        <td class="${sideCls}">${sideLabel}</td>
        <td>${formatNum(a.oldQuantity)}</td>
        <td>${formatNum(a.newQuantity)}</td>
        <td>${status}</td>
        <td>${adjReasonLabel(a.reason)}</td>
      </tr>`;
    }).join("");
  } catch (e) {
    console.warn("Failed to fetch adjustments:", e);
  }
}

async function renderAccountDeposits() {
  if (!appState.actor || !appState.isAuthenticated) return;
  const tbody = document.getElementById("account-deposits-body");
  if (!tbody) return;
  try {
    const deposits = await appState.actor.getMyDeposits();
    if (!deposits.length) {
      tbody.innerHTML = '<tr><td colspan="4" class="empty-state">No deposits yet</td></tr>';
      return;
    }
    tbody.innerHTML = [...deposits].reverse().map((d) => {
      const ts = typeof d.timestamp === "bigint"
        ? Number(d.timestamp / 1000000n)
        : Number(d.timestamp) / 1000000;
      const kind = d.kind.deposit !== undefined ? "Deposit" : "Withdrawal";
      const kindCls = d.kind.deposit !== undefined ? "side-buy" : "side-sell";
      return `<tr>
        <td>${new Date(ts).toLocaleString()}</td>
        <td>${d.token}</td>
        <td>${formatNum(d.amount)}</td>
        <td class="${kindCls}">${kind}</td>
      </tr>`;
    }).join("");
  } catch (e) {
    console.warn("Failed to fetch deposits:", e);
  }
}

// ── Stats page ──────────────────────────────────────────────────
// Aggregates a handful of query calls into the Stats view. Refreshes
// on tab-activation plus a 5s auto-refresh while the tab is visible.
// All rendering happens into pre-existing DOM containers from
// index.html; no dynamic <main> creation.

let statsRefreshTimer = null;

function startStatsAutoRefresh() {
  stopStatsAutoRefresh();
  statsRefreshTimer = setInterval(() => {
    if (document.getElementById("stats-view")?.classList.contains("active")) {
      refreshStats();
    }
  }, 5000);
}
function stopStatsAutoRefresh() {
  if (statsRefreshTimer) { clearInterval(statsRefreshTimer); statsRefreshTimer = null; }
}

// Money/qty formatters that adapt to the token's typical scale.
// ICPUSD: no decimals for big numbers, 2 otherwise.
// BTC: 4 decimals. ETH: 2. ICP: 2. Anything else: 4.
function fmtUsd(n) {
  if (n == null || isNaN(n)) return "—";
  if (Math.abs(n) >= 1000) return `$${Math.round(n).toLocaleString()}`;
  if (Math.abs(n) >= 1) return `$${n.toFixed(2)}`;
  return `$${n.toFixed(4)}`;
}
// $-quoted PRICE columns (entry/mark/liq, position-fill price): Order Book /
// Trades precision, NOT fmtUsd — money rounding (whole dollars ≥$1k, 2 dp
// above $1) blurs levels the books beside these tables quote to ≥5 digits.
function fmtUsdPrice(n, anchor) {
  const s = formatBookPrice(n, anchor);
  return s === "—" ? s : `$${s}`;
}
// Precision anchor for a cross-market activity row: the row's market price
// (mark, else last — the books' own reference), so every row prints at ITS
// market's precision — ICP rows 4 dp, BTC rows 0 dp price / 5 dp qty. Falls
// back to the row's own price until the markets list has loaded (or for a
// delisted market surviving only in history rows).
function uomAnchor(marketId, ownPrice) {
  const m = markets.find((x) => x.id === marketId);
  const p = m ? (m.markPrice > 0 ? m.markPrice : m.lastPrice) : 0;
  return p > 0 ? p : ownPrice || 0;
}
function fmtQty(n, token) {
  if (n == null || isNaN(n)) return "—";
  const dec = token === "BTC" ? 4
            : token === "ETH" ? 2
            : token === "SOL" ? 2
            : token === "ICP" ? 2
            : 4;
  return n.toLocaleString(undefined, { minimumFractionDigits: dec, maximumFractionDigits: dec });
}
function fmtPct(n, digits = 2) {
  if (n == null || isNaN(n)) return "—";
  const sign = n >= 0 ? "+" : "";
  return `${sign}${n.toFixed(digits)}%`;
}
function fmtBps(n) {
  if (n == null || isNaN(n)) return "—";
  return `${n.toFixed(1)} bps`;
}
// Render `BTC-ICPUSD` as `BTC<span class="market-quote">/ICPUSD</span>`,
// matching the Markets page's slash-and-grey format. Same .market-quote
// CSS class is reused so the dim treatment stays consistent across pages.
function fmtMarketId(id) {
  const dash = id.indexOf("-");
  if (dash < 0) return id;
  return `${id.slice(0, dash)}<span class="market-quote">/${id.slice(dash + 1)}</span>`;
}

function fmtAgo(ns) {
  if (!ns) return "never";
  const diffMs = Date.now() - Number(ns) / 1e6;
  if (diffMs < 0) return "just now";
  if (diffMs < 1000) return "just now";
  const s = Math.floor(diffMs / 1000);
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m ago`;
}

// ── Status inner-tab state (hash-driven, like the Account tabs) ──
// Internal tokens keep their legacy names (the AMM pane's token is "pnl",
// the Canisters pane's is "canister"); STATS_TOKEN_TO_SLUG maps token → the
// URL slug users see, so the address bar reads #system/amm. Unmapped tokens
// use themselves as the slug in both directions.
const STATS_TABS = ["overview", "issues", "pnl", "insurance", "treasury", "canister", "events"];
const STATS_TOKEN_TO_SLUG = { pnl: "amm" };
const STATS_SLUG_TO_TOKEN = { amm: "pnl" };
let statsTab = "overview";

function showStatsTab(name) {
  const tok = STATS_SLUG_TO_TOKEN[name] || name;
  statsTab = STATS_TABS.includes(tok) ? tok : "overview";
  document.querySelectorAll(".stats-subtab").forEach((b) =>
    b.classList.toggle("active", b.dataset.statsTab === statsTab));
  document.querySelectorAll(".stats-tab-content").forEach((p) =>
    p.classList.toggle("active", p.id === `stats-${statsTab}-pane`));
  // Issues computes only while visible — render immediately on entry rather
  // than waiting for the next 5s stats tick.
  if (statsTab === "issues") {
    const a = appState.publicActor || appState.actor;
    if (a) renderStatsIssues(a, null);
  }
}

async function refreshStats() {
  // Prefer the anonymous public appState.actor for stats — they're all query
  // calls and work pre-login. Fall back to the authenticated appState.actor
  // once logged in (same endpoints, different principal).
  const a = appState.publicActor || appState.actor;
  if (!a) return;
  try {
    // Fire all queries concurrently — each is a cheap `query` call.
    const [pools, feedStats, marketsList, btcAgg, ethAgg, solAgg, icpAgg, sources] = await Promise.all([
      a.getAmmPools(),
      a.getPriceFeedStats(),
      a.getMarkets(),
      a.getLastAggregate("BTC"),
      a.getLastAggregate("ETH"),
      a.getLastAggregate("SOL"),
      a.getLastAggregate("ICP"),
      a.getPriceSources(),
    ]);

    // Pool-value queries: fire one per pool so we get baseHeld/quoteHeld
    // (which aren't on the Pool record itself — they're computed from
    // the AMM principal's live balance).
    const poolValues = await Promise.all(
      pools.map((p) => a.getPoolValue(p.marketId).then((opt) => (opt && opt[0]) || null))
    );

    // Vault P&L data: one global value + history (single ring buffer
    // since the vault is unified). Replaces the per-pool histories.
    let vault = null;
    let vaultHistory = [];
    try { vault = await a.getVaultValue(); } catch (e) { console.warn("getVaultValue:", e); }
    try { vaultHistory = await a.getVaultValueHistory(); } catch (e) { console.warn("getVaultValueHistory:", e); }

    // Protocol treasury (accrued trading fees, ICPUSD).
    let treasury = null;
    try { treasury = await a.getTreasury(); } catch (e) { console.warn("getTreasury:", e); }

    // AMM book commitment per market — used by the Pools section to
    // show how much of each market's book the AMM is responsible for.
    const bookShares = {};
    for (const p of pools) {
      try {
        const opt = await a.getAmmBookShare(p.marketId);
        bookShares[p.marketId] = (opt && opt[0]) || null;
      } catch (e) { bookShares[p.marketId] = null; }
    }

    const aggregates = {
      BTC: btcAgg?.[0] || null,
      ETH: ethAgg?.[0] || null,
      SOL: solAgg?.[0] || null,
      ICP: icpAgg?.[0] || null,
    };

    // Order book snapshots for the depth section — one per market.
    const books = {};
    for (const m of marketsList) {
      try { books[m.id] = await a.getOrderBookDepth(m.id, [OB_FETCH_DEPTH]); } catch { books[m.id] = null; }
    }

    renderStatsKpis({ pools, feedStats, marketsList, poolValues, vault, treasury });
    renderStatsMarkets({ marketsList, pools, poolValues, aggregates });
    renderStatsPools({ pools, bookShares, vault });
    renderStatsOracle({ feedStats, aggregates, sources, pools });
    renderStatsDepth({ marketsList, books });
    let insFund = null;
    try { insFund = await a.getInsuranceFund(); } catch (e) { /* pane still renders without it */ }
    renderStatsVault({ vault, vaultHistory, insFund });
    renderStatsInsurance(a);
    renderStatsTreasury(treasury);
    renderStatsArb(a);
    renderStatsIssues(a, { pools, feedStats, marketsList });
    refreshCanisterInfo();
    renderStatsEvents();
    renderStatsLeaderboard();
  } catch (e) {
    console.warn("refreshStats failed:", e);
  }
}

// ── Stats: Issues pane — auto-detected cards + operator notices ──
// Two sources share the list: hand-edited cards in #issues-curated
// (index.html) and the cards this renders into #issues-auto from live state.
// Severity: status-error = venue-impacting right now, status-warn = needs
// attention soon, unstyled = FYI. Thresholds sit well clear of normal
// operating values (e.g. price-staleness fires at 3× the oracle refresh
// interval, never on the routine between-tick ages), so a healthy venue
// renders nothing and the all-clear shows. Recomputed only while the pane is
// visible — the subtab click renders immediately, the 5s stats tick keeps it
// fresh after that.
async function renderStatsIssues(a, shared) {
  const auto = document.getElementById("issues-auto");
  if (!auto || !document.getElementById("stats-issues-pane")?.classList.contains("active")) return;

  const grab = async (p, fallback) => { try { return await p; } catch (e) { return fallback; } };
  const [info, chain, gaps, ins, events, pools, feedStats, marketsList] = await Promise.all([
    grab(a.getCanisterInfo(), null),
    grab(a.getArchiveChain(), []),
    grab(a.getLedgerGaps(), []),
    grab(a.getInsuranceFund(), null),
    grab(a.getRecentEvents(200), []),
    shared?.pools ? Promise.resolve(shared.pools) : grab(a.getAmmPools(), []),
    shared?.feedStats ? Promise.resolve(shared.feedStats) : grab(a.getPriceFeedStats(), null),
    shared?.marketsList ? Promise.resolve(shared.marketsList) : grab(a.getMarkets(), []),
  ]);

  const out = [];
  const card = (sev, title, body) => out.push({ sev, title, body });
  const ov = (x) => (Array.isArray(x) ? x[0] : x);   // candid opt → value | undefined
  const plur = (n, w) => `${n.toLocaleString()} ${w}${n === 1 ? "" : "s"}`;

  if (info) {
    const fs = fuelState(info);
    if (fs.paused) {
      card(2, "Exchange timers are paused",
        "Matching, price updates, liquidations and history shipping are all halted. This is an " +
        "operator state — trading resumes when timers are re-enabled.");
    }
    if (fs.frozen) {
      card(2, "Exchange is out of fuel (frozen)",
        "The canister froze at its cycles floor and rejects all calls. Anyone can revive it by " +
        "sending cycles to the exchange canister — the id is on the Canisters tab.");
    } else if (fs.memFull) {
      card(2, `Exchange memory is at ${Math.round(fs.memFrac * 100)}% of its Wasm limit`,
        "Updates are rejected (or about to be) even though queries still answer — this looks like " +
        "a fuel freeze from outside but is not one; a top-up will not fix it.");
    } else if (fs.critical) {
      card(2, `Exchange nearly out of spendable fuel (${fs.liquidT.toFixed(2)}T liquid)`,
        "The canister is about to freeze. Anyone can keep it alive by sending cycles to the " +
        "exchange canister id on the Canisters tab.");
    } else {
      if (fs.timeWarn) {
        card(1, `Exchange fuel runs out in ~${fmtDuration(fs.secsToFreeze)}`,
          `Measured burn is ${(fs.burnPerDay / 1e12).toFixed(1)}T/day against ` +
          `${fs.liquidT.toFixed(1)}T spendable. Top up before the freeze — the id is on the Canisters tab.`);
      } else if (fs.low) {
        card(1, `Exchange fuel is low (${fs.liquidT.toFixed(1)}T spendable)`,
          "Not urgent yet, but a top-up keeps comfortable headroom above the freezing floor.");
      }
      if (fs.memHigh) {
        card(1, `Exchange memory at ${Math.round(fs.memFrac * 100)}% of its Wasm limit`,
          "Past the limit the canister rejects every update while queries keep answering. " +
          "Reclaim space or raise the limit before that.");
      }
    }
    if (!fs.paused && !fs.dead && Number.isFinite(fs.ageSec) && fs.ageSec > 60) {
      card(2, `Heartbeat stalled — last beat ${Math.round(fs.ageSec)}s ago`,
        "Fuel and memory look healthy, so this is not a resource freeze — venue automation " +
        "(matching release, oracle, shipping) is not running. Needs investigation, not a top-up.");
    }

    const streak = Number(info.shipFailStreak ?? 0);
    const queued = Number(info.journalUnshipped ?? 0);
    if (streak >= 3) {
      card(2, `History archive unreachable (${streak} consecutive ship failures)`,
        `${plur(queued, "event")} buffering in the DEX meanwhile — nothing is lost, and the ` +
        "failover rolls to a fresh archive if the streak continues.");
    } else if (queued > 100_000) {
      card(1, `History shipping backlog: ${plur(queued, "event")} queued`,
        "The archive shipper is behind. The queue drains automatically (~2k every 10s); a " +
        "backlog this size usually means it is catching up after an interruption.");
    }
    const shed = Number(info.shedEvents ?? 0);
    if (shed > 0 || gaps.length > 0) {
      card(1, `History has ${plur(gaps.length, "recorded gap")} (${plur(shed, "event")} shed)`,
        "Under extreme memory pressure the DEX sheds its oldest queued history rather than " +
        "freeze. Every gap is permanently recorded and the ledger verifier re-baselines across " +
        "it, so verification stays honest about what is missing.");
    }
  }

  if (feedStats && info) {
    const susp = Number(feedStats.suspendedCount ?? 0);
    if (susp > 0) {
      card(1, `${plur(susp, "price source")} suspended`,
        `Aggregation continues on the remaining sources (minimum ${Number(feedStats.minSources)} ` +
        "to price). Suspended sources return automatically when they behave again.");
    }
    const nowNs = Number(info.nowNs ?? 0);
    const staleLimS = Math.max(3 * Number(feedStats.intervalSec ?? 30), 120);
    const enabled = (pools || []).filter((p) => p.enabled);
    const stale = enabled
      .map((p) => ({ m: p.marketId, ageS: (nowNs - Number(p.refPriceUpdatedNs ?? 0)) / 1e9 }))
      .filter((s) => s.ageS > staleLimS);
    if (enabled.length > 0 && stale.length === enabled.length) {
      card(2, "Reference prices stalled on every market",
        `Oldest is ${Math.round(Math.max(...stale.map((s) => s.ageS)))}s stale. The AMM sidelines ` +
        "itself without a fresh price — matching continues users-only with a ±2% clamp. If the " +
        "Oracle tab shows healthy sources, the fault is in the price-apply pipeline, not the oracle.");
    } else {
      for (const s of stale) {
        card(1, `Reference price stale on ${s.m} (${Math.round(s.ageS)}s)`,
          "The AMM is sidelined on this market until a fresh price lands — users-only matching " +
          "with a ±2% clamp meanwhile.");
      }
    }
    for (const p of (pools || []).filter((x) => !x.enabled)) {
      card(1, `AMM disabled on ${p.marketId}`,
        "No house quotes on this market — order-book liquidity only until it is re-enabled.");
    }
    // AMM COVERAGE, measured against the MARKET list rather than the pool list.
    // Iterating pools alone can only ever see markets that HAVE a pool, so a
    // market whose pool was never created — or was wiped by a reinstall — is
    // invisible to that loop: it is absent from the array being filtered.
    // Overview counts "N of M markets" and so reports the gap; Issues stayed
    // silent through exactly the case that matters most (observed: 1 of 4
    // markets making, nothing flagged). A pool sitting at refPrice 0 is the
    // same outage wearing a different hat — it exists but cannot quote.
    // A market record keys its id as `id`; a POOL record keys the same string
    // as `marketId`. Accept either so this can't silently match nothing.
    const withPool = new Set((pools || []).map((p) => p.marketId));
    const noPool = (marketsList || []).map((m) => m.id ?? m.marketId)
      .filter((id) => id && !withPool.has(id));
    const unpriced = (pools || []).filter((p) => p.enabled && Number(p.refPrice ?? 0) === 0)
      .map((p) => p.marketId);
    const missing = [...noPool, ...unpriced];
    if (missing.length) {
      const total = (marketsList || []).length || missing.length;
      card(2, `AMM is quoting ${total - missing.length} of ${total} market${total === 1 ? "" : "s"}`,
        `No house liquidity on ${missing.join(", ")} — those books are order-book only, so spreads `
        + "are wide and a market order can move the price much further than usual. "
        + (noPool.length
            ? "The vault has no pool on those markets (never created, or cleared by a reinstall); an operator must create, fund and enable one."
            : "The pool exists but has no reference price yet, so it will not quote until the oracle prices it."));
    }
  }

  // Insurance yield the vault has earned for stakers but not handed over.
  // Not a solvency problem — the vault holds the value, just not as cash — but
  // it is a silent transfer from the junior tranche to senior LPs for as long
  // as it lasts, so it should be visible rather than inferred from a share
  // price that mysteriously will not move.
  if (ins) {
    const pending = Number(ins.pendingYieldUsd ?? 0);
    if (pending > 0) {
      card(1, `Insurance yield pending: $${formatNum(pending)}`,
        "Liquidation penalties earned by insurance stakers that the vault has not paid across yet — "
        + "it took the seized collateral in kind and is short of ICPUSD. Share value stays flat until "
        + "it settles, which happens automatically as the vault's cash recovers.");
    }
  }

  for (const e of chain || []) {
    const frozen = ov(e.frozen);
    const cyc = Number(ov(e.cycles) ?? 0);
    const lim = Number(ov(e.freezeLimitCycles) ?? 0);
    if (frozen === true) {
      card(2, `History archive frozen: ${e.canisterId}`,
        "Reads of that span of history fail until the archive is topped up — anyone can send " +
        "cycles to the canister id above. Nothing is lost; it resumes where it stopped.");
    } else if (cyc > 0 && lim > 0 && cyc < lim * 1.25) {
      card(1, `History archive near its freezing limit (${String(e.role ?? "")}): ${e.canisterId}`,
        `${(cyc / 1e12).toFixed(1)}T cycles against a ${(lim / 1e12).toFixed(1)}T floor — top up ` +
        "before reads of its history stop.");
    }
  }

  // `ins` came through the money boundary, so uncoveredBadDebtUsd is already
  // dollars — the same read the insurance KPI does. Dividing here as well is
  // how the two panes of this page ended up disagreeing by 1e8 about the
  // number this card's own copy calls the most material one on the venue.
  if (ins && Number(ins.uncoveredBadDebtUsd ?? 0) > 0) {
    card(2, `Insurance shortfall: ${fmtUsd(Number(ins.uncoveredBadDebtUsd))} of bad debt uncovered`,
      "Liquidations left debt the insurance fund could not absorb. Until the buffer recovers, " +
      "this is the venue's most material risk number.");
  }

  const errs = (events || []).filter((e) => e.severity === "error");
  if (errs.length > 0) {
    card(1, `${plur(errs.length, "error event")} in the recent log`,
      `Latest: “${escH(String(errs[0].message ?? "").slice(0, 160))}” — the Events tab has the full log.`);
  }

  auto.innerHTML = out
    .sort((x, y) => y.sev - x.sev)
    .map((c) =>
      `<div class="status-alert ${c.sev === 2 ? "status-error" : c.sev === 1 ? "status-warn" : ""}">` +
      `<div class="status-alert-head"><span class="status-alert-dot"></span>` +
      `<span class="status-alert-title">${escH(c.title)}</span></div><p>${c.body}</p></div>`)
    .join("");
  const curated = document.querySelectorAll("#issues-curated .status-alert").length;
  const ac = document.getElementById("issues-allclear");
  if (ac) ac.style.display = out.length === 0 && curated === 0 ? "" : "none";
}

// ── Stats: Arbitrageur section (AMM subtab) ──
// Live view of the protocol arbitrageur (docs/amm-vault-design.md): working
// capital, lifetime import/export at the oracle mark, and hourly-budget use.
// getArbStats is public; "wired = none" (e.g. a #production target, which must
// not run one) collapses the card to its explainer with a "not wired" note.
async function renderStatsArb(a) {
  const set = (id, txt, cls) => {
    const el = document.getElementById(id);
    if (!el) return;
    el.textContent = txt;
    if (cls !== undefined) el.className = "kpi-value " + cls;
  };
  const sub = (id, t) => { const el = document.getElementById(id); if (el) el.textContent = t; };
  let st = null;
  try { st = await a.getArbStats(); } catch (e) { console.warn("getArbStats:", e); }
  if (!st || !st.wired || st.wired.length === 0) {
    set("kpi-arb-capital", "—"); set("kpi-arb-import", "—");
    set("kpi-arb-export", "—"); set("kpi-arb-hour", "—");
    sub("kpi-arb-wired", "not wired on this deployment");
    return;
  }
  // balances arrive as (token, raw-e8) tuples — tuple values bypass MONEY_KEYS.
  let capitalUsd = 0;
  for (const [tok, amt] of st.balances) {
    if (tok === "ICPUSD") capitalUsd += Number(amt) / 1e8;
  }
  const baseTokens = st.balances
    .filter(([tok, amt]) => tok !== "ICPUSD" && Number(amt) > 0)
    .map(([tok, amt]) => `${(Number(amt) / 1e8).toFixed(4)} ${tok}`)
    .join(" · ");
  set("kpi-arb-capital", fmtUsd(capitalUsd), "health-ok");
  sub("kpi-arb-wired", baseTokens
    ? `canister ${st.wired[0].toText().slice(0, 14)}… · holding ${baseTokens}`
    : `canister ${st.wired[0].toText().slice(0, 14)}… · flat (no inventory)`);
  set("kpi-arb-import", fmtUsd(Number(st.lifetimeImportUsd)));
  set("kpi-arb-export", fmtUsd(Number(st.lifetimeExportUsd)));
  const hourPct = Number(st.hourCapUsd) > 0
    ? (100 * Number(st.hourUsedUsd) / Number(st.hourCapUsd)) : 0;
  set("kpi-arb-hour", hourPct.toFixed(1) + "%",
    hourPct > 80 ? "health-warn" : "");
  sub("kpi-arb-caps",
    `${fmtUsd(Number(st.perCallCapUsd))}/trade · ${fmtUsd(Number(st.hourCapUsd))}/hour · ${Number(st.extHaircutBps) / 100}% external haircut`);
}

// ── Stats: Trading Leaderboard pane ──
// Renders the precomputed on-chain snapshot (profit vs HODL — see the pane's
// explainer). Uses the authed actor when available so `my` resolves to the
// caller's own row/rank even outside the top 50.
async function renderStatsLeaderboard() {
  const body = document.getElementById("lb-body");
  if (!body) return;
  const a = appState.actor || appState.publicActor;
  if (!a?.getLeaderboard) return;
  let lb;
  try { lb = await a.getLeaderboard(); }
  catch (e) { console.warn("getLeaderboard:", e); return; }

  // profitUsd/capitalUsd/equityUsd are in money.js's MONEY_KEYS, so wrapActor
  // already normalized them to human dollars — do NOT divide by 1e8 here.
  const usd = (n) => Number(n);
  const money = (v) => "$" + Math.abs(usd(v)).toLocaleString(undefined, { maximumFractionDigits: 0 });
  const signedMoney = (v) => (Math.abs(usd(v)) < 0.005 ? "$0" : (usd(v) < 0 ? "−" : "+") + money(v));
  const pnlClass = (v) => (usd(v) > 0.005 ? "lb-pos" : usd(v) < -0.005 ? "lb-neg" : "");
  const medal = (r) => (r === 1 ? "🥇" : r === 2 ? "🥈" : r === 3 ? "🥉" : "#" + r);

  if (!lb.rows.length) {
    body.innerHTML = `<tr><td colspan="7" class="empty-state">No ranked traders yet — the first snapshot lands within a minute of activity.</td></tr>`;
  } else {
    body.innerHTML = lb.rows.map((r) => {
      const lvl = Number(r.feeLevel);
      const hasCapital = usd(r.capitalUsd) > 0;
      // Return computed from the normalized dollars (returnBps is an Int and
      // floors sub-bp returns to 0 — fine on-chain, too coarse for display).
      const retPct = hasCapital ? (usd(r.profitUsd) / usd(r.capitalUsd)) * 100 : null;
      const retTxt = retPct === null ? "—" : (retPct > 0 ? "+" : "") + retPct.toFixed(2) + "%";
      const me = r.isMe ? " lb-me" : "";
      return `<tr class="lb-row${me}">
        <td class="lb-rank">${medal(Number(r.rank))}</td>
        <td class="lb-trader"><span class="lb-avatar" data-seed="${escH(r.username)}">${escH((r.username[0] || "?").toUpperCase())}</span>${escH(r.username)}</td>
        <td class="lb-num ${pnlClass(r.profitUsd)}">${signedMoney(r.profitUsd)}</td>
        <td class="lb-num ${hasCapital ? pnlClass(r.profitUsd) : ""}">${retTxt}</td>
        <td class="lb-num">${(usd(r.equityUsd) < 0 ? "−" : "") + money(r.equityUsd)}</td>
        <td class="lb-num"><span class="tier-badge tier-l${lvl}">L${lvl}</span></td>
        <td class="lb-num">${Number(r.badgeCount)} 🏅</td>
      </tr>`;
    }).join("");
    // USERNAME-seeded, not principal-seeded. A principal-seeded glyph would
    // survive a username regen — which sounds like a feature until you notice
    // it re-links the new name to the old one on a public board, defeating
    // regen as a way to shed attention. Seeded from the name, the glyph is a
    // function of public data and changes with it.
    body.querySelectorAll(".lb-avatar").forEach((el) =>
      setIdenticon(el, el.dataset.seed, el.textContent));
  }

  const my = document.getElementById("lb-my-rank");
  if (my) {
    if (lb.my.length) {
      const m = lb.my[0];
      my.style.display = "";
      my.innerHTML = `Your rank: <b>${medal(Number(m.rank))}</b> of ${Number(lb.totalRanked)}`
        + ` — trading profit <b class="${pnlClass(m.profitUsd)}">${signedMoney(m.profitUsd)}</b>`;
    } else {
      my.style.display = "none";
    }
  }
  const upd = document.getElementById("lb-updated");
  if (upd && Number(lb.computedAtNs) > 0) {
    upd.textContent = `${Number(lb.totalRanked)} traders ranked · snapshot `
      + new Date(Number(lb.computedAtNs) / 1e6).toLocaleTimeString() + " · recomputed every minute";
  }
}

// ── Stats: Insurance Fund pane ──
// The margin-system risk backstop: buffer (funded by 5% liquidation
// penalties), realised uncovered bad debt, and peer-to-peer netted volume.
async function renderStatsInsurance(a) {
  try {
    const [fund, netted] = await Promise.all([
      a.getInsuranceFund(),
      a.getNettedVolumeUsd(),
    ]);
    const buffer    = Number(fund.bufferUsd);
    const uncovered = Number(fund.uncoveredBadDebtUsd);
    const set = (id, txt, cls) => {
      const el = document.getElementById(id);
      if (!el) return;
      el.textContent = txt;
      if (cls !== undefined) el.className = "kpi-value " + cls;
    };
    set("kpi-ins-buffer", "$" + formatNum(buffer), "health-ok");
    set("kpi-ins-uncovered", "$" + formatNum(uncovered), uncovered > 0.0000001 ? "health-bad" : "");
    set("kpi-ins-netted", "$" + formatNum(Number(netted)));
    // Share value: 1.00 at genesis, rises as penalties accrue (staker
    // yield), falls when the pool absorbs bad debt (junior-tranche risk).
    const sv = Number(fund.shareValueUsd);
    set("kpi-ins-sharevalue", sv.toFixed(4), sv >= 0.9999 ? "health-ok" : "health-warn");
    // Yield in flight. Share value deliberately does NOT include it (the buffer
    // must stay backed by cash the pool holds), so without this a staker sees a
    // liquidation happen, sees the share price unmoved, and cannot tell whether
    // they earned nothing or are simply owed.
    const pending = Number(fund.pendingYieldUsd || 0);
    const subEl = document.getElementById("kpi-ins-sharevalue-sub");
    if (subEl) {
      subEl.textContent = pending > 0
        ? `+$${formatNum(pending)} earned, awaiting vault cash`
        : "1.00 at genesis · rises with yield, falls on bad debt";
    }
  } catch (e) {
    console.warn("renderStatsInsurance failed:", e);
  }
}

// ── Stats: Treasury pane ──
// Protocol fee war chest (ICPUSD) + the live maker/taker fee scheme. Funds DOS
// defense + self-funding fuel. Fee rates are read live from the backend constants
// (getTreasury), so the UI never hardcodes a rate that could drift on a retune.
async function renderStatsTreasury(treasury) {
  const set = (id, txt, cls) => {
    const el = document.getElementById(id);
    if (!el) return;
    el.textContent = txt;
    if (cls !== undefined) el.className = "kpi-value " + cls;
  };
  const text = (id, t) => { const el = document.getElementById(id); if (el) el.textContent = t; };
  if (!treasury) {
    set("kpi-tr-balance", "—"); set("kpi-tr-lifetime", "—");
    set("kpi-tr-paidout", "—"); set("kpi-tr-feerate", "—");
    return;
  }
  const balance  = Number(treasury.balanceUsd || 0);
  const lifetime = Number(treasury.lifetimeFeesUsd || 0);
  // lifetime − balance = every ICPUSD the treasury has ever paid out. Vault
  // restitution (donateToVault fromTreasury) drains it exactly like a fuel
  // swap, so this delta must NOT be captioned "converted to fuel".
  const paidOut = Math.max(0, lifetime - balance);
  set("kpi-tr-balance", fmtUsd(balance), "health-ok");
  set("kpi-tr-lifetime", fmtUsd(lifetime));
  set("kpi-tr-vaultshare", fmtUsd(Number(treasury.lifetimeVaultFeesUsd || 0)), "health-ok");
  set("kpi-tr-paidout", fmtUsd(paidOut));
  text("tr-principal", treasury.principal || "—");

  const a = appState.actor || appState.publicActor;

  // Fuel on the "Paid Out" sub-line comes from the backend's EXPLICIT counter
  // — getCanisterInfo's fuelLifetimeCycles, cycles actually minted from
  // treasury funds — never inferred from the balance delta: a deployment with
  // the route unwired (fuelRouteWired=false) has converted nothing, however
  // large its payouts. lastCanisterInfo is warm from the 20s poll; query
  // directly only on a cold first paint. On failure the static HTML caption
  // (no fuel attribution) stands.
  let info = lastCanisterInfo;
  if (!info && a?.getCanisterInfo) {
    try { info = await a.getCanisterInfo(); } catch (e) { console.warn("getCanisterInfo:", e); }
  }
  if (info) {
    const minted = Number(info.fuelLifetimeCycles ?? 0);
    text("kpi-tr-paidout-sub", minted > 0
      ? `lifetime − balance · incl. fuel: ${fmtCycles(minted)} cycles self-minted`
      : `lifetime − balance · vault restitution & other payouts · ${info.fuelRouteWired ? "no fuel minted yet" : "fuel route not wired"}`);
  }

  // Fee LADDER — rates are per-trader now (earned levels L0–L4), so the pane
  // shows the live schedule from getAccessPolicy rather than two flat rates.
  // The authed actor also tells us the caller's own level, to highlight.
  // (getTreasury's makerFeeBps/takerFeeBps remain the L0 base — the fallback
  // if the policy query is unavailable.)
  let pol = null;
  if (a?.getAccessPolicy) {
    try { pol = await a.getAccessPolicy(); } catch (e) { console.warn("getAccessPolicy:", e); }
  }
  const body = document.getElementById("treasury-fee-ladder-body");
  if (!pol || !body) {
    // Base rates only (both Nats are outside MONEY_KEYS → raw passthrough).
    set("kpi-tr-feerate", `${Number(treasury.takerFeeBps || 0)} / ${Number(treasury.makerFeeBps || 0)} bps`);
    return;
  }
  const bps = (tenth) => (Number(tenth) / 10).toLocaleString(undefined, { maximumFractionDigits: 1 });
  const bars = pol.levelThresholdsUsd.map((v) => Number(v) / 1e8);   // effective (scaled) W bars, L1..L4
  const fmtBar = (v) => "$" + v.toLocaleString(undefined, { maximumFractionDigits: 0 });
  const ACCESS = [
    "0 — shed first under load",
    "1 — elevated",
    "1 — elevated",
    "2 — highest",
    "2 + quote shield",
  ];
  const myLvl = appState.isAuthenticated ? Number(pol.myLevel) : -1;
  body.innerHTML = pol.feeTenthBps.map((pair, i) => {
    const reqTxt = i === 0
      ? "join (first deposit)"
      : "≥ " + fmtBar(bars[i - 1]) + (i === 4 ? " + quote uptime ≥ 50%" : "");
    return `<tr class="lb-row${i === myLvl ? " lb-me" : ""}">
      <td><span class="tier-badge tier-l${i}">L${i}</span>${i === myLvl ? " · you" : ""}</td>
      <td>${reqTxt}</td>
      <td class="lb-num">${bps(pair[0])} bps</td>
      <td class="lb-num">${bps(pair[1])} bps</td>
      <td>${ACCESS[i]}</td>
    </tr>`;
  }).join("");
  // KPI: the whole range the ladder spans (taker L0→L4 / maker L0→L4).
  const lo = pol.feeTenthBps[0], hi = pol.feeTenthBps[pol.feeTenthBps.length - 1];
  set("kpi-tr-feerate", `${bps(lo[1])}→${bps(hi[1])} / ${bps(lo[0])}→${bps(hi[0])} bps`);
  const note = document.getElementById("treasury-fee-scale-note");
  if (note) {
    note.textContent = `Volume bars shown at today's scale — `
      + `${(Number(pol.scaleBps) / 100).toLocaleString(undefined, { maximumFractionDigits: 2 })}% of full — `
      + `they grow with exchange-wide 30-day volume, so early contributors reach levels sooner.`;
  }
}

// ── Stats: Event Log pane ──
// Rolling log of notable exchange events (oracle / AMM / swap / liquidation),
// newest first, severity-coloured. Reads the backend's public getRecentEvents.
let eventsAll = [];          // full (capped) log, newest-first
let eventsPage = 0;          // 0 = newest page
const EVENTS_PER_PAGE = 25;

async function renderStatsEvents() {
  const a = appState.publicActor || appState.actor;
  const el = document.getElementById("stats-events-list");
  if (!a || !a.getRecentEvents || !el) return;
  setupEventsPager();
  try { eventsAll = await a.getRecentEvents(0); } catch (e) { return; }  // 0 = all retained
  renderEventsPage();
}

function renderEventsPage() {
  const el = document.getElementById("stats-events-list");
  if (!el) return;
  const total = eventsAll.length;
  if (!total) { el.innerHTML = '<div class="stats-empty">No events yet</div>'; updateEventsPager(0); return; }
  const pages = Math.max(1, Math.ceil(total / EVENTS_PER_PAGE));
  eventsPage = Math.min(Math.max(0, eventsPage), pages - 1);
  const start = eventsPage * EVENTS_PER_PAGE;
  const slice = eventsAll.slice(start, start + EVENTS_PER_PAGE);
  const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  el.innerHTML = slice.map((ev) => {
    const sev = ["info", "warn", "error"].includes(ev.severity) ? ev.severity : "info";
    return `<div class="event-row event-${sev}">`
      + `<span class="event-dot"></span>`
      + `<span class="event-time">${fmtAgo(ev.ts)}</span>`
      + `<span class="event-cat">${esc(ev.category)}</span>`
      + `<span class="event-msg">${esc(ev.message)}</span>`
      + `</div>`;
  }).join("");
  updateEventsPager(pages);
}

function updateEventsPager(pages) {
  const label = document.getElementById("events-page-label");
  const prev = document.getElementById("events-prev");
  const next = document.getElementById("events-next");
  const bar = document.getElementById("events-pager");
  if (bar) bar.style.display = pages > 1 ? "" : "none";
  if (label) label.textContent = pages ? `Page ${eventsPage + 1} of ${pages} · ${eventsAll.length} events` : "";
  if (prev) prev.disabled = eventsPage <= 0;
  if (next) next.disabled = eventsPage >= pages - 1;
}

// Wired once (idempotent via a flag) — newer = toward page 0, older = higher page.
function setupEventsPager() {
  if (setupEventsPager._wired) return;
  setupEventsPager._wired = true;
  document.getElementById("events-prev")?.addEventListener("click", () => { if (eventsPage > 0) { eventsPage--; renderEventsPage(); } });
  document.getElementById("events-next")?.addEventListener("click", () => { eventsPage++; renderEventsPage(); });
}

// ── Canister health: out-of-fuel banner + Stats→Canister pane ──
// The exchange is one IC canister paying for its own compute from a cycle
// balance. If it empties, the canister freezes — the heartbeat stops, so no
// trading or oracle refresh — but it still answers queries. We poll its
// self-reported balance + heartbeat liveness on a slow cadence (cycles drain
// slowly) and surface trouble app-wide via #fuel-banner, plus detailed KPIs
// on the Canister sub-tab. Anyone can refuel it — no controller access needed.
let canisterInfoTimer = null;
let lastCanisterInfo = null;

function fuelState(info) {
  const cyclesT = Number(info.cycles) / 1e12;                      // total balance → trillions
  // A canister FREEZES — halting every update while still serving queries —
  // when its balance reaches the freezing limit, which scales with stored data
  // (≈1.5T here). So the total balance alone CANNOT tell a freeze apart from a
  // healthy stall; what matters is the LIQUID (spendable) headroom =
  // balance − freezing limit. The canister reports the limit (cached from
  // canister_status); it's 0 until first known, so fall back to treating the
  // whole balance as liquid in that brief window.
  const freezingLimitT = Number(info.freezingLimitCycles ?? 0) / 1e12;
  const liquidT = freezingLimitT > 0 ? Math.max(0, cyclesT - freezingLimitT) : cyclesT;
  const ageSec  = Number(info.nowNs - info.lastHeartbeatNs) / 1e9; // canister clock — no client skew
  const everBeat = Number(info.lastHeartbeatNs) > 0;
  const paused  = info.timersPaused;
  // Frozen = heartbeat stalled while NOT deliberately paused. The heartbeat
  // fires every IC round (~1s), so a 45s gap is ~40 missed beats — unambiguous.
  const frozen   = everBeat && !paused && ageSec > 45;
  // On a cloud engine the engine holds the cycles balance and pays for
  // operation, so the canister's own cycles read ~0 — never flag low/empty
  // cycles there (it'd be a false alarm). Memory pressure is still real.
  // Thresholds are on LIQUID headroom, not total balance: critical ≈ no
  // spendable cycles (frozen, or about to), low = top-up advised. Liquid-based
  // so the warning can fire BEFORE the freeze — a total-balance check never
  // could, since the canister freezes while its balance still reads >1T.
  const critical = !CLOUD_ENGINE && liquidT < 0.25;
  const low      = !CLOUD_ENGINE && liquidT < 5;
  // Burn rate + time-to-freeze. burnPerDay is the canister's MEASURED total
  // burn (storage + compute); time-to-freeze = liquid headroom ÷ burn rate.
  // Infinity until a rate is measured (≈2 min after boot) or when nothing
  // drains. timeWarn fires when the predicted freeze is within the window —
  // this is what surfaces "runs out in ~23h" before the balance looks alarming.
  const burnPerDay     = Number(info.burnPerDay ?? 0);
  const idleBurnPerDay = Number(info.idleBurnPerDay ?? 0);
  const liquidCycles   = liquidT * 1e12;
  const secsToFreeze   = burnPerDay > 0 ? (liquidCycles / burnPerDay) * 86400 : Infinity;
  const TIME_WARN_SEC  = 72 * 3600;   // warn ~3 days out
  const timeWarn       = !CLOUD_ENGINE && Number.isFinite(secsToFreeze) && secsToFreeze < TIME_WARN_SEC;
  // Wasm-memory pressure. A canister past its wasm_memory_limit still serves
  // queries but REJECTS every update (IC0539) — from out here that looks
  // identical to an out-of-cycles freeze (heartbeat stalls either way), so a
  // stall must NOT be blamed on cycles without checking memory first. That
  // exact misdiagnosis happened on 2026-06-10 when the canister bricked at
  // its 3 GiB limit and this banner said "out of compute fuel".
  const memBytes = Number(info.memorySizeBytes ?? 0);
  const memLimit = Number(info.wasmMemoryLimitBytes ?? 0);
  const memFrac  = memLimit > 0 ? memBytes / memLimit : 0;
  const memFull  = memLimit > 0 && memFrac >= 0.98;  // updates rejected (or imminently)
  const memHigh  = memLimit > 0 && memFrac >= 0.85;  // reclaim / raise limit soon
  // Attribute trouble to its MEASURED cause; an honest "unknown" beats a
  // confident wrong remedy. No liquid cycles ⇒ a fuel freeze (a top-up revives
  // it). A stalled heartbeat WITH healthy liquid + memory ⇒ a code/replica/
  // upgrade issue a top-up would NOT fix. The liquid headroom is what tells
  // them apart — a frozen canister still shows a multi-T balance (= its
  // freezing limit), which is exactly what used to be misread as "healthy".
  const cause = (frozen || memFull || critical)
    ? (memFull ? "memory" : critical ? "cycles" : "unknown")
    : null;
  return { cyclesT, freezingLimitT, liquidT, ageSec, paused, frozen, critical, low,
           burnPerDay, idleBurnPerDay, secsToFreeze, timeWarn,
           memBytes, memLimit, memFrac, memFull, memHigh, cause,
           dead: frozen || critical || memFull };
}

// Human "time remaining" — coarse, single unit + a second for context near
// the boundary (e.g. "23 hours", "2 days 4 hr", "3 weeks"). Infinity → "—".
function fmtDuration(sec) {
  if (!Number.isFinite(sec)) return "—";
  if (sec < 90) return `${Math.max(0, Math.round(sec))} sec`;
  const m = sec / 60;
  if (m < 90) return `${Math.round(m)} min`;
  const h = sec / 3600;
  if (h < 48) {
    const hh = Math.floor(h), mm = Math.round((h - hh) * 60);
    // Compact form keeps the "Time to Freeze" KPI on one line: "40h 11m"
    // when minutes matter, "40 hours" when they don't.
    return mm >= 5 ? `${hh}h ${mm}m` : `${hh} hours`;
  }
  const d = sec / 86400;
  if (d < 14) {
    const dd = Math.floor(d), hh = Math.round((d - dd) * 24);
    // Compact hours so it stays on one line: "2 days 15h" (not "2 days 15 hr").
    return hh >= 1 ? `${dd} days ${hh}h` : `${dd} days`;
  }
  if (d < 60) return `${Math.round(d / 7)} weeks`;
  return `${Math.round(d / 30)} months`;
}

function fmtCycles(nat) {
  const t = Number(nat) / 1e12;
  if (t >= 1) return t.toFixed(t >= 100 ? 0 : 1) + "T";
  const b = Number(nat) / 1e9;
  if (b >= 1) return b.toFixed(0) + "B";
  return (Number(nat) / 1e6).toFixed(0) + "M";
}

function fmtBytes(n) {
  const gib = n / 1073741824;
  if (gib >= 1) return gib.toFixed(2) + " GiB";
  const mib = n / 1048576;
  if (mib >= 1) return mib.toFixed(0) + " MiB";
  return Math.round(n / 1024) + " KiB";
}

function fmtCount(n) {
  if (n >= 1e6) return (n / 1e6).toFixed(1) + "M";
  if (n >= 1e3) return (n / 1e3).toFixed(1) + "k";
  return String(n);
}

function fmtAgeSec(sec) {
  if (sec < 2) return "just now";
  if (sec < 60) return `${Math.floor(sec)}s ago`;
  const m = Math.floor(sec / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m ago`;
}

// Keep --chrome-h equal to the rendered height of #top-chrome (header + fuel
// banner when visible). Viewport-sized layouts (markets grid, intelli fill,
// swap centring, docs sidebar) subtract the variable, so a banner of ANY
// height expands the chrome without pushing page content off-screen. Called
// explicitly by the banner renderers (deterministic, works even when render
// frames are throttled) and by a ResizeObserver for wrap/viewport changes.
function updateChromeHeight() {
  const el = document.getElementById("top-chrome");
  if (el) document.documentElement.style.setProperty("--chrome-h", el.offsetHeight + "px");
}

// Session-scoped banner dismissal: the ✕ hides a status banner until the
// page reloads OR the banner's STATE changes — the signature encodes the
// tier/cause, so an escalation (info → warn → critical, or a new market
// alarming) always resurfaces even while dismissed.
function applyBannerDismiss(el, key, sig) {
  try {
    if (sessionStorage.getItem(key) === sig) { el.style.display = "none"; return true; }
  } catch { /* private mode etc. — banner just isn't dismissible */ }
  const b = document.createElement("button");
  b.className = "banner-dismiss";
  b.title = "Hide this notice (returns if the situation changes, or on next visit)";
  b.textContent = "✕";
  b.addEventListener("click", () => {
    try { sessionStorage.setItem(key, sig); } catch {}
    el.style.display = "none";
    updateChromeHeight();
  });
  el.appendChild(b);
  return false;
}

// ── Launch notice ────────────────────────────────────────────────
// The play-mode story banner. Shown ONLY in the #play posture (the public
// competition), never in #dev or #production. Persistently dismissible: the
// ✕ writes a localStorage flag so a returning visitor isn't nagged (unlike
// the status banners, which resurface each session). Keyed by a version so
// the notice can be re-shown if the story changes materially.
const LAUNCH_NOTICE_KEY = "mdx.launchNoticeHidden.v1";
function renderLaunchBanner() {
  const el = document.getElementById("launch-banner");
  if (!el) return;
  let dismissed = false;
  try { dismissed = localStorage.getItem(LAUNCH_NOTICE_KEY) === "1"; } catch {}
  if (appState.deployMode !== "play" || dismissed) {
    el.style.display = "none";
    updateChromeHeight();
    return;
  }
  el.innerHTML =
    `<span class="launch-mark">✦</span>` +
    `<strong>You're early.</strong> MULTI/DEX was written entirely by AI, runs 100% on-chain, ` +
    `and will be owned by the world. It's in <strong>play mode</strong> — trade dummy assets, climb ` +
    `the leaderboard, and help decide when it's ready for the NNS. ` +
    `<a class="launch-more" href="#docs/launch">Read the story →</a>`;
  const b = document.createElement("button");
  b.className = "banner-dismiss";
  b.title = "Hide this notice";
  b.textContent = "✕";
  b.addEventListener("click", () => {
    try { localStorage.setItem(LAUNCH_NOTICE_KEY, "1"); } catch {}
    el.style.display = "none";
    updateChromeHeight();
  });
  el.appendChild(b);
  el.style.display = "block";
  updateChromeHeight();
}

// Resolve the deployment posture once (public query) and (re)render the
// launch notice. Safe pre-auth — getDeployMode is a query the publicActor
// can make. Idempotent; call whenever an actor becomes available.
async function resolveDeployModeAndBanner() {
  try {
    const a = appState.publicActor || appState.actor;
    if (a?.getDeployMode) { appState.deployMode = await a.getDeployMode(); }
  } catch { /* leave deployMode unset → banner stays hidden */ }
  renderLaunchBanner();
}

function updateFuelBanner(info) {
  const el = document.getElementById("fuel-banner");
  if (!el) return;
  const s = fuelState(info);
  let sig = "";   // dismissal signature — one per banner state (see applyBannerDismiss)
  if (s.dead) {
    sig = `critical:${s.cause || "stall"}`;
    el.className = "fuel-banner critical";
    if (s.cause === "memory") {
      // Sending cycles does NOT fix a memory stall — say so explicitly, or
      // helpful strangers burn cycles on the wrong remedy.
      el.innerHTML =
        `<strong>⛔ MULTI/DEX has hit its memory limit ` +
        `(${fmtBytes(s.memBytes)} of ${fmtBytes(s.memLimit)}) — trading is halted.</strong> ` +
        `The canister still answers queries but rejects every state-changing call. ` +
        `A controller must raise its wasm-memory limit or reclaim storage; ` +
        `sending cycles will <em>not</em> help.`;
    } else if (s.cause === "cycles") {
      // A frozen canister can still show a multi-T balance (= its freezing
      // limit), so spell out WHY it's halted — otherwise this reads as "plenty
      // of cycles, must be something else", the exact misread we're fixing.
      const note = s.freezingLimitT > 0
        ? `Its cycle balance (≈${s.cyclesT.toFixed(1)}T) has fallen to the freezing threshold ` +
          `(≈${s.freezingLimitT.toFixed(1)}T) — the level, set by how much data it stores, below ` +
          `which the IC freezes the canister and rejects every update. `
        : `It has run out of compute fuel. `;
      el.innerHTML =
        `<strong>⛔ MULTI/DEX is out of fuel — trading is halted.</strong> ` + note +
        `Anyone can revive the exchange by sending cycles to ` +
        `<code class="fuel-banner-id">${info.canisterId}</code>`;
    } else {
      el.innerHTML =
        `<strong>⛔ MULTI/DEX has stalled — trading is halted.</strong> ` +
        `The heartbeat last fired ${fmtAgeSec(s.ageSec)}, but its spendable cycles ` +
        `(≈${s.liquidT.toFixed(1)}T above the freezing threshold) and memory ` +
        `(${Math.round(s.memFrac * 100)}% of limit) both look fine — so this is likely a ` +
        `replica or upgrade issue rather than fuel.`;
    }
    el.style.display = "";
    applyBannerDismiss(el, "dismiss.fuel", sig);
  } else if (s.timeWarn || s.low || s.memHigh) {
    // Self-funding check: with the fuel route wired, auto-fuel armed and a
    // non-dust treasury, the exchange converts its OWN trading fees into
    // cycles before the freeze — begging strangers for cycles would be
    // wrong twice (unnecessary, and it advertises a fragility we don't
    // have). The fuel warnings downgrade to a calm informational note; the
    // memory warning is unrelated to cycles and keeps its alarm. If the
    // treasury drains to dust the real warning returns by itself — and the
    // "dead" tier above is untouched (a freeze despite auto-fuel means the
    // loop failed; donated cycles ARE the right ask then).
    const treasuryUsd = Number(info.treasuryUsdE8s ?? 0) / 1e8;
    const treasuryIcp = Number(info.treasuryIcpE8s ?? 0) / 1e8;
    const selfFunding = info.autoFuelEnabled && info.fuelRouteWired
      && (treasuryUsd >= 50 || treasuryIcp >= 1);
    let show = true;
    if (s.memHigh) {
      sig = "warn:mem";
      el.className = "fuel-banner warn";
      el.innerHTML =
        `<strong>⚠ MULTI/DEX memory is at ${Math.round(s.memFrac * 100)}% of its ` +
        `${fmtBytes(s.memLimit)} limit.</strong> ` +
        `State-changing calls halt at 100% — reclaim storage or raise the limit before then.`;
    } else if (selfFunding) {
      // With auto-fuel armed the freeze this tier counts down to will never
      // arrive — tickAutoFuel (main.mo) converts treasury → cycles once liquid
      // headroom dips below max(2T, one day of burn). A standing "trending
      // down" note is therefore noise; surface it only SHORTLY BEFORE the
      // top-up (< ~1h out), as an explainer for the conversion that's coming.
      const triggerCycles = Math.max(2e12, s.burnPerDay);   // mirrors AUTO_FUEL_HEADROOM_MIN / burn floor
      const secsToTopup = s.burnPerDay > 0
        ? Math.max(0, (s.liquidT * 1e12 - triggerCycles) / s.burnPerDay * 86400)
        : Infinity;
      if (secsToTopup > 3600) {
        show = false;   // healthy self-funding state — nothing worth a banner
      } else {
        // Deliberately no treasury figures here: quoting the whole chest read
        // as "it will convert ALL of that" — it only draws what the refill
        // needs.
        sig = "info:topup";
        el.className = "fuel-banner info";
        el.innerHTML =
          `<strong>ℹ Auto-fuel top-up ${secsToTopup <= 0 ? "due" : `in ~${fmtDuration(secsToTopup)}`}</strong> — ` +
          `spendable fuel is nearing the refuel floor (≈${fmtCycles(triggerCycles)}, one day of burn). ` +
          `The exchange will draw on its own treasury to create new cycles automatically. ` +
          `No action needed.`;
      }
    } else if (s.timeWarn) {
      // The actionable one: a countdown to the freeze at the measured burn rate.
      sig = "warn:freeze";
      el.className = "fuel-banner warn";
      el.innerHTML =
        `<strong>⚠ MULTI/DEX will run out of fuel in ~${fmtDuration(s.secsToFreeze)}.</strong> ` +
        `At the current burn rate (≈${fmtCycles(s.burnPerDay)}/day) its spendable cycles ` +
        `(≈${s.liquidT.toFixed(1)}T) will reach the freezing threshold and trading will halt. ` +
        `The self-funding treasury is empty, so a top-up must come from outside — send cycles to ` +
        `<code class="fuel-banner-id">${info.canisterId}</code>`;
    } else {
      sig = "warn:low";
      el.className = "fuel-banner warn";
      el.innerHTML =
        `<strong>⚠ MULTI/DEX is low on spendable fuel (≈${s.liquidT.toFixed(1)}T above its ` +
        `freezing threshold).</strong> It freezes and halts trading when that reaches 0 — ` +
        `top it up by sending cycles to ` +
        `<code class="fuel-banner-id">${info.canisterId}</code>`;
    }
    if (show) {
      el.style.display = "";
      applyBannerDismiss(el, "dismiss.fuel", sig);
    } else {
      el.style.display = "none";
    }
  } else {
    el.style.display = "none";
  }
  updateChromeHeight();
}

// Oracle divergence banner — the ops alarm the backend raises when a HEALTHY
// primary price sits >300bps from the independent XRC anchor (a possible
// source poisoning: the jump breaker bounds each tick, but a slow walk stays
// inside it). Alarm-only by design (docs/oracle-xrc-fallback-design.md §3.3):
// trading continues, the reader is told to cross-check. Backend clears an
// alarm on the next in-band accept; we ALSO age alarms out after 10 minutes
// so a market whose feed went quiet doesn't pin a stale banner forever.
const ORACLE_ALARM_MAX_AGE_S = 600;
function updateOracleBanner(info) {
  const el = document.getElementById("oracle-banner");
  if (!el) return;
  const nowNs = Number(info.nowNs ?? 0);
  const live = (info.oracleDivergence || [])
    .map(([tok, bps, atNs]) => ({ tok, bps: Number(bps), ageS: Math.max(0, (nowNs - Number(atNs)) / 1e9) }))
    .filter((a) => a.ageS <= ORACLE_ALARM_MAX_AGE_S);
  if (!live.length) {
    el.style.display = "none";
    updateChromeHeight();
    return;
  }
  const parts = live
    .sort((a, b) => b.bps - a.bps)
    .map((a) => `<strong>${a.tok}</strong> is ${(a.bps / 100).toFixed(1)}% from the anchor (${fmtAgeSec(a.ageS)})`);
  el.className = "oracle-banner warn";
  el.innerHTML =
    `<strong>⚠ Oracle divergence.</strong> The primary price feed disagrees with the ` +
    `independent on-chain anchor (XRC): ${parts.join(" · ")}. ` +
    `Marks and liquidations follow the primary feed — cross-check prices before trading.`;
  el.style.display = "";
  // Dismissal signature = the SET of alarming markets, so a fresh market
  // joining the alarm resurfaces the banner even if it was dismissed.
  applyBannerDismiss(el, "dismiss.oracle", live.map((a) => a.tok).sort().join(","));
  updateChromeHeight();
}

function renderStatsCanister(info) {
  if (!info) return;
  const s = fuelState(info);
  const set = (id, txt, cls) => {
    const el = document.getElementById(id);
    if (!el) return;
    el.textContent = txt;
    if (cls !== undefined) el.className = "kpi-value " + cls;
  };
  // Backend build vs the bundle running this page — a mixed deploy (frontend
  // and backend ship separately) is normal but worth being able to SEE.
  {
    const raw = Array.isArray(info.appVersion) ? info.appVersion[0] : info.appVersion;
    const bv = String(raw || "—");
    const match = APP_VERSION && bv === APP_VERSION;
    set("kpi-can-version", "v" + bv.replace(/\.0$/, ""), match ? "health-ok" : "");
    const vsub = document.getElementById("kpi-can-version-sub");
    if (vsub) vsub.textContent = APP_VERSION
      ? (match ? "matches this page's build" : `this page runs v${APP_VERSION.replace(/\.0$/, "")}`)
      : "release this wasm was built from";
  }
  set("kpi-can-cycles", fmtCycles(info.cycles), s.critical ? "health-bad" : s.low ? "health-warn" : "health-ok");
  const csub = document.getElementById("kpi-can-cycles-sub");
  // Auto-fuel state rides along: "armed" = the treasury→cycles loop will
  // self-top-up when spendable headroom runs low (route wired + switch on).
  let fuelNote = (info.autoFuelEnabled && info.fuelRouteWired)
    ? (Number(info.fuelLifetimeCycles) > 0
        ? ` · auto-fuel armed (${fmtCycles(Number(info.fuelLifetimeCycles))} self-minted)`
        : " · auto-fuel armed")
    : " · auto-fuel off";
  // #47.2: the stage-2 saga latch — ICP already sent to the CMC, notify not
  // yet acknowledged. Normally clears within a retry window; one that AGES
  // is the ops alarm the backend also raises in the event log after 1h.
  {
    const pn = Array.isArray(info.fuelPendingNotify) ? info.fuelPendingNotify[0] : info.fuelPendingNotify;
    if (pn) {
      const ageS = Math.max(0, (Number(info.nowNs) - Number(pn.sinceNs)) / 1e9);
      fuelNote += ` · ⚠ top-up awaiting CMC notify (block ${pn.blockIndex}, ${fmtAgeSec(ageS)})`;
    }
  }
  if (csub) csub.textContent = CLOUD_ENGINE
    ? "compute paid by cloud engine"
    // Show SPENDABLE headroom (above the freezing floor) — the figure that
    // actually predicts a freeze — rather than the total, which stays >1T even
    // when frozen. Falls back to the raw total until the floor is known.
    : (s.freezingLimitT > 0
        ? `≈ ${s.liquidT.toFixed(1)}T spendable · ${s.freezingLimitT.toFixed(1)}T freezing floor${fuelNote}`
        : (s.cyclesT >= 1 ? `≈ ${s.cyclesT.toFixed(1)}T remaining` : `${Math.round(s.cyclesT * 1000)}B remaining`) + fuelNote);

  // Burn rate (measured total) with the storage/compute split, and the
  // resulting time-to-freeze + the watermark balance it freezes at. On a cloud
  // engine the engine pays compute, so there's no self-measured burn.
  const bsub = document.getElementById("kpi-can-burn-sub");
  const tsub = document.getElementById("kpi-can-ttf-sub");
  if (CLOUD_ENGINE) {
    set("kpi-can-burn", "n/a", undefined);
    if (bsub) bsub.textContent = "compute paid by cloud engine";
    set("kpi-can-ttf", "n/a", "health-ok");
    if (tsub) tsub.textContent = "compute paid by cloud engine";
  } else {
    set("kpi-can-burn", s.burnPerDay > 0 ? `${fmtCycles(s.burnPerDay)}/day` : "measuring…", undefined);
    if (bsub) bsub.textContent = s.burnPerDay > 0
      ? `storage ${fmtCycles(s.idleBurnPerDay)} + compute ${fmtCycles(Math.max(0, s.burnPerDay - s.idleBurnPerDay))} per day`
      : "sampling the balance over time…";
    const ttf = s.secsToFreeze, finite = Number.isFinite(ttf);
    set("kpi-can-ttf", s.frozen ? "frozen" : finite ? `~${fmtDuration(ttf)}` : "—",
        (s.frozen || (finite && ttf < 24 * 3600)) ? "health-bad"
        : (finite && ttf < 72 * 3600) ? "health-warn" : "health-ok");
    if (tsub) tsub.textContent = s.freezingLimitT > 0
      ? `freezes at ≈${s.freezingLimitT.toFixed(1)}T balance · ${s.cyclesT.toFixed(1)}T now`
      : "at current burn rate";
  }

  // Memory = allocated wasm memory vs limit. Under enhanced orthogonal
  // persistence this NEVER shrinks — freed heap is reused, not returned —
  // so it's the allocation high-water mark, and the number that halts
  // updates when it reaches the limit (IC0539). The healthy signal is a
  // plateau, not a fall.
  // Memory: USED as the headline; max + breakdown in the sub (consistent with
  // the archive tile). The DEX keeps all state in wasm memory under EOP — there
  // is no separate durable Region — so its memory is all "wasm".
  set("kpi-can-memory", fmtBytes(s.memBytes),
      s.memFull ? "health-bad" : s.memHigh ? "health-warn" : "health-ok");
  const msub = document.getElementById("kpi-can-memory-sub");
  // If the on-canister lowmemory() threshold hook has fired, say so — it is
  // the earliest hard signal that the wasm ceiling is approaching.
  const lowMemNs = Number(info.lowMemoryAtNs ?? 0);
  const lowMemNote = lowMemNs > 0
    ? ` · low-memory hook fired ${fmtAgeSec(Math.max(0, (Number(info.nowNs) - lowMemNs) / 1e9))}`
    : "";
  if (msub) msub.textContent = (s.memLimit > 0
    ? `max ${fmtBytes(s.memLimit)} · ${fmtBytes(s.memBytes)} wasm`
    : `${fmtBytes(s.memBytes)} wasm`) + lowMemNote;

  // Heap = live data actually in use right now (post-GC). The gap between
  // Heap and Memory is reusable free space — a low Heap under a high Memory
  // means growth has stopped, not that trouble is near. Colour tracks live
  // data against the LIMIT: live data near the limit can't be fixed by
  // GC or reaping, only by a higher limit or less retained state.
  const heapBytes = Number(info.heapLiveBytes ?? 0);
  const heapFrac  = s.memLimit > 0 ? heapBytes / s.memLimit : 0;
  set("kpi-can-heap", fmtBytes(heapBytes),
      heapFrac >= 0.95 ? "health-bad" : heapFrac >= 0.85 ? "health-warn" : "health-ok");
  const hsub = document.getElementById("kpi-can-heap-sub");
  if (hsub) hsub.textContent = s.memBytes > 0
    ? `${Math.round((heapBytes / s.memBytes) * 100)}% of allocated memory`
    : "live data after GC";

  const status = s.frozen ? "Frozen" : s.memFull ? "Rejecting updates" : s.paused ? "Paused" : "Live";
  set("kpi-can-status", status, (s.frozen || s.memFull) ? "health-bad" : s.paused ? "health-warn" : "health-ok");
  const ssub = document.getElementById("kpi-can-status-sub");
  if (ssub) ssub.textContent = s.frozen
    ? (s.cause === "memory" ? "heartbeat stalled — memory limit reached"
       : s.cause === "cycles" ? "heartbeat stalled — out of fuel"
       : "heartbeat stalled — cause unknown")
    : s.memFull ? "memory at limit — updates rejected"
    : s.paused ? "maintenance paused" : "heartbeat firing every round";

  set("kpi-can-heartbeat", s.paused ? "paused" : fmtAgeSec(s.ageSec), undefined);

  set("kpi-can-storage", `${fmtCount(Number(info.ordersRetained ?? 0))} orders`, undefined);
  const stsub = document.getElementById("kpi-can-storage-sub");
  // History pipeline health rides along here: archived = durably in the
  // sidecar; a persistently growing "queued" means shipping has stalled.
  const archived = Number(info.archivedEvents ?? 0);
  const queued   = Number(info.journalUnshipped ?? 0);
  if (stsub) stsub.textContent =
    `${fmtCount(Number(info.tradesRetained ?? 0))} trades · ` +
    `${fmtCount(Number(info.usersRegistered ?? 0))} users · ` +
    `${fmtCount(archived)} events archived` +
    (queued > 0 ? ` (+${fmtCount(queued)} queued)` : "");

  const idEl = document.getElementById("canister-id-value");
  if (idEl) idEl.textContent = info.canisterId;
}

// ── History archive sidecar stats (Stats → Canister) ─────────────────
// Queried with an ANONYMOUS agent (the archive's stats() is a public query and
// the Stats page is public — getArchiveActor uses the signed-in agent and is
// gated on auth, so it can't serve this). Cached per archive id.
let _pubArchiveActor = null, _pubArchiveActorId = null;
async function getPublicArchiveActor(archiveId) {
  if (!archiveId || !HttpAgent || !Actor) return null;
  if (_pubArchiveActor && _pubArchiveActorId === archiveId) return _pubArchiveActor;
  try {
    let canisterEnv;
    try { const m = await import("@icp-sdk/core/agent/canister-env"); canisterEnv = m.safeGetCanisterEnv?.(); } catch {}
    const agent = await HttpAgent.create({ host: window.location.origin, rootKey: canisterEnv?.IC_ROOT_KEY });
    _pubArchiveActor = wrapActor(Actor.createActor(getArchiveIdlFactory(), { agent, canisterId: archiveId }));
    _pubArchiveActorId = archiveId;
    return _pubArchiveActor;
  } catch (_) { return null; }
}

// Populate the Stats → "History Archive" section from the sidecar's stats().
// The buffered count comes from main (always available — it's the answer when
// the archive is down); memory / heap / cycles / events come from the archive
// itself, which is unreachable when it's out of cycles.
async function renderArchiveStats(info) {
  const sec = document.getElementById("stats-archive-section");
  if (!sec || !info) return;
  const archiveId = (info.archiveCanisterId && info.archiveCanisterId.length) ? info.archiveCanisterId[0] : null;
  if (!archiveId) { sec.style.display = "none"; return; }   // sidecar not spawned yet
  sec.style.display = "";
  // The chain table renders independently of the ACTIVE archive's health —
  // when the tip is frozen/unreachable is exactly when you need the list.
  renderArchiveChain();
  const set = (id, txt, cls) => {
    const el = document.getElementById(id);
    if (!el) return;
    el.textContent = txt;
    if (cls !== undefined) el.className = "kpi-value " + cls;
  };
  const sub = (id, txt) => { const el = document.getElementById(id); if (el) el.textContent = txt; };

  const idEl = document.getElementById("archive-id-value");
  if (idEl) idEl.textContent = archiveId;

  const queued = Number(info.journalUnshipped ?? 0);
  // A few thousand is normal churn (ships every 10s); a large backlog means the
  // archive can't keep up — usually it's out of cycles — so watch then critical.
  set("kpi-arch-buffered", fmtCount(queued) + (queued === 1 ? " event" : " events"),
      queued >= 250000 ? "health-bad" : queued >= 25000 ? "health-warn" : "health-ok");
  sub("kpi-arch-buffered-sub", queued >= 25000 ? "shipping behind — top up the archive?"
      : queued > 0 ? "buffered, re-ships ~2k/10s" : "all shipped — up to date");

  const a = await getPublicArchiveActor(archiveId);
  let st = null;
  if (a) { try { st = await a.stats(); } catch (_) { st = null; } }
  if (!st) {
    // Out of cycles / unreachable — history is safe (buffered above), but the
    // archive can't be queried for its own footprint until it's refunded.
    set("kpi-arch-cycles", "unreachable", "health-bad");
    sub("kpi-arch-cycles-sub", "out of cycles? top up: scripts/topup_archive.sh");
    set("kpi-arch-memory", "—", ""); set("kpi-arch-heap", "—", ""); set("kpi-arch-events", "—", "");
    sub("kpi-arch-events-sub", `${fmtCount(Number(info.archivedEvents ?? 0))} acked by the DEX`);
    return;
  }
  const cyclesT = Number(st.cycles) / 1e12;
  set("kpi-arch-cycles", fmtCycles(st.cycles),
      CLOUD_ENGINE ? "" : (cyclesT < 5 ? "health-bad" : cyclesT < 20 ? "health-warn" : "health-ok"));
  sub("kpi-arch-cycles-sub", CLOUD_ENGINE ? "compute paid by cloud engine"
      : (cyclesT >= 1 ? `≈ ${cyclesT.toFixed(1)}T remaining` : `${Math.round(cyclesT * 1000)}B remaining`));

  // Memory: USED (wasm + durable Region) as the headline; max + breakdown in the
  // sub — same shape as the DEX tile. "max" is the wasm-memory limit (reused
  // from the DEX's; the archive's own setting isn't query-readable without
  // controlling it). The durable Region is bounded by the much larger storage
  // cap, not this limit, so colour tracks the wasm part vs the limit.
  const wasm = Number(st.memorySizeBytes), durable = Number(st.bytes);
  const limit = Number(info.wasmMemoryLimitBytes ?? 0);
  const memFrac = limit > 0 ? wasm / limit : 0;
  set("kpi-arch-memory", fmtBytes(wasm + durable),
      memFrac >= 0.95 ? "health-bad" : memFrac >= 0.85 ? "health-warn" : "health-ok");
  sub("kpi-arch-memory-sub", limit > 0
      ? `max ${fmtBytes(limit)} · ${fmtBytes(wasm)} wasm + ${fmtBytes(durable)} durable`
      : `${fmtBytes(wasm)} wasm + ${fmtBytes(durable)} durable`);

  const heapB = Number(st.heapLiveBytes);
  const heapFrac = limit > 0 ? heapB / limit : 0;
  set("kpi-arch-heap", fmtBytes(heapB),
      heapFrac >= 0.95 ? "health-bad" : heapFrac >= 0.85 ? "health-warn" : "health-ok");
  sub("kpi-arch-heap-sub", wasm > 0 ? `${Math.round(heapB / wasm * 100)}% of allocated memory` : "live data");

  set("kpi-arch-events", fmtCount(Number(st.eventCount)), "");
  // Chain provenance rides along: sealed archives behind the active one
  // (Phase B) + where the tamper-evidence hash chain starts (Phase D).
  const sealed = Number(info.archivesSealed ?? 0);
  const chainFrom = (st.chainStartSeq && st.chainStartSeq.length) ? Number(st.chainStartSeq[0]) : null;
  sub("kpi-arch-events-sub",
    `${fmtCount(Number(st.users))} users · seq up to ${fmtCount(Number(st.nextSeq))}` +
    (sealed > 0 ? ` · +${sealed} sealed archive${sealed === 1 ? "" : "s"}` : "") +
    (chainFrom !== null ? ` · hash-chained from seq ${fmtCount(chainFrom)}` : ""));
}

// Archive chain table — EVERY canister carrying the ledger (sealed segments,
// the active tip, the pre-spawned successor), from getArchiveChain(). The
// fuel pass observes each ~5 min; "frozen" means the IC refuses it execution
// (balance below its own freezing limit), which breaks serving/verifying
// that segment's seq range until it's topped up.
async function renderArchiveChain() {
  const body = document.getElementById("archive-chain-body");
  if (!body) return;
  const a = appState.publicActor || appState.actor;
  if (!a?.getArchiveChain) return;
  let list = [];
  try { list = await a.getArchiveChain(); } catch (_) { return; }
  if (!list.length) {
    body.innerHTML = `<tr><td colspan="5" class="stats-empty">No archives spawned yet</td></tr>`;
    return;
  }
  const opt = (o) => (o && o.length ? o[0] : null);
  body.innerHTML = list.map((r) => {
    const cyc = opt(r.cycles), lim = opt(r.freezeLimitCycles), froz = opt(r.frozen);
    const f0 = opt(r.firstSeq), l0 = opt(r.lastSeq);
    const seqs = f0 === null ? "—"
      : `${fmtCount(Number(f0))} – ${l0 === null ? "growing" : fmtCount(Number(l0))}`;
    const state = froz === true
      ? `<span class="chain-badge chain-frozen">frozen</span>`
      : froz === false
        ? `<span class="chain-badge chain-ok">ok</span>`
        : `<span class="chain-badge">not yet observed</span>`;
    const fuel = cyc === null ? "—"
      : `${fmtCycles(cyc)}${lim !== null ? `<span class="chain-sub"> · freezes &lt; ${fmtCycles(lim)}</span>` : ""}`;
    return `<tr>`
      + `<td><span class="chain-role chain-role-${r.role}">${r.role}</span></td>`
      + `<td><code class="canister-id-value">${r.canisterId}</code></td>`
      + `<td>${seqs}</td>`
      + `<td>${fuel}</td>`
      + `<td>${state}</td>`
      + `</tr>`;
  }).join("");
}

// Consecutive health-poll failures (reset on success). One failed poll is
// noise; three (~1 min) is an outage worth surfacing.
let canisterInfoFailures = 0;

async function refreshCanisterInfo() {
  const a = appState.publicActor || appState.actor;
  if (!a || !a.getCanisterInfo) return;
  try {
    const info = await a.getCanisterInfo();
    lastCanisterInfo = info;
    canisterInfoFailures = 0;
    updateFuelBanner(info);
    updateOracleBanner(info);
    renderStatsCanister(info);
    renderArchiveStats(info);   // async, fire-and-forget — must not block the main render
  } catch (e) {
    console.warn("getCanisterInfo failed:", e);
    canisterInfoFailures += 1;
    // A HARD-frozen canister rejects even QUERY calls (IC0207: "…is frozen /
    // out of cycles: please top up…"), so this health poll itself dies and
    // fuelState never gets fresh data — the banner would keep rendering a
    // stale "healthy" snapshot while the exchange is completely dark. The
    // ERROR is the diagnosis: classify it and report the truth.
    const msg = String(e?.message ?? e);
    const frozenOutOfCycles = /IC0207|is frozen|out of cycles|top up the canister/i.test(msg);
    if (frozenOutOfCycles) {
      updateFuelBannerUnreachable("cycles", msg);
    } else if (canisterInfoFailures >= 3) {
      updateFuelBannerUnreachable("network", msg);
    }
  }
}

// Banner for the states where the canister CAN'T report on itself — the poll
// error is the only evidence. cause="cycles": the IC refused the call because
// the canister is frozen below its freezing threshold (even reads rejected) —
// a top-up is the one and only fix. cause="network": can't reach the replica
// at all; whatever is on screen is stale.
async function updateFuelBannerUnreachable(cause, msg) {
  const el = document.getElementById("fuel-banner");
  if (!el) return;
  el.className = "fuel-banner critical";
  const cid = lastCanisterInfo?.canisterId || (await getCanisterId()) || "(canister id unavailable)";
  if (cause === "cycles") {
    const known = lastCanisterInfo
      ? ` Its freezing threshold was last measured at ≈${(Number(lastCanisterInfo.freezingLimitCycles) / 1e12).toFixed(1)}T cycles — the balance has fallen to (or below) that level.`
      : "";
    el.innerHTML =
      `<strong>⛔ MULTI/DEX is OUT OF CYCLES — the canister is frozen and completely unreachable.</strong> ` +
      `The Internet Computer is rejecting <em>every</em> call, including the read-only queries behind this page ` +
      `(reject IC0207), so all data shown is the last snapshot before the freeze.${known} ` +
      `Trading, deposits and withdrawals are halted until it is topped up — anyone can revive it by sending cycles to ` +
      `<code class="fuel-banner-id">${cid}</code>`;
  } else {
    el.innerHTML =
      `<strong>⛔ MULTI/DEX is unreachable.</strong> ` +
      `The exchange canister isn't answering (${canisterInfoFailures} consecutive health checks failed) and the ` +
      `error doesn't look like an out-of-cycles freeze — likely a network or replica issue. ` +
      `Data shown may be stale.`;
  }
  el.style.display = "";
  updateChromeHeight();
}

function startCanisterInfoPoll() {
  if (canisterInfoTimer) return;
  refreshCanisterInfo();
  // Slow cadence — cycles drain over hours; a stall shows within one tick.
  canisterInfoTimer = setInterval(refreshCanisterInfo, 20000);
}

// ── Stats sub-tabs ──
// Toggle between the "Overview" pane (KPIs / markets / pool detail /
// oracle / depth) and the "AMM P&L" pane (per-pool valuePerLP charts).
function setupStatsSubtabs() {
  // System inner tabs — hash-driven like the Account tabs (#system/<slug>),
  // so back/forward and deep links work. The click writes the hash; the
  // hashchange → activateTab → showStatsTab does the actual pane swap.
  document.querySelectorAll(".stats-subtab").forEach((btn) => {
    btn.addEventListener("click", () => {
      const tok = btn.dataset.statsTab;
      window.location.hash = "system/" + (STATS_TOKEN_TO_SLUG[tok] || tok);
    });
  });

  // Copy the canister ID (so it's easy to paste into a cycles top-up).
  const copyBtn = document.getElementById("canister-id-copy");
  if (copyBtn) {
    copyBtn.addEventListener("click", async () => {
      const id = lastCanisterInfo?.canisterId
        || document.getElementById("canister-id-value")?.textContent;
      if (!id || id === "—") return;
      try {
        await navigator.clipboard.writeText(id);
        copyBtn.textContent = "Copied!";
        setTimeout(() => { copyBtn.textContent = "Copy"; }, 1500);
      } catch { /* clipboard blocked (insecure context) — no-op */ }
    });
  }
  const archCopyBtn = document.getElementById("archive-id-copy");
  if (archCopyBtn) {
    archCopyBtn.addEventListener("click", async () => {
      const id = (lastCanisterInfo?.archiveCanisterId?.length ? lastCanisterInfo.archiveCanisterId[0] : null)
        || document.getElementById("archive-id-value")?.textContent;
      if (!id || id === "—") return;
      try {
        await navigator.clipboard.writeText(id);
        archCopyBtn.textContent = "Copied!";
        setTimeout(() => { archCopyBtn.textContent = "Copy"; }, 1500);
      } catch { /* clipboard blocked — no-op */ }
    });
  }
}

// Build a small inline-SVG line chart of valuePerLP over time. The
// breakeven (1.0) is drawn as a dashed reference; line is green
// above, red below. Designed for ~280×80 inside a card.
function buildPnlChart(snapshots, opts = {}) {
  const w = opts.width || 320;
  const h = opts.height || 88;
  const pad = 6;
  if (!snapshots || snapshots.length < 2) {
    return `<div class="pnl-empty">Building history… (need at least 2 snapshots)</div>`;
  }
  const xs = snapshots.map((s) => Number(s.timestamp));
  const ys = snapshots.map((s) => Number(s.valuePerLP));
  const minX = Math.min(...xs), maxX = Math.max(...xs);
  // Always include 1.0 (the breakeven) in the y-range so the dashed
  // reference line is visible even when the pool has only ever been
  // above (or below) it.
  const minY = Math.min(...ys, 1.0);
  const maxY = Math.max(...ys, 1.0);
  const xSpan = maxX - minX || 1;
  const ySpan = (maxY - minY) || 1;
  const xs2 = (x) => pad + ((x - minX) / xSpan) * (w - 2 * pad);
  const ys2 = (y) => h - pad - ((y - minY) / ySpan) * (h - 2 * pad);
  const path = snapshots
    .map((s, i) => `${i === 0 ? "M" : "L"}${xs2(Number(s.timestamp)).toFixed(1)},${ys2(Number(s.valuePerLP)).toFixed(1)}`)
    .join(" ");
  // Filled area below the line for visual weight, capped at the
  // breakeven if line is above (highlights "profit zone"); flipped
  // if line ends below.
  const areaPath = `${path} L${xs2(maxX).toFixed(1)},${(h - pad).toFixed(1)} L${xs2(minX).toFixed(1)},${(h - pad).toFixed(1)} Z`;
  const lastVal = ys[ys.length - 1];
  const cls = lastVal >= 1.0 ? "pos" : "neg";
  return `
    <svg class="pnl-chart ${cls}" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
      <path d="${areaPath}" class="pnl-area"/>
      <line x1="${pad}" y1="${ys2(1.0).toFixed(1)}" x2="${w - pad}" y2="${ys2(1.0).toFixed(1)}" class="pnl-breakeven"/>
      <path d="${path}" class="pnl-line"/>
    </svg>
  `;
}

// Single vault P&L card. The AMM is one bankroll across all markets,
// so there's exactly one equity curve — not three. Card shows:
//   - valuePerLP headline + pct change vs 1.00 baseline
//   - one chart (vault valuePerLP over time, breakeven at 1.00)
//   - asset-mix breakdown with horizontal stacked bar
//   - footer metrics: P&L $, total value, LP supply, tracked-time
function renderStatsVault({ vault, vaultHistory, insFund }) {
  // What the vault owes insurance stakers. Already DEDUCTED from NAV by the
  // backend, so it is shown as an explicit negative rather than silently
  // shrinking the value beside it.
  const owedToInsurance = Number(insFund?.pendingYieldUsd ?? 0);
  const container = document.getElementById("stats-pnl-list");
  if (!vault) {
    container.innerHTML = `<div class="stats-empty">Vault not initialised. Seed a pool with <code>seedAmmPool</code>.</div>`;
    return;
  }
  const lpSupply = Number(vault.lpSupply || 0);
  const totalValue = Number(vault.totalQuoteValue || 0);
  const valuePerLP = Number(vault.valuePerLP || 0);
  if (lpSupply <= 0) {
    container.innerHTML = `<div class="stats-empty">Vault has no LP yet. Seed via <code>seedAmmPool</code>.</div>`;
    return;
  }
  const baseline = 1.0;
  const pnlPct = (valuePerLP / baseline - 1) * 100;
  const pnlAbs = (valuePerLP - baseline) * lpSupply;
  const cls = pnlPct >= 0 ? "pos" : "neg";

  const chart = buildVaultPnlChart(vaultHistory);
  const earliest = vaultHistory.length > 0 ? Number(vaultHistory[0].timestamp) : 0;
  const ageMin = earliest ? Math.round((Date.now() * 1e6 - earliest) / 60_000_000_000) : 0;

  // Asset-mix breakdown: each component's quote-denominated weight.
  const b = vault.basket;
  const p = vault.prices;
  const mix = [
    { token: "BTC",    val: Number(b.btc)    * Number(p.btc), qty: Number(b.btc),    cls: "mix-btc"    },
    { token: "ETH",    val: Number(b.eth)    * Number(p.eth), qty: Number(b.eth),    cls: "mix-eth"    },
    { token: "SOL",    val: Number(b.sol)    * Number(p.sol), qty: Number(b.sol),    cls: "mix-sol"    },
    { token: "ICP",    val: Number(b.icp)    * Number(p.icp), qty: Number(b.icp),    cls: "mix-icp"    },
    { token: "ICPUSD", val: Number(b.icpusd),                  qty: Number(b.icpusd), cls: "mix-icpusd" },
  ];
  // LENT OUT — the vault is the margin system's lender, so part of its value
  // is not inventory at all but principal out on loan to margin pools. It is
  // derived, not fetched: the backend's NAV is holdings + loan book, so the
  // difference IS the loan book, and deriving it can never disagree with the
  // value printed beside it. Without this the mix bar summed to HOLDINGS while
  // "Vault value" showed NAV, so the two silently disagreed by the size of the
  // loan book and the vault's single largest allocation was invisible to the
  // LP carrying its credit risk.
  const holdingsVal = mix.reduce((s, m) => s + m.val, 0);
  const lentOut = Math.max(0, totalValue - holdingsVal);
  if (lentOut > 0) mix.push({ token: "Lent out", val: lentOut, qty: null, cls: "mix-lent" });
  const mixTotal = mix.reduce((s, m) => s + m.val, 0) || 1;
  const segments = mix.map((m) =>
    `<div class="vault-mix-seg ${m.cls}" style="width:${(m.val / mixTotal * 100).toFixed(2)}%" title="${m.token}: ${fmtUsd(m.val)} (${(m.val/mixTotal*100).toFixed(1)}%)"></div>`
  ).join("");
  const legend = mix.map((m) =>
    `<span class="vault-mix-key"><span class="vault-mix-dot ${m.cls}"></span>${m.token} ${(m.val/mixTotal*100).toFixed(0)}%`
    + `<span class="vault-mix-sub">${m.qty === null ? fmtUsd(m.val) : fmtQty(m.qty, m.token)}</span></span>`
  ).join("");

  container.innerHTML = `
    <div class="pnl-card vault-card">
      <div class="pnl-head">
        <div class="pnl-title">
          <span class="pool-name">AMM Vault</span>
          <span class="pnl-base">Single basket across all markets</span>
        </div>
        <div class="pnl-stats">
          <span class="pnl-vplp ${cls}">${valuePerLP.toFixed(4)}</span>
          <span class="pnl-pct ${cls}">${fmtPct(pnlPct)}</span>
        </div>
      </div>
      <div class="pnl-chart-wrap">${chart}</div>
      <div class="vault-mix">
        <div class="vault-mix-bar">${segments}</div>
        <div class="vault-mix-legend">${legend}</div>
      </div>
      <div class="pnl-foot">
        <span class="pnl-foot-label">P&amp;L</span>
        <span class="pnl-foot-val ${cls}">${pnlAbs >= 0 ? "+" : ""}${fmtUsd(pnlAbs)}</span>
        <span class="pnl-foot-sep">·</span>
        <span class="pnl-foot-label">Vault value</span>
        <span class="pnl-foot-val">${fmtUsd(totalValue)}</span>
        <span class="pnl-foot-sep">·</span>
        <span class="pnl-foot-label">Lent out</span>
        <span class="pnl-foot-val">${fmtUsd(lentOut)}${totalValue > 0 ? ` (${(lentOut / totalValue * 100).toFixed(1)}%)` : ""}</span>
        ${owedToInsurance > 0 ? `<span class="pnl-foot-sep">·</span>
        <span class="pnl-foot-label">Owed to insurance</span>
        <span class="pnl-foot-val neg">−${fmtUsd(owedToInsurance)}</span>` : ""}
        <span class="pnl-foot-sep">·</span>
        <span class="pnl-foot-label">LP supply</span>
        <span class="pnl-foot-val">${lpSupply.toLocaleString(undefined, { maximumFractionDigits: 0 })}</span>
        <span class="pnl-foot-sep">·</span>
        <span class="pnl-foot-label">Tracked</span>
        <span class="pnl-foot-val">${ageMin > 0 ? `${ageMin}m` : "—"}</span>
      </div>
    </div>
  `;
}

// Vault-flavoured chart — same shape as buildPnlChart but takes
// VaultSnapshots (which have valuePerLP at the top level, not nested
// in a pool record).
function buildVaultPnlChart(snapshots) {
  const w = 600, h = 120, pad = 8;
  if (!snapshots || snapshots.length < 2) {
    return `<div class="pnl-empty">Building history… (need at least 2 snapshots — first samples in &lt;30s)</div>`;
  }
  const xs = snapshots.map((s) => Number(s.timestamp));
  const ys = snapshots.map((s) => Number(s.valuePerLP));
  const minX = Math.min(...xs), maxX = Math.max(...xs);
  const minY = Math.min(...ys, 1.0);
  const maxY = Math.max(...ys, 1.0);
  const xSpan = maxX - minX || 1;
  const ySpan = (maxY - minY) || 1;
  const xs2 = (x) => pad + ((x - minX) / xSpan) * (w - 2 * pad);
  const ys2 = (y) => h - pad - ((y - minY) / ySpan) * (h - 2 * pad);
  const path = snapshots
    .map((s, i) => `${i === 0 ? "M" : "L"}${xs2(Number(s.timestamp)).toFixed(1)},${ys2(Number(s.valuePerLP)).toFixed(1)}`)
    .join(" ");
  const areaPath = `${path} L${xs2(maxX).toFixed(1)},${(h - pad).toFixed(1)} L${xs2(minX).toFixed(1)},${(h - pad).toFixed(1)} Z`;
  const lastVal = ys[ys.length - 1];
  const cls = lastVal >= 1.0 ? "pos" : "neg";
  return `
    <svg class="pnl-chart vault-chart ${cls}" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none">
      <path d="${areaPath}" class="pnl-area"/>
      <line x1="${pad}" y1="${ys2(1.0).toFixed(1)}" x2="${w - pad}" y2="${ys2(1.0).toFixed(1)}" class="pnl-breakeven"/>
      <path d="${path}" class="pnl-line"/>
    </svg>
  `;
}

function renderStatsKpis({ pools, feedStats, marketsList, poolValues, vault, treasury }) {
  // TVL = vault's total quote-denominated value (sum of basket
  // components × refPrice + ICPUSD held). The single-vault model
  // means there's exactly one TVL, not three to sum. (poolValues
  // is still passed in case any per-pool view ever needs it.)
  const tvl = vault ? Number(vault.totalQuoteValue || 0) : 0;
  let enabledPools = 0;
  for (const p of pools) { if (p.enabled) enabledPools += 1; }

  let vol = 0;
  for (const m of marketsList) { vol += Number(m.volume24h || 0); }

  document.getElementById("kpi-tvl").textContent = fmtUsd(tvl);
  document.getElementById("kpi-tvl-sub").textContent = `${pools.length} pool${pools.length === 1 ? "" : "s"} seeded`;
  document.getElementById("kpi-24vol").textContent = fmtUsd(vol);
  document.getElementById("kpi-refresh").textContent = Number(feedStats.successCount).toLocaleString();
  const fails = Number(feedStats.failureCount);
  document.getElementById("kpi-refresh-sub").textContent =
    `${fails} failure${fails === 1 ? "" : "s"} · every ${Number(feedStats.intervalSec)}s`;
  document.getElementById("kpi-pools").textContent = String(enabledPools);
  document.getElementById("kpi-pools-total").textContent = String(marketsList.length);

  // Treasury — accrued trading fees (ICPUSD). balanceUsd is spendable now;
  // lifetimeFeesUsd is the all-time total ever skimmed.
  const tEl = document.getElementById("kpi-treasury");
  if (tEl) {
    const treasuryBal = treasury ? Number(treasury.balanceUsd || 0) : 0;
    const treasuryLifetime = treasury ? Number(treasury.lifetimeFeesUsd || 0) : 0;
    tEl.textContent = fmtUsd(treasuryBal);
    document.getElementById("kpi-treasury-sub").textContent = `${fmtUsd(treasuryLifetime)} lifetime fees`;
  }
}

function renderStatsMarkets({ marketsList, pools, poolValues, aggregates }) {
  const poolsByMarket = Object.fromEntries(pools.map((p) => [p.marketId, p]));
  const pvByMarket = Object.fromEntries(poolValues.filter(Boolean).map((pv) => [pv.marketId, pv]));
  const container = document.getElementById("stats-market-grid");
  if (!marketsList.length) {
    container.innerHTML = `<div class="stats-empty">No markets configured.</div>`;
    return;
  }
  container.innerHTML = marketsList.map((m) => {
    const base = m.id.split("-")[0];
    const pool = poolsByMarket[m.id];
    const agg = aggregates[base];
    const pv = pvByMarket[m.id];
    const last = Number(m.lastPrice || 0);
    const oraclePrice = pool ? Number(pool.refPrice || 0) : (agg ? Number(agg.price || 0) : 0);

    // 24h change — use the same signed-change math the rest of the UI does.
    const absChange = Number(m.priceChange24hAbs || 0);
    const openPrice = last - absChange;
    const pct = openPrice > 0 ? (absChange / openPrice) * 100 : 0;
    const pctCls = pct > 0 ? "pos" : pct < 0 ? "neg" : "";

    // Oracle drift — how far the last traded price is from the oracle mid.
    let driftHtml = "";
    if (oraclePrice > 0 && last > 0) {
      const drift = ((last - oraclePrice) / oraclePrice) * 100;
      const driftCls = Math.abs(drift) < 0.1 ? "drift-ok" : Math.abs(drift) < 1 ? "drift-warn" : "drift-bad";
      driftHtml = `<div class="sm-drift ${driftCls}">
        <span class="sm-drift-label">vs oracle</span>
        <span>${fmtUsd(oraclePrice)}</span>
        <span class="sm-drift-pct">${fmtPct(drift)}</span>
      </div>`;
    }

    const enabled = pool && pool.enabled ? "enabled" : "disabled";
    const statusBadge = pool
      ? `<span class="sm-amm-badge ${enabled}">AMM ${enabled}</span>`
      : `<span class="sm-amm-badge disabled">no AMM</span>`;

    return `
      <a class="sm-card" href="#markets/${m.id}">
        <div class="sm-head">
          <span class="sm-name">${fmtMarketId(m.id)}</span>
          ${statusBadge}
        </div>
        <div class="sm-price">${fmtUsd(last)}</div>
        <div class="sm-change ${pctCls}">${fmtPct(pct)}</div>
        <div class="sm-row">
          <span class="sm-k">24h Vol</span>
          <span class="sm-v">${fmtUsd(Number(m.volume24h || 0))}</span>
        </div>
        ${driftHtml}
      </a>
    `;
  }).join("");
}

// Per-market AMM commitment cards. Each card shows two horizontal
// progress bars filled to the AMM's CAPITAL DEPLOYMENT for that
// market — i.e. how much of the AMM's own reserves are actively
// quoted on this side:
//
//   ASKS  ▮▮▮▮▮▮▮▮▮▯▯▯▯▯▯  2.50 BTC      58% of BTC reserves
//   BIDS  ▮▮▮▮▯▯▯▯▯▯▯▯▯▯▯  $186k         18% of cash reserves
//
// Replaces the prior "% of book" framing, which had the AMM at "5%"
// of total book depth but understated what's really happening — the
// AMM had 58% of its BTC actively listed for sale, the more useful
// signal for an LP/observer. ICPUSD is shared across all four pools,
// so the "% of cash" denominators on the four cards sum to the
// AMM's TOTAL bid-cash deployment across all markets.
function renderStatsPools({ pools, bookShares, vault }) {
  const container = document.getElementById("stats-pool-list");
  if (!pools.length) {
    container.innerHTML = `<div class="stats-empty">No pools seeded. Use <code>seedAmmPool</code> to bootstrap one.</div>`;
    return;
  }
  // Vault basket lookup: gives us the AMM's TOTAL holdings of each
  // base token + the shared ICPUSD reserve. Used as the denominator
  // for "% of reserves" in each card.
  const basket = vault?.basket || { btc: 0, eth: 0, sol: 0, icp: 0, icpusd: 0 };
  const baseHeldFor = (token) => Number(
    basket[String(token).toLowerCase()] ?? 0
  );
  const cashHeld = Number(basket.icpusd || 0);

  container.innerHTML = pools.map((p) => {
    const base = p.baseToken;
    const refPrice = Number(p.refPrice || 0);
    const share = bookShares[p.marketId] || null;

    const ammAskQty   = share ? Number(share.ammAskQty)    : 0;
    const ammBidValue = share ? Number(share.ammBidValue)  : 0;

    // Reserve-relative percentages — what fraction of the AMM's own
    // capital is currently quoted on this side. These can sum across
    // markets to >100% on the bid side because cash is shared and an
    // individual order's "reservation" against cash is at fill time,
    // not placement time. The cash-floor guard in ammPlaceQuote
    // prevents new bids when total cash drops below 5% of vault TVL.
    const baseHeld = baseHeldFor(base);
    const askPct = baseHeld > 0 ? Math.min(100, (ammAskQty / baseHeld) * 100) : 0;
    const bidPct = cashHeld > 0 ? Math.min(100, (ammBidValue / cashHeld) * 100) : 0;

    // Inventory skew — only meaningful if target is configured.
    const target = Number(p.inventoryTargetBase || 0);
    let skewHtml = "";
    if (target > 0 && share) {
      // Use the AMM's per-market base inventory (= ammAskQty + base
      // already-paid-out value). For the "vs target" comparison we
      // want the AMM principal's actual base-token balance, which is
      // tracked in the Pool record indirectly via inventoryTargetBase.
      // The most informative single number here is the ammAskQty —
      // how much base the AMM has currently quoted available — so
      // present that against the target.
      const dev = ((ammAskQty - target) / target) * 100;
      const cls = Math.abs(dev) < 10 ? "drift-ok" : Math.abs(dev) < 25 ? "drift-warn" : "drift-bad";
      skewHtml = `
        <div class="pool-kv">
          <div class="pool-k">Quoted vs target</div>
          <div class="pool-v">
            ${fmtQty(ammAskQty, base)} ${base}
            <span class="pool-sub ${cls}">${fmtPct(dev, 1)} vs ${fmtQty(target, base)}</span>
          </div>
        </div>`;
    }

    const bidsCount = (p.activeBidIds || []).length;
    const asksCount = (p.activeAskIds || []).length;
    const vol = Number(p.volRegime || 0);

    return `
      <div class="pool-card">
        <div class="pool-head">
          <div class="pool-title">
            <img class="market-logo market-logo-sm" src="/assets/${base}.svg" alt="" data-hide-on-error>
            <span class="pool-name">${fmtMarketId(p.marketId)}</span>
            <span class="sm-amm-badge ${p.enabled ? "enabled" : "disabled"}">${p.enabled ? "enabled" : "disabled"}</span>
          </div>
          <div class="pool-value">${fmtUsd(refPrice)}</div>
        </div>

        <div class="commitment-row">
          <div class="commitment-label commitment-ask">Asks</div>
          <div class="commitment-bar"><div class="commitment-fill ask" style="width:${askPct.toFixed(1)}%"></div></div>
          <div class="commitment-value">${fmtQty(ammAskQty, base)} ${base}</div>
          <div class="commitment-pct">${askPct.toFixed(0)}% of ${base} reserves</div>
        </div>
        <div class="commitment-row">
          <div class="commitment-label commitment-bid">Bids</div>
          <div class="commitment-bar"><div class="commitment-fill bid" style="width:${bidPct.toFixed(1)}%"></div></div>
          <div class="commitment-value">${fmtUsd(ammBidValue)}</div>
          <div class="commitment-pct">${bidPct.toFixed(0)}% of cash reserves</div>
        </div>

        <div class="pool-kvs">
          ${skewHtml}
          <div class="pool-kv">
            <div class="pool-k">Active quotes</div>
            <div class="pool-v">${bidsCount} bids · ${asksCount} asks<span class="pool-sub">${fmtAgo(p.lastRequoteNs)}</span></div>
          </div>
          <div class="pool-kv">
            <div class="pool-k">Ref price</div>
            <div class="pool-v">${fmtUsd(refPrice)}<span class="pool-sub">${fmtAgo(p.refPriceUpdatedNs)}</span></div>
          </div>
          <div class="pool-kv">
            <div class="pool-k">Volatility</div>
            <div class="pool-v">${fmtBps(vol)}<span class="pool-sub">EWMA log-returns</span></div>
          </div>
          <div class="pool-kv">
            <div class="pool-k">Config</div>
            <div class="pool-v">spread ${p.spreadBps} bps · ${p.numLevels} levels<span class="pool-sub">window ${p.protectionWindowSec}s</span></div>
          </div>
        </div>
      </div>
    `;
  }).join("");
}

// ── Oracle source-error popover ──────────────────────────────────────
// A failed oracle source (notably a single-node HTTPS-outcall failure on a
// cloud engine) can return a long, multi-line error. Rendering it inline in the
// readings table broke the layout, so each failed source shows a compact "error"
// trigger and reveals the full message in ONE shared, viewport-positioned
// popover with a SCROLLABLE body: hover to peek (desktop, hoverable so a long
// error can be scrolled), tap to pin (mobile), Escape / outside-click to
// dismiss. It is position:fixed (no ancestor can clip it) and the message rides
// on the trigger's data-err attribute, so it survives the table's re-renders.
function escapeAttr(s) {
  return String(s)
    .replace(/&/g, "&amp;").replace(/"/g, "&quot;")
    .replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
let _oracleErrPop = null;
let _oracleErrHideTimer = null;
function cancelHideOraclePop() {
  if (_oracleErrHideTimer) { clearTimeout(_oracleErrHideTimer); _oracleErrHideTimer = null; }
}
function scheduleHideOraclePop() {
  cancelHideOraclePop();
  _oracleErrHideTimer = setTimeout(() => hideOracleErrPop(false), 150);
}
function oracleErrPopEl() {
  if (!_oracleErrPop) {
    _oracleErrPop = document.createElement("div");
    _oracleErrPop.className = "oracle-err-pop";
    _oracleErrPop.innerHTML =
      `<div class="oracle-err-pop-head">Oracle source error</div>` +
      `<pre class="oracle-err-pop-body"></pre>`;
    // Keep it open while the pointer is over it, so a long error can be scrolled.
    _oracleErrPop.addEventListener("mouseenter", cancelHideOraclePop);
    _oracleErrPop.addEventListener("mouseleave", scheduleHideOraclePop);
    document.body.appendChild(_oracleErrPop);
  }
  return _oracleErrPop;
}
function showOracleErrPop(trigger, pin) {
  cancelHideOraclePop();
  const pop = oracleErrPopEl();
  pop.querySelector(".oracle-err-pop-body").textContent = trigger.dataset.err || "(no message reported)";
  pop.classList.toggle("pinned", !!pin);
  pop._for = trigger;
  pop.style.display = "block";
  pop.style.left = "0px"; pop.style.top = "0px";   // reset before measuring
  const r = trigger.getBoundingClientRect();
  const pw = pop.offsetWidth, ph = pop.offsetHeight, m = 8;
  const left = Math.max(m, Math.min(r.right - pw, window.innerWidth - pw - m));
  let top = r.bottom + 6;
  if (top + ph > window.innerHeight - m) top = Math.max(m, r.top - ph - 6);
  pop.style.left = left + "px";
  pop.style.top = top + "px";
}
function hideOracleErrPop(force) {
  cancelHideOraclePop();
  if (!_oracleErrPop) return;
  if (_oracleErrPop.classList.contains("pinned") && !force) return;
  _oracleErrPop.style.display = "none";
  _oracleErrPop.classList.remove("pinned");
  _oracleErrPop._for = null;
}
// Wire delegated listeners once on the persistent #stats-oracle container so
// they survive the table's innerHTML re-renders.
function setupOracleErrPopover(container) {
  if (!container || container.dataset.errPopWired) return;
  container.dataset.errPopWired = "1";
  container.addEventListener("mouseover", (e) => {
    const t = e.target.closest(".oracle-err-trigger");
    if (!t || (_oracleErrPop && _oracleErrPop.classList.contains("pinned"))) return;
    showOracleErrPop(t, false);
  });
  container.addEventListener("mouseout", (e) => {
    if (e.target.closest(".oracle-err-trigger")) scheduleHideOraclePop();
  });
  container.addEventListener("click", (e) => {
    const t = e.target.closest(".oracle-err-trigger");
    if (!t) return;
    e.stopPropagation();                              // don't trip the outside-click dismiss
    const open = _oracleErrPop && _oracleErrPop.style.display === "block"
              && _oracleErrPop.classList.contains("pinned") && _oracleErrPop._for === t;
    if (open) hideOracleErrPop(true); else showOracleErrPop(t, true);
  });
  container.addEventListener("keydown", (e) => {
    const t = e.target.closest(".oracle-err-trigger");
    if (t && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); showOracleErrPop(t, true); }
  });
  document.addEventListener("click", (e) => {
    if (e.target.closest(".oracle-err-trigger") || e.target.closest(".oracle-err-pop")) return;
    hideOracleErrPop(true);
  });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") hideOracleErrPop(true); });
}

function renderStatsOracle({ feedStats, aggregates, sources, pools }) {
  const container = document.getElementById("stats-oracle");
  setupOracleErrPopover(container);
  const hasAny = aggregates.BTC || aggregates.ETH || aggregates.SOL || aggregates.ICP;
  if (!hasAny) {
    container.innerHTML = `<div class="stats-empty">No price readings yet. The feed refreshes every ${Number(feedStats.intervalSec)}s.</div>`;
    return;
  }
  const inFlight = feedStats.refreshInFlight ? `<span class="oracle-live">● refreshing</span>` : "";
  const globalStats = `
    <div class="oracle-global">
      <div class="oracle-stat"><span class="oracle-k">Sources</span><span class="oracle-v">${sources.length}</span></div>
      <div class="oracle-stat"><span class="oracle-k">Successes</span><span class="oracle-v">${Number(feedStats.successCount).toLocaleString()}</span></div>
      <div class="oracle-stat"><span class="oracle-k">Failures</span><span class="oracle-v">${Number(feedStats.failureCount).toLocaleString()}</span></div>
      <div class="oracle-stat"><span class="oracle-k">Interval</span><span class="oracle-v">${Number(feedStats.intervalSec)}s</span></div>
      <div class="oracle-stat"><span class="oracle-k">Min sources</span><span class="oracle-v">${Number(feedStats.minSources)}</span></div>
      <div class="oracle-stat"><span class="oracle-k">Max stddev</span><span class="oracle-v">${fmtBps(Number(feedStats.maxStddevBps))}</span></div>
      ${inFlight}
    </div>
  `;

  const aggHtml = ["BTC", "ETH", "SOL", "ICP"].map((asset) => {
    const agg = aggregates[asset];
    if (!agg) {
      return `
        <div class="oracle-asset">
          <div class="oracle-asset-head">${asset}</div>
          <div class="oracle-empty">no reading</div>
        </div>`;
    }
    const readings = (agg.readings || []).map((r) => {
      // A failed source (e.g. a single-node HTTPS-outcall failure on a cloud
      // engine) can carry a long, multi-line error. Don't dump it into the
      // price cell — that breaks the table. Show a compact "error" trigger in
      // place of the price; the full message opens in a scrollable popover on
      // hover (desktop) / tap (mobile). See setupOracleErrPopover.
      const priceCell = r.ok
        ? fmtUsd(Number(r.price))
        : `<span class="oracle-err-trigger" tabindex="0" role="button" aria-label="Show ${r.sourceId} oracle error" data-err="${escapeAttr(r.errMessage?.[0] || "request failed")}">error</span>`;
      return `
        <tr>
          <td class="oracle-src">${r.sourceId}</td>
          <td class="oracle-num">${priceCell}</td>
          <td class="${r.ok ? "oracle-ok" : "oracle-err"}">${r.ok ? "✓" : "✗"}</td>
        </tr>`;
    }).join("");
    const stddev = Number(agg.stddevBps);
    const stdCls = stddev < 10 ? "drift-ok" : stddev < 50 ? "drift-warn" : "drift-bad";
    // FETCHED vs APPLIED, deliberately distinct rows: the numbers above are
    // the latest multi-source FETCH (it can look perfectly healthy while
    // every reading is being vetoed by the accept gate), while the AMM
    // quotes off the pool's APPLIED refPrice. The live incident this
    // surfaces: ICP fetched fresh every few seconds for hours while its
    // applied price stayed frozen and the AMM sat sidelined — and nothing
    // on this page said so.
    const pool = (pools || []).find((p) => p.marketId === `${asset}-ICPUSD`);
    let appliedHtml = "";
    if (pool) {
      const ageSec = Math.max(0, (Date.now() - Number(pool.refPriceUpdatedNs) / 1e6) / 1000);
      const maxAge = Number(feedStats.maxRefPriceAgeSec) || 300;
      const sidelined = ageSec > maxAge;
      const ageCls = sidelined ? "drift-bad" : ageSec > maxAge / 2 ? "drift-warn" : "drift-ok";
      appliedHtml = `
        <div class="oracle-asset-applied">
          <span>applied ${fmtUsd(Number(pool.refPrice))}</span>
          <span class="${ageCls}">· ${fmtAgo(pool.refPriceUpdatedNs)}</span>
          ${sidelined ? `<span class="oracle-sidelined" title="The applied refPrice is older than ${maxAge}s — the AMM refuses to quote on it. Fills fall back to users-only.">AMM SIDELINED</span>` : ""}
        </div>`;
    }
    return `
      <div class="oracle-asset">
        <div class="oracle-asset-head">
          <span>${asset}</span>
          <span class="oracle-asset-price">${fmtUsd(Number(agg.price))}</span>
        </div>
        <div class="oracle-asset-meta">
          <span class="${stdCls}">±${fmtBps(stddev)}</span>
          <span>· ${Number(agg.sourceCount)} of ${sources.length} sources</span>
          <span>· fetched ${fmtAgo(agg.timestamp)}</span>
        </div>
        ${appliedHtml}
        <table class="oracle-table">
          <tbody>${readings}</tbody>
        </table>
      </div>
    `;
  }).join("");

  container.innerHTML = `${globalStats}<div class="oracle-assets">${aggHtml}</div>`;
}

function renderStatsDepth({ marketsList, books }) {
  const container = document.getElementById("stats-depth-grid");
  if (!marketsList.length) {
    container.innerHTML = `<div class="stats-empty">No markets.</div>`;
    return;
  }
  // For each market, compute cumulative quote-denominated depth within
  // ±0.5%, ±1%, and ±2% of the current mid.
  container.innerHTML = marketsList.map((m) => {
    const book = books[m.id];
    if (!book || (!book.bids?.length && !book.asks?.length)) {
      return `
        <div class="depth-card">
          <div class="depth-head">${fmtMarketId(m.id)}</div>
          <div class="stats-empty">No orders on book</div>
        </div>`;
    }
    const bestBid = book.bids?.[0]?.price || 0;
    const bestAsk = book.asks?.[0]?.price || 0;
    const mid = bestBid && bestAsk ? (bestBid + bestAsk) / 2 : (bestAsk || bestBid);
    const spread = bestBid && bestAsk ? bestAsk - bestBid : 0;
    const spreadBps = mid > 0 ? (spread / mid) * 10000 : 0;

    // Cumulative depth helper: sum (price * quantity) for levels within
    // `pct` of `mid`. For bids we sum levels with price >= mid*(1-pct);
    // for asks, levels with price <= mid*(1+pct).
    function cumDepth(levels, pct, side) {
      let sum = 0;
      for (const lv of levels) {
        const p = Number(lv.price);
        const q = Number(lv.quantity);
        if (side === "bid" && p >= mid * (1 - pct)) sum += p * q;
        else if (side === "ask" && p <= mid * (1 + pct)) sum += p * q;
      }
      return sum;
    }
    const bands = [0.005, 0.01, 0.02];
    const rows = bands.map((pct) => {
      const bidD = cumDepth(book.bids, pct, "bid");
      const askD = cumDepth(book.asks, pct, "ask");
      const max = Math.max(bidD, askD, 1);
      return `
        <div class="depth-row">
          <div class="depth-pct">±${(pct * 100).toFixed(pct < 0.01 ? 1 : 0)}%</div>
          <div class="depth-bars">
            <div class="depth-bid-cell">
              <div class="depth-bid-fill" style="width:${(bidD / max * 100).toFixed(0)}%"></div>
              <span>${fmtUsd(bidD)}</span>
            </div>
            <div class="depth-ask-cell">
              <div class="depth-ask-fill" style="width:${(askD / max * 100).toFixed(0)}%"></div>
              <span>${fmtUsd(askD)}</span>
            </div>
          </div>
        </div>`;
    }).join("");

    return `
      <div class="depth-card">
        <div class="depth-head">
          <span class="depth-market">${fmtMarketId(m.id)}</span>
          <span class="depth-spread">spread ${fmtBps(spreadBps)}</span>
        </div>
        <div class="depth-mid">Mid ${fmtUsd(mid)}</div>
        <div class="depth-legend">
          <span class="depth-legend-bid">Bids</span>
          <span class="depth-legend-ask">Asks</span>
        </div>
        ${rows}
      </div>
    `;
  }).join("");
}

async function refreshAccountData() {
  if (!appState.isAuthenticated) return;
  renderAccountPage();
  await Promise.all([
    renderAccountOpenOrders(),
    renderAccountClosedOrders(),
    renderAccountTrades(),
    renderAccountAdjustments(),
    renderAccountDeposits(),
  ]);
}

// ── Account tabs: All | Wallet | Spot | Positions | Earn | … ─────
// "All" is the overview (account value + venue breakdown + earned badges);
// the rest group the account by domain. Hash is the source of truth
// (#account/<tab>). "status" is the internal key for the Fee Level tab.
let acctTab = "overview";
const ACCT_TABS = ["overview", "deposit", "wallet", "spot", "positions", "earn", "archive", "status", "ai"];
function showAccountTab(name) {
  acctTab = ACCT_TABS.includes(name) ? name : "overview";
  document.querySelectorAll(".acct-tab").forEach((b) => b.classList.toggle("active", b.dataset.acct === acctTab));
  for (const t of ACCT_TABS) {
    const pane = document.getElementById("acct-pane-" + t);
    // Panes only show signed in — signed out the page is just the sign-in CTA.
    if (pane) pane.style.display = (appState.isAuthenticated && t === acctTab) ? "" : "none";
  }
  if (!appState.isAuthenticated) {
    // Match the sign-in prompt to what the user came for (see index.html): the
    // Launch page's "Get your free dummy crypto" CTA lands here signed-out.
    const ttl = document.getElementById("account-signin-title");
    const sub = document.getElementById("account-signin-sub");
    if (ttl && sub) {
      const claiming = acctTab === "deposit";
      ttl.textContent = claiming ? "Sign in to collect your free dummy crypto" : "Sign in to view your account";
      sub.textContent = claiming
        ? "Every account gets a play allowance to trade with. No email, no password, no KYC — and nothing here is real money."
        : "Your profile, balances and trading history are here.";
    }
    return;
  }
  // Refresh the entered pane's data.
  if (acctTab === "overview") { renderAllOverview(); refreshStatusTab(); }
  else if (acctTab === "deposit") refreshDepositPage();
  else if (acctTab === "wallet") renderPoolTransfers();
  else if (acctTab === "positions") { renderPositions(); renderPositionsHistory(); renderPoolsHistory(); }
  else if (acctTab === "earn") renderEarnCard();
  else if (acctTab === "archive") loadArchive({ reset: true });
  else if (acctTab === "status") refreshStatusTab();
  else if (acctTab === "ai") refreshAiUsageTab();
}

// ── Account → AI: assistant usage + abuse-guard state ────────────────
// Everything comes from getMyAiUsage (caller-scoped query): lifetime step
// classification, live sliding-window consumption vs the proxy's limits,
// and the refusal/suspension state. The bars reuse the Fee Level pane's
// access-bar components.
async function refreshAiUsageTab() {
  const a = appState.actor;
  if (!a?.getMyAiUsage) return;
  let u;
  try { u = await a.getMyAiUsage(); } catch (_) { return; }
  const n = (x) => Number(x);
  const setTxt = (id, txt) => { const el = document.getElementById(id); if (el) el.textContent = txt; };
  const setBar = (id, used, lim) => {
    const el = document.getElementById(id);
    if (el) el.style.width = Math.min(100, lim > 0 ? (used / lim) * 100 : 0) + "%";
  };
  setTxt("ai-used-minute", `${n(u.usedMinute)} of ${n(u.limitMinute)}`);
  setBar("ai-bar-minute", n(u.usedMinute), n(u.limitMinute));
  setTxt("ai-used-hour", `${n(u.usedHour)} of ${n(u.limitHour)}`);
  setBar("ai-bar-hour", n(u.usedHour), n(u.limitHour));
  setTxt("ai-used-day", `${n(u.usedDay)} of ${n(u.limitDay)}`);
  setBar("ai-bar-day", n(u.usedDay), n(u.limitDay));
  setTxt("ai-stat-replies", fmtCount(n(u.replies)));
  setTxt("ai-stat-reads", fmtCount(n(u.reads)));
  setTxt("ai-stat-proposed", fmtCount(n(u.actionsProposed)));
  setTxt("ai-stat-executed", fmtCount(n(u.actionsExecuted)));
  setTxt("ai-stat-refused", fmtCount(n(u.refused)));
  setTxt("ai-stat-limited", fmtCount(n(u.rateLimited)));
  setTxt("ai-stat-steps", fmtCount(n(u.steps)));
  const banner = document.getElementById("ai-suspended-banner");
  if (banner) {
    const until = (u.suspendedUntilNs && u.suspendedUntilNs.length) ? Number(u.suspendedUntilNs[0]) : null;
    if (until) {
      banner.style.display = "";
      banner.textContent = `⛔ AI access is suspended until ${new Date(until / 1e6).toLocaleString()} — `
        + `${n(u.refusals24h)} policy-refused prompts within 24 hours.`;
    } else if (n(u.refusals24h) > 0) {
      banner.style.display = "";
      banner.textContent = `⚠ ${n(u.refusals24h)} of ${n(u.refusalLimit24h)} policy refusals in the last `
        + `24 hours — reaching ${n(u.refusalLimit24h)} suspends AI access for 24 hours.`;
    } else {
      banner.style.display = "none";
    }
  }
}

// Positions History sub-view: raw pool fills (default — the granular
// active-trading feed) vs closed-position episodes.
let phMode = "fills";
let phPage = 0;                 // Positions History pager (shared by both modes)
const PH_PAGE_SIZE = 20;
function setPhMode(mode) {
  phMode = mode;
  phPage = 0;
  document.getElementById("ph-mode-episodes")?.classList.toggle("seg-active", phMode === "episodes");
  document.getElementById("ph-mode-fills")?.classList.toggle("seg-active", phMode === "fills");
  renderPositionsHistory();
}

// Same Prev/Next control as the Markets-page activity panel
// (renderUomPagination), but with its own page state so the two don't fight.
function phPaginationHTML(pages, more) {
  // `more`: the archive may hold older rows — keep Next live at the loaded
  // edge (advancing triggers the backfill) and mark the count open-ended.
  if (pages <= 1 && !more) return "";
  return `<div class="uom-pagination"><button id="ph-prev" ${phPage === 0 ? "disabled" : ""}>‹ Prev</button>
    <span>${phPage + 1} / ${pages}${more ? "+" : ""}</span>
    <button id="ph-next" ${phPage >= pages - 1 && !more ? "disabled" : ""}>Next ›</button></div>`;
}
function wirePhPagination() {
  document.getElementById("ph-prev")?.addEventListener("click", () => { phPage--; renderPositionsHistory(); });
  document.getElementById("ph-next")?.addEventListener("click", () => { phPage++; renderPositionsHistory(); });
}

const tsToMs = (ts) => (typeof ts === "bigint" ? Number(ts / 1000000n) : Number(ts) / 1000000);
const fmtTs = (ts) => new Date(tsToMs(ts)).toLocaleString();
const escH = (s) => String(s).replace(/[<>&"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" }[c]));

// Wallet ⇄ pool margin transfers ("To / From Positions").
async function renderPoolTransfers() {
  const wrap = document.getElementById("pool-transfers-wrap");
  if (!wrap || !appState.actor || !appState.isAuthenticated) return;
  try {
    const xs = await appState.actor.getMyPoolTransfers();
    if (!xs || xs.length === 0) { wrap.innerHTML = '<div class="empty-state">No margin transfers yet</div>'; return; }
    const rows = [...xs].reverse().map((t) => {
      const fund = "fund" in t.kind;
      return `<tr>
        <td>${fmtTs(t.timestamp)}</td>
        <td>${fund ? "Wallet → pool" : "Pool → wallet"}</td>
        <td>${escH(t.poolName)}</td>
        <td class="${fund ? "pos-down" : "pos-up"}">${fund ? "−" : "+"}${fmtUsd(Number(t.amount))}</td>
      </tr>`;
    }).join("");
    wrap.innerHTML = `<table class="positions-table"><thead><tr>
      <th>Time</th><th>Direction</th><th>Pool</th><th>Amount</th>
    </tr></thead><tbody>${rows}</tbody></table>`;
  } catch (e) { console.warn("renderPoolTransfers failed:", e); }
}

// Positions History: episodes (one row per open→flat lifetime) or raw fills.
async function renderPositionsHistory() {
  const wrap = document.getElementById("positions-history-wrap");
  if (!wrap || !appState.actor || !appState.isAuthenticated) return;
  try {
    if (phMode === "episodes") {
      const eps = await appState.actor.getMyPositionEpisodes();
      if (!eps || eps.length === 0) { wrap.innerHTML = '<div class="empty-state">No closed positions yet — entries appear when a position is fully closed (or liquidated)</div>'; return; }
      const all = [...eps].reverse();
      const pages = Math.max(1, Math.ceil(all.length / PH_PAGE_SIZE));
      phPage = Math.min(phPage, pages - 1);
      const rows = all.slice(phPage * PH_PAGE_SIZE, (phPage + 1) * PH_PAGE_SIZE).map((e) => {
        const isLong = "long" in e.side;
        const pnl = Number(e.realizedPnl);
        return `<tr>
          <td>${fmtTs(e.closedAt)}</td>
          <td><span class="pos-side ${isLong ? "pos-long" : "pos-short"}">${isLong ? "LONG" : "SHORT"}</span> ${escH(e.baseToken)}${e.liquidated ? ' <span class="liq-tag">LIQ</span>' : ""}</td>
          <td>${escH(e.poolName)}</td>
          <td>${fmtQty(Number(e.qty), e.baseToken)} ${e.baseToken}</td>
          <td>${fmtUsd(Number(e.avgEntry))}</td>
          <td>${fmtUsd(Number(e.avgExit))}</td>
          <td class="${pnl >= 0 ? "pos-up" : "pos-down"}">${pnl >= 0 ? "+" : ""}${fmtUsd(pnl)}</td>
        </tr>`;
      }).join("");
      wrap.innerHTML = `<table class="positions-table"><thead><tr>
        <th>Closed</th><th>Coin</th><th>Pool</th><th>Qty</th><th>Avg entry</th><th>Avg exit</th><th>Realized PnL</th>
      </tr></thead><tbody>${rows}</tbody></table>` + phPaginationHTML(pages);
      wirePhPagination();
    } else {
      const [fills, pools] = await Promise.all([appState.actor.getMyPositionFills(), appState.actor.getMyMarginPools()]);
      _poolsCache = pools || [];
      const byPrincipal = new Map(_poolsCache.map((p) => [p.principal, p]));
      const hotIds = new Set((fills || []).map((t) => Number(t.id)));
      // Hot rows (one per pool-side) plus archived rows merged behind them —
      // same feed as the Markets-page Positions History (see the
      // archived-fills module for sourcing + classification).
      const merged = (fills || []).flatMap((t) => {
        const out = [];
        const mk = (pool, isBuy) => ({ isBuy, poolHTML: escH(pool.name), marketId: t.marketId,
          quantity: Number(t.quantity), price: Number(t.price), tsMs: tsToMs(t.timestamp), archived: false });
        const bPool = byPrincipal.get(t.buyer.toText ? t.buyer.toText() : String(t.buyer));
        const sPool = byPrincipal.get(t.seller.toText ? t.seller.toText() : String(t.seller));
        if (bPool) out.push(mk(bPool, true));
        if (sPool) out.push(mk(sPool, false));
        return out;
      }).concat(afPositionRows(hotIds).map((r) => ({
        isBuy: r.side === "buy", poolHTML: r.poolName ? escH(r.poolName) : "—", marketId: r.marketId,
        quantity: r.quantity, price: r.price, tsMs: r.tsMs, archived: true,
      })));
      const allRows = merged.sort((a, b) => b.tsMs - a.tsMs);
      const pages = Math.max(1, Math.ceil(allRows.length / PH_PAGE_SIZE));
      // Re-render only when rows landed or the chain finished (afFetchNext
      // caller contract — freeze guard).
      if (afMore() && appState.myPrincipalText && (allRows.length === 0 || phPage >= pages - 1)) {
        afFetchNext().then((added) => { if ((added || !afMore()) && phMode === "fills") renderPositionsHistory(); });
      }
      if (!allRows.length) {
        wrap.innerHTML = afMore()
          ? '<div class="empty-state">Searching the archive for older history…</div>'
          : '<div class="empty-state">No position fills yet</div>';
        return;
      }
      phPage = Math.min(phPage, pages - 1);
      const rows = allRows.slice(phPage * PH_PAGE_SIZE, (phPage + 1) * PH_PAGE_SIZE).map((r) => `<tr${r.archived ? ' class="uom-row-archived"' : ""}>
            <td>${new Date(r.tsMs).toLocaleString()}${r.archived ? " " + AF_TAG : ""}</td>
            <td><span class="pos-side ${r.isBuy ? "pos-long" : "pos-short"}">${r.isBuy ? "BUY" : "SELL"}</span> ${r.marketId.split("-")[0]}</td>
            <td>${r.poolHTML}</td>
            <td>${fmtQty(r.quantity, r.marketId.split("-")[0])}</td>
            <td>${fmtUsd(r.price)}</td>
          </tr>`).join("");
      wrap.innerHTML = `<table class="positions-table"><thead><tr>
        <th>Time</th><th>Side</th><th>Pool</th><th>Qty</th><th>Price</th>
      </tr></thead><tbody>${rows}</tbody></table>` + phPaginationHTML(pages, afMore());
      wirePhPagination();
    }
  } catch (e) { console.warn("renderPositionsHistory failed:", e); }
}

// Pools History: creations, margin transfers, liquidations — one merged log.
async function renderPoolsHistory() {
  const wrap = document.getElementById("pools-history-wrap");
  if (!wrap || !appState.actor || !appState.isAuthenticated) return;
  try {
    const [pools, xfers, liqs, rejs] = await Promise.all([
      appState.actor.getMyMarginPools(), appState.actor.getMyPoolTransfers(), appState.actor.getMyPoolLiquidations(),
      appState.actor.getMyReleaseRejections(),
    ]);
    _poolsCache = pools || [];
    const byPrincipal = new Map(_poolsCache.map((p) => [p.principal, p]));
    const ev = [];
    for (const r of (rejs || [])) {
      const clamped = r.clampedTo && r.clampedTo.length;
      const pool = r.poolName && r.poolName.length ? r.poolName[0] : null;
      ev.push({ ms: tsToMs(r.timestamp), warn: true, html:
        `${clamped ? "Order reduced" : "Order blocked"} at release${pool ? ` in <b>${escH(pool)}</b>` : ""} (${escH(r.marketId)}): ${escH(r.reason)}` });
    }
    for (const p of _poolsCache) {
      ev.push({ ms: tsToMs(p.createdAt), html: `Created pool <b>${escH(p.name)}</b> (${p.isolated ? "isolated" : "cross"})` });
    }
    for (const t of (xfers || [])) {
      ev.push({ ms: tsToMs(t.timestamp), html: "fund" in t.kind
        ? `Funded ${fmtUsd(Number(t.amount))} into <b>${escH(t.poolName)}</b>`
        : `Withdrew ${fmtUsd(Number(t.amount))} from <b>${escH(t.poolName)}</b>` });
    }
    for (const l of (liqs || [])) {
      const pool = byPrincipal.get(l.user.toText ? l.user.toText() : String(l.user));
      ev.push({ ms: tsToMs(l.timestamp), warn: true, html:
        `Liquidation in <b>${pool ? escH(pool.name) : "pool"}</b>: repaid ${formatNum(Number(l.debtRepaid))} ${l.debtToken} debt, seized ${formatNum(Number(l.collateralSeized))} ${l.collateralToken} (penalty ${fmtUsd(Number(l.penaltyUsd))})` });
    }
    if (ev.length === 0) { wrap.innerHTML = '<div class="empty-state">No pool events yet</div>'; return; }
    ev.sort((a, b) => b.ms - a.ms);
    wrap.innerHTML = ev.slice(0, 100).map((e) =>
      `<div class="pool-event-row${e.warn ? " pool-event-warn" : ""}"><span class="pe-time">${new Date(e.ms).toLocaleString()}</span><span class="pe-text">${e.html}</span></div>`
    ).join("");
  } catch (e) { console.warn("renderPoolsHistory failed:", e); }
}

// ── Archive tab: the unified "conceptual archive" ────────────────
// One timeline spanning the durable archive sidecar AND this canister's
// not-yet-shipped tail, plus app-only records that never become events (pool
// transfers, position closes, order rejections). Event rows are deduped by the
// dense global `seq`; everything is normalised to a common row and sorted by
// time. Sidecar history pages in (newest-first); app-only sources load once.
let _archRows = [];           // accumulated normalized rows
let _archSeen = new Set();    // seqs already merged (dedup sidecar vs tail vs pages)
let _archTradeIds = new Set(); // fill tradeIds merged (dedup margin-fill source vs owner-attributed sidecar fills)
let _archOffset = 0;          // fetched rows across the whole archive chain
let _archTotal = 0;           // sum of known per-archive totals (for load-more)
// Archive CHAIN sources, newest-first: the active archive, then sealed
// archives newest → oldest (Phase B — main.getArchives is the routing table).
// Each source pages independently; "load more" drains the active archive
// first, then continues seamlessly into the sealed history behind it.
let _archSources = null;      // [{ id, actor, offset, total|null }]
let _archPrincipals = [];     // [human, ...pool principals] — the deep-pagination key set
let _archSidecarErr = null;   // surfaced when the durable archive can't be read
const ARCH_PAGE = 200;

const archCoin = (mkt) => (mkt ? String(mkt).split("-")[0] : "");
// Normalise a backend UserEvent (variant kind) into a timeline row.
function normalizeUserEvent(e, status) {
  const k = e.kind, ms = tsToMs(e.ts);
  let category = "other", market = null, summary = "Event";
  if ("fill" in k) {
    const f = k.fill, isBuy = "buy" in f.side, coin = archCoin(f.marketId);
    category = "fill"; market = f.marketId;
    summary = `${isBuy ? "Buy" : "Sell"} ${fmtQty(Number(f.qty), coin)} ${coin} @ ${fmtUsd(Number(f.price))}`;
  } else if ("deposit" in k) {
    const d = k.deposit, isW = "withdrawal" in d.kind;
    category = isW ? "withdrawal" : "deposit";
    summary = `${isW ? "Withdraw" : "Deposit"} ${formatNum(Number(d.amount))} ${d.token}`;
  } else if ("orderClosed" in k) {
    const o = k.orderClosed, isBuy = "buy" in o.side, coin = archCoin(o.marketId);
    category = "orderClosed"; market = o.marketId;
    const st = "filled" in o.status ? "filled" : "cancelled";
    summary = `${isBuy ? "Buy" : "Sell"} order ${st} — ${fmtQty(Number(o.filled), coin)}/${fmtQty(Number(o.quantity), coin)} ${coin} @ ${fmtUsd(Number(o.price))}`;
  } else if ("liquidation" in k) {
    const l = k.liquidation;
    category = "liquidation"; market = l.collateralToken + "-ICPUSD";
    summary = `Liquidation — repaid ${formatNum(Number(l.debtRepaid))} ${l.debtToken}, seized ${formatNum(Number(l.collateralSeized))} ${l.collateralToken} (penalty ${fmtUsd(Number(l.penaltyUsd))})`;
  } else if ("lpDeposit" in k) {
    const l = k.lpDeposit; category = "lp"; market = l.marketId;
    summary = `AMM vault deposit — ${formatNum(Number(l.lpMinted))} LP`;
  } else if ("lpWithdraw" in k) {
    category = "lp"; summary = `AMM vault withdraw — ${formatNum(Number(k.lpWithdraw.lpBurned))} LP`;
  } else if ("insuranceStake" in k) {
    category = "insurance"; summary = `Insurance stake ${fmtUsd(Number(k.insuranceStake.amountUsd))}`;
  } else if ("insuranceUnstake" in k) {
    category = "insurance"; summary = `Insurance unstake — ${formatNum(Number(k.insuranceUnstake.shares))} shares → ${fmtUsd(Number(k.insuranceUnstake.payoutUsd))}`;
  } else if ("borrow" in k) {
    category = "borrow"; summary = `Borrow ${formatNum(Number(k.borrow.amount))} ${k.borrow.token}`;
  } else if ("repay" in k) {
    category = "repay"; summary = `Repay ${formatNum(Number(k.repay.amount))} ${k.repay.token}`;
  } else if ("config" in k) {
    // #47.4 — authority rewires/config flips on the durable tape (controller-
    // attributed; shows on the controller's own timeline).
    category = "config"; summary = `Config — ${k.config.setter}: ${k.config.value}`;
  }
  // prevHash (Phase-D tamper-evidence chain) rides along for the export: the
  // IDL decodes opt blob as [] | [Uint8Array] — hex-encode when present.
  const ph = (e.prevHash && e.prevHash.length)
    ? Array.from(e.prevHash[0]).map((b) => b.toString(16).padStart(2, "0")).join("")
    : "";
  return { ts: ms, seq: Number(e.seq), category, market, summary, status, prevHash: ph };
}
function archAddEvents(events, status) {
  for (const e of events) {
    const seq = Number(e.seq);
    if (_archSeen.has(seq)) continue;
    // Ledger #delta rows are machine records (one per balance mutation, for
    // replay/PoR) — the semantic events already tell the human story here.
    if ("delta" in e.kind || "debtDelta" in e.kind || "lpShareDelta" in e.kind || "insShareDelta" in e.kind || "gap" in e.kind) { _archSeen.add(seq); continue; }
    // Dedup fills by tradeId too: a margin fill surfaced from the hot store can
    // also arrive here as an owner-attributed sidecar #fill — show it once.
    if ("fill" in e.kind) {
      const tid = Number(e.kind.fill.tradeId);
      if (_archTradeIds.has(tid)) { _archSeen.add(seq); continue; }
      _archTradeIds.add(tid);
    }
    _archSeen.add(seq);
    _archRows.push(normalizeUserEvent(e, status));
  }
}

// Load (reset=true) or extend the archive. Reset pulls the app-side sources once
// (unshipped tail + pool transfers + episodes + rejections) plus the first
// sidecar page; load-more pulls the next sidecar page.
// The deep-pagination key set: the human principal + every pool principal.
// Margin fills/liquidations archive under the POOL principals (or under the
// human for events captured after the owner-remap), so querying this whole set
// — not just the caller — is what lets margin history page back through time.
function archPrincipalSet(pools) {
  const out = []; const seen = new Set();
  const add = (txt) => {
    if (!txt || seen.has(txt) || !Principal) return;
    try { out.push(Principal.fromText(txt)); seen.add(txt); } catch (_) {}
  };
  if (appState.myPrincipalText) add(appState.myPrincipalText);
  for (const p of (pools || [])) add(p.principal);
  return out;
}

async function loadArchive(opts) {
  const reset = opts && opts.reset;
  if (!appState.actor || !appState.isAuthenticated) return;
  const list = document.getElementById("archive-list");
  wireArchiveControls();
  if (reset) {
    _archRows = []; _archSeen = new Set(); _archTradeIds = new Set(); _archOffset = 0; _archTotal = 0; _archSources = null;
    _archPrincipals = archPrincipalSet([]); // human-only until pools load below
    if (list) list.innerHTML = `<div class="empty-state">Loading your history…</div>`;
    // App-side, one-shot: the freshest (unshipped) events + records that never
    // become events + margin fills (executed under POOL principals, so absent
    // from the per-user archive index — pulled from the hot store here).
    try {
      const [tail, xfers, eps, rejs, mfills, pools] = await Promise.all([
        appState.actor.getMyUnshippedEvents().catch(() => []),
        appState.actor.getMyPoolTransfers().catch(() => []),
        appState.actor.getMyPositionEpisodes().catch(() => []),
        appState.actor.getMyReleaseRejections().catch(() => []),
        appState.actor.getMyPositionFills().catch(() => []),
        appState.actor.getMyMarginPools().catch(() => []),
      ]);
      archAddEvents(tail || [], "pending");
      // Now that pools are known, the deep-pagination set spans human + pools.
      _archPrincipals = archPrincipalSet(pools);
      // Margin fills — deduped by tradeId against owner-attributed sidecar fills.
      const poolByPrin = new Map((pools || []).map((p) => [p.principal, p]));
      for (const t of (mfills || [])) {
        const tid = Number(t.id);
        if (_archTradeIds.has(tid)) continue;
        _archTradeIds.add(tid);
        const bp = t.buyer.toText ? t.buyer.toText() : String(t.buyer);
        const sp = t.seller.toText ? t.seller.toText() : String(t.seller);
        const isBuy = poolByPrin.has(bp);
        const pool = poolByPrin.get(isBuy ? bp : sp);
        const coin = archCoin(t.marketId);
        _archRows.push({ ts: tsToMs(t.timestamp), seq: null, category: "fill", market: t.marketId,
          summary: `${isBuy ? "Buy" : "Sell"} ${fmtQty(Number(t.quantity), coin)} ${coin} @ ${fmtUsd(Number(t.price))} · margin${pool ? " (" + pool.name + ")" : ""}`, status: "live" });
      }
      for (const t of (xfers || [])) {
        const fund = "fund" in t.kind;
        _archRows.push({ ts: tsToMs(t.timestamp), seq: null, category: "transfer", market: null,
          summary: `${fund ? "Wallet → " + t.poolName : t.poolName + " → wallet"}: ${fmtUsd(Number(t.amount))}`, status: "live" });
      }
      for (const ep of (eps || [])) {
        const isLong = "long" in ep.side, pnl = Number(ep.realizedPnl);
        _archRows.push({ ts: tsToMs(ep.closedAt), seq: null, category: "position", market: ep.marketId,
          summary: `Closed ${isLong ? "LONG" : "SHORT"} ${fmtQty(Number(ep.qty), ep.baseToken)} ${ep.baseToken} @ ${fmtUsd(Number(ep.avgExit))} · PnL ${pnl >= 0 ? "+" : ""}${fmtUsd(pnl)}${ep.liquidated ? " (liquidated)" : ""}`, status: "live" });
      }
      for (const r of (rejs || [])) {
        _archRows.push({ ts: tsToMs(r.timestamp), seq: null, category: "rejection", market: r.marketId,
          summary: r.reason, status: "live" });
      }
    } catch (e) { console.warn("archive app-side load failed:", e); }
  }
  // Sidecar page (durable history). Falls back gracefully if not spawned.
  _archSidecarErr = null;
  try {
    const sources = await archChainSources();
    if (!sources || !sources.length) {
      _archSidecarErr = "durable archive not reachable (sidecar not spawned, or you're offline)";
    } else {
      // Page the first source that still has rows: the active archive first,
      // then each sealed archive behind it. Deep history across the human +
      // pool principals; falls back to the caller-scoped query only if the
      // principal set somehow came up empty (e.g. pre-whoami).
      const src = sources.find((s) => s.total === null || s.offset < s.total);
      if (src) {
        // Federated through the exchange: the archive's by-principal query is
        // owner-gated, so getMyArchivedEvents resolves our principals (human +
        // pools) and reads the named archive AS the owner. One archive per call
        // keeps the chain paging (src.id walks getArchives newest→oldest).
        const res = await appState.actor.getMyArchivedEvents(
          Principal.fromText(src.id), BigInt(src.offset), BigInt(ARCH_PAGE));
        src.total = Number(res.total);
        archAddEvents(res.events || [], "archived");
        src.offset += (res.events ? res.events.length : 0);
      }
      _archTotal = sources.reduce((n, s) => n + (s.total ?? 0), 0);
      _archOffset = sources.reduce((n, s) => n + Math.min(s.offset, s.total ?? s.offset), 0);
      // An unqueried sealed source counts as "more available".
      if (sources.some((s) => s.total === null)) _archTotal = Math.max(_archTotal, _archOffset + 1);
    }
  } catch (e) {
    _archSidecarErr = "durable archive query failed: " + (e && e.message ? e.message : String(e));
    console.warn("archive sidecar load failed:", e);
  }
  renderArchive();
}

// Build the chain source list (once per reset): main.getArchives() is the
// routing table (sealed oldest→newest, active last); reversed here so reads
// go newest-first. Falls back to the single active archive when the routing
// query is unavailable (older backend / public actor without the method).
async function archChainSources() {
  if (_archSources) return _archSources;
  const base = await getArchiveActor();   // ensures agent + active archive id
  if (!base) return null;
  let chain = [];
  try {
    const a = appState.actor || appState.publicActor;
    if (a?.getArchives) chain = (await a.getArchives()).slice().reverse();
  } catch (_) { /* routing unavailable — single-archive fallback below */ }
  if (!chain.length) chain = [{ canisterId: _archiveId }];
  _archSources = chain.map((s) => ({
    id: s.canisterId,
    actor: s.canisterId === _archiveId
      ? appState.archiveActor
      : wrapActor(Actor.createActor(getArchiveIdlFactory(), { agent: icAgent, canisterId: s.canisterId })),
    offset: 0,
    total: null,
  }));
  return _archSources;
}

function renderArchive() {
  const list = document.getElementById("archive-list");
  const countEl = document.getElementById("archive-count");
  const moreBtn = document.getElementById("archive-more");
  if (!list) return;
  const rows = archFilteredRows();
  if (countEl) {
    const arch = _archRows.filter((r) => r.status === "archived").length;
    const pend = _archRows.filter((r) => r.status === "pending").length;
    const live = _archRows.filter((r) => r.status === "live").length;
    const more = (_archTotal > _archOffset) ? ` of ${_archTotal}+ archived` : "";
    countEl.textContent = `${rows.length} shown · ${arch} archived${more}${pend ? ` · ${pend} pending` : ""}${live ? ` · ${live} live` : ""}`;
  }
  const note = _archSidecarErr ? `<div class="archive-note">⚠ ${escH(_archSidecarErr)} — showing live + pending only.</div>` : "";
  if (rows.length === 0) {
    list.innerHTML = note + `<div class="empty-state">No matching history.</div>`;
  } else {
    list.innerHTML = note + `<table class="positions-table archive-table"><thead><tr>
      <th>Time</th><th>Type</th><th>Market</th><th>Detail</th><th></th>
    </tr></thead><tbody>${rows.map(archRowHTML).join("")}</tbody></table>`;
  }
  // Load-more shows while the sidecar has older pages not yet pulled.
  if (moreBtn) moreBtn.style.display = (_archOffset < _archTotal) ? "" : "none";
}

const ARCH_LABELS = { fill: "Fill", deposit: "Deposit", withdrawal: "Withdrawal", transfer: "Transfer",
  position: "Position", orderClosed: "Order", liquidation: "Liquidation", lp: "AMM vault",
  insurance: "Insurance", rejection: "Rejection", borrow: "Borrow", repay: "Repay",
  config: "Config", other: "Event" };
function archRowHTML(r) {
  const badge = r.status === "pending" ? `<span class="arch-badge arch-pending">pending</span>`
              : r.status === "archived" ? `<span class="arch-badge arch-archived">archived</span>`
              : `<span class="arch-badge arch-live">live</span>`;
  const coin = r.market ? archCoin(r.market) : "—";
  return `<tr>
    <td class="arch-time">${new Date(r.ts).toLocaleString()}</td>
    <td><span class="arch-cat arch-cat-${r.category}">${ARCH_LABELS[r.category] || r.category}</span></td>
    <td>${escH(coin)}</td>
    <td class="arch-detail">${escH(r.summary)}</td>
    <td>${badge}</td>
  </tr>`;
}

// Current filter/search state applied to the accumulated rows, newest-first.
function archFilteredRows() {
  const cat = document.getElementById("arch-cat")?.value || "";
  const mkt = document.getElementById("arch-market")?.value || "";
  const q = (document.getElementById("arch-search")?.value || "").trim().toLowerCase();
  const fromV = document.getElementById("arch-from")?.value;
  const toV = document.getElementById("arch-to")?.value;
  const fromMs = fromV ? new Date(fromV + "T00:00:00").getTime() : null;
  const toMs = toV ? new Date(toV + "T23:59:59.999").getTime() : null;
  return _archRows
    .filter((r) => !cat || r.category === cat)
    .filter((r) => !mkt || r.market === mkt)
    .filter((r) => fromMs == null || r.ts >= fromMs)
    .filter((r) => toMs == null || r.ts <= toMs)
    .filter((r) => !q || r.summary.toLowerCase().includes(q) || (r.market || "").toLowerCase().includes(q) || (ARCH_LABELS[r.category] || "").toLowerCase().includes(q))
    .sort((a, b) => b.ts - a.ts);
}

function archExport(fmt) {
  const rows = archFilteredRows();
  if (rows.length === 0) { showToast("Nothing to export with the current filters", "warning"); return; }
  let blob, name;
  if (fmt === "json") {
    blob = new Blob([JSON.stringify(rows.map((r) => ({
      time: new Date(r.ts).toISOString(), type: ARCH_LABELS[r.category] || r.category,
      market: r.market || "", detail: r.summary, status: r.status, seq: r.seq,
      // Tamper-evidence chain (docs/archive-design.md Phase D): each archived
      // event carries the SHA-256 chain hash of the one before it.
      prevHash: r.prevHash || "",
    })), null, 2)], { type: "application/json" });
    name = "uplands-archive.json";
  } else {
    const esc = (s) => `"${String(s).replace(/"/g, '""')}"`;
    const header = "time,type,market,detail,status,seq,prevHash\n";
    const body = rows.map((r) => [new Date(r.ts).toISOString(), ARCH_LABELS[r.category] || r.category,
      r.market || "", r.summary, r.status, r.seq == null ? "" : r.seq, r.prevHash || ""].map(esc).join(",")).join("\n");
    blob = new Blob([header + body], { type: "text/csv" });
    name = "uplands-archive.csv";
  }
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url; a.download = name; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function wireArchiveControls() {
  const root = document.getElementById("archive-card");
  if (!root || root.dataset.wired) return;
  root.dataset.wired = "1";
  ["arch-cat", "arch-market", "arch-from", "arch-to"].forEach((id) =>
    document.getElementById(id)?.addEventListener("change", renderArchive));
  document.getElementById("arch-search")?.addEventListener("input", renderArchive);
  document.getElementById("arch-csv")?.addEventListener("click", () => archExport("csv"));
  document.getElementById("arch-json")?.addEventListener("click", () => archExport("json"));
  document.getElementById("archive-more")?.addEventListener("click", () => loadArchive({ reset: false }));
}

// Header account value ticks on a WALL-CLOCK-ALIGNED 10s grid (…:00, :10, :20)
// rather than a per-tab interval: every open tab fires at the same instants,
// queries the same backend snapshot, and therefore shows the same figure —
// aligned timeouts (rescheduled each tick) instead of setInterval, so tabs
// can't drift apart and a laggy tick doesn't stack.
let _acctClockStarted = false;
function startAcctValueClock() {
  if (_acctClockStarted) return;
  _acctClockStarted = true;
  const TICK_MS = 10_000;
  const schedule = () => setTimeout(tick, TICK_MS - (Date.now() % TICK_MS) + 5);
  const tick = async () => {
    if (appState.isAuthenticated && appState.actor) {
      try {
        cachedAcctSummary = await appState.actor.getMyAccountSummary();
        renderBalances();
      } catch (_) { /* keep last figure; retry next aligned tick */ }
    }
    schedule();
  };
  schedule();
}

// ── Rendering ───────────────────────────────────────────────────
// ── Odometer ────────────────────────────────────────────────────
// Renders `text` into `el` with every digit as a 0–9 wheel (a vertical strip
// translated to −digit·1em inside a 1em window). When the text keeps the
// same SHAPE (length + digit positions — e.g. $12,848 → $12,901), only the
// strip transforms change, and the CSS transition rolls the wheels. A shape
// change (new magnitude, first render) rebuilds cold with no roll — a
// half-animated re-layout looks worse than a snap.
function renderOdometer(el, text) {
  if (el.dataset.odo === text) return;
  const prev = el.dataset.odo || "";
  el.dataset.odo = text;
  const isD = (c) => c >= "0" && c <= "9";
  const sameShape = prev.length === text.length &&
    [...prev].every((c, i) => isD(c) === isD(text[i]));
  if (!sameShape) {
    const wheel = (d) =>
      `<span class="odo-digit"><span class="odo-strip" style="transform:translateY(-${d}em)">` +
      "0123456789".split("").map((n) => `<i>${n}</i>`).join("") +
      `</span></span>`;
    el.innerHTML = [...text].map((c) => isD(c) ? wheel(c) : `<span class="odo-char">${c}</span>`).join("");
    return;
  }
  const strips = el.querySelectorAll(".odo-strip");
  let di = 0;
  for (const c of text) {
    if (isD(c)) strips[di++].style.transform = `translateY(-${c}em)`;
  }
}

function renderBalances() {
  // Two mounts, one figure: the desktop pill-side value and the mobile
  // header value (before the hamburger). CSS shows exactly one per
  // breakpoint; both are kept in sync here so a resize never reveals a
  // stale number.
  const el = document.getElementById("balance-display");
  const elM = document.getElementById("balance-display-mobile");
  if (!appState.isAuthenticated) {
    el.style.display = "none";
    if (elM) elM.style.display = "none";
    return;
  }
  el.style.display = "flex";
  if (elM) elM.style.display = "flex";
  // ACCOUNT value = wallet + every pool's equity (positions marked to market,
  // net of debt) — from getMyAccountSummary. Until the first summary arrives,
  // fall back to wallet holdings only so the figure isn't blank.
  let walletVal = userBalances["ICPUSD"] || 0;
  for (const m of markets) {
    const bal = userBalances[m.baseToken] || 0;
    if (bal > 0 && m.lastPrice > 0) walletVal += bal * m.lastPrice;
  }
  if (cachedAcctSummary) walletVal = Number(cachedAcctSummary.freeWalletValueUsd) || 0;
  const net = cachedAcctSummary ? Number(cachedAcctSummary.netAccountValueUsd) || 0 : walletVal;
  // Pill shows whole dollars — it's a glanceable figure; cents live on the
  // Account page. Digits render as odometer wheels that ROLL when the 10s
  // clock lands a new figure, instead of the text snapping.
  const txt = `$${Math.round(net).toLocaleString("en-US")}`;
  for (const mount of [el, elM]) {
    if (!mount) continue;
    let amt = mount.querySelector(".amount");
    if (!amt) { mount.innerHTML = `<span class="amount"></span>`; amt = mount.querySelector(".amount"); }
    renderOdometer(amt, txt);
  }
  // Keep the Account-page figures in sync: the Account-value card shows the
  // aggregate; the Wallet card shows its own component (wallet holdings only),
  // so Account value = Wallet value + Pools value is visibly auditable.
  const acctEl = document.getElementById("acct-net-value");
  if (acctEl) acctEl.textContent = fmtUsd(net);
  const walletEl = document.getElementById("wallet-value");
  if (walletEl) walletEl.textContent = fmtUsd(walletVal);
}

function updateSwapBalances() {
  const fromToken = document.getElementById("swap-from-token").value;
  const toToken = document.getElementById("swap-to-token").value;
  document.getElementById("swap-from-balance").textContent = `Balance: ${formatNum(userBalances[fromToken] || 0)}`;
  document.getElementById("swap-to-balance").textContent = `Balance: ${formatNum(userBalances[toToken] || 0)}`;
}

function renderMarketDropdown() {
  function renderItems(list, container) {
    container.innerHTML = list
      .map((m) => `<div class="market-dropdown-item ${selectedMarket === m.id ? "active" : ""}" data-market="${escH(m.id)}"><span class="dd-name"><img class="market-logo market-logo-sm" src="/assets/${escH(m.baseToken)}.svg" alt="" data-hide-on-error>${escH(m.baseToken)}<span class="market-quote">/${escH(m.quoteToken)}</span></span><span class="dd-price">${m.lastPrice > 0 ? formatPrice(m.lastPrice) : "—"}</span></div>`)
      .join("");
    container.querySelectorAll(".market-dropdown-item").forEach((item) => {
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        // User explicitly chose this market → push a new history entry so
        // Back returns to the previously-viewed market.
        selectMarket(item.dataset.market, { pushHistory: true });
      });
    });
  }

  // Recent section
  const recentSection = document.getElementById("market-dropdown-recent");
  const recentList = document.getElementById("market-dropdown-recent-list");
  const recentData = recentMarkets.map((id) => markets.find((m) => m.id === id)).filter(Boolean);
  if (recentData.length) {
    recentSection.style.display = "";
    renderItems(recentData, recentList);
  } else {
    recentSection.style.display = "none";
  }

  // All section
  const allList = document.getElementById("market-dropdown-all-list");
  renderItems(markets, allList);
}

// Click-to-fill the Place Order form from the Order Book (delegated on the
// asks/bids containers — the rows are re-rendered every poll, the containers
// persist). Clicking a price sets the order price; in aggregation mode,
// clicking the (cumulative) Quantity or Value also sets the order amount.
function onOrderBookClick(e) {
  const span = e.target.closest("span.ob-click");
  if (!span) return;
  const row = span.closest(".orderbook-row");
  if (!row) return;
  const price = row.dataset.price;
  const qty   = row.dataset.qty;
  const priceInput = document.getElementById("order-price");
  if (priceInput && price) {
    priceInput.value = price;
    savedOrderPrices[orderSide] = price;
  }
  // Quantity / Value spans only carry .ob-click in aggregation mode → also set
  // the order amount (the cumulative size up to this level).
  if ((span.classList.contains("ob-qty") || span.classList.contains("ob-val")) && qty) {
    const qtyInput = document.getElementById("order-quantity");
    if (qtyInput) qtyInput.value = qty;
  }
  updateOrderTotal();
}

// ── Order-book aggregation (shared by the Markets book + the Swap market box)──
// Bucket raw levels into price intervals of size `g` (0 = exact, no bucketing).
// Asks (ascending): first row = best ask, then round intervals above — always
// regular, empty rows kept. Bids (descending): first row = best bid, then round
// intervals below. Pure: identical logic drives renderOrderBook and
// renderSwapBook so the granularity control behaves the same on both.
function bucketLevels(levels, side, g) {
  if (g <= 0 || !levels.length) return levels;
  const MAX_ROWS = 100; // cap to prevent runaway output
  const result = [];

  if (side === "ask") {
    // levels sorted ascending (best/lowest ask first)
    const best = levels[0].price;
    const firstEdge = Math.ceil(best / g) * g;
    const edge1 = (firstEdge <= best) ? best + g : firstEdge;
    // First bucket: [best, edge1)
    let bucket = { price: best, quantity: 0, orderCount: 0 };
    let edge = edge1;
    let idx = 0;

    while (idx < levels.length && result.length < MAX_ROWS) {
      const l = levels[idx];
      if (l.price < edge) {
        bucket.quantity += l.quantity;
        bucket.orderCount += Number(l.orderCount) || 0;
        idx++;
      } else {
        // Push current bucket (even if empty) and start new one at the boundary
        result.push(bucket);
        bucket = { price: edge, quantity: 0, orderCount: 0 };
        edge += g;
      }
    }
    if (result.length < MAX_ROWS) result.push(bucket);
    return result;
  } else {
    // levels sorted descending (best/highest bid first)
    const best = levels[0].price;
    const firstEdge = Math.floor(best / g) * g;
    const edge1 = (firstEdge >= best) ? best - g : firstEdge;
    // First bucket: (edge1, best]
    let bucket = { price: best, quantity: 0, orderCount: 0 };
    let edge = edge1;
    let idx = 0;

    while (idx < levels.length && result.length < MAX_ROWS) {
      const l = levels[idx];
      if (l.price > edge) {
        bucket.quantity += l.quantity;
        bucket.orderCount += Number(l.orderCount) || 0;
        idx++;
      } else {
        result.push(bucket);
        bucket = { price: edge, quantity: 0, orderCount: 0 };
        edge -= g;
      }
    }
    if (result.length < MAX_ROWS) result.push(bucket);
    return result;
  }
}

// The granularity dropdown options for a given best price — "Exact" plus the
// round price steps that split the visible book into a sensible number of rows.
function granularityOptionsFor(bestPrice) {
  if (bestPrice <= 0) return null;
  const allSteps = [0.001, 0.01, 0.1, 0.5, 1, 5, 10, 50, 100, 500, 1000];
  const validSteps = allSteps.filter((s) => bestPrice / s > 10 && bestPrice / s < 50000);
  return [{ value: 0, label: "Exact" }, ...validSteps.map((s) => ({ value: s, label: s >= 1 ? s.toFixed(0) : String(s) }))];
}

// Populate a granularity <menu> element from the current best price, marking the
// active step. Shared by the Markets toolbar and the Swap toolbar.
function fillGranMenu(menu, bestPrice, currentG) {
  if (!menu) return;
  const options = granularityOptionsFor(bestPrice);
  if (!options) return;
  menu.innerHTML = options.map((o) =>
    `<div class="ob-gran-option${o.value === currentG ? " active" : ""}" data-value="${o.value}">${o.label}</div>`
  ).join("");
}

// The dropdown's button label for a granularity value ("Exact" or the step).
function granLabelText(g) { return g === 0 ? "Exact" : (g >= 1 ? g.toFixed(0) : String(g)); }

// ── Depth-bar normalization (both books) ─────────────────────────
// Scale bars against the depth WITHIN the near-the-spread window (about the
// rows that fit on screen), saturating deeper rows at 100%. Whole-side maxima
// let the far tail flatten the visible shape to slivers — on BTC at Exact
// granularity the book holds hundreds of levels, so the rows by the spread
// sat at 1–5% width and read as invisible. One COMMON norm across both sides
// keeps bid/ask imbalance readable; a 2% floor keeps tiny nonzero levels
// visible. Values arrive best-first (cumulative or per-level — both work:
// the window max is simply the largest of the nearest OB_BAR_WINDOW rows).
const OB_BAR_WINDOW = 15;

// Levels fetched per side from the backend. The book widgets render only the
// top of the book (and client-side tick-grouping can only merge rows, never
// needs more), so a fixed fetch depth keeps the payload constant no matter
// how deep the resting book grows.
const OB_FETCH_DEPTH = 100;

function obBarNorm(askVals, bidVals) {
  return Math.max(
    ...askVals.slice(0, OB_BAR_WINDOW),
    ...bidVals.slice(0, OB_BAR_WINDOW),
    1e-12,
  );
}
function obBarPct(v, norm) {
  return v <= 0 ? 0 : Math.max(2, Math.min(100, (v / norm) * 100));
}


// ── Shared order-book row pipeline (Markets book + Swap book) ─────
// Both books bucket, cumulate, flash and bar-scale identically; only their
// markup differs. Keeping that arithmetic in ONE place is not tidiness — the
// two copies had already drifted into two separate bugs (the cumulative-total
// flash, and the whole-book-max decimal blow-up from a poison order), each
// fixed on one book only. Callers render rows; this decides what a row IS.
//
// Returns rows carrying: quantity (what's DISPLAYED — running total in
// cumulative mode), levelQty (the level's OWN size), barPct, and changed —
// plus the display precisions and the ready-made baselines for next render.
//
// The flash rule is: a row flashes iff something the user can SEE changed —
// its DISPLAYED price existed last render and the DISPLAYED size at that
// price differs now. Three failure modes taught us each clause:
//   · comparing the cumulative running total flashed every row deeper than
//     any fill (one trade → whole book);
//   · flashing unknown keys (before === undefined) flashed every row whenever
//     the AMM re-laddered, since each level lands on a fresh price — new
//     levels must appear SILENTLY (HyperLiquid behavior);
//   · keying by the raw float (toFixed(8)) strobed rows whose price moved by
//     less than the display precision — the user sees "63901" both times,
//     so 63901.23 → 63901.47 with the same size is NOT a change.
// Hence: aggregate per displayed-price string, compare displayed-size strings.
function obPrepare(rawAsks, rawBids, { granularity = 0, cumulative = false,
                                       prevAsk = {}, prevBid = {} } = {}) {
  const shape = (arr) => {
    let sum = 0;
    return arr.map((l) => ({ ...l, levelQty: l.quantity, quantity: cumulative ? (sum += l.quantity) : l.quantity }));
  };
  const asks = shape(bucketLevels(rawAsks || [], "ask", granularity));   // best (lowest) first
  const bids = shape(bucketLevels(rawBids || [], "bid", granularity));   // best (highest) first
  const all = [...asks, ...bids];
  const priceDp = all.length ? priceDecimals(all.map((l) => l.price)) : 2;
  const qtyDp = obQtyDecimals(asks, bids);
  // What the user sees at each displayed price: the per-level sizes summed
  // (distinct raw prices can share a display string) and rounded for display.
  const seen = (rows) => {
    const m = {};
    for (const l of rows) { const k = l.price.toFixed(priceDp); m[k] = (m[k] || 0) + l.levelQty; }
    for (const k in m) m[k] = m[k].toFixed(qtyDp);
    return m;
  };
  const nextAskBaseline = seen(asks);
  const nextBidBaseline = seen(bids);
  // Cumulative mode scales bars by running size; per-level by notional value.
  const barVal = (l) => (cumulative ? l.quantity : l.price * l.quantity);
  const norm = obBarNorm(asks.map(barVal), bids.map(barVal));
  const decorate = (l, prev, next) => {
    const k = l.price.toFixed(priceDp);
    return { ...l,
      barPct: obBarPct(barVal(l), norm),
      changed: prev[k] !== undefined && prev[k] !== next[k] };
  };
  // A flash means "look HERE" — so a bulk rewrite must not flash. The house
  // AMM re-posts its ENTIRE quote ladder on every requote (oracle tick, or
  // rebalancing after a fill), which legitimately changes the size of every
  // level it owns: diffing alone cannot tell that apart from real activity,
  // and it is what made a single trade light up the whole ask side.
  // Discrete events — a fill, someone's order landing or pulled — move a
  // handful of levels; a rewrite moves most of them. So when more than a
  // third of a side changes in one render, treat it as a rewrite and stay
  // quiet. (Properly, the flash should be driven off the TRADE feed rather
  // than book diffs; that is the real fix, and this bounds the noise until
  // then.)
  const BULK_REWRITE_FRACTION = 1 / 3;
  const strip = (rows) => {
    const changed = rows.reduce((n, l) => n + (l.changed ? 1 : 0), 0);
    if (changed > rows.length * BULK_REWRITE_FRACTION) for (const l of rows) l.changed = false;
    return rows;
  };
  return {
    asks: strip(asks.map((l) => decorate(l, prevAsk, nextAskBaseline))),
    bids: strip(bids.map((l) => decorate(l, prevBid, nextBidBaseline))),
    priceDp, qtyDp, nextAskBaseline, nextBidBaseline,
  };
}

// Quantity decimals = integer digits of the price, one uniform count per book
// (no per-row flicker). Representative price is the TOUCH, never the whole-book
// max: one absurd stink order deep in the fetched depth (seen live: a resting
// ask at ~1e33) would otherwise blow the count to ~40 and unformat every
// quantity. Hard-capped at 8 in case the touch itself is junk.
function obQtyDecimals(asks, bids) {
  const touch = Math.max(asks.length ? Math.abs(asks[0].price) : 0,
                         bids.length ? Math.abs(bids[0].price) : 0);
  return Math.min(touch >= 1 ? String(Math.floor(touch)).length : 1, 8);
}

function renderOrderBook(snapshot) {
  lastOrderBookSnapshot = snapshot;

  const asksEl   = document.getElementById("orderbook-asks");
  const bidsEl   = document.getElementById("orderbook-bids");
  const spreadEl = document.getElementById("orderbook-spread");

  // Bucket + cumulate + flash + bar scaling — shared with the Swap book.
  const prep = obPrepare(snapshot.asks, snapshot.bids, {
    granularity: obGranularity, cumulative: obCumulative,
    prevAsk: obPrevAsk, prevBid: obPrevBid,
  });
  const { asks, bids, priceDp, qtyDp } = prep;

  // Consistent decimals for price/total (columns align); quantity uses the
  // 5-dp/trailing-zero-stripped format so values read naturally (0.0125 instead
  // of 0.01250) even if that means ragged fractional lengths across rows.

  // Third column is a cash (quote/ICPUSD) amount — show whole numbers, rounded.
  const totalDp = 0;
  const fmtFixed = (n, dp) => n.toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });

  // Column headers reflect the mode: aggregation → Price | Quantity | Value
  // (cumulative running figures); per-level → Price | Amount | Cost.
  const qtyLabelEl   = document.getElementById("orderbook-qty-label");
  const totalLabelEl = document.getElementById("orderbook-total-label");
  if (qtyLabelEl)   qtyLabelEl.textContent   = obCumulative ? "Quantity" : "Amount";
  if (totalLabelEl) totalLabelEl.textContent = obCumulative ? "Value" : "Cost";

  // Flash a row when its size changed since the last render (like Trades /
  // HyperLiquid). Only once we have a baseline for this market (prev non-
  // empty), so switching markets / first load doesn't flash everything.
  function renderRow(l, cls) {
    const pct = l.barPct;
    // Clay Tint / Mint Tint depth bars with a SHEEN: brightest (0.32) at the
    // right edge where the bar is anchored, fading to a dim tip (0.10) —
    // dimensional instead of a flat slab. Average brightness ≈ the old flat
    // 0.25, and the change-flash keyframes in orderbook.css sit at 0.42 to
    // stay distinctly above the brightest resting edge.
    const edge = cls === "ask" ? "rgba(240,122,108,0.32)" : "rgba(94,230,180,0.32)";
    const tip  = cls === "ask" ? "rgba(240,122,108,0.10)" : "rgba(94,230,180,0.10)";
    // Longhand background-image (not the `background` shorthand): the shorthand
    // would reset the background-size/position that .orderbook-row uses to inset
    // the depth bar vertically (background gap between consecutive bars).
    const bg = `background-image:linear-gradient(to left,${edge} 0%,${tip} ${pct}%,transparent ${pct}%)`;
    const flash = l.changed ? ` ob-flash-${cls === "ask" ? "ask" : "bid"}` : "";
    // Click-to-fill: the price is always clickable (sets the order price); the
    // (cumulative) Quantity / Value are clickable only in aggregation mode
    // (they also set the order amount). data-* carry plain parseable numbers.
    const clk = obCumulative ? " ob-click" : "";
    return `<div class="orderbook-row ${cls}${flash}" style="${bg}" data-price="${l.price.toFixed(priceDp)}" data-qty="${l.quantity.toFixed(qtyDp)}"><span class="price ob-click">${fmtFixed(l.price, priceDp)}</span><span class="ob-qty${clk}">${fmtFixed(l.quantity, qtyDp)}</span><span class="ob-val${clk}">${fmtFixed(l.price * l.quantity, totalDp)}</span></div>`;
  }

  // In cumulative mode, depth bars reflect cumulative quantity; otherwise
  // notional value. The norm is computed on the BEST-FIRST arrays (the
  // window must hug the spread), then applied per row in display order.
  // Asks: reversed for display (highest at top, best ask at bottom near spread)
  const displayAsks = [...asks].reverse();
  asksEl.innerHTML = displayAsks.length
    ? displayAsks.map((l) => renderRow(l, "ask")).join("")
    : '<div class="empty-state">No asks</div>';

  asksEl.scrollTop = asksEl.scrollHeight;

  // Preserve the bids scroll position across re-renders — the book
  // re-renders on every poll, and innerHTML resets scrollTop to 0, which
  // would snap a scrolled-down bids list back to the top each tick (reads
  // as "can't scroll"). Asks intentionally re-pin to the bottom (best ask).
  const bidScroll = bidsEl.scrollTop;
  bidsEl.innerHTML = bids.length
    ? bids.map((l) => renderRow(l, "bid")).join("")
    : '<div class="empty-state">No bids</div>';
  bidsEl.scrollTop = bidScroll;

  // Baseline for the next render's change-flash (display-precision keys).
  obPrevAsk = prep.nextAskBaseline;
  obPrevBid = prep.nextBidBaseline;

  // Update granularity dropdown options based on current price
  updateGranularityOptions(asks, bids);

  // Spread row (HyperLiquid-style): best-ask − best-bid, shown as an absolute
  // value and a percent of mid. asks[0] is the best (lowest) ask; bids[0] is
  // the best (highest) bid. The "Spread" legend is hidden on mobile via CSS.
  const bestAsk = asks.length ? asks[0].price : 0;
  const bestBid = bids.length ? bids[0].price : 0;
  spreadEl.style.color = "";
  if (bestAsk > 0 && bestBid > 0 && bestAsk >= bestBid) {
    const spreadAbs = bestAsk - bestBid;
    const mid       = (bestAsk + bestBid) / 2;
    const spreadPct = mid > 0 ? (spreadAbs / mid) * 100 : 0;
    spreadEl.innerHTML =
      `<span class="ob-spread-label">Spread</span>` +
      `<span class="ob-spread-abs">${fmtFixed(spreadAbs, priceDp)}</span>` +
      `<span class="ob-spread-pct">${spreadPct.toFixed(3)}%</span>`;
  } else {
    spreadEl.innerHTML =
      `<span class="ob-spread-label">Spread</span>` +
      `<span class="ob-spread-abs">—</span><span class="ob-spread-pct"></span>`;
  }

  // Initialize order price if empty
  initOrderPrice();
}

function updateGranularityOptions(asks, bids) {
  const bestPrice = asks.length ? asks[0].price : (bids.length ? bids[0].price : 0);
  fillGranMenu(document.getElementById("ob-gran-menu"), bestPrice, obGranularity);
}

function renderTrades(trades) {
  const el = document.getElementById("recent-trades");
  if (!trades.length) {
    el.innerHTML = '<div class="empty-state">No trades yet</div>';
    lastTradeIds = new Set();
    return;
  }

  // Work chronologically (oldest→newest) to apply the tick rule, then reverse for display
  const chrono = [...trades]; // backend returns oldest-first
  const dirs = [];
  let lastDir = "buy";
  for (let i = 0; i < chrono.length; i++) {
    if (i > 0) {
      if (chrono[i].price > chrono[i - 1].price)      lastDir = "buy";
      else if (chrono[i].price < chrono[i - 1].price) lastDir = "sell";
      // equal price → zero-tick, keep previous direction
    }
    dirs.push(lastDir);
  }

  // Newest first for display
  const sorted = [...chrono].reverse();
  const sortedDirs = [...dirs].reverse();
  const newIds = new Set(sorted.map((t) => String(t.id)));

  // Consistent decimals only for price (columns align); quantity uses the
  // 5-dp/trailing-zero-stripped format.
  const priceDp = priceDecimals(sorted.map((t) => t.price));
  // Size decimals = integer digits of the price — the same rule as the order
  // book's Quantity column (renderOrderBook's qtyDp).
  const repPrice = sorted.length ? Math.max(...sorted.map((t) => Math.abs(t.price))) : 0;
  const qtyDp = repPrice >= 1 ? String(Math.floor(repPrice)).length : 1;
  const fmtQ = (q) => q.toLocaleString("en-US", { minimumFractionDigits: qtyDp, maximumFractionDigits: qtyDp });

  const now = Date.now();
  el.innerHTML = sorted
    .map((t, i) => {
      const isNew = !lastTradeIds.has(String(t.id)) && lastTradeIds.size > 0;
      const dir = sortedDirs[i];
      const cls = ["trade-row", `trade-row-${dir}`, isNew ? "trade-row-new" : ""].join(" ").trim();
      const tMs = typeof t.timestamp === "bigint" ? Number(t.timestamp / 1000000n) : Number(t.timestamp) / 1000000;
      const ago = now - tMs;
      const opacity = ago < 10000 ? Math.min((Math.floor(ago / 1000) + 1) * 0.1, 0.9) : 0.9; // 0.9 = resting span opacity
      const priceTxt = t.price.toLocaleString("en-US", { minimumFractionDigits: priceDp, maximumFractionDigits: priceDp });
      return `<div class="${cls}"><span class="price">${priceTxt}</span><span>${fmtQ(t.quantity)}</span><span class="time" style="opacity:${opacity}">${formatTime(t.timestamp)}</span></div>`;
    })
    .join("");

  lastTradeIds = newIds;
  renderedTrades = sorted;

  // Keep the selector-bar price in sync with the trade feed (this runs on the
  // 2s poll; the markets refresh is only 10s). setSelectorPrice de-dupes
  // against prevMarketPrice so it won't double-flash with updatePriceChange.
  // The price stays white and pulses green/red only on a move; the spread row
  // is owned by renderOrderBook (true bid/ask spread).
  if (chrono.length) {
    setSelectorPrice(chrono[chrono.length - 1].price);
  }
}

function renderSwapOrders(orders) {
  const section = document.getElementById("swap-orders-section");
  const list    = document.getElementById("swap-orders-list");
  const openOrders = orders.filter((o) => o.status.open !== undefined || o.status.partiallyFilled !== undefined);

  if (!openOrders.length) {
    section.style.display = "none";
    return;
  }

  section.style.display = "block";
  list.innerHTML = openOrders
    .map(
      (o) => `
    <div class="swap-order-row">
      <div class="swap-order-info">
        <span class="${o.side.buy !== undefined ? "side-buy" : "side-sell"}">${o.side.buy !== undefined ? "BUY" : "SELL"}</span>
        <span>${o.marketId}</span>
        <span>${formatNum(o.quantity - o.filled)} @ ${formatPrice(o.price)}</span>
      </div>
      <button class="btn btn-danger btn-sm" data-cancel="${o.id}">Cancel</button>
    </div>
  `
    )
    .join("");

  list.querySelectorAll("[data-cancel]").forEach((btn) => {
    btn.addEventListener("click", () => cancelOrder(Number(btn.dataset.cancel)));
  });
}

// ── Archived-fills backfill (Spot History · Positions History · Account trades) ──
// The hot tape (orderStore.trades) is bounded VENUE-WIDE, so an active fleet
// evicts a user's older fills within days and the history views below would
// silently go blank (2026-08 incident). The durable copies are the archive
// chain's owner-attributed #fill events; this module pages them in (newest →
// oldest, the Archive tab's chain walk but with its own offsets so the two
// paginations don't fight) and each view merges them behind its hot rows.
//
// Classification: an archived #fill names only the archive owner, not which
// pool executed it (the public tape deliberately drops sub-account identity —
// see backend emitEvent). A row is attributed back to a pool by (a) the event
// user being a pool principal (pre-remap capture era), else (b) falling inside
// a closed episode's [openedAt, closedAt] window on the same market. Fills of
// a position still OPEN when the tape churned past them stay unclassified —
// they render as spot rows until the episode closes and a reload rejoins them.
let _afForPrincipal = null;  // cache key: state rebuilds when the signed-in principal changes
let _afRows = [];            // normalized archived fills, all markets, unordered
let _afSeen = new Set();     // archive event seqs merged (dedup across pages)
let _afSources = null;       // [{ id, offset, total|null }] chain paging state
let _afPoolByPrin = null;    // pool principal text → pool record
let _afEpisodes = null;      // closed-position episodes (window join)
let _afLoading = null;       // single-flight page fetch
let _afDone = false;         // chain exhausted (or unavailable)
const AF_PAGE = 200;               // server-side page cap
const AF_MAX_PAGES_PER_PULL = 200; // runaway backstop only — one pull drains until it finds fills or exhausts the chain
const AF_EPISODE_SLACK_MS = 5000;  // reap/settle lag tolerance around episode windows

function afReset() {
  _afRows = []; _afSeen = new Set(); _afSources = null;
  _afPoolByPrin = null; _afEpisodes = null; _afLoading = null; _afDone = false;
}

function afClassify(e) {
  const f = e.kind.fill;
  const userTxt = e.user.toText ? e.user.toText() : String(e.user);
  const tsMs = tsToMs(e.ts);
  let poolName = null;
  const pool = _afPoolByPrin && _afPoolByPrin.get(userTxt);
  if (pool) {
    poolName = pool.name;
  } else {
    const ep = (_afEpisodes || []).find((x) => x.marketId === f.marketId
      && tsMs >= tsToMs(x.openedAt) - AF_EPISODE_SLACK_MS
      && tsMs <= tsToMs(x.closedAt) + AF_EPISODE_SLACK_MS);
    if (ep) poolName = ep.poolName;
  }
  return {
    tradeId: Number(f.tradeId), marketId: f.marketId,
    side: "buy" in f.side ? "buy" : "sell",
    price: Number(f.price), quantity: Number(f.qty),
    tsMs, poolName, isPosition: poolName !== null, archived: true,
  };
}

async function afEnsure() {
  if (_afForPrincipal !== appState.myPrincipalText) { afReset(); _afForPrincipal = appState.myPrincipalText; }
  if (_afSources !== null) return;
  const [pools, eps] = await Promise.all([
    appState.actor.getMyMarginPools().catch(() => []),
    appState.actor.getMyPositionEpisodes().catch(() => []),
  ]);
  _afPoolByPrin = new Map((pools || []).map((p) => [p.principal, p]));
  _afEpisodes = eps || [];
  let chain = [];
  try { if (appState.actor.getArchives) chain = (await appState.actor.getArchives()).slice().reverse(); } catch (_) {}
  _afSources = chain.map((s) => ({ id: s.canisterId, offset: 0, total: null }));
  if (!_afSources.length) _afDone = true;   // no sidecar (fresh deploy) — hot rows only
}

// True while older history may still be fetchable from the chain.
function afMore() { return !_afDone; }

// Pull the caller's archived events; resolves true when new fill rows landed.
// Single-flight: concurrent view renders share a fetch. The per-user index
// mixes all event kinds, so one pull keeps paging until it finds fills or
// exhausts the chain — so `false` means "nothing more will arrive without a
// state change" (chain done, or the auth guard bounced).
//
// CALLER CONTRACT: re-render from .then ONLY when `added || !afMore()`. The
// guard below returns an INSTANTLY-resolved false while auth state is still
// bootstrapping (isAuthenticated flips before actor/principal exist on a
// reload) — an unconditional re-render on that path re-kicks the fetch in the
// same microtask cycle, and the loop never yields: the page hard-freezes
// (Chrome's "wait or kill this page", found live 2026-08-07).
function afFetchNext() {
  if (_afDone || !appState.actor || !appState.isAuthenticated || !appState.myPrincipalText) return Promise.resolve(false);
  if (_afLoading) return _afLoading;
  _afLoading = (async () => {
    try {
      await afEnsure();
      let added = false, pulls = 0;
      while (!added && !_afDone && pulls < AF_MAX_PAGES_PER_PULL) {
        const src = _afSources.find((s) => s.total === null || s.offset < s.total);
        if (!src) { _afDone = true; break; }
        const res = await appState.actor.getMyArchivedEvents(
          Principal.fromText(src.id), BigInt(src.offset), BigInt(AF_PAGE));
        src.total = Number(res.total);
        const evs = res.events || [];
        src.offset += evs.length;
        if (!evs.length) src.offset = src.total;   // drained/empty source — advance past it
        for (const e of evs) {
          const seq = Number(e.seq);
          if (_afSeen.has(seq)) continue;
          _afSeen.add(seq);
          if (!("fill" in e.kind)) continue;
          _afRows.push(afClassify(e));
          added = true;
        }
        if (!_afSources.some((s) => s.total === null || s.offset < s.total)) _afDone = true;
        pulls += 1;
      }
      return added;
    } catch (e) {
      console.warn("archived-fills fetch failed:", e);
      _afDone = true;   // fail closed: hot rows still render; a reload retries
      return false;
    } finally { _afLoading = null; }
  })();
  return _afLoading;
}

// View feeds: archived rows not already covered by the given hot tradeIds.
function afSpotRows(hotIds)     { return _afRows.filter((r) => !r.isPosition && !hotIds.has(r.tradeId)); }
function afPositionRows(hotIds) { return _afRows.filter((r) =>  r.isPosition && !hotIds.has(r.tradeId)); }
const AF_TAG = '<span class="af-tag" title="Restored from the durable archive — the live tape only keeps the venue’s recent trades">archive</span>';

// ── Activity panel (Open Orders · Spot History · Positions · Positions History — all viewports) ─
function renderUserOrdersMobile() {
  const content = document.getElementById("uom-content");
  const pagination = document.getElementById("uom-pagination");
  if (!content || !pagination) return;

  if (!appState.isAuthenticated) {
    content.innerHTML = '<div class="uom-empty">Sign in to view your activity</div>';
    pagination.innerHTML = "";
    return;
  }
  if (uomTab === "positions") {
    renderUomPositions(content, pagination);
    return;
  }
  if (uomTab === "poshistory") {
    renderUomPositionsHistory(content, pagination);
    return;
  }
  if (!selectedMarket) {
    content.innerHTML = '<div class="uom-empty">Select a market</div>';
    pagination.innerHTML = "";
    return;
  }
  if (uomTab === "open") {
    renderUomOpenOrders(content, pagination);
  } else {
    renderUomHistory(content, pagination);
  }
}

// Markets-page "Positions" tab — cross-market, reuses the shared table.
async function renderUomPositions(content, pagination) {
  pagination.innerHTML = "";
  if (!appState.actor) return;
  try {
    // Fetch pools too: the Pool column resolves names from _poolsCache, which
    // is otherwise only populated by the Account page's renderPositions.
    const [positions, pools] = await Promise.all([
      appState.actor.getMyPositions(),
      appState.actor.getMyMarginPools(),
    ]);
    _poolsCache = pools || [];
    content.innerHTML = positionsTableHTML(uomScoped(positions, (p) => p.marketId));
  } catch (e) {
    content.innerHTML = '<div class="uom-empty">Could not load positions</div>';
  }
}

// Positions History on the Markets page shows position FILLS — the granular
// feed active trading needs (a position CLOSING is already inferable from the
// Positions tab beside it; per-lifetime episode summaries live on
// Account→Positions→Positions History). Same data as that page's "fills"
// mode: each trade where one of the caller's pools was a party, one row per
// pool-side, newest first.
async function renderUomPositionsHistory(content, pagination) {
  if (!appState.actor) { pagination.innerHTML = ""; return; }
  try {
    const [fills, pools] = await Promise.all([
      appState.actor.getMyPositionFills(),
      appState.actor.getMyMarginPools(),
    ]);
    _poolsCache = pools || [];
    const byPrincipal = new Map(_poolsCache.map((p) => [p.principal, p]));
    const hotIds = new Set((fills || []).map((t) => Number(t.id)));
    // Hot rows: one per pool-side of each trade. A buy fill adds long
    // exposure, a sell fill short — the position vocabulary, not the order
    // one. Archived rows merge behind (dedup by tradeId), pool label from
    // the classification join.
    const merged = (fills || []).flatMap((t) => {
      const out = [];
      const ms = tsToMs(t.timestamp);
      const bPool = byPrincipal.get(t.buyer.toText ? t.buyer.toText() : String(t.buyer));
      const sPool = byPrincipal.get(t.seller.toText ? t.seller.toText() : String(t.seller));
      const mk = (pool, isBuy) => ({ marketId: t.marketId, isBuy, poolHTML: poolLabelHTML(Number(pool.id)),
        quantity: Number(t.quantity), price: Number(t.price), tsMs: ms, archived: false });
      if (bPool) out.push(mk(bPool, true));
      if (sPool) out.push(mk(sPool, false));
      return out;
    }).concat(afPositionRows(hotIds).map((r) => ({
      marketId: r.marketId, isBuy: r.side === "buy",
      poolHTML: r.poolName ? escH(r.poolName) : "—",
      quantity: r.quantity, price: r.price, tsMs: r.tsMs, archived: true,
    })));
    const allRows = uomScoped(merged).sort((a, b) => b.tsMs - a.tsMs);

    // Backfill from the archive when the view runs dry (nothing loaded, or
    // the user reached the last loaded page). Re-render only when rows landed
    // or the chain finished (afFetchNext caller contract — freeze guard).
    const pages = Math.max(1, Math.ceil(allRows.length / UOM_PAGE_SIZE));
    if (afMore() && appState.myPrincipalText && (allRows.length === 0 || uomPage >= pages - 1)) {
      afFetchNext().then((added) => { if ((added || !afMore()) && uomTab === "poshistory") renderUserOrdersMobile(); });
    }

    if (!allRows.length) {
      content.innerHTML = afMore()
        ? '<div class="uom-empty">Searching the archive for older history…</div>'
        : `<div class="uom-empty">No position fills${uomScopeActive() ? " on this market" : ""}</div>`;
      pagination.innerHTML = "";
      return;
    }
    uomPage = Math.min(uomPage, pages - 1);
    const rows = allRows.slice(uomPage * UOM_PAGE_SIZE, (uomPage + 1) * UOM_PAGE_SIZE).map((r) => {
      const coin = r.marketId.split("-")[0];
      const anchor = uomAnchor(r.marketId, r.price);
      return `<tr${r.archived ? ' class="uom-row-archived"' : ""}>
        <td>${assetCellHTML(coin)}</td>
        <td class="td-side">${sidePillHTML(r.isBuy ? "Long" : "Short")}</td>
        <td class="pos-pool">${r.poolHTML}</td>
        <td>${formatBookQty(r.quantity, anchor)}</td>
        <td>${fmtUsdPrice(r.price, anchor)}</td>
        <td title="${new Date(r.tsMs).toLocaleString()}">${whenLabel(r.tsMs)}${r.archived ? " " + AF_TAG : ""}</td>
      </tr>`;
    }).join("");
    content.innerHTML = `<table class="positions-table"><thead><tr>
      <th>Asset</th><th class="th-side">Side</th><th class="th-pool">Pool</th><th>Qty</th><th>Price</th><th>When</th>
    </tr></thead><tbody>${rows}</tbody></table>`;
    renderUomPagination(pagination, pages, afMore());
  } catch (e) {
    content.innerHTML = '<div class="uom-empty">Could not load position fills</div>';
    pagination.innerHTML = "";
  }
}

function renderUomOpenOrders(content, pagination) {
  // Pending matches: crossing slices that hit a protected (AMM) maker and
  // are awaiting settlement. Shown above open orders with a distinct row
  // type so the user understands these aren't lost — they finalise into
  // trades after the protection window (typically 5s).
  const nowNs = BigInt(Date.now()) * 1_000_000n;
  const pendings = uomPendingMatches.map((p) => {
    const expiryNs = typeof p.expiryNs === "bigint" ? p.expiryNs : BigInt(p.expiryNs);
    const remainingMs = Number((expiryNs - nowNs) / 1_000_000n);
    return { ...p, remainingMs };
  });

  // All markets by default; the panel checkbox narrows to the selected one.
  const scopedPendings = uomScoped(pendings);
  const orders = uomScoped(uomOpenOrders);
  const poolOrders = uomScoped(uomPoolOrders || []);
  const total = orders.length + scopedPendings.length + poolOrders.length;
  const pages = Math.max(1, Math.ceil(orders.length / UOM_PAGE_SIZE));
  uomPage = Math.min(uomPage, pages - 1);
  const start = uomPage * UOM_PAGE_SIZE;
  const orderPage = orders.slice(start, start + UOM_PAGE_SIZE);

  if (!total) {
    content.innerHTML = `<div class="uom-empty">No open orders${uomScopeActive() ? " on this market" : ""}</div>`;
    pagination.innerHTML = "";
    return;
  }

  const pendingRows = scopedPendings.map((p) => {
    const isBuy = p.takerSide.buy !== undefined;
    const secs = Math.max(0, Math.ceil(p.remainingMs / 1000));
    const anchor = uomAnchor(p.marketId, p.price);
    return `<div class="uom-row uom-row-pending" title="Pending match — settling against AMM-protected maker">
      <span class="uom-cell-coin">${assetCellHTML(uomCoin(p.marketId))}</span>
      <span>${sidePillHTML(isBuy ? "Buy" : "Sell")}</span>
      <span>${formatBookPrice(p.price, anchor)}</span>
      <span>${formatBookQty(p.quantity, anchor)}</span>
      <span class="uom-settling">${secs > 0 ? `~${secs}s` : "now"}</span>
      <span></span>
    </div>`;
  }).join("");

  const orderRows = orderPage.map((o) => {
    const isBuy = o.side.buy !== undefined;
    // STAGED (sealed-until-GEPTOR): accepted but held off-book until the next
    // price update (~1s) releases it. Show "pending" rather than a fill count.
    const staged = stagedOrderIds.has(Number(o.id));
    const isMarket = o.orderType && o.orderType.market !== undefined;
    const anchor = uomAnchor(o.marketId, o.price);
    return `<div class="uom-row"${staged ? ' title="Pending — awaiting the next price update (~1s); not yet on the book"' : ""}>
      <span class="uom-cell-coin">${assetCellHTML(uomCoin(o.marketId))}</span>
      <span>${sidePillHTML(isBuy ? "Buy" : "Sell")}</span>
      <span>${staged && isMarket ? "mkt" : formatBookPrice(o.price, anchor)}</span>
      <span>${formatBookQty(o.quantity, anchor)}</span>
      <span>${staged ? '<span style="opacity:.65;font-style:italic">pending</span>' : formatBookQty(o.filled, anchor)}</span>
      <button class="uom-cancel" data-uom-cancel="${o.id}" title="Cancel">✕</button>
    </div>`;
  }).join("");

  // Resting MARGIN orders (owned by a pool) — Long/Short in the Coin cell IS
  // the margin marker, opening a position when they fill. Shown here (not just
  // Account→Positions) so a margin limit placed on this page is visible on it.
  // Cancel repays the borrow (cancelMyOrder routes pool orders through the
  // deleveraging path backend-side, so the plain cancel handler is correct
  // even when the pool tag is unresolved).
  const marginRows = poolOrders.map((o) => {
    const isBuy = o.side.buy !== undefined;
    const staged = stagedOrderIds.has(Number(o.id));
    const anchor = uomAnchor(o.marketId, o.price);
    return `<div class="uom-row uom-row-margin" title="${staged ? "Pending — awaiting the next price update (~1s); " : ""}Margin order in pool &quot;${escH(o.poolName)}&quot; — opens a ${isBuy ? "long" : "short"} position when it fills">
      <span class="uom-cell-coin">${assetCellHTML(uomCoin(o.marketId))}</span>
      <span>${sidePillHTML(isBuy ? "Long" : "Short")}</span>
      <span>${formatBookPrice(o.price, anchor)}</span>
      <span>${formatBookQty(o.quantity, anchor)}</span>
      <span>${staged ? '<span style="opacity:.65;font-style:italic">pending</span>' : formatBookQty(o.filled, anchor)}</span>
      <button class="uom-cancel" data-uom-cancel="${o.id}" title="Cancel">✕</button>
    </div>`;
  }).join("");

  content.innerHTML =
    '<div class="uom-header"><span>Asset</span><span>Side</span><span>Price</span><span>Qty</span><span>Filled</span><span></span></div>' +
    pendingRows + marginRows + orderRows;

  content.querySelectorAll("[data-uom-cancel]").forEach((btn) => {
    btn.addEventListener("click", () => cancelOrder(Number(btn.dataset.uomCancel)));
  });
  content.querySelectorAll("[data-pool-cancel]").forEach((btn) => {
    btn.addEventListener("click", () => onCancelPoolOrder(Number(btn.dataset.poolCancel), Number(btn.dataset.order)));
  });

  renderUomPagination(pagination, pages);
}

async function renderUomHistory(content, pagination) {
  // Fetch the full trade history if we've never populated the cache. After
  // that, polling merges new trades into the per-market buckets so we don't
  // need to refetch on every market switch.
  if (Object.keys(uomTradeHistoryByMarket).length === 0 && appState.actor) {
    try {
      const allTrades = await appState.actor.getMyTradeHistory();
      // Pre-populate every market's bucket — saves a round trip when the
      // user switches to a market they've previously traded.
      const buckets = {};
      for (const t of allTrades) {
        (buckets[t.marketId] = buckets[t.marketId] || []).push(t);
      }
      for (const [mid, trades] of Object.entries(buckets)) {
        // Server returns oldest-first; we want newest-first for display.
        uomTradeHistoryByMarket[mid] = trades.reverse();
      }
      // Leave a marker bucket even when the account has no trades at all, so
      // we don't re-fetch on every render.
      if (selectedMarket) { uomTradeHistoryByMarket[selectedMarket] ||= []; }
    } catch (e) {
      console.warn("Failed to fetch trade history:", e);
    }
  }

  // All markets, newest first; the panel checkbox narrows the view. Hot rows
  // first (already loaded), archived rows merged behind them — dedup by
  // tradeId so a fill still on the hot tape shows once.
  const hot = Object.values(uomTradeHistoryByMarket).flat();
  const hotIds = new Set(hot.map((t) => Number(t.id)));
  const merged = hot.map((t) => ({
    marketId: t.marketId,
    // Your side of the fill = which party you were — compare the trade's
    // buyer principal to your own (same rule as the Account→Spot history).
    side: (!!appState.myPrincipalText && String(t.buyer) === appState.myPrincipalText) ? "buy" : "sell",
    price: t.price, quantity: t.quantity, tsMs: tsToMs(t.timestamp), archived: false,
  })).concat(afSpotRows(hotIds));
  const data = uomScoped(merged).sort((a, b) => b.tsMs - a.tsMs);
  const total = data.length;
  const pages = Math.max(1, Math.ceil(total / UOM_PAGE_SIZE));
  uomPage = Math.min(uomPage, pages - 1);
  const start = uomPage * UOM_PAGE_SIZE;
  const page = data.slice(start, start + UOM_PAGE_SIZE);

  // Backfill from the archive when the view runs dry: nothing loaded yet, or
  // the user is on the last loaded page. Re-render only when rows landed or
  // the chain finished (see afFetchNext's caller contract — an unconditional
  // re-render here microtask-loops into a page freeze during auth bootstrap).
  if (afMore() && appState.myPrincipalText && (total === 0 || uomPage >= pages - 1)) {
    afFetchNext().then((added) => { if ((added || !afMore()) && uomTab === "history") renderUserOrdersMobile(); });
  }

  if (!total) {
    content.innerHTML = afMore()
      ? '<div class="uom-empty">Searching the archive for older history…</div>'
      : `<div class="uom-empty">No trade history${uomScopeActive() ? " on this market" : ""}</div>`;
    pagination.innerHTML = "";
    return;
  }

  content.innerHTML =
    '<div class="uom-header"><span>Asset</span><span>Side</span><span>Price</span><span>Qty</span><span>When</span><span></span></div>' +
    page.map((t) => {
      const anchor = uomAnchor(t.marketId, t.price);
      return `<div class="uom-row${t.archived ? " uom-row-archived" : ""}">
        <span class="uom-cell-coin">${assetCellHTML(uomCoin(t.marketId))}</span>
      <span>${sidePillHTML(t.side === "buy" ? "Buy" : "Sell")}</span>
        <span>${formatBookPrice(t.price, anchor)}</span>
        <span>${formatBookQty(t.quantity, anchor)}</span>
        <span title="${new Date(t.tsMs).toLocaleString()}">${whenLabel(t.tsMs)}${t.archived ? " " + AF_TAG : ""}</span>
        <span></span>
      </div>`;
    }).join("");

  renderUomPagination(pagination, pages, afMore());
}

function renderUomPagination(el, pages, more) {
  // `more`: older rows may still be fetchable from the archive — keep Next
  // live at the loaded edge (advancing triggers the backfill) and mark the
  // page count open-ended.
  if (pages <= 1 && !more) { el.innerHTML = ""; return; }
  el.innerHTML = `<button id="uom-prev" ${uomPage === 0 ? "disabled" : ""}>‹ Prev</button>
    <span>${uomPage + 1} / ${pages}${more ? "+" : ""}</span>
    <button id="uom-next" ${uomPage >= pages - 1 && !more ? "disabled" : ""}>Next ›</button>`;
  document.getElementById("uom-prev")?.addEventListener("click", () => { uomPage--; renderUserOrdersMobile(); });
  document.getElementById("uom-next")?.addEventListener("click", () => { uomPage++; renderUserOrdersMobile(); });
}

// ── Actions ─────────────────────────────────────────────────────
// opts.pushHistory: true  — add a new browser-history entry (user picked
//                           this market explicitly, e.g. from the dropdown).
//                 false — replace the current entry (programmatic fallback,
//                           e.g. default-selecting when a tab is entered).
function selectMarket(marketId, opts) {
  selectedMarket = marketId;
  // The market view only becomes measurable once a market is selected and its
  // panels render, which is AFTER the markets query returns — later than any
  // bounded frame-retry from page load can wait for. This is the reliable
  // moment to size the book column; it self-guards to run once.
  requestAnimationFrame(() => autoSizeBookColumn());
  // Keep the URL hash in sync so copy-paste captures the visible market.
  syncHashToState({ push: !!(opts && opts.pushHistory) });
  lastTradeIds = new Set(); // reset so initial load for new market doesn't flash
  obPrevAsk = {}; obPrevBid = {}; // ditto for the order-book change-flash
  prevMarketPrice = null;         // and the selector-bar price flash
  // Reset market status cache so the next poll triggers a full fetch
  // (doesn't clear per-market trade cache — we reuse it for instant switching)
  delete cachedMarketStatus[marketId];
  delete orderBookState[marketId]; // drop stale delta cache so next poll rebuilds from snapshot
  savedOrderPrices = { buy: "", sell: "" }; // reset prices for new market
  document.getElementById("order-price").value = ""; // clear so initOrderPrice fills it
  // A quantity sized for the OLD market is meaningless on the new one — clear
  // it and park the size slider at 0% (updateOrderTotal syncs thumb + total).
  document.getElementById("order-quantity").value = "";
  updateOrderTotal();
  uomPage = 0;
  // No need to reset uomTradeHistoryByMarket — it's keyed per market and
  // the renderer reads the current market's bucket.
  uomOpenOrders = [];
  uomPendingMatches = [];

  // Restore per-market order book granularity (default to Exact for new markets)
  obGranularity = obGranularityByMarket[marketId] || 0;
  const granLabel = document.getElementById("ob-gran-label");
  if (granLabel) {
    granLabel.textContent = obGranularity === 0 ? "Exact" : (obGranularity >= 1 ? obGranularity.toFixed(0) : String(obGranularity));
  }

  // Track recent markets (most recent first, max 3)
  recentMarkets = [marketId, ...recentMarkets.filter((id) => id !== marketId)].slice(0, 3);
  lastMarket = marketId;

  // Persist preferences
  const prefs = { recentMarkets, lastMarket };
  saveLocalPrefs(prefs);
  if (appState.isAuthenticated && appState.actor) {
    appState.actor.setUserPreferences({ recentMarkets, lastMarket: [lastMarket] });
  }

  // Close dropdowns
  document.getElementById("market-selector").classList.remove("open");
  document.getElementById("market-stats-toggle")?.classList.remove("open");
  document.querySelector(".market-stat-more.open")?.classList.remove("open");

  document.getElementById("market-detail").style.display = "";
  const market_ = markets.find((m) => m.id === marketId);
  const titleEl = document.getElementById("market-title");
  if (market_) {
    // Asset logo from public/assets/<TOKEN>.svg; hides itself if a market's
    // base token has no logo file yet.
    titleEl.innerHTML = `<img class="market-logo" src="/assets/${escH(market_.baseToken)}.svg" alt="" data-hide-on-error>${escH(market_.baseToken)}<span class="market-quote">/${escH(market_.quoteToken)}</span>`;
  } else {
    titleEl.textContent = marketId;
  }

  // Render inline chart on all viewports
  destroyMiniChart();
  renderMiniChart();
  if (miniChartRefreshInterval) clearInterval(miniChartRefreshInterval);
  miniChartRefreshInterval = setInterval(refreshMiniChart, 10000);

  // Public liquidation map for the newly-selected market (no sign-in needed).
  refreshHeatmap(marketId);
  // Paint the telemetry tail now from the per-market cache (or "—" on a
  // first visit); the fetch refreshes everything when it lands.
  paintMarketTele(marketId);
  refreshMarketTele(marketId);

  const market = markets.find((m) => m.id === marketId);
  if (market) {
    updatePriceChange(market);
    document.getElementById("order-qty-label").textContent = `${orderMode === "margin" ? "Size" : "Quantity"} (${market.baseToken})`;
    updateOrderSideUI();
  }

  // Show cached data instantly if available; indicate staleness if > 10s old
  const cached = marketDataCache[marketId];
  const hasCached = cached && cached.timestamp;
  const isStale = hasCached && (Date.now() - cached.timestamp >= 10000);

  if (hasCached && cached.orderBook) {
    renderOrderBook(cached.orderBook);
  } else {
    document.getElementById("orderbook-asks").innerHTML = '';
    document.getElementById("orderbook-bids").innerHTML = '';
    document.getElementById("orderbook-spread").innerHTML =
      '<span class="ob-spread-label">Spread</span><span class="ob-spread-abs">—</span><span class="ob-spread-pct"></span>';
  }

  if (hasCached && cached.trades) {
    renderTrades(cached.trades);
  } else {
    document.getElementById("recent-trades").innerHTML = '';
  }

  // Show "updating" badge on stale panels; hide once fresh data arrives
  setStaleIndicator("orderbook-stale", isStale || !hasCached);
  setStaleIndicator("trades-stale", isStale || !hasCached);

  renderMarketDropdown();
  // Always refresh in the background to get latest data
  pollMarketStatus();
  refreshUserOrders();
}

async function executeSwap() {
  // Not signed in → route the click to Internet Identity login instead of
  // silently returning. The button is a "Sign In" CTA in that state.
  if (!appState.isAuthenticated) { login(); return; }
  if (!appState.actor) return;

  const fromToken = document.getElementById("swap-from-token").value;
  const toToken   = document.getElementById("swap-to-token").value;
  const amount    = parseFloat(document.getElementById("swap-from-amount").value);

  if (!amount || amount <= 0) {
    showToast("Enter a valid amount", "error");
    return;
  }
  if (fromToken === toToken) {
    showToast("Cannot swap same token", "error");
    return;
  }

  // Defensive guard: if the last preview showed partial fill and the user has
  // "No partial fulfillment" checked, refuse before calling the backend
  // (which would reject with an error anyway). Handles the rare race where
  // the book shrank between preview and click.
  const noPartial = document.getElementById("no-partial-fill").checked;
  if (noPartial && lastSwapEstimate && !lastSwapEstimate.filled &&
      lastSwapEstimate.fromAmount === amount &&
      lastSwapEstimate.fromToken  === fromToken &&
      lastSwapEstimate.toToken    === toToken) {
    showToast(`Insufficient liquidity: only ${formatNum(lastSwapEstimate.consumedFrom)} ${fromToken} can be swapped`, "error");
    return;
  }

  const btn = document.getElementById("swap-execute-btn");
  btn.disabled = true;
  btn.innerHTML = '<span class="spinner"></span> Swapping...';

  try {
    // Market orders only — the Limit UI was removed 2026-07-08 pending the
    // swap-limit design (docs/swap-limit-orders-design.md); the backend
    // #limitOrder path still exists for when it returns.
    const request = {
      fromToken,
      toToken,
      amount: toE8(amount),
      mode: { marketOrder: { maxSlippage: toE8(maxSlippage) } },
      noPartialFill: document.getElementById("no-partial-fill").checked,
    };

    const result = await appState.actor.swap(request);

    if (result.ok) {
      const r = result.ok;
      // Sealed-until-GEPTOR: a partial-OK swap is STAGED (fromAmount 0 + a staged
      // order id) and clears at the next price update (~1s).
      const staged = Number(r.fromAmount) < 0.0000001 && (r.swapOrderId || []).length > 0;
      showToast(
        staged
          ? `Swap ${formatNum(amount)} ${fromToken} → ${toToken} staged — clears at next price (~1s)`
          : `Swapped ${formatNum(r.fromAmount)} ${fromToken} for ${formatNum(r.toAmount)} ${toToken}${r.fullyFilled ? "" : " (partial)"}`,
        "success"
      );
      // A staged swap releases asynchronously (on the next GEPTOR). Poll its
      // outcome so the user is told if it filled, partly filled, or couldn't fill
      // within slippage — instead of it silently disappearing.
      if (staged && (r.swapOrderId || []).length > 0) {
        watchSwapOutcome(Number(r.swapOrderId[0]));
      }
      document.getElementById("swap-from-amount").value = "";
      const toAmountEl = document.getElementById("swap-to-amount");
      toAmountEl.value = "";
      toAmountEl.classList.remove("estimated");
      document.getElementById("swap-preview").style.display = "none";
      refreshBalances();
      refreshUserOrders();
    } else {
      showToast(result.err, "error");
    }
  } catch (e) {
    showToast("Swap failed: " + e.message, "error");
  } finally {
    btn.disabled = false;
    btn.textContent = "Swap";
  }
}

// Poll a staged cross-swap's outcome and toast what actually happened. The
// backend records the caller's latest swap outcome; we match on id so we report
// THIS swap. ~24s window covers the GEPTOR release + the 15s users-only fallback.
async function watchSwapOutcome(swapId) {
  if (!appState.actor || !appState.actor.getMyRecentSwap) return;
  for (let i = 0; i < 16; i++) {
    await new Promise((res) => setTimeout(res, 1500));
    let o;
    try { o = await appState.actor.getMyRecentSwap(); } catch { continue; }
    o = (o && o[0]) || null;
    if (!o || Number(o.id) !== swapId) continue;
    if (o.filled) {
      const extra = o.note ? ` — ${o.note}` : "";
      showToast(`Swapped ${formatNum(Number(o.fromAmount))} ${o.fromToken} → ${formatNum(Number(o.toAmount))} ${o.toToken}${extra}`, "success");
    } else {
      showToast(`Swap didn't complete — ${o.note || "no liquidity within slippage; funds returned"}`, "error");
    }
    refreshBalances();
    refreshUserOrders();
    return;
  }
}

// ── Underlying market trades beneath the swap box ──
// Shows the real trades on the market this swap routes through (the asset being
// acquired, or sold if swapping to ICPUSD), so the user sees live activity —
// including a thin/expensive destination market that might stall their swap.
let swapMarketTimer = null;
let swapMarketTab = null;            // "src-book" | "src-trades" | "dst-book" | "dst-trades"
let swapMarketLastTradeIds = new Set();
let swapRenderedTrades = [];         // rendered swap-box trades (newest-first) for the 1s time/opacity ticker
let swapBookPrevAsk = {}, swapBookPrevBid = {}, swapBookPrevMkt = null;   // order-book change-flash baseline
let lastSwapBookSnap = null;         // cached raw snapshot → instant re-render on a granularity/Σ change
let swapBookMarket = null;           // market currently shown in the swap book (per-market granularity key)
// The swap book's own aggregation state — same controls as the Markets book but
// independent memory, so changing one page never surprises the other.
let swapObGranByMarket = {};         // marketId → last-used granularity in the swap book
let swapObCumulative = true;         // Σ cumulative-depth toggle (on by default, like Markets)

// Last-known Sell/Buy token values, so a same-asset pick can FLIP instead of
// producing a degenerate BTC→BTC pair (which has no market → the chart and
// book/trades box vanish). Seeded from the selects when the listeners attach.
let _swapPrevFrom = null;
let _swapPrevTo = null;

// One change handler for both Swap token selects. If the pick collides with the
// other side, the OTHER side takes THIS side's previous asset — a flip (same as
// the reverse arrow), so both assets are preserved and the pair is never
// same→same. The flip dispatches a change on the other select, which re-enters
// here for that side and runs the single refresh; this call then returns.
function onSwapTokenChange(which) {
  const from = document.getElementById("swap-from-token");
  const to   = document.getElementById("swap-to-token");
  if (from.value === to.value) {
    if (which === "from") { to.value = _swapPrevFrom; to.dispatchEvent(new Event("change", { bubbles: true })); }
    else                  { from.value = _swapPrevTo; from.dispatchEvent(new Event("change", { bubbles: true })); }
    _swapPrevFrom = from.value; _swapPrevTo = to.value;
    return;   // the dispatched change above already refreshed for the resolved pair
  }
  _swapPrevFrom = from.value; _swapPrevTo = to.value;
  updateSwapBalances(); scheduleSwapPreview(); swapMarketTab = null; refreshSwapMarketBox(); refreshSwapGraph(true);
}

// Source / destination assets of the current swap and their markets. An asset's
// market is "<ASSET>-ICPUSD"; ICPUSD itself is the quote (cash) and has no
// standalone market, so its market is null.
function swapMarketAssets() {
  const src = document.getElementById("swap-from-token")?.value || null;
  const dst = document.getElementById("swap-to-token")?.value || null;
  const mkt = (a) => (a && a !== "ICPUSD") ? `${a}-ICPUSD` : null;
  return { src, dst, srcMkt: mkt(src), dstMkt: mkt(dst) };
}
// Default tab = the source book, unless the source is the ICPUSD quote (no
// market), in which case fall back to the destination book.
function defaultSwapMarketTab(as) { return as.srcMkt ? "src-book" : (as.dstMkt ? "dst-book" : "src-book"); }

function setSwapMarketTab(tab) {
  swapMarketTab = tab;
  swapMarketLastTradeIds = new Set();   // switching panes shouldn't flash every row
  refreshSwapMarketBox();
}

// Render the active tab's order book or recent trades for the source/dest asset.
async function refreshSwapMarketBox() {
  const section = document.getElementById("swap-market-section");
  const body = document.getElementById("swap-market-body");
  const a = appState.publicActor || appState.actor;
  if (!section || !body) return;
  const as = swapMarketAssets();
  if (!as.src || !as.dst || as.src === as.dst || !a) { section.style.display = "none"; return; }
  section.style.display = "";

  // Only show tabs for assets that have a market. ICPUSD is the quote (cash)
  // leg with no standalone market, so its Book/Trades tabs are hidden. (Both
  // sides ICPUSD ⇒ src===dst ⇒ the whole box is hidden above.)
  const vis = { "src-book": !!as.srcMkt, "src-trades": !!as.srcMkt, "dst-book": !!as.dstMkt, "dst-trades": !!as.dstMkt };
  const lbl = { "src-book": `${as.src} Book`, "src-trades": `${as.src} Trades`, "dst-book": `${as.dst} Book`, "dst-trades": `${as.dst} Trades` };
  document.querySelectorAll("#swap-market-tabs .smt-tab").forEach((b) => {
    b.style.display = vis[b.dataset.smt] ? "" : "none";
    b.textContent = lbl[b.dataset.smt] || b.textContent;
  });

  // Keep the active tab on a visible (market-bearing) tab.
  if (!swapMarketTab || !vis[swapMarketTab]) swapMarketTab = defaultSwapMarketTab(as);
  document.querySelectorAll("#swap-market-tabs .smt-tab").forEach((b) => b.classList.toggle("active", b.dataset.smt === swapMarketTab));

  const isSrc = swapMarketTab.startsWith("src");
  const isBook = swapMarketTab.endsWith("book");
  const market = isSrc ? as.srcMkt : as.dstMkt;
  // The aggregation toolbar belongs to the order book only (hidden on Trades).
  const toolbar = document.getElementById("swap-ob-toolbar");
  if (toolbar) toolbar.style.display = isBook ? "" : "none";
  try {
    if (isBook) { renderSwapBook(body, await a.getOrderBookDepth(market, [OB_FETCH_DEPTH]), market); }
    else        { renderSwapMarketTrades(body, await a.getRecentTrades(market)); }
  } catch (_) { body.innerHTML = `<div class="swap-market-empty">Couldn’t load ${fmtMarketId(market)}.</div>`; }
}

// Compact order book with the SAME aggregation controls as the Markets book: a
// price-interval (granularity) dropdown + the Σ cumulative toggle, driven by the
// same shared bucketLevels() so both books behave identically. State is the
// swap book's own (swapObGranByMarket / swapObCumulative), remembered per-market.
// Rows flash on a size change; the best ask hugs the spread.
function renderSwapBook(body, snap, market) {
  lastSwapBookSnap = snap;      // cache for instant re-render on a control change
  swapBookMarket = market;      // which market a granularity pick applies to

  // Change-flash: reset the baseline when the market (tab) changes so a switch
  // doesn't flash every row; only flash once a baseline for THIS market exists.
  if (market !== swapBookPrevMkt) { swapBookPrevAsk = {}; swapBookPrevBid = {}; swapBookPrevMkt = market; }
  // Bucket + cumulate + flash + bar scaling — the SAME pipeline the Markets
  // book runs (obPrepare), so the two can't drift apart again.
  const g = swapObGranByMarket[market] || 0;
  const prep = obPrepare(snap.asks, snap.bids, {
    granularity: g, cumulative: swapObCumulative,
    prevAsk: swapBookPrevAsk, prevBid: swapBookPrevBid,
  });
  const { asks, bids, qtyDp } = prep;
  const dp = prep.priceDp;
  const fmtP = (p) => p.toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });
  const fmtQ = (q) => q.toLocaleString("en-US", { minimumFractionDigits: qtyDp, maximumFractionDigits: qtyDp });
  const row = (l, side) => {
    const pct = l.barPct;
    // Sheen matching the Markets book bars: bright anchored edge → dim tip.
    const edge = side === "ask" ? "rgba(240,122,108,0.32)" : "rgba(94,230,180,0.32)";
    const tip  = side === "ask" ? "rgba(240,122,108,0.10)" : "rgba(94,230,180,0.10)";
    const bg = `background-image:linear-gradient(to left,${edge} 0%,${tip} ${pct}%,transparent ${pct}%)`;
    const flash = l.changed ? ` ob-flash-${side}` : "";
    return `<div class="swap-ob-row ${side}${flash}" style="${bg}"><span class="p">${fmtP(l.price)}</span><span class="q">${fmtQ(l.quantity)}</span><span class="v">${Math.round(l.price * l.quantity).toLocaleString("en-US")}</span></div>`;
  };
  const asksHtml = asks.length ? asks.slice().reverse().map((l) => row(l, "ask")).join("") : `<div class="swap-ob-empty">no asks</div>`;
  const bidsHtml = bids.length ? bids.map((l) => row(l, "bid")).join("") : `<div class="swap-ob-empty">no bids</div>`;
  // Spread row — identical content + styling to the Markets order book (reuses
  // .orderbook-spread): "Spread" legend, absolute spread, and percent of mid.
  // asks[0] is the best (lowest) ask; bids[0] is the best (highest) bid.
  const bestAsk = asks.length ? asks[0].price : 0;
  const bestBid = bids.length ? bids[0].price : 0;
  let spreadHtml;
  if (bestAsk > 0 && bestBid > 0 && bestAsk >= bestBid) {
    const spreadAbs = bestAsk - bestBid;
    const mid = (bestAsk + bestBid) / 2;
    const spreadPct = mid > 0 ? (spreadAbs / mid) * 100 : 0;
    spreadHtml = `<span class="ob-spread-label">Spread</span><span class="ob-spread-abs">${fmtP(spreadAbs)}</span><span class="ob-spread-pct">${spreadPct.toFixed(3)}%</span>`;
  } else {
    spreadHtml = `<span class="ob-spread-label">Spread</span><span class="ob-spread-abs">—</span><span class="ob-spread-pct"></span>`;
  }
  // Column headers track the mode, like the Markets book: aggregation →
  // Quantity | Value; per-level → Amount | Cost.
  const qtyLbl = swapObCumulative ? "Quantity" : "Amount";
  const valLbl = swapObCumulative ? "Value" : "Cost";
  body.innerHTML =
    `<div class="swap-ob-cols"><span>Price</span><span>${qtyLbl}</span><span>${valLbl}</span></div>` +
    `<div class="swap-ob swap-ob-asks">${asksHtml}</div>` +
    `<div class="orderbook-spread">${spreadHtml}</div>` +
    `<div class="swap-ob swap-ob-bids">${bidsHtml}</div>`;
  // Best ask hugs the spread: snap the asks region to its bottom each render
  // (like the Markets book) so the near-spread levels are what's shown and the
  // deeper asks scroll up out of view. Bids default to the top (best bid first).
  const asksEl = body.querySelector(".swap-ob-asks");
  if (asksEl) asksEl.scrollTop = asksEl.scrollHeight;
  // Sync the toolbar (a stable sibling of `body`): options for this price,
  // active label, and Σ button state.
  fillGranMenu(document.getElementById("swap-ob-gran-menu"), bestAsk || bestBid, g);
  const granLbl = document.getElementById("swap-ob-gran-label");
  if (granLbl) granLbl.textContent = granLabelText(g);
  document.getElementById("swap-ob-cumulative")?.classList.toggle("active", swapObCumulative);
  // Baseline for the next render's change-flash (display-precision keys).
  swapBookPrevAsk = prep.nextAskBaseline;
  swapBookPrevBid = prep.nextBidBaseline;
}

// Re-render the swap book from the cached snapshot — instant feedback when the
// user changes granularity or toggles Σ, with no refetch (like the Markets book
// re-rendering from lastOrderBookSnapshot).
function rerenderSwapBook() {
  const body = document.getElementById("swap-market-body");
  if (body && lastSwapBookSnap && swapMarketTab && swapMarketTab.endsWith("book")) {
    renderSwapBook(body, lastSwapBookSnap, swapBookMarket);
  }
}

function renderSwapMarketTrades(body, trades) {
  if (!trades.length) { body.innerHTML = '<div class="swap-market-empty">No recent trades</div>'; swapMarketLastTradeIds = new Set(); swapRenderedTrades = []; return; }
  const chrono = [...trades];               // oldest-first
  const dirs = []; let last = "buy";
  for (let i = 0; i < chrono.length; i++) {
    if (i > 0) { if (chrono[i].price > chrono[i - 1].price) last = "buy"; else if (chrono[i].price < chrono[i - 1].price) last = "sell"; }
    dirs.push(last);
  }
  const sorted = [...chrono].reverse().slice(0, 30);   // newest first — enough to fill the desktop box; mobile scrolls
  const sdirs  = [...dirs].reverse().slice(0, 30);
  const ids = new Set(sorted.map((t) => String(t.id)));
  const dp = priceDecimals(sorted.map((t) => t.price));
  // Size decimals = integer digits of the price — the same rule as the order
  // book's Quantity column and the Markets Trades list.
  const repPrice = sorted.length ? Math.max(...sorted.map((t) => Math.abs(t.price))) : 0;
  const qtyDp = repPrice >= 1 ? String(Math.floor(repPrice)).length : 1;
  const fmtQ = (q) => q.toLocaleString("en-US", { minimumFractionDigits: qtyDp, maximumFractionDigits: qtyDp });
  const now = Date.now();
  body.innerHTML =
    `<div class="swap-trades-cols"><span>Price</span><span>Size</span><span>Time</span></div>` +
    `<div class="swap-trades-list">` +
    sorted.map((t, i) => {
      const isNew = swapMarketLastTradeIds.size > 0 && !swapMarketLastTradeIds.has(String(t.id));
      const cls = ["swap-trade-row", `dir-${sdirs[i]}`, isNew ? "is-new" : ""].join(" ").trim();
      const priceTxt = t.price.toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });
      // Fresh trades' times start faded and ramp up — same age-based ramp as
      // the Markets Trades list (tickTradeTimes), capped at the rows' resting
      // span opacity (0.9).
      const tMs = typeof t.timestamp === "bigint" ? Number(t.timestamp / 1000000n) : Number(t.timestamp) / 1000000;
      const ago = now - tMs;
      const opacity = ago < 10000 ? Math.min((Math.floor(ago / 1000) + 1) * 0.1, 0.9) : 0.9;
      return `<div class="${cls}"><span class="p">${priceTxt}</span><span class="q">${fmtQ(t.quantity)}</span><span class="t" style="opacity:${opacity}">${formatTime(t.timestamp)}</span></div>`;
    }).join("") +
    `</div>`;
  swapMarketLastTradeIds = ids;
  swapRenderedTrades = sorted;   // the 1s ticker (tickTradeTimes) ages these in place
}

function startSwapMarketPoll() {
  stopSwapMarketPoll();
  swapMarketTimer = setInterval(() => {
    if (document.getElementById("swap-view")?.classList.contains("active")) refreshSwapMarketBox();
  }, 2000);   // match the Markets book cadence (AMM requotes ~2s)
  // Rate graph: refresh now, then follow the backend's clock-fill cadence
  // (a new zero-volume candle lands each minute) — no point polling faster.
  refreshSwapGraph(true);
  swapGraphTimer = setInterval(() => {
    if (document.getElementById("swap-view")?.classList.contains("active")) refreshSwapGraph();
  }, 60000);
}
function stopSwapMarketPoll() {
  if (swapMarketTimer) { clearInterval(swapMarketTimer); swapMarketTimer = null; }
  if (swapGraphTimer)  { clearInterval(swapGraphTimer);  swapGraphTimer = null; }
}

// ── Swap rate graph ("1 FROM = X TO" history) ────────────────────
// Second box on the Swap page (Swap, Graph, Book/Trades). Direct pairs plot
// the market's own close series, anchored on the non-ICPUSD asset (the
// familiar "1 BTC = $X" whichever direction the swap runs); cross pairs
// divide the legs' closes bucket-by-bucket — bucket boundaries are the same
// wall-clock formula for every market, so closes align exactly. A LINE of
// closes, not candles: dividing two OHLC series fabricates highs/lows the
// ratio never traded at. The backend's zero-volume clock-fill keeps both legs
// gapless; buckets missing from either leg (downtime) are skipped honestly.
let swapGraphChart = null;
let swapGraphSeries = null;
let swapGraphInterval = 3600000;   // 1H default (300d retention backend-side)
let swapGraphTimer = null;
let swapGraphKey = null;           // "BASE→QUOTE@interval" — fit the view only when this changes

// Which ratio to plot for the current token pair: base = the anchor asset
// (1 base = X quote). Same anchoring rule as the swap-preview rate line.
function swapGraphAnchor() {
  const from = document.getElementById("swap-from-token")?.value;
  const to   = document.getElementById("swap-to-token")?.value;
  if (!from || !to || from === to) return null;
  if (from === "ICPUSD") return { base: to, quote: "ICPUSD" };
  return { base: from, quote: to };
}

async function refreshSwapGraph(pairChanged = false) {
  const section = document.getElementById("swap-graph-section");
  if (!section) return;
  const src = appState.actor || appState.publicActor;
  const anchor = swapGraphAnchor();
  if (!src || !anchor) { section.style.display = "none"; swapGraphKey = null; return; }
  const key = `${anchor.base}→${anchor.quote}@${swapGraphInterval}`;

  // Show the CHROME immediately — an empty chart (axes, grid, background)
  // reads as "loading" where a hidden box reads as broken. The line lands
  // when the candles do (~a second on a cold load). On a pair/interval
  // change, clear the stale line right away so the old pair's data never
  // sits under the new pair's title.
  section.style.display = "";
  ensureSwapGraphChart();
  if (key !== swapGraphKey) {
    document.getElementById("swap-graph-title").textContent = `1 ${anchor.base} = … ${anchor.quote}`;
    if (swapGraphSeries && swapGraphKey !== null) swapGraphSeries.setData([]);
  }

  try {
    const [baseResp, quoteResp] = await Promise.all([
      src.getCandles(`${anchor.base}-ICPUSD`, swapGraphInterval, 0),
      anchor.quote === "ICPUSD"
        ? Promise.resolve(null)
        : src.getCandles(`${anchor.quote}-ICPUSD`, swapGraphInterval, 0),
    ]);
    // Late responses for a pair the user has already left must not paint.
    if (key !== `${swapGraphAnchor()?.base}→${swapGraphAnchor()?.quote}@${swapGraphInterval}`) return;

    let points;
    if (!quoteResp) {
      points = baseResp.candles.map((c) => ({
        time: Math.floor(Number(c.time) / 1_000_000_000),
        value: c.close,
      }));
    } else {
      const quoteClose = new Map();
      for (const c of quoteResp.candles) {
        quoteClose.set(Math.floor(Number(c.time) / 1_000_000_000), c.close);
      }
      points = [];
      for (const c of baseResp.candles) {
        const t = Math.floor(Number(c.time) / 1_000_000_000);
        const q = quoteClose.get(t);
        if (q > 0) points.push({ time: t, value: c.close / q });
      }
    }
    if (!points.length) { return; }   // keep the empty chrome — honest "no data yet"

    const last = points[points.length - 1].value;
    document.getElementById("swap-graph-title").textContent =
      `1 ${anchor.base} = ${formatNum(last)} ${anchor.quote}`;

    if (!swapGraphChart) return;   // container not laid out yet — next tick catches it
    // Ratios span magnitudes (BTC/ICP ~1e4, ICP/BTC ~1e-4): pick axis
    // precision from the latest value so small ratios don't render as 0.00.
    const precision = last >= 1000 ? 2 : last >= 1 ? 4 : 8;
    swapGraphSeries.applyOptions({
      priceFormat: { type: "price", precision, minMove: Math.pow(10, -precision) },
    });
    swapGraphSeries.setData(points);
    if (pairChanged || key !== swapGraphKey) swapGraphChart.timeScale().fitContent();
    swapGraphKey = key;
  } catch (e) {
    console.warn("swap rate graph:", e);   // keep the chrome; the 60s tick retries
  }
}

function ensureSwapGraphChart() {
  if (swapGraphChart) return;
  const el = document.getElementById("swap-graph-canvas");
  if (!el) return;
  swapGraphChart = createChart(el, {
    width: el.clientWidth,
    height: el.clientHeight || 220,
    layout: {
      background: { type: "solid", color: "transparent" },
      textColor: "#7A8699",
      fontSize: 11,
    },
    grid: { vertLines: { color: "rgba(34,46,64,0.4)" }, horzLines: { color: "rgba(34,46,64,0.4)" } },
    crosshair: {
      mode: 0,
      vertLine: { color: "rgba(59,184,212,0.5)", width: 1, style: 2 },
      horzLine: { color: "rgba(59,184,212,0.5)", width: 1, style: 2 },
    },
    localization: {
      timeFormatter: (time) => {
        const d = new Date(time * 1000);
        return d.toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false });
      },
    },
    timeScale: {
      borderColor: "rgba(34,46,64,0.5)",
      timeVisible: true,
      secondsVisible: false,
    },
    rightPriceScale: { borderColor: "rgba(34,46,64,0.5)", scaleMargins: { top: 0.12, bottom: 0.10 } },
    handleScroll: true,
    handleScale: true,
  });
  // Glacier line — the accent the synthetic (oracle-tracking) candles use,
  // honest about what this is: a ref-price rate line, not a trade tape.
  swapGraphSeries = swapGraphChart.addSeries(
    LineSeries,
    { color: "rgba(56, 189, 240, 0.9)", lineWidth: 2, priceLineVisible: true, lastValueVisible: true },
  );
  // Re-fit once on the first real layout: the chart may be created while the
  // tab is backgrounded (0×0), and a fitContent computed then leaves the data
  // squashed into a corner (same fix as the Markets mini chart).
  let roFirstRealResize = true;
  const ro = new ResizeObserver(() => {
    if (!swapGraphChart) return;
    const w = el.clientWidth, h = el.clientHeight;
    if (w > 0 && h > 0) {
      swapGraphChart.applyOptions({ width: w, height: h });
      if (roFirstRealResize) {
        roFirstRealResize = false;
        swapGraphChart.timeScale().fitContent();
      }
    }
  });
  ro.observe(el);
}

// ── Margin mode: open a position from the Place Order box ────────
// The box doubles as a position-entry surface so the trader keeps the chart,
// order book and depth in view (Spot|Margin toggle). Spot trades the Wallet;
// Margin opens a leveraged / short position in a margin pool via openPosition,
// reusing the same Limit/Market + price + size + slippage controls. Long ⇄ Buy,
// Short ⇄ Sell at the engine level (a long buys base, a short sells borrowed base).

// The margin pool the box will open into. Defaults to the first pool; the
// dropdown lets a multi-pool user pick. Empty selection (no pools yet) → null,
// and submit auto-creates a default cross pool.
function selectedOrderPool() {
  const sel = document.getElementById("order-pool");
  if (!sel || !sel.value) return _poolsCache[0] || null;
  return _poolsCache.find((p) => String(Number(p.id)) === String(sel.value)) || _poolsCache[0] || null;
}

// Repopulate the box's pool dropdown from _poolsCache (shared with the Account
// Positions box), preserving the current selection.
function refreshOrderPoolSelect() {
  const sel = document.getElementById("order-pool");
  if (!sel) return;
  const prev = sel.value;
  if (!_poolsCache || _poolsCache.length === 0) {
    sel.innerHTML = `<option value="">New pool (auto)</option>`;
  } else {
    const esc = (s) => String(s).replace(/[<>&"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" }[c]));
    sel.innerHTML = _poolsCache.map((p) => `<option value="${Number(p.id)}">${esc(p.name)} · ${p.isolated ? "isolated" : "cross"}</option>`).join("");
    if (prev && _poolsCache.some((p) => String(Number(p.id)) === prev)) sel.value = prev;
  }
}

// Apply the Spot|Margin mode to the box: toggle the margin-only controls, relabel
// the side buttons (Buy/Sell ⇄ Long/Short), and refresh the preview + button.
function applyOrderMode() {
  const isMargin = orderMode === "margin";
  document.querySelectorAll(".order-mode-btn").forEach((b) => b.classList.toggle("active", b.dataset.mode === orderMode));
  const mc = document.getElementById("margin-controls");
  if (mc) mc.style.display = isMargin ? "" : "none";
  const prev = document.getElementById("margin-preview");
  if (prev) prev.style.display = isMargin ? "" : "none";
  // Relabel side buttons. Long stays green (buy), Short stays red (sell).
  const buyBtn  = document.querySelector('.side-btn[data-side="buy"]');
  const sellBtn = document.querySelector('.side-btn[data-side="sell"]');
  if (buyBtn)  buyBtn.textContent  = isMargin ? "Long"  : "Buy";
  if (sellBtn) sellBtn.textContent = isMargin ? "Short" : "Sell";
  const market = markets.find((m) => m.id === selectedMarket);
  const lbl = document.getElementById("order-qty-label");
  if (lbl && market) lbl.textContent = `${isMargin ? "Size" : "Quantity"} (${market.baseToken})`;
  if (isMargin) {
    refreshOrderPoolSelect();
    // Ensure the pool list is loaded even if the user never opened the Account
    // tab — renderPositions() refreshes _poolsCache and the dropdown.
    if (appState.isAuthenticated) renderPositions();
  }
  updateSpotTotalVisibility();
  updateOrderSideUI();
  updateOrderTotal();
}

// In margin mode the spot "Bid/Ask total" line is redundant with the position
// preview, so hide it; show it again in spot mode.
function updateSpotTotalVisibility() {
  const totalEl = document.querySelector(".order-panel .order-total");
  if (totalEl) totalEl.style.display = orderMode === "margin" ? "none" : "";
}

// Compute and render the position preview (notional, leverage, margin pulled,
// est. entry/liq price, est. slippage) and set the place button. Size is the
// Quantity field (base units); margin = notional / leverage is auto-pulled from
// the wallet on submit.
// Pool-capacity preview cache: previewOpenPosition is debounced and its
// verdict re-rendered synchronously while the inputs it answered for are
// unchanged. Seq guards stale replies.
let _poolPreviewKey = null;
let _poolPreviewRes = null;
let _poolPreviewTimer = null;
let _poolPreviewSeq = 0;

function updateMarginPreview() {
  const box = document.getElementById("margin-preview");
  const placeBtn = document.getElementById("place-order-btn");
  if (!box) return;
  const sideStr = orderSide === "buy" ? "long" : "short";
  const size = parseFloat(document.getElementById("order-quantity").value) || 0;
  const lev  = parseFloat(document.getElementById("order-leverage")?.value || "1") || 1;
  const market = markets.find((m) => m.id === selectedMarket);
  const base = market ? market.baseToken : "";

  // Entry estimate: limit → the limit price; market → VWAP from live depth.
  const isLimit = orderType === "limit";
  const limitPx = parseFloat(document.getElementById("order-price").value) || 0;
  let entry, slipPct = null, exhausted = false;
  if (isLimit) {
    entry = limitPx;
  } else {
    const f = estimateFill(selectedMarket, orderSide, size);
    entry = f.avg; exhausted = f.exhausted;
    if (f.mid > 0 && entry > 0) slipPct = Math.abs(entry - f.mid) / f.mid * 100;
  }

  if (!(size > 0) || !(entry > 0)) {
    box.innerHTML = `<span class="mp-muted">Enter a size${isLimit ? " and limit price" : ""} to preview the position.</span>`;
    if (placeBtn) {
      placeBtn.disabled = true;
      placeBtn.textContent = sideStr === "long" ? "Long" : "Short";
      placeBtn.style.background = "var(--bg-hover)";
      placeBtn.style.color = "var(--text-muted)";
    }
    return;
  }

  const notional = size * entry;
  const margin   = notional / lev;
  const oracle = market ? (market.markPrice > 0 ? market.markPrice : market.lastPrice) : 0;
  const slipSel = parseFloat(document.getElementById("order-slippage")?.value || "0.05") || 0.05;
  const cash     = userAvailBalances["ICPUSD"] || 0;   // spendable, net of reservations
  const pool     = selectedOrderPool();
  const free     = pool ? Number(pool.freeQuote) || 0 : 0;
  const need     = Math.max(0, margin - free);        // extra to pull from wallet
  const shortCash = need > cash + 0.0000001;          // not enough wallet cash

  // Pool-capacity verdict — ONE source of truth: previewOpenPosition runs
  // openPosition's exact gauntlet (isolated rules, price band, borrow need
  // net of pool holdings, the same BorrowEngine health check) with the
  // intended wallet top-up applied. The old client-side heuristic modeled
  // the position as if backed by nothing but its own margin and falsely
  // blocked e.g. a 1-SOL short against a pool with $27k free; it survives
  // only for the no-pool case below, where a fresh pool funded with
  // margin = notional/lev makes the standalone model exact.
  let poolWarn = "", poolBlocked = false, capacityRow = "", estLiq = null;
  if (appState.actor?.previewOpenPosition) {
    const key = [pool ? Number(pool.poolId) : "new", selectedMarket, sideStr, size, isLimit ? `l${limitPx}` : `s${slipSel}`, need.toFixed(2)].join("|");
    if (_poolPreviewKey === key && _poolPreviewRes) {
      const r = _poolPreviewRes;
      if (r.err) { poolBlocked = true; poolWarn = r.err; }
      else {
        estLiq = r.estLiqPrice;
        if (r.maxSizeBase > 0) {
          capacityRow = `<span class="mp-row"><span>Pool capacity</span><b>~${formatNum(r.maxSizeBase)} ${base}</b></span>`;
        }
        if (!r.canOpen) {
          poolBlocked = true;
          poolWarn = (r.reason || "The pool cannot take this position right now.")
            + (r.maxSizeBase > 0 ? ` Max ~${formatNum(r.maxSizeBase)} ${base} at this price.` : "");
        }
      }
    } else {
      clearTimeout(_poolPreviewTimer);
      const seq = ++_poolPreviewSeq;
      _poolPreviewTimer = setTimeout(async () => {
        try {
          const res = await appState.actor.previewOpenPosition(
            pool ? [BigInt(Number(pool.poolId))] : [], selectedMarket,
            sideStr === "long" ? { buy: null } : { sell: null },
            toE8(size), toE8(slipSel), isLimit ? [toE8(limitPx)] : [], toE8(need));
          if (seq !== _poolPreviewSeq) return;
          _poolPreviewRes = ("ok" in res)
            ? { canOpen: res.ok.canOpen, reason: res.ok.reason.length ? res.ok.reason[0] : null,
                maxSizeBase: Number(res.ok.maxSizeBase) / 1e8,
                estLiqPrice: res.ok.estLiqPrice.length ? Number(res.ok.estLiqPrice[0]) / 1e8 : null }
            : { err: res.err };
          _poolPreviewKey = key;
          updateMarginPreview();   // re-render with the verdict (key now matches)
        } catch { /* advisory — the backend re-checks at submit anyway */ }
      }, 250);
    }
  }

  const rows = [];
  rows.push(`<span class="mp-row"><span>Notional</span><b>${fmtUsd(notional)}</b></span>`);
  rows.push(`<span class="mp-row"><span>Margin (${lev}×)</span><b>${fmtUsd(margin)}</b></span>`);
  rows.push(`<span class="mp-row"><span>Est. entry</span><b>${fmtUsd(entry)}</b></span>`);
  rows.push(`<span class="mp-row"><span>Est. liq.</span><b>${estLiq != null ? fmtUsd(estLiq) : "—"}</b></span>`);
  if (capacityRow) rows.push(capacityRow);
  if (!isLimit && slipPct != null) {
    const sc = slipPct > 1 ? "mp-warn" : "";
    rows.push(`<span class="mp-row"><span>Est. slippage</span><b class="${sc}">${slipPct.toFixed(2)}%${exhausted ? " +" : ""}</b></span>`);
  }
  let warn = "";
  if (poolBlocked)    warn = poolWarn;
  else if (shortCash) warn = `Need ${fmtUsd(need)} margin — only ${fmtUsd(cash)} in wallet.`;
  else if (!isLimit && exhausted) warn = `Order book too thin for full size — slippage may be higher.`;
  box.innerHTML = `<div class="mp-grid">${rows.join("")}</div>${warn ? `<div class="mp-alert">${escH(warn)}</div>` : ""}`;

  if (placeBtn) {
    const blocked = poolBlocked || shortCash;
    placeBtn.disabled = blocked;
    placeBtn.textContent = sideStr === "long" ? "Open Long" : "Open Short";
    placeBtn.style.background = blocked ? "var(--bg-hover)" : (sideStr === "long" ? "var(--green)" : "var(--red)");
    placeBtn.style.color      = blocked ? "var(--text-muted)" : (sideStr === "long" ? "var(--green-text)" : "var(--red-text)");
    placeBtn.style.opacity = "";
  }
}

// Submit a margin position: ensure a funded pool, pull the margin shortfall from
// the wallet, then openPosition (limitPrice = [] for market, [px] for limit).
async function placeMarginPosition() {
  if (!appState.actor || !appState.isAuthenticated || !selectedMarket) return;
  const btn = document.getElementById("place-order-btn");
  const sideStr = orderSide === "buy" ? "long" : "short";
  const side = orderSide === "buy" ? { buy: null } : { sell: null };
  const size = parseFloat(document.getElementById("order-quantity").value) || 0;
  const lev  = parseFloat(document.getElementById("order-leverage")?.value || "1") || 1;
  const market = markets.find((m) => m.id === selectedMarket);
  const base = market ? market.baseToken : "";
  if (!(size > 0)) { showToast("Enter a position size > 0", "error"); return; }

  const isLimit = orderType === "limit";
  const limitPx = parseFloat(document.getElementById("order-price").value) || 0;
  if (isLimit && !(limitPx > 0)) { showToast("Enter a valid limit price", "error"); return; }
  if (isLimit) {
    const bandErr = priceBandError(selectedMarket, limitPx);
    if (bandErr) { showToast(bandErr, "error"); return; }
  }
  const entry = isLimit ? limitPx : estimateFill(selectedMarket, orderSide, size).avg;
  if (!(entry > 0)) { showToast("No price available — try again in a moment", "error"); return; }
  const margin = (size * entry) / lev;
  const slip = isLimit ? 0.05 : parseFloat(document.getElementById("order-slippage").value || "0.05");
  const limitOpt = isLimit ? [toE8(limitPx)] : [];

  btn.disabled = true;
  btn.innerHTML = '<span class="spinner"></span> Opening...';
  try {
    // 1. Ensure a pool. Use the selected one; if the user has none, create a
    //    default cross pool (capital-efficient; one pool backs many positions).
    let pool = selectedOrderPool();
    if (!pool) {
      const cr = await appState.actor.createMarginPool("Markets", false);
      if ("err" in cr) { showToast(cr.err, "error"); return; }
      await renderPositions();                  // repopulates _poolsCache
      refreshOrderPoolSelect();
      pool = _poolsCache.find((p) => String(Number(p.id)) === String(Number(cr.ok))) || _poolsCache[0];
      const sel = document.getElementById("order-pool");
      if (sel && pool) sel.value = String(Number(pool.id));
    }
    if (!pool) { showToast("Couldn't create a margin pool", "error"); return; }

    // 2. Top up the pool's free margin from the wallet if needed.
    const free = Number(pool.freeQuote) || 0;
    const need = margin - free;
    if (need > 0.0000001) {
      const cash = userBalances["ICPUSD"] || 0;
      if (need > cash + 0.0000001) { showToast(`Need ${fmtUsd(need)} more margin than your wallet holds`, "error"); return; }
      const fr = await appState.actor.fundMarginPool(BigInt(Number(pool.id)), toE8(need));
      if ("err" in fr) { showToast(fr.err, "error"); return; }
    }

    // 3. Open the position.
    const res = await appState.actor.openPosition(BigInt(Number(pool.id)), selectedMarket, side, toE8(size), toE8(slip), limitOpt);
    if ("err" in res) { showToast(res.err, "error"); return; }
    const coin = base || selectedMarket.split("-")[0];
    showToast(isLimit
      ? `${sideStr === "long" ? "Long" : "Short"} ${formatNum(size)} ${coin} limit @ ${fmtUsd(limitPx)} resting — fills with no slippage when the market reaches it.`
      : `${sideStr === "long" ? "Long" : "Short"} ${formatNum(size)} ${coin} opening — settles on the next price (~1–2s).`, "success");
    document.getElementById("order-quantity").value = "";
    if (isLimit) { document.getElementById("order-price").value = ""; savedOrderPrices[orderSide] = ""; }
    await Promise.all([refreshBalances(), renderPositions()]);
    refreshOrderPoolSelect();
    refreshUserOrders();
    if (uomTab === "positions") renderUserOrdersMobile();
    // The order releases on the next GEPTOR (~1–2s). If the release kills or
    // clamps it (initial-margin re-gate, FOK), the global checkReleaseRejections
    // watcher (driven by pollChanges on the user-version bump) toasts it — for
    // market AND late-filling resting limit entries alike.
    setTimeout(() => {
      renderPositions(); refreshUserOrders();
      if (uomTab === "positions") renderUserOrdersMobile();
    }, 2500);
    updateMarginPreview();
    updateOrderSideUI();
  } catch (e) {
    showToast("Position failed: " + e.message, "error");
  } finally {
    btn.disabled = false;
    if (orderMode === "margin") updateMarginPreview(); else { btn.textContent = orderSide === "buy" ? "Buy" : "Sell"; }
  }
}

// Fat-finger guard, mirroring the backend's 100× price band: a limit price
// more than 100× from the current mark is an input error (a lean on the
// keyboard, a paste), not an order. The backend rejects it too — this just
// fails fast, before the wallet round-trip, with a friendlier message.
function priceBandError(marketId, px) {
  const m = markets.find((x) => x.id === marketId);
  const mark = m ? (m.markPrice > 0 ? m.markPrice : m.lastPrice) : 0;
  if (!(mark > 0) || !(px > 0)) return null;
  if (px > mark * 100) return `Price is more than 100× above the mark (${formatPrice(mark)}) — check for a typo`;
  if (px * 100 < mark) return `Price is more than 100× below the mark (${formatPrice(mark)}) — check for a typo`;
  return null;
}

async function placeOrder() {
  if (!appState.actor || !appState.isAuthenticated || !selectedMarket) return;

  // Margin mode opens a leveraged / short position in a pool, not a spot trade.
  if (orderMode === "margin") { return placeMarginPosition(); }

  const price    = parseFloat(document.getElementById("order-price").value);
  const quantity = parseFloat(document.getElementById("order-quantity").value);
  const side     = orderSide === "buy" ? { buy: null } : { sell: null };

  const btn = document.getElementById("place-order-btn");

  // Spot is pure Wallet custody — no borrowing. Selling more base than you hold,
  // or buying for more cash than you hold, is a position: switch to Margin mode.
  btn.disabled = true;
  btn.innerHTML = '<span class="spinner"></span> Placing...';

  try {
    if (orderType === "limit") {
      if (!price || price <= 0 || !quantity || quantity <= 0) {
        showToast("Enter valid price and quantity", "error");
        return;
      }
      const bandErr = priceBandError(selectedMarket, price);
      if (bandErr) { showToast(bandErr, "error"); return; }
      // Advanced: optional self-expiry (GTC by default). [] = GTC; [secs] = expire after N seconds.
      const expSel = document.getElementById("order-expiry");
      const expSecs = expSel ? parseInt(expSel.value, 10) : 0;
      const expiryArg = expSecs > 0 ? [BigInt(expSecs)] : [];
      const result = await appState.actor.placeLimitOrderExp(selectedMarket, side, toE8(price), toE8(quantity), expiryArg);
      if (result.ok) {
        // Sealed-until-GEPTOR: the order is STAGED (off-book) and clears at the
        // next price update (~1s) — matching crossing orders + the fresh AMM,
        // with any remainder then resting on the book. It shows as "pending" in
        // Open Orders until then.
        showToast(`${orderSide === "buy" ? "Buy" : "Sell"} ${formatNum(quantity)} @ ${formatPrice(price)} staged — clears at next price (~1s)`, "success");
        document.getElementById("order-price").value = "";
        document.getElementById("order-quantity").value = "";
        savedOrderPrices[orderSide] = ""; // clear so it re-initializes from order book
      } else {
        showToast(result.err, "error");
      }
    } else {
      if (!quantity || quantity <= 0) {
        showToast("Enter a valid quantity", "error");
        return;
      }
      const slip   = parseFloat(document.getElementById("order-slippage").value);
      const result = await appState.actor.placeMarketOrder(selectedMarket, side, toE8(quantity), toE8(slip), false);
      if (result.ok) {
        const r = result.ok;
        const filled = Number(r.totalFilled);
        // Sealed-until-GEPTOR: a partial-OK market order is STAGED and clears at
        // the next price update (~1s) against users + the fresh AMM. (Filled>0
        // only on the all-or-nothing immediate path.)
        if (filled > 0) {
          showToast(`Market ${orderSide}: filled ${formatNum(filled)} @ avg ${formatPrice(r.avgPrice)}`, "success");
        } else {
          showToast(`Market ${orderSide} ${formatNum(quantity)} staged — clears at next price (~1s)`, "success");
        }
        document.getElementById("order-quantity").value = "";
      } else {
        showToast(result.err, "error");
      }
    }
    refreshBalances();
    pollMarketStatus();
    refreshUserOrders();
    updateOrderTotal();
    updateOrderSideUI();
  } catch (e) {
    showToast("Order failed: " + e.message, "error");
  } finally {
    btn.disabled = false;
    btn.textContent = orderSide === "buy" ? "Buy" : "Sell";
    btn.style.background = orderSide === "buy" ? "var(--green)" : "var(--red)";
    btn.style.color = orderSide === "buy" ? "var(--green-text)" : "var(--red-text)";
  }
}

async function cancelOrder(orderId) {
  if (!appState.actor) return;
  try {
    const result = await appState.actor.cancelMyOrder(orderId);
    if (result.ok !== undefined) {
      showToast("Order cancelled", "success");
    } else {
      showToast(result.err, "error");
    }
    refreshUserOrders();
    pollMarketStatus();
    refreshBalances();
  } catch (e) {
    showToast("Cancel failed: " + e.message, "error");
  }
}

// ── UI Updates ──────────────────────────────────────────────────
function updateUI() {
  const authBtn  = document.getElementById("auth-btn");
  const swapBtn  = document.getElementById("swap-execute-btn");
  const placeBtn = document.getElementById("place-order-btn");

  // Order form inputs
  const orderInputs = [
    document.getElementById("order-price"),
    document.getElementById("order-quantity"),
    document.getElementById("order-slippage"),
  ].filter(Boolean);

  // Order panel auth overlay
  const orderPanel = document.querySelector(".order-panel");
  let authOverlay = document.getElementById("order-auth-overlay");

  if (appState.isAuthenticated) {
    authBtn.textContent = "Sign Out";
    authBtn.className   = "btn btn-secondary";
    // Delegate Swap button text/disabled to updateSwapButtonState so the last
    // preview's filled/partial state is respected post-auth.
    updateSwapButtonState();
    placeBtn.className   = "btn btn-lg btn-primary";
    orderInputs.forEach((i) => { i.disabled = false; });
    // Button text/enabled derive from the order form's validity — spot via
    // updateOrderTotal, margin via updateMarginPreview (which it delegates to) —
    // rather than being force-enabled here (which let "Buy" click at qty 0).
    updateOrderTotal();
    document.querySelectorAll(".order-type-btn, .side-btn").forEach((b) => { b.disabled = false; });
    if (authOverlay) authOverlay.style.display = "none";
  } else {
    authBtn.textContent = "Sign In";
    authBtn.className   = "btn btn-primary";
    // Swap CTA stays enabled when signed out — clicking it triggers the
    // Internet Identity sign-in flow (see executeSwap).
    updateSwapButtonState();
    placeBtn.textContent = "Sign in to trade";
    placeBtn.disabled    = true;
    placeBtn.style.background = "";
    document.getElementById("balance-display").style.display = "none";
    orderInputs.forEach((i) => { i.disabled = true; });
    document.querySelectorAll(".order-type-btn, .side-btn").forEach((b) => { b.disabled = true; });

    // Create or show the auth overlay on the order panel
    if (orderPanel) {
      if (!authOverlay) {
        authOverlay = document.createElement("div");
        authOverlay.id = "order-auth-overlay";
        authOverlay.className = "order-auth-overlay";
        authOverlay.innerHTML = `
          <div class="order-auth-overlay-content">
            <div class="order-auth-icon">
              <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0110 0v4"/><circle cx="12" cy="16" r="1"/></svg>
            </div>
            <div class="order-auth-title">Sign in to start trading</div>
            <div class="order-auth-desc">Create an account with Internet Identity to place orders and access the full exchange</div>
            <button class="btn btn-primary order-auth-signin-btn" id="order-panel-signin-btn">Sign In</button>
          </div>
        `;
        orderPanel.style.position = "relative";
        orderPanel.appendChild(authOverlay);
        document.getElementById("order-panel-signin-btn").addEventListener("click", login);
      }
      authOverlay.style.display = "flex";
    }
  }

  renderAccountPage();
  updateOrderSideUI();
  dxOnAuthChange();   // reflect sign-in/out in the Data explorer's gate
  applyIntelliAuthGate();
}

// ── AI section: signed-out gate ──────────────────────────────────
// Everything in this section is caller-scoped — the assistant proxy is
// requireAuth (aiComplete), and every explorer query is bounded by the
// caller's identity — so signed out the section has nothing to answer with.
// Show the same sign-in card the Account/Earn panes use INSTEAD of the body,
// rather than presenting controls that can only fail. Called on every auth
// change and whenever the section is shown, so a sign-out while sitting on
// the page swaps it immediately.
function applyIntelliAuthGate() {
  const prompt = document.getElementById("intelli-signin-prompt");
  const view = document.getElementById("intelli-view");
  if (!prompt || !view) return;
  const authed = !!appState.isAuthenticated;
  prompt.style.display = authed ? "none" : "";
  for (const sel of [".intelli-head", ".intelli-tabs"]) {
    const el = view.querySelector(sel);
    if (el) el.style.display = authed ? "" : "none";
  }
  // Panes: signed out BOTH hide; signed in, restore the ACTIVE one only.
  // Blanket-showing them would defeat showIntelliTab's choice and render the
  // assistant and the explorer stacked on top of each other, since this runs
  // after it.
  const ex = document.getElementById("intelli-pane-explorer");
  const ai = document.getElementById("intelli-pane-ai");
  if (ex) ex.style.display = (authed && appState.intelliTab === "explorer") ? "" : "none";
  if (ai) ai.style.display = (authed && appState.intelliTab === "ai") ? "" : "none";
  // The AI pane makes the view a flex fill; with the body hidden that would
  // stretch the prompt card down the page.
  view.classList.toggle("intelli-fill", authed && appState.intelliTab === "ai");
}

// ── Column resizer (Markets page: chart | book-trades) ──────────
// Drag the vertical handle between the chart and the Order Book to adjust
// `--book-col-width`. Width is clamped to [220px, marketContentWidth − 700]
// so neither side collapses below a usable width. Persisted to localStorage
// so the preference sticks across reloads.
// Key is versioned: bumping it re-defaults everyone once (the default changed
// to match the Place Order column) while future drags persist as before.
const COL_RESIZER_STORAGE_KEY = "uplands.bookColWidth.v2";
const COL_RESIZER_MIN_PX = 220;
const COL_RESIZER_CHART_MIN_PX = 400; // reserve at least this much for chart + resizer + order-panel + gaps
function clampBookWidth(px, totalWidth) {
  const maxW = Math.max(COL_RESIZER_MIN_PX + 20, totalWidth - COL_RESIZER_CHART_MIN_PX - 280 - 20);
  return Math.min(maxW, Math.max(COL_RESIZER_MIN_PX, px));
}
function restoreBookColWidth() {
  const saved = localStorage.getItem(COL_RESIZER_STORAGE_KEY);
  if (!saved) return;
  const px = parseFloat(saved);
  if (!(px > 0)) return;
  const mc = document.querySelector(".market-content");
  if (!mc) return;
  const tw = mc.clientWidth || window.innerWidth;
  mc.style.setProperty("--book-col-width", clampBookWidth(px, tw) + "px");
}
// ── First-open width: fit Order Book + Trades side-by-side, if it's free ──
// Desktop opens the Markets page at the CSS default (280px), which is below
// the container-query threshold, so both panes arrive stacked behind a tab bar
// even on a wide monitor with room to spare. Give the column exactly the width
// at which the split engages — and not one pixel more than the market
// telemetry strip above the chart can survive, since widening this column
// steals from the chart column the header lives in and would fold the stats
// into their dropdown.
//
// Neither threshold is hardcoded. The split is a CONTAINER query on the panel
// (orderbook.css), so we ask the layout whether it engaged rather than
// duplicating its 520px and drifting when it changes; compaction is measured
// exactly as updateMarketHeaderMode does it. Cost is a handful of forced
// reflows, once, on a page that has just done a round of canister queries.
let _bookColAutoSized = false;
function autoSizeBookColumn(attempt = 0) {
  if (_bookColAutoSized) return;
  // A saved width is a deliberate user preference — never override it. Its
  // absence is precisely what "opened for the first time" means here.
  if (localStorage.getItem(COL_RESIZER_STORAGE_KEY)) { _bookColAutoSized = true; return; }
  // Not marked done: a narrow window that is later widened past the desktop
  // breakpoint should still get sized on its next visit to Markets.
  if (!window.matchMedia("(min-width: 901px)").matches) return;
  const mc = document.querySelector(".market-content");
  const panel = document.querySelector(".book-trades-panel");
  const body = panel?.querySelector(".bt-body");
  const header = document.querySelector(".market-content > .market-header");
  const tw = mc?.clientWidth || 0;
  // Landing straight on #markets runs this before the view has been laid out,
  // where clientWidth is 0 and NOTHING is measurable — the first version
  // silently gave up there and always fell back to the CSS default. Retry on
  // later frames instead, bounded so a page that never shows Markets doesn't
  // spin.
  const retry = () => { if (attempt < 120) requestAnimationFrame(() => autoSizeBookColumn(attempt + 1)); };
  if (!mc || !panel || !body || !header || !tw) { retry(); return; }

  const prev = mc.style.getPropertyValue("--book-col-width");
  const restore = () => {
    if (prev) { mc.style.setProperty("--book-col-width", prev); }
    else { mc.style.removeProperty("--book-col-width"); }
  };
  const apply = (px) => mc.style.setProperty("--book-col-width", px + "px");
  const splitEngaged = () => getComputedStyle(body).flexDirection === "row";
  const headerFits = () => {
    // Run the real mode logic at the candidate width: the header "survives"
    // as long as it stays out of the FULL compact dropdown — folding trailing
    // stats (24h Volume, Total Depth, …) into the overflow popup is normal
    // degradation, not the failure this constraint guards against.
    updateMarketHeaderMode();
    return !header.classList.contains("market-header-compact");
  };

  const maxW = clampBookWidth(Number.MAX_SAFE_INTEGER, tw);  // widest the resizer allows
  apply(maxW);
  if (!splitEngaged()) { restore(); retry(); return; }   // too narrow (or not populated yet)

  // Smallest width that still splits — binary search, so the chart keeps
  // every pixel the split doesn't need.
  let lo = COL_RESIZER_MIN_PX, hi = maxW;
  while (hi - lo > 2) {
    const mid = Math.round((lo + hi) / 2);
    apply(mid);
    if (splitEngaged()) { hi = mid; } else { lo = mid; }
  }
  apply(hi);

  // Hard constraint: telemetry must not be squeezed into the dropdown. If the
  // minimum split width already costs the header too much, the two goals don't
  // both fit — keep the default and leave the split to a manual drag.
  if (!headerFits()) { restore(); retry(); return; }
  // Only NOW is it settled. Marking done any earlier meant a transient layout
  // — measurable but not yet populated — silently consumed the one attempt and
  // left the column at its default forever.
  _bookColAutoSized = true;
}

function setupColResizer() {
  const resizer = document.getElementById("col-resizer");
  const mc = document.querySelector(".market-content");
  const bookPanel = document.querySelector(".book-trades-panel");
  if (!resizer || !mc || !bookPanel) return;

  restoreBookColWidth();
  // Frame-count retries are the wrong instrument here: on a busy replica the
  // markets view can stay hidden (clientWidth 0, nothing measurable) for
  // longer than any sane frame budget, and the budget then expires before the
  // one moment we actually need. Observe the container instead — it fires
  // exactly when the view gains a real size — and disconnect once sized.
  autoSizeBookColumn();
  if (typeof ResizeObserver !== "undefined") {
    const ro = new ResizeObserver(() => {
      autoSizeBookColumn();
      if (_bookColAutoSized) ro.disconnect();
    });
    ro.observe(mc);
  }

  let dragging = false;
  let startX = 0;
  let startWidth = 0;

  resizer.addEventListener("pointerdown", (e) => {
    // Only respond to primary button / primary touch.
    if (e.button !== undefined && e.button !== 0) return;
    dragging = true;
    startX = e.clientX;
    // Measure the rendered book-panel width directly. This is robust whether
    // --book-col-width was set inline (px) by a previous drag/restore or
    // resolved via the CSS calc() default — getPropertyValue returns the
    // SPECIFIED value (still calc(...)), which parseFloat can't handle.
    startWidth = bookPanel.getBoundingClientRect().width;
    resizer.setPointerCapture(e.pointerId);
    resizer.classList.add("dragging");
    mc.classList.add("resizing");
    e.preventDefault();
  });

  resizer.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    // Resizer sits to the LEFT of the book column: dragging left grows book,
    // dragging right shrinks it. Delta of `clientX - startX`; subtract from
    // startWidth.
    const delta = e.clientX - startX;
    const nextRaw = startWidth - delta;
    const next = clampBookWidth(nextRaw, mc.clientWidth);
    mc.style.setProperty("--book-col-width", next + "px");
  });

  const endDrag = (e) => {
    if (!dragging) return;
    dragging = false;
    resizer.classList.remove("dragging");
    mc.classList.remove("resizing");
    try { resizer.releasePointerCapture(e.pointerId); } catch {}
    // Persist final width — measure rendered panel to handle the calc() case.
    const finalPx = bookPanel.getBoundingClientRect().width;
    if (finalPx > 0) localStorage.setItem(COL_RESIZER_STORAGE_KEY, finalPx + "px");
  };
  resizer.addEventListener("pointerup", endDrag);
  resizer.addEventListener("pointercancel", endDrag);

  // Re-clamp on viewport resize so a persisted width doesn't exceed the new
  // available space. When there's no saved value, the CSS calc() default
  // tracks viewport size automatically — no JS needed.
  window.addEventListener("resize", () => {
    if (!localStorage.getItem(COL_RESIZER_STORAGE_KEY)) return;
    const cur = bookPanel.getBoundingClientRect().width;
    const next = clampBookWidth(cur, mc.clientWidth);
    if (Math.abs(next - cur) > 0.5) mc.style.setProperty("--book-col-width", next + "px");
  });
}

// ── Tab routing via URL hash ─────────────────────────────────────
// Supports: #swap, #account, #markets, #markets/<MARKET_ID>
// Market IDs are case-sensitive server-side (e.g. "BTC-ICPUSD"); the tab
// name is case-insensitive for convenience.
// ── Docs (multi-page documentation) ───────────────────────────────
// Page content lives in docs.js; registry order IS the story order. The
// sidebar, the welcome-page reading map and each page's prev/next pager are
// all rendered from that registry, so adding a page there is the only step
// needed to extend the docs. Routes: #docs (home = launch) and #docs/<slug>.
let docsCurrentSlug = null;   // slug currently rendered into #docs-page

const DOCS_HOME = "launch";   // page the bare #docs route lands on

const docsHref = (p) => (p.slug === DOCS_HOME ? "#docs" : `#docs/${p.slug}`);

function renderDocsSidebar() {
  const side = document.getElementById("docs-side");
  if (!side) return;
  const groups = DOCS_PARTS.map((label, i) => {
    const links = DOCS_PAGES.filter((p) => p.part === i)
      .map((p) => `<a class="docs-side-link" data-docs-slug="${p.slug}" data-nav="${p.nav}" href="${docsHref(p)}">${p.nav}</a>`)
      .join("");
    return `<div class="docs-side-group"><button type="button" class="docs-side-part">${label}</button>${links}</div>`;
  }).join("");
  side.innerHTML =
    `<input id="docs-filter" class="docs-filter" type="search" placeholder="Filter docs…" autocomplete="off">` + groups;
  document.getElementById("docs-filter")?.addEventListener("input", (e) => docsFilterNav(e.target.value));
  side.querySelectorAll(".docs-side-part").forEach((btn) => {
    btn.addEventListener("click", () => {
      const g = btn.closest(".docs-side-group");
      const open = !g.classList.toggle("collapsed");
      btn.setAttribute("aria-expanded", String(open));
    });
  });
  docsCollapseToDefault();
  if (docsCurrentSlug) {
    // Cold deep-link: docsRoute() may already have run before the sidebar
    // existed — restore the active link it would have set.
    side.querySelectorAll(".docs-side-link").forEach((a) => {
      a.classList.toggle("active", a.dataset.docsSlug === docsCurrentSlug);
    });
  }
}

// Collapse every part except the current page's (hierarchy default). The
// mobile chip row ignores collapse entirely — the hiding rule is desktop-only.
function docsCollapseToDefault() {
  const page = docsPage(docsCurrentSlug || DOCS_HOME);
  document.querySelectorAll("#docs-side .docs-side-group").forEach((g, i) => {
    const open = !!page && i === page.part;
    g.classList.toggle("collapsed", !open);
    g.querySelector(".docs-side-part")?.setAttribute("aria-expanded", String(open));
  });
}

// Sidebar quick-find: hide nav links whose page (title + full text) doesn't
// match. While a query is active every matching group is expanded so results
// are visible; clearing the box restores the default collapse.
function docsFilterNav(q) {
  const needle = (q || "").trim().toLowerCase();
  const side = document.getElementById("docs-side");
  if (!side) return;
  side.querySelectorAll(".docs-side-link").forEach((a) => {
    const page = docsPage(a.dataset.docsSlug);
    const hay = page
      ? (page.nav + " " + page.title + " " + page.blurb + " " + page.html.replace(/<[^>]+>/g, " ")).toLowerCase()
      : "";
    a.style.display = !needle || hay.includes(needle) ? "" : "none";
  });
  side.querySelectorAll(".docs-side-group").forEach((g) => {
    const any = [...g.querySelectorAll(".docs-side-link")].some((a) => a.style.display !== "none");
    g.style.display = any ? "" : "none";
    if (needle && any) {
      g.classList.remove("collapsed");
      g.querySelector(".docs-side-part")?.setAttribute("aria-expanded", "true");
    }
  });
  if (!needle) docsCollapseToDefault();
}

// Render the docs page for a #docs/<subpath> route (invalid/missing → home).
function docsRoute(subpath) {
  const slug = docsPage(subpath) ? subpath : DOCS_HOME;
  const page = docsPage(slug);
  const body = document.getElementById("docs-page");
  if (!body || !page) return;
  const changed = docsCurrentSlug !== slug;
  docsCurrentSlug = slug;
  if (changed) {
    const idx = DOCS_PAGES.indexOf(page);
    const prev = idx > 0 ? DOCS_PAGES[idx - 1] : null;
    const next = idx < DOCS_PAGES.length - 1 ? DOCS_PAGES[idx + 1] : null;
    const pager =
      `<nav class="docs-pager">` +
      (prev
        ? `<a class="docs-pager-link docs-pager-prev" href="${docsHref(prev)}"><span>← Previous</span><b>${prev.title}</b></a>`
        : `<span></span>`) +
      (next
        ? `<a class="docs-pager-link docs-pager-next" href="${docsHref(next)}"><span>Next →</span><b>${next.title}</b></a>`
        : `<span></span>`) +
      `</nav>`;
    body.innerHTML = page.html + pager +
      `<div class="docs-foot">MULTI/DEX — algorithmic exchange on the Internet Computer.</div>`;
    // Welcome page carries a reading map of every other page.
    const map = document.getElementById("docs-map");
    if (map) {
      map.innerHTML = DOCS_PAGES.filter((p) => p.slug !== "welcome").map((p) =>
        `<a class="docs-map-card" href="${docsHref(p)}">` +
        `<span class="docs-map-part">${DOCS_PARTS[p.part]}</span>` +
        `<span class="docs-map-title">${p.title}</span>` +
        `<span class="docs-map-blurb">${p.blurb}</span></a>`).join("");
    }
    // Between docs pages the view stays active, so activateTab's scroll reset
    // doesn't fire — reset explicitly.
    window.scrollTo(0, 0);
    document.getElementById("docs-view")?.scrollTo(0, 0);
  }
  document.querySelectorAll("#docs-side .docs-side-link").forEach((a) => {
    a.classList.toggle("active", a.dataset.docsSlug === slug);
  });
  // Accordion: landing on a page opens exactly its part. Parts the reader
  // toggles by hand stay put until the next navigation.
  if (changed) docsCollapseToDefault();
}

const VALID_TABS = new Set(["swap", "markets", "stats", "intelli", "ledger", "leaderboard", "account", "docs", "phase1"]);

// URL-facing hash slug ↔ internal tab token. The nav labels were renamed to
// Status / Intelligence, so the address bar should read #status / #intelligence
// — but the view element ids, CSS, and every `tabName === "stats"` check still
// key off the original tokens, so we translate only at the URL boundary. The
// old #stats / #intelli hashes still resolve (VALID_TABS lists the tokens and
// routeFromHash passes an unmapped slug straight through), so existing links
// and bookmarks keep working.
const ROUTE_TO_TAB = { system: "stats", status: "stats", ai: "intelli", intelligence: "intelli" };   // URL slug → internal token
const TAB_TO_ROUTE = { stats: "system", intelli: "ai" };                             // internal token → URL slug
// Nav items that are shortcuts INTO another section rather than sections of
// their own: Deposit and Earn live under Account. Resolved before VALID_TABS
// is consulted, so old #deposit links keep working.
const ROUTE_ALIASES = { deposit: "account/deposit", earn: "account/earn" };
// The sub-path a bare #<tab> lands on, so the URL always names the visible
// pane (deep links and back/forward stay meaningful).
const TAB_DEFAULT_SUB = { docs: "launch", stats: "overview", intelli: "assistant", account: "overview" };
// Intelligence inner tabs: URL slug ⇄ internal token (panes/gate keep ai|explorer).
const INTELLI_SLUG_TO_TOKEN = { assistant: "ai", memory: "explorer" };
const INTELLI_TOKEN_TO_SLUG = { ai: "assistant", explorer: "memory" };

// Parse the current URL hash into { tab, subpath }. Unknown tab → "swap".
function routeFromHash() {
  const raw = (window.location.hash || "").slice(1);
  if (!raw) return { tab: "swap", subpath: null };
  const slash0 = raw.indexOf("/");
  const head = (slash0 < 0 ? raw : raw.slice(0, slash0)).toLowerCase();
  // #deposit / #play are aliases for a path inside another section.
  const expanded = ROUTE_ALIASES[head] ? ROUTE_ALIASES[head] + (slash0 < 0 ? "" : raw.slice(slash0)) : raw;
  const slash = expanded.indexOf("/");
  const tabRaw = (slash < 0 ? expanded : expanded.slice(0, slash)).toLowerCase();
  const tab = ROUTE_TO_TAB[tabRaw] || tabRaw;   // #status→stats, #ai→intelli
  const subpath = slash < 0 ? null : expanded.slice(slash + 1) || null;
  return { tab: VALID_TABS.has(tab) ? tab : "swap", subpath };
}

// Activate a tab by name, optionally with a sub-path (e.g. a market ID for
// the Markets tab). Called on page load, on every hashchange, and
// indirectly via tab-button clicks.
// ── Provisional Phase I leaders (static snapshot page) ─────────────
// Renders assets/phase1-provisional.json, written by
// scripts/phase1_snapshot.sh. Static by design: the live board is wiped at
// the phase boundary, and this page must keep showing Phase I exactly as it
// stood — with the prize-audit process spelled out — long after the reset.
let phase1Loaded = false;
async function renderPhase1Leaders() {
  if (phase1Loaded) return;
  const body = document.getElementById("phase1-body");
  if (!body) return;
  try {
    const res = await fetch("assets/phase1-provisional.json", { cache: "no-cache" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const snap = await res.json();
    const esc = (t) => String(t).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
    const asof = document.getElementById("phase1-asof");
    if (asof) asof.textContent = `Standings as of ${snap.asOf} — top ${snap.rows.length} of `
      + `${snap.totalRanked.toLocaleString("en-US")} ranked accounts. The exchange's own `
      + `market-making and simulation accounts are not competitors and are excluded.`;
    const fmtUsd = (v) => (v < 0 ? "−$" : "$")
      + Math.abs(v).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    const cls = (v) => (v > 0 ? "lb-pos" : v < 0 ? "lb-neg" : "");
    body.innerHTML = snap.rows.map((r) => `
      <tr>
        <td class="lb-rank">${r.rank}</td>
        <td>${esc(r.username)}</td>
        <td class="lb-num ${cls(r.profitUsd)}">${fmtUsd(r.profitUsd)}</td>
        <td class="lb-num ${cls(r.returnBps)}">${(r.returnBps / 100).toFixed(2)}%</td>
        <td class="lb-num">L${r.feeLevel}</td>
        <td class="lb-num">${r.badgeCount}</td>
      </tr>`).join("");
    phase1Loaded = true;
  } catch (e) {
    console.warn("phase1 snapshot:", e);
    body.innerHTML = `<tr><td colspan="6" class="empty-state">Snapshot unavailable — try reloading.</td></tr>`;
  }
}

function activateTab(tabName, subpath) {
  if (!VALID_TABS.has(tabName)) tabName = "swap";

  const isSwitchingView = !(currentTab === tabName
    && document.getElementById(tabName + "-view")?.classList.contains("active"));

  if (isSwitchingView) {
    document.querySelectorAll(".tab").forEach((t) => {
      t.classList.toggle("active", t.dataset.tab === tabName);
    });
    // On desktop the user pill IS the Account nav item (Account isn't in the
    // tab row) — give it the selected cue while the Account view is active.
    document.getElementById("user-menu")?.classList.toggle("view-active", tabName === "account");
    currentTab = tabName;
    document.querySelectorAll(".view").forEach((v) => v.classList.remove("active"));
    const activeView = document.getElementById(tabName + "-view");
    if (!activeView) return;
    activeView.classList.add("active");
    activeView.scrollTop = 0;
    window.scrollTo(0, 0);
    document.querySelector(".header")?.classList.remove("menu-open", "acct-menu", "sys-menu");
  }

  if (tabName === "markets") {
    // Resolve which market to show: explicit subpath wins; otherwise keep
    // current selection; otherwise fall back to last-viewed / first available.
    if (markets.length) {
      const requested = subpath && markets.find((m) => m.id === subpath) ? subpath : null;
      if (requested && requested !== selectedMarket) {
        selectMarket(requested);
      } else if (!selectedMarket) {
        const defaultMkt = lastMarket && markets.find((m) => m.id === lastMarket)
          ? lastMarket
          : markets[0].id;
        selectMarket(defaultMkt);
      }
    }
    // else: markets haven't loaded yet; init() will reapply the hash after they do.
    // Size the book column now the view is actually laid out — at setup time
    // the page may still be on another tab, where clientWidth is 0 and nothing
    // can be measured. No-ops once a width has been saved by a drag.
    requestAnimationFrame(() => autoSizeBookColumn());
  }
  if (tabName === "account") {
    if (isSwitchingView) refreshAccountData();
    // Subpath selects the inner tab: #account/all|wallet|spot|positions|earn|archive|status.
    showAccountTab(subpath || acctTab);
  }
  if (tabName === "intelli") {
    // Subpath selects the inner tab: #ai/assistant|memory (legacy
    // #intelligence/ai|explorer still resolves). A named subpath is an explicit
    // choice (tab clicks route through the hash) — remember it so refreshAiGate
    // doesn't yank the user off it, and remember an "assistant" wish so a click
    // that lands before the gate resolves is honoured, not swallowed.
    const tok = INTELLI_SLUG_TO_TOKEN[subpath] || subpath;
    if (tok === "ai" || tok === "explorer") {
      intelliUserChose = true;
      intelliWishAi = tok === "ai";
    }
    showIntelliTab(tok || appState.intelliTab);
  }
  if (tabName === "ledger") {
    ledgerCtl?.onShow();   // first show loads the chain + tape
  }
  if (tabName === "leaderboard") {
    renderStatsLeaderboard();   // its own view now — System no longer carries it
  }
  if (tabName === "phase1") {
    renderPhase1Leaders();      // static snapshot — one fetch, then cached
  }
  if (tabName === "docs") {
    // Subpath selects the docs page: #docs/<slug> (missing/unknown → home).
    docsRoute(subpath);
  }
  if (tabName === "stats") {
    // Subpath selects the inner tab: #system/overview|issues|…|amm (missing →
    // keep the current one, overview initially) — mirrors the Account tabs.
    showStatsTab(subpath || statsTab);
  }
  if (tabName === "stats" && isSwitchingView) {
    refreshStats();
    startStatsAutoRefresh();
  } else if (tabName !== "stats") {
    stopStatsAutoRefresh();
  }
  if (tabName === "swap") {
    refreshSwapMarketBox();
    startSwapMarketPoll();
  } else {
    stopSwapMarketPoll();
  }
}

// Rewrite the URL hash to reflect the currently-visible state.
//   push=true  → pushState (new history entry — user-initiated navigation,
//                so Back returns to the prior market/tab)
//   push=false → replaceState (state sync from a programmatic source, e.g.
//                default-selecting a market when the Markets tab is entered;
//                Back should still return to wherever the user came from)
// No-op if the hash already matches the desired value, so feedback loops
// (hashchange → activateTab → selectMarket → syncHashToState) don't thrash.
function syncHashToState(opts) {
  const push = !!(opts && opts.push);
  let want;
  if (currentTab === "markets" && selectedMarket) {
    want = `#markets/${selectedMarket}`;
  } else if (currentTab === "docs" && docsCurrentSlug) {
    want = `#docs/${docsCurrentSlug}`;
  } else if (currentTab === "stats" && statsTab) {
    want = `#system/${STATS_TOKEN_TO_SLUG[statsTab] || statsTab}`;
  } else if (currentTab === "intelli" && appState.intelliTab) {
    want = `#ai/${INTELLI_TOKEN_TO_SLUG[appState.intelliTab] || appState.intelliTab}`;
  } else if (currentTab === "account" && acctTab) {
    want = `#account/${acctTab}`;
  } else if (currentTab && currentTab !== "swap") {
    want = `#${TAB_TO_ROUTE[currentTab] || currentTab}`;
  } else {
    return;
  }
  if (window.location.hash === want) return;
  if (push) {
    window.history.pushState(null, "", want);
  } else {
    window.history.replaceState(null, "", want);
  }
}

// Highlight the Account section the drawer's level-2 list is currently on.
// ONLY when the Account page is actually open: acctTab persists (it defaults
// to "overview" and remembers the last section visited), so keying purely off
// it lit up a row while the user was on Markets or Swap — the sub-menu claimed
// a selection that reflected nothing on screen. Selection must mean "this is
// the page you are looking at", so off-Account nothing is selected.
function syncDrawerAcctActive() {
  const onAccount = currentTab === "account";
  document.querySelectorAll("[data-acct-go]").forEach((b) =>
    b.classList.toggle("active", onAccount && b.dataset.acctGo === acctTab));
}
// Mirror for the System level-2 list: highlight the pane actually open.
function syncDrawerSysActive() {
  const onSystem = currentTab === "stats";
  document.querySelectorAll("[data-sys-go]").forEach((b) =>
    b.classList.toggle("active", onSystem && b.dataset.sysGo === statsTab));
}

// ── Event Listeners ─────────────────────────────────────────────
function setupEventListeners() {
  // Stats sub-tabs (Overview / AMM P&L). Wired here so they work
  // even when the user lands on Stats first via the URL hash.
  setupStatsSubtabs();
  wireDepositPage();   // Deposit tab buttons (Bridge canister stub)

  // Auth
  document.getElementById("auth-btn").addEventListener("click", () => {
    if (appState.isAuthenticated) logout();
    else login();
  });
  // The Account-page sign-in CTA used to have an inline `onclick="login()"`,
  // which silently no-op'd because Vite bundles main.js as an ES module
  // and `login` isn't on window. Bind it the same way as the other Sign In
  // buttons.
  document.getElementById("account-signin-btn")?.addEventListener("click", login);
  document.getElementById("intelli-signin-btn")?.addEventListener("click", login);

  // Sign-in options dialog: remember the choice, then run the II login with the
  // chosen max-session-length (minutes) + whether the session key is on disk.
  const signinModal = document.getElementById("signin-modal");
  const closeSignin = () => { if (signinModal) signinModal.style.display = "none"; };
  document.getElementById("signin-close")?.addEventListener("click", closeSignin);
  document.getElementById("signin-backdrop")?.addEventListener("click", closeSignin);
  document.getElementById("signin-confirm")?.addEventListener("click", () => {
    const min = signinModal?.querySelector('input[name="signin-ttl"]:checked')?.value || "60";
    const inMemory = !!document.getElementById("signin-inmemory")?.checked;
    localStorage.setItem(SIGNIN_TTL_KEY, min);
    localStorage.setItem(SIGNIN_MEM_KEY, inMemory ? "1" : "0");
    closeSignin();
    doLogin({ ttlMinutes: parseFloat(min), inMemory });
  });
  // One-click Google path: same session options, but II authenticates via the
  // linked Google account directly — for play users this satisfies the
  // deposit-verification requirement in the same gesture that signs them in
  // (the Deposit page still runs the attribute handshake once, on demand).
  document.getElementById("signin-google")?.addEventListener("click", () => {
    const min = signinModal?.querySelector('input[name="signin-ttl"]:checked')?.value || "60";
    const inMemory = !!document.getElementById("signin-inmemory")?.checked;
    localStorage.setItem(SIGNIN_TTL_KEY, min);
    localStorage.setItem(SIGNIN_MEM_KEY, inMemory ? "1" : "0");
    closeSignin();
    doLogin({ ttlMinutes: parseFloat(min), inMemory, openIdProvider: "google" });
  });

  // Hamburger menu toggle
  document.getElementById("menu-toggle").addEventListener("click", () => {
    const header = document.querySelector(".header");
    header.classList.toggle("menu-open");
    header.classList.remove("acct-menu", "sys-menu");   // always reopen at the top level
  });

  // Market selector dropdown toggle
  document.getElementById("market-selector").addEventListener("click", (e) => {
    // Don't toggle if clicking inside the dropdown itself (handled by item click)
    if (e.target.closest(".market-dropdown")) return;
    document.getElementById("market-selector").classList.toggle("open");
  });

  // Mobile price/stats dropdown (price-over-change → labeled stats popup).
  const statsToggle = document.getElementById("market-stats-toggle");
  if (statsToggle) {
    statsToggle.addEventListener("click", (e) => {
      // Clicks inside the popup itself shouldn't re-toggle it.
      if (e.target.closest(".market-stats-dropdown")) return;
      statsToggle.classList.toggle("open");
    });
  }

  // Desktop overflow popup: the trigger cell moves as the header resizes
  // (updateMarketHeaderMode), so delegate from the stats row.
  const statsRow = document.querySelector(".market-content .market-stats");
  if (statsRow) {
    statsRow.addEventListener("click", (e) => {
      if (e.target.closest(".market-stats-dropdown")) return;
      const trigger = e.target.closest(".market-stat-more");
      if (trigger) trigger.classList.toggle("open");
    });
  }

  // Close dropdowns on click outside
  document.addEventListener("click", (e) => {
    const selector = document.getElementById("market-selector");
    if (selector && !selector.contains(e.target)) {
      selector.classList.remove("open");
    }
    const stats = document.getElementById("market-stats-toggle");
    if (stats && !stats.contains(e.target)) {
      stats.classList.remove("open");
    }
    const moreOpen = document.querySelector(".market-stat-more.open");
    if (moreOpen && !moreOpen.contains(e.target)) {
      moreOpen.classList.remove("open");
    }
    const userMenu = document.getElementById("user-menu");
    if (userMenu && !userMenu.contains(e.target)) {
      closeUserMenu();
    }
    const chartView = document.getElementById("mini-chart-view");
    if (chartView && !chartView.contains(e.target)) {
      chartView.classList.remove("open");
    }
  });

  // Auto-compact the desktop market header when its (resizable) column is too
  // narrow for the full stat cells — watch the header's own size (changes when
  // the user drags the chart/book column resizer) and the viewport.
  const mhHeaderEl = document.querySelector(".market-content > .market-header");
  if (mhHeaderEl && typeof ResizeObserver !== "undefined") {
    let mhScheduled = false;
    const mhRO = new ResizeObserver(() => {
      if (mhScheduled) return;
      mhScheduled = true;
      requestAnimationFrame(() => { mhScheduled = false; updateMarketHeaderMode(); });
    });
    mhRO.observe(mhHeaderEl);
  }
  window.addEventListener("resize", updateMarketHeaderMode);
  updateMarketHeaderMode();

  // Tabs — clicking a tab updates the URL hash; the hashchange listener
  // (registered below) drives activateTab, which does the actual view swap.
  // This way the hash is the single source of truth, so refreshes and
  // browser back/forward keep the same tab.
  document.querySelectorAll(".tab").forEach((tab) => {
    tab.addEventListener("click", () => {
      const name = tab.dataset.tab;
      // Mobile drawer, signed in: the username pill opens the Account section
      // list in place (level 2) instead of navigating. .menu-open only ever
      // exists on mobile, so this can't fire on desktop.
      const header = document.querySelector(".header");
      if (name === "account" && appState.isAuthenticated && header?.classList.contains("menu-open")) {
        header.classList.add("acct-menu");
        syncDrawerAcctActive();
        return;
      }
      // Same treatment for System: its sub-tabs are a level-2 list rather
      // than a jump to Overview. No sign-in gate — System is public.
      if (name === "stats" && header?.classList.contains("menu-open")) {
        header.classList.add("sys-menu");
        syncDrawerSysActive();
        return;
      }
      // Alias items (Deposit → Account, Play → the Launch page) aren't
      // sections, so the same-tab guard below doesn't apply to them.
      if (ROUTE_ALIASES[name]) {
        document.querySelector(".header")?.classList.remove("menu-open", "acct-menu", "sys-menu");
        window.location.hash = ROUTE_ALIASES[name];
        return;
      }
      if (currentTab === name) {
        // Same tab tapped — don't thrash history, but on mobile the menu is
        // open and the user expects the tap to dismiss it.
        document.querySelector(".header")?.classList.remove("menu-open", "acct-menu", "sys-menu");
        return;
      }
      // Clicking "Markets" goes to the last-viewed market (if any) so the
      // URL captures a shareable state; every other section writes its full
      // path (#docs/launch, #system/overview, #ai/assistant, #account/overview)
      // so the URL always names the pane on screen.
      const slug = TAB_TO_ROUTE[name] || name;
      if (name === "markets" && selectedMarket) {
        window.location.hash = `markets/${selectedMarket}`;
      } else {
        const sub = TAB_DEFAULT_SUB[name];
        window.location.hash = sub ? `${slug}/${sub}` : slug;
      }
    });
  });
  // Mobile drawer level 2 (Account sections): back returns to the nav list;
  // an item navigates and closes the whole drawer.
  document.getElementById("drawer-acct-back")?.addEventListener("click", () => {
    document.querySelector(".header")?.classList.remove("acct-menu");
  });
  // System level 2: same back/navigate pair.
  document.getElementById("drawer-sys-back")?.addEventListener("click", () => {
    document.querySelector(".header")?.classList.remove("sys-menu");
  });
  document.querySelectorAll("[data-sys-go]").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelector(".header")?.classList.remove("menu-open", "sys-menu");
      window.location.hash = "system/" + btn.dataset.sysGo;
    });
  });
  document.querySelectorAll("[data-acct-go]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const header = document.querySelector(".header");
      header?.classList.remove("menu-open", "acct-menu", "sys-menu");
      window.location.hash = "account/" + btn.dataset.acctGo;
    });
  });

  // Signed-in user dropdown (desktop far right): the trigger toggles the menu;
  // its items route to Account or sign out. Outside-click closes it (wired into
  // the shared close-dropdowns listener above).
  const userTrigger = document.getElementById("user-menu-trigger");
  if (userTrigger) {
    userTrigger.addEventListener("click", (e) => {
      e.stopPropagation();
      const menu = document.getElementById("user-menu");
      const open = menu.classList.toggle("open");
      userTrigger.setAttribute("aria-expanded", open ? "true" : "false");
    });
  }
  document.querySelectorAll(".user-menu-item").forEach((item) => {
    item.addEventListener("click", () => {
      const action = item.dataset.useraction;
      closeUserMenu();
      if (action === "account") {
        if (currentTab !== "account") window.location.hash = "account";
      } else if (action && action.startsWith("acct:")) {
        // Account section shortcuts (Value, Wallet, …) — hash-driven so
        // back/forward works; if we're already there the hash is unchanged
        // and the click just closes the menu.
        window.location.hash = "account/" + action.slice(5);
      } else if (action === "signout") {
        logout();
      }
    });
  });

  // Publish the top chrome's height as --chrome-h (see updateChromeHeight).
  // The banner renderers call it explicitly at every show/hide; the observer
  // additionally catches text re-wrapping and viewport resizes.
  const topChrome = document.getElementById("top-chrome");
  if (topChrome) {
    new ResizeObserver(updateChromeHeight).observe(topChrome);
    updateChromeHeight();
  }

  // Docs: build the sidebar once; page bodies render on route (docsRoute).
  // In-page table-of-contents links use data-docs-goto and scroll WITHOUT
  // touching the URL hash (the app routes on the hash). Content re-renders on
  // every page switch, so the handler is delegated to the view.
  renderDocsSidebar();
  document.getElementById("docs-view")?.addEventListener("click", (e) => {
    const a = e.target.closest("[data-docs-goto]");
    if (!a) return;
    const el = document.getElementById("docs-sec-" + a.dataset.docsGoto);
    if (el) el.scrollIntoView({ behavior: "smooth", block: "start" });
  });

  // Account inner tabs (Wallet | Spot | Positions | Earn) — hash-driven.
  document.querySelectorAll(".acct-tab").forEach((btn) => {
    btn.addEventListener("click", () => { window.location.hash = "account/" + btn.dataset.acct; });
  });
  // Positions History sub-view toggle (episodes ⇄ fills).
  document.getElementById("ph-mode-episodes")?.addEventListener("click", () => setPhMode("episodes"));
  document.getElementById("ph-mode-fills")?.addEventListener("click", () => setPhMode("fills"));

  window.addEventListener("hashchange", () => {
    const r = routeFromHash();
    activateTab(r.tab, r.subpath);
  });

  // Order book granularity dropdown (custom)
  const granEl = document.getElementById("ob-granularity");
  granEl.addEventListener("click", (e) => {
    const opt = e.target.closest(".ob-gran-option");
    if (opt) {
      e.stopPropagation();
      obGranularity = Number(opt.dataset.value);
      if (selectedMarket) obGranularityByMarket[selectedMarket] = obGranularity;
      document.getElementById("ob-gran-label").textContent = opt.textContent;
      granEl.classList.remove("open");
      if (lastOrderBookSnapshot) renderOrderBook(lastOrderBookSnapshot);
      return;
    }
    if (e.target.closest(".ob-gran-menu")) return;
    // Position menu above the button using fixed positioning
    const menu = document.getElementById("ob-gran-menu");
    const rect = granEl.getBoundingClientRect();
    menu.style.left = rect.left + "px";
    menu.style.bottom = (window.innerHeight - rect.top + 4) + "px";
    granEl.classList.toggle("open");
  });
  document.addEventListener("click", (e) => {
    if (!granEl.contains(e.target)) granEl.classList.remove("open");
  });

  // Mobile user orders tabs
  document.querySelectorAll(".uom-tab").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".uom-tab").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      uomTab = btn.dataset.uom;
      uomPage = 0;
      renderUserOrdersMobile();
    });
  });
  // Panel-level market scope: one checkbox filters all four tabs (venue norm
  // is all-markets by default — open risk on other markets stays visible).
  {
    const scope = document.getElementById("uom-scope-current");
    if (scope) {
      scope.checked = uomScopeCurrent;
      scope.addEventListener("change", () => {
        uomScopeCurrent = scope.checked;
        try { localStorage.setItem("uplandsUomScopeCurrent", uomScopeCurrent ? "1" : "0"); } catch {}
        uomPage = 0;
        renderUserOrdersMobile();
      });
    }
    // Crossing the mobile breakpoint flips whether the scope applies (the
    // checkbox is hidden and inert below it) — re-render so rows match.
    uomMobileMQ.addEventListener("change", () => { uomPage = 0; renderUserOrdersMobile(); });
  }
  // Close buttons inside the Markets "Positions" tab (delegated).
  document.getElementById("uom-content")?.addEventListener("click", (e) => {
    const btn = e.target.closest(".pos-close-btn");
    if (btn) onClosePosition(btn.dataset.pool, btn.dataset.market);
  });

  // Order Book / Trades tabs inside the book-trades panel
  document.querySelectorAll(".bt-tab").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".bt-tab").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      const which = btn.dataset.bt;
      const obPane = document.getElementById("orderbook-pane");
      const trPane = document.getElementById("trades-pane");
      const obStale = document.getElementById("orderbook-stale");
      const trStale = document.getElementById("trades-stale");
      if (which === "orderbook") {
        if (obPane) obPane.style.display = "";
        if (trPane) trPane.style.display = "none";
        if (trStale) trStale.style.display = "none";
      } else {
        if (obPane) obPane.style.display = "none";
        if (trPane) trPane.style.display = "";
        if (obStale) obStale.style.display = "none";
      }
    });
  });

  // Order book click-to-fill (delegated on the stable asks/bids containers).
  ["orderbook-asks", "orderbook-bids"].forEach((id) => {
    document.getElementById(id)?.addEventListener("click", onOrderBookClick);
  });

  // Order book cumulative toggle
  document.getElementById("ob-cumulative").addEventListener("click", () => {
    obCumulative = !obCumulative;
    document.getElementById("ob-cumulative").classList.toggle("active", obCumulative);
    if (lastOrderBookSnapshot) renderOrderBook(lastOrderBookSnapshot);
  });

  // Swap market-box order book: the SAME granularity dropdown + Σ toggle as the
  // Markets book, on the swap book's own swapObGranByMarket / swapObCumulative.
  const swapGranEl = document.getElementById("swap-ob-granularity");
  swapGranEl?.addEventListener("click", (e) => {
    const opt = e.target.closest(".ob-gran-option");
    if (opt) {
      e.stopPropagation();
      if (swapBookMarket) swapObGranByMarket[swapBookMarket] = Number(opt.dataset.value);
      swapGranEl.classList.remove("open");
      rerenderSwapBook();
      return;
    }
    if (e.target.closest(".ob-gran-menu")) return;
    const menu = document.getElementById("swap-ob-gran-menu");
    const rect = swapGranEl.getBoundingClientRect();
    menu.style.left = rect.left + "px";
    menu.style.bottom = (window.innerHeight - rect.top + 4) + "px";
    swapGranEl.classList.toggle("open");
  });
  document.addEventListener("click", (e) => {
    if (swapGranEl && !swapGranEl.contains(e.target)) swapGranEl.classList.remove("open");
  });
  document.getElementById("swap-ob-cumulative")?.addEventListener("click", () => {
    swapObCumulative = !swapObCumulative;
    document.getElementById("swap-ob-cumulative").classList.toggle("active", swapObCumulative);
    rerenderSwapBook();
  });

  // Slippage buttons — the estimate walks the book bounded by maxSlippage, so
  // changing it must recompute the preview (this is what makes the setting's
  // effect visible).
  document.querySelectorAll(".slip-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".slip-btn").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      maxSlippage = parseFloat(btn.dataset.slip);
      scheduleSwapPreview();
    });
  });

  // Swap reverse
  document.getElementById("swap-reverse-btn").addEventListener("click", () => {
    const from = document.getElementById("swap-from-token");
    const to   = document.getElementById("swap-to-token");
    const temp = from.value;
    from.value = to.value;
    to.value   = temp;
    // Dispatch change so the enhanced dropdown buttons re-sync their labels; the
    // change listeners below then re-run the balance / preview / market refresh.
    from.dispatchEvent(new Event("change", { bubbles: true }));
    to.dispatchEvent(new Event("change", { bubbles: true }));
  });

  // Swap token change — reset the market box to its default tab for the new pair,
  // and flip the other side if the pick would make a same→same pair.
  _swapPrevFrom = document.getElementById("swap-from-token").value;
  _swapPrevTo   = document.getElementById("swap-to-token").value;
  document.getElementById("swap-from-token").addEventListener("change", () => onSwapTokenChange("from"));
  document.getElementById("swap-to-token").addEventListener("change",   () => onSwapTokenChange("to"));
  // Market-box tab clicks (delegated; tabs are re-labelled, never replaced).
  document.getElementById("swap-market-tabs")?.addEventListener("click", (e) => {
    const btn = e.target.closest(".smt-tab");
    if (btn) setSwapMarketTab(btn.dataset.smt);
  });
  // Rate-graph interval switch (delegated).
  document.getElementById("swap-graph-ivs")?.addEventListener("click", (e) => {
    const btn = e.target.closest("button");
    if (!btn) return;
    document.querySelectorAll("#swap-graph-ivs button").forEach((b) => b.classList.toggle("active", b === btn));
    swapGraphInterval = Number(btn.dataset.ms);
    refreshSwapGraph(true);
  });

  // Swap amount input
  document.getElementById("swap-from-amount").addEventListener("input", scheduleSwapPreview);

  // "No partial fulfillment" toggle: re-derive the Swap button state so an
  // unfilled estimate flips between "Swap (partial)" and "Insufficient liquidity".
  document.getElementById("no-partial-fill").addEventListener("change", updateSwapButtonState);

  // ── Column resizer: drag to adjust Order Book / Trades width ─────
  setupColResizer();

  // Click-to-fill on the partial-fill warning: copy the max swappable amount
  // into the "From" field and re-run the preview.
  document.getElementById("swap-preview-rate").addEventListener("click", () => {
    const rateEl = document.getElementById("swap-preview-rate");
    if (!rateEl.classList.contains("clickable")) return;
    if (!lastSwapEstimate || lastSwapEstimate.filled) return;
    const cap = lastSwapEstimate.consumedFrom;
    if (!(cap > 0)) return;
    const fromEl = document.getElementById("swap-from-amount");
    // Strip trailing zeros from fixed-precision output; numeric inputs accept
    // dot-separated decimals regardless of locale.
    fromEl.value = Number(cap.toFixed(8)).toString();
    fromEl.dispatchEvent(new Event("input", { bubbles: true }));
    fromEl.focus();
  });

  // Swap execute
  document.getElementById("swap-execute-btn").addEventListener("click", executeSwap);

  // Order mode toggle (Spot ⇄ Margin)
  document.querySelectorAll(".order-mode-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      orderMode = btn.dataset.mode;
      applyOrderMode();
    });
  });

  // Order type toggle
  document.querySelectorAll(".order-type-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".order-type-btn").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      orderType = btn.dataset.type;
      document.getElementById("limit-price-group").style.display    = orderType === "limit"  ? "block" : "none";
      document.getElementById("market-slippage-group").style.display = orderType === "market" ? "block" : "none";
      const eg = document.getElementById("limit-expiry-group");
      // Expiry only applies to spot limit orders; margin limit entries rest as GTC.
      if (eg) eg.style.display = (orderType === "limit" && orderMode === "spot") ? "block" : "none";
      updateOrderTotal();
    });
  });

  // Margin controls: leverage / pool changes re-preview.
  document.getElementById("order-leverage")?.addEventListener("change", () => {
    updateMarginPreview();
    syncOrderPctSlider();   // leverage rescales what 100% means
  });
  document.getElementById("order-pool")?.addEventListener("change", () => { updateOrderSideUI(); updateMarginPreview(); });

  // Order side toggle
  document.querySelectorAll(".side-btn").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".side-btn").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      // Save current price for the side we're leaving
      const priceInput = document.getElementById("order-price");
      savedOrderPrices[orderSide] = priceInput.value;
      // Switch side
      orderSide = btn.dataset.side;
      // Restore saved price for new side (empty string triggers initOrderPrice)
      priceInput.value = savedOrderPrices[orderSide];
      initOrderPrice();
      updateOrderSideUI();
      updateOrderTotal();   // refresh preview/button (initOrderPrice skips this when a price is already set)
      updateUI();
    });
  });

  // Order-size slider (replaces the 25/50/75/100 prefill buttons): drag to
  // size the order as a continuous % of what "Available:" shows — ICPUSD
  // through the price (buy), the base balance (sell), buying power ×
  // leverage through the entry price (margin). updateOrderTotal syncs the
  // thumb back whenever the quantity changes by any other route (typing,
  // side/mode switches, price edits).
  document.getElementById("order-pct-slider").addEventListener("input", (e) => {
    const pct = parseInt(e.target.value, 10) || 0;
    // A disabled slider fires no input events, so being here means signed-in
    // with a market — write the sized quantity even when it's zero. Decimals
    // follow the per-asset Order Book rule (orderQtyDecimals), not a flat 6.
    document.getElementById("order-quantity").value = ((orderMaxQty() * pct) / 100).toFixed(orderQtyDecimals());
    setOrderPctUI(pct);
    updateOrderTotal();
  });

  // Order total calculation
  document.getElementById("order-price").addEventListener("input", updateOrderTotal);
  document.getElementById("order-quantity").addEventListener("input", updateOrderTotal);

  // Place order
  document.getElementById("place-order-btn").addEventListener("click", placeOrder);

  // (The old Wallet-card "+ Add Tokens (dev)" faucet button is gone — the
  // Deposit page is the on-ramp on every posture; dev funding is scripted.)
  // Wallet: withdraw (deposits live on the Deposit page).
  // Use a custom dropdown for the asset selector: the native popup mispositions
  // in embedded/webview browsers.
  enhanceSelectDropdown("wallet-token");
  // Clicking a balance figure pre-fills the Withdraw row: select that asset
  // (dispatch change so the enhanced dropdown re-labels) + fill the amount.
  // Delegated — the grid re-renders on every balance refresh.
  const balGridFill = (cell) => {
    const sel = document.getElementById("wallet-token");
    if (sel && sel.value !== cell.dataset.token) {
      sel.value = cell.dataset.token;
      sel.dispatchEvent(new Event("change", { bubbles: true }));
    }
    const amt = document.getElementById("wallet-wd-amount");
    if (amt) { amt.value = cell.dataset.bal; amt.focus(); }
  };
  document.getElementById("account-balances-grid")?.addEventListener("click", (e) => {
    const cell = e.target.closest(".balance-amount-fill");
    if (cell) balGridFill(cell);
  });
  document.getElementById("account-balances-grid")?.addEventListener("keydown", (e) => {
    const cell = e.target.closest(".balance-amount-fill");
    if (cell && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); balGridFill(cell); }
  });
  // Every asset/token selector uses the custom dropdown — native <select> popups
  // misposition in the embedded/webview gateway (the menu anchors to the button).
  enhanceSelectDropdown("swap-from-token", { icons: true });
  enhanceSelectDropdown("swap-to-token", { icons: true });
  enhanceSelectDropdown("earn-vault-deposit-token");
  document.getElementById("wallet-wd-btn")?.addEventListener("click", onWalletWithdraw);

  // Regen username
  document.getElementById("regen-username-btn").addEventListener("click", doRegenerateUsername);

  // Copy your principal (the raw key behind the friendly username).
  const principalCopyBtn = document.getElementById("profile-principal-copy");
  if (principalCopyBtn) {
    principalCopyBtn.addEventListener("click", async () => {
      if (!appState.myPrincipalText) return;
      try {
        await navigator.clipboard.writeText(appState.myPrincipalText);
        principalCopyBtn.textContent = "Copied!";
        setTimeout(() => { principalCopyBtn.textContent = "Copy"; }, 1500);
      } catch { /* clipboard blocked (insecure context) — no-op */ }
    });
  }

  // Chart overlay
  document.getElementById("chart-btn").addEventListener("click", openChart);
  document.getElementById("chart-close-btn").addEventListener("click", closeChart);
  document.querySelectorAll(".chart-interval-btn").forEach((btn) => {
    btn.addEventListener("click", () => changeChartInterval(Number(btn.dataset.interval)));
  });
}

// ── Margin-mode (position) preview helpers ──────────────────────
// Spot trades from the Wallet (no leverage). Margin mode opens a leveraged /
// short position in a margin pool via openPosition — these helpers drive the
// pre-trade preview (notional, est. entry/liq price, slippage) shown in the box.
const MAINTENANCE_HEALTH_RATIO = 1.15; // mirror of backend Types.MAINTENANCE_HEALTH_RATIO

// Walk cached order-book depth to estimate the average fill price (and thus
// slippage) for a market order of `sizeBase`. A long lifts asks; a short hits
// bids. Returns { avg, filled, exhausted, mid }; falls back to mark/last when
// there's no book.
function estimateFill(marketId, side, sizeBase) {
  const ob = orderBookCache[marketId];
  const market = markets.find((m) => m.id === marketId);
  const ref = market ? (market.markPrice > 0 ? market.markPrice : market.lastPrice) : 0;
  const bestAsk = ob && ob.asks && ob.asks.length ? ob.asks[0].price : 0;
  const bestBid = ob && ob.bids && ob.bids.length ? ob.bids[0].price : 0;
  const mid = bestAsk > 0 && bestBid > 0 ? (bestAsk + bestBid) / 2 : ref;
  const levels = side === "buy" ? (ob && ob.asks) : (ob && ob.bids);
  if (!levels || levels.length === 0 || !(sizeBase > 0)) {
    return { avg: ref, filled: 0, exhausted: true, mid };
  }
  let remaining = sizeBase, cost = 0, filled = 0;
  for (const lvl of levels) {
    const take = Math.min(remaining, lvl.quantity);
    cost += take * lvl.price; filled += take; remaining -= take;
    if (remaining <= 1e-9) break;
  }
  const avg = filled > 0 ? cost / filled : ref;
  return { avg, filled, exhausted: remaining > 1e-9, mid };
}

// (previewLiqPrice and maxOpenLeverage are gone: Est. liq. and the
// over-leverage verdict come from previewOpenPosition — the canister
// simulates the open on a discarded state copy and reads the liq price
// through the same routine that renders the Positions table.)

// (The old updateLeverageOptions dropdown-greying is gone: it applied the
// standalone-pool model to every pool, greying choices the real pool-wide
// gate would happily accept. Leverage is a funding calculator in a cross
// pool — the pool-capacity verdict now comes from previewOpenPosition.)

// What quantity "100%" means for the current mode/side: spot buy sizes the
// wallet's ICPUSD through the price, spot sell is simply the base balance,
// margin is buying power (wallet cash + pool free margin) × leverage through
// the entry price. Same basis as the form's "Available:" line (total wallet
// balances — what the old 25/50/75/100 buttons used).
function orderMaxQty() {
  if (!selectedMarket || !appState.isAuthenticated) return 0;
  const market = markets.find((m) => m.id === selectedMarket);
  if (!market) return 0;
  if (orderMode === "margin") {
    const lev = parseFloat(document.getElementById("order-leverage")?.value || "1") || 1;
    const pool = selectedOrderPool();
    const free = pool ? Number(pool.freeQuote) || 0 : 0;
    const marginAvail = (userBalances["ICPUSD"] || 0) + free;
    const px = orderType === "limit"
      ? (parseFloat(document.getElementById("order-price").value) || market.lastPrice)
      : (market.markPrice > 0 ? market.markPrice : market.lastPrice);
    return px > 0 ? (marginAvail * lev) / px : 0;
  }
  if (orderSide === "buy") {
    const price = parseFloat(document.getElementById("order-price").value) || market.lastPrice;
    return price > 0 ? (userBalances["ICPUSD"] || 0) / price : 0;
  }
  return userBalances[market.baseToken] || 0;
}

// Decimal places for the size field — the Order Book / Trades quantity rule
// (renderOrderBook's qtyDp): integer digits of the price set the quantity's
// decimals, so a $65,905 asset sizes in 5 dp and a $2 asset in 1 dp. Uses
// the same price the sizing math uses (typed limit price, else mark/last).
function orderQtyDecimals() {
  const market = markets.find((m) => m.id === selectedMarket);
  const px = parseFloat(document.getElementById("order-price").value)
    || (market ? (market.markPrice > 0 ? market.markPrice : market.lastPrice) : 0);
  return px >= 1 ? String(Math.floor(px)).length : 1;
}

// Thumb + % readout + filled-track position (the CSS paints the track's
// accent fill up to --pct).
function setOrderPctUI(pct) {
  const slider = document.getElementById("order-pct-slider");
  if (!slider) return;
  slider.value = String(pct);
  slider.style.setProperty("--pct", pct + "%");
  const readout = document.getElementById("order-pct-readout");
  if (readout) readout.textContent = pct + "%";
}

// The thumb follows the quantity field whichever way it was filled (typed,
// dragged, side/mode/price change): quantity as a % of orderMaxQty, clamped
// to [0,100]. Disabled only when dragging could mean nothing at all (signed
// out / no market) — a zero balance keeps a live slider that writes 0.000000,
// the same as the old 25/50/75/100 buttons did.
function syncOrderPctSlider() {
  const slider = document.getElementById("order-pct-slider");
  if (!slider) return;
  slider.disabled = !appState.isAuthenticated || !markets.find((m) => m.id === selectedMarket);
  const max = orderMaxQty();
  const qty = parseFloat(document.getElementById("order-quantity").value) || 0;
  setOrderPctUI(max > 0 ? Math.max(0, Math.min(100, Math.round((qty / max) * 100))) : 0);
}

function updateOrderTotal() {
  // Every quantity-affecting path funnels through here — keep the slider
  // thumb tracking the quantity before any early return below.
  syncOrderPctSlider();
  // Margin mode previews a leveraged position rather than a spot total.
  if (orderMode === "margin") { updateMarginPreview(); return; }

  const price = parseFloat(document.getElementById("order-price").value)    || 0;
  const qty   = parseFloat(document.getElementById("order-quantity").value) || 0;
  const total = price * qty;
  document.getElementById("order-total-value").textContent = formatNum(total) + " ICPUSD";

  const placeBtn = document.getElementById("place-order-btn");
  if (!placeBtn) return;
  const market = markets.find((m) => m.id === selectedMarket);
  // Not submittable (no quantity, or a limit order with no price) → DISABLE the
  // button. The old early-return here left it enabled from updateUI, so "Buy"
  // stayed clickable at quantity 0.
  const needsPrice = orderType === "limit";
  if (!appState.isAuthenticated || !market || qty <= 0 || (needsPrice && price <= 0)) {
    placeBtn.disabled = true;
    placeBtn.textContent = orderSide === "buy" ? "Buy" : "Sell";
    placeBtn.style.background = "var(--bg-hover)";
    placeBtn.style.color = "var(--text-muted)";
    placeBtn.style.opacity = "";
    return;
  }

  // Spot is pure Wallet custody: a buy needs the cash, a sell needs the base.
  // Trading beyond what you hold (leverage / short) is a position — Margin mode.
  let ok, label;
  if (orderSide === "buy") {
    ok = (userAvailBalances["ICPUSD"] || 0) + 0.0000001 >= total;
    label = "Buy";
  } else {
    ok = (userAvailBalances[market.baseToken] || 0) + 0.0000001 >= qty;
    label = "Sell";
  }
  placeBtn.disabled = !ok;
  placeBtn.textContent = label;
  placeBtn.style.background = ok ? (orderSide === "buy" ? "var(--green)" : "var(--red)") : "var(--bg-hover)";
  placeBtn.style.color      = ok ? (orderSide === "buy" ? "var(--green-text)" : "var(--red-text)") : "var(--text-muted)";
  placeBtn.style.opacity = "";
}

function initOrderPrice() {
  const priceInput = document.getElementById("order-price");
  if (!priceInput || !lastOrderBookSnapshot) return;
  const currentPrice = parseFloat(priceInput.value);
  if (currentPrice > 0) return; // only set if empty/zero

  const snap = lastOrderBookSnapshot;
  if (orderSide === "buy") {
    // One unit above highest bid
    if (snap.bids && snap.bids.length > 0) {
      const bestBid = snap.bids[0].price;
      const step = bestBid >= 1000 ? 1 : bestBid >= 1 ? 0.01 : 0.001;
      priceInput.value = (bestBid + step).toFixed(step < 1 ? (step < 0.01 ? 3 : 2) : 0);
    }
  } else {
    // One unit below lowest ask
    if (snap.asks && snap.asks.length > 0) {
      const bestAsk = snap.asks[0].price;
      const step = bestAsk >= 1000 ? 1 : bestAsk >= 1 ? 0.01 : 0.001;
      priceInput.value = (bestAsk - step).toFixed(step < 1 ? (step < 0.01 ? 3 : 2) : 0);
    }
  }
  updateOrderTotal();
}

function updateOrderSideUI() {
  // The size slider enables/scales off the same data as the Available line,
  // and every path that refreshes that line (sign-in, balance polls, deposits,
  // side/market switches) funnels through here — sync it first, so the early
  // returns below can't strand the slider in a stale enabled/disabled state.
  syncOrderPctSlider();

  // Total label: Bid for buy/long, Ask for sell/short.
  const label = document.getElementById("order-total-label");
  if (label) label.textContent = orderSide === "buy" ? "Bid: " : "Ask: ";

  const el = document.getElementById("order-available");
  if (!el) return;
  if (!appState.isAuthenticated || !selectedMarket) { el.innerHTML = ""; return; }
  const market = markets.find((m) => m.id === selectedMarket);
  if (!market) { el.innerHTML = ""; return; }

  if (orderMode === "margin") {
    // Margin: show wallet cash available to commit + the selected pool's free margin.
    const cash = userBalances["ICPUSD"] || 0;
    const p = selectedOrderPool();
    const poolNote = p ? ` <span class="avail-borrow">(${escH(p.name)}: ${formatNum(Number(p.freeQuote) || 0)} free)</span>` : "";
    el.innerHTML = `Margin: <span>${formatNum(cash)} ICPUSD</span> in wallet${poolNote}`;
    return;
  }

  if (orderSide === "buy") {
    const bal = userBalances["ICPUSD"] || 0;
    el.innerHTML = `Available: <span>${formatNum(bal)} ICPUSD</span>`;
  } else {
    const bal = userBalances[market.baseToken] || 0;
    el.innerHTML = `Available: <span>${formatNum(bal)} ${market.baseToken}</span>`;
  }
}

// ── Utilities ───────────────────────────────────────────────────

// Pure formatting helpers (formatQty, priceDecimals, uniformDecimals, formatNum,
// formatPrice, formatTime, flashPriceEl) live in ./format.js — imported at top.

// Set the selector-bar price (desktop stat + mobile inline) and flash it
// green/red on a move. Called from BOTH renderTrades (2s, in sync with the
// trade feed) and updatePriceChange (10s markets refresh). De-dupes against
// prevMarketPrice so only the first to see a new price flashes — the other
// no-ops, avoiding a double flash.
function setSelectorPrice(price) {
  if (!(price > 0)) return;
  const dtPriceEl = document.getElementById("dt-market-price");
  const priceEl   = document.getElementById("market-header-price");
  const formatted = formatPrice(price);
  if (dtPriceEl) dtPriceEl.textContent = formatted;
  if (priceEl)   priceEl.textContent   = formatted; // no "$" — matches desktop Price cell
  if (prevMarketPrice !== null && price !== prevMarketPrice) {
    const dir = price > prevMarketPrice ? 1 : -1;
    flashPriceEl(dtPriceEl, dir);
    flashPriceEl(priceEl, dir);
  }
  prevMarketPrice = price;
}

// Desktop only: fit the market-header telemetry to the (user-resizable) chart
// column. Three regimes, best to worst:
//   1. Everything fits → the plain stat bar.
//   2. The trailing cells (after 24h Change) don't fit → hide them from the
//      end; the LAST cell still visible grows a chevron and becomes a dropdown
//      listing exactly the hidden stats. Any number of telemetry cells can be
//      appended to the bar under this rule — a wide enough window shows them
//      all, anything narrower folds the tail into the dropdown.
//   3. Not even Price…24h Change fit — the selector bar's right edge would
//      cover the Change cell → the single compact dropdown (same component
//      mobile uses), price over change.
// Measures the FULL layout each call — reset, check overflow, degrade — so it
// also un-degrades when space returns. The header's width is fixed by its grid
// column, not its content, so the class/display toggles here can't change the
// observed size (no ResizeObserver loop).
function updateMarketHeaderMode() {
  const header = document.querySelector(".market-content > .market-header");
  if (!header) return;
  const cells = Array.from(header.querySelectorAll(".market-stats .market-stat"));
  const overflow = document.getElementById("market-stats-overflow");
  // Survive value refreshes: if the SAME cell ends up the trigger again, an
  // open popup stays open (reset() below necessarily closes it while
  // measuring — all within one synchronous pass, so nothing flickers).
  const openBefore = header.querySelector(".market-stat-more.open");
  const reset = () => {
    header.classList.remove("market-header-compact");
    for (const c of cells) { c.style.display = ""; c.classList.remove("market-stat-more", "open"); }
  };
  if (!window.matchMedia("(min-width: 901px)").matches) {
    reset(); // mobile: CSS shows the compact dropdown; no progressive state
    return;
  }
  reset();
  const fits = () => header.scrollWidth <= header.clientWidth + 1;
  if (fits()) return;

  // Progressive overflow. Only cells after 24h Change may hide — Change is
  // the floor: rather than let the trigger walk back onto Mark or Price, the
  // header drops to the compact dropdown (regime 3). `cut` is the index of
  // the first hidden cell, so cells[cut-1] is the trigger carrying the popup.
  const changeIdx = cells.findIndex((c) => c.querySelector("#dt-market-change"));
  const floor = changeIdx >= 0 ? changeIdx : cells.length - 1;
  for (let cut = cells.length - 1; cut >= floor + 1; cut--) {
    cells[cut].style.display = "none";
    cells[cut].classList.remove("market-stat-more"); // was the trigger last iteration
    const trigger = cells[cut - 1];
    trigger.classList.add("market-stat-more");
    if (!fits()) continue;
    // Fits with this tail hidden: park the shared popup in the trigger cell
    // and mirror the hidden cells into it (label + value, colour class and
    // all). Rebuilt on every pass so an open popup tracks live values.
    if (overflow) {
      if (overflow.parentElement !== trigger) trigger.appendChild(overflow);
      overflow.innerHTML = cells.slice(cut).map((c) => {
        const v = c.querySelector(".ms-value");
        return `<div class="msd-row"><span class="ms-label">${escH(c.querySelector(".ms-label")?.textContent ?? "")}</span>` +
          `<span class="${escH(v?.className || "ms-value")}">${escH(v?.textContent ?? "")}</span></div>`;
      }).join("");
    }
    if (openBefore === trigger) trigger.classList.add("open");
    return;
  }
  // Regime 3: even the floor set overflows → single compact dropdown.
  reset();
  header.classList.add("market-header-compact");
}

function updatePriceChange(market) {
  const priceEl      = document.getElementById("market-header-price");
  const changeEl     = document.getElementById("market-price-change");
  const dtPriceEl    = document.getElementById("dt-market-price");
  const dtChangeEl   = document.getElementById("dt-market-change");
  const dtVolumeEl   = document.getElementById("dt-market-volume");

  // ── Last price (mobile inline + desktop stat) ───────────────────────
  // setSelectorPrice owns the text + flash; renderTrades also calls it (2s) so
  // the price tracks the visible trade feed rather than this 10s refresh.
  const hasPrice = market && market.lastPrice > 0;
  if (hasPrice) {
    setSelectorPrice(market.lastPrice);
  } else {
    if (priceEl)   priceEl.textContent   = "—";
    if (dtPriceEl) dtPriceEl.textContent = "—";
  }
  // Mobile popup mirror of the price.
  const msdPriceEl = document.getElementById("msd-price");
  if (msdPriceEl) msdPriceEl.textContent = hasPrice ? formatPrice(market.lastPrice) : "—";

  // ── Mark (oracle/AMM ref price) — desktop stat + mobile popup ────────
  const dtMarkEl  = document.getElementById("dt-market-mark");
  const msdMarkEl = document.getElementById("msd-mark");
  const markTxt   = (market && market.markPrice > 0) ? formatPrice(market.markPrice) : "—";
  if (dtMarkEl)  dtMarkEl.textContent  = markTxt;
  if (msdMarkEl) msdMarkEl.textContent = markTxt;

  // ── 24h change: derive % from absolute + lastPrice ──────────────────
  // Backend returns priceChange24hAbs (in quote-token units). open24h =
  // lastPrice − abs. pct = abs / open24h × 100. Guard against missing data
  // and a zero baseline price.
  const abs       = market ? Number(market.priceChange24hAbs) : 0;
  const lastPrice = market ? Number(market.lastPrice) : 0;
  const open24h   = lastPrice - abs;
  const hasData   = market && lastPrice > 0 && open24h > 0 && abs !== 0;
  const msdChangeEl = document.getElementById("msd-change");
  if (!hasData) {
    if (changeEl)    { changeEl.textContent    = "—"; changeEl.style.color = ""; }
    if (dtChangeEl)  { dtChangeEl.textContent  = "—"; dtChangeEl.className  = "ms-value"; }
    if (msdChangeEl) { msdChangeEl.textContent = "—"; msdChangeEl.className = "ms-value"; }
  } else {
    const pct   = (abs / open24h) * 100;
    const sign  = abs >= 0 ? "+" : "-";
    const absTxt = `${sign}${formatPrice(Math.abs(abs))}`;
    const pctTxt = `${sign}${Math.abs(pct).toFixed(2)}%`;
    // "+1.48 / +0.23%" (Hyperliquid format), color by sign — used everywhere.
    const fullTxt   = `${absTxt} / ${pctTxt}`;
    const valueCls  = "ms-value " + (abs > 0 ? "up" : abs < 0 ? "down" : "");
    // Mobile inline (under the price): full abs / pct, colored.
    if (changeEl) {
      changeEl.textContent = fullTxt;
      changeEl.style.color = abs > 0 ? "var(--green)" : abs < 0 ? "var(--red)" : "";
    }
    // Desktop stat cell + mobile popup row.
    if (dtChangeEl)  { dtChangeEl.textContent  = fullTxt; dtChangeEl.className  = valueCls; }
    if (msdChangeEl) { msdChangeEl.textContent = fullTxt; msdChangeEl.className = valueCls; }
  }

  // ── 24h volume (desktop stat + mobile popup) ─────────────────────────
  const msdVolumeEl = document.getElementById("msd-volume");
  if (market && market.volume24h > 0) {
    const vol = Number(market.volume24h);
    const quote = market.quoteToken || "";
    const volTxt = "$" + vol.toLocaleString("en-US", { maximumFractionDigits: 2 }) + (quote ? " " + quote : "");
    if (dtVolumeEl)  dtVolumeEl.textContent  = volTxt;
    if (msdVolumeEl) msdVolumeEl.textContent = volTxt;
  } else {
    if (dtVolumeEl)  dtVolumeEl.textContent  = "—";
    if (msdVolumeEl) msdVolumeEl.textContent = "—";
  }

  // Re-evaluate desktop header fit (value/name widths just changed).
  updateMarketHeaderMode();
}

// ── Depth / Longs / Shorts / side health (desktop stats + mobile popup) ──
// One getMarketTele query serves the whole tail of the bar: depth is
// Σ price×qty across every resting bid and ask (walked live canister-side);
// Longs/Shorts are the per-side position notionals and Long/Short Health
// the side's MERGED-BOOK collateral÷debt — recomputed on the 30s heartbeat
// (see tickMarketSideAgg in the backend). Health is a ratio against the
// venue's fault lines: 1.25 required to open, 1.15 liquidation — shown red
// below 1.25, "∞" for an all-equity side. Cached per market so a switch
// paints the last-seen figures instantly while the fetch is in flight;
// "—" only before a market's first fetch.
const _marketTeleCache = new Map();   // marketId -> [[elementId, text, className|null], …]

// The opt-wrapped health arrives as raw e8 (normMoney keys only direct
// record fields, not opt elements): [] = no positions on that side.
function fmtHealth(opt) {
  const h = Array.isArray(opt) && opt.length ? Number(opt[0]) / 1e8 : null;
  if (h === null) return { txt: "—", cls: "ms-value" };
  if (h >= 1000) return { txt: "∞", cls: "ms-value" };   // covers HEALTHY_INF
  return { txt: h.toFixed(2), cls: "ms-value" + (h < 1.25 ? " down" : "") };
}

function paintMarketTele(marketId) {
  const slots = _marketTeleCache.get(marketId) ?? [
    ["dt-market-depth", "—", null], ["msd-depth", "—", null],
    ["dt-market-high", "—", null], ["msd-high", "—", null],
    ["dt-market-low", "—", null], ["msd-low", "—", null],
    ["dt-market-longs", "—", null], ["msd-longs", "—", null],
    ["dt-market-shorts", "—", null], ["msd-shorts", "—", null],
    ["dt-market-lhealth", "—", "ms-value"], ["msd-lhealth", "—", "ms-value"],
    ["dt-market-shealth", "—", "ms-value"], ["msd-shealth", "—", "ms-value"],
    ["dt-market-lliq", "—", null], ["msd-lliq", "—", null],
    ["dt-market-sliq", "—", null], ["msd-sliq", "—", null],
  ];
  let changed = false;
  for (const [id, txt, cls] of slots) {
    const el = document.getElementById(id);
    if (!el) continue;
    if (el.textContent !== txt) { el.textContent = txt; changed = true; }
    if (cls !== null && el.className !== cls) { el.className = cls; changed = true; }
  }
  // Width changed → re-fit. Skipped on the (frequent) no-change polls so the
  // 2s poll doesn't buy a forced reflow every tick.
  if (changed) updateMarketHeaderMode();
}

async function refreshMarketTele(marketId) {
  const src = appState.actor || appState.publicActor;
  if (!src || !marketId) return;
  try {
    const r = await src.getMarketTele?.(marketId);
    const tele = (Array.isArray(r) ? r[0] : r) ?? null;
    if (!tele) return;   // older backend without the method, or unknown market
    const usd = (v) => "$" + Number(v || 0).toLocaleString("en-US", { maximumFractionDigits: 0 });
    // High/Low match the Price/Mark cells: formatPrice, no "$" prefix.
    const px = (v) => (Number(v) > 0 ? formatPrice(Number(v)) : "—");
    // Nearest liquidation distance: opt bps (raw — not a MONEY_KEYS field),
    // quantized canister-side to the side's disclosure precision. Longs
    // liquidate below the mark, shorts above, hence the fixed signs.
    const liq = (opt, sign) => (Array.isArray(opt) && opt.length
      ? sign + (Number(opt[0]) / 100).toFixed(1) + "%" : "—");
    const lh = fmtHealth(tele.longHealth);
    const sh = fmtHealth(tele.shortHealth);
    _marketTeleCache.set(marketId, [
      ["dt-market-depth", usd(tele.totalDepthUsd), null], ["msd-depth", usd(tele.totalDepthUsd), null],
      ["dt-market-high", px(tele.high24h), null], ["msd-high", px(tele.high24h), null],
      ["dt-market-low", px(tele.low24h), null], ["msd-low", px(tele.low24h), null],
      ["dt-market-longs", usd(tele.longNotionalUsd), null], ["msd-longs", usd(tele.longNotionalUsd), null],
      ["dt-market-shorts", usd(tele.shortNotionalUsd), null], ["msd-shorts", usd(tele.shortNotionalUsd), null],
      ["dt-market-lhealth", lh.txt, lh.cls], ["msd-lhealth", lh.txt, lh.cls],
      ["dt-market-shealth", sh.txt, sh.cls], ["msd-shealth", sh.txt, sh.cls],
      ["dt-market-lliq", liq(tele.longNearLiqBps, "-"), null], ["msd-lliq", liq(tele.longNearLiqBps, "-"), null],
      ["dt-market-sliq", liq(tele.shortNearLiqBps, "+"), null], ["msd-sliq", liq(tele.shortNearLiqBps, "+"), null],
    ]);
    if (marketId === selectedMarket) paintMarketTele(marketId);
  } catch (e) { console.warn("getMarketTele failed:", e?.message || e); }
}


function setStaleIndicator(id, show) {
  const el = document.getElementById(id);
  if (el) el.style.display = show ? "inline" : "none";
}

function showToast(message, type = "info") {
  const container = document.getElementById("toast-container");
  const toast     = document.createElement("div");
  toast.className = `toast ${type}`;
  toast.textContent = message;
  container.appendChild(toast);
  setTimeout(() => toast.remove(), 4000);
}


// ── Intelli section: AI Assistant + Data Explorer (OQL query browser) ─
// The Data Explorer is a generic browser over the canister's OQL surface:
// pick an entity from schema(), build a filter/sort/limit query (or hand-edit
// the JSON), and run it via execute(). Results respect row-level scoping —
// the caller sees public entities + only their own pools/positions.
// active Intelli sub-tab now lives on appState (state.js) — shared with explorer.js.
// Set once the user explicitly picks a sub-tab (#ai/<sub> — tab clicks
// route through the hash). Until then the section default is the AI
// Assistant, and refreshAiGate may move us onto it when the key resolves.
let intelliUserChose = false;
// The user's LAST explicit sub-tab pick was the assistant. A click on the AI
// tab that lands while aiConfigured is still unknown/false demotes to the
// explorer (showIntelliTab) — this flag lets refreshAiGate honour that click
// as soon as the key resolves, instead of the click being silently swallowed.
let intelliWishAi = false;
// Query whether the backend AI assistant is configured and show/hide the
// "AI Assistant" tab accordingly. When it's off, the tab button is hidden and
// any attempt to route to it falls back to the Data Explorer. Called at
// startup and after sign-in (the query is public, so anonymous works too);
// a THROWN probe (transient network) retries once rather than leaving the
// tab hidden for the whole page life.
let _aiGateRetried = false;
async function refreshAiGate() {
  let on = false, threw = false;
  // Signed-out visitors only have the anonymous publicActor (appState.actor
  // is set on sign-in) — the query is public, so either actor works.
  const a = appState.actor || appState.publicActor;
  try { if (a?.aiConfigured) on = await a.aiConfigured(); } catch { on = false; threw = true; }
  appState.aiConfigured = !!on;
  const btn = document.querySelector('.intelli-tab[data-intelli="assistant"]');
  if (btn) btn.style.display = on ? "" : "none";
  if (!on && appState.intelliTab === "ai") showIntelliTab("explorer");
  // Key confirmed → move onto the assistant when either (a) the user never
  // picked a sub-tab (it's the section default) or (b) their last explicit
  // pick WAS the assistant but arrived before the gate resolved.
  if (on && appState.intelliTab !== "ai" && (intelliWishAi || !intelliUserChose)) {
    if (document.getElementById("intelli-view")?.classList.contains("active")) {
      showIntelliTab("ai");
    } else {
      appState.intelliTab = "ai";
    }
  }
  if (threw && !_aiGateRetried) { _aiGateRetried = true; setTimeout(refreshAiGate, 4000); }
}

function showIntelliTab(name) {
  // URL/button slugs are assistant|memory; the internal tokens stay ai|explorer
  // (pane ids, appState.intelliTab, the AI gate all key off them).
  name = INTELLI_SLUG_TO_TOKEN[name] || name;
  if (name !== "ai" && name !== "explorer") name = "ai";   // section default
  // The assistant tab is unavailable when the backend has no AI key configured.
  if (name === "ai" && !appState.aiConfigured) name = "explorer";
  appState.intelliTab = name;
  document.querySelectorAll(".intelli-tab").forEach((b) =>
    b.classList.toggle("active", (INTELLI_SLUG_TO_TOKEN[b.dataset.intelli] || b.dataset.intelli) === appState.intelliTab));
  const ex = document.getElementById("intelli-pane-explorer");
  const ai = document.getElementById("intelli-pane-ai");
  if (ex) ex.style.display = appState.intelliTab === "explorer" ? "" : "none";
  if (ai) ai.style.display = appState.intelliTab === "ai" ? "" : "none";
  // AI tab fills the viewport (prompt pinned bottom); explorer keeps page flow.
  document.getElementById("intelli-view")?.classList.toggle("intelli-fill", appState.intelliTab === "ai");
  if (appState.intelliTab === "explorer") {
    dxEnsureSchema();
    dxUpdateIdentity();
  } else {
    assistantOnShow();   // focus the input + seed the greeting once (assistant.js owns _asstSeeded)
  }
  // LAST: this function reassigns pane display and intelli-fill above, so the
  // signed-out gate has to win after it, not before.
  applyIntelliAuthGate();
}


// ── Start ───────────────────────────────────────────────────────
init();
