import Foundation
import SiftCore

/// A `GridSource` over generated rows, for model and UI tests.
///
/// Row `n` of an unsorted query has `n` in column 0 and `r<n>c<column>` in the others; a descending sort reverses
/// the order, so a test can see which query a page answered. `trueCount` is how many rows really exist: a page
/// past it is short or empty. Every call is recorded. With `holdsPages` (or `holdsCounts`) an answer waits until the
/// test releases it, in any order, so a test can make a slow answer land after a newer one.
public final class FakeGridSource: GridSource, @unchecked Sendable {
    public enum Call: Equatable, Sendable {
        case count(GridQuery)
        case exactCount(GridQuery)
        /// `keyset` is true when the call carried the previous page's last row.
        case page(index: Int, size: Int, query: GridQuery, keyset: Bool)
        /// `changeMarker()` was asked.
        case marker
    }

    public let columns: [ResultColumn]
    public var orderNote: String? { lock.withLock { _orderNote } }

    private let lock = NSLock()

    /// What `page` reads under the lock, so the rest of the page is built outside it.
    private struct PageState {
        var only: [Int]?
        var total: Int
        var fixed: [[SiftValue]]?
        var flagged: Bool
        var changed: Set<Int>
        var overrides: [Int: [Int: SiftValue]]
    }
    private var _calls: [Call] = []
    private var _cancelCalls = 0
    private var _closed = false
    private var _orderNote: String?
    private var _holdsPages = false
    private var _holdsCounts = false
    private var _holdsMarkers = false
    private var _supportsChanges = false
    private var _keyColumns: [Int] = []
    private var _markers: [String] = []
    private var _markerCount = 0
    private var _changed: Set<Int> = []
    private var _overrides: [Int: [Int: SiftValue]] = [:]
    private var _trueCount: Int
    private var _countAnswer: RowCount?
    private var _refreshedEstimate: Int64?
    private var _failures: [SourceError] = []
    private var fixedRows: [[SiftValue]]?
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []

    /// - Parameters:
    ///   - trueCount: how many rows exist.
    ///   - count: what `count(for:)` answers; by default `.exact(trueCount)`.
    public init(columns: [ResultColumn], trueCount: Int, count: RowCount? = nil) {
        self.columns = columns
        _trueCount = trueCount
        _countAnswer = count
    }

    /// Five text columns `c0` ... `c4`, `c0` being an int.
    public convenience init(columnCount: Int = 5, trueCount: Int, count: RowCount? = nil) {
        self.init(
            columns: (0..<columnCount).map {
                ResultColumn(name: "c\($0)", typeOID: $0 == 0 ? 20 : 25, typeName: $0 == 0 ? "int8" : "text")
            },
            trueCount: trueCount, count: count)
    }

    /// A source that answers exactly `rows`, in order (a descending sort reverses them).
    public convenience init(columns: [ResultColumn], rows: [[SiftValue]]) {
        self.init(columns: columns, trueCount: rows.count)
        let rows = rows
        lock.withLock { fixedRows = rows }
    }

    public var trueCount: Int {
        get { lock.withLock { _trueCount } }
        set { lock.withLock { _trueCount = newValue } }
    }
    public var countAnswer: RowCount? {
        get { lock.withLock { _countAnswer } }
        set { lock.withLock { _countAnswer = newValue } }
    }
    public var holdsPages: Bool {
        get { lock.withLock { _holdsPages } }
        set { lock.withLock { _holdsPages = newValue } }
    }
    public var holdsCounts: Bool {
        get { lock.withLock { _holdsCounts } }
        set { lock.withLock { _holdsCounts = newValue } }
    }
    public var holdsMarkers: Bool {
        get { lock.withLock { _holdsMarkers } }
        set { lock.withLock { _holdsMarkers = newValue } }
    }
    public var supportsChanges: Bool {
        get { lock.withLock { _supportsChanges } }
        set { lock.withLock { _supportsChanges = newValue } }
    }
    public var keyColumns: [Int] {
        get { lock.withLock { _keyColumns } }
        set { lock.withLock { _keyColumns = newValue } }
    }
    /// The markers the next `changeMarker()` calls answer, in order. When the queue is empty, markers are `m1`, `m2`, ...
    public func setMarkers(_ markers: [String]) { lock.withLock { _markers = markers } }
    /// The ordinals (rows of the unsorted data) a read with `changes` flags as changed; with `only`, the only ones returned.
    public func setChanged(_ ordinals: Set<Int>) { lock.withLock { _changed = ordinals } }
    /// Makes the row with this ordinal answer `value` in `column` from now on: a row that changed between two looks.
    public func setValue(_ value: SiftValue, row ordinal: Int, column: Int) {
        lock.withLock { _overrides[ordinal, default: [:]][column] = value }
    }
    public func setOrderNote(_ note: String?) { lock.withLock { _orderNote = note } }
    /// The next calls throw these, one each, in order.
    public func failNext(_ errors: [SourceError]) { lock.withLock { _failures.append(contentsOf: errors) } }
    public var calls: [Call] { lock.withLock { _calls } }
    public var cancelCalls: Int { lock.withLock { _cancelCalls } }
    public var isClosed: Bool { lock.withLock { _closed } }

