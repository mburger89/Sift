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

/// The paged rows of one `GridSource`, as `Table` reads them.
///
/// **Reading never queries.** `value(row:column:)` answers from the page cache, or answers nil (the cell draws a
/// placeholder) and asks for the page. The ask is deferred to the next main-actor turn and de-duplicated, so a build
/// never writes observable state. **One query runs at a time:** a count, a page or an exact count. A request for a
/// page nobody is looking at any more is cancelled on the server (`cancelCurrent()`), and every answer carries the
/// generation of the query it was asked under, so a superseded answer never lands.
@Observable @MainActor
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
    /// The cell cursor, and the selected row.
    public var activePosition: GridPosition?
    public var selectedRow: Int?

    public let source: any GridSource
    public var columns: [ResultColumn] { source.columns }
    public var rows: GridRowRefs { GridRowRefs(count: count.value) }
    public var orderNote: String? { source.orderNote }

    // MARK: Internals

    private enum Work: Equatable {
        case count
        case exactCount
        case page(Int)
    }
    private struct InFlight {
        var work: Work
        var serial: Int
    }
    private struct Snapshot {
        var query: GridQuery
        var pages: [Int: [[SiftValue]]]
        var count: RowCount
    }
    private struct Read {
        var epoch: Int
        var tick: Int
    }

    @ObservationIgnored private let clock: any SiftClock
    @ObservationIgnored private var pages: [Int: [[SiftValue]]] = [:]
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
    /// How many times `value(row:column:)` has been asked. For cost tests.
    @ObservationIgnored public private(set) var valueReads = 0

    /// Sets the read counter back to zero. For cost tests.
    public func resetReadCount() { valueReads = 0 }

    public init(source: any GridSource, clock: any SiftClock = SystemClock()) {
        self.source = source
        self.clock = clock
        isLoading = true
        scheduleTurn()
    }

    // MARK: Reading

    /// The value at `(row, column)`, or nil when its page is not loaded (draw a placeholder). A missing page is
    /// requested once, on the next main-actor turn.
    public func value(row: Int, column: Int) -> SiftValue? {
        _ = pagesVersion
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

    /// The pages in the cache, in order. For tests.
    public var cachedPages: [Int] { pages.keys.sorted() }

    // MARK: Changing what is shown

    /// Shows `query`. Pages are dropped and the query in flight is cancelled; a count is asked again only when the
    /// filters or the search changed. If the server refuses the new query, the model goes back to the last good one.
    public func apply(_ query: GridQuery) {
        guard query != self.query else { return }
        if inFlight != nil {
            source.cancelCurrent()
            inFlight = nil
        }
        generation += 1
        if previous == nil { previous = Snapshot(query: self.query, pages: pages, count: count) }
        let narrowed = query.filters != self.query.filters || query.search != self.query.search
        self.query = query
        resetPages()
        error = nil
        errorIsFilter = false
        if narrowed {
            count = .estimated(GridPaging.pageSize)
            countNeeded = true
            exactNeeded = false
            isCountingExactly = false
        }
        selectedRow = nil
        activePosition = nil
        pagesVersion += 1
        isLoading = true
        scheduleTurn()
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
            if exactNeeded {
                start(.exactCount)
            } else if countNeeded {
                start(.count)
            } else if let next = missing.first {
                start(.page(next))
            }
        }
        let busy = inFlight != nil || countNeeded || !missing.isEmpty
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
        pagesVersion += 1
        pump()
    }

    private func pageArrived(_ page: Int, _ rows: [[SiftValue]], generation mine: Int, serial mineSerial: Int) {
        guard finish(serial: mineSerial, generation: mine) else { return pump() }
        previous = nil
        pages[page] = rows
        wanted.remove(page)
        let size = GridPaging.pageSize
        if rows.count < size {
            count = .exact(page * size + rows.count)
        } else if !count.isExact, (page + 1) * size >= count.value {
            count = .estimated((page + 2) * size)
        }
        evict()
        pagesVersion += 1
        pump()
    }

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
        let message = Self.describe(error)
        var filterRefusal = false
        if let source = error as? SourceError, case .server = source.kind { filterRefusal = previous != nil }
        if filterRefusal, let good = previous {
            // The server refused the new filters: show the last good rows again, with the reason.
            previous = nil
            generation += 1
            query = good.query
            pages = good.pages
            count = good.count
            lastRead = [:]
            wanted = []
            failedPages = []
            countNeeded = false
            exactNeeded = false
            isCountingExactly = false
            self.error = message
            errorIsFilter = true
            pagesVersion += 1
            return pump()
        }
        self.error = message
        errorIsFilter = false
        switch work {
        case .page(let page): failedPages.insert(page)
        case .count: countNeeded = false
        case .exactCount:
            exactNeeded = false
            isCountingExactly = false
        }
        pump()
    }

    private func evict() {
        while pages.count > GridPaging.cachedPages {
            // The least recently read page that nobody is looking at.
            let victim = pages.keys.filter { !isVisible($0) }.min { (lastRead[$0]?.tick ?? -1) < (lastRead[$1]?.tick ?? -1) }
            guard let victim else { return }
            pages[victim] = nil
            lastRead[victim] = nil
        }
    }

    nonisolated static func describe(_ error: any Error) -> String {
        if let error = error as? SourceError { return error.message }
        return String(describing: error)
    }
}
