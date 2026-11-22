# Release notes

The product version — the `VERSION x.y` badge on the loading page, `package.json`'s
`version`, and the backend's `getAppVersion()` / `getCanisterInfo.appVersion` — is one
number, bumped at every release and held in step by `tests/test_deploy_hygiene.sh` §6bf.
The on-chain API carries its own `apiVersion` (`getMarketSpecs` / `getAccessPolicy`
report it live; [`candid/README.md`](../candid/README.md) is its contract), which moves
only on a breaking change. Bot authors watch the second number; everyone else the first.

Entries are written in user terms. The design detail lives in the documents each entry
cites.

## 1.81.0 — 2026-11-04

Everything landed since the 1.80 build the live targets took on 2026-11-03/04 (`main`
63307e2): the operator's phone round of 2026-11-04 — the account value in the header opens
into a ledger of what it is made of, the menu on phones is a drawer over the page, the
Account area's phone fixes — and, under the hood, the retirement of the one-shot migration
the 1.80 upgrade applied. A minor: nothing in the public API changed (apiVersion stays 6.0.0).

Source: the commits on `main` (`git log 63307e2..`); the operator's frontend round landed as
direct commits and carries no task ids, so the short shas are cited instead. The Docs → Change
log carries the same list in the app.

- **The account value opens** (9fc6915, 422b8a0). The figure beside your name in the header is
  a button: click it for a compact ledger of what it is made of — the wallet's assets with
  their quantities, each margin pool on its own line with its legs, leverage and distance to
  liquidation (red inside 20 %), the AMM Vault and Insurance Fund stakes with their LP / shares,
  a cooldown and a staged withdrawal — every row a link into the Account tab it belongs to, and
  what has changed since you last looked, attributed to prices, positions, yield and trades &
  fees exactly to the cent. The baseline is your last look (the sign-in snapshot before any;
  the first open says so), a venue you hold nothing in reads "nothing yet", and while the
  ledger is open it follows every balance refresh, a row whose figure moved flashing once.
  Opening it closes the user menu; a click elsewhere, Escape or following a row closes it. On
  phones the same ledger is a sheet from the bottom over a scrim.
- **The menu on phones is a drawer** (6f63df9). The hamburger slides a 248 px panel in from
  the left over the page — which stays exactly where it was, instead of being pushed down by a
  header that grew — with the lockup, the theme switch and a close at its head, the sections as
  rows, your username pill, and Sign in / out at its foot; the close, the scrim, Escape or a
  tap on a row puts it away. **Platform** (the former System) and the pill carry a chevron: a
  tap opens their sections as a titled list with a "Menu" row back. **AI** is an icon tab —
  last in the desktop nav, and on phones in the header itself, after the account value.
- **Signing out clears the account value** (c8daaed). On phones the header's figure used to
  keep its last reading after Sign out until the next refresh; it now goes with the session.
- **Two phone fixes in the Account area** (838a66e). The profile card stacks on phones — the
  avatar beside the name and ID, the principal and the member line across the card, the
  regenerate control a foot row with its count beside it — instead of squeezing its details
  into a sliver that broke the username at its hyphens and wrapped the principal every eight
  characters; and the drawer's account pill is avatar, name and chevron only — the account
  value stays in the header, in view beside the open drawer — with a long username ellipsised
  on one line.
- **For bot authors: nothing to change.** apiVersion stays 6.0.0 and `candid/backend.did` is
  the one the 1.80 drop published, byte for byte.
- **Under the hood** (1793580820). The sixth one-shot state migration, which the 1.80 upgrade
  applied once to each live target, is retired from the build — its frozen pre-6.0.0 shapes
  and their test leave the tree — so this upgrade is a plain one. The loading page's badge
  reads `VERSION 1.81`; a tab left open on 1.80 refreshes itself, and Platform → Canisters
  shows the backend answering `1.81.0` beside it.

## 1.80.0 — 2026-11-04

