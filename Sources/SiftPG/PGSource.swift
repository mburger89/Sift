import Foundation
import SiftCore

/// A read-only `DatabaseSource` over one libpq session.
public final class PGSource: DatabaseSource, @unchecked Sendable {
    let connection: PGConnection
    private let parameters: PGConnectionParameters?
    private let gridLock = NSLock()
    private var grids: [PGRelationPager] = []

    private init(connection: PGConnection, parameters: PGConnectionParameters?) {
        self.connection = connection
        self.parameters = parameters
    }

    /// Connects read-only (decision D5): the startup option asks for it, then `SHOW` must answer `on`.
    /// If not (a pooler can drop startup options), `SET` is tried once; if the server still does not
    /// say `on`, the session is refused and closed.
    public static func connect(_ parameters: PGConnectionParameters) async throws -> PGSource {
        var p = parameters
        p.readOnly = true
        let connection: PGConnection
        do { connection = try PGConnection(parameters: p) } catch let e as PGError { throw Self.map(e) }
        let source = PGSource(connection: connection, parameters: p)
        do {
            if try await source.readOnlySetting() != "on" {
                _ = try await source.rawQuery("SET default_transaction_read_only = on")
                if try await source.readOnlySetting() != "on" {
                    throw SourceError(.readOnlyNotEnforced, "The server did not enforce a read-only session")
                }
            }
        } catch {
            connection.close()
            throw error
        }
        return source
    }

    private func readOnlySetting() async throws -> String? {
        let page = try await rawQuery("SHOW default_transaction_read_only")
        if case .text(let s)? = page.rows.first?.first { return s }
        return nil
    }

    /// Runs one statement through this source's connection, with errors mapped to `SourceError`.
    func rawQuery(_ sql: String, params: [String?] = []) async throws -> ResultPage {
        do { return try await connection.execute(sql, params: params) } catch let e as PGError { throw Self.map(e) }
    }

    public func snapshot() async throws -> SchemaSnapshot {
        do { return try await PGIntrospector(connection: connection).snapshot() } catch let e as PGError { throw Self.map(e) }
    }

    public func firstRows(of relation: RelationID, limit: Int) async throws -> ResultPage {
        try await rawQuery("SELECT * FROM \(PGIdentifier.qualified(relation)) LIMIT $1", params: [String(max(limit, 0))])
    }

    public func exactRowCount(of relation: RelationID) async throws -> Int64 {
        let page: ResultPage
        do {
            page = try await connection.executeInReadOnlyTransaction(
                "SELECT count(*) FROM \(PGIdentifier.qualified(relation))", statementTimeout: "60s")
        } catch let e as PGError { throw Self.map(e) }
        guard case .int(let n)? = page.rows.first?.first else { throw SourceError(.other, "count(*) returned no number") }
        return n
    }

    public func cancelCurrent() { connection.cancel() }

    public var isBroken: Bool { connection.isBroken }

    public func close() {
        let open = gridLock.withLock { () -> [PGRelationPager] in
            defer { grids = [] }
            return grids
        }
        for grid in open { grid.close() }
        connection.close()
    }

    /// A pager on a second connection of its own, opened at its first call, so cancelling a grid's query never
    /// cancels this source's schema refresh. It closes with the source.
    public func gridSource(for relation: RelationInfo) -> (any GridSource)? {
        guard let parameters else { return nil }
        let pager = PGRelationPager(parameters: parameters, relation: relation)
        gridLock.withLock { grids.append(pager) }
        return pager
    }

    static func map(_ e: PGError) -> SourceError {
        if e.isConnectionLost { return SourceError(.connectionLost, e.message) }
        if e.sqlState == "57014" { return SourceError(.cancelled, e.message) }
        if let state = e.sqlState { return SourceError(.server(sqlState: state), e.message) }
        return SourceError(.other, e.message)
    }
}
