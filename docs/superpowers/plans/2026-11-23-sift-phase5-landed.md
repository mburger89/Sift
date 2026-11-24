# Sift phase 5: checking what landed — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** make the grid answer "did what my code wrote land?":
- newest rows first, by a timestamp or serial column;
- Refresh highlights the rows that are new or changed since the last look, down to the cell where Sift knows the old value;
- a foreign-key value can be followed to the row it references, and a row can list and open the rows that reference it, with back and forward.

**Architecture:**
- **Newest first** is only a sort: `GridQuery.sort` gains an explicit NULLS placement. A pure `RecencyColumns` in `SiftCore` picks the column. The session gives a new grid that sort by default when the column is cheap to sort on.
- **Changes** use Postgres's `xmin`. Every inserted or updated row version carries the transaction that wrote it.
  - At each look, the grid takes a *marker*: the first transaction id not yet assigned (`txid_snapshot_xmax(txid_current_snapshot())`).
  - The next Refresh asks the pager to add a hidden per-row flag, `age(xmin) <= age(marker)`. It can also filter to the flagged rows.
  - The model compares a flagged row with the values it held for the same key before the refresh, to find the changed cells.
- **Following keys** is pure filtering. Following `orders.customer_id = 42` opens `customers` with the chip `id = 42`, and "referenced by" opens `orders` with `customer_id = 42`. Both reuse phase 3's bound, cast filters, so nothing new reaches SQL. `AppModel` keeps a back and forward history of the relations visited, with each grid's query and active cell.

**Tech stack:**
- Swift 6.4, libpq, swift-testing and MetalUITesting.
- MetalUI at the commit phase 4 pinned (`METALUI_REF` on `phase4/sql-editor`, `3f1b2bb7` or later). It already has `tableCellBackground` (TCM-I), `contextMenu(forSelectionType:menu:primaryAction:)` (TBL-P), and `ScrollViewReader`/`scrollTo(TableCell)` (TCM-J). MetalUI has no navigation-stack primitive, so the history is Sift's.

**Spec:** `docs/superpowers/specs/2026-11-18-sift-design.md`: "Checking what landed", "Read-only by default", the anti-goals, and the phase 5 line. The MetalUI contracts are in `../MetalUI/docs/superpowers/2026-11-18-table-decisions.md`, read for these rulings:
- TBL-P: context menu and primary action;
- TBL-Y: keys;
- TBL-Z: `scrollTo`.

The cell-mode contracts are in `../MetalUI/docs/superpowers/specs/2026-11-20-table-cell-mode-design.md`, read for:
- TCM-E: the keys cell mode consumes;
- TCM-I: `tableCellBackground`, which runs once per realised cell per build;
- TCM-J: revealing a cell.

**Where it runs:**
- Use worktree `~/Developer/worktrees/Sift/landed` on branch `phase5/landed`.
- Branch from `main` if phase 4 is merged by then. Otherwise branch from `origin/phase4/sql-editor`, and open the PR against `phase4/sql-editor` until phase 4 merges, then retarget it to `main`.
- `../MetalUI` resolves to `~/Developer/worktrees/Sift/MetalUI`, which phase 4's session also uses. **Never check out, pull or edit anything in it.** If it is not at the commit you need, stop and report.

## Global constraints

- **Read-only:**
  - Every query runs through `executeInReadOnlyTransaction`, with the pager's existing timeouts. The marker query has `2s`.
  - Nothing in this phase writes to a database. `txid_current_snapshot()` does not assign a transaction id, and it works in `READ ONLY` and on a hot standby.