Everything landed since the 1.75 build the live targets took on 2026-11-01 (`main` 1851081):
the operator's Place Order round of 2026-11-02/03, the margin preview's agreement with the
release clamp, and the round that landed on 2026-11-01/02 after that build was cut — the
launch notice, the fuel banner, the sign-in library, the archive's tolerance of a missing
segment — which rode the 1.75 public drop of 2026-11-02 and reaches the live targets with this
release. A minor: nothing in the public API changed (apiVersion stays 6.0.0).

Source: the merge commits on `main` (`git log --first-parent 1851081..`), one task id per
item; the operator's frontend round landed as direct commits and carries none ("operator
round"). The Docs → Change log carries the same list in the app.

- **The Place Order box reads top-down, as a trader decides** (operator round, 2026-11-02).
  Spot | Margin are the header's tabs, Buy | Sell (Long | Short on Margin) is the one coloured
  surface, the money rows — "Available to trade" and the resting orders; on Margin the wallet
  margin, the buying power and the pool's free margin — come before the inputs they constrain,
  Limit | Market sits on the price field it swaps, the price field offers Mid / Bid / Ask from
  the live book, the unit sits inside the size field, the size slider is a drawn track with
  quarter stops, an editable % box and a "100% = N ICP" line, expiry, max slippage and margin
  pool are one-line rows, and the button states the order it will place. The frame is
  feedback: the outline takes the side's hue (mint buy, clay sell) and Margin adds a second
  hairline inside the edge; the option rows wrap instead of overflowing, so the box never
  grows a sideways scrollbar at any width.
- **The Margin ticket takes the collateral first** (operator round, 2026-11-03). A Margin
  field and slider over everything you can commit — the pool's free margin first, shaded on
  the rail, then the wallet — and a Leverage slider from 1× up to the ceiling the engine
  allows for that margin, labelled "Max N.NNx"; the Size is derived (margin × leverage ÷
  price) and still typable, back-solving the margin. The ceiling is the engine's own answer
  (`previewOpenPosition`), never a table in the page, and the leverage chips are gone. The
  preview and the order use the margin you set, the derived size is floored to the asset's
  precision (no more "Need $22,112 margin — only $22,112 in wallet"), and a real shortfall is
  stated to the cent.
- **The slider's 100% is what the wallet can actually reserve** (operator round, 2026-11-03).
  A market buy is sized at the slippage cap plus the taker fee — the figure the engine
  reserves — a limit buy at its price plus the fee, every size on the spendable balance (net
  of resting orders, which "Available to trade" now shows), and the hint says what the figure
  is net of: "100% = N ICP after the 5% slippage cap and the 0.10% fee". A market long's
  leverage note explains its lower ceiling ("ceiling at the 5% slippage cap — a limit order at
  the mark allows more"), and the ceiling keeps two decimals (Max 1.96x, not 1.9x).
- **Quantities carry thousands separators** (operator round, 2026-11-03). "Long 108,265.4
  ICP", "100% = 2,012.4 ICP" and the resting-orders row read like the money figures beside
  them; the typed Size field keeps raw digits, and the order book and trades stay ungrouped.
- **The preview judges a long and a short by the clamp the fill is held to** (1793732895,
  1793733917). `previewOpenPosition`'s `maxSizeBase` is the smaller of what the vault can lend
  and what the opening-health bar allows at the worst-case price, for either side, and
  `canOpen` is false past it with the side named — before, a long's preview promised what the
  release then clamped. Docs → Margin (§5 and the quick reference) and `getApiDoc` state the
  ceilings the engine enforces today, 1 / (1.25 − LTV): BTC/ETH ≈2.9×, SOL ≈2.5×, ICP ≈2.2×.
- **The launch notice** (1793573913, 1793575027, 1793577015). The strip above the header
  carries the operator's launch text (shown once more to anyone who had dismissed the old
  one); on phones (≤480 px) it collapses to its first sentence and the story link with a
  keyboard-operable Read more / Show less, and its ✕ sits in the strip's top-right corner
  instead of trailing the text.
- **The fuel banner** (1793572114, 1793575028, 1793575742). The freeze countdown shows only
  inside 24 hours (System → Canisters keeps its 72-hour view), the treasury sentence matches
  the venue's posture — on a play venue it says the self-funding treasury holds no real
  assets — and is painted right the first time rather than after the next poll, and the
  donation tiers (the 24-hour countdown, the low-fuel appeal) step aside on phones while the
  frozen tier stays on every width.
