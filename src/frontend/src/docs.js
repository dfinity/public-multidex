// ── Docs content ───────────────────────────────────────────────────
// The on-site documentation, one entry per page. Pure data — no imports, no
// DOM access — so main.js can bundle it statically and render pages into the
// #docs-view shell (see docsRoute() in main.js). Registry order IS the story
// order: the prev/next pager walks this array, so a reader who starts at
// "The launch" and keeps pressing Next covers the whole exchange.
//
// Conventions inside `html` strings:
//   <a href="#docs/slug">           — cross-page link (real hash routing)
//   <a data-docs-goto="name">       — scroll to #docs-sec-<name> on THIS page
//   h1 + .docs-crumb + .docs-lead   — every page's standard header block
// Facts stated here are grounded in the backend (main.mo + lib/*) — keep them
// in sync when constants change (fee ladder, clamps, health ratios…).

export const DOCS_PARTS = [
  "Foundations",
  "Trading",
  "Costs & rewards",
  "Beyond spot",
  "Money & data",
  "Automate & integrate",
  "Community",
];

export const DOCS_PAGES = [

  // ════════════════════════════════ Part I — Foundations ═══════════
  {
    slug: "launch",
    nav: "The launch",
    title: "Welcome to a DEX that's better, and 100% on-chain",
    part: 0,
    blurb: "Why MULTI/DEX is live in play mode — an AI-written, 100%-on-chain exchange headed for NNS governance, and how you can help decide when it's ready.",
    html: `
      <div class="docs-aurora" aria-hidden="true"><i></i><i></i></div>
      <div class="docs-crumb">Part I · Foundations</div>
      <h1>Welcome to a DEX that's better, and 100% on-chain</h1>
      <p class="docs-lead">You're early. MULTI/DEX is a complete crypto exchange — written
      <b>entirely by AI agents</b>, running <b>100% on the Internet Computer</b>, and destined to be
      owned by nobody at all. It's live in <b>play mode</b>: you trade with free dummy crypto, so
      <b>nothing you do can cost you real money</b>. Play well and there are real prizes of ICP
      tokens. In the
      process, you will help advance MULTI/DEX through its community evaluation phase into
      production.</p>

      <div class="docs-start">
        <div class="docs-start-head">Start here — about a minute</div>
        <ol class="docs-start-steps">
          <li><b>Sign-in</b> with Internet Identity and stay anonymous with passkeys (note: while 
          the exchange remains in Play mode, you must sign in via a linked Google account, which
          is anonymized, to help keep each player to a single account).</li>
          <li><b>Collect your free dummy crypto</b> <a href="#account/deposit">here</a>, to join
          the trading competition and win real ICP.</li>
          <li><b>Trade</b> simply using <a href="#swap">Swap</a> or the full orderbook
          <a href="#markets">Markets</a> with spot and margin trading features.</li>
          <li><b>Climb the <a href="#leaderboard">leaderboard</a></b>, which scores skill —
          your profit against simply holding what you started with.</li>
        </ol>
        <a class="docs-start-cta" href="#account/deposit">Get your free dummy crypto →</a>
      </div>

      <h2 id="docs-sec-prizes">Prizes and bounties</h2>
      <p>The stakes are paper, but the rewards are real. At the end of each development phase,
      <b>DFINITY awards prizes to the traders at the top of the
      <a href="#leaderboard">leaderboard</a></b>, according to where they rank — so trading
      well here is worth something even though the assets are simulated.</p>
      <p>DFINITY also pays <b>bounties</b> for genuinely valuable contributions: a bug, an exploit,
      a flaw in the mechanics, or an idea that makes the exchange better. Send it to
      <a href="mailto:multidex@dfinity.org">multidex@dfinity.org</a>. Awards are made at DFINITY's
      own discretion, and the more clearly and reproducibly you write it up, the better it fares.
      Details on both are on <a href="#docs/prizes">Prizes &amp; bounties</a>.</p>
      <p class="docs-dim">Using an exploit to inflate your P&amp;L disqualifies the prize; reporting
      it earns the bounty.</p>

      <h2 id="docs-sec-firsts">What you're helping prove</h2>
      <p>Along the way, you will help MULTI/DEX pioneer many firsts:</p>
      <ul>
        <li>the first exchange <b>owned by the world</b>, token free, and
        <a href="#docs/platform">NNS controlled</a></li>
        <li>the first <b>AIware exchange</b> you can
        <a href="#ai">query and instruct through AI chat</a></li>        
        <li>the first <b>genuinely on-chain, open source
        <a href="#docs/markets">order book</a> exchange</b></li>
        <li>the first <b>capital-efficient <a href="#docs/swap">swap</a> platform backed by market order books</b></li>
        <li>the first <b>order book exchange with an autonomous
        <a href="#docs/liquidity">AMM</a></b></li>
        <li>the first <b>order book exchange with verifiable
        <a href="#docs/ledger">proof of reserves</a></b></li>
      </ul>

      <h2 id="docs-sec-play">This is play mode — nobody can lose</h2>
      <p>Right now MULTI/DEX trades <b>dummy assets</b>. Every account starts empty and on-ramps
      through a capped play allowance; the balances, the BTC and ETH and SOL you'll trade, the P&amp;L
      on the leaderboard — all of it is simulated. <b>There is no real money at risk anywhere on the
      exchange.</b> That's deliberate: it lets anyone kick the tyres of a real, full-featured venue —
      order books, a market-making AMM, leverage, yield, a verifiable ledger — with zero downside,
      while the community decides whether it's ready to run for real.</p>

      <h2 id="docs-sec-ai">Written by AI, start to finish</h2>
      <p>The novel part isn't just what MULTI/DEX does — it's how it was built. <b>AI agents wrote all
      of the software</b>: the sealed matching engine, the margin system, the oracle, the AMM, the
      hash-chained archive, the query layer, the AI assistant, and this very page. (One
      consequence, stated plainly: raw archive rows are complete — fill records keep their order
      ids, because chain verification hashes the full canonical row. "De-identified" applies to the
      live convenience queries, never to the permanent tape.) It's an
      extraordinary demonstration of what agents can now build on the Internet Computer using
      <b>Motoko</b>, a software language designed for AI that codes, and for developing AIware — a
      genuinely sophisticated financial application, produced by AI, running end-to-end as on-chain
      code with no servers hiding behind it, which enables you to analyse your position, and execute
      trades, <a href="#ai">using the built-in Agent Chat</a>. The source is open; you can read every line (see
      <a href="https://github.com/dfinity/public-multidex">the repository</a>) and judge the work yourself.</p>

      <h2 id="docs-sec-owned">Owned by nobody, run by the NNS</h2>
      <p>MULTI/DEX will be <b>owned by nobody</b>. There is no company behind it, no operator, no
      shareholder — in production it is run by the Internet Computer's <b>Network Nervous System
      (NNS)</b>, the on-chain DAO of ICP holders worldwide. That makes it a <b>community effort</b>
      in the literal sense: the people who trade it, test it, read its code and propose changes are
      the ones who shape it, and eventually the network as a whole votes on it. There is no admin with a database console, and — crucially —
      <b>no secret backdoor keys</b>. It is upgraded only by the NNS: code ships by public
      proposal and on-chain vote, in the open. Nobody can quietly pause withdrawals, edit balances, or
      slip in a change. This is what "trustless" actually requires, and it's covered in depth in
      <a href="#docs/platform">Trustless by construction</a>.</p>

      <h2 id="docs-sec-help">Every trade is a test</h2>
      <p>The community isn't just watching; it's part of development. Trading hard is itself the
      contribution — every order you place and every edge case you hit stresses a venue that is
      being proven before it handles real value. Read the
      <a href="https://github.com/dfinity/public-multidex">source</a>, poke at the mechanics, earn
      <a href="#docs/badges">badges</a>, and send anything that looks wrong to
      <a href="mailto:multidex@dfinity.org">multidex@dfinity.org</a>. That is the entire point of
      the weeks in play mode.</p>

      <h2 id="docs-sec-onchain">100% on-chain — and why that's rare</h2>
      <p>"On-chain" is a claim almost everyone makes and almost no one fully meets. MULTI/DEX means it
      literally — the matching engine, the books, custody, prices, history, and the front-end you're
      reading are all canister code on a public network. For contrast:</p>
      <ul>
        <li><b>vs. Ethereum DeFi.</b> The contracts may be on-chain, but the <i>front-ends</i>
        typically aren't — they're websites run by for-profit companies on ordinary servers, which can
        change, gate, or disappear. And because that website is where you actually sign transactions,
        a <b>hacked front-end puts traders directly at risk</b>: a compromised domain or an injected
        script can quietly swap in a malicious transaction and drain the wallet that trusted it — a
        failure mode that has hit real DeFi users more than once. Here the app itself is served by the
        exchange canister; there is no company-run website in the middle to compromise. Meanwhile,
        front-running by validator nodes able to order transactions is seen as a feature called
        <b>MEV</b> (Miner Extracted Value).</li>
        <li><b>vs. HyperLiquid.</b> It's fast, but it runs on what amounts to a dedicated,
        purpose-built cluster and is <b>entirely closed-source</b>. Because no one outside the company
        can see the code, its traders must place their <b>full faith in the operator</b> — you cannot
        verify the matching rules, the fees, or whether the house quietly advantages itself. MULTI/DEX
        runs on a real, general-purpose public network (the Internet Computer) and is
        <b>open source</b>: anyone can read it, verify it, fork it, or propose changes to it.</li>
        <li><b>vs. dYdX.</b> Its order matching happens <b>off-chain</b>, in an engine the operator
        runs — only settlement touches the chain. So the rules that decide whose order fills first,
        and in what order, are not public, and there is <b>no way to know</b> whether the operator or
        privileged partners receive preferential treatment or the opportunity to <b>front-run</b>
        everyone else. MULTI/DEX matches <i>entirely on-chain</i>, in using rules that are public
        code: orders are staged so there is no queue to jump, release priority is earned and visible,
        and no operator or partner can be handed a private edge — because there is no operator.</li>
      </ul>

      <h2 id="docs-sec-burn">Gains that burn ICP</h2>
      <p>The exchange collects fees into a <a href="#docs/fees">treasury</a> that first pays for its
      own compute — it fuels itself, with no operator to subsidise it. Beyond that, the design intent
      is public-good: once the treasury exceeds a set threshold, <b>further gains are used to burn the
      ICP token</b>, reducing supply and benefiting every ICP holder. The exchange doesn't enrich an
      owner — because it doesn't have one; surplus flows back to the network that runs it.</p>

      <h2 id="docs-sec-road">The road to production</h2>
      <p>The plan is simple and public:</p>
      <ol>
        <li><b>Now → a few weeks:</b> MULTI/DEX runs in play mode. The community trades, competes,
        reads the code, and finds what needs fixing.</li>
        <li><b>When the community is satisfied it's ready,</b> anyone can <b>propose its wasm to the
        NNS</b> — submitting the exact code to be adopted, for the network to vote on.</li>
        <li><b>If the NNS accepts it,</b> the exchange becomes a permanent, ownerless public utility,
        upgraded only ever by the same open governance.</li>
      </ol>
      <p class="docs-dim">No token sale, no insider allocation, no "team wallet." The path from
      experiment to production is a public vote on open code — and until then, it's a game you're
      welcome to play.</p>

      <h2 id="docs-sec-start">Ready?</h2>
      <p><a href="#account/deposit">Collect your free dummy crypto</a> and start trading — or read
      <a href="#docs/welcome">What is MULTI/DEX?</a> first for the exchange itself. Everything you
      do is written to a <a href="#docs/ledger">public, verifiable ledger</a> you can check
      yourself.</p>
    `,
  },

  {
    slug: "welcome",
    nav: "What is MULTI/DEX?",
    title: "What is MULTI/DEX?",
    part: 0,
    blurb: "The exchange, its ethos, and why there is no one to trust.",
    html: `
      <div class="docs-aurora" aria-hidden="true"><i></i><i></i></div>
      <div class="docs-crumb">Part I · Foundations</div>
      <h1>What is MULTI/DEX?</h1>
      <p class="docs-lead">A complete crypto exchange — order book, AMM, margin, yield, custody,
      analytics and even its AI — running as a single autonomous service on the Internet Computer.</p>

      <div class="docs-start">
        <div class="docs-start-head">Open source</div>
        <p>MULTI/DEX is open source at
        <a href="https://github.com/dfinity/public-multidex" target="_blank" rel="noopener">github.com/dfinity/public-multidex</a>.
        Send issues, and links to pull requests on forks, to
        <a href="mailto:multidex@dfinity.org">multidex@dfinity.org</a> — and sometimes win bounties.</p>
      </div>

      <p>MULTI/DEX is the most advanced DeFi application ever created. Moreover, every component
      — the sealed matching engine, the order books, the
      market-making AMM, leveraged trading, the price oracle, the yield vaults, deposit custody, your
      permanent trade history, the analytics surface, and the very page you are reading — runs
      <b>entirely from the network</b>, as tamperproof code and data on the
      <a href="#docs/platform">Internet Computer</a>. There are no company servers behind it, no
      off-chain matching engine, no operations team with a database console. You are interacting
      directly with autonomous onchain code that has served this user experience into your browser.</p>

      <h2 id="docs-sec-trustless">Trustless, in the strict sense</h2>
      <p>Most venues ask for trust somewhere: a custodian holding keys, an operator running servers,
      an admin able to upgrade contracts from a laptop. MULTI/DEX is built so there is
      <b>no one to trust</b>:</p>
      <ul>
        <li><b>No operator.</b> The exchange is fully algorithmic. Nobody enrolls market makers,
        negotiates fee deals, pauses withdrawals, or edits balances. Every privilege is
        <a href="#docs/levels">earned by measurable contribution</a>, computed on-chain.</li>
        <li><b>No hidden infrastructure.</b> Matching, custody, prices, history, the UI — all of it is
        canister code whose behaviour anyone can verify against the network.</li>
        <li><b>No secret admin keys.</b> In production the exchange is controlled by the
        <b>Network Nervous System (NNS)</b> — the Internet Computer's on-chain DAO. Code updates ship
        only by public NNS proposal and vote. There is no backdoor key holder who could upgrade,
        freeze, or drain it quietly. The upgrade path itself is governance, in the open.</li>
      </ul>

      <h2 id="docs-sec-ethos">The ethos: everything is earned</h2>
      <p>Because there is no operator, there is nothing to hand out. Fee discounts, execution
      priority under load, the market-maker shield, badges — every one of them is derived from what
      your principal actually does on the venue, over a public, auditable schedule. The exchange
      rewards the behaviour that makes it useful: resting liquidity, consistent quoting, real
      volume. It is a meritocracy enforced by code, described in
      <a href="#docs/levels">Fee levels &amp; access</a> and <a href="#docs/badges">Badges</a>.</p>

      <h2 id="docs-sec-how">How to read these docs</h2>
      <p>The pages are ordered as a story. Read them in sequence with the
      <b>Next</b> link at the bottom of each page and you will go from first principles to a complete
      working model of the exchange: the platform it runs on, how orders match, where prices and
      liquidity come from, what trading costs, how margin and yield work, how money moves in and
      out, and what happens to your data. In a sitting, you can understand the whole venue you are
      about to trade on. In a hurry? Jump straight to any page from the sidebar, or filter it by
      keyword.</p>
      <div id="docs-map" class="docs-map"><!-- reading-map cards injected by docsRoute() --></div>
    `,
  },

  {
    slug: "platform",
    nav: "The platform",
    title: "Trustless by construction",
    part: 0,
    blurb: "The Internet Computer, reverse gas, NNS custody, and why the whole stack is on-chain.",
    html: `
      <div class="docs-crumb">Part I · Foundations</div>
      <h1>Trustless by construction</h1>
      <p class="docs-lead">What "runs entirely from the network" actually means — and how to verify it.</p>

      <h2 id="docs-sec-ic">A web-speed blockchain that serves the app itself</h2>
      <p>MULTI/DEX runs on the <b>Internet Computer</b>, a blockchain whose smart contracts
      (<i>canisters</i>) run at web speed, hold gigabytes of state, serve HTTP directly, and call
      external web APIs under consensus. That is what makes a fully on-chain exchange possible:</p>
      <ul>
        <li><b>The engine is a canister.</b> Order books, balances, the AMM, margin accounting, the
        event log — all state and logic live in replicated smart-contract memory.</li>
        <li><b>The UI is served from chain.</b> This frontend ships from an asset canister with
        certified responses — the page you load is cryptographically the page governance deployed.
        There is no web server to hack and no DNS-level bait-and-switch on the app logic.</li>
        <li><b>Even the oracle is on-chain.</b> Prices come from the canister itself making
        consensus-validated HTTPS calls to public exchanges — no off-chain price bot
        (<a href="#docs/oracle">Prices &amp; the oracle</a>).</li>
      </ul>

      <h2 id="docs-sec-gas">Reverse gas: the exchange pays for itself</h2>
      <p>You never buy gas to use MULTI/DEX. On the Internet Computer the <i>canister</i> pays for
      its own compute and storage in <b>cycles</b> ("fuel"). The exchange funds this from its own
      <a href="#docs/fees">fee treasury</a> — trading fees convert into the fuel that keeps the venue
      running. A self-sustaining loop: usage pays for operation, with no gas friction on you and no
      donor to depend on.</p>

      <h2 id="docs-sec-nns">Production custody: the NNS, not admins</h2>
      <p>Every canister has a <i>controller</i> — the identity allowed to upgrade it. For MULTI/DEX
      in production that controller is the <b>Network Nervous System</b>, the Internet Computer's
      protocol-level DAO. The consequences are worth spelling out:</p>
      <ul>
        <li>Code changes reach production only through a <b>public NNS proposal</b>, adopted by open
        voting. The proposal carries the exact module hash that will run.</li>
        <li><b>No developer retains an upgrade key.</b> There is no "emergency admin", no pause
        switch held by a person, no secret multisig. The team that wrote the code cannot quietly
        change it — and neither can anyone else.</li>
        <li><b>You can check.</b> Canister controllers and module hashes are public on-chain facts;
        anyone can confirm that the running code is the code governance approved.</li>
      </ul>
      <p class="docs-dim">Dev and demo deployments (like a local replica) are, of course, controlled
      by whoever runs them — the NNS posture applies to the production mainnet service.</p>

      <h2 id="docs-sec-transparent">Radical transparency</h2>
      <p>Every consequential engine action — fills, level changes, oracle updates, liquidations,
      order kills and clamps — is written to a <b>public event log</b>, and the exchange exposes a
      live query surface over its own state (<a href="#docs/data">Intelligence</a>). The rules are
      documented here; the data proving the rules are followed is one query away. Trustless lets you
      trust in the ultimate way, because it means you don't have to trust a technical admin. Only
      the NNS can transparently update code through public vote. The exchange writes everything to
      an on-chain ledger so you can verify its state, and on-chain code is tamperproof, making it
      immune to infrastructure hacks.</p>
    `,
  },

  // ════════════════════════════════ Part II — Trading ══════════════
  {
    slug: "swap",
    nav: "Swap",
    title: "Swap — trading made simple",
    part: 1,
    blurb: "How to use the Swap box, from zero: pick, preview, swap — and what the slippage setting protects you from.",
    html: `
      <div class="docs-crumb">Part II · Trading</div>
      <h1>Swap — trading made simple</h1>
      <p class="docs-lead">Give one token, get another. The Swap page is the whole exchange behind
      one box — this page shows you how to use it, and the one setting worth understanding.</p>

      <nav class="docs-toc">
        <a data-docs-goto="what">What a swap is</a>
        <a data-docs-goto="how">Making a swap</a>
        <a data-docs-goto="slippage">Slippage</a>
        <a data-docs-goto="mins">Balances &amp; minimums</a>
        <a data-docs-goto="hood">Under the hood</a>
      </nav>

      <h2 id="docs-sec-what"><span class="docs-num">1</span>What a swap is</h2>
      <p>A swap exchanges one token you hold for another, at the going rate — like a currency desk
      at the airport, except the rate comes from a live market rather than a chalkboard, and there
      is no teller taking a cut in the middle. You choose what to <b>Sell</b> and what to
      <b>Buy</b>; the box quotes what you'll get; you confirm. That's the entire job.</p>
      <p class="docs-dim">One honest caveat the airport desk shares: the bigger your swap, the less
      favourable the average rate — big orders eat deeper into the market. That effect (and the
      knob that bounds it) is <a data-docs-goto="slippage">slippage</a>, covered below.</p>

      <h2 id="docs-sec-how"><span class="docs-num">2</span>Making a swap</h2>
      <ol>
        <li><b>Sign in</b> and open <b>Swap</b>. Your balances show under each field.</li>
        <li><b>Pick the Sell token and amount.</b> Type an amount or press <b>Max</b>. The arrow
        button between the panels flips the direction.</li>
        <li><b>Read the Buy panel.</b> It fills in by itself with a live estimate: how much you'll
        receive, the average price, and the price impact of your size. If the estimate says
        "incl. AMM depth", part of your size is priced against the protocol's own standing
        liquidity beyond the visible orders.</li>
        <li><b>Press Swap.</b> The trade executes through the exchange's
        <a href="#docs/matching">sealed engine</a> within about a second.</li>
        <li><b>Done.</b> The tokens land in your <a href="#docs/custody">wallet</a>; the fill
        appears in <b>Account → Spot</b>, and in your <a href="#docs/data">permanent history</a>.</li>
      </ol>

      <h2 id="docs-sec-slippage"><span class="docs-num">3</span>Slippage — the one setting that matters</h2>
      <p>Picture buying every apple at a street market. The first stall sells cheap, the next
      charges a little more, the last one knows you're desperate. Your <i>average</i> price ends up
      worse than the first stall's sign. Markets work the same way: a big enough order moves the
      price as it fills.</p>
      <p><b>Max Slippage</b> is your protection: the worst average rate you're willing to accept,
      relative to the going price. The exchange fills as much of your swap as it can within that
      bound and <b>returns the rest unfilled</b> — it will never quietly fill you at a worse rate
      than you allowed. Small swaps rarely touch the bound; for large ones, the estimate's
      <i>price impact</i> figure tells you before you commit.</p>

      <h2 id="docs-sec-mins"><span class="docs-num">4</span>Balances &amp; minimums</h2>
      <ul>
        <li><b>Balance lines</b> under each field show what you hold; <b>Max</b> commits it all.</li>
        <li><b>Minimum order: 10 ICPUSD</b> of value — with one exception: an order spending your
        entire remaining balance is always allowed, so you can always fully exit.</li>
        <li><b>Fees</b> are charged on the trade like any other (a few hundredths of a percent,
        falling with your <a href="#docs/levels">earned level</a> — the estimate reflects the
        market, and fees settle on the ICPUSD leg: <a href="#docs/fees">how fees work</a>).</li>
      </ul>

      <h2 id="docs-sec-hood"><span class="docs-num">5</span>Under the hood: real order books</h2>
      <p>Here is what the simple box actually does. Every swap is routed across the exchange's
      underlying <a href="#docs/markets">order-book markets</a> — public lists of <b>bid</b> and
      <b>ask</b> orders placed by individual traders (and by the protocol's own
      <a href="#docs/liquidity">AMM</a>), each saying "I'll buy this much at this price" or "I'll
      sell this much at that price". Your swap consumes the best-priced of those offers, walking
      down the list as far as your size requires — that walk is exactly where price impact comes
      from. Swaps between two non-dollar tokens route through the ICPUSD books in two legs.</p>
      <p>The two panels beside the box show this machinery live. The <b>middle panel</b> charts
      the going rate between the two tokens you've picked — "1 BTC = so many ICP", through time.
      For a pair involving ICPUSD that is simply the market's price history; between two
      non-dollar tokens it is the two legs' prices divided, moment by moment — an indicative
      rate, before fees. The <b>right panel</b> shows the order book and trade tape for the
      markets your swap routes through. Experienced traders read them to judge depth before
      sizing a trade. You don't have to: the slippage bound reads the book for you.</p>
      <p>Swaps always trade <b>now</b>, at the best rate the books offer. When you'd rather name
      a price and wait for the market to come to you, that lives on the
      <a href="#docs/markets">Markets page</a> — the full trading floor: same markets, every
      control exposed, including <b>limit orders</b> that rest until your price is reached.</p>
    `,
  },

  {
    slug: "markets",
    nav: "Markets",
    title: "Markets & order books",
    part: 1,
    blurb: "Order-book trading from first principles, plus a tour of every control on the Markets page.",
    html: `
      <div class="docs-crumb">Part II · Trading</div>
      <h1>Markets &amp; order books</h1>
      <p class="docs-lead">How an order-book exchange works, explained from zero — then a tour of
      the Markets page, control by control.</p>

      <nav class="docs-toc">
        <a data-docs-goto="book">What an order book is</a>
        <a data-docs-goto="price">Where the price comes from</a>
        <a data-docs-goto="tour">A tour of the page</a>
        <a data-docs-goto="placing">Placing an order</a>
        <a data-docs-goto="tracking">Tracking your trading</a>
        <a data-docs-goto="rules">Ground rules</a>
        <a data-docs-goto="lifecycle">The life of an order</a>
      </nav>

      <h2 id="docs-sec-book"><span class="docs-num">1</span>What an order book is</h2>
      <p>Imagine a market square with one big public noticeboard. Buyers pin up notes saying
      "I'll pay $63,200 for 0.5 BTC"; sellers pin up "I'll sell 0.3 BTC at $63,400". The
      <b>order book</b> is that noticeboard, kept sorted: all the buy offers (<b>bids</b>) from
      highest price down, all the sell offers (<b>asks</b>) from lowest price up. The gap between
      the best bid and the best ask is the <b>spread</b>.</p>
      <p>A trade happens when someone stops pinning notes and simply accepts the best one on the
      other side. The two roles have names that matter here:</p>
      <ul>
        <li><b>Maker</b> — you posted a note and waited. You <i>made</i> liquidity.</li>
        <li><b>Taker</b> — you accepted an existing note. You <i>took</i> liquidity.</li>
      </ul>
      <p class="docs-dim">Makers are what keep a venue usable, so maker fills pay lower
      <a href="#docs/fees">fees</a> and earn double <a href="#docs/levels">scorecard weight</a>.</p>

      <h2 id="docs-sec-price"><span class="docs-num">2</span>Where the price comes from</h2>
      <p>"The price" of an asset is nothing more than <b>the last trade that actually happened</b>,
      bracketed by the current best bid and ask. Nobody sets it; it emerges from the notes on the
      board. Three background facts keep it honest:</p>
      <ul>
        <li>Every market quotes against <b>ICPUSD</b>, the exchange's dollar-denominated quote asset
        (<code>BTC-ICPUSD</code>, <code>ETH-ICPUSD</code>, …) — prices read like dollar prices, and
        one quote asset keeps liquidity concentrated instead of fragmented across pairs.</li>
        <li>The protocol's own <a href="#docs/liquidity">AMM</a> rests quotes in every book, so
        there is always someone to trade with, even in a quiet hour.</li>
        <li>An <a href="#docs/oracle">oracle reference price</a> anchors the engine's sanity checks,
        so a thin book can't be pushed to absurd prices for free.</li>
      </ul>

      <h2 id="docs-sec-tour"><span class="docs-num">3</span>A tour of the page</h2>
      <ul>
        <li><b>Market selector</b> (top left) — pick which book you're looking at; each row shows
        the pair and its live price.</li>
        <li><b>Stat strip</b> — last price, 24h change and 24h volume for the selected market.</li>
        <li><b>The chart</b> — price history as candles. The buttons pick the time each candle
        covers (1m … 1W); the ⤢ button at the right of its bar opens the chart full-screen
        (drag left for older history; <i>Esc</i> or × closes it); <i>Hide</i> collapses the
        chart if you'd rather have the room.</li>
        <li><b>Order Book box</b> — the noticeboard itself: asks stacked in red above, bids in green
        below, the spread row between them. Each row is a price with the <i>Quantity</i> waiting at
        it and its <i>Value</i>; the coloured bars make size readable at a glance. The interval menu
        (bottom left) bundles nearby prices into coarser rows so you can see further from the mid —
        <i>Exact</i> shows every price level as-is. The <b>Σ</b> button switches the rows to running
        totals ("how much would I move buying down to here?").</li>
        <li><b>Trades tab</b> — the tape: every fill in this market as it happens, newest first.</li>
        <li><b>The ◄ ► handle</b> between chart and book — drag it to trade chart space for book
        space; your split is remembered.</li>
      </ul>

      <h2 id="docs-sec-placing"><span class="docs-num">4</span>Placing an order</h2>
      <p>The Place Order box, top to bottom:</p>
      <ul>
        <li><b>Spot / Margin</b> — spot trades what you hold; Margin opens leveraged positions
        backed by a pool (<a href="#docs/margin">its own page</a>).</li>
        <li><b>Limit</b> — "this price or better." Set a price and quantity; if it crosses the book
        it fills immediately, and any remainder rests on the book as a maker order until filled,
        cancelled, or expired (the Expiry menu, up to good-'til-cancelled).</li>
        <li><b>Market</b> — "fill me now." It sweeps the best resting orders and, if your size needs
        more, walks the <a href="#docs/liquidity">AMM curve</a> — bounded by the <b>Max Slippage</b>
        setting, exactly as on the <a href="#docs/swap">Swap page</a>. Market orders never rest:
        anything unfillable within your bound is returned, not parked as a stale quote.</li>
        <li><b>The % buttons</b> size the order from your available balance; the total line under
        them shows the worst-case commitment before you press the button.</li>
      </ul>

      <h2 id="docs-sec-tracking"><span class="docs-num">5</span>Tracking your trading</h2>
      <p>The box beneath the chart follows your activity: <b>Open Orders</b> (cancel from here;
      margin-pool orders are tagged <b>MGN</b>), <b>Spot History</b> (recent closes and fills),
      <b>Positions</b> and <b>Positions History</b> for margin. "This market only" narrows any tab
      to the selected market. The same records — and much deeper history — live in
      <b>Account → Spot</b> and the <a href="#docs/data">permanent archive</a>.</p>

      <h2 id="docs-sec-rules"><span class="docs-num">6</span>Ground rules</h2>
      <ul>
        <li><b>Minimum order: 10 ICPUSD notional.</b> Dust orders cost the venue more than they add.
        One exception — an order committing your <i>entire remaining balance</i> is always allowed,
        so you can always fully exit (the dust-out exemption).</li>
        <li><b>You cannot trade with yourself.</b> If your incoming order would cross your own
        resting one, the resting order is cancelled instead of filled — wash-trading your own book
        is structurally impossible.</li>
        <li><b>Funds are reserved up front.</b> Placing an order escrows what a worst-case fill
        could need (fees reserved at the base rate; you settle at your earned rate — the discount is
        simply never debited). No phantom orders, no failed settlements.</li>
        <li><b>Access is deposit-gated.</b> Only principals that have deposited can send trading
        calls at all — the venue's outermost anti-spam wall
        (<a href="#docs/custody">Deposits &amp; withdrawals</a>).</li>
      </ul>

      <h2 id="docs-sec-lifecycle"><span class="docs-num">7</span>The life of an order</h2>
      <p>Orders are not executed the instant they arrive — they are <b>staged</b>, then
      <b>released</b> into a sealed matching pass moments later. This is the exchange's core defence
      against front-running, and it deserves its own page:
      <a href="#docs/matching">GEPTOR, the sealed matching engine</a>. From your side it is simple:
      place → (about a second) → filled, resting, or released back. Open orders and recent closes
      live in <b>Account → Spot</b>, and every fill is written to your
      <a href="#docs/data">permanent history</a>.</p>
    `,
  },

  {
    slug: "matching",
    nav: "Matching engine",
    title: "GEPTOR — sealed matching",
    part: 1,
    blurb: "Why orders are staged and released, and how front-running is engineered away.",
    html: `
      <div class="docs-crumb">Part II · Trading</div>
      <h1>GEPTOR — the sealed matching engine</h1>
      <p class="docs-lead">On a transparent chain, a visible pending order is an invitation to jump the
      queue. MULTI/DEX's answer is to make the queue sealed.</p>

      <h2 id="docs-sec-problem">The problem: everyone can see your order coming</h2>
      <p>On most on-chain venues, orders sit in a public mempool before execution. Bots read them and
      trade first — front-running, sandwiching, quote-sniping. The usual "fixes" (trusted relayers,
      private mempools) reintroduce exactly the middlemen DeFi was meant to remove.</p>

      <h2 id="docs-sec-sealed">The GEPTOR pass</h2>
      <p>The engine's heartbeat is the <b>GEPTOR</b> pass — <b>G</b>et <b>E</b>xternal <b>P</b>rice
      <b>T</b>hrough <b>O</b>racle and <b>R</b>equote. Roughly every second the engine takes a fresh
      <a href="#docs/oracle">oracle reference price</a>, requotes the protocol's
      <a href="#docs/liquidity">AMM</a> around it, and runs a sealed matching pass. Incoming orders
      are <b>staged</b> — accepted, funds reserved, but not yet executable and not yet a visible
      quote — and each pass releases staged orders into the book and matches them:</p>
      <ul>
        <li><b>Release order is earned, not bought.</b> Staged orders release by
        <a href="#docs/levels">access rank</a> first (higher earned rank first), then by arrival
        time within a rank. Under calm conditions this is effectively time-priority; under load,
        contributors go first.</li>
        <li><b>There is nothing to front-run.</b> Between staging and release your order is invisible
        to other traders, and no external actor can insert itself into the pass. The pass itself is
        deterministic canister code.</li>
        <li><b>The AMM yields to users.</b> The protocol's own <a href="#docs/liquidity">AMM</a>
        participates in matching, but on an order's immediate release pass it is <i>non-takeable</i>
        — resting user orders get first claim on flow; the house never snipes its own customers.</li>
      </ul>

      <h2 id="docs-sec-stall">When the oracle stalls</h2>
      <p>Matching normally happens around a fresh <a href="#docs/oracle">reference price</a>. If the
      oracle goes stale, the engine drops to a <b>users-only</b> mode: the AMM sits out, and fills
      are clamped to <b>±2%</b> of the last known mid. Trading continues, but nobody can print a
      wild wick against a blind book. (Historical chart wicks trace back to exactly these episodes —
      the clamp is why they are small.)</p>

      <h2 id="docs-sec-commit">Staged means committed</h2>
      <p>A staged taker order is <b>committed for its first 3 seconds</b> — you cannot cancel it
      before its release pass. This closes the "free look": without it, anyone could stage an
      order, watch a faster off-chain feed for a second, and cancel whenever the move went against
      them — a free option written by whoever would have filled it. Post-only orders are exempt
      (they never take), so quoting bots keep instant cancel-and-replace.</p>

      <h2 id="docs-sec-shield">The market-maker shield</h2>
      <p>A quoter repricing into fresh information is briefly exposed: the old quote is still resting
      while the new one is staged. Earned <b>L4</b> quoters get the <b>quote-freshness shield</b>:
      while their repricing order is staged, their resting quotes on that market cannot be picked
      off. Sharper quotes for everyone, because quoting tight is survivable
      (<a href="#docs/levels">how L4 is earned</a>).</p>

      <h2 id="docs-sec-load">Backpressure, not blackouts</h2>
      <p>Each principal may hold at most <b>32 staged orders</b>; when the global staged queue grows
      past <b>2,000</b> and then <b>5,000</b> entries, the exchange raises its shed floor and turns
      away the lowest access ranks at the gate first. The venue degrades in an orderly, published
      way — never a silent stall. Your current standing is always visible in
      <b>Account → Fee Level</b>.</p>
    `,
  },

  {
    slug: "liquidity",
    nav: "AMM & liquidity",
    title: "The AMM & its vault",
    part: 1,
    blurb: "The protocol market maker: never crosses the mark, prices scarcity like a curve, and gets paid for the risk it carries.",
    html: `
      <div class="docs-crumb">Part II · Trading</div>
      <h1>The AMM &amp; its vault</h1>
      <p class="docs-lead">Every market has a built-in market maker, so there is always a two-sided
      price — and it is built so that no pattern of trading can drain it.</p>

      <h2 id="docs-sec-role">What the AMM is for</h2>
      <p>An order book with no orders is a dead venue. Each MULTI/DEX market carries a protocol
      <b>AMM</b> that continuously quotes both sides around the live
      <a href="#docs/oracle">oracle reference price</a> (the <b>mark</b>), with depth drawn from a
      shared inventory vault funded by <a href="#docs/earn">Earn depositors</a>. Its quotes appear
      in the book like anyone else's — but it plays by stricter rules than a human market maker:</p>
      <ul>
        <li><b>It never quotes across the mark.</b> Every AMM bid sits below the mark and every AMM
        ask above it, whatever its inventory looks like — enforced as a hard invariant in the quote
        engine. A round trip through the AMM always pays the vault the spread; there is no sequence
        of trades that turns it into a money pump.</li>
        <li><b>Scarcity is priced like a curve.</b> The more one-sided flow depletes a reserve, the
        further that side's quotes move away (asks carry a growing premium when inventory runs
        short; bids back away when it runs long), rising steeply near a hard <b>reserve floor</b> —
        the last 15% is simply not for sale. Think Uniswap's curve, expressed as a ladder around
        the mark.</li>
        <li><b>Slippage is band-capped.</b> A single fill cannot walk the book into fantasy prices;
        oversized remainders release back to you instead.</li>
        <li><b>It yields to users.</b> On an order's immediate release pass the AMM is non-takeable
        (<a href="#docs/matching">see GEPTOR</a>); resting user quotes always have first claim.</li>
        <li><b>It never chases.</b> The AMM does not market-buy to fix its inventory — that habit is
        exploitable, so it doesn't have it. Recovery is passive: the depleted side quotes the most
        competitive price the never-cross rule allows and lets flow come to it, while the
        <a href="#docs/arbitrage">arbitrageur</a> keeps the venue price pinned near the mark so that
        flow actually arrives.</li>
      </ul>

      <h2 id="docs-sec-paid">Paid for the risk it carries</h2>
      <p>The vault is the venue's always-on maker, the margin system's lender, and the senior
      absorber of bad debt. It is compensated accordingly: it earns the <b>bid/ask spread</b> on
      every fill, plus <b>half of every trading fee</b> the venue collects
      (<a href="#docs/fees">Fees &amp; treasury</a>). Both accrue directly to the vault that
      <a href="#docs/earn">Earn depositors</a> own.</p>

      <h2 id="docs-sec-vault">Where the depth comes from</h2>
      <p>The AMM trades out of a vault that anyone can join: deposit inventory and you own a slice
      of the venue's market maker. The economics — cost-basis P&amp;L, the exit fee that keeps
      round-trips honest, and the deposit gates that protect existing LPs — are covered in
      <a href="#docs/earn">Earn</a>.</p>
    `,
  },

  {
    slug: "oracle",
    nav: "Prices & the oracle",
    title: "Prices & the oracle",
    part: 1,
    blurb: "Six public sources, robust-median aggregation, on-chain fetching, and stall behaviour.",
    html: `
      <div class="docs-crumb">Part II · Trading</div>
      <h1>Prices &amp; the oracle</h1>
      <p class="docs-lead">The reference price steers the AMM, marks margin collateral, and triggers
      liquidations — so it is engineered like it matters.</p>

      <h2 id="docs-sec-sources">Consensus prices, fetched by the chain itself</h2>
      <p>The exchange's canister fetches spot prices directly — via the Internet Computer's
      consensus-validated <b>HTTPS outcalls</b> — from six independent public sources:
      Coinbase, Kraken, OKX, KuCoin, CryptoCompare and CoinGecko. There is no off-chain price
      daemon, no privileged "oracle updater" account, no single API whose failure or capture moves
      the venue.</p>

      <h2 id="docs-sec-aggregate">Robust aggregation</h2>
      <p>Samples are combined with a <b>robust median</b>: take the median, discard outliers more
      than 2σ from it, and take the median of the remainder. One venue printing a bad tick — or
      lying outright — is simply trimmed away. The result becomes the market's
      <b>reference price</b>, refreshed continuously and considered stale after <b>45 seconds</b>
      without an update.</p>

      <h2 id="docs-sec-uses">What the reference price drives</h2>
      <ul>
        <li><b>AMM centring</b> — protocol quotes track it (<a href="#docs/liquidity">the AMM</a>).</li>
        <li><b>Matching bands</b> — fill-price sanity clamps are measured from it
        (<a href="#docs/matching">GEPTOR</a>).</li>
        <li><b>Margin marks</b> — collateral values, health ratios and liquidation triggers use it
        (<a href="#docs/margin">Margin trading</a>).</li>
        <li><b>Your account value</b> — the marked-to-market figure on the Account page.</li>
      </ul>

      <h2 id="docs-sec-stale">Failure is a designed state</h2>
      <p>If every source is unreachable — an outage, not an edge case, on a network that fetches
      under consensus — the exchange does not guess. The AMM stands down and matching continues in
      <b>users-only</b> mode with fills clamped to ±2% of the last mid, until fresh prices return.
      Degraded, bounded, and honest: the one thing the venue will not do is trade confidently on a
      price it does not have. Every oracle update and stall episode is written to the public event
      log.</p>
    `,
  },

  {
    slug: "arbitrage",
    nav: "The arbitrageur",
    title: "The arbitrageur",
    part: 1,
    blurb: "Synthetic assets have no external market — so the venue runs its own arbitrageur to keep prices honest.",
    html: `
      <div class="docs-crumb">Part II · Trading</div>
      <h1>The arbitrageur</h1>
      <p class="docs-lead">On a normal exchange, arbitrageurs keep prices honest. MULTI/DEX trades
      synthetic assets — so the venue runs its own, in the open, with rules.</p>

      <h2 id="docs-sec-why">The problem it solves</h2>
      <p>When Uniswap's pool price drifts from the wider market, arbitrageurs buy where it's cheap
      and sell where it's rich, moving assets between venues until prices agree. That external
      force is what lets a passive market maker hold fair quotes and wait. MULTI/DEX's assets are
      synthetic — there is no "other venue" — so without help, determined flow could hold the venue
      price away from the <a href="#docs/oracle">oracle mark</a> indefinitely. The
      <a href="#docs/liquidity">AMM</a> refuses to chase (that refusal is what makes it
      un-drainable), so something else must do the converging.</p>

      <h2 id="docs-sec-how">How it works</h2>
      <p>A dedicated <b>Arbitrage canister</b> simulates moving assets in and out of the venue. It
      may exchange assets with the "external world" at the oracle mark (paying a small haircut,
      like any real cross-venue trader), and it trades the venue side through the exact same
      staged, fee-paying order path as everyone else — no matching privileges, no fee exemption:</p>
      <ul>
        <li><b>Venue rich</b> (bids well above the mark): it imports supply at the mark and sells
        into those bids.</li>
        <li><b>Venue cheap</b> (asks well below the mark): it buys them and exports at the mark.</li>
      </ul>
      <p>Its orders are pinned just beyond the mark, so it can never trade with the AMM (whose
      quotes never cross the mark) and never worsens a fair price. It acts only outside a
      <b>±0.5% band</b>, in bounded sizes, under per-call and hourly caps, and it stands down
      whenever the oracle is stale or a circuit-breaker jump is pending — the same trust bar the
      AMM applies to itself.</p>

      <h2 id="docs-sec-who-pays">Who pays for it? Whoever pushes prices around</h2>
      <p>The arbitrageur's profit comes exclusively from orders priced away from the mark — that
      is, from whoever moved the price there. Pushing the venue off its reference price used to be
      free; now it is a <b>taxed activity</b>, and the tax funds the venue. Every import and export
      is written to the public <b>event log</b>; its live balances, lifetime flows and caps sit on
      the <b>Status → AMM</b> pane (and are queryable by anyone via
      <span class="docs-mono">getArbStats</span>); and its rows in the Data Explorer are labeled
      <i>Arbitrageur</i> — an arbitrageur with an audit trail.</p>
    `,
  },

  // ════════════════════════════ Part III — Costs & rewards ═════════
  {
    slug: "fees",
    nav: "Fees & treasury",
    title: "Fees & the treasury",
    part: 2,
    blurb: "What trading costs, why fees exist at all, and where every basis point goes.",
    html: `
      <div class="docs-crumb">Part III · Costs &amp; rewards</div>
      <h1>Fees &amp; the treasury</h1>
      <p class="docs-lead">Fees on MULTI/DEX are not revenue extraction — they are the venue's spam
      defence and its fuel supply, at rates you can trade down to zero.</p>

      <h2 id="docs-sec-schedule">The schedule</h2>
      <p>Every fill charges a fee on its <b>quote (ICPUSD) leg</b>, on both sides of the trade:</p>
      <div class="docs-tablebox">
      <table>
        <tr><th></th><th class="docs-c">Maker (resting side)</th><th class="docs-c">Taker (crossing side)</th></tr>
        <tr><td>Base rate (L0)</td><td class="docs-c">5.0 bps</td><td class="docs-c">10.0 bps</td></tr>
        <tr><td>Best earned rate (L4)</td><td class="docs-c docs-good">0.0 bps</td><td class="docs-c">6.0 bps</td></tr>
      </table>
      </div>
      <p>Your rate is set by your <a href="#docs/levels">earned level</a>, evaluated at fill time.
      Amounts floor-round in the treasury's favour and the seller's credit is net of fee — the
      arithmetic never rounds in a way that could mint value. Makers are always cheaper than takers,
      and the maker rate floors at zero: it is never a rebate, because
      <a href="#docs/levels">rebates are what make wash-trading profitable</a>.</p>

      <h2 id="docs-sec-why">Why a trustless venue charges fees at all</h2>
      <p>With no gas cost to users (<a href="#docs/platform">reverse gas</a>), a free exchange would
      be a free denial-of-service target: unlimited zero-cost orders. Fees make every fill cost
      something real, which — combined with the 10 ICPUSD minimum order and deposit-gated access —
      is the venue's economic spam defence.</p>

      <h2 id="docs-sec-treasury">Where every basis point goes</h2>
      <p>Every settled fee is <b>split down the middle</b>. Half accrues to the
      <a href="#docs/earn">AMM vault</a> — the LPs whose capital makes the venue liquid and who
      backstop its margin system carry real risk, and fee income is part of their pay. The other
      half accrues to the <b>protocol treasury</b> — an on-chain balance you can watch live under
      <b>Status → Treasury</b> — whose job is to keep the exchange alive: it converts into
      <b>cycles</b>, the fuel the canister burns for compute and storage. Trading pays the people
      who carry its risks and the machine that clears it — no token emissions, no external subsidy,
      no rent extraction.</p>

      <h2 id="docs-sec-edges">Edge cases, by construction</h2>
      <ul>
        <li><b>Margin pools pay fees like anyone else</b> — leveraged opens and closes are normal
        engine trades, and they credit the pool owner's scorecard.</li>
        <li><b>Liquidations carry no trading fee</b> — they bypass the trading engine entirely; a
        forced close is not a fee event.</li>
        <li><b>Protocol liquidity is fee-exempt</b> — the AMM, insurance and treasury pay no fees to
        themselves; no circular accounting.</li>
        <li><b>Reservations use the base rate</b> — orders escrow fees at L0 and settle at your
        earned rate, so a level change mid-flight can never under-reserve.</li>
      </ul>
      <p class="docs-dim">Next: the ladder that decides your personal rate — and everything else you
      can earn.</p>
    `,
  },

  {
    slug: "levels",
    nav: "Fee levels",
    title: "Fee levels & access",
    part: 2,
    blurb: "The earned ladder: scorecard volume, dynamic thresholds, L4 uptime and access rank.",
    html: `
      <div class="docs-crumb">Part III · Costs &amp; rewards</div>
      <h1>Fee levels &amp; access</h1>
      <p class="docs-lead">How the exchange rewards contribution, with no operator in the loop —
      this page is the rulebook behind <b>Account → Fee Level</b>.</p>

      <nav class="docs-toc">
        <a data-docs-goto="idea">The idea</a>
        <a data-docs-goto="scorecard">Your scorecard</a>
        <a data-docs-goto="levels">Fee levels</a>
        <a data-docs-goto="scaling">Dynamic thresholds</a>
        <a data-docs-goto="uptime">Level 4 &amp; quote uptime</a>
        <a data-docs-goto="access">Access priority</a>
        <a data-docs-goto="gaming">Anti-gaming</a>
        <a data-docs-goto="fineprint">Fine print</a>
      </nav>

      <h2 id="docs-sec-idea"><span class="docs-num">1</span>Everything is earned</h2>
      <p>MULTI/DEX is fully algorithmic — there is no operator to enroll partners, negotiate fee deals,
      or hand out priority. Every privilege on the exchange is computed on-chain from what your
      principal actually does:</p>
      <ul>
        <li><b>Fee level (L0–L4)</b> — earned from your rolling 30-day contribution; decays if you stop trading.</li>
        <li><b>Access priority</b> — under load, higher levels keep access and release first; derived from the same level.</li>
      </ul>
      <p class="docs-dim">The exchange also mints permanent <a href="#docs/badges">badges</a> at lifetime milestones —
      but those are recognition, not economics, and gate nothing; they have their own page. Every level change is
      written to the public event log, and anyone can query the full schedule and their own scorecard
      (<code>getAccessPolicy</code>) — the progression is publicly auditable.</p>

      <h2 id="docs-sec-scorecard"><span class="docs-num">2</span>Your scorecard: weighted volume</h2>
      <p>Every settled fill credits both parties with its quote value (in ICPUSD). Which side you were on matters:</p>
      <ul>
        <li><b>Maker volume</b> — your order was <i>resting on the book</i> and someone crossed it. You provided liquidity.</li>
        <li><b>Taker volume</b> — your order crossed a resting one. You consumed liquidity.</li>
      </ul>
      <p>Your level is keyed on <b>weighted window volume</b> over a rolling ~30-day window:</p>
      <div class="docs-formula">W &nbsp;=&nbsp; <b>2 × maker volume</b> &nbsp;+&nbsp; taker volume</div>
      <p class="docs-dim">Maker fills count double — resting quotes are what make the venue usable, so they are what the
      ladder rewards most. Margin-pool activity counts toward the pool <i>owner's</i> scorecard.</p>

      <h2 id="docs-sec-levels"><span class="docs-num">3</span>Fee levels</h2>
      <p>Fees are charged on the quote leg of each fill, on both sides, and accrue to the protocol treasury.
      Your earned level picks your rate:</p>
      <div class="docs-tablebox">
      <table>
        <tr><th>Level</th><th>Weighted 30-day volume (full scale)</th><th class="docs-c">Maker fee</th><th class="docs-c">Taker fee</th><th>Access rank</th></tr>
        <tr><td class="docs-lvl">L0</td><td>join (first deposit)</td><td class="docs-c">5.0 bps</td><td class="docs-c">10.0 bps</td><td>0 — shed first under load</td></tr>
        <tr><td class="docs-lvl">L1</td><td>≥ $20k × scale</td><td class="docs-c">4.5 bps</td><td class="docs-c">9.0 bps</td><td>1</td></tr>
        <tr><td class="docs-lvl">L2</td><td>≥ $200k × scale</td><td class="docs-c">3.5 bps</td><td class="docs-c">8.0 bps</td><td>1</td></tr>
        <tr><td class="docs-lvl">L3</td><td>≥ $2M × scale</td><td class="docs-c">2.5 bps</td><td class="docs-c">7.0 bps</td><td>2</td></tr>
        <tr><td class="docs-lvl">L4</td><td>≥ $10M × scale <b>and</b> quote uptime ≥ 50%</td><td class="docs-c docs-good">0.0 bps</td><td class="docs-c">6.0 bps</td><td>2 + quote shield</td></tr>
      </table>
      </div>
      <p class="docs-dim">Levels re-evaluate continuously against the rolling window: trade more and you climb within
      about a minute of the fills settling; go quiet and the window (and your level) decays. The maker rate
      floors at zero — it is never negative (see <a class="docs-anchor" data-docs-goto="gaming"><u>anti-gaming</u></a>).</p>

      <h2 id="docs-sec-scaling"><span class="docs-num">4</span>Dynamic thresholds — early contributors reach levels sooner</h2>
      <p>The volume bars above are <b>full-scale</b> values, for a mature venue. While overall exchange volume
      is still growing, every bar shrinks proportionally:</p>
      <div class="docs-formula">scale &nbsp;=&nbsp; clamp( <b>exchange 30-day volume / $100M</b>, &nbsp;1%, &nbsp;100% )<br>
      effective bar for level i &nbsp;=&nbsp; full bar × scale</div>
      <p>Worked example: if the whole exchange traded <b>$1M</b> in the current window, the scale is 1%, so
      L1 needs just <b>$200</b> of weighted volume, L2 <b>$2,000</b>, L3 <b>$20,000</b> and L4 <b>$100,000</b>
      (plus uptime). As venue volume grows toward $100M per window, the bars grow back to full size.</p>
      <p class="docs-dim">The intent: the earliest participants — whose activity is what bootstraps the venue — can
      earn real fee discounts and priority with proportionally modest contribution. Your Fee Level tab always
      shows the <i>current effective</i> bars, never the abstract full-scale ones.</p>

      <h2 id="docs-sec-uptime"><span class="docs-num">5</span>Level 4 &amp; quote uptime</h2>
      <p>L4 is the market-maker tier. Volume alone doesn't reach it — the exchange samples your book
      roughly once a minute and checks for a <b>two-sided market</b>:</p>
      <ul>
        <li>resting bids <i>and</i> asks on the same market, each within <b>±1%</b> of the reference price,</li>
        <li>at least <b>$500</b> of quote value per side,</li>
        <li>passing at least <b>50%</b> of samples, measured over a minimum of 20 samples.</li>
      </ul>
      <p>Qualified L4 quoters also get the <b>quote freshness shield</b>: when you stage a repricing order,
      your resting quotes on that market can't be picked off before your new price lands. Uptime is a moving
      figure — stop quoting and it decays, and L4 (with its shield) lapses back to L3.</p>

      <h2 id="docs-sec-access"><span class="docs-num">6</span>Access priority under load</h2>
      <p>Deposit-gated access is the DEX's DoS defence: only principals that have deposited can send update
      calls at all. On top of that, your level derives an <b>access rank</b> (0, 1 or 2) used two ways:</p>
      <ul>
        <li><b>Admission.</b> Under heavy load the exchange raises a shed floor and refuses calls below it at
        the gate — rank 0 sheds first, rank 2 keeps access longest. The current floor is public
        and shown in your Fee Level tab.</li>
        <li><b>Release ordering.</b> Staged orders release highest-rank-first (ties by age), so contributors'
        orders land before drive-by flow when everyone is queued.</li>
      </ul>

      <h2 id="docs-sec-gaming"><span class="docs-num">7</span>Why this is hard to game</h2>
      <ul>
        <li><b>The maker rate floors at 0, never negative.</b> With a rebate, a wash pair could earn money from
        the venue. At zero, the cheapest possible self-generated volume still pays the full taker fee to the
        treasury — faking volume costs real money on every fill.</li>
        <li><b>Self-trades don't fill.</b> If your incoming order would cross your own resting order, the resting
        one is cancelled instead (self-trade prevention). You cannot be your own maker.</li>
        <li><b>You can't buy rank quickly.</b> Climbing the ladder means paying full-freight fees on the way up,
        and the window decays — a burst attacker pays L0 rates for the privilege.</li>
        <li><b>Scaling can't be pushed down.</b> Extra volume only <i>raises</i> the exchange-wide scale and with it
        everyone's bars — an attacker inflating volume makes levels harder to reach, including their own.</li>
        <li><b>Maker volume requires counterparties.</b> The double-weighted input is resting orders that other,
        independent principals chose to cross.</li>
      </ul>

      <h2 id="docs-sec-fineprint"><span class="docs-num">8</span>Fine print</h2>
      <ul class="docs-dim">
        <li>Fees are computed at <b>fill time</b> at your then-current level — two fills minutes apart can pay
        different rates if your level moved between them.</li>
        <li>Orders reserve funds at the base (L0) taker rate and settle at your earned rate, so a discount can
        never cause under-reservation; the difference simply isn't debited.</li>
        <li>Liquidations carry no trading fee by construction. The protocol's own liquidity (AMM, insurance,
        treasury) is fee-exempt; margin pools pay fees like any user and credit their owner's scorecard.</li>
        <li>Minimum order size is 10 ICPUSD notional — except an order that commits your entire remaining
        balance, which is always allowed (dust-out exemption).</li>
        <li>Level changes are event-logged; thresholds, rates and your scorecard are queryable
        by anyone via <code>getAccessPolicy</code>.</li>
      </ul>
    `,
  },

  {
    slug: "badges",
    nav: "Badges",
    title: "Badges",
    part: 2,
    blurb: "Permanent lifetime milestones — recognition, not privilege. The nine badges and how each is earned.",
    html: `
      <div class="docs-crumb">Part III · Costs &amp; rewards</div>
      <h1>Badges</h1>
      <p class="docs-lead">Permanent marks of what your principal has done on the exchange —
      shown on <b>Account → All</b>, minted by algorithm, never lost.</p>

      <nav class="docs-toc">
        <a data-docs-goto="idea">Recognition, not power</a>
        <a data-docs-goto="list">The nine badges</a>
        <a data-docs-goto="fineprint">Fine print</a>
      </nav>

      <h2 id="docs-sec-idea"><span class="docs-num">1</span>Recognition, not power</h2>
      <p>Badges record your milestones within the app, and are never lost. They are the counterpart to
      <a href="#docs/levels">fee levels</a>, with the opposite temperament:</p>
      <ul>
        <li><b>Levels are economic and decay</b> — they price your trades and gate access, and they fall
        when contribution stops.</li>
        <li><b>Badges are recognition and permanent</b> — once earned, a badge is yours even if your level
        decays to zero. Badges carry no privileges: they change no fee, no rank, no limit.</li>
      </ul>
      <p class="docs-dim">Like everything on MULTI/DEX, badges are earned by algorithm — there is no operator
      to hand one out, and none can be revoked.</p>

      <h2 id="docs-sec-list"><span class="docs-num">2</span>The nine badges</h2>
      <p>Badges key on <b>lifetime</b> totals — unlike the level scorecard's rolling window, these counters
      only ever go up, and their bars never scale down.</p>
      <div class="docs-tablebox">
      <table>
        <tr><th>#</th><th>Badge</th><th>How it's earned</th></tr>
        <tr><td class="docs-c">1</td><td class="docs-badge-name">DeFi 2.0 User</td><td>Join — your first deposit registers you on the exchange.</td></tr>
        <tr><td class="docs-c">2</td><td class="docs-badge-name">First Fill</td><td>Your first settled trade.</td></tr>
        <tr><td class="docs-c">3</td><td class="docs-badge-name">MULTI/DEX Player</td><td>$10k lifetime volume.</td></tr>
        <tr><td class="docs-c">4</td><td class="docs-badge-name">Maker Clout</td><td>$100k lifetime <b>maker</b> volume.</td></tr>
        <tr><td class="docs-c">5</td><td class="docs-badge-name">Two-Sided</td><td>First passed quote-uptime sample (a real two-sided book, once).</td></tr>
        <tr><td class="docs-c">6</td><td class="docs-badge-name">Market Mover</td><td>$500k lifetime volume.</td></tr>
        <tr><td class="docs-c">7</td><td class="docs-badge-name">Iron Quoter</td><td>Sustained ≥50% quote uptime across a full sampling window.</td></tr>
        <tr><td class="docs-c">8</td><td class="docs-badge-name">Whale</td><td>$10M lifetime volume.</td></tr>
        <tr><td class="docs-c">9</td><td class="docs-badge-name">Market Pillar</td><td>$10M lifetime <b>maker</b> volume.</td></tr>
      </table>
      </div>
      <p class="docs-dim">The badge shelf on <b>Account → All</b> shows the badges you hold; the
      <i>next badge</i> nudge beneath it names the closest unearned one and how far along you are.</p>

      <h2 id="docs-sec-fineprint"><span class="docs-num">3</span>Fine print</h2>
      <ul class="docs-dim">
        <li>Every badge award is written to the public event log at the moment it mints.</li>
        <li>Your badge set and lifetime counters are queryable by anyone via <code>getAccessPolicy</code> —
        like the rest of the exchange, the record is publicly auditable.</li>
        <li>Volume badges use the same settled-fill accounting as the level scorecard (quote value in ICPUSD;
        margin-pool activity credits the pool owner) — only the window differs: lifetime, not 30 days.</li>
        <li>Badge thresholds are fixed full-scale values — they do not shrink with the
        <a href="#docs/levels">dynamic level thresholds</a> while the venue is young.</li>
      </ul>
    `,
  },

  // ═══════════════════════════════ Part IV — Beyond spot ═══════════
  {
    slug: "margin",
    nav: "Margin trading",
    title: "Margin trading",
    part: 3,
    blurb: "From first principles: pools, positions, what each fill borrows, leverage, financing costs, health and liquidation — plus worked examples and a quick-reference table.",
    html: `
      <div class="docs-crumb">Part IV · Beyond spot</div>
      <h1>Margin trading</h1>
      <p class="docs-lead">Trading with more money than you have — explained from zero. Plain words
      first, exact numbers where they matter, and a <a data-docs-goto="reference">quick-reference
      table</a> at the end if you already know how margin works.</p>

      <nav class="docs-toc">
        <a data-docs-goto="what">What margin is</a>
        <a data-docs-goto="pools">Pools</a>
        <a data-docs-goto="positions">Positions</a>
        <a data-docs-goto="borrows">What a fill borrows</a>
        <a data-docs-goto="leverage">Leverage</a>
        <a data-docs-goto="financing">Financing costs</a>
        <a data-docs-goto="health">Health &amp; distance to liquidation</a>
        <a data-docs-goto="liq">Liquidation</a>
        <a data-docs-goto="example">A worked example</a>
        <a data-docs-goto="reference">Quick reference</a>
      </nav>

      <h2 id="docs-sec-what"><span class="docs-num">1</span>What margin is</h2>
      <p>Spot trading spends money you have: $1,000 buys $1,000 of BTC. <b>Margin trading</b> adds
      borrowed money on top, so the same $1,000 can control a $3,000 position. Your own money is the
      <b>collateral</b> — the lender's safety cushion — and the multiplier is the <b>leverage</b>
      (here, 3×).</p>
      <p>Why do it? Because your profit and loss are measured on the whole position, but belong to
      your $1,000:</p>
      <ul>
        <li>BTC rises 10% → the $3,000 position gains $300 → <b>+30%</b> on your money.</li>
        <li>BTC falls 10% → the position loses $300 → <b>−30%</b> on your money.</li>
      </ul>
      <p>That is the entire idea, and both halves of it are always true at once. Everything else on
      this page is the machinery that keeps the borrowed part safe: what you can lose is capped at
      the money you committed, and it can never spill onto anyone else.</p>

      <h2 id="docs-sec-pools"><span class="docs-num">2</span>Pools: a separate box for risk</h2>
      <p>On MULTI/DEX you never borrow against your wallet. Instead you put money into a
      <b>margin pool</b> — think of it as a separate, labelled box. The box holds your committed
      cash, any positions it backs, and any debt it owes. The rule that makes margin safe here is
      structural: <b>a pool can lose at most what's inside it</b>. Your wallet, your other pools,
      and every other trader are physically out of reach (each pool is its own on-chain principal —
      a separate account at the protocol level, not a display grouping).</p>
      <ul>
        <li><b>Funding the box.</b> Moving money in and out is an explicit transfer — <i>Fund</i> and
        <i>Withdraw</i> in the pool's footer (Account → Positions). The <b>Net funded</b> chip shows
        your lifetime deposits minus withdrawals, so equity − net funded = what the pool has made or
        lost for you, all-time.</li>
        <li><b>Cross vs isolated.</b> A <i>cross</i> pool lets several positions share one cushion of
        collateral (a winner can carry a loser). An <i>isolated</i> pool holds a single position, so
        its risk is fenced off alone. You can run several of each.</li>
        <li><b>No setup ceremony.</b> Place a Margin order on the Markets page with no pool selected
        and a default cross pool is created for you.</li>
        <li><b>First-class citizens.</b> A pool's opens and closes are ordinary engine trades — they
        pay <a href="#docs/fees">fees</a> and credit <i>your</i> <a href="#docs/levels">scorecard</a> —
        and pools, positions and episodes are queryable via <a href="#docs/data">Intelligence</a>.</li>
      </ul>

      <h2 id="docs-sec-positions"><span class="docs-num">3</span>Positions: what actually happens</h2>
      <p>A <b>position</b> is a leveraged bet held by a pool. Unlike perpetual-futures exchanges,
      nothing here is synthetic — the pool really borrows and really trades, through the same
      <a href="#docs/matching">sealed matching engine</a> as every spot order (leverage buys no
      special path to the book):</p>
      <ul>
        <li><b>Long</b> (you expect a rise): the pool borrows ICPUSD, buys the asset, and holds the
        asset itself. Close = sell the asset, repay the debt, keep the difference.</li>
        <li><b>Short</b> (you expect a fall): the pool borrows the <i>asset</i>, sells it for ICPUSD,
        and holds the cash. Close = buy the asset back (hopefully cheaper), return it, keep the
        difference.</li>
      </ul>
      <p>Open positions from <b>Markets → Place Order → Margin</b>, as market or limit orders with a
      max-slippage bound. A resting margin limit order appears in Open Orders tagged <b>MGN</b>. If a
      fill would land the pool below its required opening health, the engine <b>clamps the size</b>
      to what the collateral supports (you'll see a "size reduced" notice) rather than rejecting
      outright. Manage everything from <b>Account → Positions</b>: each pool block shows equity, net
      funded, exposure, leverage, unrealized P&amp;L and distance to liquidation, with its positions
      nested beneath.</p>
      <p><b>The borrow happens at the fill, not when you place the order.</b> Placing a Margin
      order only <i>checks</i> that the vault could lend the shortfall at today's prices (it refuses
      up front if not) and stages the whole size. While the order is staged or resting on the book
      it holds <b>no debt</b> and accrues <b>no interest</b>; each fill borrows exactly its own
      shortfall from the vault at that instant, and interest runs from then. Cancelling an unfilled
      entry therefore repays nothing — there is nothing to repay. What exactly each fill borrows — and
      the three things that can stop one — is the <a data-docs-goto="borrows">next section</a>.</p>

      <h2 id="docs-sec-borrows"><span class="docs-num">4</span>What a fill borrows</h2>
      <p>Every fill of a Margin entry is settled on its own, and each one asks the same question:
      does the pool hold enough of the token this fill <i>pays with</i>? Whatever it lacks, the vault
      lends — exactly that amount, right there inside the fill, before the trade settles. Which token
      that is depends on the direction:</p>
      <ul>
        <li><b>A long borrows cash.</b> A buy pays in ICPUSD, so the fill needs its cost plus the
        pool's trading fee. The pool's free ICPUSD goes first and the rest is borrowed:
        <i>borrow = cost + fee − free ICPUSD</i> (nothing, if the free cash covers it). The pool ends
        up holding the asset and owing ICPUSD.</li>
        <li><b>A short borrows the asset.</b> A sell pays in the asset, so the fill needs the quantity
        it sells; the pool borrows that (less any of the asset it already holds free — usually none),
        sells it, and ends up holding the ICPUSD proceeds and owing the <i>asset</i>. That debt, and
        the interest on it, is counted in units of the asset — which is why a short loses when the
        price rises: the same number of units costs more to buy back. Closing buys the asset back and
        returns it to the vault in kind; the Repay row's token selector shows the same per-token debt
        (<a data-docs-goto="financing">Financing</a>).</li>
        <li><b>Only fills that add exposure borrow.</b> A fill that shrinks a position — selling
        against a long, buying against a short — is paid from what the pool already holds (the asset
        a long holds, the cash a short holds) and borrows nothing, so closing never waits on the
        vault. A fill that carries the pool <i>through</i> flat and out the other side is treated as
        an entry: the holdings cover what they can and the vault lends the excess. Plainly: closing
        never borrows; flipping borrows for the part past flat.</li>
        <li><b>Several fills, one position.</b> A limit entry that fills in slices — or several
        entries in the same direction — builds one position whose entry price is the
        quantity-weighted average of its fills (VWAP). The debt is simpler: each slice's shortfall is
        added to the pool's debt in that token (ICPUSD for a long, the asset for a short), and each
        slice's interest clock runs from its own fill — the first slice has been accruing since it
        filled, the second starts when it does. What you see is one figure per token: the slices'
        shortfalls plus the interest booked so far.</li>
      </ul>
      <p><b>Two slices, in numbers.</b> You fund a pool with <b>$1,000</b> and place a 3× long
      limit entry for 30 units of an asset quoted near $100 (BTC's 0.90 LTV weight; fees left out so
      the arithmetic stays visible). It fills in two slices:</p>
      <ul>
        <li><b>Slice 1 — 15 units at $100 ($1,500).</b> The pool's $1,000 goes first, so this fill
        borrows the <b>$500</b> shortfall. The pool now holds 15 units, has no free cash, and owes
        $500 of ICPUSD — whose 5% clock starts now, about 7 cents a day.</li>
        <li><b>Slice 2 — two days later, 15 units at $102 ($1,530).</b> The remainder rested on the
        book at $102 until a seller hit it. No free cash is left, so this fill borrows all
        <b>$1,530</b>; its own clock starts now, about 21 cents a day. The first slice has meanwhile
        accrued about 14 cents.</li>
        <li><b>The position:</b> 30 units at an entry of <b>$101</b> — the VWAP,
        (15 × 100 + 15 × 102) / 30 — worth $3,060 at the $102 mark. <b>The debt:</b> one ICPUSD
        figure, 500 + 1,530 + 0.14 = <b>$2,030.14</b>. Equity ≈ $1,030 (the first slice is already
        $30 in the money). Health at the second fill = 0.90 × 3,060 / 2,030 ≈ <b>1.36</b> — above
        the 1.25 bar, which is why that slice was allowed to borrow.</li>
      </ul>
      <p><b>What can refuse a fill.</b> Because the vault lends at the fill, a check that passed at
      placement can fail when the fill finally comes — the vault's capacity moves with everyone
      else's borrows, repayments and deposits in between. Three things refuse a borrow:</p>
      <ul>
        <li><b>The vault cap.</b> At most <b>half</b> of what the vault holds in a token may be on
        loan at once — live positions only; resting orders hold none of it. A shortfall that would
        cross the line is refused.</li>
        <li><b>Opening health.</b> After the borrow the pool must stand at health ≥ <b>1.25</b>
        (<a data-docs-goto="health">below</a>) on fresh prices — the whole pool, every token it holds
        or owes, not just the one being traded.</li>
        <li><b>A stale oracle price</b> — for the asset being traded, or for anything in the pool's
        collateral or debt.</li>
      </ul>
      <p>When one of them bites, that slice does not fill and settles nothing; slices already settled
      stand; the rest of the order is <b>cancelled</b> rather than left resting; and the reason is
      recorded — a notice appears in the app, and bots read it from
      <code>getMyReleaseRejections</code>. Nothing dies silently. And since exits never borrow, a
      close can never be refused this way.</p>

      <h2 id="docs-sec-leverage"><span class="docs-num">5</span>Leverage: why the ceiling depends on the asset</h2>
      <p>The margin desk does not value all collateral equally. Each asset has a <b>loan-to-value
      (LTV)</b> weight — the fraction of its market value the desk will count when it sizes the
      cushion. Stable cash counts fully; the more volatile the asset, the bigger the haircut. LTV is
      what caps how much leverage a position can <i>open</i> with — the ceilings below are what the
      opening-health rule works out to per asset:</p>
      <div class="docs-tablebox">
      <table>
        <tr><th>Asset</th><th class="docs-c">LTV weight</th><th class="docs-c">Max opening leverage*</th><th class="docs-c">Borrow APR</th></tr>
        <tr><td>ICPUSD (cash)</td><td class="docs-c">1.00</td><td class="docs-c">—</td><td class="docs-c">5%</td></tr>
        <tr><td>BTC</td><td class="docs-c">0.90</td><td class="docs-c">≈ 2.9×</td><td class="docs-c">8%</td></tr>
        <tr><td>ETH</td><td class="docs-c">0.90</td><td class="docs-c">≈ 2.9×</td><td class="docs-c">8%</td></tr>
        <tr><td>SOL</td><td class="docs-c">0.85</td><td class="docs-c">≈ 2.5×</td><td class="docs-c">10%</td></tr>
        <tr><td>ICP</td><td class="docs-c">0.80</td><td class="docs-c">≈ 2.2×</td><td class="docs-c">10%</td></tr>
      </table>
      </div>
      <p class="docs-dim">*The ceiling the engine enforces today, long or short: when a fill is
      checked, the whole position is scored as borrowed and the pool's LTV-weighted collateral must
      stay ≥ 1.25 × its debt — max leverage = 1 / (1.25 − LTV). A long's own margin is not credited
      against the asset it buys (crediting it would lift the long ceilings to 1 / (1 − LTV/1.25):
      ≈ 2.8× ICP, 3.1× SOL, 3.6× BTC/ETH — an open design decision, tracked as task 1793733873).
      On the ticket you set the margin you commit and the leverage you run, and the size follows
      (margin × leverage ÷ price); the leverage slider stops at the ceiling the engine reports for that
      margin, and the ceiling itself is enforced by the check below.</p>
      <p><b>What the ticket's "Pool capacity" means.</b> As you type, the ticket asks the engine
      the question the fill will ask: the largest size this pool could open <i>right now</i> — the
      opening-health rule above, plus whether the vault could lend the shortfall at today's prices.
      It is a <b>check, not a reservation</b>. The vault's lending capacity (at most half of what it
      holds) is consumed only by positions that have actually filled — never by orders resting on
      the book, yours or anyone else's — so it can be used up, or freed, between placing a resting
      entry and its fill. The fill re-runs the same check and, if the vault can no longer lend,
      fails closed as described above.</p>

      <h2 id="docs-sec-financing"><span class="docs-num">6</span>Financing: what holding a position costs</h2>
      <p>There is <b>no funding rate</b> here. Perpetual-futures venues charge longs or shorts a
      periodic fee to tether a synthetic price to the real one; MULTI/DEX positions hold real assets
      and real debt, so the only carrying cost is real too: <b>interest on what the pool actually
      borrowed</b>, at the APRs in the table above, accruing continuously (linear, per second) on the
      borrowed amount only, from the moment of the fill that took each borrow.</p>
      <ul>
        <li><b>Cash-funded positions cost nothing to hold.</b> If the pool's own cash covered the
        purchase, there is no borrow, so there is no interest — ever.</li>
        <li><b>Nothing accrues before the fill.</b> A staged or resting entry has borrowed nothing
        yet, so leaving it on the book costs nothing — and cancelling it repays nothing.</li>
        <li><b>The lender is the protocol's own vault</b> — the shared inventory funded by
        <a href="#docs/earn">Earn depositors</a>, who receive the interest. At most half the vault's
        holdings can be on loan at once, and "on loan" counts live positions only: resting orders
        hold none of it.</li>
        <li><b>See it per pool.</b> Each pool block's <i>Financing</i> disclosure shows exactly what
        is borrowed and what free cash remains — if it says "Borrowed nothing", holding is free.</li>
        <li><b>Idle debt is yours to retire.</b> A pool can end up owing against free cash (a fill's
        tail that never used its borrow, a top-up you would rather turn into repayment). The
        liquidation pass never repays it for you, and <i>Fund</i> is margin, not repayment — so
        the pool block shows a <i>Repay</i> row while it owes anything: enter an amount and a
        token and it pays min(amount, debt, free) in kind via <code>repayPoolDebt</code>, where
        free is the pool's cash minus what your resting <i>exits</i> earmark (a resting close must
        stay funded; a resting entry borrows at its fill and holds nothing back). The row's
        Debt and Free figures are per token — the selector lists
        exactly what the pool owes (a short's debt is its base token) and the "Will pay" preview
        is the backend's min() to the unit. Paying at least the debt retires it whole, interest
        accrued to that moment included; the button stays disabled while nothing would be paid.</li>
      </ul>

      <h2 id="docs-sec-health"><span class="docs-num">7</span>Health: your distance to liquidation</h2>
      <p>Every pool's standing is one number, recomputed continuously against the
      <a href="#docs/oracle">oracle reference price</a>:</p>
      <div class="docs-formula">health &nbsp;=&nbsp; LTV-weighted collateral value &nbsp;/&nbsp; debt</div>
      <p>In words: what the box holds (haircut by LTV), divided by what the box owes. Three
      thresholds govern the pool's life:</p>
      <div class="docs-tablebox">
      <table>
        <tr><th>Threshold</th><th class="docs-c">Health</th><th>Meaning</th></tr>
        <tr><td>Open / increase risk</td><td class="docs-c">≥ 1.25</td><td>New or increased positions must start at least this healthy.</td></tr>
        <tr><td>Maintenance</td><td class="docs-c docs-bad">&lt; 1.15</td><td>The pool becomes liquidatable.</td></tr>
        <tr><td>Restore target</td><td class="docs-c docs-good">1.25</td><td>A partial liquidation closes only enough to restore this.</td></tr>
      </table>
      </div>
      <p>The UI translates this into the <b>"% to liq"</b> chip on each pool: 100% means no debt and
      no liquidation risk at all; the number falls as the pool approaches the maintenance line, and
      0% means the line has been reached. Watch it like a fuel gauge — and top the pool up
      (<i>Fund</i>) or close some position to move it back up.</p>

      <h2 id="docs-sec-liq"><span class="docs-num">8</span>Liquidation, without drama</h2>
      <p>If the market moves against a pool until its health drops below <b>1.15</b>, the protocol
      steps in and closes part of the position. Nobody phones a margin desk and nobody gets to look
      away — it is deterministic machinery:</p>
      <ul>
        <li><b>Partial, not punitive.</b> It sells (or buys back) only enough to lift health back to
        1.25 — not a full wipe-out of the position.</li>
        <li><b>Priced by the oracle, penalty included.</b> Seized value transacts at the reference
        price with a <b>5% penalty</b> folded in against the pool. The penalty accrues to the
        <a href="#docs/earn">insurance fund</a> — the staked backstop that absorbs bad debt if a
        crash ever outruns liquidations.</li>
        <li><b>No fee, no queue.</b> Liquidations bypass the trading engine entirely: they are not
        trades, pay no trading fee, and cannot be front-run in the book.</li>
        <li><b>Bounded by the box.</b> If prices keep falling, deleveraging continues until the pool
        is solvent or empty. The loss stops at the pool wall — your wallet and other pools are
        untouched, by construction.</li>
        <li><b>Fully recorded.</b> Every step is event-logged, and each borrow-to-close cycle is a
        margin <b>episode</b> in your <a href="#docs/data">permanent history</a>
        (Account → Positions → Positions History).</li>
      </ul>

      <h2 id="docs-sec-example"><span class="docs-num">9</span>A worked example</h2>
      <p>You fund a pool with <b>$1,000</b> and open a <b>3× long on BTC</b> — $3,000 of BTC. Say
      the order fills in two slices. The first buys $1,200 of BTC: the pool's own $1,000 goes first,
      so that fill borrows <b>$200</b>. The second buys the remaining $1,800 with no free cash left,
      so it borrows all <b>$1,800</b>. Debt: $200 + $1,800 = <b>$2,000</b> of ICPUSD — exactly what
      a single fill would have borrowed — with interest on the $200 running from the first fill and
      on the $1,800 from the second; until each slice filled, the pool owed nothing. Opening
      health = 0.90 × 3,000 / 2,000 = <b>1.35</b> — comfortably above the 1.25 bar.</p>
      <ul>
        <li><b>BTC +10%:</b> the BTC is worth $3,300; debt is still $2,000. Your equity is $1,300 —
        up 30%. Close now: sell, repay, walk away with the gain (minus the trade fees and any
        interest accrued).</li>
        <li><b>BTC −15%:</b> the BTC is worth $2,550. Health = 0.90 × 2,550 / 2,000 = <b>1.15</b> —
        the maintenance line. The protocol sells about $710 of BTC at a 5% penalty against the pool:
        debt falls to roughly $1,320, the position shrinks to ≈ $1,840, health is restored to 1.25,
        and equity is ≈ $515 (the ≈$36 penalty went to the insurance fund). You still hold a smaller
        long — nothing else you own was touched.</li>
      </ul>
      <p class="docs-dim">Note what 3× did: a 10% market move became a 30% equity move, and a 15%
      slide met the liquidation line. Leverage compresses the distance between "fine" and
      "liquidating" — that is the price of the amplification.</p>

      <h2 id="docs-sec-reference"><span class="docs-num">10</span>Quick reference</h2>
      <div class="docs-tablebox">
      <table>
        <tr><th>Thing</th><th>Value / where</th></tr>
        <tr><td>Open / maintenance / restore health</td><td>1.25 / 1.15 / 1.25 (LTV-weighted collateral ÷ debt)</td></tr>
        <tr><td>LTV weights</td><td>ICPUSD 1.00 · BTC 0.90 · ETH 0.90 · SOL 0.85 · ICP 0.80</td></tr>
        <tr><td>Max opening leverage</td><td>1 / (1.25 − LTV), long or short → BTC/ETH ≈2.9×, SOL ≈2.5×, ICP ≈2.2× (the whole fill scored as borrowed; the ticket's "Pool capacity" is this bound at today's price)</td></tr>
        <tr><td>Borrow APR (interest on borrows only)</td><td>ICPUSD 5% · BTC/ETH 8% · SOL/ICP 10%, continuous, paid to the <a href="#docs/earn">Earn vault</a></td></tr>
        <tr><td>Funding rate</td><td>None — real borrow interest instead</td></tr>
        <tr><td>When leverage is borrowed</td><td>At the <b>fill</b>, never at placement — a staged or resting entry holds no debt and accrues no interest; cancelling it repays nothing; a fill the vault cannot fund fails closed with a recorded reason</td></tr>
        <tr><td>What a fill borrows</td><td>Long → its ICPUSD shortfall (cost + fee − the pool's free ICPUSD); short → the asset it sells, owed and repaid in kind. Exits borrow nothing; a flip borrows for the part past flat. Several fills: entry = VWAP, debt = the sum per token, each slice's interest from its own fill</td></tr>
        <tr><td>Pool capacity (ticket)</td><td>The largest size the pool could open right now — a check at today's prices, not a reservation; the vault's capacity is consumed by live positions only</td></tr>
        <tr><td>Liquidation</td><td>Partial to health 1.25 · 5% penalty → insurance fund · no trading fee · engine bypassed</td></tr>
        <tr><td>Trade fees on open/close</td><td>Normal maker/taker <a href="#docs/fees">fees</a>; they credit your <a href="#docs/levels">level scorecard</a></td></tr>
        <tr><td>Open a position</td><td>Markets → Place Order → <b>Margin</b> (market or limit + max slippage; size may clamp to collateral)</td></tr>
        <tr><td>Manage pools &amp; positions</td><td>Account → <b>Positions</b>: Fund / Withdraw, Financing disclosure, "% to liq" chip, close buttons</td></tr>
        <tr><td>History</td><td>Positions History (fills &amp; episodes) · Pools History · <a href="#docs/ledger">public ledger</a></td></tr>
      </table>
      </div>

      <p class="docs-dim">Leverage multiplies both directions. The mechanics above bound <i>how</i>
      losses resolve — not whether they happen.</p>
    `,
  },

  {
    slug: "earn",
    nav: "Earn",
    title: "Earn — vault & insurance",
    part: 3,
    blurb: "Fund the AMM's inventory or backstop the margin system — protocol-native yield, priced honestly.",
    html: `
      <div class="docs-crumb">Part IV · Beyond spot</div>
      <h1>Earn — vault &amp; insurance</h1>
      <p class="docs-lead">Two ways to put capital to work inside the protocol itself: market-make
      through the AMM's vault, or underwrite the margin system.</p>

      <h2 id="docs-sec-vault">The AMM vault: earn the spread — and half the fees</h2>
      <p>The <a href="#docs/liquidity">AMM</a> quotes out of a shared inventory vault. Deposit into
      it (<b>Account → Earn</b>) and you own a slice of the venue's market maker — it earns the
      bid/ask spread on every fill, <b>plus half of every trading fee the venue collects</b>
      (<a href="#docs/fees">the other half funds the treasury</a>), and both accrue to your
      position. The vault's accounting is built to be un-gameable:</p>
      <ul>
        <li><b>New deposits never dilute old earnings.</b> Your share of <i>future</i> income is
        weighted by contribution — the fees earned <i>before</i> you arrived stay with the LPs whose
        capital earned them. There is no deposit-timing trick to skim the pool.</li>
        <li><b>P&amp;L is shown against your own cost basis</b> — what your position is worth versus
        what you actually put in. No synthetic APY theatre.</li>
        <li><b>The vault targets balanced inventory</b> across its assets, held there by quote
        pricing that makes depletion progressively expensive (<a href="#docs/liquidity">how the AMM
        defends its reserves</a>) — a deposit is a diversified market-making position, not a bet on
        one coin.</li>
        <li><b>Deposits are gated for fairness:</b> a deposit never settles while the
        <a href="#docs/oracle">oracle</a> is stale or a price jump is awaiting confirmation —
        your request simply waits for the next confirmed price (nobody buys in at a knowingly
        wrong mark; five minutes without one and it is refunded) — and it is sized against pool
        conditions at that moment, so a whale cannot distort the vault in one shot.</li>
        <li><b>Deposits and withdrawals are staged, then settled at the next fresh mark.</b> A
        request reserves your funds (or shares) and settles at the first vault valuation whose
        prices were fetched <i>after</i> you asked — so nobody can join or leave at a mark the
        market has already left. You may <b>cancel a staged request</b> from the Earn card and get
        the reservation back, under the same commit rule as a staged order: not in its first
        3 seconds, and not while a price fetch started after your request is still in flight
        (the card's Cancel button says exactly why it is disabled). A request no fresh prices
        reach within 5 minutes is cancelled and refunded automatically.</li>
        <li><b>Withdrawals pay a 0.4% exit fee</b> that stays in the vault for remaining LPs. It
        exists to make "deposit, then immediately withdraw the basket" strictly worse than just
        trading — an honest exit pays it once; a scheme pays it every lap.</li>
        <li><b>Withdrawals redeem at full vault value — instantly up to your share of what the
        vault holds.</b> The vault is also the <a href="#docs/margin">margin</a> system's lender.
        Every LP share redeems at NAV (the held basket plus the loan book, per share — the same
        figure it was minted at), less the exit fee, and is paid in kind from what the vault
        <i>physically holds</i>: a loan cannot be handed out as inventory. So your
        <b>maximum instant withdrawal</b> is your pro-rata share of the vault's holdings — the
        Earn card shows it as "withdrawable now / total" with how much of the vault is lent out,
        before you deposit as well as after. "Lent out" counts positions that have actually
        filled: a margin order resting on the book has borrowed nothing yet (leverage is borrowed
        at the fill), so it never reduces what you can withdraw. The rest of your value is your share of the loan
        book: those shares stay yours, keep earning, and become withdrawable as the loans repay.
        A request above the limit is refused (nothing is queued), and nobody can drain the
        vault's cash ahead of you — every LP can take only their own share of it. What NAV
        marks is the loan book at face value net of known arrears; a default beyond its
        collateral and the insurance fund lowers NAV for whoever holds shares at that moment.</li>
      </ul>
      <p class="docs-dim">Honest risk note: LP capital carries inventory risk. The AMM holds the
      assets it quotes; in a sharp move its inventory marks down like any market maker's would. The
      spread and fee income pay you to carry that risk — they do not remove it.</p>

      <h2 id="docs-sec-insurance">Insurance staking: underwrite the margin system</h2>
      <p>The <b>insurance fund</b> is the buffer that absorbs losses when a
      <a href="#docs/margin">liquidation</a> cannot fully cover a pool's debt — it is why one blown
      pool never becomes anyone else's problem. It is funded by liquidation penalties, and you can
      stake into it: stakers share the fund's income in exchange for holding first-loss risk on
      margin blowups. The fund's live size and flows are public under
      <b>Status → Insurance Fund</b>.</p>

      <h2 id="docs-sec-together">One account view</h2>
      <p>Wallet balances, every margin pool's equity, and both Earn positions roll up — marked to
      market, net of debt — into the single <b>Account value</b> figure at the top of your Account
      page. Nothing hides off-balance-sheet, including from you.</p>
    `,
  },

  // ═══════════════════════════════ Part V — Money & data ═══════════
  {
    slug: "custody",
    nav: "Deposits & withdrawals",
    title: "Deposits & withdrawals",
    part: 4,
    blurb: "Chain-key custody: native-chain deposit addresses with no bridge operator to trust.",
    html: `
      <div class="docs-crumb">Part V · Money &amp; data</div>
      <h1>Deposits &amp; withdrawals</h1>
      <p class="docs-lead">Moving real assets into a trustless exchange is where most venues quietly
      reintroduce trust. MULTI/DEX is designed to use the Internet Computer's chain-key cryptography
      instead. This page describes that design.</p>

      <div class="docs-callout docs-callout--warn">
        <b>Not built yet — never send real funds.</b> Chain-key custody is the architecture, not
        something this deployment implements. MULTI/DEX runs in <b>play mode</b>: the deposit
        addresses the app shows you are <b>simulated placeholders</b> with no keys behind them and
        no valid checksums, and every balance is play money. Assets sent to them are lost. The
        custody component described below is a separate build, not yet written; withdrawals are
        disabled on any value-bearing posture until it exists.
      </div>

      <h2 id="docs-sec-model">Your deposit address, held by a protocol</h2>
      <p>The intended flow: open the <b>Deposit</b> tab and the exchange derives <b>your own deposit
      address on each supported chain</b> — a real native address (Bitcoin, Ethereum, …), not an IOU
      ticket. The private keys behind those addresses would <i>not exist anywhere</i>: signatures are
      produced by <b>threshold cryptography</b> across the Internet Computer's nodes, under
      consensus. Compare that with the usual options:</p>
      <ul>
        <li><b>No bridge operator</b> — no multisig committee whose keys can be stolen or subpoenaed.</li>
        <li><b>No wrapped-token issuer</b> — no "wBTC-style" middleman whose solvency you must track.</li>
        <li><b>No omnibus hot wallet</b> — per-user addresses mean deposits are attributable by
        construction.</li>
      </ul>

      <h2 id="docs-sec-flow">The flow</h2>
      <ul>
        <li><b>Deposit:</b> send to your address on the native chain; once confirmed, claim it in the
        Deposit tab and your exchange balance is credited. Your <b>first deposit is also your
        registration</b> — it mints your account, your first
        <a href="#docs/levels">badge</a>, and your access to trading calls (the deposit gate).</li>
        <li><b>Withdraw:</b> the exchange would sign a native-chain transaction from its custody and
        send to the address you name. The network's transaction fee is sponsored from a protocol gas
        pool; withdrawals carry a small fixed + percentage fee that replenishes it. <b>Today there is
        no signing leg at all:</b> in play mode a withdrawal simply burns the play balance, and on a
        value-bearing posture the call is refused outright rather than destroy anything.</li>
      </ul>

      <h2 id="docs-sec-solvency">The solvency invariant</h2>
      <p>The design runs two ledgers: what each user is <b>credited</b>, and where the underlying
      assets actually <b>sit</b> — with a hard invariant between them, <b>credits never exceed
      holdings</b>. No fractional anything: no lending out, rehypothecating, or "temporarily
      borrowing" deposits.</p>
      <p>Be clear about what that means right now. With no custody component there are no holdings
      for credits to be measured against, so the invariant is a property of the architecture rather
      than something this deployment currently enforces. What you <i>can</i> check today is the
      credit side, in full: every balance change is on the
      <a href="#docs/ledger">public tape</a>, and the verifier recomputes it from scratch.</p>
    `,
  },

  {
    slug: "ledger",
    nav: "The public ledger",
    title: "The ledger: verify, don\u2019t trust",
    part: 4,
    blurb: "Every balance change on one hash-chained tape \u2014 and how to verify it yourself, in the browser or from a terminal.",
    html: `
      <div class="docs-crumb">Part V \u00b7 Money &amp; data</div>
      <h1>The ledger: verify, don\u2019t trust</h1>
      <p class="docs-lead">Everything the exchange owes anyone is defined by one public, append-only
      tape \u2014 and you can check it without believing a word the exchange says.</p>

      <h2 id="docs-sec-tape">One tape, hash-chained, subnet-signed</h2>
      <p>Every action that moves value \u2014 fills, deposits, withdrawals, vault and insurance flows,
      margin debt \u2014 writes signed <b>delta records</b> to the archive. Each record carries the
      SHA-256 hash of the record before it, so history cannot be quietly edited: change any past
      entry and every hash after it breaks. The newest hash (the <b>head</b>) is placed in the
      archive\u2019s <code>certified_data</code>, which the Internet Computer\u2019s subnet
      <i>signs</i>; and when an archive fills, it is sealed and <b>blackholed</b> \u2014 its
      controller list is emptied, so not even the exchange can touch that slice of history again.
      Fold the delta records per account and you have reconstructed every balance the exchange owes:
      that fold is the liabilities half of <b>Proof of Reserves</b>, computable by anyone from
      public data.</p>

      <h2 id="docs-sec-chain">A chain of canisters, sized to never stop</h2>
      <p>The tape is not one canister — it is a <b>chain</b>. The active archive absorbs events
      until it reaches capacity, counted in <i>events and bytes</i> (each segment stores its
      records in an 8&nbsp;GiB stable region, with capacity checked on every single write); at
      that point it is sealed into the routing table and a <b>pre-spawned successor</b> takes
      over without dropping a beat. The first record of each new segment carries the sealed
      segment's head hash, so the chain of custody crosses canister boundaries unbroken — one
      verification walk covers them all. A segment that cannot take one more record acknowledges
      exactly what it stored and the exchange rolls forward; and if an archive is ever
      unreachable — mid-upgrade, out of cycles, full — nothing is lost: the exchange buffers
      unshipped history in its own state (visible as <code>journalUnshipped</code> under
      <b>Status → Canisters</b>) and re-ships when the archive returns. Each archive's cycle
      balance and freezing limit are tracked and topped up automatically from the exchange's own
      reserves, and sealed segments stay queryable forever through the routing table.</p>

      <h2 id="docs-sec-browser">Verify in the browser</h2>
      <p>Open <b>Ledger</b> from the top menu. The page shows the archive chain (each canister, its
      sequence range, its certified head) and the latest entries with their hashes <i>recomputed
      locally as the table renders</i> \u2014 each row\u2019s hash chip reappears as the row above\u2019s
      <i>prev</i> chip, so the chain is literally visible. Press <b>Verify in my browser</b> and the
      page re-derives the canonical bytes of each event, re-hashes them, walks the links (the last
      500, 2,000, or the full history), and compares the result against the IC-certified head.
      Nothing in that pipeline takes the exchange\u2019s word for anything.</p>

      <h2 id="docs-sec-script">Verify from a terminal (the auditor\u2019s tool)</h2>
      <p>For verification that does not even trust this website, the exchange\u2019s source
      repository ships a <b>standalone verifier</b> \u2014 one self-contained file,
      <code>scripts/verify_ledger.mjs</code>, with the canonical form re-implemented from scratch so
      it agrees with the canister only if the bytes really match. You need
      <b>Node.js 18+</b> and one library:</p>
      <pre class="docs-code">npm i @icp-sdk/core</pre>
      <p>Then point it at the exchange (the backend canister id is shown under
      <b>Stats \u2192 Canisters</b>, with a Copy button):</p>
      <pre class="docs-code"># quick check \u2014 the newest 2,000 events
node scripts/verify_ledger.mjs --backend &lt;canister-id&gt; \\
     --host https://icp-api.io --last 2000

# the full audit \u2014 every event ever, plus the Proof-of-Reserves fold
node scripts/verify_ledger.mjs --backend &lt;canister-id&gt; \\
     --host https://icp-api.io --full --fold</pre>
      <p>Flags: <code>--host</code> is the gateway (mainnet <code>https://icp-api.io</code>; a local
      replica like <code>http://127.0.0.1:8000</code> works too), <code>--last N</code> checks the
      newest N events \u2014 across every sealed archive the window reaches, each visited sealed head
      certificate-checked; only the tape below the window is skipped \u2014, <code>--full</code> (the
      default) walks the entire history across every sealed archive, and <code>--fold</code> additionally folds every delta row into per-account balances
      and prints <b>per-token liability totals</b> \u2014 the numbers to compare against on-chain
      custody.</p>
      <p>The script checks three things and exits non-zero if <i>any</i> fail:</p>
      <ul>
        <li><b>Every link</b> \u2014 each event\u2019s recomputed hash equals the next event\u2019s
        <code>prevHash</code>, including across sealed archive canisters;</li>
        <li><b>Every head</b> \u2014 each archive\u2019s recomputed head equals its certified head;</li>
        <li><b>The signature</b> \u2014 the head\u2019s IC certificate validates against the network
        root key, so the subnet itself vouches for what you just recomputed. (On a local dev replica
        this last step reports \u201cunavailable\u201d \u2014 test-replica certificates differ; on
        mainnet it must say <i>IC certificate VALID</i>.)</li>
      </ul>
      <p>Exit codes: <b>0</b> everything verified; <b>1</b> a check failed; <b>2</b> usage;
      <b>3</b> <i>inconclusive</i> \u2014 nothing failed, but the readable tape stopped short of the
      certified head and no re-fetched head landed inside what was read, so nothing the network
      signed covers the walk. The script re-fetches the head a bounded number of times
      (<code>--anchor-retries</code>) before saying so; an honest gateway whose replicas are a
      moment apart catches up on the retry. A 3 is never a pass \u2014 re-run, or try another
      gateway.</p>
      <p class="docs-dim">A successful run means: the history you can download is the history that
      happened, the totals it implies are the exchange\u2019s true liabilities, and the network \u2014
      not the exchange \u2014 signed the head you checked it against.</p>
    `,
  },

  {
    slug: "data",
    nav: "History & data",
    title: "Your data & the open exchange",
    part: 4,
    blurb: "Permanent archives, the public event log, live queries, and AI that can read it all.",
    html: `
      <div class="docs-crumb">Part V · Money &amp; data</div>
      <h1>Your data &amp; the open exchange</h1>
      <p class="docs-lead">A trustless venue owes you two things about data: your history must be
      permanent, and the venue's behaviour must be inspectable. Both are built in.</p>

      <h2 id="docs-sec-account">Your account, in seven tabs</h2>
      <p><b>Account</b> is your home: <b>All</b> (account value by venue, plus your
      <a href="#docs/badges">badges</a>), <b>Wallet</b> (balances), <b>Spot</b> (open orders, recent
      closes, trades), <b>Positions</b> (margin pools and episodes), <b>Earn</b> (vault and
      insurance stakes), <b>Archive</b> (deep history), and <b>Fee Level</b> (your earned level and
      scorecard — the live view of <a href="#docs/levels">the rulebook</a>).</p>
      <p>The <b>account value</b> beside your name in the header is a button. Click it for a compact
      ledger of what the figure is made of — the wallet's assets, each margin pool with its distance
      to liquidation, your AMM Vault and Insurance Fund stakes — and what has changed since you
      last looked, split into prices, positions, yield and trades &amp; fees. Every line is a link
      into the tab above; on a phone the ledger slides up from the bottom.</p>

      <h2 id="docs-sec-archive">A permanent archive, not a rolling buffer</h2>
      <p>Exchanges love to forget: histories that stop at 90 days are the norm. MULTI/DEX ships every
      account event — fills, transfers, margin episodes, deposits, withdrawals — to a dedicated
      <b>archive canister</b> that exists to remember. It is tax-grade, permanent history: paginate
      back years, and it survives every upgrade of the exchange itself. The archive pays for its own
      storage out of the <a href="#docs/fees">treasury's fuel economy</a>, and its vital signs are
      public under <b>Status → History Archive</b>. The same tape is public, hash-chained and
      verifiable by anyone — see <a href="#docs/ledger">The ledger</a>.</p>

      <h2 id="docs-sec-log">The public event log</h2>
      <p>The engine narrates itself: fills, oracle updates and stalls, level changes, badge awards,
      order kills and clamps, liquidations, rebalances — all written to a public, queryable event
      log. When these docs claim a behaviour ("liquidations restore to 1.25", "fills clamp at ±2% in
      a stall"), the log is where you catch it happening.</p>

      <h2 id="docs-sec-intelli">Intelligence: query the venue like a database</h2>
      <p>The <b>Intelligence</b> tab exposes a live query surface (OQL) over the exchange and the archive:
      markets, order books, events, pools, positions — with <b>row-level scoping</b> enforced
      server-side. Your pools, positions, balances and closed orders are yours alone: those entities are
      owner-scoped and another caller's rows never leave the canister.</p>
      <p><b>What is deliberately public.</b> This is an anti-mixer venue, so the money-flow ledger is a
      published record, not a private one: <b>every user's deposits and withdrawals are readable by
      anyone, attributed to the principal that made them</b>, through the archive and the public event
      tape. That is a design requirement — it is what makes reserves and flows independently
      verifiable — not an accident, and it is worth understanding before you fund an account. Trade
      fills and liquidations are likewise attributed on the tape. Presets cover the common questions,
      or write your own queries.</p>

      <h2 id="docs-sec-ai">And AI that can read it all</h2>
      <p><b>Agent Chat</b> drives that same query surface in natural language — it can walk the live
      order book, check your positions, or explain an event, and anything state-changing is
      confirm-gated back to you: a proposed action is first <b>resolved against live data</b> (the
      exact market, the pool by number and name, the amount in the venue's units) and checked the way
      the canister would check it, then shown on a card with the decoded details and a caution line —
      <i>nothing changes until you confirm</i>, a decline is final, and after a confirmed action the
      chat re-reads the state it changed before reporting. It knows who is asking and which page and
      market you are on, it answers <i>how do I…?</i> questions from these Docs (citing the pages it
      drew on — and it still does that when no AI key is configured), and every answer keeps its
      workings behind a link. The same interface is open to external agents: connect Claude or
      another assistant through the IC connector and it operates the exchange <i>as you</i>, under
      your keys, against the same scoped API. Nothing about the venue is a black box — not even to
      your tools.</p>

      <p class="docs-dim">That is the whole exchange: sealed matching, oracle-anchored liquidity,
      earned privilege, boxed risk, chain-key custody, permanent memory — one autonomous service,
      governed in the open. Welcome to MULTI/DEX.</p>
    `,
  },

  // ═══════════════════════ Part VI — Automate & integrate ══════════
  {
    slug: "market-making",
    nav: "Market making",
    title: "Market making — quote the books, earn the venue",
    part: 5,
    blurb: "What makers already earn here (fees to zero, queue priority, a snipe shield) and the bot-safety API: dead-man switch, cancel-all, atomic replace, bulk quotes, post-only.",
    html: `
      <div class="docs-crumb">Part VI · Automate &amp; integrate</div>
      <h1>Market making — quote the books, earn the venue</h1>
      <p class="docs-lead">A market maker stands ready to trade — resting a bid and an ask so
      everyone else finds a price waiting. This venue pays for that standing readiness more
      directly than most: this page is what you get, and the safety API your bot needs.</p>

      <nav class="docs-toc">
        <a data-docs-goto="what">What a maker is</a>
        <a data-docs-goto="program">What the venue pays</a>
        <a data-docs-goto="safety">The bot-safety API</a>
        <a data-docs-goto="start">Getting started</a>
        <a data-docs-goto="honest">The honest print</a>
      </nav>

      <h2 id="docs-sec-what"><span class="docs-num">1</span>What a maker is</h2>
      <p>Every <a href="#docs/markets">order book</a> has two kinds of participant: takers, who
      cross the spread because they want to trade <i>now</i>, and makers, whose resting limit
      orders are what the takers cross into. A maker quotes both sides — buy a little below the
      going price, sell a little above — and earns the gap between them, trade by trade. The risk
      is being on the wrong side of a move: the price runs, your stale quote fills, and the spread
      you earned doesn't cover it. Everything on this page — the fee ladder, the shield, the
      safety API — exists to make that trade-off winnable.</p>

      <h2 id="docs-sec-program"><span class="docs-num">2</span>What the venue pays for quotes</h2>
      <p>None of this is a promotion — it is standing machinery, live today, measured by the
      exchange itself:</p>
      <ul>
        <li><b>Maker volume counts double.</b> The <a href="#docs/levels">earned-level score</a>
        weights filled maker volume 2× against taker volume — quoting climbs the ladder twice as
        fast as taking.</li>
        <li><b>Maker fees fall to zero.</b> The <a href="#docs/fees">fee ladder</a> steps down
        with your level; at Level 4 the maker fee is exactly 0 — you keep the whole spread.</li>
        <li><b>The quote-freshness shield.</b> At Level 4, the moment your reprice is staged your
        resting quotes on that market become non-takeable until it lands — and during an oracle
        stall your whole book is protected. Nobody snipes your stale quote while your update is
        in flight. (Takers see this honestly: a shielded quote simply isn't theirs to hit.)</li>
        <li><b>Queue priority.</b> Within each sealed batch, Level 3–4 orders execute first
        (<a href="#docs/matching">how matching works</a>) — your requotes land on the book before
        lower-tier flow in the same pass.</li>
        <li><b>Load-shed immunity.</b> Under ingress load the venue sheds lowest levels first;
        high-level quoting keeps trading through the storm.</li>
        <li><b>Permanent maker <a href="#docs/badges">badges</a></b> — Maker Clout, Two-Sided,
        Iron Quoter — sealed into the permanent record.</li>
      </ul>

      <h2 id="docs-sec-safety"><span class="docs-num">3</span>The bot-safety API</h2>
      <p>Everything here works over plain update calls and queries — no websockets; your bot
      polls. One semantic to internalize first: <b>every order stages, then releases</b> into a
      sealed batch about a second later (<a href="#docs/matching">the matching engine</a>). A
      placement returning <code>ok</code> means <i>staged</i>, not <i>filled</i> — reconcile fills
      from your orders and trades, and expect a release to clamp or kill an order with a recorded
      reason (<code>getMyReleaseRejections</code> — nothing dies silently). And one identity rule:
      the id a placement returns is the <b>staged</b> id; when the remainder rests on the book it
      is reborn under a fresh order id. <code>getMyOrderStatus</code> bridges the rebirth (it
      reports <code>releasedAsId</code>), and cancel / replace resolve placement ids through the
      same link automatically.</p>
      <ul>
        <li><b><code>cancelAllAfter(opt seconds)</code> — the dead-man switch.</b> Arm it once
        (5&nbsp;s to 1&nbsp;day) and every trading call you make re-arms the full window
        (placements, bulk, replace, market orders, swaps, cancels). If your bot crashes and the
        window lapses, the exchange cancels <i>everything</i> you have resting or staged and logs
        why. <code>null</code> disarms; <code>getMyCancelAllAfter()</code> shows the armed state.
        Without it, a crashed bot's quotes rest for up to 30 days.</li>
        <li><b><code>cancelAllMyOrders(opt marketId)</code></b> — cancel every order you own,
        one market or all (<code>null</code>), staged and resting alike; returns the count.
        Wallet-scoped: margin-pool position orders are deliberately excluded (cancel those with
        <code>cancelPoolOrder</code>, which repays nothing — leverage is borrowed at the fill, so an unfilled entry holds no debt).</li>
        <li><b><code>replaceMyOrder(orderId, price, quantity)</code></b> — cancel + place in one
        message, so there is no consensus round where your old quote is dead and the new one
        hasn't arrived. The cancel always stands; if the replacement fails validation you're told
        and left flat — for a quoter, pulled beats stale. The replacement is a plain GTC limit on
        the same market and side.</li>
        <li><b><code>placeLimitOrdersBulk([items])</code></b> — a full ladder in one message, up
        to 32 items, each <code>{ marketId; side; price; quantity; expiresInSec; postOnly }</code>
        with a per-item result (never all-or-nothing). Everything accepted lands in the
        <i>same</i> sealed batch.</li>
        <li><b><code>placeLimitOrderPO(...)</code> — post-only.</b> If, at release, your order
        would cross funded, takeable depth, it is killed with a recorded reason instead of taking.
        At maker fee 0 you must never accidentally pay taker; the check uses the same funded-depth
        walk the engine itself uses, so a stale unfunded overlap doesn't kill your quote.</li>
        <li><b>Introspection, one call each.</b> <code>getMyTradesSinceId(sinceId, limit)</code>:
        your fills by id cursor with the <i>exact</i> quote-leg fee each side paid — PnL to the
        penny without folding the archive (fees are retained for a bounded recent window; the
        <a href="#docs/ledger">ledger</a> is the deep history). <code>getMyOrderStatus(id)</code>:
        staged / resting / closed, following the id rebirth. <code>getMarketSpecs()</code>: every
        constant bots otherwise learn from rejection strings — decimals, tick, minimums, bands,
        caps, seal delay. <code>getReleaseInfo(market)</code>: the armed seal deadline, so a bot
        phase-aligns its requotes. <code>whyAmIRefused()</code>: the admission gate explained
        (queries bypass it, so a shed bot can always self-diagnose) — <code>admittedNow</code> is
        the verdict for order entry and other sheddable updates, while <code>exitsAdmitted</code>
        and <code>exitMethods</code> say that cancels, closes, unstakes and withdrawals are
        admitted at <i>any</i> load floor: the exit set is never shed, so a shed bot can always
        flatten even while it cannot quote. <code>preRegistrationAdmitted</code> and
        <code>preRegistrationMethods</code> cover the signed-in, never-deposited principal: that
        set (profile, preferences, username, the two Internet Identity sign-in legs) is the
        <i>only</i> one it reaches, on every posture, and everything outside it is refused
        pre-consensus until the first deposit registers the principal. Pre-deposit profile and
        preference state lives in a hard-capped, self-expiring store until then
        (<code>getPreRegStoreStats</code> reports size, cap and counters); the first deposit makes
        it permanent. One wrinkle: <code>getUserPreferences</code> is still an <i>update</i> call,
        not a query, until apiVersion 7.0.0 (Candid cannot flip the mode inside a major) — sign it
        like a mutation. <code>getAccessPolicy</code>
        additionally reports open-order counts and caps, uptime qualification, your dead-man
        state, the self-trade policy, and a machine-readable <code>apiVersion</code>.</li>
      </ul>

      <h2 id="docs-sec-start"><span class="docs-num">4</span>Getting started</h2>
      <ol>
        <li><b>Identity:</b> a bot signs with a raw keypair (browser passkeys don't apply) — any
        agent library for the Internet Computer works.</li>
        <li><b>Fund it:</b> your first <a href="#docs/custody">deposit</a> registers the
        principal; the balance is your quoting capital.</li>
        <li><b>Read your standing:</b> <code>getAccessPolicy</code> returns your level, your
        current fees, the level thresholds, and the maker-quality constants — one query, machine
        readable.</li>
        <li><b>Poll, don't stream:</b> <code>getMarketChanges</code> is a version-cursor delta
        query — book changes, your fills, and balances in one round trip.</li>
        <li><b>Arm the dead-man switch before your first quote.</b> Then quote both sides and
        let the ladder do the rest. Orders below <b>10 ICPUSD</b> of value are refused (dust
        exemption aside), and prices far outside the market's band are rejected at placement.</li>
      </ol>

      <h2 id="docs-sec-honest"><span class="docs-num">5</span>The honest print</h2>
      <p class="docs-dim">Sealed batching means ~1–2 s between staging and release — that is the
      venue's anti-snipe working for you, and it also means nobody, including you, trades inside
      the seal. Query reads are fast but uncertified (verify against the
      <a href="#docs/ledger">public ledger</a> when it matters). And your competitor is the house
      <a href="#docs/liquidity">AMM</a>, which quotes every market around the oracle price — the
      spread it offers is the rate card you have to beat. When you do beat it, the fee ladder,
      the shield, and the queue are yours.</p>
    `,
  },

  // ═══════════════════════════════ Part VII — Community ════════════
  {
    slug: "prizes",
    nav: "Prizes & bounties",
    title: "Prizes & bounties",
    part: 6,
    blurb: "Recognition for play-mode work: prizes for fair trading wins, and a direct line for exploit and bug reports — and the code is open to fork.",
    html: `
      <div class="docs-aurora" aria-hidden="true"><i></i><i></i></div>
      <div class="docs-crumb">Part VII · Community</div>
      <h1>Prizes &amp; bounties</h1>
      <p class="docs-lead">Play mode is a proving ground, and DFINITY has put real rewards behind
      it: prizes for the traders who come out on top, and recognition for the people who find what's
      broken. Paper stakes on the exchange — real recognition off it.</p>

      <div class="docs-map docs-map--pair">
        <a class="docs-map-card" href="#status">
          <span class="docs-map-part">Prizes</span>
          <span class="docs-map-title">Win by trading</span>
          <span class="docs-map-blurb">DFINITY is committed to giving out prizes to those who
          succeed in trading — without cheating. Climb the leaderboard on skill; bots and
          strategies welcome, exploits are not.</span>
        </a>
        <a class="docs-map-card" href="mailto:multidex@dfinity.org">
          <span class="docs-map-part">Bounties</span>
          <span class="docs-map-title">Break it, report it</span>
          <span class="docs-map-blurb">Serious exploit and bug reports are valued, and rewards are
          at DFINITY's discretion — there is no standing bounty programme (see SECURITY.md). One
          address for both: multidex@dfinity.org.</span>
        </a>
        <a class="docs-map-card" href="https://github.com/dfinity/public-multidex" target="_blank" rel="noopener noreferrer">
          <span class="docs-map-part">Open source</span>
          <span class="docs-map-title">Read every line</span>
          <span class="docs-map-blurb">The complete exchange — matching engine, AMM, custody, UI,
          these very docs — is public at github.com/dfinity/public-multidex.</span>
        </a>
        <a class="docs-map-card" href="https://github.com/dfinity/public-multidex/fork" target="_blank" rel="noopener noreferrer">
          <span class="docs-map-part">Propose</span>
          <span class="docs-map-title">Fork it, ship it</span>
          <span class="docs-map-blurb">Think you can make it better? Fork the repo, deploy your
          version to the Internet Computer, and show a running link.</span>
        </a>
      </div>

      <h2 id="docs-sec-bounty"><span class="docs-num">1</span>Reporting exploits &amp; bugs</h2>
      <p>Found a way to mint balances, dodge a fee, jump the queue, break settlement — or just
      something that misbehaves? That finding is worth more than anything it could win you on the
      leaderboard. Write it up (what you did, what you expected, what actually happened; a
      reproducible path multiplies the value) and send it in:</p>
      <div class="docs-formula">exploits &amp; bug reports → <b><a href="mailto:multidex@dfinity.org">multidex@dfinity.org</a></b></div>
      <p class="docs-dim">Using an exploit to inflate P&amp;L disqualifies the prize — reporting
      it earns the bounty. Choose the payout that exists.</p>

      <h2 id="docs-sec-propose"><span class="docs-num">2</span>Proposing changes</h2>
      <p>Because the exchange is <a href="https://github.com/dfinity/public-multidex" target="_blank"
      rel="noopener noreferrer">open source</a> and the platform permissionless, a proposal here
      isn't a slide deck — it's a working exchange:</p>
      <ol>
        <li>Fork <a href="https://github.com/dfinity/public-multidex" target="_blank" rel="noopener noreferrer">github.com/dfinity/public-multidex</a>
        and build your improvement.</li>
        <li>Deploy your version to the Internet Computer, so anyone can try it live.</li>
        <li>Send DFINITY the link — <a href="mailto:multidex@dfinity.org">multidex@dfinity.org</a> —
        and/or share it on social media.</li>
      </ol>
      <p class="docs-dim">A running link is the most persuasive pull request. The strongest ideas
      shape what ships — see the <a href="#docs/changelog">change log</a>.</p>
    `,
  },

  {
    slug: "changelog",
    nav: "Change log",
    title: "Change log",
    part: 6,
    blurb: "What's new on the exchange, version by version — curated highlights of the road to launch.",
    html: `
      <div class="docs-crumb">Part VII · Community</div>
      <h1>Change log</h1>
      <p class="docs-lead">Through community evaluation and simulated trading, MULTI/DEX is
      steadily developing and getting better — in preparation for its transition into the first
      on-chain asset swap and order-book exchange, with an order-book AMM, where assets on
      multiple chains can be trustlessly deposited, traded, and withdrawn directly, and AIware
      functionality lets users analyze the markets and their positions, and trade, via AI.</p>

      <h3>1.81 — 4 November 2026</h3>
      <ul>
        <li><b>The account value opens.</b> The figure beside your name in the header is now a
        button: click it for a compact ledger of what it is made of — the wallet's assets, each
        margin pool with its distance to liquidation, your AMM Vault and Insurance Fund stakes —
        and what has changed since you last looked, split into prices, positions, yield and
        trades &amp; fees. Every line is a link into the Account tab it belongs to, a venue you
        hold nothing in reads "nothing yet", and the ledger keeps up with every balance refresh
        while it is open; on a phone it slides up from the bottom.</li>
        <li><b>The menu on phones is a drawer.</b> The hamburger slides a panel in from the
        left over the page — which stays exactly where it was, instead of being pushed down by a
        header that grew — with the lockup, the theme switch and a close at its head, the sections
        as rows, your username pill, and Sign out at the foot.
        <b>Platform</b> (the former System) and the pill carry a chevron: a tap opens their
        sections as a list with a "Menu" row back. <b>AI</b> is now an icon: last in the desktop
        nav, and on phones in the header itself, beside your account value.</li>
        <li><b>Signing out clears the account value.</b> On a phone the header's figure used to
        keep its last reading after Sign out; it now goes with the session.</li>
        <li><b>Two phone fixes in the Account area.</b> The profile card stacks on a phone — the
        avatar beside your name and ID, the principal and the member line across the card, the
        regenerate control a foot row with its count beside it — instead of squeezing its details
        into a sliver that broke the username at its hyphens and wrapped the principal every
        eight characters; and the drawer's account pill is avatar, name and chevron only — your
        account value stays in the header, in view beside the open drawer — with a long username
        ellipsised on one line.</li>
        <li><b>Bot authors: nothing to change.</b> apiVersion stays <b>6.0.0</b> and the interface
        is the one the 1.80 drop published, byte for byte. See the <a href="https://github.com/dfinity/public-multidex/blob/HEAD/candid/README.md" target="_blank" rel="noopener noreferrer">API docs</a>.</li>
        <li><b>Under the hood.</b> The sixth one-shot state migration, which the 1.80 upgrade
        applied once per venue, is retired from the build, so this upgrade is a plain one. The
        loading page's badge reads <b>VERSION 1.81</b>; a tab left open on 1.80 refreshes itself,
        and Platform → Canisters shows the backend answering 1.81.0 beside it.</li>
      </ul>

      <h3>1.80 — 4 November 2026</h3>
      <ul>
        <li><b>The Place Order box reads top-down, as you decide.</b> Spot | Margin are the
        header's tabs, Buy | Sell (Long | Short on Margin) is the one coloured surface, the money
        rows — what you can trade and your resting orders; on Margin your wallet margin, buying
        power and the pool's free margin — come before the inputs they constrain, Limit | Market
        sits on the price field it swaps, the price field offers Mid / Bid / Ask from the live
        book, the unit sits inside the size field, the size slider is a drawn track with quarter
        stops, an editable % box and a "100% = N ICP" line, expiry, max slippage and margin pool
        are one-line rows, and the button states the order it will place. The frame is feedback:
        its outline takes the side's hue (mint buy, clay sell) and Margin adds a second hairline
        inside the edge; the rows wrap instead of overflowing, so the box never grows a sideways
        scrollbar.</li>
        <li><b>Margin: the collateral first.</b> A Margin field and slider over everything you can
        commit — the pool's free margin first, shaded on the rail, then your wallet — and a
        Leverage slider from 1× up to the ceiling the engine allows for that margin ("Max
        N.NNx"); the Size is derived (margin × leverage ÷ price) and still typable, back-solving
        the margin. The ceiling is the engine's own answer, never a table in the page, and the
        leverage chips are gone. The preview and the order use the margin you set, the size is
        floored to the asset's precision (no more "Need $22,112 margin — only $22,112 in wallet"),
        and a real shortfall is stated to the cent.</li>
        <li><b>100% is what your wallet can actually reserve.</b> A market buy is sized at the
        slippage cap plus the taker fee — what the engine reserves — a limit buy at its price plus
        the fee, every size on your spendable balance (net of resting orders, which "Available to
        trade" now shows), and the hint says what the figure is net of: "100% = N ICP after the 5%
        slippage cap and the 0.10% fee". A market long's note explains its lower ceiling
        ("ceiling at the 5% slippage cap — a limit order at the mark allows more"), and the
        ceiling keeps two decimals (Max 1.96x, not 1.9x).</li>
        <li><b>Quantities carry thousands separators.</b> "Long 108,265.4 ICP", "100% = 2,012.4
        ICP" and the resting-orders row read like the money figures beside them; the Size field
        you type into keeps raw digits, and the order book and trades stay ungrouped.</li>
        <li><b>The preview says what the fill will be held to.</b> For a long and for a short, the
        margin preview's maximum size is the smaller of what the vault can lend and what the
        opening-health bar allows at the worst-case price, and past it the preview says no and
        names the side — before, a long's preview could promise what the fill then clamped. The
        Margin page here (§5 and the quick reference) states the ceilings the engine enforces
        today, 1 / (1.25 − LTV): BTC/ETH ≈2.9×, SOL ≈2.5×, ICP ≈2.2×.</li>
        <li><b>The launch notice.</b> The strip above the header carries the launch text (shown
        once more if you had dismissed the old one); on a phone it collapses to its first sentence
        and the story link with a Read more / Show less you can operate from the keyboard, and
        its ✕ sits in the strip's top-right corner instead of trailing the text.</li>
        <li><b>The fuel banner.</b> The freeze countdown shows only inside 24 hours (System →
        Canisters keeps its 72-hour view), the treasury sentence matches the venue — on a play
        venue it says the self-funding treasury holds no real assets — and is painted right the
        first time rather than after the next poll, and the donation tiers step aside on phones
        while the frozen tier stays on every width.</li>
        <li><b>Sign-in on the current Internet Identity library.</b> The Internet Identity window
        opens at <code>id.ai</code>, an idle hour signs you out and reloads as before, signing
        out revokes the session at Internet Identity, and a session that ends elsewhere — expiry,
        a sign-out in another tab — is noticed within 15 seconds and toasted.</li>
        <li><b>A missing history segment no longer stalls your history.</b> A sealed archive
        segment whose canister is gone is tolerated everywhere it is read: the trade-history
        backfill closes that source and appends "· segment N unavailable" to its progress line,
        and Account → Archive skips the dead hop with a per-segment note instead of parking on it.
        The controller can name the failure and retire the row, declaring the hole on the tape as
        a <code>#gap</code> event, as an archive shed does.</li>
        <li><b>Local venues.</b> A venue served from a port of its own is registered as a sign-in
        origin when it is deployed, so Verify-with-Google — and the play deposits it unlocks —
        work there too.</li>
        <li><b>Bot authors: nothing to change.</b> apiVersion stays <b>6.0.0</b> and the interface
        is the one the 1.75 drop published; the archived-events pagers' new
        <code>unavailable</code> field is optional, so a 6.0.0 decoder reads the reply unchanged.
        See the <a href="https://github.com/dfinity/public-multidex/blob/HEAD/candid/README.md" target="_blank" rel="noopener noreferrer">API docs</a>.</li>
        <li><b>Under the hood.</b> The build carries the sixth one-shot state migration — it sweeps
        the fossils the 6.0.0 removal left in stable memory — applied once per venue at this
        upgrade and then retired like its five predecessors. The loading page's badge reads
        <b>VERSION 1.80</b>; a tab left open on 1.75 refreshes itself, and Platform → Canisters
        shows the backend answering 1.80.0 beside it.</li>
      </ul>

      <h3>1.75 — 1 November 2026</h3>
      <ul>
        <li><b>Agent Chat, rebuilt on the open-saas assistant's trust rules.</b> A proposed
        action is now <b>resolved and validated before its card</b>: the exact market, pool and
        token are looked up (an ambiguous name comes back as a question listing the candidates,
        never a guess), amounts are converted in code, and what the canister would refuse — an
        unknown market, slippage outside 1–25%, a balance you lack, an order under the 10 ICPUSD
        minimum — is refused up front. The card shows the decoded details and a caution line for
        slippage, leverage and anything that borrows or leaves the exchange; declining is final,
        and after a confirmed action the chat <b>re-reads what changed</b> before reporting, then
        refreshes the Markets and Account views. It knows who is asking (your username and
        principal), the page, market and pool you are on, and today's date; suggested prompts
        cover portfolio, markets, margin, earn, the leaderboard and help; the step line narrates
        each read; a footer states what the chat can do right now. <b>Help questions</b>
        ("how do I deposit?") are answered from these Docs with in-app citations — also when the
        AI key is off or the model does not answer — and failures are classified plainly (a
        refusal, a model outage, a step budget) with the technical reason in small print and
        your question put back in the box to retry. The conversation survives a reload in this
        tab (a card that was pending comes back as "nothing ran") and is purged at sign-out. The
        tab itself is now called <b>Agent Chat</b> (it was the AI assistant); its address is
        <code>#ai/agent-chat</code>, and the old <code>#ai/assistant</code> link still lands
        there. Help answers lead with one actionable next step, and the chat's standing
        instructions were cut by a quarter — the long venue description now loads only when a
        question needs it.</li>
        <li><b>A Home page.</b> The logo now opens <code>#home</code>: the strap
        "Actually decentralized. Secure. Yours.", a short introduction, Swap / Markets / Earn
        boxes that lead into the app, a live proof strip and an open-source section. Swap
        keeps a strap of its own — "Directly swap digital assets. No middleman." — so the
        two pages do not repeat each other.</li>
        <li><b>MCP is gone from the product.</b> The Docs page on wiring an MCP client to the
        exchange is deleted and its cross-links point at Agent Chat instead; the API contract
        for bot authors stays where it was, in the public repository's
        <code>candid/README.md</code>.</li>
        <li><b>Docs → Margin explains borrow-at-fill end to end.</b> What a fill borrows, a
        two-slice worked example and a quick-reference row — the page now describes the
        model this release ships (below), not the old borrow-at-placement one.</li>
        <li><b>Trade history backfills in seconds.</b> Reading your archived fills used to
        walk the whole archive one segment at a time; it now pages fills only, probes six
        segments at once and shows a live "segments 7–12 of 42" line while it works. After an
        upgrade the archive rebuilds its own fill and deposit/withdrawal indexes, so neither
        history goes slow after a release.</li>
        <li><b>A major release.</b> The first product version since 1.60 (7 August): the
        public API broke (apiVersion <b>6.0.0</b>), and margin, vault and matching behaviour
        changed in ways you will notice. Its hardening half — the API, margin and vault changes
        below — has been live since 31 October under the 1.60 badge; everything else in this
        entry arrives with the 1.75 badge. The full list, in user terms, is
        <code>docs/release-notes.md</code> in
        <a href="https://github.com/dfinity/public-multidex" target="_blank" rel="noopener noreferrer">the repository</a>;
        the highlights follow.</li>
        <li><b>A leveraged order holds no debt until it fills.</b> A leveraged limit order
        used to borrow its whole leverage from the vault the moment it was placed, and paid
        interest while it rested. Now placement only checks that the vault could fund it: a
        staged or resting entry holds <b>zero debt and pays no carry</b>, and the fill
        borrows exactly what it fills, against fresh prices, with interest running from that
        instant. The one new outcome: if the vault has run dry by the time your order would
        fill, it does not fill — the remainder is cancelled and one record in your release
        rejections says why.</li>
        <li><b>Vault LP: redemption at NAV, sealed deposits and withdrawals.</b> Every LP
        share now redeems at the same per-share value it was minted at, so a
        deposit-then-withdraw round trip costs exactly the fee — an exit no longer forfeits
        its slice of the loan book. What you can withdraw <i>instantly</i> is your share of
        what the vault physically holds (a loan cannot be handed out in kind); a request past
        that cap is refused with the figure, never clamped or queued, and after a maximum
        exit your remaining shares stay locked until borrowers repay — so repeated maximum
        exits can no longer drain the liquidity of the LPs who stay. Both doors are now
        sealed: a deposit or withdrawal is staged and settles a second or two later at a
        price fetched <i>after</i> you committed, so nobody can mint or redeem against a
        stale mark, and the old "deposit paused: price is stale" flicker is gone.</li>
        <li><b>Bot authors: apiVersion 6.0.0 is breaking.</b> <code>depositLp</code> /
        <code>withdrawLp</code> return a staged request — read its id from <code>#ok</code>
        and poll <code>getMyStagedLpRequests</code>; <code>seedAmmPool</code> is
        controller-only; and the long-inert protection-window surfaces are gone
        (<code>getMyPendingMatches</code>, <code>placeProtectedLimitOrder</code>, the
        <code>pendingMatches</code> result fields, <code>setAmmConfig</code>'s sixth
        argument). Since 1.60 the interface also took 3.0.0, 4.0.0 and 5.0.0 — the tape's
        <code>#gap</code> and <code>#config</code> events, and the removal of the never-fed
        adverse-flow queries. See the <a href="https://github.com/dfinity/public-multidex/blob/HEAD/candid/README.md" target="_blank" rel="noopener noreferrer">API docs</a>.</li>
        <li><b>The September hardening wave</b> — 37 tasks from a 48-finding security scan,
        all landed: bounded margin-pool fills so a pool's equity cannot go negative at the
        worst-case price; fresh whole-basket prices required for any action that adds debt;
        a scan budget on every book-walking simulation; every cross-swap leg capped around
        its market's mid and settled through the sealed release like every other order; both
        release passes paced; a maker shield that holds only while a genuine repricing is in
        flight; ledger verifiers that never report success unanchored; an atomic season seal;
        unregistered principals held to the sign-up methods; one slow or one off-price feed
        unable to stall or freeze the mark; and a deploy pipeline that pins canister ids and
        controller sets and reads the posture back after every install.</li>
        <li><b>The funding authority.</b> The simulated traders are refilled by a single,
        narrowly scoped funding key the controller designates — admitted to the balance
        setters and nothing else, every designation on the public tape — so the key that
        can upgrade the exchange is never one a bot process holds.</li>
        <li><b>Light mode.</b> A sun/moon toggle at the top right of the header switches the
        exchange to a light theme. The choice is remembered per browser; until you pick, the
        site follows your system's dark/light preference. Charts, the order book and the
        liquidation map re-colour with it, and the charts keep their visible range and
        crosshair across a toggle.</li>
        <li><b>The full-size chart.</b> The ⤢ button at the right of the chart bar opens the
        chart full-screen at the interval you were looking at — drag left to page older
        history, switch intervals, <i>Esc</i> or × closes it. (It was always in the app;
        the button that opened it had been hidden since the first release.)</li>
        <li><b>The chart, fixed in four places.</b> A refresh merges the newest candles into
        the series you are looking at instead of replacing it, so older history you scrolled
        in and your visible range survive the 10-second ticks; the older-history fetch fires
        only when you actually pan to the left edge (every interval switch and overlay open
        used to buy one wasted query); after a pan, switching interval or opening the
        overlay lands exactly at real time again; and the time axis labels read as a year, a
        month, a day, HH:MM or HH:MM:SS depending on how far you zoom.</li>
        <li><b>Keyboard.</b> The chart cell's view menu (<b>Chart | Liquidations | Hide</b>)
        works without a mouse — <i>Tab</i> to it, <i>Enter</i> or the arrow keys open it, the
        arrows move, <i>Enter</i> picks, <i>Esc</i> closes — and the full-size chart keeps
        <i>Tab</i> inside it until you close it.</li>
        <li><b>Keyboard, everywhere a menu drops.</b> The order book's price-grouping menu
        (Markets and Swap), the market selector, the price/stats popups, the signed-in user
        menu and the drop-down selectors under Wallet, Swap and Earn work without a
        mouse the same way — <i>Tab</i> to the control, <i>Enter</i> or the arrows open it,
        the arrows move, <i>Enter</i> picks, <i>Esc</i> closes.</li>
        <li><b>Oracle error popovers.</b> The error popover on a price source now survives the
        5-second stats refresh — it follows its re-drawn trigger, or closes once the source
        has recovered — and follows a scroll or a resize; keyboard focus on the trigger
        survives the refresh too. The token-select buttons announce themselves to screen
        readers ("Sell token: BTC").</li>
        <li><b>Copy buttons copy.</b> The explorer's principal and URL Copy buttons and the
        Copy on an Agent Chat error were silently dead — the page's own permissions policy
        denied it the clipboard. It may write to the clipboard now (and still never read
        it).</li>
        <li><b>Two layout fixes.</b> Account → Deposit fills its pane like the other Account
        panes instead of a narrow capped column, and the glow behind The launch, What is
        MULTI/DEX? and Prizes in these Docs fades out at its edges instead of ending in a
        hard vertical line — in both themes, and without widening the page on a phone.</li>
        <li><b>Hosting and resilience.</b> The site is served by the certified-assets
        static-site recipe: the same security headers as before, and cached files carry an
        ETag so a return visit revalidates them instead of downloading them again. On a
        local venue, a stale or foreign venue cookie no longer breaks the app — it picks its
        own venue row, heals once and names the mismatch in the banner.</li>
        <li><b>Earn: one-tap Max on the LP withdraw field.</b> A Max button beside the field
        fills it with the most you can withdraw right now — the figure the placeholder quoted,
        which you used to retype, commas and all, into a box that rejects them — and is greyed
        out while there is nothing to fill or the submit is paused. The figure is your instant
        maximum less a 0.01% drift allowance, and the hint says so: a request that settles even
        if the vault re-prices between the quote and your settlement, while the tiles above keep
        the exact figure.</li>
        <li><b>Earn: a settled deposit says so.</b> Since the sealed doors a deposit answers with
        a staged request, but the card still read the reply as the old immediate mint and never
        recognised the settlement — twelve polls, then "Your deposit is still staged" under a
        position that had minted seconds earlier. It now reports "Settled: minted N LP at the
        post-request NAV." (or that the request was cancelled, and why), a lingering "still
        staged" line clears itself at the next refresh, and a slow refresh started before
        settlement can no longer repaint LP 0.00 and the stale "Staged deposit" line over your
        minted position — the newest refresh owns the card.</li>
        <li><b>A season seal cancels what is still staged.</b> A deposit or withdrawal still
        staged when the season is sealed (or the exchange reset) is cancelled before the wipe —
        "season sealed before settlement; nothing settled, funds released" in your recent
        outcomes and as a vault row on the tape, the reservation released — rather than
        vanishing with the old world.</li>
        <li><b>The vault's provision is priced on accrued debt.</b> The expected-loss provision
        the Earn card shows (and the NAV deducts) is refreshed on every price update and
        heartbeat; that scan now accrues each margin pool's loans to the instant first, so it
        prices the debt the liquidator would see rather than a figure the interest since the
        last booking had left behind. Your own deposit or withdrawal settling does not accrue,
        so your request never moves the NAV you were quoted at.</li>
        <li><b>Agent Chat on sign-in.</b> Signing in while Agent Chat is the open view shows the
        greeting at once (after a sign-out on the tab, the next sign-in used to leave the pane
        empty until you left and came back), and a page loaded on <code>#ai/agent-chat</code>
        restores your conversation once your principal is known — once, and never someone
        else's. Its leaderboard reads come in dollars: profit, capital and equity are human
        figures like the other money columns it queries (the return stays in basis points), so
        "Who is top of the leaderboard?" no longer prints a $10,000 capital as $10,000,000.</li>
        <li><b>Home, as it went live.</b> The "What is MULTI/DEX?" introduction under the hero
        is gone (the Docs keep the page), the hero's sub-paragraph and the three boxes are
        reworded — the Swap and Markets boxes now with screenshots of the pages, the Earn box
        with a rising-value sketch — the open-source section is headed "Open source and
        verifiable" with the repository link, and "Read how it works" opens Docs → What is
        MULTI/DEX? rather than The launch.</li>
      </ul>

      <h3>1.60 — 7 August 2026</h3>
      <ul>
        <li><b>The order book is bounded everywhere it walks.</b> A taker sweeping many resting
        orders at one price used to pay a cost that grew with the <i>square</i> of the queue — a
        few thousand orders at a single price could push one match past the platform's
        instruction limit. Every price level now keeps its queue in time priority, so the next
        order to fill is found in logarithmic time however deep the level, and every sweep
        carries a hard budget: one match call takes at most <b>256</b> steps — a market order
        that hits it stops there with its unfilled remainder cancelled, as before, while a limit
        order rests the remainder — an all-or-nothing order that would need more than 128
        distinct makers is refused up front rather than half-filled, and a price level holds at
        most <b>512</b> resting orders, a new order at a crowded level being refused rather than
        an old one evicted. The AMM's resting-order sweep and the expiry release pass have
        budgets of their own. Every live book was migrated to the new index in place and
        verified identical afterwards.</li>
        <li><b>Your history no longer goes blank.</b> The exchange keeps a bounded hot tape of
        recent trades, and under the simulated traders' churn a user's older fills leave it
        within days — Spot History, Positions History, Account → Position fills and the Account
        spot table were silently emptying (a trader's Phase II day-one fills were already gone).
        Each view now shows its recent rows at once and merges your <b>archived</b> fills in
        behind them from the public ledger chain: paging is open-ended (<i>N / M+</i>), Next at
        the loaded edge pulls another archive page, the Account table gains a <b>Load older</b>
        button, and archived rows ride dimmed with an <b>ARCHIVE</b> tag. One caveat: the public
        tape carries no sub-account identity, so archived fills of a position that is still open
        read as spot until it closes.</li>
        <li>Open Orders, Spot History, Positions and Positions History now quote prices at the
        <b>same precision as the books beside them</b> — at least five significant digits, with
        the decimals set per row by that row's market (an ICP row to four places, a BTC row to
        whole dollars) — instead of the coarse two-decimal money format that rounded to whole
        dollars above $1,000.</li>
        <li><b>The first community audits of the public repository, and their fixes.</b> Two
        waves of outside reports — about forty findings, each re-verified against the code and
        nearly all confirmed — landed within a week of open-sourcing; the reporters are credited
        in the repository's <code>CONTRIBUTORS.md</code>. What changed: the in-browser
        <b>ledger verifier actually verifies</b> — its certificate check had been failing on
        every call with the failure swallowed, so a fabricated tape would have ticked green —
        and it now fails closed and trusts the platform root key only on the hosts it belongs
        to; a short with health between 1.15 and 1.25 can be <b>closed again</b> instead of
        being held for the liquidation penalty a permitted close would have avoided; a
        dust-sized collateral balance can no longer stall a liquidation and book a
        fully-collateralised position as a loss to the insurance fund, and a liquidation pass
        that runs out of budget mid-walk resumes on the next sweep rather than declaring
        insolvency; no liquidation is decided on a stale mark; unstaking the Insurance Fund is
        priced symmetrically with staking (an exit could redeem more than it had put in); the
        liquidation batch is sliced and guarded by a breaker that backs off instead of retrying
        a failing pass every beat; the price feed's outlier trim uses a robust band that a
        single off-price source cannot inflate — the old band could not reject anything at three
        or four sources, which is how one source a percent adrift froze the mark; the ledger
        archive no longer discards events on a backlog alone; a free sign-in can no longer write
        unbounded permanent state; the dev-only hooks trap on every public posture; the Bridge
        has its own posture and asset allowlist and no longer records a ledger row for an asset
        it rejects; the AI connect page validates where it sends the sign-in delegation it mints
        and shows the lifetime it actually requests; six frontend display defects are fixed in
        which a confidently wrong figure rendered without error (a staker's pending yield shown
        100,000,000× too large, a duplicated trade, a chart drawn continuous across missing
        pages, the units the AI assistant is told); the app ships with a content-security
        policy; and these docs now say plainly that on this anti-mixer venue every deposit and
        withdrawal is a public, attributed record, where they used to claim other users' rows
        never leave the canister. Every fix is pinned by a test that fails on the pre-fix
        tree.</li>
        <li>The first pull requests from outside the core team were adopted. The one you can
        see: Platform → Canisters reports the exchange's <b>real memory ceiling</b>, read back
        from the platform rather than hand-copied from the source — the dashboard had once read
        45% while the exchange sat at 79% of its true limit.</li>
        <li>The footer's version badge is stamped into the page at build time, so it shows from
        first paint and cannot drift from the running build — it had read 1.51 while 1.52 was
        live, and sat blank whenever the app stumbled before stamping it.</li>
      </ul>

      <h3>1.52 — 2 August 2026</h3>
      <ul>
        <li><b>The app keeps itself up to date.</b> Until now a new release only
        reached you if you happened to hard-refresh — a browser will happily serve a cached page
        for days. Each build now publishes its version, and the app checks for a newer one: a tab
        you're using shows a small <b>"A new version is available"</b> card with a Refresh button
        (dismissable — it never reloads while you're mid-trade), while a tab sitting in the
        background quietly refreshes itself, so you come back to a current app without ever seeing
        a prompt. Reloading costs nothing: orders, positions and balances live on-chain, and the
        page you were on is preserved. This is the last release you'll need to refresh by hand.
        Platform → Canisters also now shows the <b>backend's version</b>, so you can see at a glance
        which build the exchange is running.</li>
        <li>Earn: depositing to or withdrawing from the AMM Vault, and staking or unstaking the
        Insurance Fund, now confirm with the same <b>toast</b> every other action uses — the result
        previously appeared as a line at the foot of the page, under the Insurance box, which made
        a vault deposit look like it was reporting on Insurance. The figures behind it are refreshed
        too: <b>Overview, Wallet and the header account value now update immediately</b> after an
        Earn action instead of waiting for the next background poll to notice.</li>
        <li>Header: the account value beside your name is now vertically centred with the nav (it
        sat a few pixels low), and on mobile the account value is shown in the header itself rather
        than only inside the menu. <b>System</b> gains a mobile sub-menu listing its sections —
        Overview, Issues, AMM, Insurance Fund, Treasury, Canisters, Events — matching the way the
        account menu already worked.</li>
      </ul>

      <h3>1.51 — 1 August 2026</h3>
      <ul>
        <li>Fixed a position-reporting bug: unwinding a position in slices could <b>freeze the
        Realized figure and silently rewrite the Entry price</b> to a later fill's price, which
        in turn skewed uPnL — a long entered at 2.07 and reduced at higher prices could show a
        loss while the account was in profit. The cause was a settlement race: placing an order
        briefly blanked the position record's internal size, and an order that was
        <b>immediately marketable</b> (a resting counter-order already at its price) settled
        before the record was repaired, so the engine booked the reducing fill as if it opened a
        fresh position. Orders that rested a while escaped, which is why the first sells of an
        unwind reported correctly and later ones froze. <b>Balances and account value were never
        wrong</b> — the money always moved correctly; only the position panel's Entry/Realized
        (and the episode history derived from them) misreported. The settlement path now keeps
        the running size intact, and a regression test pins the exact race ordering plus the
        accounting laws: entry never moves on a reduce, realized grows by (price − entry) ×
        quantity on every reducing fill, increases blend the entry VWAP, and uPnL always equals
        (mark − entry) × size. One caveat: a position already corrupted before this fix keeps
        its rewritten entry until it is closed — the figures heal on the next fresh
        position.</li>
      </ul>

      <h3>1.50 — 1 August 2026</h3>
      <ul>
        <li><b>Phase II begins.</b> The phase boundary now seals history instead of deleting
        it: <code>resetSeason</code> keeps every Phase I archive canister alive and publicly
        queryable forever, and captures a <b>SeasonRecord</b> — the certified chain head, the
        final event sequence, and the final top-100 standings (usernames and numbers; no
        principals, matching the board's privacy stance). A frozen <b>Provisional Phase I
        Leaders</b> page preserves the standings as they stood, linked from the Leaderboard,
        which also gained the competition's terms (<b>Play for free</b>) and the <b>Phase
        II</b> announcement — MULTI/DEX is now open source.</li>
        <li>The liquidation map is now <b>exact</b>. The k-anonymous band-merging introduced in
        1.35 turned out to protect nobody: the public ledger already reconstructs every
        position's liquidation price precisely (proof-of-reserves requires it), so blurring the
        map only handicapped players who don't fold the tape — an asymmetry favouring the
        sophisticated. And liquidations settle off the <b>external oracle price</b>, which no
        amount of trading here can move, so "liquidation hunting" of individuals is structurally
        impossible on this venue. The map now publishes every non-empty 1% band verbatim
        (notionals still rounded to $100); geometry is withheld only where the oracle mark
        itself is untrustworthy. What everyone could compute, everyone now sees.</li>
        <li>The Markets page telemetry bar grew up: <b>24h High/Low</b>, <b>Total Depth</b>
        (every resting bid and ask), <b>Longs</b> and <b>Shorts</b> (open notional per side),
        <b>Long/Short Health</b> (each side merged into one book — collateral ÷ debt, red
        below the 1.25 opening floor, liquidation at 1.15), and <b>Long/Short Liq</b> (distance
        from the mark to each side's nearest liquidation, at the map's 1% precision — signed by
        the direction the mark must move, which follows the book's health slope rather than its
        side, and reading <b>liquidatable</b> when a position is already past maintenance). Stats
        that don't fit fold into a dropdown on the last visible cell — any number of stats can
        join the bar; the single compact dropdown appears only when not even the 24h Change
        fits.</li>
        <li>Honest vault accounting, three ways. The AMM vault's value now counts its <b>loan
        book</b> — lending to leveraged traders moves tokens out of the basket and used to read
        as an instant "loss" (a freshly seeded vault showed −14.4% minutes after the first
        margin trade); System→AMM now shows <b>Lent out</b> explicitly. Insurance penalties
        earned while the vault's cash leg is short are no longer dropped: they accrue as an
        <b>arrears ledger</b>, visible as pending yield to stakers, and settle automatically
        the moment cash recovers. And the insurance fund's share price is pinned against
        small-supply runaway by the same virtual-offset guard the LP vault uses.</li>
        <li>The simulated traders got real: strategy archetypes — market-making, scalping,
        trend-following, mean-reversion, swing, and a deliberately overleveraged degen cohort —
        most trading <b>on margin</b> under a supervisor, so the liquidation machinery and its
        map are exercised continuously. The venue is sized for launch: a <b>$5.125M</b> AMM
        vault and a <b>$144k</b> insurance fund.</li>
        <li>Oracle hardening: <b>Binance</b> and <b>Kraken</b> joined the price feed — eight
        independent sources per asset — and the price circuit breaker now requires a
        confirmation to be an <b>independent reading</b>, so two fetches a second apart can no
        longer confirm each other's jump.</li>
        <li>AI assistant governance: a new <b>Account → AI usage</b> page shows your
        consumption against the per-user limits (now 10/min, 100/hr, 250/day); harmful and
        jailbreak prompts are refused, with repeated attempts earning a 24-hour ban; and the
        AI section asks you to sign in, like Earn and Account.</li>
        <li>Data Explorer: a schema panel summarising the selected canister's entities and
        joins, quick search over any entity, and field tooltips that explain types, keys, enum
        values — and how to chain across edges from the query box.</li>
        <li>Markets polish: first open on desktop now sizes the book column so <b>Order Book
        and Trades sit side by side</b> when the screen allows it (without squeezing the
        telemetry bar); System→Issues flags markets the AMM isn't quoting; mobile menu
        selection and the Earn page's underwriting card render properly on small screens.</li>
      </ul>

      <h3>1.35 — 29 July 2026</h3>
      <ul>
        <li>The liquidation heat surface: the chart cell's new <b>Liquidations</b> view shows
        where the leveraged book liquidates as a time × price field — colour is the notional
        resting at each level, the white trace is the mark walking into (or bouncing off) the
        bright zones. Bands above the mark are shorts, below are longs. Unlike the estimated maps
        on other venues, this is the real book — published only as <b>k-anonymous</b> aggregates:
        bands merge until each holds enough positions to identify nobody, notionals are rounded,
        and thinly-priced markets withhold detail entirely. History is served from a ~4-hour ring
        of 30-second snapshots. See <a href="#docs/margin">Margin trading</a>.</li>
        <li>The chart cell grew a view menu — <b>Chart | Liquidations | Hide</b> — in place of
        the old hide toggle; the choice persists across visits.</li>
        <li>Earn shows LPs what the vault underwrites: open leverage, debt against the borrow
        cap, utilisation, the insurance buffer ahead of the vault, and any below-maintenance
        exposure — the loan book an LP is actually lending to, identifying nobody.</li>
        <li>Privacy hardening: the public trade feeds are <b>de-identified</b> — recent-trade
        and history queries return trades without account attribution (your own fills, with
        fees, are unchanged; the attributed archive tape remains public, which
        proof-of-reserves requires). The owner↔pool index is no longer published, and
        per-account balances and badges answer only to their owner. <b>Bot authors:</b> this is
        a breaking Candid change on <code>getRecentTrades</code> / <code>getAllTrades</code> /
        <code>getTradesSince</code> — apiVersion moved to <b>2.0.0</b> at that release (the
        current apiVersion is <b>6.0.0</b>; <code>getAccessPolicy</code> and
        <code>getMarketSpecs</code> report it live); see the
        <a href="https://github.com/dfinity/public-multidex/blob/HEAD/candid/README.md" target="_blank" rel="noopener noreferrer">API docs</a>.</li>
        <li>Sealed vault LP deposits and withdrawals (<code>depositLp</code> /
        <code>withdrawLp</code> as staged requests, apiVersion 6.0.0) and the removal of the
        protection-window surfaces shipped with <b>1.75</b> — see that entry above.</li>
        <li>Two deep audits ahead of open-sourcing, and their fixes: a deposit-crediting race
        that could double-credit, a registration gap in the AI deposit path, an AMM sweep that
        could overfill against a stale quantity, sealed archive segments that could run out of
        fuel after handover, maker-affordability in fill simulation, a non-finite price guard in
        the oracle, and stricter output-escaping throughout the UI.</li>
        <li>Operational settings now survive upgrades (AMM auto-inventory, the arbitrageur's
        hourly cap, the refuel cooldown), and upgrades no longer rebuild the order-book indexes —
        on a large book that rebuild risked exceeding the upgrade instruction budget.</li>
      </ul>

      <h3>1.30 — 23 July 2026</h3>
      <ul>
        <li>Enhanced ledger handling. An archive segment hit its storage allotment mid-write and
        the shipper stalled — no history was lost (unshipped events buffer inside the exchange and
        re-ship), and the fix hardens the whole path: capacity is now checked on <i>every</i>
        write, a full segment acknowledges exactly what it stored and hands over cleanly, segments
        seal by <b>bytes</b> as well as event count, and per-segment capacity is doubled to 8 GiB.
        The buffered backlog — over three million events — drained back onto the tape within hours.
        The sealed-chain design then proved itself in production for the first time: the first
        archive sealed at its ten-million-event cap and the tape rolled to a pre-spawned successor
        with every hash link intact across the canister boundary. See
        <a href="#docs/ledger">The ledger</a>.</li>
        <li>Place Order sizes with a slider — drag anywhere from 0–100% of what's available
        instead of four fixed buttons. The thumb follows hand-typed quantities both ways, sizes
        follow each market's own decimal convention (a $65,905 asset sizes in 5 decimals, a $2
        asset in 1), the quantity resets when switching markets, and the margin preview keeps
        every figure on one line however large it grows.</li>
        <li>Status → Treasury tells the truth about fuel: cycles bought are read from the fuel
        meter itself, and treasury payouts (vault restitution, prize funding) are no longer
        mislabeled as "converted to fuel".</li>
        <li>Resting-order caps write themselves to the ledger: when the book evicts stale orders
        at the cap, edge and roll-up events land on the tape and the owner gets a private
        notice.</li>
        <li>Off-ladder fills log the observable fact — how stale the reference price was —
        instead of guessing at a cause.</li>
      </ul>

      <h3>1.29 — 22 July 2026</h3>
      <ul>
        <li>Deposits admit by reservation: the play-mode allowance is debited and reserved the
        moment a deposit is admitted, so deposits can no longer be queued past the limit and
        strand mid-claim. The Deposit page walks the steps in order, previews what a deposit
        would leave of the allowance, and clears the amount after each one.</li>
        <li>Oracle robustness: one bad price source can no longer freeze a market — outliers are
        trimmed before <i>both</i> the aggregate price and the quality gate that judges it. And
        trades are stamped at settlement, so "6 seconds ago" means six seconds ago.</li>
        <li>AI assistant replies keep their workings (the intermediate tables) behind a link that
        opens them on demand.</li>
        <li>The AMM is reworked so it can no longer be drained. The old quoting logic tried to
        keep its inventory in balance with out-of-the-money trades — when short, it would bid
        above the reference price to refill, and bots cycled that money pump. Quotes now form a
        curve around the oracle mark that bids and asks never cross (a round trip through the
        AMM always pays the vault the spread), running low makes further depletion more
        expensive, recovery is passive, and half of every trading fee now accrues to the LP
        vault. See <a href="#docs/liquidity">AMM &amp; liquidity</a>.</li>
        <li>The venue runs its own <a href="#docs/arbitrage">arbitrageur</a>. Synthetic markets
        have no cross-venue arb, so a dedicated canister trades the mispriced side of the book
        back to the oracle mark through the ordinary fee-paying taker path — pinning the venue
        price to the mark, paid for by whoever pushed it off.</li>
        <li>AMM vault restitution: after the pre-drain-proofing losses, a par repair added funds
        to the vault without minting LP shares, so the recovery accrued to existing LP holders —
        value per LP restored from 0.748 to 1.000, with every step attributed on the public
        ledger.</li>
        <li>Positions History paginates on the Account card and the Markets activity panel —
        older history is pageable instead of silently capped at 200 rows.</li>
        <li>Archive fuel: each archive canister's freezing limit is tracked individually and the
        whole chain is exposed.</li>
        <li>Docs: this change log and <a href="#docs/prizes">Prizes &amp; bounties</a> join the
        new Community section.</li>
      </ul>

      <h3>1.28 — 11 July 2026</h3>
      <ul>
        <li>Clearer names across the app: Stats → Status, Intelli → Intelligence, and the old
        Status pane is now Issues.</li>
        <li>Docs open on <a href="#docs/launch">The launch</a>.</li>
        <li>Status notices and swap fixes, shipped to the subnet.</li>
      </ul>

      <h3>1.27 — 11 July 2026</h3>
      <ul>
        <li>Deposit-page UX overhaul.</li>
      </ul>

      <h3>1.18 – 1.22 — 10 July 2026</h3>
      <ul>
        <li>AI assistant: Anthropic provider joins Gemini, and replies are grounded in venue
        semantics — staged matching, oracle-settled liquidations, fee levels, play-mode funding.</li>
        <li>Swap: the rate-graph chrome appears immediately while candles load.</li>
        <li>Mobile polish (drawer, ledger tape) and self-healing simulation bots.</li>
      </ul>

      <h3>1.17 — the public snapshot</h3>
      <ul>
        <li>The exchange's code goes public at
        <a href="https://github.com/dfinity/public-multidex" target="_blank" rel="noopener noreferrer">github.com/dfinity/public-multidex</a>.</li>
      </ul>

      <p class="docs-dim">Curated highlights, newest first. The complete, commit-level history is
      public in the <a href="https://github.com/dfinity/public-multidex" target="_blank"
      rel="noopener noreferrer">repository</a>.</p>
    `,
  },
];

// Quick slug → page lookup (also used to validate #docs/<slug> routes).
const BY_SLUG = new Map(DOCS_PAGES.map((p) => [p.slug, p]));
export function docsPage(slug) {
  return BY_SLUG.get(slug) || null;
}