- **No user text in SQL:**
  - Identifiers go through `PGIdentifier.quote`.
  - Every value is a bound `$n`: the marker, and every followed key value (cast `$n::<type>` by phase 3's filter path).
  - A key value is never spliced into SQL text.
- **One query in flight per grid:** the marker is one more kind of `GridModel` work, under the same generation and serial rules. A superseded marker never lands.
- **No O(rows) main-actor work:**
  - `tableCellBackground`'s closure and the cells read only the page cache, O(1) per realised cell, and never read observable state (TCM-I).
  - The cell diff runs once per page that lands (at most 500 rows), never per frame.
  - The keep-for-diff copy is at most the cache, 20 000 rows.
- **Passwords:** none in logs, errors or test output (existing rule).
- **Off-Darwin test pitfalls:**
  - use `runUntilIdle()`;
  - sum `frameWork`;
  - use `Modifiers.primary`.
- **CI:** CI stays green on macOS, Linux and Windows. Keep the Windows `-Xcc -D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH` flag.
- **Windows stack (G17, MetalUI PE-K):** Windows test-worker threads have a 1 MB stack. In a debug build, a large result builder held inline among its siblings gets a huge stack frame (about 1.2 MB). Phase 4's first CI run overflowed this way in MapToolbar: a Picker with three tagged segments, inline in the toolbar's HStack.
  - Put any sizeable builder in its own `Component, Equatable` and use it with `.equatable()`, as `DetailModePicker` does. That applies to a Picker, a Menu or context-menu content, or a run of several controls. The toolbar's new Refresh, Newest-first and Only-changes controls, the row context menu, and the header's back and forward buttons each go in their own component.
  - Every wrapper this phase adds also deepens the grid's element tree: `ScrollViewReader`, the context menu, the header buttons. Keep each one flat: no new nesting layers for layout alone.
  - Treat a Windows CI crash as this risk first.
- **No hacks around MetalUI:** a missing piece goes in the spec's section 11 table with a minimal repro. Add G17 (Windows: a large inline builder's debug stack frame overflows a 1 MB test-worker stack, MetalUI PE-K, from phase 4) when you first touch section 11, then continue from G18. Do not edit `../MetalUI`.
- **Cleanup:**
  - Any Postgres container you start is named `sift-landed-*`, and is deleted, with its volume, as soon as its result has been read.
  - Remove its image too if you pulled it. Touch nothing else's.

## Decisions (coordinator's calls)

**Newest first**
- **Recency candidates** (`RecencyColumns.candidates(for: RelationInfo) -> [Int]`, in order):
  1. Timestamp-like columns whose name is, case-insensitively, one of these. Timestamp-like means `timestamp with time zone`, `timestamp without time zone`, `timestamptz`, `timestamp` or `date`. Names, in this priority:
     - `created_at`, `inserted_at`, `created`, `created_on`, `creation_time`, `createdat`;
     - then `updated_at`, `modified_at`, `updated`, `modified`, `last_modified`, `updatedat`.
  2. Any other timestamp-like column whose `defaultExpression`, lowercased, contains `now()`, `current_timestamp` or `clock_timestamp()`.
  3. Integer columns (`smallint`, `integer`, `bigint` and their aliases) that are an identity column or whose default starts with `nextval(`. The primary-key column comes first.

  The first candidate is the default. Fewer than 1 candidate means the toggle is hidden.
- **Default on:** a new grid opens newest-first when its first candidate is cheap to sort on (`RecencyColumns.defaultSort(for:) -> GridSort?`). Cheap means either of these:
  - the candidate is the first column of a btree index (the primary key counts);
  - the relation's estimate is under 100 000 rows, or unknown.

  Otherwise the grid opens in key order, with the toggle off.
- **Sort:** `GridSort(column: c, ascending: false, nullsLast: true)`. NULLs go last, not first: a row with no timestamp is not "newest".
  - `GridSort` gains `nullsLast: Bool`. Its initialiser takes `nullsLast: Bool? = nil`, defaulting to `ascending`, which is phase 3's behaviour.
  - The pager writes `NULLS LAST` or `NULLS FIRST` from it. Keyset is already off for nullable sort columns.
  - `QueryResultSource` (phase 4) must honour it too. Add one test there.
- **Toolbar:** a "Newest first" toggle button (`grid.newest`). When there is more than one candidate, it is followed by a picker of the candidates (`grid.newest.column`). A header-click sort turns the toggle off because the sort no longer matches. Turning it off sets `sort = nil`.

**Changes since the last look**
- **Marker:** `SELECT (txid_snapshot_xmax(txid_current_snapshot()) % 4294967296)::text`. This works on every supported server version. It is kept as the decimal text of a 32-bit xid.
  - **Flag:** `age(xmin) <= age($n::xid)` is true for any row version written by a transaction that started at or after the marker.
  - A frozen or old row has a larger age. The rule holds for 2³¹ transactions.
- **When markers are taken:**
  - When a grid opens: before its first page, so nothing committed between the first read and the marker is missed.
  - At every Refresh: before that refresh's pages. Refresh then shows the changes since the *previous* marker and keeps the new one for next time.
  - Overlap is allowed: a row committed while a look is in progress may be flagged twice. A gap is not: no change is ever missed.