- **Sign-in on the current Internet Identity library** (1787222434). `@icp-sdk/auth` 11.1.0
  and `@icp-sdk/core` 6.1.1: the Internet Identity window opens at `id.ai`, an idle hour signs
  you out and reloads as before, signing out revokes the session at Internet Identity, and a
  session that ends elsewhere — expiry, a sign-out in another tab — is noticed within
  15 seconds and toasted. [`docs/session-policy.md`](session-policy.md) describes the
  mechanics.
- **A missing history segment no longer stalls your history** (1793569495). A sealed archive
  segment whose canister is gone is tolerated everywhere it is read: the trade-history
  backfill closes that source and appends "· segment N unavailable" to its progress line, and
  Account → Archive skips the dead hop with a per-segment note instead of parking on it. The
  controller can name the failure (`adminUpgradeArchives` reports "N upgraded, B skipped,
  F failed — <canister>: <reason>") and retire the row (`adminDropMissingArchive` drops a
  verified-missing segment and declares the hole on the tape as a `#gap` event, as an
  archive shed does).
- **Local venues** (operator round, 2026-11-03). A venue served from a port of its own is
  registered as a sign-in origin when it is deployed, so Verify-with-Google — and the play
  deposits it unlocks — work on it, not only on the canonical `:8000` venue.
- **For bot authors: nothing to change.** apiVersion stays 6.0.0 and `candid/backend.did` is
  the one the 1.75 drop published. The archive item's `unavailable` field on the
  archived-events pagers is additive and optional (a 6.0.0 decoder reads the reply unchanged),
  and the two methods it adds are controller-only.
- **Under the hood** (1788744109). The build carries the sixth one-shot state migration — it
  sweeps the six PendingMatch-era fossils the 6.0.0 removal left in stable memory — so this
  upgrade of each live target is a migrating one, applied once and then retired like its five
  predecessors. The loading page's badge reads `VERSION 1.80`; a tab left open on 1.75
  refreshes itself, and System → Canisters shows the backend answering `1.80.0` beside it.

## 1.75.0 — 2026-11-01

The first product release since 1.60 (stamped 2026-08-07) — one release, shipped in two
steps. The apiVersion 6.0.0 hardening below (the API, margin, vault and matching changes)
reached both live targets — the cloud-engine competition venue and the dedicated subnet —
on 2026-10-31 under the 1.60 stamp, which is what `getAppVersion` and the loading badge kept
showing; the rest of this release, the 2026-11-01 round in the next section, ships with the
1.75 stamp. A major, because the public API broke (apiVersion 6.0.0) and because margin,
vault and matching behaviour changed in ways a trader or a bot author will notice.

### The 2026-11-01 round: light theme, Agent Chat, a Home page, the chart and the menus

Source: the round's merge commits on `main` (`git log --first-parent 1f2f020..`), one task
id per item; the Docs → Change log carries the same list in the app.

- **Light theme** (1793489931, 1793494438). A sun/moon toggle at the top right of the header
  (and at the top of the mobile drawer) switches the exchange to a light theme; the choice is
  remembered per browser and, until you pick, the site follows your system preference.
  Charts, identicons, the loader, the order book's depth bars and the liquidation heat map
  re-colour with it, and the candle and mini charts keep their visible range and crosshair
  across a toggle.
- **AI → Agent Chat** (1793489927). The Intelligence sub-tab is labelled Agent Chat and
  `#ai/agent-chat` is its address; the legacy `#ai/assistant` link still lands there.
- **Agent Chat rebuilt on trust rules** (1793489932). A proposed action is resolved and
  validated before its confirm card — the exact market, pool and token are looked up, an
  ambiguous name comes back as a question listing the candidates, amounts are converted in
  code, and what the canister would refuse is refused up front; declining is final, and a
  confirmed action is re-read before it is reported, then the Markets and Account views
  refresh. The chat knows who is asking, where they are and today's date; ten suggested
  prompts in groups; live step labels; a footer stating what it can do right now; help
  questions answered from the Docs with in-app citations — also with the AI key off or the
  model down; failures classified plainly (a refusal, a transport failure, the step budget)
  with the question put back in the composer; the transcript survives a reload in the tab
  and is purged at sign-out.
