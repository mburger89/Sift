import Foundation
import Observation
import SiftCore

/// A cell of the grid: a row's ordinal and a column's index in the source's `columns`.
public struct GridPosition: Hashable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// How a row differs from the previous look: the row was written (`newOrChanged`, no earlier copy to compare with), or
/// it was and these cells (indexes into `columns`) differ from the copy taken at Refresh (possibly none: a no-op update).
public enum RowMark: Equatable, Sendable {
    case newOrChanged
    case changed(cells: Set<Int>)
}

/// The paged rows of one `GridSource`, as `Table` reads them.
///
/// **Reading never queries.** `value(row:column:)` answers from the page cache, or answers nil (the cell draws a
/// placeholder) and asks for the page. The ask is deferred to the next main-actor turn and de-duplicated, so a build
/// never writes observable state. **One query runs at a time:** a count, a page or an exact count. A request for a
/// page nobody is looking at any more is cancelled on the server (`cancelCurrent()`), and every answer carries the
/// generation of the query it was asked under, so a superseded answer never lands.
@Observable @MainActor
// swiftlint:disable:next type_body_length - GridModel is one state machine reviewed as a unit
public final class GridModel {
    // MARK: What the view reads

    public private(set) var count: RowCount = .estimated(0)
    public private(set) var query = GridQuery()
    /// The message of the last failure, or nil.
    public private(set) var error: String?
    /// True when the last failure was the server refusing the filters or the search (bad text for a type, say).
    public private(set) var errorIsFilter = false
    /// True while a count or a page is being fetched, or one is waiting to be.
    public private(set) var isLoading = false
    /// True while an exact count runs.
    public private(set) var isCountingExactly = false
    /// Bumped once for each page that lands, and for each change of query: what the visible cells depend on.
    public private(set) var pagesVersion = 0
    /// Bumped by every `reload` (a query change, `load`, a refresh's re-read) and by a rollback: the rows behind every
    /// position may be other ones. Not bumped when a page lands. What shows one cell's value (the inspector) reads it,
    /// as its position can stay the same while the value under it changes.
    public private(set) var lookVersion = 0
    /// The cell cursor, and the selected row. A position's column is -1 for the frozen row-number column.
    public var activePosition: GridPosition?
    public var selectedRow: Int?
    /// Filters the server refused with the last `apply`; the toolbar shows them on a red chip with `error`.
    public private(set) var rejectedFilters: [GridFilter] = []
    /// The toolbar's form: the filter being written, and the search text (applied on Return, never per keystroke).
    public var draftColumn = 0
    public var draftOp = FilterOp.contains
    public var draftValue = ""
    public var searchText = ""
    /// The time of the look the highlight is relative to; nil when nothing is highlighted.
    public private(set) var changesSince: Date?
    /// The cell a `reveal(_:)` asked the table to scroll to.
    public private(set) var revealRequest: GridPosition?
    /// Counts the reveals: the table scrolls when it changes, even for a cell it was already asked to show.
    public private(set) var revealCount = 0
    /// The foreign keys of this grid's relation, for following them; nil for a result that is not a relation's rows.
    public var links: GridLinks?
    /// Newest-first sorts, one per recency candidate in candidate order; set by the session. Empty hides the toggle.
    public var recencySorts: [GridSort] = []
    public var recencyColumns: [Int] { recencySorts.map(\.column) }
    /// The recency column the toggle starts with: the first cheap candidate, which is not always the first one.
    /// Nil means the first of `recencySorts`.
    public var defaultNewestColumn: Int?
    private var chosenNewestColumn: Int?

    public let source: any GridSource
    public var columns: [ResultColumn] { source.columns }
    public var rows: GridRowRefs { GridRowRefs(count: count.value) }
    public var orderNote: String? { source.orderNote }

    /// Whether the query sorts newest first on one of the recency candidates.
    public var isNewestFirst: Bool {
        guard let sort = query.sort else { return false }
        return recencySorts.contains(sort)
    }

