import Foundation
import SiftCore

/// A `DatabaseSource` over canned data, with switches for the failures a UI test needs.
public final class FakeSource: DatabaseSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _schema: SchemaSnapshot
    private var _rows: [RelationID: ResultPage]
    private var _counts: [RelationID: Int64]
    private var _failNext: SourceError?
    private var _holdCountUntilCancel = false
    private var _cancelCalls = 0
    private var _broken = false
    private var _closed = false
    private var _rowRequests: [RelationID] = []
    private var held: CheckedContinuation<Int64, any Error>?
    private var _grids: [RelationID: FakeGridSource] = [:]
    private var _gridRequests: [RelationID] = []
    private var _runner: FakeQueryRunner?

    public init(schema: SchemaSnapshot, rows: [RelationID: ResultPage] = [:], counts: [RelationID: Int64] = [:]) {
        _schema = schema
        _rows = rows
        _counts = counts
    }

    /// The snapshot `snapshot()` answers.
    public var schema: SchemaSnapshot {
        get { lock.withLock { _schema } }
        set { lock.withLock { _schema = newValue } }
    }
    public var rows: [RelationID: ResultPage] {
        get { lock.withLock { _rows } }
        set { lock.withLock { _rows = newValue } }
    }
    public var counts: [RelationID: Int64] {
        get { lock.withLock { _counts } }
        set { lock.withLock { _counts = newValue } }
    }
    /// The next call of any kind throws this once, then it is cleared.
    public var failNext: SourceError? {
        get { lock.withLock { _failNext } }
        set { lock.withLock { _failNext = newValue } }
    }
    /// `exactRowCount` waits until `cancelCurrent()` and then throws `.cancelled`.
    public var holdCountUntilCancel: Bool {
        get { lock.withLock { _holdCountUntilCancel } }
        set { lock.withLock { _holdCountUntilCancel = newValue } }
    }
    public private(set) var cancelCalls: Int {
        get { lock.withLock { _cancelCalls } }
        set { lock.withLock { _cancelCalls = newValue } }
    }
    public var isBroken: Bool {
        get { lock.withLock { _broken } }
        set { lock.withLock { _broken = newValue } }
    }
    public var isClosed: Bool { lock.withLock { _closed } }
    /// Every relation `firstRows` was asked for, in order.
    public var rowRequests: [RelationID] { lock.withLock { _rowRequests } }

    private func takeFailure() throws {
        if let error = lock.withLock({ () -> SourceError? in
            defer { _failNext = nil }
            return _failNext
        }) { throw error }
    }

    public func snapshot() async throws -> SchemaSnapshot {
        try takeFailure()
        return schema
    }

    public func firstRows(of relation: RelationID, limit: Int) async throws -> ResultPage {
        lock.withLock { _rowRequests.append(relation) }
        try takeFailure()
        guard let page = rows[relation] else { return ResultPage(columns: [], rows: []) }
        return ResultPage(columns: page.columns, rows: Array(page.rows.prefix(limit)))
    }

    public func exactRowCount(of relation: RelationID) async throws -> Int64 {
        try takeFailure()
        if holdCountUntilCancel {
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { held = continuation }
            }
        }
        return counts[relation] ?? 0
    }

    public func cancelCurrent() {
        let continuation = lock.withLock { () -> CheckedContinuation<Int64, any Error>? in
            _cancelCalls += 1
            defer { held = nil }
            return held
        }
        continuation?.resume(throwing: SourceError(.cancelled, "The count was cancelled"))
    }

    public func close() {
        let open = lock.withLock { () -> [FakeGridSource] in
            _closed = true
            return Array(_grids.values)
        }
        for grid in open { grid.close() }
    }

    /// The grid `gridSource(for:)` answers for a relation. Without one, it answers the relation's canned `rows`.
    public func setGrid(_ grid: FakeGridSource, for relation: RelationID) { lock.withLock { _grids[relation] = grid } }
    /// The grids `gridSource(for:)` handed out, in order.
    public var gridRequests: [RelationID] { lock.withLock { _gridRequests } }
    public func grid(for relation: RelationID) -> FakeGridSource? { lock.withLock { _grids[relation] } }

    /// The runner `queryRunner()` hands out, made at the first ask.
    public var runner: FakeQueryRunner {
        lock.withLock {
            if let _runner { return _runner }
            let made = FakeQueryRunner()
            _runner = made
            return made
        }
    }

    public func queryRunner() -> (any QueryRunning)? { runner }

    public func gridSource(for relation: RelationInfo) -> (any GridSource)? {
        lock.withLock {
            _gridRequests.append(relation.id)
            if let grid = _grids[relation.id] { return grid }
            let columns: [ResultColumn]
            let rows: [[SiftValue]]
            if let page = _rows[relation.id] {
                columns = page.columns
                rows = page.rows
            } else {
                columns = relation.columns.map { ResultColumn(name: $0.name, typeOID: 0, typeName: $0.typeName, isEnum: $0.isEnum) }
                rows = []
            }
            let grid = FakeGridSource(columns: columns, rows: rows)
            _grids[relation.id] = grid
            return grid
        }
    }
}