- **Query:** `GridQuery` gains `changes: ChangeFilter?`, where `ChangeFilter { since: String; only: Bool }`.
  - With `changes` set, each row the pager returns has one extra trailing value: `.bool(changed)`. It is always the row's **last** value, after `ctid`.
  - With `only`, the pager also adds the flag to `WHERE`, and `narrows` is true.
  - Sort, filter and search changes keep `changes`. The highlight lasts until the next Refresh, or until Clear (`changes = nil`).
- **Support:** `GridSource.supportsChanges`:
  - `PGRelationPager` supports tables, partitioned tables and materialized views.
  - Views and foreign tables have no `xmin`, so they are unsupported.
  - Fakes and `QueryResultSource` use the default, `false`.
  - Unsupported means no Refresh highlight. Refresh still re-reads.
- **Cell diff:**
  - At a Refresh, before dropping pages, the model copies `key → row` from every cached page. `key` is the values at `GridSource.keyColumns`: the primary key or the unique NOT NULL key. It is empty for `ctid` or no key, and then there is no copy.
  - When a page lands, each flagged row gets a mark:
    - `.changed(cells:)`: the set of column indexes whose value differs from the copy, possibly empty for a no-op `UPDATE`;
    - `.newOrChanged`: there is no copy of its key.
  - Unflagged rows get no mark.
- **Drawing:** `tableCellBackground`.
  - `.newOrChanged` and `.changed` rows get the row tint across every cell, including "#". A changed cell gets the stronger tint.
  - Two theme keys in `Theme.swift`: `ChangeRowFill` (light `(0.86, 0.93, 1.0)`, dark `(0.13, 0.22, 0.36)`) and `ChangeCellFill` (light `(1.0, 0.87, 0.55)`, dark `(0.45, 0.33, 0.08)`).
  - Colour is never the only signal. A marked cell's content has an `accessibilityValue` of `"changed"` (changed cell), `"row changed"` (`.changed` row, other cells) or `"new or changed"`.
  - No animation: TBL-K cells have no animation slot, and a fade would redraw every realised cell every frame.
- **Status bar:**
  - After a Refresh with changes: "Changes since 10:42:13". The time comes from an injected `now: () -> Date` and is shown in the local zone, `HH:mm:ss`.
  - Then a toggle "Only changes" (`grid.changes.only`, sets `only`) and "Clear" (`grid.changes.clear`).
  - With `only` on, the existing count shows how many changed.
  - The "full scan" warning also shows when `only` is on over more than 1 M estimated rows.
- **Refresh:**
  - A toolbar button "Refresh" (`grid.refresh`).
  - The app's existing ⌘R (`AppModel.refresh()`) also refreshes the grid that is showing: the selected relation's grid, when `detailMode == .table` and `relationTab == .rows`.
  - There is no second shortcut.
- **Not in this phase:**
  - deleted rows (`xmin` cannot see them);
  - auto-refresh or `LISTEN`;
  - changes in SQL-editor results.

**Following keys**
- **Links of a row** (`ReferenceLinks`, pure):
  - **Outgoing:** for each FK in `snapshot.outgoing(of: relation)`, a link to `fk.to`, with `fk.toColumns[i] = row[fk.fromColumns[i]]`.
  - **Incoming:** for each FK in `snapshot.incoming(of: relation)`, a link to `fk.from`, with `fk.fromColumns[i] = row[fk.toColumns[i]]`.
  - A link whose values include NULL, or a value that is not loaded, is **disabled**. It still shows, as "customer_id is NULL".
  - Value text is `CellFormat.rawText`. The filter is `.eq` per column pair, ANDed. Column indexes are positions in the target's `relation.columns`.
  - Composite keys pair by position (`shipments (product_id, order_id) → order_items (product_id, order_id)`).
- **Following:**
  - `AppModel.follow(_ link: GridFollow, in key: ConnectionKey)` records history, selects the target, and sets `relationTab = .rows`.
  - It applies `GridQuery(sort: RecencyColumns.defaultSort(for: target), filters: link.filters)` to the target's grid, which is created if needed.
  - It sets `activePosition` to `(row 0, first target key column)` and `selectedRow = 0`, and asks the grid to reveal that cell.
  - A self-reference (`employees.manager_id`) re-filters the same grid. History restores it.