    /// The recency column the toggle sorts by: the one the query sorts by now, else the one chosen, else the default, else the first.
    public var newestColumn: Int? {
        if let sort = query.sort, recencySorts.contains(sort) { return sort.column }
        if let chosen = chosenNewestColumn, recencyColumns.contains(chosen) { return chosen }
        if let preferred = defaultNewestColumn, recencyColumns.contains(preferred) { return preferred }
        return recencySorts.first?.column
    }

    // MARK: Internals

    private enum Work: Equatable {
        case count
        case exactCount
        case page(Int)
        case marker
    }
    private struct InFlight {
        var work: Work
        var serial: Int
    }
    private struct Snapshot {
        var query: GridQuery
        var pages: [Int: [[SiftValue]]]
        var count: RowCount
        var marks: [Int: [RowMark?]]
        var previousMarker: String?
        var previousMarkerTime: Date?
        var changesSince: Date?
        var keyCopy: [[SiftValue]: [SiftValue]]
        var keyCopyServed: Bool
    }
    private struct Read {
        var epoch: Int
        var tick: Int
    }

    @ObservationIgnored private let clock: any SiftClock
    @ObservationIgnored private var pages: [Int: [[SiftValue]]] = [:]
    @ObservationIgnored private var marks: [Int: [RowMark?]] = [:]
    /// Rows by key, copied from the cache when a Refresh is asked and installed when its marker lands: what changed
    /// cells are found against.
    @ObservationIgnored private var keyCopy: [[SiftValue]: [SiftValue]] = [:]
    @ObservationIgnored private var retriedMarkerAfterCancel = false
    /// The copy a pending refresh took, installed with the marker state when its marker lands (so a rollback's snapshot
    /// still holds the copy of the look it goes back to).
    @ObservationIgnored private var pendingKeyCopy: [[SiftValue]: [SiftValue]]?
    /// True once a page has landed under a look the installed copy is older than: a refresh must not keep it.
    @ObservationIgnored private var keyCopyServed = false
    @ObservationIgnored private var markerNeeded: Bool
    /// The marker taken when the grid opened and its look has not landed: a refresh's marker also serves as it.
    @ObservationIgnored private var openMarkerPending: Bool
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private var previousMarker: String?
    @ObservationIgnored private var previousMarkerTime: Date?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var lastRead: [Int: Read] = [:]
    @ObservationIgnored private var wanted: Set<Int> = []
    @ObservationIgnored private var failedPages: Set<Int> = []
    @ObservationIgnored private var retriedAfterCancel: Set<Int> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var inFlight: InFlight?
    @ObservationIgnored private var countNeeded = true
    @ObservationIgnored private var exactNeeded = false
    @ObservationIgnored private var previous: Snapshot?
    @ObservationIgnored private var turnScheduled = false
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var tick = 0
    /// Called when a query fails because the connection is gone: the session starts reconnecting. A grid has a
    /// connection of its own, so the session may not have noticed.
    /// Called when the user follows a key (the inspector, the row menu, Return or a double click on a key cell).
    @ObservationIgnored public var onFollow: (@MainActor (GridFollow) -> Void)?
    @ObservationIgnored public var onConnectionLost: (@MainActor (any Error) -> Void)?
    /// How many times `value(row:column:)` has been asked. For cost tests.
    @ObservationIgnored public private(set) var valueReads = 0

    /// How many cell values the diff against the key copy has compared. For cost tests.
    @ObservationIgnored public private(set) var diffComparisons = 0

    /// Sets the read counter back to zero. For cost tests.
    public func resetReadCount() { valueReads = 0 }

    /// How many times the table asked for a cell's fill (`noteFillRead`). For cost tests.
    @ObservationIgnored public private(set) var fillReads = 0

    /// Counts one ask of the cell fill; the fill itself reads only `mark(row:)`.
    public func noteFillRead() { fillReads += 1 }

    /// Sets the fill counter back to zero. For cost tests.
    public func resetFillReads() { fillReads = 0 }