- **Agent Chat's prompt and help lookup** (1793497427, 1793497428, 1793501313). The standing
  instructions are budgeted — the long venue description sits behind a read tool and the
  first call fell from about 17 KB to about 13 KB; help answers lead with one actionable next
  step, ranked from a curated question → Docs-page map across every tab.
- **MCP guidance removed from the product** (1793489926). The Docs "MCP" page is deleted, its
  cross-links point at Agent Chat and at `candid/README.md` on the public repository, and the
  "Use MCP" link is gone from the AI usage page.
- **A Home page at `#home`, and the straplines** (1793490812, 1793489949). The logo opens a
  Home page — hero, introduction, Swap / Markets / Earn boxes, a live proof strip and an
  open-source section. The strap "Actually decentralized. Secure. Yours." was written for
  Swap first and moved to the Home hero with the page; Swap now reads "Directly swap digital
  assets. No middleman."
- **Docs → Margin explains borrow-at-fill end to end** (1793489928). What a fill borrows, a
  two-slice worked example and a quick-reference row — the page describes the model this
  release ships (below), not the old borrow-at-placement one.
- **History backfill finds archived fills in seconds** (1793489930, 1793495003). The
  trade-history backfill pages fills only (a per-principal fill index on the archive, a
  sort-free merge across segments), probes segments in parallel waves of six with a live
  "segments 7–12 of 42" progress line, and the archive rebuilds its fill and
  deposit/withdrawal indexes itself after an upgrade — twelve serial round trips became two
  waves on a 23-segment chain.
- **Keyboard-operable menus** (1793503737, 1793506246, 1793509280, 1793511304). The chart
  cell's view menu, the order book's price-grouping menus (Markets and Swap), the market
  selector, the price/stats popups, the signed-in user menu and the drop-down selectors
  under Wallet, Swap and Earn are real menu buttons on one shared helper — Tab to them,
  Enter or the arrows open, the arrows move, Enter picks, Esc closes — and the full-size
  chart overlay traps focus while it is open.
- **The chart** (1793498839, 1793498836, 1793502035, 1793510573, 1793498838). The full-size
  overlay is reachable again through an expand (⤢) button on the chart bar — the button that
  opened it had been hidden since the first release — and is a dialog (Esc closes, focus
  returns, the header wraps under 900 px); a refresh merges the newest page into the held
  series, so scrolled-in older history and the visible range survive the 10 s / 5 s ticks;
  the older-history lazy load fires only on a real pan (every interval switch, overlay open
  and first load used to buy one wasted query); after a pan an interval switch or overlay
  open lands exactly at real time; and the time-axis labels honour the tick type — a year, a
  short month, day + month, HH:MM or HH:MM:SS.
- **Oracle error popover and focus** (1793512901, 1793514706). The error popover on a price
  source survives the 5-second stats re-render (re-anchored on its re-drawn trigger, or
  hidden once the source recovered), follows a page scroll or resize, and the focused
  trigger keeps keyboard focus across the re-render; the token-select buttons carry an
  accessible name ("Sell token: BTC").
- **Copy buttons work** (1793506794). The page's Permissions-Policy allows its own clipboard
  writes (`clipboard-write=(self)`; `clipboard-read` stays denied), so the explorer's
  principal / URL Copy buttons and the Agent Chat error-body Copy actually copy — they were
  silently dead.
- **Account → Deposit** (1793489929). The pane fills the Account container like its sibling
  panes instead of a 760 px column.
- **Docs aurora** (1793490294). The glow behind The launch / What is MULTI/DEX? / Prizes
  fades out at its edges instead of ending in a hard vertical line, in both themes, and no
  longer widens the Docs page on a phone.
- **Hosting** (1793503326). The frontend is served by the `@dfinity/static-site`
  certified-assets recipe; the security headers (CSP and the rest) are unchanged, and
  cached files carry an ETag so the browser revalidates (304) instead of re-downloading.
- **Local venues: a stale or foreign venue cookie no longer breaks the app** (1793499221).
  The app picks its own venue row, self-heals once and names the mismatch in the banner.