- **Where links appear:**
  1. **Inspector:** a "Links" section under the value: outgoing links first, then "Referenced by". Each is a button, `inspector.link.out.<fk.id>` or `inspector.link.in.<fk.id>`, titled like `KeysSection`'s titles plus the values: `customer_id → customers (id = 42)`.
  2. **Row context menu:** `contextMenu(forSelectionType: Int.self)`. For a single row, the same links are menu items. For several rows, no items.
  3. **Primary action** (Return or a double click in cell mode, TBL-P and TCM-E): follows the active cell's outgoing FK when its column belongs to exactly one outgoing FK. Otherwise it does nothing.
  4. **FK columns:** cells in a column of an outgoing FK draw in `MapAccent`'s colour (move that key to a shared name, `LinkAccent`, used by both). The header shows the plain column name.
- **Reveal:** `GridModel` gains `revealRequest: GridPosition?` (observable, bumped by `follow` and by back and forward). `GridTable` wraps its `Table` in a `ScrollViewReader`, and on a new request calls `proxy.scrollTo(TableCell(row:, column: column + 1), anchor: .center)`. Writing the active-cell binding does not scroll (TBL-Z).
- **History** (`NavigationHistory`, a pure struct in `SiftKit/Model`):
  - An entry is `(key, relation, query, activePosition)`.
  - Every change of the selected relation pushes the place being left, unless the change *is* a back or forward: sidebar clicks, follows, `KeysSection` buttons and the map's open.
  - A push clears forward. At most 100 entries; the oldest is dropped.
  - Back and forward restore the selection, the relation tab (`.rows` when the entry has a query) and the grid's query and active cell, then reveal it.
  - An entry whose session or relation is gone is still selected: the detail shows "not in the current schema", as it does today.
  - Buttons ‹ and › in `RelationHeader` (`detail.back`, `detail.forward`) are disabled when there is nowhere to go.
  - Menu commands "Back" ⌘[ and "Forward" ⌘] go in `installSiftCommands`.

## Review focus

1. **A change is missed:** the marker is read after a page instead of before it, so a row committed in between is never flagged. Pin the order of calls in the fake (`marker` before every page of that look), and in the integration test insert between "marker taken" and "page read".
2. **A stale answer lands:** a marker or page from before a sort, Clear or second Refresh lands into the new view and marks rows wrongly. Pin it with held, reordered answers.
3. **A followed value does not match** after its text round trip: `uuid`, `bigint`, `timestamptz`, `numeric`, `text` with `'` and `%`, and a composite key. Integration-test each against the fixture, and assert they are parameters, never SQL text.
4. **Back after a self-reference or a chain loses state:** customers (all, row 300 active) → follow incoming → orders `customer_id = 42` → follow product → back → back. The first grid's query, active cell and reveal must come back.
5. **Newest first on a nullable timestamp puts NULL rows on top**, or a header click leaves the toggle showing on. Pin `NULLS LAST` in SQL and in a real query, and pin the toggle's state.

---

### Task 1: the query model and SQL for newest-first and changes (SiftCore, SiftPG; pure)

**Files:**
- Modify `Sources/SiftCore/GridSource.swift`.
- Create `Sources/SiftCore/RecencyColumns.swift`.
- Modify `Sources/SiftPG/PGRelationQuery.swift`.
- Modify `Sources/SiftCore/QueryResultSource.swift` (phase 4), only for `nullsLast`.
- Test: `Tests/SiftCoreTests/RecencyColumnsTests.swift`, `Tests/SiftPGTests/PGRelationQueryTests.swift` (add) and `Tests/SiftCoreTests/QueryResultSourceTests.swift` (add one).

**Interfaces (produced):**
```swift
public struct GridSort { public var column: Int; public var ascending: Bool; public var nullsLast: Bool
    public init(column: Int, ascending: Bool = true, nullsLast: Bool? = nil) }        // nil → ascending
public struct ChangeFilter: Sendable, Equatable { public var since: String; public var only: Bool
    public init(since: String, only: Bool = false) }
// GridQuery gains `public var changes: ChangeFilter?` (init param `changes: ChangeFilter? = nil`); `narrows` is also true when `changes?.only == true`.
// GridSource gains, with defaults in the extension:
var supportsChanges: Bool { get }                      // false
var keyColumns: [Int] { get }                          // []
func changeMarker() async throws -> String             // throws SourceError(.other, "changes are not supported")
public enum RecencyColumns {
    public static func candidates(for relation: RelationInfo) -> [Int]
    public static func defaultSort(for relation: RelationInfo) -> GridSort?
    public static let cheapRowLimit = 100_000
}
// PGRelationQuery:
public static let markerSQL: String
public var supportsChanges: Bool { get }               // relation.kind ∈ table, partitionedTable, materializedView
```