    /// The number of `changeMarker()` calls so far.
    public var markerCalls: Int { calls.filter { $0 == .marker }.count }

    /// The pages asked for, in order.
    public var pageCalls: [(index: Int, query: GridQuery, keyset: Bool)] {
        calls.compactMap {
            if case .page(let index, _, let query, let keyset) = $0 { return (index, query, keyset) } else { return nil }
        }
    }

    // MARK: Holding

    /// Lets the call at `index` in `calls` answer. It may be released before it waits.
    public func release(callAt index: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released.insert(index)
            return waiting.removeValue(forKey: index)
        }
        continuation?.resume()
    }

    /// Lets every waiting call answer, and every later one too.
    public func releaseAll() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _holdsPages = false
            _holdsCounts = false
            _holdsMarkers = false
            defer { waiting = [:] }
            return Array(waiting.values)
        }
        for c in all { c.resume() }
    }

    private func record(_ call: Call, holds: Bool) async throws -> Int {
        let (id, failure) = lock.withLock { () -> (Int, SourceError?) in
            _calls.append(call)
            return (_calls.count - 1, _failures.isEmpty ? nil : _failures.removeFirst())
        }
        if holds {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let immediate = lock.withLock { () -> Bool in
                    if released.contains(id) { return true }
                    waiting[id] = c
                    return false
                }
                if immediate { c.resume() }
            }
        }
        if let failure { throw failure }
        return id
    }

    // MARK: GridSource

    public func count(for query: GridQuery) async throws -> RowCount {
        _ = try await record(.count(query), holds: holdsCounts)
        return lock.withLock {
            if let only = onlyChanged(query) { return .exact(only.count) }
            if !query.narrows, let _refreshedEstimate { return .estimated(Int(_refreshedEstimate)) }
            return _countAnswer ?? .exact(_trueCount)
        }
    }

    /// What a pager does with the refreshed relation: an un-narrowed count answers its estimate from then on.
    public func relationRefreshed(_ relation: RelationInfo) {
        if case .estimated(let n) = relation.rowEstimate { lock.withLock { _refreshedEstimate = n } }
    }

    public func exactCount(for query: GridQuery) async throws -> Int {
        _ = try await record(.exactCount(query), holds: holdsCounts)
        return lock.withLock { onlyChanged(query)?.count ?? _trueCount }
    }

    public func changeMarker() async throws -> String {
        _ = try await record(.marker, holds: holdsMarkers)
        return lock.withLock {
            _markerCount += 1
            return _markers.isEmpty ? "m\(_markerCount)" : _markers.removeFirst()
        }
    }

    /// The changed ordinals, ascending, when the query keeps only changes on a source that supports them. Under the lock.
    private func onlyChanged(_ query: GridQuery) -> [Int]? {
        guard _supportsChanges, query.changes?.only == true else { return nil }
        return _changed.filter { $0 < _trueCount }.sorted()
    }

    public func page(_ index: Int, size: Int, query: GridQuery, after: [SiftValue]?) async throws -> [[SiftValue]] {
        _ = try await record(.page(index: index, size: size, query: query, keyset: after != nil), holds: holdsPages)
        let pageState = lock.withLock { () -> PageState in
            let only = onlyChanged(query)
            return PageState(only: only, total: only?.count ?? _trueCount, fixed: fixedRows,
                             flagged: _supportsChanges && query.changes != nil, changed: _changed, overrides: _overrides)
        }
        let (only, total, fixed, flagged, changed, overrides) =
            (pageState.only, pageState.total, pageState.fixed, pageState.flagged, pageState.changed, pageState.overrides)
        let start = index * size
        guard start < total else { return [] }
        return (start..<min(start + size, total)).map { position in
            let sorted = (query.sort?.ascending == false) ? total - 1 - position : position
            let ordinal = only?[sorted] ?? sorted
            var row: [SiftValue]
            if let fixed {
                row = fixed[ordinal]
            } else {
                row = columns.indices.map { column in
                    column == 0 ? .int(Int64(ordinal)) : .text("r\(ordinal)c\(column)")
                }
            }
            for (column, value) in overrides[ordinal] ?? [:] where row.indices.contains(column) { row[column] = value }
            if flagged { row.append(.bool(changed.contains(ordinal))) }
            return row
        }
    }

    public func cancelCurrent() { lock.withLock { _cancelCalls += 1 } }
    public func close() { lock.withLock { _closed = true } }
}
