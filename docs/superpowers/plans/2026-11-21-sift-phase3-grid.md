# Sift phase 3: grid browsing — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** replace the 100-row preview with a real grid. It browses a whole relation of any size through MetalUI's `Table`: server-side paging, sort, filter and search, type-aware cells, and a cell cursor with a value inspector.

**Architecture:**
- A UI-free `GridSource` protocol in `SiftCore`: columns, a row count, and pages fetched by index. `PGRelationPager` in `SiftPG` implements it with keyset paging over a stable order, and an OFFSET fallback for jumps.
- `SiftKit` holds a `GridModel` (`@Observable`, main actor). It keeps an LRU of pages and exposes a `RandomAccessCollection` of lightweight row handles to `Table`. A read of a row whose page is missing returns a placeholder and schedules the fetch, never a synchronous query.
- Phases 4 (SQL results) and 6 (SQLite and CSV) implement the same `GridSource`.

**Tech stack:** Swift 6.4, MetalUI at master `dc52cd37`, which has `Table` (TBL-), cell mode (TCM-) and SecureField. Also libpq, swift-testing and MetalUITesting.

**Spec:** `docs/superpowers/specs/2026-11-18-sift-design.md`: the Grid goal, "Read-only by default", and the phase 3 line. The MetalUI contracts used are in `../MetalUI/docs/superpowers/2026-11-18-table-decisions.md` (TBL-D, the row source: only realised rows are read; TBL-N selection; TBL-Q sort; TBL-Z scrollTo) and `../MetalUI/docs/superpowers/specs/2026-11-20-table-cell-mode-design.md`.

## Global constraints

- **MetalUI version:** bump `METALUI_REF` in `.github/workflows/ci.yml` to `dc52cd379709fed3e884d6830e03a30b9aa3d5b9`. Local worktrees use `~/Developer/worktrees/Sift/MetalUI`, which is already checked out at that commit, as `../MetalUI`.
- **Read-only:** every grid query runs through `PGConnection.executeInReadOnlyTransaction` with `statementTimeout: "15s"`. No grid code writes to a database.
- **No user text in SQL:** identifiers go through `PGIdentifier.quote`. Values are always bound parameters (`$n`). Filter operators come from a closed enum.
- **One query in flight per grid:** a new request (scroll jump, sort, filter, search) supersedes the old one. Call `cancelCurrent()` on the old one and drop its result by generation number. A superseded answer never lands.
- **No O(rows) work on the main actor:** the grid touches only realised rows (TBL-D). Count the reads in tests.
- **Passwords:** none in logs, errors or test output (existing rule).
- **Off-Darwin test pitfalls:**
  - use `runUntilIdle()`;
  - sum `frameWork`;
  - use `Modifiers.primary`.
- **CI:** the job must stay green on macOS, Linux and Windows. Keep the Windows `-Xcc -D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH` flag.

## Decisions (coordinator's calls, numbered after phase 2's D-series: continue from the last `D` in the phase-2 plan)

- **Paging:**
  - 500 rows per page.
  - Order by the primary key. With no primary key, use the first unique index whose columns are all NOT NULL. Failing that, use `ctid`, and show the note "no stable key: rows may shift".
  - A page whose previous page is loaded uses keyset: `WHERE (k1,k2) > ($1,$2) ORDER BY k1,k2 LIMIT 500`. Any other page uses `OFFSET p*500 LIMIT 500`.
  - Under a user sort, the order is `(sortcol, key…)`, and keyset uses the same tuple. NULLs sort with an explicit `NULLS LAST` for ascending and `NULLS FIRST` for descending, so the keyset comparison stays correct; nullable sort columns use OFFSET only.
- **Page cache:** an LRU of 40 pages (20 000 rows). A page is evicted only when no realised row needs it.
- **Row count:**
  - Start from the catalog estimate.
  - If the estimate is under 1 000 000, run `SELECT count(*)` with a 2-second timeout. If it finishes, the count is exact.
  - Otherwise the count stays estimated, and the status bar shows "≈ N rows · Count exactly", which uses the existing `countExactly`.
  - A page that comes back short fixes the count at its true end.
  - A page that comes back full when it was the last estimated page grows the count by one page. This repeats until a short page arrives.