### Also in the 1.75 build (landed 2026-11-01, after the entry above was cut)

The entry above was written from `main` at efc2f7c (2026-11-01, 17:06 +0100); the 1.75
build the live targets took that evening (21:44Z) was `main` 1851081. Everything that landed
between the two shipped live as 1.75 and is recorded here — the 1.80.0 entry deliberately
starts at 1851081. Source: `git log --first-parent efc2f7c..1851081`, one task id per item
(the test, smoke-harness and deploy-tooling merges in that range are not entries); the
Docs → Change log carries the same items at the end of its 1.75 entry.

- **Earn: a one-tap Max for the LP withdraw field** (1793553361, 1788746837). A Max button
  between the field and its submit fills it with the most you can withdraw instantly — the
  figure the placeholder already quoted, which you used to retype, commas and all, into a
  number box that rejects them — and is disabled while there is nothing to fill or the submit
  is paused. The figure is your instant maximum less a 0.01% drift allowance, named in the
  field's hint ("max now N after a 0.01% drift allowance"), so the request settles even if the
  vault re-prices between the quote and your request's settlement; the tiles keep the exact
  quote and the backend's cap check stays exact.
- **Earn: a settled deposit is reported settled** (1793558036, 1793560085). Since apiVersion
  6.0.0 a deposit answers with a staged request, but the card still read the reply as the
  old immediate mint and never recognised the settlement — twelve polls, then "Your deposit
  is still staged" under a position that had minted seconds earlier. The card now reads the
  request id and reports "Settled: minted N LP at the post-request NAV." (or that the request
  was cancelled, and why), and a lingering "still staged" line clears itself against the next
  staged view. Separately, a slower render started before settlement could finish after a
  newer one and repaint LP 0.00 with the stale "Staged deposit #N" line over the minted
  position; the newest render now owns the paint.
- **A season seal cancels pending staged LP requests, on the tape** (1788731610). A deposit or
  withdrawal still staged when the season is sealed (or the exchange reset) is cancelled
  before the wipe — "season sealed before settlement; nothing settled, funds released" in
  your recent outcomes and as a `vault` row on the tape, the reservation released — so the
  cancellations open the new epoch's record instead of the requests vanishing with the old
  world. `getApiDoc` states the rule; [`docs/amm-vault-design.md`](amm-vault-design.md)
  records it under the season boundary.
- **The vault's expected-loss provision is priced on accrued debt** (1788736589). The
  provision the Earn card shows (and the NAV deducts) — the expected loss on under-water or
  near-liquidation margin loans beyond the insurance fund's first-loss — is refreshed on
  every mark update and heartbeat; that scan now accrues each margin pool's loans to the scan
  instant first, so it prices the debt the liquidator would see rather than a figure the
  interest since the last booking had left behind. A scan driven by your own deposit or
  withdrawal settling does not accrue, so your request never moves the NAV you were quoted
  at. [`docs/amm-vault-design.md`](amm-vault-design.md), the per-loan impairment reserve.
- **Agent Chat on the sign-in edge** (1793554545, 1793551778). Signing in while Agent Chat is
  the open view shows the greeting at once — after a sign-out on the tab, the next sign-in
  used to leave the pane empty until you left and came back — and a page loaded on
  `#ai/agent-chat` restores your conversation once the session names your principal, exactly
  once and never across principals; the sign-out purge is unchanged.
- **Agent Chat reads the leaderboard in dollars** (1793551691). The OQL leaderboard entity
  serves `profitUsd` / `capitalUsd` / `equityUsd` in human units like the market, position
  and user-event money columns (`returnBps` stays basis points), and the chat's standing
  instructions list it among them — "Who is top of the leaderboard?" had printed a $10,000
  capital as $10,000,000. The candid `getLeaderboard` is unchanged.
- **Home, as it went live** (1793554905, 1793553989, 1793554661, 1793554852, 1793554039). The
  "What is MULTI/DEX?" introduction under the hero is gone (the Docs keep the page); the
  hero's sub-paragraph is the operator's text; the Swap and Markets boxes carry product
  screenshots and the Earn box a rising-value sketch, each with the operator's copy; the
  open-source section is headed "Open source and verifiable" and carries the operator's two
  paragraphs with the repository link (the issues/bounties paragraph left Home — the Docs and
  the Account view keep theirs); and "Read how it works" opens Docs → What is MULTI/DEX?
  rather than The launch.

