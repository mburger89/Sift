import Dispatch
import Foundation
import SiftCore

/// A `GridSource` over one Postgres relation, on a connection of its own.
///
/// Every statement runs through `executeInReadOnlyTransaction` with a 15-second `statement_timeout` (a count
/// that is only a nicety has 2 seconds). SQL text and parameters come from `PGRelationQuery`: identifiers are
/// quoted there, values are only ever bound.
public final class PGRelationPager: GridSource, @unchecked Sendable {
    public static let pageTimeout = "15s"
    public static let countTimeout = "2s"
    public static let exactCountTimeout = "60s"
    /// An estimate at or above this is not counted: the status bar offers "Count exactly" instead.
    public static let countThreshold = 1_000_000

    public let columns: [ResultColumn]
    private let relation: RelationInfo
    private let builder: PGRelationQuery

    private let lock = NSLock()
    private var connection: PGConnection?
    private var connecting: Task<PGConnection, any Error>?
    private let parameters: PGConnectionParameters?
    private var closed = false
    private var cancelRequested = false

    /// Pages over a connection the caller owns. `close()` closes it.
    public init(connection: PGConnection, relation: RelationInfo) {
        self.connection = connection
        self.parameters = nil
        self.relation = relation
        let key = PGRelationQuery.orderKey(for: relation)
        self.builder = PGRelationQuery(relation: relation, orderKey: key.columns, keyKind: key.kind)
        self.columns = Self.resultColumns(of: relation)
    }

    /// Pages over a connection opened at the first call, read-only, so building a grid never blocks the caller.
    public init(parameters: PGConnectionParameters, relation: RelationInfo) {
        var p = parameters
        p.readOnly = true
        self.parameters = p
        self.relation = relation
        let key = PGRelationQuery.orderKey(for: relation)
        self.builder = PGRelationQuery(relation: relation, orderKey: key.columns, keyKind: key.kind)
        self.columns = Self.resultColumns(of: relation)
    }

    static func resultColumns(of relation: RelationInfo) -> [ResultColumn] {
        relation.columns.map { column in
            let known = PGOID.canonical(formatted: column.typeName)
            return ResultColumn(name: column.name, typeOID: known.oid, typeName: known.name, isEnum: column.isEnum)
        }
    }

    public var orderNote: String? {
        switch builder.keyKind {
        case .primaryKey, .uniqueNotNull: return nil
        case .ctid, .unordered: return "no stable key: rows may shift"
        }
    }

    /// The server process of the connection, once there is one. For tests of cancellation.
    public var backendPID: Int32? { lock.withLock { connection }?.backendPID }

    // MARK: Connection

    private func ready() async throws -> PGConnection {
        let task: Task<PGConnection, any Error> = try lock.withLock {
            if closed { throw SourceError(.connectionLost, "The grid was closed") }
            if let connection { return Task { connection } }
            if let connecting { return connecting }
            guard let parameters else { throw SourceError(.connectionLost, "The grid has no connection") }
            let task = Task<PGConnection, any Error> {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<PGConnection, any Error>) in
                    DispatchQueue.global().async {
                        do { c.resume(returning: try PGConnection(parameters: parameters)) } catch let e as PGError {
                            c.resume(throwing: PGSource.map(e))
                        } catch { c.resume(throwing: error) }
                    }
                }
            }
            connecting = task
            return task
        }
        let opened = try await task.value
        let usable: Bool = lock.withLock {
            if closed { return false }
            connection = opened
            connecting = nil
            return true
        }
        if !usable {
            opened.close()
            throw SourceError(.connectionLost, "The grid was closed")
        }
        return opened
    }

    private func run(_ built: (sql: String, params: [String?]), timeout: String) async throws -> ResultPage {
        let connection = try await ready()
        lock.withLock { cancelRequested = false }
        do {
            return try await connection.executeInReadOnlyTransaction(built.sql, params: built.params, statementTimeout: timeout)
        } catch let e as PGError {
            throw PGSource.map(e)
        }
    }

    // MARK: GridSource

    public func count(for query: GridQuery) async throws -> RowCount {
        var estimate: Int?
        if case .estimated(let n) = relation.rowEstimate { estimate = Int(n) }
        if !query.narrows, let estimate, estimate >= Self.countThreshold { return .estimated(estimate) }
        do {
            return .exact(try await exactNumber(builder.countSQL(query: query), timeout: Self.countTimeout))
        } catch let e as SourceError where e.kind == .cancelled && !lock.withLock({ cancelRequested }) {
            // The server's timeout, not a cancel: the table is too big to count in the time given.
            if !query.narrows, let estimate, estimate > 0 { return .estimated(estimate) }
            return .estimated(GridPaging.pageSize)
        }
    }

    public func exactCount(for query: GridQuery) async throws -> Int {
        try await exactNumber(builder.countSQL(query: query), timeout: Self.exactCountTimeout)
    }

    private func exactNumber(_ built: (sql: String, params: [String?]), timeout: String) async throws -> Int {
        let page = try await run(built, timeout: timeout)
        guard case .int(let n)? = page.rows.first?.first else { throw SourceError(.other, "count(*) returned no number") }
        return Int(n)
    }

    public func page(_ index: Int, size: Int, query: GridQuery, after: [SiftValue]?) async throws -> [[SiftValue]] {
        try await run(builder.pageSQL(index: index, size: size, query: query, after: after), timeout: Self.pageTimeout).rows
    }

    public func cancelCurrent() {
        let connection = lock.withLock { () -> PGConnection? in
            cancelRequested = true
            return self.connection
        }
        connection?.cancel()
    }

    public func close() {
        let (connection, pending) = lock.withLock { () -> (PGConnection?, Task<PGConnection, any Error>?) in
            closed = true
            defer { self.connection = nil; connecting = nil }
            return (self.connection, connecting)
        }
        connection?.close()
        pending?.cancel()
    }
}
