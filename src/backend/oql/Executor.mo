/// Query executor. Fixed pipeline:
///
///     where_ → (groupBy + aggregate) → orderBy → offset → limit → select
///
/// Operates over `Predicate.Row` values produced by `entity.rows()`,
/// wrapped with edge-aware lookup: a dotted path (`["dept","name"]`)
/// whose head is a declared `#edge` field traverses to the target entity
/// via a per-query primary-key hash index (left-join semantics). Returns
/// a typed `Result` for Candid serialisation on the way out.

import Array     "mo:core/Array";
import Bool      "mo:core/Bool";
import Float     "mo:core/Float";
import Int       "mo:core/Int";
import Iter      "mo:core/Iter";
import List      "mo:core/List";
import Map       "mo:core/Map";
import Nat       "mo:core/Nat";
import Option    "mo:core/Option";
import Order     "mo:core/Order";
import Principal "mo:core/Principal";
import Runtime   "mo:core/Runtime";
import Text      "mo:core/Text";
import Auth      "Auth";
import Entity    "Entity";
import Predicate "Predicate";
import Query     "Query";
import Registry  "Registry";
import Schema    "Schema";
import Types     "Types";

module {

  type Value = Types.Value;
  type Path  = Types.Path;
  type Row   = Predicate.Row;

  public type Cell = { name : Text; value : Value };

  public type Result = {
    rows    : [[Cell]];
    hasMore : Bool;
  };

  /// The per-entity read decision for one query. Resolving access per
  /// `Entity.Decl` (rather than a single subject) is what lets entities
  /// carry different authorization levels: the mixin supplies
  /// `func d = Auth.resolve(d.auth, caller)`. There is deliberately no
  /// auth-bypassing convenience entry point — every run goes through
  /// `runWith` with an explicit resolver, so authorization can never be
  /// skipped by accident.
  public type Access = Entity.Decl -> Auth.Access;

  /// The query subject an `Access` scopes to: a concrete principal for
  /// `#scoped`, `null` (unrestricted) otherwise.
  func subjectOf(a : Auth.Access) : ?Principal =
    switch a { case (#scoped p) { ?p }; case _ { null } };

  /// Authorization-aware run. `access` decides, per entity, whether the
  /// caller may read it and at what scope. A denied start entity traps; a
  /// denied join target contributes an empty index, so traversal into it is
  /// a left-join null (no leak). Scoped entities — start AND join targets —
  /// yield only the rows their owner check admits for the resolved subject.
  public func runWith(r : Registry.Registry, q : Query.Query, access : Access) : Result {
    let entity = switch (Registry.lookup(r, q.start)) {
      case null { Runtime.trap("OQL: unknown entity '" # q.start # "'") };
      case (?d) { d };
    };

    let startSubject = switch (access(entity)) {
      case (#deny) { Runtime.trap("OQL: caller not allowed to read '" # entity.name # "'") };
      case (a) { subjectOf(a) };
    };

    // Index-served aggregate: answer count / min / max / group-count straight
    // off the index stats, with no scan. Same gate as the planner (unrestricted
    // + served); exact cases only, so the result equals a scan of the query.
    switch (startSubject, entity.served) {
      case (null, ?s) {
        switch (aggPlan(s, q)) {
          case (?(rows, cols)) { return finishRows(rows, ?cols, false, q, entity.fields) };
          case null {};
        };
      };
      case _ {};
    };

    let hops = collectHops(r, entity, q, access);

    // Planner: for an unrestricted read, try to serve the row source from the
    // entity's maintained index instead of scanning. `served` rows bypass the
    // owner/view scoping `makeRows` applies, so we only plan when the subject
    // is `null` (unrestricted) — scoped reads always scan. A plan yields a
    // SUPERSET (the residual `where_` still runs below); `ordered` says the
    // stream already satisfies `orderBy`, so the sort is skipped and the scan
    // cap applies even with `orderBy` present.
    let plan : ?{ rows : Iter.Iter<Row>; ordered : Bool } =
      switch (startSubject, entity.served) {
        case (null, ?s) {
          switch (planServed(s, q)) {
            case (?p) { ?p };                              // own-column filter/orderBy
            case null { planJoin(hops, r, entity, s, q, access) }; // else a semi-join on an edge filter
          }
        };
        case _ { null };
      };
    let planOrdered = switch plan { case (?pl) pl.ordered; case null false };

    // With no ordering or aggregation, the result is just the first
    // `offset+limit` survivors in scan order — so stop scanning there instead
    // of materialising the whole table (+1 to still detect `hasMore`). An
    // index-ordered plan is already in `orderBy` order, so the same early stop
    // applies even when `orderBy` is present. With no limit, or when
    // aggregation is present, every row is needed. The window/`hasMore` logic
    // below is unchanged and yields identical results.
    let scanCap : ?Nat =
      if ((q.orderBy.size() == 0 or planOrdered) and q.aggregate.size() == 0 and q.groupBy.size() == 0) {
        switch (q.limit) { case (?lim) { ?(q.offset.get(0) + lim + 1) }; case null { null } };
      } else { null };

    // Every dotted path is validated into `hops.edges` (collectHops traps on
    // an invalid hop), so an empty `edges` means the query never traverses —
    // `wrapRow` would be a pure pass-through. Skip it to save a per-row closure
    // allocation on the common join-free query.
    let hasEdges = hops.edges.size() > 0;
    let baseRows = switch plan { case (?pl) pl.rows; case null entity.rows(startSubject) };
    let kept = filter(
      if (hasEdges) { baseRows.map(func (row : Row) : Row = wrapRow(row, entity.name, hops)) }
      else          { baseRows },
      q.where_,
      scanCap,
    );

    // Aggregation stage: when grouping or aggregates are requested, collapse
    // the filtered rows into grouped rows; `defaultCols` then drives the
    // default projection (group keys + aggregate columns) instead of the
    // entity's own fields. Grouped rows are wrapped too, so an FK group key
    // still traverses (`groupBy: ["dept"], select: ["dept.name"]`).
    let (workRows, defaultCols) : ([Row], ?[Text]) =
      if (q.aggregate.size() == 0 and q.groupBy.size() == 0) { (kept, null) }
      else {
        let g = aggregateRows(kept, q.groupBy, q.aggregate);
        let gr = if (hasEdges) { g.rows.map(func (row : Row) : Row = wrapRow(row, entity.name, hops)) }
                 else          { g.rows };
        (gr, ?g.columns)
      };

    finishRows(workRows, defaultCols, planOrdered, q, entity.fields)
  };

  /// The tail shared by the scan pipeline and the index-served aggregate path:
  /// order → offset/limit window → project. `planOrdered` skips the sort when
  /// the rows already arrive in `orderBy` order.
  func finishRows(workRows : [Row], defaultCols : ?[Text], planOrdered : Bool, q : Query.Query, fields : [Schema.FieldDecl]) : Result {
    let sorted = if (q.orderBy.size() == 0 or planOrdered) { workRows }
                 else { sortByKeys(workRows, q.orderBy) };

    let offset  = q.offset.get(0);
    let limit   = q.limit.get(sorted.size());
    let endIdx  = if (offset > sorted.size()) { sorted.size() }
                  else { Nat.min(offset + limit, sorted.size()) };
    let window  = sorted.sliceToArray(offset, endIdx);
    let hasMore = endIdx < sorted.size();

    let paths = projectionPaths(q.select, fields, defaultCols);
    // Column names + flat slots are identical across rows — resolve them once,
    // not per cell per row.
    let names = paths.map(Types.pathToText);
    let slots = resolveSlots(if (window.size() == 0) null else ?window[0], paths);
    let rows  = window.map(func (row : Row) : [Cell] = project(row, paths, names, slots));

    { rows; hasMore }
  };

  /// Answer a single aggregate from the index's stats — no row scan — as the
  /// synthetic aggregated rows + their column names (the shape `aggregateRows`
  /// produces), or `null` to fall back to the scan. Served ONLY when the whole
  /// query is expressible as an exact stat (no residual `where`), so the answer
  /// equals a scan's:
  ///   - `groupBy [col]` + `count(*)`, no `where` → the per-value histogram;
  ///   - `count(*)` with no `where` → the row count; with a lone `#eq` on an
  ///     indexed column → that posting's size;
  ///   - `min(col)` / `max(col)`, no `where`, `col` `#ordered`-indexed → the
  ///     extreme non-null value.
  /// Everything else (sum/avg, multi-aggregate, residual predicates, non-indexed
  /// or `#hash` min/max) returns `null`. `orderBy`/`limit`/`select` are applied
  /// by `finishRows` over the synthetic rows, exactly as for the scan path.
  // ── DEAD IN THIS TREE (W6-08): aggPlan/planServed/planJoin are reachable
  // only through a `withServed` registration, whose sole call site is
  // oql/IndexedMap.mo — unused outside oql/. Every live query full-scans.
  // Four latent defects are documented on these paths (#21 pt 2, #39 —
  // including an authorisation misdirect via `__N` column-name collision).
  // Do NOT enable this planner without fixing them: the gating note lives at
  // Entity.withServed and docs/tasks/W6-08-latent-oql-watch-item.md.
  func aggPlan(s : Entity.Served, q : Query.Query) : ?([Row], [Text]) {
    if (q.aggregate.size() != 1) return null;
    let st = switch (s.stats) { case (?x) { x }; case null { return null } };
    let a = q.aggregate[0];
    let name = aggName(a);

    // groupBy <indexed col> + count(*), no where → the histogram.
    if (q.groupBy.size() == 1 and q.where_ == null and a.fn == #count and a.field == null and q.groupBy[0].size() == 1) {
      let col = q.groupBy[0][0];
      switch (st.groupCount(col)) {
        case (?pairs) {
          let out = List.empty<Row>();
          for ((v, n) in pairs) { out.add(rowOf([(col, v), (name, #nat(n))])) };
          return ?(out.toArray(), [col, name]);
        };
        case null { return null };
      };
    };

    // no groupBy → a single scalar aggregate row.
    if (q.groupBy.size() == 0) {
      switch (a.fn, a.field) {
        case (#count, null) {
          let cs = conjuncts(q.where_);
          if (cs.size() == 0) { return ?([rowOf([(name, #nat(st.total()))])], [name]) };
          if (cs.size() == 1) {
            switch (cs[0]) {
              case (#eq(p, v)) {
                if (p.size() == 1) {
                  switch (st.count(p[0], v)) { case (?n) { return ?([rowOf([(name, #nat(n))])], [name]) }; case null {} };
                };
              };
              case _ {};
            };
          };
          return null;
        };
        case ((#min or #max), ?p) {
          if (q.where_ == null and p.size() == 1 and s.kindOf(p[0]) == ?#ordered) {
            let v = switch (a.fn) { case (#min) { st.min(p[0]) }; case _ { st.max(p[0]) } };
            return ?([rowOf([(name, Option.get<Value>(v, #null_))])], [name]);
          };
          return null;
        };
        case _ { return null };
      };
    };
    null
  };

  // ── Planner ───────────────────────────────────────────────────────────────

  /// Pick an index access for `q` against the entity's `served` capability, or
  /// `null` to scan. Every plan yields a SUPERSET; the executor re-applies the
  /// full `where_` as a residual filter, so a plan only ever changes speed. Row
  /// order follows SQL semantics: an explicit `orderBy` is honoured (the
  /// executor sorts the superset unless the plan is already in that order), and
  /// without one the result order — including which rows a bare `limit` keeps —
  /// is unspecified, which is what lets an unordered range/`#in_` stream serve.
  ///
  /// Shapes, in priority order (a heuristic, not a cost model):
  ///   1. An equality PREFIX over a declared composite plus something pushed
  ///      onto the NEXT column — a range bound, a single-field `orderBy`
  ///      (direction from the clause, `ordered = true` so top-N applies), a
  ///      second pinned column, or a full-length prefix → one contiguous
  ///      composite seek, the narrowest superset (every prefix column pins a
  ///      key element).
  ///   2. `#eq` on an indexed column (through top-level `#and_`) → point probe:
  ///      the narrowest single-column superset, posting order = scan order.
  ///   3. Single-field `orderBy` on an `#ordered` column (no grouping /
  ///      aggregation) → ordered range in the requested direction, with any
  ///      `where_` bounds on that column pushed into the seek. `ordered = true`
  ///      lets the executor skip the sort and stop at `offset+limit` (top-N).
  ///   4. `#in_` on an indexed column → the union of its point probes.
  ///   5. A range (`#lt`/`#le`/`#gt`/`#ge`) on an indexed column → the bounded
  ///      range (inclusive; strict bounds handled by the residual filter).
  ///   6. A bare one-column composite prefix (`#eq` on the leading column of a
  ///      composite, nothing pushed further) — last, because a single-column
  ///      shape serves the same constraint from a narrower posting; this only
  ///      routes what would otherwise scan.
  ///
  /// Only `#eq`/`#in_`/range constraints reachable through top-level `#and_`
  /// drive — the same predicate under `#or_`/`#not_` is not a superset of the
  /// query's matches. Everything else scans.
  func planServed(s : Entity.Served, q : Query.Query) : ?{ rows : Iter.Iter<Row>; ordered : Bool } {
    let cs = conjuncts(q.where_);
    let comp = switch (s.composites) { case (?c) { planComposite(c, cs, q) }; case null { null } };
    switch comp {
      case (?p) { if (p.pushed) return ?{ rows = p.rows; ordered = p.ordered } };
      case null {};
    };
    switch (findEq(cs, s)) {
      case (?(col, v)) { return ?{ rows = s.point(col, v); ordered = false } };
      case null {};
    };
    if (q.aggregate.size() == 0 and q.groupBy.size() == 0
        and q.orderBy.size() == 1 and q.orderBy[0].field.size() == 1) {
      let col = q.orderBy[0].field[0];
      if (s.kindOf(col) == ?#ordered) {
        let (lo, hi) = boundsFor(cs, col);
        return ?{ rows = s.range(col, lo, hi, q.orderBy[0].dir); ordered = true };
      };
    };
    switch (findIn(cs, s)) {
      case (?(col, vs)) { return ?{ rows = s.points(col, vs); ordered = false } };
      case null {};
    };
    switch (findRangeCol(cs, s)) {
      case (?col) { let (lo, hi) = boundsFor(cs, col); return ?{ rows = s.range(col, lo, hi, #asc); ordered = false } };
      case null {};
    };
    switch comp {
      case (?p) { return ?{ rows = p.rows; ordered = p.ordered } };
      case null {};
    };
    null
  };

  /// Composite plan for one query. Per declared composite, the longest
  /// equality prefix the top-level conjuncts pin (in the DECLARED column
  /// order — an `#eq` on a later column without its prefix cannot seek, the
  /// gate that keeps issue #45's silent under-fetch impossible), plus at most
  /// one range / single-field `orderBy` pushed onto the NEXT column.
  /// `pushed` reports whether the match drives more than a bare single-column
  /// `#eq` would — that is what ranks it against the single-column shapes.
  /// The first declaration with a pushed match wins; a bare one-column prefix
  /// is remembered as the last-resort route. No prefix → no composite plan.
  /// The `orderBy` claim is sound because the prefix is pinned by equality:
  /// within it, composite key order IS next-column order.
  func planComposite(c : Entity.ServedComposite, cs : [Predicate.Predicate], q : Query.Query)
    : ?{ rows : Iter.Iter<Row>; ordered : Bool; pushed : Bool } {
    var bare : ?{ rows : Iter.Iter<Row>; ordered : Bool; pushed : Bool } = null;
    for (cols in c.decls().values()) {
      let prefix = List.empty<Value>();
      label pin for (col in cols.values()) {
        switch (eqOn(cs, col)) { case (?v) { prefix.add(v) }; case null { break pin } };
      };
      let k = prefix.size();
      if (k == cols.size() and k > 0) {
        return ?{ rows = c.range(cols, prefix.toArray(), null, null, #asc); ordered = false; pushed = true };
      };
      if (k > 0) {
        let next = cols[k];
        let (lo, hi) = boundsFor(cs, next);
        let ob = q.aggregate.size() == 0 and q.groupBy.size() == 0
          and q.orderBy.size() == 1 and q.orderBy[0].field.size() == 1 and q.orderBy[0].field[0] == next;
        if (ob) {
          return ?{ rows = c.range(cols, prefix.toArray(), lo, hi, q.orderBy[0].dir); ordered = true; pushed = true };
        };
        if (lo != null or hi != null or k > 1) {
          return ?{ rows = c.range(cols, prefix.toArray(), lo, hi, #asc); ordered = false; pushed = true };
        };
        switch bare {
          case null { bare := ?{ rows = c.range(cols, prefix.toArray(), null, null, #asc); ordered = false; pushed = false } };
          case _ {};
        };
      };
    };
    bare
  };

  /// The first `#eq` on exactly the single-segment column `col`.
  func eqOn(cs : [Predicate.Predicate], col : Text) : ?Value {
    for (p in cs.values()) {
      switch p { case (#eq(path, v)) { if (path.size() == 1 and path[0] == col) return ?v }; case _ {} };
    };
    null
  };

  /// Flatten a where clause's top-level conjunction into its leaf predicates —
  /// the sargable candidates a plan may drive on. Only `#and_` is transparent: a
  /// leaf under `#or_`/`#not_` is not a superset of the query's matches, so it
  /// never surfaces here. Computed once per plan; the finders below scan the
  /// flat list rather than each re-walking the tree.
  func conjuncts(where_ : ?Predicate.Predicate) : [Predicate.Predicate] {
    let acc = List.empty<Predicate.Predicate>();
    func go(p : Predicate.Predicate) = switch p {
      case (#and_ ps) { for (x in ps.values()) { go(x) } };
      case _          { acc.add(p) };
    };
    switch where_ { case (?p) { go(p) }; case null {} };
    acc.toArray()
  };

  /// Join-aware plan: an edge-path filter `edge.col <op> v` (a constraint on a
  /// column of the *target* entity, where `<op>` is `=`/`in`/a range) becomes a
  /// semi-join. Resolve the target rows the constraint admits, take their primary
  /// keys, and drive the start through an `#in_` on the foreign-key column's
  /// index — reusing `s.points`. So a filter behind an edge is served by the FK
  /// index instead of scanning every start row.
  ///
  /// Requires the FK column (`edge`) to be a served index on the start and a
  /// declared edge. The target's matches come from its own index when the
  /// constraint is an `#eq` on a served target column (a point probe), else a
  /// scan of the target — cheap for the usual dimension table. Complete for these
  /// positive filters: a start row with a dangling FK has `edge.col = null`,
  /// which none of them admit, so dropping it is correct. A denied target admits
  /// nothing (empty `#in_`), matching the left-join-to-null the residual produces.
  func planJoin(hops : Hops, r : Registry.Registry, start : Entity.Decl, s : Entity.Served, q : Query.Query, access : Access)
    : ?{ rows : Iter.Iter<Row>; ordered : Bool } {
    switch (findEdgeFilter(conjuncts(q.where_), s, start)) {
      case null { null };
      case (?(edge, targetPred)) {
        let targetName = switch (edgeTarget(start, edge)) { case (?t) { t }; case null { return null } };
        let target = switch (Registry.lookup(r, targetName)) { case (?d) { d }; case null { return null } };
        let tSubject = switch (access(target)) {
          case (#deny) { return ?{ rows = s.points(edge, []); ordered = false } };  // can't read target → no matches
          case (a)     { subjectOf(a) };
        };
        // Primary keys of the targets the (rewritten) constraint admits.
        let pks = List.empty<Value>();
        switch (tSubject, target.served, targetPred) {
          // `#eq` on a served target column → narrow via the target's own point index.
          case (null, ?ts, #eq(path, v)) if (path.size() == 1 and ts.kindOf(path[0]) != null) {
            for (trow in ts.point(path[0], v)) {
              if (Predicate.eval(targetPred, trow)) {
                switch (trow.get([target.primaryKey])) { case (?pk) { pks.add(pk) }; case null {} };
              };
            };
          };
          // Otherwise reuse the PK index `collectHops` already materialised for
          // this target (rows built once, and the key IS the primary key), so the
          // target isn't scanned a second time. Fall back to a fresh scan only if
          // no such index exists (the edge filter is always a queried path, so it
          // normally does).
          case _ {
            switch (hops.indexes.get(Text.compare, targetName)) {
              case (?idx) { for ((pk, trow) in idx.entries()) { if (Predicate.eval(targetPred, trow)) { pks.add(pk) } } };
              case null {
                for (trow in target.rows(tSubject)) {
                  if (Predicate.eval(targetPred, trow)) {
                    switch (trow.get([target.primaryKey])) { case (?pk) { pks.add(pk) }; case null {} };
                  };
                };
              };
            };
          };
        };
        ?{ rows = s.points(edge, pks.toArray()); ordered = false }
      };
    };
  };

  /// The target entity of a declared `#edge` field `name` on `start`, if any.
  func edgeTarget(start : Entity.Decl, name : Text) : ?Text {
    for (f in start.fields.values()) {
      if (f.name == name) { return (switch (f.role) { case (#edge e) { ?e.to }; case _ { null } }) };
    };
    null
  };

  /// The first `edge.col <op> v` (two-segment path, `<op>` ∈ `=`/`in`/range)
  /// through top-level `#and_` whose head is both a served index and a declared
  /// edge of `start`. Returns the FK column and the constraint rewritten onto the
  /// target column (path `[col]`) so it can be `Predicate.eval`'d on target rows.
  func findEdgeFilter(cs : [Predicate.Predicate], s : Entity.Served, start : Entity.Decl)
    : ?(Text, Predicate.Predicate) {
    // (edge, col) when `path` is a two-segment `edge.col` on a served FK edge.
    func split(path : Types.Path) : ?(Text, Text) =
      if (path.size() == 2 and s.kindOf(path[0]) != null and edgeTarget(start, path[0]) != null)
        ?(path[0], path[1]) else null;
    for (p in cs.values()) {
      let m : ?(Text, Predicate.Predicate) = switch p {
        case (#eq(path, v))  { switch (split(path)) { case (?(e, c)) { ?(e, #eq([c], v)) };  case null { null } } };
        case (#in_(path, v)) { switch (split(path)) { case (?(e, c)) { ?(e, #in_([c], v)) }; case null { null } } };
        case (#lt(path, v))  { switch (split(path)) { case (?(e, c)) { ?(e, #lt([c], v)) };  case null { null } } };
        case (#le(path, v))  { switch (split(path)) { case (?(e, c)) { ?(e, #le([c], v)) };  case null { null } } };
        case (#gt(path, v))  { switch (split(path)) { case (?(e, c)) { ?(e, #gt([c], v)) };  case null { null } } };
        case (#ge(path, v))  { switch (split(path)) { case (?(e, c)) { ?(e, #ge([c], v)) };  case null { null } } };
        case _ { null };
      };
      switch m { case (?r) { return ?r }; case null {} };
    };
    null
  };

  /// The first `#eq` on an indexed single-segment column.
  func findEq(cs : [Predicate.Predicate], s : Entity.Served) : ?(Text, Value) {
    for (p in cs.values()) {
      switch p { case (#eq(path, v)) { if (path.size() == 1 and s.kindOf(path[0]) != null) return ?(path[0], v) }; case _ {} };
    };
    null
  };

  /// The first `#in_` on an indexed single-segment column.
  func findIn(cs : [Predicate.Predicate], s : Entity.Served) : ?(Text, [Value]) {
    for (p in cs.values()) {
      switch p { case (#in_(path, vs)) { if (path.size() == 1 and s.kindOf(path[0]) != null) return ?(path[0], vs) }; case _ {} };
    };
    null
  };

  /// The first indexed single-segment column carrying a range bound.
  func findRangeCol(cs : [Predicate.Predicate], s : Entity.Served) : ?Text {
    for (p in cs.values()) {
      switch p {
        case (#lt(path, _) or #le(path, _) or #gt(path, _) or #ge(path, _)) {
          if (path.size() == 1 and s.kindOf(path[0]) != null) return ?path[0];
        };
        case _ {};
      };
    };
    null
  };

  /// Inclusive `[lo, hi]` bounds for `col` gathered from the conjuncts
  /// (`#gt`/`#ge` → `lo`, `#lt`/`#le` → `hi`; strictness is left to the residual
  /// filter). A missing bound stays open; looser bounds only widen the superset,
  /// never drop a match.
  func boundsFor(cs : [Predicate.Predicate], col : Text) : (?Value, ?Value) {
    var lo : ?Value = null;
    var hi : ?Value = null;
    for (p in cs.values()) {
      switch p {
        case (#gt(path, v) or #ge(path, v)) { if (path.size() == 1 and path[0] == col and lo == null) lo := ?v };
        case (#lt(path, v) or #le(path, v)) { if (path.size() == 1 and path[0] == col and hi == null) hi := ?v };
        case _ {};
      };
    };
    (lo, hi)
  };

  // ── Edge traversal ──────────────────────────────────────────────────────

  /// Validated hops + per-target PK indexes for one query.
  type Hops = {
    edges   : Map.Map<Text, Text>;                // "<entity>\u{1f}<edge>" -> target entity
    indexes : Map.Map<Text, Map.Map<Value, Row>>;  // target entity -> PK index (Value-keyed)
  };

  /// Collect every dotted path in the query, validate each hop against the
  /// schema, and build one PK index per distinct target entity. Each
  /// target's index is built at its OWN resolved access: a denied target
  /// gets an empty index (every traversal into it is a left-join null), a
  /// scoped target only its caller-owned rows.
  func collectHops(r : Registry.Registry, start : Entity.Decl, q : Query.Query, access : Access) : Hops {
    let edges  = Map.empty<Text, Text>();
    let seen   = Map.empty<Text, ()>();
    let needed = List.empty<Entity.Decl>();

    for (path in queryPaths(q).values()) {
      if (path.size() > 5) {
        Runtime.trap("OQL: path '" # Types.pathToText(path) # "' exceeds 4 hops");
      };
      var entity = start;
      var i = 0;
      while (i + 1 < path.size()) {
        let target = validateHop(r, entity, path[i]);
        edges.add(Text.compare, entity.name # "\u{1f}" # path[i], target.name);
        if (seen.get(Text.compare, target.name) == null) {
          seen.add(Text.compare, target.name, ());
          needed.add(target);
        };
        entity := target;
        i += 1;
      };
    };

    let indexes = Map.empty<Text, Map.Map<Value, Row>>();
    for (decl in needed.values()) {
      let idx = switch (access(decl)) {
        case (#deny) { Map.empty<Value, Row>() };  // denied target -> left-join null
        case (a)     { buildIndex(decl, subjectOf(a)) };
      };
      indexes.add(Text.compare, decl.name, idx);
    };
    { edges; indexes }
  };

  /// Every field path referenced anywhere in the query.
  func queryPaths(q : Query.Query) : [Path] {
    let acc = List.empty<Path>();
    func fromPred(p : Predicate.Predicate) {
      switch p {
        case (#eq(path, _) or #ne(path, _) or #lt(path, _) or #le(path, _)
           or #gt(path, _) or #ge(path, _) or #contains(path, _)
           or #icontains(path, _) or #startsWith(path, _) or #endsWith(path, _)) {
          acc.add(path)
        };
        case (#in_(path, _)) { acc.add(path) };
        case (#and_ ps) { for (x in ps.values()) fromPred(x) };
        case (#or_  ps) { for (x in ps.values()) fromPred(x) };
        case (#not_ x)  { fromPred(x) };
      };
    };
    switch (q.where_) { case (?p) { fromPred(p) }; case null {} };
    for (ob in q.orderBy.values()) acc.add(ob.field);
    for (g in q.groupBy.values()) acc.add(g);
    for (a in q.aggregate.values()) {
      switch (a.field) { case (?p) { acc.add(p) }; case null {} };
    };
    switch (q.select) {
      case (?ps) { for (p in ps.values()) acc.add(p) };
      case null {};
    };
    acc.toArray()
  };

  /// One hop: `edge` on `entity` must be a declared `#edge` whose target is
  /// registered, exposes its primary key, and is join-compatible. A target
  /// with no seed (`fields == []`) skips the PK/type checks — its index is
  /// empty and every traversal is a left-join null.
  func validateHop(r : Registry.Registry, entity : Entity.Decl, edge : Text) : Entity.Decl {
    let fld = switch (entity.fields.find(func f = f.name == edge)) {
      case (?f) { f };
      case null { Runtime.trap("OQL: '" # edge # "' is not an edge of '" # entity.name # "'") };
    };
    let to = switch (fld.role) {
      case (#edge e) { e.to };
      case _ { Runtime.trap("OQL: '" # edge # "' is not an edge of '" # entity.name # "'") };
    };
    let target = switch (Registry.lookup(r, to)) {
      case (?t) { t };
      case null {
        Runtime.trap("OQL: edge '" # entity.name # "." # edge
          # "' targets unknown entity '" # to # "'")
      };
    };
    if (target.fields.size() > 0) {
      let pk = switch (target.fields.find(func f = f.name == target.primaryKey)) {
        case (?f) { f };
        case null {
          Runtime.trap("OQL: cannot expand into '" # target.name # "' — primary key '"
            # target.primaryKey # "' is hidden or absent")
        };
      };
      if (not joinable(fld.typeName, pk.typeName)) {
        Runtime.trap("OQL: cannot join '" # entity.name # "." # edge # "' ("
          # fld.typeName # ") to '" # target.name # "." # target.primaryKey
          # "' (" # pk.typeName # ")");
      };
    };
    target
  };

  /// Exact, stable equality only: Text, Bool, and Nat/Int (bridged like
  /// `compare`). Float is rejected. "Null" means the seed row's value was
  /// null — type unknown, defer to runtime where `joinKey` stays total.
  func joinable(fk : Text, pk : Text) : Bool {
    func num(t : Text) : Bool = t == "Nat" or t == "Int";
    if (fk == "Null" or pk == "Null") return true;
    (fk == "Text" and pk == "Text") or (fk == "Bool" and pk == "Bool")
      or (num(fk) and num(pk))
  };

  /// Whether a Value may serve as a join key. The PK index is keyed on `Value`
  /// directly via `Predicate.compare` (which bridges `#nat`/`#int`), so there
  /// is no per-access Text encoding; this only gates build-time insertion so a
  /// target with a null/float primary key surfaces loudly instead of silently
  /// left-joining every traversal to null.
  func joinableValue(v : Value) : Bool = switch v {
    case (#text _) true;
    case (#nat  _) true;
    case (#int  _) true;
    case (#bool _) true;
    case _ { false };
  };

  func buildIndex(decl : Entity.Decl, subject : ?Principal) : Map.Map<Value, Row> {
    let idx = Map.empty<Value, Row>();
    for (row in decl.rows(subject)) {
      let pk = row.get([decl.primaryKey]).get(#null_);
      if (not joinableValue(pk)) {
        Runtime.trap("OQL: row of '" # decl.name # "' has no joinable primary key '"
          # decl.primaryKey # "'")
      };
      idx.add(Predicate.compare, pk, row);
    };
    idx
  };

  /// Edge-aware row view: base-first, traverse-on-miss. Plain rows answer
  /// null for multi-segment paths (`Entity.makeRow`), so they always fall
  /// through to traversal; aggregated rows resolve their flat dotted group
  /// columns locally and only traverse from FK group keys.
  func wrapRow(base : Row, entityName : Text, hops : Hops) : Row = {
    get = func (path : Path) : ?Value {
      switch (base.get(path)) {
        case (?v) { ?v };
        case null {
          if (path.size() < 2) return null;
          let target = switch (hops.edges.get(Text.compare, entityName # "\u{1f}" # path[0])) {
            case (?t) { t };
            case null { return null };
          };
          let idx = switch (hops.indexes.get(Text.compare, target)) {
            case (?i) { i };
            case null { return null };
          };
          let fk = switch (base.get([path[0]])) {
            case (?v) { v };
            case null { return null };
          };
          // Float/null FKs are unjoinable by design — a float PK traps at build
          // time, so mirror that on the FK side: left-join to null instead of
          // letting Predicate.compare bridge a #float FK into a numerically-equal
          // #nat/#int PK (e.g. #float 3.0 joining #nat 3, or -0.0 joining 0).
          // (A declared-Float FK is rejected earlier by validateHop's `joinable`
          // type check; this guard covers the runtime divergence case where the
          // seed row was Nat but a later row emits #float for the same FK.)
          if (not joinableValue(fk)) return null;
          switch (idx.get(Predicate.compare, fk)) {
            case null { null };               // dangling FK -> left-join null
            case (?t) {
              let rest = path.sliceToArray(1, path.size());
              if (rest.size() == 1) { t.get(rest) }          // single-hop: read off target, no re-wrap
              else { wrapRow(t, target, hops).get(rest) };   // multi-hop: keep recursion
            };
          };
        };
      };
    };
    // Own-field single-segment reads hit `base` first and are identical to
    // the base row, so forward its flat accessor; edge paths (multi-segment)
    // go through `get` above, which the flat path never serves.
    slot = base.slot; values = base.values;
  };

  /// Filter the row iterator by the predicate. `cap` bounds how many survivors
  /// to collect (lazy: the scan stops once `cap` is reached); `null` collects
  /// all. Bounding is only passed when ordering/aggregation are absent, where
  /// scan order is the result order.
  func filter(it : Iter.Iter<Row>, where_ : ?Predicate.Predicate, cap : ?Nat) : [Row] {
    let matched = switch where_ {
      case null    { it };
      case (?p)    { it.filter(func row = Predicate.eval(p, row)) };
    };
    switch cap {
      case null { matched.toArray() };
      case (?n) {
        let acc = List.empty<Row>();
        label scan for (row in matched) {
          if (acc.size() >= n) break scan;
          acc.add(row);
        };
        acc.toArray()
      };
    };
  };

  /// Resolve each single-segment field to its flat slot ONCE, using a sample
  /// row's fast accessor (the slot map is shared across the entity's rows).
  /// Multi-segment paths (edge traversal) and non-flat rows yield `null`, so
  /// the per-row caller falls back to `get`.
  func resolveSlots(sample : ?Row, fields : [Path]) : [?Nat] =
    switch (do ? { sample!.slot! }) {
      case (?resolve) { Array.map<Path, ?Nat>(fields, func p = if (p.size() == 1) resolve(p[0]) else null) };
      case null       { Array.tabulate<?Nat>(fields.size(), func _ = null) };
    };

  func project(row : Row, paths : [Path], names : [Text], slots : [?Nat]) : [Cell] =
    Array.tabulate<Cell>(paths.size(), func i = {
      name  = names[i];
      value = switch (slots[i], row.slot) {
        case (?s, ?_) { row.values[s] };              // flat: index directly
        case _        { row.get(paths[i]).get(#null_) };
      };
    });

  /// Explicit `select` wins. Otherwise: for aggregated results project the
  /// group-key + aggregate columns; for plain results project every
  /// non-hidden field in declaration order (hidden fields are already
  /// absent from the row).
  func projectionPaths(sel : ?[Path], all : [Schema.FieldDecl], defaultCols : ?[Text]) : [Path] =
    switch sel {
      case (?p) { p };
      case null {
        switch defaultCols {
          case (?cols) { cols.map(func (c : Text) : Path = [c]) };
          case null {
            all.filter(func f = switch (f.role) { case (#hidden) false; case _ true })
               .map(func (f : Schema.FieldDecl) : Path = [f.name])
          };
        }
      };
    };

  /// Decorate-sort. The naive approach calls `row.get(c.field)` inside every
  /// comparison; for a dotted path that re-traverses the join O(n log n) times.
  /// Instead, extract each row's orderBy key ONCE (n traversals), then sort the
  /// (key, row) pairs comparing the precomputed keys. `Array.sort` is stable and
  /// `compareKeys` mirrors the old comparator exactly (same `Predicate.compare`,
  /// same asc/desc, same null handling), so the result is identical.
  func sortByKeys(rows : [Row], clauses : [Query.OrderBy]) : [Row] {
    let slots = resolveSlots(
      if (rows.size() == 0) null else ?rows[0],
      Array.map<Query.OrderBy, Path>(clauses, func c = c.field));
    func keyOf(r : Row) : [Value] =
      Array.tabulate<Value>(clauses.size(), func i =
        switch (slots[i], r.slot) {
          case (?s, ?_) { r.values[s] };
          case _        { r.get(clauses[i].field).get(#null_) };
        });
    let decorated = Array.map<Row, ([Value], Row)>(rows, func r = (keyOf(r), r));
    let ordered = Array.sort<([Value], Row)>(
      decorated, func ((ka, _), (kb, _)) = compareKeys(ka, kb, clauses));
    Array.map<([Value], Row), Row>(ordered, func ((_, r)) = r)
  };

  /// Compare two precomputed orderBy keys (aligned to `clauses`), applying each
  /// clause's direction. Same semantics as the former per-row comparator.
  func compareKeys(ka : [Value], kb : [Value], clauses : [Query.OrderBy]) : Order.Order {
    var i = 0;
    while (i < clauses.size()) {
      let raw = Predicate.compare(ka[i], kb[i]);
      let oriented = switch (clauses[i].dir) { case (#asc) raw; case (#desc) flip(raw) };
      if (oriented != #equal) return oriented;
      i += 1;
    };
    #equal
  };

  func flip(o : Order.Order) : Order.Order = switch o {
    case (#less)    { #greater };
    case (#equal)   { #equal };
    case (#greater) { #less };
  };

  // ── Aggregation ─────────────────────────────────────────────────────────

  type Group = { keyCells : [(Text, Value)]; members : List.List<Row> };

  /// Bucket `rows` by the `groupBy` keys and collapse each bucket to one
  /// output row: the group-key cells followed by one cell per aggregate.
  /// With no `groupBy` but aggregates present, emits a single row over all
  /// rows (so `count` of an empty set is `0`). Group order is first-seen.
  func aggregateRows(rows : [Row], groupBy : [Path], aggs : [Agg])
    : { rows : [Row]; columns : [Text] } {

    let columns = groupBy.map(Types.pathToText).concat(aggs.map(aggName));

    // One output row: the group's key cells plus one cell per aggregate.
    func aggRow(keyCells : [(Text, Value)], members : [Row]) : Row {
      let aggCells = Array.map<Agg, (Text, Value)>(aggs, func a = (aggName(a), computeAgg(a, members)));
      rowOf(keyCells.concat(aggCells))
    };

    if (groupBy.size() == 0) return { rows = [aggRow([], rows)]; columns };

    let groups = Map.empty<Text, Group>();
    let order  = List.empty<Text>();
    for (row in rows.values()) {
      let keyVals = groupBy.map(func (p : Path) : Value = row.get(p).get(#null_));
      let key = groupKey(keyVals);
      switch (groups.get(Text.compare, key)) {
        case (?g) { g.members.add(row) };
        case null {
          let keyCells = Array.tabulate<(Text, Value)>(
            groupBy.size(),
            func i = (Types.pathToText(groupBy[i]), keyVals[i]),
          );
          let g : Group = { keyCells; members = List.empty<Row>() };
          g.members.add(row);
          groups.add(Text.compare, key, g);
          order.add(key);
        };
      };
    };

    let out = List.empty<Row>();
    for (key in order.values()) {
      let g = switch (groups.get(Text.compare, key)) { case (?x) x; case null { Runtime.trap("OQL: group vanished") } };
      out.add(aggRow(g.keyCells, g.members.toArray()));
    };
    { rows = out.toArray(); columns };
  };

  type Agg = Query.Agg;

  /// Output column for an aggregate. Defaults join path segments with
  /// `_` (not `.`): a dotted default like `sum_dept.budget` would parse
  /// as an edge path on any later reference and trap.
  func aggName(a : Agg) : Text = switch (a.as_) {
    case (?n) { n };
    case null {
      let base = switch (a.fn) {
        case (#count) "count"; case (#sum) "sum"; case (#avg) "avg";
        case (#min) "min";     case (#max) "max";
      };
      switch (a.field) { case null { base }; case (?p) { base # "_" # p.values().join("_") } };
    };
  };

  func computeAgg(a : Agg, members : [Row]) : Value =
    switch (a.fn) {
      case (#count) { #nat(members.size()) };
      case (#sum)   { sumOf(fieldValues(a.field, members)) };
      case (#avg)   { avgOf(fieldValues(a.field, members)) };
      case (#min)   { extremeOf(fieldValues(a.field, members), true) };
      case (#max)   { extremeOf(fieldValues(a.field, members), false) };
    };

  /// Non-null values at `field` across `members`.
  func fieldValues(field : ?Path, members : [Row]) : [Value] {
    switch field {
      case null { [] };
      case (?p) {
        let acc = List.empty<Value>();
        for (row in members.values()) {
          switch (row.get(p)) { case (?v) { if (v != #null_) acc.add(v) }; case null {} };
        };
        acc.toArray()
      };
    };
  };

  func sumOf(vals : [Value]) : Value {
    var acc : Value = #nat(0);
    for (v in vals.values()) acc := numAdd(acc, v);
    acc
  };

  func avgOf(vals : [Value]) : Value {
    if (vals.size() == 0) return #null_;
    #float(toFloat(sumOf(vals)) / Float.fromInt(vals.size()))
  };

  /// `wantMin = true` → minimum; otherwise maximum. Uses `Predicate.compare`
  /// so numeric variants bridge and text compares lexicographically.
  func extremeOf(vals : [Value], wantMin : Bool) : Value {
    if (vals.size() == 0) return #null_;
    var acc = vals[0];
    var i = 1;
    while (i < vals.size()) {
      let c = Predicate.compare(vals[i], acc);
      if ((wantMin and c == #less) or (not wantMin and c == #greater)) acc := vals[i];
      i += 1;
    };
    acc
  };

  /// Numeric addition promoting Nat → Int → Float; non-numeric `b` is a no-op.
  func numAdd(a : Value, b : Value) : Value =
    switch (a, b) {
      case (#float x, _) { #float(x + toFloat(b)) };
      case (_, #float y) { #float(toFloat(a) + y) };
      case (#int x, _)   { #int(x + toInt(b)) };
      case (_, #int y)   { #int(toInt(a) + y) };
      case (#nat x, #nat y) { #nat(x + y) };
      case _ { a };
    };

  func toFloat(v : Value) : Float = switch v {
    case (#float f) { f }; case (#int i) { Float.fromInt(i) };
    case (#nat n)   { Float.fromInt(n) }; case _ { 0.0 };
  };

  func toInt(v : Value) : Int = switch v {
    case (#int i) { i }; case (#nat n) { n }; case _ { 0 };
  };

  /// Synthetic row for aggregated results. Keys on the rendered path text
  /// so a dotted group column (`"dept.name"`) is reachable both as the
  /// single-segment default-projection path and as the parsed
  /// `["dept","name"]` from orderBy/select.
  func rowOf(cells : [(Text, Value)]) : Row {
    let m = Map.empty<Text, Value>();
    for ((k, v) in cells.values()) m.add(Text.compare, k, v);
    {
      get = func (p : Path) : ?Value = if (p.size() == 0) null else m.get(Text.compare, Types.pathToText(p));
      slot = null; values = [];  // aggregated row is Map-backed (dotted group keys) — no flat layout.
    }
  };

  /// Type-tagged serialisation of the group-key tuple, so distinct values
  /// (and distinct types) never collide into the same bucket.
  func groupKey(vals : [Value]) : Text {
    var s = "";
    for (v in vals.values()) s := s # valueKey(v) # "\u{1f}";
    s
  };

  func valueKey(v : Value) : Text = switch v {
    case (#null_)   { "0:" };
    case (#bool b)  { "1:" # Bool.toText(b) };
    case (#nat n)   { "2:" # Nat.toText(n) };
    case (#int i)   { "3:" # Int.toText(i) };
    case (#float f) { "4:" # Float.toText(f) };
    case (#text t)  { "5:" # t };
  };

};