### For bot authors: apiVersion 6.0.0 (breaking)

Source: [`candid/README.md`](../candid/README.md), "Major bumps so far" — 6.0.0,
September 2026 (task 1788731608).

- **`depositLp` / `withdrawLp` return a staged request, not the result.** Both now answer
  `{#ok : StagedLpRequest; #err : Text}`: the deposit legs (or the shares) are reserved at
  the call and the request settles at the first vault valuation whose marks all postdate
  it. Read the request id from `#ok` and poll `getMyStagedLpRequests()` for the outcome —
  a refusal at settlement is a `#cancelled` outcome there, not an `#err` at the call. The
  5.1.0 names `stageLpDeposit` / `stageLpWithdraw` are gone, with no alias: they existed
  for one unreleased minor and never reached a live target.
- **`seedAmmPool` is controller-only.** It is the one immediate mint door left, for the
  seed scripts; an open immediate mint would have been the sniping window the sealed doors
  close.
- **The long-inert protection-window surfaces are removed:** `getMyPendingMatches`
  (always empty since the sealed release replaced the protection window),
  `placeProtectedLimitOrder` (an alias of `placeLimitOrder` whose window was ignored), the
  `pendingMatches` field of the `placeMarketOrder` / `placeLimitOrder*` results (always
  `[]`), the `PendingMatch` / `PendingMatchStatus` types, `setAmmConfig`'s sixth parameter
  `protectionWindowSec` (callers pass five arguments now) and `AmmPool.protectionWindowSec`
  (`getAmmPool` / `getAmmPools` return the record without it).
- **Not in 6.0.0:** `getUserPreferences` stays an update call; it becomes a query at the
  next major (7.0.0), per the operator ruling of 2026-09-17 recorded in `candid/README.md`.
- Since the 1.60 stamp the interface also took three majors that no product release
  announced, each in `candid/README.md`: 3.0.0 (2026-08-17 — the tape gains `#gap` events,
  so an archive shed is declared on the chain itself), 4.0.0 (2026-08-20 — the never-fed
  adverse-flow queries and their type are deleted) and 5.0.0 (2026-08-20 — the tape gains
  `#config` events, so the six authority setters are on the permanent record). A decoder
  built against an older major fails on the first event kind it does not know, by design.

### Margin: a leveraged order holds no debt until it fills

Source: [`docs/limit-order-positions-design.md`](limit-order-positions-design.md)
("borrow timing"), the operator ruling of 2026-09-05 (task 1788467597, decision D5,
option (d)), delivered by H-34; [`docs/amm-vault-design.md`](amm-vault-design.md).

- Until this release a leveraged limit order borrowed its whole leverage from the vault
  the moment it was placed, sized at the worst price it might fill at, and the loan sat
  against the resting order accruing interest until it filled or was cancelled — so a
  far-off resting bid tied up vault liquidity it was not using, and one pool could crowd
  every later borrower out.
- Now placement is a **check**, not a borrow: the order is refused up front if the vault
  could not fund it, then it stages whole. A staged or resting leveraged entry holds
  **zero vault debt**, pays **no carry**, and does not move the vault's balance or anyone's
  instant-withdrawal cap.
- **The fill borrows exactly its quantity**, inside the matching pass, against fresh marks
  for the traded token and the whole collateral basket; interest runs from that instant.
  This holds whether the pool is the taker or a resting maker hit later.
- The one new outcome: if the vault cannot lend at the moment of the fill (it has run dry
  since you placed), the order **does not fill** — the remainder is cancelled and one
  record in `getMyReleaseRejections` says why. Nothing is clamped or retried silently.

### Vault LP: sealed deposits and withdrawals, redemption at NAV, the instant-withdrawal cap