- [ ] **Step 1: write the failing tests.**
  - `RecencyColumnsTests`:
    - `createdAtBeatsUpdatedAtBeatsADefaultNowColumnBeatsASerialKey`;
    - `namesMatchCaseInsensitivelyAndOnlyOnTimestampLikeTypes` (a `text` column named `created_at` is not a candidate);
    - `anIdentityOrNextvalIntegerIsACandidatePrimaryKeyFirst`;
    - `noCandidatesMeansNoDefault`;
    - `theDefaultIsOnOnlyWhenIndexedOrSmall`: an unindexed `created_at` on a 5 M estimate gives nil, the same with a btree index leading on `created_at` gives `GridSort(column:, ascending: false, nullsLast: true)`, and a 50 000 estimate also gives the sort.
  - `PGRelationQueryTests`:
    - `aDescendingSortCanPutNullsLast`: `ORDER BY "created_at" DESC NULLS LAST, "id" DESC`;
    - `theDefaultNullsPlacementIsUnchanged` (phase 3's strings);
    - `changesAddATrailingFlagAfterCtid`: the select list ends `ctid::text AS "_sift_ctid", age(xmin) <= age($1::xid) AS "_sift_changed"`, and the params are `["123"]`;
    - `onlyChangesAlsoFiltersAndCountsWithTheFlag`: `pageSQL` and `countSQL` contain `WHERE age(xmin) <= age($n::xid)` with the marker bound;
    - `theMarkerIsNeverInTheSQLText`: the marker `"1; drop table x"` appears only in the params;
    - `keysetStillWorksWithChangesOn`: the keyset placeholders are numbered after the marker's;
    - `viewsDoNotSupportChanges`.
  - `QueryResultSourceTests`: `nullsLastHonouredInMemory`.
- [ ] **Step 2: run** `swift test --filter 'RecencyColumnsTests|PGRelationQueryTests|QueryResultSourceTests'`. Expect FAIL: not defined.
- [ ] **Step 3: implement.**
- [ ] **Step 4: run.** Expect PASS. Also run the whole `SiftPGTests` and `SiftCoreTests`: phase 3's tests must still pass unchanged.
- [ ] **Step 5: commit** "Landed: newest-first sort and the change flag in the relation SQL".

### Task 2: `PGRelationPager` markers and changes, integration-tested (SiftPG)

**Files:**
- Modify `Sources/SiftPG/PGRelationPager.swift`: `supportsChanges`, `keyColumns` (the order key for `.primaryKey`/`.uniqueNotNull`, else `[]`) and `changeMarker()` (`markerSQL`, timeout `2s`).
- Modify `Sources/SiftTestSupport/PGFixture.swift`, only to add what the tests below need: `a.notes (id serial PRIMARY KEY, body text, created_at timestamptz)` with some NULL `created_at`, and a `bytea` and a `numeric` FK pair if none exists.
- Test: `Tests/SiftPGTests/PGRelationPagerChangesTests.swift`. It skips without `SIFT_PG_URL`, like the other integration tests. Writes to the fixture go through `PGFixture`'s own admin connection, never through the pager.

- [ ] **Step 1: write the failing tests.**
  - `aRowInsertedAfterTheMarkerIsFlaggedAndOldRowsAreNot`.
  - `anUpdatedRowIsFlagged`, and a row that was only `SELECT … FOR UPDATE`d is not.
  - `aRowCommittedBetweenMarkerAndPageReadIsFlagged` (Review focus 1).
  - `onlyChangesReturnsExactlyTheFlaggedRowsAndCountsThem`.
  - `aPartitionedTableSupportsChanges` (`a.events`). If the server refuses `xmin` on the partitioned parent, stop and report it: do not quietly mark it unsupported.
  - `aViewDoesNotSupportChanges`.
  - `newestFirstPutsNullTimestampsLast` (`a.notes`).
  - `theMarkerRunsReadOnlyAndLeavesTheConnectionIdle`.
- [ ] **Step 2: run them** against a local Postgres 17 container `sift-landed-pg`. Expect FAIL.
- [ ] **Step 3: implement.**
- [ ] **Step 4: run.** Expect PASS. Delete the container.
- [ ] **Step 5: commit** "Landed: the pager's change markers".

### Task 3: `GridModel`: newest-first state, markers, refresh and change marks (SiftKit)

**Files:**
- Modify `Sources/SiftKit/Grid/GridModel.swift`.
- Modify `Sources/SiftTestSupport/FakeGridSource.swift`. Add:
  - `supportsChanges`, `keyColumns` and a scripted `changeMarker()`, which can be held like pages;
  - a way for a test to say which ordinals are "changed" and to change a row's values between looks;
  - `.marker` in `Call`.
- Modify `Sources/SiftKit/Model/DatabaseSession.swift`:
  - a new grid gets `RecencyColumns.defaultSort` as its first query, and its `recencyColumns`;
  - `existingGrid(for:) -> GridModel?` (never creates).
- Test: `Tests/SiftKitTests/GridChangesTests.swift`, and update `GridModelTests` only where the new marker call changes a recorded call list.

**Interfaces (produced):**
```swift
public enum RowMark: Equatable, Sendable { case newOrChanged; case changed(cells: Set<Int>) }
// GridModel:
public init(source: any GridSource, clock: any SiftClock = SystemClock(), initialQuery: GridQuery = GridQuery(), now: @escaping @Sendable () -> Date = { Date() })
public var recencyColumns: [Int]                       // set by the session; empty hides the toggle
public var isNewestFirst: Bool { get }                 // query.sort == newest sort of the chosen column
public var newestColumn: Int?                          // the chosen candidate
public func setNewestFirst(_ on: Bool)
public func refresh()                                  // take a marker, then re-read with changes since the previous one
public func setOnlyChanges(_ on: Bool)
public func clearChanges()
public private(set) var changesSince: Date?            // the time of the look the highlight is relative to; nil = none
public func mark(row: Int) -> RowMark?                 // O(1), page cache only, never observed
public private(set) var revealRequest: GridPosition?
public func reveal(_ position: GridPosition)
```
- `Work` gains `.marker`. The pump order is: marker, exact count, count, page.
- When a grid opens, `init` queues a marker when `supportsChanges`. The first page waits for it.
- `refresh()` queues a marker. When it lands, the model:
  1. copies the cache (`key → row`) when `keyColumns` is not empty;
  2. applies the query with `changes = ChangeFilter(since: previousMarker, only: currentOnly)`;
  3. stores the new marker as `previousMarker` and sets `changesSince = now()` of the previous look.

  Without `supportsChanges`, `refresh()` re-applies the same query with its pages dropped. That needs a forced re-read: `apply` ignores an equal query, so add a private path.
- The trailing flag is stripped from each row as its page lands, so `value(row:column:)` and `columns` are unchanged. Marks are kept per page beside the rows and evicted with them.

- [ ] **Step 1: write the failing tests.**
  - `openingTakesAMarkerBeforeTheFirstPage`.
  - `refreshTakesAMarkerThenReadsWithChangesSinceThePreviousOne` (two refreshes: the second uses the first refresh's marker).
  - `flaggedRowsAreMarkedAndUnflaggedAreNot`.
  - `aChangedRowWithAKnownKeyMarksOnlyItsChangedCells`.
  - `aFlaggedRowWithNoCopyIsNewOrChanged`.
  - `noKeyColumnsMeansRowMarksOnly`.
  - `aStaleMarkerAfterClearOrASecondRefreshNeverLands` (Review focus 2).
  - `sortAndFilterKeepTheHighlight`.
  - `clearDropsTheHighlight`.
  - `onlyChangesNarrowsAndRecounts`.
  - `anUnsupportedSourceRefreshesWithoutMarkers`.
  - `theTrailingFlagNeverReachesValueReads`.
  - `markReadsNoObservableState` (`withObservationTracking`, as phase 3's `aBuildNeverWritesObservableState`).
  - `newestFirstToggleSetsAndClearsTheDescNullsLastSort`.
  - `aHeaderSortTurnsNewestFirstOff`.
  - `theSessionOpensACheapRecencyGridNewestFirst`.
  - `aDiffOfAFullPageCostsOnePassOverIt`: count the comparisons, at most 500 × columns.
- [ ] **Steps 2–4:** fail, implement, pass. Run `GridModelTests`, `GridViewTests` and `GridCostTests` too. A phase 3 test may change only because of the opening marker, or because a fixture relation now opens newest-first. Say which ones changed, and why, in the report.
- [ ] **Step 5: commit** "Landed: refresh, change marks and newest-first in the grid model".

### Task 4: the grid's newest-first and change UI (SiftKit)

**Files:**
- Modify `GridToolbar.swift` (Newest first toggle and picker, and Refresh), `GridStatusBar.swift` ("Changes since", Only changes, Clear), `GridView.swift` (`tableCellBackground`, the marks' accessibility values) and `GridCell.swift` (a `mark` input).
- Modify `Theme.swift`: `ChangeRowFill`, `ChangeCellFill`, and `LinkAccent` replacing `MapAccent`'s definition, with the map pointing at it.
- Modify `AppModel.refresh()`: it also refreshes the grid that is showing.
- Test: `Tests/SiftKitTests/GridChangesViewTests.swift`, plus additions to `Tests/SiftKitTests/GridCostTests.swift`.

- [ ] **Step 1: write the failing tests**, with the fake source.
  - `theNewestToggleIsHiddenWithoutCandidatesAndShowsThePickerWithTwo`.
  - `clickingNewestSortsAndAHeaderClickTurnsItOff`.
  - `refreshTintsChangedRowsAndCells`: read the cell's `accessibilityValue`s, and check the fill closure's answers for a changed cell, a row cell and an unmarked cell.
  - `theStatusBarSaysChangesSinceTheLookTime`: inject `now` and the time zone; expect `Changes since 10:42:13`.
  - `onlyChangesAndClearWork`.
  - `primaryRRefreshesTheShowingGrid`: `Modifiers.primary`+R through the app command. The map and the structure tab do not refresh a grid.

  Cost (each shown red under a mutation):
  - `anIdleGridWithAHighlightAsksNoFrames`;
  - `aScrollStepAsksTheFillOncePerRealisedCell`: count the fill calls, at most `tableCellsRealized`;
  - `aRefreshRebuildsOnlyTheGridsParts`: the sidebar and the relation header are not rebuilt.
- [ ] **Steps 2–4:** fail, implement, pass.
- [ ] **Step 5: commit** "Landed: newest-first and change highlighting in the grid".

### Task 5: following keys (SiftKit)

**Files:**
- Create `Sources/SiftKit/Grid/ReferenceLinks.swift` (pure).
- Modify:
  - `GridModel.swift`: `links: GridLinks?` and `onFollow`;
  - `DatabaseSession.swift`: it sets `links` and `onFollow` on each grid it makes, from its snapshot, and refreshes `links` when the snapshot changes;
  - `ValueInspector.swift`: the Links section;
  - `GridView.swift`: the context menu, the primary action, the link colour for FK columns, and `ScrollViewReader` with reveal;
  - `AppModel.swift`: `follow(_:in:)`, and setting `session.onFollow` in `makeSession`.
- Test: `Tests/SiftKitTests/ReferenceLinksTests.swift` and `Tests/SiftKitTests/FollowTests.swift`. Add to `Tests/SiftPGTests` one integration test, `followedValuesMatchTheirRow`.

**Interfaces (produced):**
```swift
public struct GridFollow: Equatable, Sendable { public var target: RelationID; public var filters: [GridFilter]; public var title: String; public var targetColumn: Int }
public struct ReferenceLink: Equatable, Sendable { public var foreignKey: ForeignKeyInfo; public var outgoing: Bool; public var follow: GridFollow?   // nil = disabled
                                                   public var title: String }   // "customer_id → customers (id = 42)" / "orders.customer_id (= 42)" / "customer_id is NULL"
public struct GridLinks: Sendable { public init(snapshot: SchemaSnapshot, relation: RelationID)
    public var outgoingColumns: Set<Int> { get }                         // FK columns, for the link colour
    public func links(row: Int, value: (Int) -> SiftValue?) -> [ReferenceLink]
    public func primaryFollow(row: Int, column: Int, value: (Int) -> SiftValue?) -> GridFollow? }
// GridModel: public var links: GridLinks?; @ObservationIgnored public var onFollow: (@MainActor (GridFollow) -> Void)?
// AppModel: public func follow(_ follow: GridFollow, in key: ConnectionKey)
```

- [ ] **Step 1: write the failing tests.**
  - `ReferenceLinksTests`, over the fixture snapshot (`FixtureSnapshot`):
    - `outgoingLinkFiltersTheTargetsKey`;
    - `incomingLinkFiltersTheReferencingColumns`;
    - `aCompositeKeyPairsByPosition` (shipments → order_items);
    - `aNullValueDisablesTheLinkAndSaysSo`;
    - `anUnloadedValueDisablesTheLink`;
    - `aSelfReferenceTargetsTheSameRelation`;
    - `primaryFollowNeedsExactlyOneOutgoingFKOnTheColumn`.
  - `FollowTests`, with UI and the fake connector:
    - `theInspectorListsLinksAndClickingOneOpensTheFilteredTarget`: the selection, the Rows tab, the chip `id = 42`, the active cell at row 0, and a reveal requested;
    - `returnOnAnFKCellFollowsIt`;
    - `doubleClickOnAnFKCellFollowsIt`;
    - `theRowMenuOffersEveryLinkOfOneRowAndNoneForSeveral`;
    - `fkColumnsDrawInTheLinkColour`;
    - `aFollowIntoACheapRecencyTargetKeepsItsNewestFirstSort`.
  - Integration test `followedValuesMatchTheirRow`. For each of `uuid`, `bigint`, a composite key, `text` containing `'` and `%`, and `timestamptz`, then also `numeric` and `bytea` from Task 2's fixture: build the follow from a real page's values, page the target with its filters, and expect exactly the referenced row. The SQL text contains none of the values (Review focus 3).
- [ ] **Steps 2–4:** fail, implement, pass.
- [ ] **Step 5: commit** "Landed: follow foreign keys forward and back".

### Task 6: back and forward (SiftKit)

**Files:**
- Create `Sources/SiftKit/Model/NavigationHistory.swift`.
- Modify `AppModel.swift`: push on relation changes, and add `goBack()`, `goForward()`, `canGoBack` and `canGoForward`.
- Modify `RelationDetailView.swift` (the ‹ › buttons in `RelationHeader`) and `Commands.swift` (Back ⌘[ and Forward ⌘]).
- Test: `Tests/SiftKitTests/NavigationHistoryTests.swift` (pure) and `Tests/SiftKitTests/BackForwardTests.swift`.

**Interfaces (produced):**
```swift
public struct NavigationEntry: Equatable, Sendable { public var key: ConnectionKey; public var relation: RelationID; public var query: GridQuery?; public var active: GridPosition? }
public struct NavigationHistory: Sendable { public static let limit = 100
    public mutating func push(_ leaving: NavigationEntry)
    public mutating func back(from current: NavigationEntry) -> NavigationEntry?
    public mutating func forward(from current: NavigationEntry) -> NavigationEntry?
    public var canGoBack: Bool { get }; public var canGoForward: Bool { get } }
```

- [ ] **Step 1: write the failing tests.**
  - `NavigationHistoryTests`:
    - `pushClearsForward`;
    - `backThenForwardReturns`;
    - `theLimitDropsTheOldest`.
  - `BackForwardTests`:
    - `aSidebarClickAndAFollowBothPush`;
    - `backRestoresTheGridsQueryAndActiveCellAndReveals` (Review focus 4: the full chain from customers to orders to products, then back twice);
    - `backAfterASelfReferenceRestoresTheUnfilteredGrid`;
    - `primaryBracketsGoBackAndForward`;
    - `theButtonsAreDisabledAtTheEnds`;
    - `anEntryWhoseSessionClosedShowsNotInTheSchema`;
    - `backAndForwardDoNotPush`;
    - `aSwitchToTheMapAndBackDoesNotPushTwice`.
- [ ] **Steps 2–4:** fail, implement, pass.
- [ ] **Step 5: commit** "Landed: back and forward".

### Task 7: docs, CI and the PR

- [ ] Update `docs/superpowers/specs/2026-11-18-sift-design.md`:
  - mark phase 5 built, with a pointer to this plan;
  - make sure G17 is in section 11, and add any new gaps from G18;
  - state the change semantics in one line under "Checking what landed": `xmin` since the last look, deletes not shown.
- [ ] Update the README's status section.
- [ ] Leave `METALUI_REF` at the commit the branch built against. Bump it only if you built against a newer one.
- [ ] Run the full `swift test --no-parallel` locally against a `sift-landed-pg` Postgres container, then **delete it**.
- [ ] Push `phase5/landed` and open the PR "Phase 5: checking what landed", based as "Where it runs" says.
- [ ] Get CI green on all three OSes.
- [ ] **Do not merge.** Report the PR, the CI status, the test counts and any MetalUI gaps (G17+), so they can be sent to the MetalUI session.