    public init(
        source: any GridSource, clock: any SiftClock = SystemClock(), initialQuery: GridQuery = GridQuery(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.clock = clock
        self.now = now
        query = initialQuery
        markerNeeded = source.supportsChanges
        openMarkerPending = source.supportsChanges
        isLoading = true
        scheduleTurn()
    }

    // MARK: Reading

    /// The value at `(row, column)`, or nil when its page is not loaded (draw a placeholder). A missing page is
    /// requested once, on the next main-actor turn.
    public func value(row: Int, column: Int) -> SiftValue? {
        // Not a read of `pagesVersion`: this runs while a table lays out, outside any component's body, and an observed
        // read there would make a page landing rebuild whatever is being tracked. The component that shows cells reads
        // `pagesVersion` itself, in its body.
        valueReads += 1
        let size = GridPaging.pageSize
        let page = row / size
        tick += 1
        lastRead[page] = Read(epoch: epoch, tick: tick)
        guard let loaded = pages[page] else {
            if !failedPages.contains(page), !wanted.contains(page) { wanted.insert(page) }
            scheduleTurn()
            return nil
        }
        let index = row - page * size
        guard loaded.indices.contains(index), loaded[index].indices.contains(column) else { return nil }
        return loaded[index][column]
    }

    /// How row `row` differs from the previous look, or nil. O(1), from the page cache; never an observed read.
    public func mark(row: Int) -> RowMark? {
        let size = GridPaging.pageSize
        guard let page = marks[row / size] else { return nil }
        let index = row - (row / size) * size
        guard page.indices.contains(index) else { return nil }
        return page[index]
    }

    /// The pages in the cache, in order. For tests.
    public var cachedPages: [Int] { pages.keys.sorted() }

    // MARK: Changing what is shown

    /// Shows `query`. Pages are dropped and the query in flight is cancelled; a count is asked again only when the
    /// filters or the search changed. If the server refuses the new query, the model goes back to the last good one.
    public func apply(_ query: GridQuery) {
        guard query != self.query else { return }
        reload(query, keepSelection: false)
    }

    /// Shows `query` and reads it again even when it equals the current one (a follow into the same filter twice).
    /// The cursor and the selection are cleared, as `apply` clears them.
    public func load(_ query: GridQuery) {
        reload(query, keepSelection: false, recount: true)
    }

    /// Shows `query` even when it equals the current one, dropping the pages. A refresh keeps the cursor and the
    /// selection (`keepSelection`) and asks for the count again (`recount`).
    ///
    /// **Invariant: `changesSince != nil` exactly when `query.changes != nil`.** The bar and the highlight are one
    /// thing. A query with no `changes` clears `changesSince` and the key copy; an incoming `changes` is dropped when
    /// the grid has no `changesSince` (a follow or Back carrying a filter from a look this grid no longer has). Only a
    /// refresh's own marker starts a look (`startsLook`), and sets `changesSince` right after. Any other incoming `changes`
    /// keeps its `only` and takes the grid's current marker.
    private func reload(_ query: GridQuery, keepSelection: Bool, recount: Bool = false, startsLook: Bool = false) {
        var query = query
        // Taken first: the invariant's own mutations below must not be in what a rollback goes back to.
        if previous == nil { previous = Snapshot(
                query: self.query, pages: pages, count: count, marks: marks, previousMarker: previousMarker,
                previousMarkerTime: previousMarkerTime, changesSince: changesSince, keyCopy: keyCopy,
                keyCopyServed: keyCopyServed) }
        if query.changes == nil {
            changesSince = nil
            keyCopy = [:]
        } else if changesSince == nil, !startsLook {
            query.changes = nil
        } else if !startsLook, var shown = self.query.changes {
            // An incoming filter keeps its `only` but takes this grid's current marker: Back must not put an older
            // look's marker under the newer `changesSince` and key copy.
            shown.only = query.changes?.only ?? shown.only
            query.changes = shown
        }
        retriedMarkerAfterCancel = false
        if inFlight != nil {
            source.cancelCurrent()
            inFlight = nil
        }
        generation += 1
        let narrowed =
            query.filters != self.query.filters || query.search != self.query.search
            || query.changes?.only != self.query.changes?.only || (recount && query.changes?.only == true)
        self.query = query
        resetPages()
        error = nil
        errorIsFilter = false
        if narrowed {
            count = .estimated(GridPaging.pageSize)
            countNeeded = true
            exactNeeded = false
            isCountingExactly = false
        } else if recount {
            countNeeded = true
            // A refresh's recount may only get an estimate (a big table), which never replaces an exact count: the
            // exact one from before the refresh is stale, so it stops claiming to be exact.
            if keepSelection, count.isExact { count = .estimated(count.value) }
        }
        if !keepSelection {
            selectedRow = nil
            activePosition = nil
        }
        rejectedFilters = []
        pagesVersion += 1
        lookVersion += 1
        isLoading = true
        scheduleTurn()
    }

    // MARK: Newest first

    public func setNewestFirst(_ on: Bool) { sortNewest(on, column: newestColumn) }

    /// Chooses the column the toggle sorts by, and sorts by it.
    public func setNewestColumn(_ column: Int) {
        guard recencyColumns.contains(column) else { return }
        chosenNewestColumn = column
        sortNewest(true, column: column)
    }

    private func sortNewest(_ on: Bool, column: Int?) {
        var next = query
        if on {
            guard let column, let sort = recencySorts.first(where: { $0.column == column }) else { return }
            next.sort = sort
        } else {
            next.sort = nil
        }
        apply(next)
    }

    // MARK: Refresh and change marks

    /// Looks again. With a source that can flag changes, takes a marker first and then reads with the changes since
    /// the previous one; otherwise it only reads the same query again.
    public func refresh() {
        guard source.supportsChanges else {
            reload(query, keepSelection: true, recount: true)
            return
        }
        pendingRefresh = true
        markerNeeded = true
        // The copy is the last look's rows: taken now, while the pages are still those (a sort while the marker is
        // out drops them). A second refresh copies again, unless nothing is cached to copy.
        retriedMarkerAfterCancel = false
        copyKeys()
        if inFlight != nil {
            source.cancelCurrent()
            inFlight = nil
        }
        generation += 1
        isLoading = true
        scheduleTurn()
    }

    /// Keeps only the changed rows (or all of them again). Does nothing without a highlight.
    public func setOnlyChanges(_ on: Bool) {
        guard var changes = query.changes else { return }
        changes.only = on
        var next = query
        next.changes = changes
        apply(next)
    }

    /// Drops the highlight. The marker is kept, so the next Refresh still shows everything since the last look.
    public func clearChanges() {
        let wasPending = pendingRefresh
        pendingRefresh = false
        markerNeeded = openMarkerPending
        keyCopy = [:]
        pendingKeyCopy = nil
        changesSince = nil
        if wasPending, !markerNeeded, inFlight?.work == .marker {
            source.cancelCurrent()
            inFlight = nil
            generation += 1
        }
        var next = query
        next.changes = nil
        if next != query { apply(next) } else { scheduleTurn() }
    }

    /// A cursor on a row that does not exist (a follow into an empty result) is dropped once the count is exact. An
    /// estimate never drops it: it is a guess, and the placeholder one is only there while a count is out.
    private func dropCursorPastCount() {
        guard count.isExact, let active = activePosition, active.row >= count.value else { return }
        activePosition = nil
        if let selected = selectedRow, selected >= count.value { selectedRow = nil }
    }

    public func reveal(_ position: GridPosition) {
        activePosition = position
        revealRequest = position
        revealCount += 1
    }

    /// The values of the key columns that identify a row across looks, nil when there are none or one is out of range.
    private func key(of row: [SiftValue], _ keys: [Int]) -> [SiftValue]? {
        guard !keys.isEmpty, keys.allSatisfy({ row.indices.contains($0) }) else { return nil }
        return keys.map { row[$0] }
    }

    private func copyKeys() {
        let keys = source.keyColumns
        guard !keys.isEmpty else { return }
        guard !pages.isEmpty else {
            // Nothing cached (a sort dropped it): keep what an earlier refresh of this one took, unless a look has landed
            // since the installed copy, which then is one look stale.
            pendingKeyCopy = pendingKeyCopy ?? (keyCopyServed ? [:] : keyCopy)
            return
        }
        var copy: [[SiftValue]: [SiftValue]] = [:]
        for rows in pages.values {
            for row in rows { if let k = key(of: row, keys) { copy[k] = row } }
        }
        pendingKeyCopy = copy
    }

    // MARK: The toolbar's actions

    /// Adds the filter in the form as a chip and applies it. A filter that needs a value and has none is ignored.
    public func addDraftFilter() {
        guard columns.indices.contains(draftColumn) else { return }
        if draftOp.takesValue, draftValue.isEmpty { return }
        var next = query
        next.filters.append(GridFilter(column: draftColumn, op: draftOp, value: draftOp.takesValue ? draftValue : nil))
        draftValue = ""
        apply(next)
    }

    public func removeFilter(at index: Int) {
        guard query.filters.indices.contains(index) else { return }
        var next = query
        next.filters.remove(at: index)
        apply(next)
    }

    /// Drops the red chip of a refused filter, and its message.
    public func dismissRejectedFilters() {
        rejectedFilters = []
        if errorIsFilter {
            error = nil
            errorIsFilter = false
        }
    }

    /// Applies the search text: the Return key. An empty text clears the search.
    public func submitSearch() {
        var next = query
        next.search = searchText.isEmpty ? nil : searchText
        apply(next)
    }

    /// The text of a chip: `name = value`.
    public func chipTitle(_ filter: GridFilter) -> String {
        let name = columns.indices.contains(filter.column) ? columns[filter.column].name : "?"
        return filter.op.takesValue ? "\(name) \(filter.op.title) \(filter.value ?? "")" : "\(name) \(filter.op.title)"
    }

    /// Asks again for what failed.
    public func retry() {
        error = nil
        errorIsFilter = false
        failedPages = []
        scheduleTurn()
    }

    /// Counts the rows exactly. The status bar offers this when the count is only an estimate.
    public func countExactly() {
        guard !isCountingExactly else { return }
        exactNeeded = true
        isCountingExactly = true
        scheduleTurn()
    }

    /// Stops an exact count in flight or waiting.
    public func cancelExactCount() {
        exactNeeded = false
        isCountingExactly = false
        if inFlight?.work == .exactCount {
            source.cancelCurrent()
            inFlight = nil
            scheduleTurn()
        }
    }

    /// Cancels what is running and releases the source.
    public func close() {
        generation += 1
        if inFlight != nil { source.cancelCurrent() }
        inFlight = nil
        source.close()
    }

    private func resetPages() {
        pages = [:]
        marks = [:]
        lastRead = [:]
        wanted = []
        failedPages = []
        retriedAfterCancel = []
    }

    // MARK: The turn: one deferred step per main-actor turn

    private func scheduleTurn() {
        guard !turnScheduled else { return }
        turnScheduled = true
        Task { @MainActor [weak self] in self?.turn() }
    }

    private func turn() {
        turnScheduled = false
        epoch += 1
        pump()
    }

    /// The pages read in the latest build that are not loaded.
    private func missingVisiblePages() -> [Int] {
        wanted.filter { pages[$0] == nil && !failedPages.contains($0) && (lastRead[$0]?.epoch ?? -2) >= epoch - 1 }.sorted()
    }

    private func isVisible(_ page: Int) -> Bool { (lastRead[page]?.epoch ?? -2) >= epoch - 1 }

    private func pump() {
        let missing = missingVisiblePages()
        wanted = Set(missing)
        if let flying = inFlight, case .page(let page) = flying.work, !missing.contains(page) {
            // Nobody is looking at that page any more: stop it on the server.
            source.cancelCurrent()
            inFlight = nil
        }
        if inFlight == nil {
            if markerNeeded {
                start(.marker)
            } else if exactNeeded {
                start(.exactCount)
            } else if countNeeded {
                start(.count)
            } else if let next = missing.first {
                start(.page(next))
            }
        }
        let busy = inFlight != nil || markerNeeded || countNeeded || !missing.isEmpty
        if isLoading != busy { isLoading = busy }
    }

    private func start(_ work: Work) {
        serial += 1
        let mine = serial
        let mineGeneration = generation
        let query = self.query
        inFlight = InFlight(work: work, serial: mine)
        isLoading = true
        let source = self.source
        let after: [SiftValue]? = {
            if case .page(let page) = work, page > 0 { return pages[page - 1]?.last }
            return nil
        }()
        Task { @MainActor [weak self] in
            do {
                switch work {
                case .count:
                    let count = try await source.count(for: query)
                    self?.countArrived(count, generation: mineGeneration, serial: mine)
                case .exactCount:
                    let n = try await source.exactCount(for: query)
                    self?.countArrived(.exact(n), generation: mineGeneration, serial: mine)
                case .page(let page):
                    let rows = try await source.page(page, size: GridPaging.pageSize, query: query, after: after)
                    self?.pageArrived(page, rows, generation: mineGeneration, serial: mine)
                case .marker:
                    let marker = try await source.changeMarker()
                    self?.markerArrived(marker, generation: mineGeneration, serial: mine)
                }
            } catch {
                self?.failed(error, work: work, generation: mineGeneration, serial: mine)
            }
        }
    }

    // MARK: Answers

    /// Ends the request `serial` and answers whether its answer is still wanted: it was not superseded by a new query
    /// (`generation`) and not cancelled or replaced by the pump (`inFlight`).
    private func finish(serial mine: Int, generation answered: Int) -> Bool {
        let current = inFlight?.serial == mine
        if current { inFlight = nil }
        return current && answered == generation
    }

    private func countArrived(_ new: RowCount, generation mine: Int, serial mineSerial: Int) {
        let wasExact = inFlight?.work == .exactCount && inFlight?.serial == mineSerial
        guard finish(serial: mineSerial, generation: mine) else { return pump() }
        previous = nil
        if wasExact {
            exactNeeded = false
            isCountingExactly = false
        } else {
            countNeeded = false
        }
        // A count that cannot be bettered than what the pages already proved is kept: never shrink an exact count.
        if !(count.isExact && !new.isExact) { count = new }
        dropCursorPastCount()
        pagesVersion += 1
        pump()
    }

    private func markerArrived(_ marker: String, generation mine: Int, serial mineSerial: Int) {
        guard finish(serial: mineSerial, generation: mine) else { return pump() }
        let taken = now()
        markerNeeded = false
        openMarkerPending = false
        retriedMarkerAfterCancel = false
        let earlier = previousMarker
        let earlierTime = previousMarkerTime
        guard pendingRefresh else {
            previousMarker = marker
            previousMarkerTime = taken
            // A rollback must not drop the opening marker.
            previous?.previousMarker = marker
            previous?.previousMarkerTime = taken
            return pump()
        }
        pendingRefresh = false
        var next = query
        if let earlier {
            next.changes = ChangeFilter(since: earlier, only: query.changes?.only ?? false)
        } else {
            next.changes = nil
        }
        let copy = earlier == nil ? [:] : (pendingKeyCopy ?? [:])
        pendingKeyCopy = nil
        // The reload snapshots the state a rollback goes back to: the marker state is advanced after it.
        reload(next, keepSelection: true, recount: true, startsLook: true)
        changesSince = earlier == nil ? nil : earlierTime
        keyCopy = copy
        keyCopyServed = false
        previousMarker = marker
        previousMarkerTime = taken
    }

    private func pageArrived(_ page: Int, _ landed: [[SiftValue]], generation mine: Int, serial mineSerial: Int) {
        guard finish(serial: mineSerial, generation: mine) else { return pump() }
        previous = nil
        var rows = landed
        if query.changes != nil { keyCopyServed = true }
        var pageMarks: [RowMark?] = []
        if query.changes != nil, source.supportsChanges {
            pageMarks.reserveCapacity(rows.count)
            let keys = source.keyColumns
            for index in rows.indices {
                // A row has the flag only when it is wider than the columns (a `ctid` may follow them, the flag is last).
                var flagged = false
                if rows[index].count > columns.count, case .bool(let flag)? = rows[index].last {
                    flagged = flag
                    rows[index].removeLast()
                }
                pageMarks.append(flagged ? markFor(rows[index], keys) : nil)
            }
        }
        pages[page] = rows
        marks[page] = pageMarks.isEmpty ? nil : pageMarks
        wanted.remove(page)
        let size = GridPaging.pageSize
        if rows.count < size {
            count = .exact(page * size + rows.count)
        } else if !count.isExact, (page + 1) * size >= count.value {
            count = .estimated((page + 2) * size)
        }
        dropCursorPastCount()
        evict()
        pagesVersion += 1
        pump()
    }

    /// The mark of a flagged row: the cells that differ from the copy of the same key, or a row mark without one.
    private func markFor(_ row: [SiftValue], _ keys: [Int]) -> RowMark {
        guard let k = key(of: row, keys), let old = keyCopy[k] else { return .newOrChanged }
        var cells = Set<Int>()
        for c in 0..<columns.count where old.indices.contains(c) && row.indices.contains(c) {
            diffComparisons += 1
            if old[c] != row[c] { cells.insert(c) }
        }
        return .changed(cells: cells)
    }

    // swiftlint:disable:next function_body_length - the generation checks of the failure path stay in one place
    private func failed(_ error: any Error, work: Work, generation mine: Int, serial mineSerial: Int) {
        // A failure nobody waits for (we cancelled it, or a newer query replaced it) is dropped.
        guard finish(serial: mineSerial, generation: mine) else { return pump() }
        if let source = error as? SourceError, source.kind == .cancelled {
            // Still wanted and cancelled: the server's own timeout, or a cancel signal that outlived its target and
            // hit this query. A page is asked for once more before it is reported.
            if case .page(let page) = work, retriedAfterCancel.insert(page).inserted {
                wanted.insert(page)
                return pump()
            }
        }
        if case .marker = work {
            if let cancelled = error as? SourceError, cancelled.kind == .cancelled, !retriedMarkerAfterCancel {
                // A stray cancel signal: ask once more before the marker counts as failed.
                retriedMarkerAfterCancel = true
                return pump()
            }
            retriedMarkerAfterCancel = false
            // A marker that fails never blocks reading. On open there is no previous marker; on a refresh the old one
            // is kept (so the next refresh still covers everything since it) and the rows are read plain.
            markerNeeded = false
            openMarkerPending = false
            if let lost = error as? SourceError, lost.kind == .connectionLost { onConnectionLost?(error) }
            if pendingRefresh {
                pendingRefresh = false
                keyCopy = [:]
                pendingKeyCopy = nil
                changesSince = nil
                var next = query
                next.changes = nil
                reload(next, keepSelection: true, recount: true)
            } else {
                pump()
            }
            return
        }
        let message = Self.describe(error)
        var filterRefusal = false
        if let source = error as? SourceError, case .server = source.kind { filterRefusal = previous != nil }
        if filterRefusal, let good = previous {
            // The server refused the new filters: show the last good rows again, with the reason.
            previous = nil
            generation += 1
            rejectedFilters = query.filters.filter { !good.query.filters.contains($0) }
            let narrowedDifferently = !rejectedFilters.isEmpty || query.search != good.query.search
            query = good.query
            pages = good.pages
            marks = good.marks
            previousMarker = good.previousMarker
            previousMarkerTime = good.previousMarkerTime
            changesSince = good.changesSince
            keyCopy = good.keyCopy
            keyCopyServed = good.keyCopyServed
            count = good.count
            lastRead = [:]
            wanted = []
            failedPages = []
            countNeeded = false
            exactNeeded = false
            isCountingExactly = false
            self.error = message
            errorIsFilter = narrowedDifferently
            pagesVersion += 1
            lookVersion += 1
            return pump()
        }
        self.error = message
        errorIsFilter = false
        if let lost = error as? SourceError, lost.kind == .connectionLost { onConnectionLost?(error) }
        switch work {
        case .page(let page): failedPages.insert(page)
        case .count: countNeeded = false
        case .exactCount:
            exactNeeded = false
            isCountingExactly = false
        case .marker: break
        }
        pump()
    }

    private func evict() {
        while pages.count > GridPaging.cachedPages {
            // The least recently read page that nobody is looking at.
            let victim = pages.keys.filter { !isVisible($0) }.min { (lastRead[$0]?.tick ?? -1) < (lastRead[$1]?.tick ?? -1) }
            guard let victim else { return }
            pages[victim] = nil
            marks[victim] = nil
            lastRead[victim] = nil
        }
    }

    nonisolated static func describe(_ error: any Error) -> String {
        if let error = error as? SourceError { return error.message }
        return String(describing: error)
    }
}