Source: [`docs/amm-vault-design.md`](amm-vault-design.md) §5 — "Redemption at NAV +
pro-rata instant liquidity" (operator decision 2026-09-03), "Locked shares" (operator
decision 2026-09-06) and "Sealed LP requests" (operator decision 2026-09-06).

- **Every LP share redeems at NAV per share** — the same figure deposits are minted at
  (held basket + loan book − insurance arrears, over supply). A deposit-then-withdraw
  round trip is exactly −fee. Until 2026-09-03 an exit forfeited that share's slice of the
  loan book to the LPs who stayed: at 50% utilisation an exiter received half of NAV,
  permanently.
- **Instant withdrawal is capped by liquidity, pro rata.** A loan cannot be handed out in
  kind, so the most you can withdraw *now* is your share of what the vault physically
  holds. A request past the cap is **refused**, with the cap and the reason in the error
  ("$N of your $NAV is lent out … Withdrawable now: $X") — nothing is clamped or queued;
  `getMaxInstantWithdraw` shows the figure before you ask. The shares you do not redeem
  stay yours and keep their claim on the loan book.
- **Locked shares make the cap race-proof.** After a maximum exit your remaining shares
  are locked — your cap reads zero however often you call — until borrowers repay, which
  releases every LP's locks in proportion; the LPs who stayed see their own caps exactly
  where they were. Repeatedly withdrawing the maximum can no longer drain the stayers'
  liquidity.
- **Deposits and withdrawals are sealed.** Both are staged and settle at the first vault
  valuation whose marks all postdate the request — the same price-postdates-entry rule
  orders release on, so nobody can mint or redeem against a mark the market has left.
  Staging arms a fresh price fetch, so settlement takes a second or two, not the old
  60-second cadence, and the "LP deposit paused: … refPrice is stale" flicker is gone.
  Every refusal (the cap, the concentration cap, dust, an unpriced leg) is evaluated **at
  settlement** and recorded as a cancelled request; five minutes without a fresh mark
  cancels and refunds. Watch `getMyStagedLpRequests` for the outcome.

### The September hardening wave (H-01 – H-37)

Source: [`docs/hardening-plan-2026-09.md`](hardening-plan-2026-09.md) — 48 findings of
the 2026-09-02 scan, 37 tasks in six waves, every one landed on main before this release
(35 under their own H-number; H-11 and H-28 through the round-18 tasks that superseded
them). Headlines only; each task's brief under `docs/tasks/done/` carries the detail.

**Operator machine & deploy pipeline**
- H-01 · The keychain helper takes no password on the command line, grants nothing
  unsigned and excludes controller identities; the earlier grants were revoked.
- H-02 · Every deploy pre-flights the pinned canister ids and controller sets and reads
  the posture back after install; the posture reader fails closed; the merge gate refuses
  id-mapping edits.
- H-03 · The skill sync never replaces or prunes a directory it did not install.
- H-04 · The integration suites use no fixed shared-`/tmp` names.

**Solvency & book poisoning**
- H-05 · A margin pool's exposure-reducing fill is bounded so its equity at the worst-case
  price stays non-negative; pool market orders get the taker price bound everyone else has.
- H-06 · Any debt-increasing pool action needs fresh marks for the whole collateral basket;
  the release clamp fails closed on a missing or stale price.
- H-07 · A pool order left with nothing staged and nothing resting repays what it had
  borrowed idle (now moot — see "a leveraged order holds no debt until it fills").
- H-08 · The swap page's limit-order path enforces the price band like every other limit
  path.
- H-09 · Every book-walking simulation has a scan budget, the fill-or-kill gate fails
  closed when its budget runs out, and public depth queries are bounded.
- H-10 · A resting order whose owner can no longer fund it is cancelled with a notice, and
  every balance-reducing action re-validates resting orders.
- H-11 · One off-price USD quote can no longer freeze the mark: a USD source group that is
  not itself robust cannot override the pooled aggregate (landed as round-18 task
  1788465030).
- H-12 · The direct-swap market cap anchors to the AMM/oracle mid, not the book's best
  resting order.
- H-13 · Staged cross-swaps count toward the per-owner staged cap and the shed-floor depth.
- H-14 · Uptime samples credit only depth the maker could actually honour at the time.
- H-15 · Caller-supplied amounts have a ceiling before valuation; refusal text never
  formats a caller-sized number.