- **Placeholder rows:** a row whose page is not loaded draws its cells as a faint "…". The row's id is its absolute ordinal, so `tableRowIndex { $0.ordinal }` is O(1).
- **Sort:**
  - A header click sets `sortOrder` (TBL-Q). The model re-queries from page 0 and keeps the scroll at the top.
  - Only columns whose type has a btree ordering are sortable. A `json` or `xml` column gets no comparator, so its header click does nothing (TBL-Q's rule).
- **Filter:**
  - One row of chips above the grid. Each chip is (column, operator, value).
  - Operators, as a closed enum: `=`, `≠`, `<`, `≤`, `>`, `≥`, `contains` (ILIKE `%v%`, with `\`-escaping of `%_\`), `starts with`, `is null`, `is not null`.
  - Chips are ANDed.
  - The value is bound as text, then cast with `$n::<column type>`. An `invalid_text_representation` error shows on the chip, not as a failure of the grid.
- **Search:**
  - A field in the toolbar. ⌘F (`Modifiers.primary`+F) focuses it.
  - The query is `WHERE (c1::text ILIKE $1 OR c2::text ILIKE $1 …)` over the visible columns. It runs only on Return, never per keystroke.
  - The status bar warns "full scan" when the relation has more than 1 M estimated rows.
- **Cells:** a cell is read-only `Text`, single line and truncated (TBL-K).

  | value | drawn as |
  |---|---|
  | NULL | italic `NULL` in the tertiary colour; never confused with an empty string |
  | empty text | nothing, plus a faint `""` marker when the column is text-like |
  | numbers | right-aligned (`TableColumnAlignment.trailing`); numeric keeps the server's exact text |
  | bool | `true`/`false` |
  | uuid | monospaced |
  | timestamptz | parsed from the server's ISO text and shown in the local time zone, as `yyyy-MM-dd HH:mm:ss` plus the zone abbreviation; the full value is in the inspector |
  | jsonb, json | compact one-line text, truncated |
  | arrays | Postgres literal text |
  | enum | its label with a subtle capsule background |
  | bytea | `\x…` plus the byte count |
- **Cursor and inspector:**
  - The grid uses MetalUI cell mode, `tableActiveCell`.
  - A trailing inspector shows the active cell's column (name and type) and its full value: JSON pretty-printed with expandable objects and arrays, long text wrapped, and NULL shown as NULL.
  - No `tableCellEditing` (phase 7).
  - ⌘C (`Modifiers.primary`+C) copies the active cell's raw text. This uses MetalUI's clipboard.
- **Frozen row number:** a "#" column showing the 1-based ordinal is frozen with `tableFrozenColumns(1)`.
- **Hidden columns:** none in phase 3. All columns show; MetalUI's two-axis windowing handles hundreds.

## Review focus (most likely to bite first)

1. **A stale page lands after a sort, filter or search change:** the rows from the old order appear briefly, or permanently, in the new view. Pin it with a fake source whose answers are delayed and reordered.
2. **The count drifts on a huge table:** the user scrolls to the estimated end and sees blank or placeholder rows forever, or a short page doesn't shrink the count. Pin both directions.
3. **A cell or filter value reaches SQL unbound:** a value containing `'`, `$1`, `%`, `_` or `\` must still be passed as a parameter and match literally. Test the filter builder's SQL text and params as pure functions.
4. **A main-actor stall on a jump:** End on a 10 M-row fake reads at most one window of rows and issues exactly one OFFSET fetch.
5. **Cancel:** a superseded query must actually be cancelled on the server. The integration test runs `pg_sleep` and checks `pg_stat_activity`.

---

### Task 1: `GridSource` and the pure SQL builders (SiftCore, SiftPG)

**Files:**
- Create: `Sources/SiftCore/GridSource.swift`, `Sources/SiftPG/PGRelationQuery.swift`
- Test: `Tests/SiftCoreTests/GridSourceTests.swift`, `Tests/SiftPGTests/PGRelationQueryTests.swift`

**Interfaces (produced):**
```swift
public struct GridSort: Sendable, Equatable { public var column: Int; public var ascending: Bool }
public enum FilterOp: String, Sendable, CaseIterable { case eq, ne, lt, le, gt, ge, contains, startsWith, isNull, isNotNull }
public struct GridFilter: Sendable, Equatable { public var column: Int; public var op: FilterOp; public var value: String? }
public struct GridQuery: Sendable, Equatable { public var sort: GridSort?; public var filters: [GridFilter]; public var search: String? }
public enum RowCount: Sendable, Equatable { case exact(Int); case estimated(Int) }
public protocol GridSource: AnyObject, Sendable {
    var columns: [ResultColumn] { get }
    func count(for query: GridQuery) async throws -> RowCount
    /// `after`: the last row of page index-1 when it is loaded (keyset), else nil (offset).
    func page(_ index: Int, size: Int, query: GridQuery, after: [SiftValue]?) async throws -> [[SiftValue]]
    func cancelCurrent()
}
public struct PGRelationQuery {   // pure: SQL text + params, no I/O
    public init(relation: RelationInfo, orderKey: [Int], keyKind: OrderKeyKind)
    public func pageSQL(index: Int, size: Int, query: GridQuery, after: [SiftValue]?) -> (sql: String, params: [String?])
    public func countSQL(query: GridQuery) -> (sql: String, params: [String?])
    public static func orderKey(for relation: RelationInfo) -> (columns: [Int], kind: OrderKeyKind)   // pk, unique-not-null, ctid
}
public enum OrderKeyKind: Sendable, Equatable { case primaryKey, uniqueNotNull, ctid }
```

- [ ] **Step 1: write the failing tests.**
  - `orderKeyPrefersThePrimaryKeyThenAUniqueNotNullIndexThenCtid`
  - `aFirstPageUsesNoOffsetAndOrdersByTheKey`: the SQL contains `ORDER BY "id" LIMIT 500` and no `OFFSET`.
  - `aPageAfterALoadedPageUsesKeyset`: the SQL has `WHERE ("a","b") > ($1,$2)`, and params `["7","x"]`.
  - `aJumpUsesOffset`: page 40 gives `OFFSET 20000`.
  - `aUserSortAppendsTheKeyAsATieBreaker`: `ORDER BY "name" DESC NULLS FIRST, "id" DESC`.
  - `aNullableSortColumnNeverUsesKeyset`
  - `filterValuesAreAlwaysBound`, over the values `"'; drop table x; --"`, `"$1"`, `"50%_\\"`: every value appears only in the params. `contains` escapes `%`, `_` and `\` and adds `ESCAPE '\'`.
  - `castsUseTheColumnsType`: `$1::timestamptz`.
  - `searchORsEveryColumnCastToText`
  - `identifiersAreQuoted`: a column named `we"ird`.
  - `aJsonColumnHasNoSortComparator`
- [ ] **Step 2:** run `swift test --filter 'PGRelationQueryTests|GridSourceTests'`. Expect FAIL: not defined.
- [ ] **Step 3:** implement both files. `GridSource` lives in SiftCore with no libpq import.
- [ ] **Step 4:** run the tests. Expect PASS.
- [ ] **Step 5:** commit "Grid: GridSource and the relation SQL builder".

### Task 2: `PGRelationPager` (SiftPG), with integration tests

**Files:**
- Create: `Sources/SiftPG/PGRelationPager.swift`
- Test: `Tests/SiftPGTests/PGRelationPagerTests.swift`. These use `SIFT_PG_URL` through `PGFixture` and skip when there is no server, as the existing SiftPG integration tests do. The fixture DDL creates a 20 000-row table (pk), a table with no pk and no unique index, a table with a jsonb, an enum, a uuid and a timestamptz column, and a 1 000-row table with nullable sort columns.

**Interfaces:**
- Consumes: Task 1, and `PGConnection.executeInReadOnlyTransaction`.
- Produces: `public final class PGRelationPager: GridSource`, with `init(connection: PGConnection, relation: RelationInfo)`. `DatabaseSession` gains `public func gridSource(for: RelationID) -> (any GridSource)?`. It uses a **second** `PGConnection` per open grid, so cancelling a grid never cancels a schema refresh; the connection closes with the session.

- [ ] **Step 1: write the failing tests.**
  - `pagingThroughAllRowsReturnsEachRowOnceInKeyOrder`: 40 pages, mixing keyset and offset.
  - `keysetAndOffsetAgreeOnTheSamePage`
  - `aSortedPageIsOrderedWithTheKeyAsTieBreaker`
  - `filtersMatchLiterallyIncludingPercentAndQuote`
  - `aBadFilterValueThrowsInvalidTextRepresentation`: the sqlState is `22P02`.
  - `aCountUnderTheThresholdIsExact`
  - `cancelStopsTheServerQuery`: start a page over `pg_sleep`, call `cancelCurrent()`, and check `pg_stat_activity` has no active query from that backend pid within 2 s.
  - `aCtidTableStillPagesAllRows`
- [ ] **Step 2:** run them against the CI Postgres or a local one. Expect FAIL.
- [ ] **Step 3:** implement. Decode with `PGOID.decode`, and add OIDs where needed: `timestamp` 1114, `date` 1082, `int4[]`. Enum detection comes from `ColumnInfo.isEnum`.
- [ ] **Step 4:** run them. Expect PASS. Clean up any Docker container you started for this.
- [ ] **Step 5:** commit "Grid: the Postgres relation pager".

### Task 3: `GridModel` (SiftKit, UI-free logic)

**Files:**
- Create: `Sources/SiftKit/Grid/GridModel.swift`, `Sources/SiftKit/Grid/GridRows.swift`
- Create: `Sources/SiftTestSupport/FakeGridSource.swift`. It generates rows from the ordinal, has a configurable count and per-call latency, records its calls, and lets a test hold and release individual answers in any order.
- Test: `Tests/SiftKitTests/GridModelTests.swift`

**Interfaces:**
```swift
@Observable @MainActor public final class GridModel {
    public init(source: any GridSource, clock: any SiftClock)
    public private(set) var count: RowCount
    public var query: GridQuery { get }          // set via apply(_:), which resets pages and bumps generation
    public func apply(_ query: GridQuery)
    public var rows: GridRows { get }            // RandomAccessCollection<GridRow>, count = count.value
    public func value(row: Int, column: Int) -> SiftValue?   // nil = page not loaded (placeholder)
    public private(set) var error: String?
    public private(set) var isLoading: Bool
}
public struct GridRow: Identifiable, Hashable { public let ordinal: Int; public var id: Int { ordinal } }
```
- A `GridRows` subscript is pure. It returns `GridRow(ordinal:)`. The data reads happen in cell content through `value(row:column:)`. When that finds a page missing, it calls `requestPage(_:)`, which **defers** the fetch to the next main-actor turn and de-duplicates it. It never writes observable state during a build.
- A page arriving writes one observable `pagesVersion` bump, so only the visible cells rebuild.

- [ ] **Step 1: write the failing tests.**
  - `readingAMissingRowRequestsItsPageOnceAndDrawsAPlaceholder`
  - `aBuildNeverWritesObservableState`: wrap a read in `withObservationTracking` with no write.
  - `aJumpToTheEndOf10MFetchesOnePage`: 1 call, offset 19 999.
  - `aStalePageAfterApplyIsDropped`: hold page 0 under the old query, apply a sort, release it; its rows never show.
  - `aShortPageFixesTheCount`
  - `aFullLastEstimatedPageGrowsTheCount`
  - `theLRUKeepsAtMost40PagesAndNeverEvictsAVisibleOne`
  - `applyCancelsTheInFlightQuery`
  - `aFilterErrorIsReportedWithoutClearingTheGrid`
- [ ] **Step 2:** run them. Expect FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** run them. Expect PASS.
- [ ] **Step 5:** commit "Grid: the paged model".

### Task 4: cell rendering and formatting

**Files:**
- Create: `Sources/SiftKit/Formatting/CellFormat.swift`. It is pure: `SiftValue` plus `ResultColumn` give a `CellText` with text, style (`.null`, `.empty`, `.number`, `.mono`, `.enumLabel`, `.plain`) and alignment.
- Create: `Sources/SiftKit/Grid/GridCell.swift`, the `Text` with styling.
- Test: `Tests/SiftKitTests/CellFormatTests.swift`

- [ ] **Step 1: write the failing tests.** One per row of the cell table in Decisions, and also:
  - `nullAndEmptyStringAreDistinct`
  - `timestamptzIsShownInTheGivenTimeZone`: inject the `TimeZone`; `2026-11-21 10:00:00+00` in `America/Los_Angeles` gives `2026-11-21 02:00:00 PST`.
  - `numericKeepsItsExactText`: `12345678901234567890.0001`.
  - `byteaShowsHexAndLength`
  - `jsonIsCompactedToOneLine`
- [ ] **Steps 2–4:** fail, implement, pass.
- [ ] **Step 5:** commit "Grid: cell formatting".

### Task 5: `GridView` on MetalUI `Table`, toolbar, status bar, inspector

**Files:**
- Create: `Sources/SiftKit/Grid/GridView.swift`, `GridToolbar.swift` (filter chips and the search field), `GridStatusBar.swift`, `ValueInspector.swift`. The inspector's JSON tree uses `DisclosureGroup`.
- Modify: `Sources/SiftKit/Views/Detail/RelationDetailView.swift`. The "Rows" tab shows `GridView`. Delete `PreviewSection.swift` and its tests once nothing uses them. Keep `previewRowLimit` only if something else needs it; otherwise remove it.
- Test: `Tests/SiftKitTests/GridViewTests.swift`, `Tests/SiftKitTests/GridCostTests.swift`

**Shape:**
- `Table(model.rows, selection:, sortOrder:)` with the columns built as follows:
  - a frozen `TableColumn("#")`;
  - `TableColumnForEach(0..<columns.count)`, each `.width(min: 60, ideal: 160, max: 600)`, with a sort comparator only when the column is sortable;
  - `.tableFrozenColumns(1)`;
  - `.tableRowIndex { $0 }`;
  - `.tableActiveCell($active)`.
- The sort binding maps to `GridQuery.sort`.

- [ ] **Step 1: write the failing tests** with `MetalUITesting` and the fake source. Find cells by `accessibilityIdentifier("grid.cell.<row>.<col>")`.
  - `theGridShowsTheFirstWindowAndPlaceholdersUntilPagesArrive`
  - `aHeaderClickSortsOnTheServer`: the fake records `GridSort(column: 2, ascending: true)`, then a second click gives descending.
  - `aFilterChipAppliesAndItsErrorShowsOnTheChip`
  - `searchRunsOnReturnNotPerKeystroke`
  - `theInspectorShowsTheActiveCellsFullValueAndPrettyJSON`
  - `primaryCCopiesTheActiveCellsRawText`
  - `endJumpsToTheLastRowAndLoadsOnePage`
  - `nullIsDrawnDistinctly`

  **Cost tests** (`GridCostTests`), each shown red under a mutation:
  - `anIdleGridAsksNoFrames`
  - `aScrollStepRealisesOnlyTheWindow`: `tableRowsRealized` ≤ 30, and `value(row:column:)` reads ≤ the window × visible columns.
  - `aPageArrivingRebuildsOnlyTheTable`: the sidebar and toolbar are not rebuilt.
  - `aSiblingRedrawDoesNotRebuildAnUnfocusedGrid`: a sidebar spinner ticking costs 0 table rows (MetalUI's retained replay, record 394's fix).
- [ ] **Steps 2–4:** fail, implement, pass.
- [ ] **Step 5:** commit "Grid: the view, toolbar, status bar and inspector".

### Task 6: CI bump, docs and closeout

- [ ] **CI:** bump `METALUI_REF` in `.github/workflows/ci.yml` to `dc52cd379709fed3e884d6830e03a30b9aa3d5b9`.
- [ ] **Spec:** update `docs/superpowers/specs/2026-11-18-sift-design.md`. Mark phase 3 built, and list any MetalUI gaps found, in the "fix in MetalUI, never hack around" style, in a new section 11 table, as the phase-2 plan does.
- [ ] **Full suite:** run `swift test --no-parallel` locally (macOS). Use a local Postgres for the SiftPG integration tests: an OrbStack container you create and **delete afterwards**, together with its image if you pulled it.
- [ ] **PR and CI:** push and open the PR "Phase 3: grid browsing". Get CI green on all three OSes.
- [ ] **Do not merge.** Report the PR, CI status, test counts and any MetalUI gaps.