- H-16 · A merged archive shed emits one gap event covering the whole coalesced range.
- H-17 · `#play` refuses a repeated genesis mint once the venue is live.

**Verifier & frontend**
- H-18 · The ledger verifiers, both mirrors: anchored at origin by default, no unanchored
  success, every segment's certificate must verify, every re-anchor must be justified,
  tiled gaps accepted.
- H-19 · CSV exports neutralise leading formula characters; pool names are restricted to a
  benign character set.

**Matching fairness & release pacing**
- H-20 · Every cross-swap leg executes under an absolute cap anchored to its market's mid;
  sell sizing never divides by the book's best bid.
- H-21 · No player-reachable taker settles inside the caller's own message: the
  all-or-nothing cross-swap is staged and checked at release like everything else.
- H-22 · Both release passes are paced (a per-pass release cap and fill budget, resuming
  next tick) and the requote/release dispatchers sit behind a failure-streak breaker.
- H-23 · The sealed model keys on the price fetch's dispatch time — the anti-snipe gate,
  the sweep gate, cross-swap freshness and the owner commit lock all read the same clock.
- H-24 · The L4 maker shield holds only while a genuine repricing intent is in flight;
  shielded depth earns neither display weight nor uptime; the sweep honours the shield for
  non-AMM makers.
- H-25 · The AMM tick / finaliser breaker and the pacing constants are documented as an
  extension of the heartbeat-isolation design.

**Season boundary & state growth**
- H-26 · Bridge: a refused admission leaves its state untouched; a wipe-pending fence lets
  the season wipe complete against a sustained admission stream; ineligible callers never
  occupy the interlock.
- H-27 · Bridge: an amount above the ceiling is refused before any write; a failure on the
  exchange side rolls the write-ahead back.
- H-28 · The season seal is atomic with its preconditions — a sealing latch across the
  Bridge wipe round-trip (landed as round-18 task 1788465019).
- H-29 · Pool principals are unique for the lifetime of the archive set; season-archive
  queries pass only principals the caller owned in that season.
- H-30 · Unregistered principals reach only the pre-registration methods; state-writing
  methods require registration; dead-man fires are capped per pass.
- H-31 · Per-account trade history costs proportional to your own matches; anonymous
  history queries return before touching the tape.
- H-32 · One account's inflow into the archive through the exit set is bounded without
  ever refusing a genuine exit; a healthy archive never loses history to user-driven
  inflow.
- H-33 · The play-deposit allowance is valued only at a fresh, unpended mark.
- H-34 · The idle pre-borrow is gone — see "a leveraged order holds no debt until it fills".
- H-35 · Insurance-penalty yield vests with holding time (an unstake cooldown).
- H-36 · Pre-registration profile and preference records are capped and expire.

**Oracle fan-out**
- H-37 · The mark is applied on a robust quorum or a per-refresh deadline; one slow price
  provider cannot delay the aggregate past the staging window.

### The funding authority

Source: [`docs/deployment-modes.md`](deployment-modes.md), kill matrix (task 1789609263,
keychain hardening F17, 2026-09-17).

- The simulated traders are refilled by a **funding authority**: a single non-controller
  principal the controller designates (`setFundingAuthority`, cleared with `null`),
  admitted to the two balance setters and the scoped balance read and to nothing else. The
  live controller key signs no refill, so the key that can upgrade the exchange is never a
  key a bot process holds.
- Every designation and clearance is a `#config` row on the public tape, so who held the
  role and when is part of the permanent record; `whyAmIRefused` reports the role.
- On `#production` the role does not exist — the setter refuses, as the mints it would
  admit already do.

### Under the hood

- The five one-shot state migrations applied to the live targets between June and
  September (the last, the "fossil sweep" of parked stable fields, rolled 2026-09-03) are
  retired from the code: this build is an ordinary in-place upgrade of either target
  (`src/backend/main.mo`, header note).
- The loading page's badge reads `VERSION 1.75`; a tab left open on 1.60 refreshes itself
  (the self-update introduced in 1.52), and System → Canisters shows the backend answering
  `1.75.0` beside it.
