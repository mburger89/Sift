import CLibPQ
import Dispatch
import Foundation
import SiftCore

/// A failure from libpq, carrying `PQerrorMessage` (or `PQresultErrorMessage`).
public struct PGError: Error, Sendable, CustomStringConvertible {
    public var message: String
    /// The five-character SQLSTATE of a server error, or nil (a dropped socket has none).
    public var sqlState: String?
    /// True when the connection itself is gone (`PQstatus` is `CONNECTION_BAD` after the failure).
    public var isConnectionLost: Bool
    /// The 1-based character offset in the sent text the server points at (`PG_DIAG_STATEMENT_POSITION`), or nil.
    public var position: Int?
    /// The server's `DETAIL` and `HINT` lines, when it sent them.
    public var detail: String?
    public var hint: String?
    /// The one-line message without the `ERROR:` prefix and the `LINE n:` context (`PG_DIAG_MESSAGE_PRIMARY`).
    public var primaryMessage: String?
    public init(
        _ message: String, sqlState: String? = nil, isConnectionLost: Bool = false,
        position: Int? = nil, detail: String? = nil, hint: String? = nil, primaryMessage: String? = nil
    ) {
        self.message = message
        self.sqlState = sqlState
        self.isConnectionLost = isConnectionLost
        self.position = position
        self.detail = detail
        self.hint = hint
        self.primaryMessage = primaryMessage
    }
    public var description: String { message }
}

/// One Postgres connection. Every libpq call on it runs on one serial queue, so none is concurrent.
/// `cancel()` is the single exception: it is the thread-safe `PQcancel` and runs on the caller's thread.
public final class PGConnection: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sift.pg.connection")
    // Touched only on `queue` (and in deinit, when nothing else can hold the object).
    private var conn: OpaquePointer?
    // Created once after connecting; `PQcancel` on it is safe from any thread.
    private let cancelHandle: OpaquePointer?
    // Read from any thread without waiting for a running statement (`isBroken`).
    private let brokenLock = NSLock()
    private var brokenFlag = false

    /// Connects with a libpq connection string or URL.
    public convenience init(conninfo: String) throws {
        try self.init(connected: PQconnectdb(conninfo))
    }

    /// Connects with keyword and value arrays (`PQconnectdbParams`, `expand_dbname = 0`), so no
    /// conninfo string is ever built from parts and no password sits inside a string that might be logged.
    public convenience init(parameters: PGConnectionParameters) throws {
        let pairs = parameters.keywordValues()
        let keys: [UnsafeMutablePointer<CChar>?] = pairs.map { strdup($0.0) } + [nil]
        let values: [UnsafeMutablePointer<CChar>?] = pairs.map { strdup($0.1) } + [nil]
        defer {
            for k in keys { free(k) }
            for v in values { free(v) }
        }
        let k: [UnsafePointer<CChar>?] = keys.map { $0.map { UnsafePointer($0) } }
        let v: [UnsafePointer<CChar>?] = values.map { $0.map { UnsafePointer($0) } }
        try self.init(connected: PQconnectdbParams(k, v, 0))
    }

    private init(connected c: OpaquePointer?) throws {
        guard let c else { throw PGError("PQconnectdb returned nil") }
        if PQstatus(c) != CONNECTION_OK {
            let message = String(cString: PQerrorMessage(c))
            PQfinish(c)
            throw PGError(message.trimmingTrailingNewlines())
        }
        conn = c
        cancelHandle = PQgetCancel(c)
    }

    deinit {
        if let cancelHandle { PQfreeCancel(cancelHandle) }
        if let conn { PQfinish(conn) }
    }

    /// The server version as libpq reports it, e.g. `170002` for 17.2.
    public var serverVersion: Int {
        queue.sync { conn.map { Int(PQserverVersion($0)) } ?? 0 }
    }

    /// True once a statement has found the connection unusable, or it was closed. It does not wait
    /// for a running statement, so it is safe to read from the UI.
    public var isBroken: Bool {
        brokenLock.lock()
        defer { brokenLock.unlock() }
        return brokenFlag
    }

    private func markBroken() {
        brokenLock.lock()
        brokenFlag = true
        brokenLock.unlock()
    }

    /// Closes the connection. Later statements fail as connection-lost.
    public func close() {
        queue.sync {
            if let conn { PQfinish(conn) }
            conn = nil
        }
        markBroken()
    }

    /// Runs `sql` inside `BEGIN READ ONLY` with `SET LOCAL statement_timeout`, always ending the
    /// transaction (`COMMIT`, or `ROLLBACK` when anything failed).
    public func executeInReadOnlyTransaction(
        _ sql: String, params: [String?] = [], statementTimeout: String
    ) async throws -> ResultPage {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<ResultPage, any Error>) in
            queue.async {
                do {
                    _ = try self.run("BEGIN READ ONLY", params: [])
                    do {
                        // The timeout is validated by the server; it never carries user text.
                        _ = try self.run("SET LOCAL statement_timeout = '\(statementTimeout)'", params: [])
                        let page = try self.run(sql, params: params)
                        _ = try self.run("COMMIT", params: [])
                        c.resume(returning: page)
                    } catch {
                        _ = try? self.run("ROLLBACK", params: [])
                        c.resume(throwing: error)
                    }
                } catch { c.resume(throwing: error) }
            }
        }
    }

    /// Runs `body` inside `BEGIN READ ONLY` with `SET LOCAL statement_timeout`, on this connection's queue, so every
    /// statement `body` runs through its `PGTransaction` shares one transaction. When `body` returns the transaction
    /// is committed; when it throws (or a statement fails) it is rolled back, so the connection never stays
    /// `idle in transaction`. `statementTimeout` is a server interval such as `60s`, or `0` for none.
    public func readOnlyTransaction<T: Sendable>(
        statementTimeout: String, _ body: @escaping @Sendable (PGTransaction) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, any Error>) in
            queue.async {
                do {
                    _ = try self.run("BEGIN READ ONLY", params: [])
                    do {
                        _ = try self.run("SET LOCAL statement_timeout = '\(statementTimeout)'", params: [])
                        let value = try body(PGTransaction(connection: self))
                        _ = try self.run("COMMIT", params: [])
                        c.resume(returning: value)
                    } catch {
                        _ = try? self.run("ROLLBACK", params: [])
                        c.resume(throwing: error)
                    }
                } catch { c.resume(throwing: error) }
            }
        }
    }

    /// The server process id of this session.
    public var backendPID: Int32 {
        queue.sync { conn.map { PQbackendPID($0) } ?? 0 }
    }

    /// Runs one statement with text parameters (`nil` is NULL) and text results.
    public func query(_ sql: String, params: [String?] = []) throws -> ResultPage {
        try queue.sync { try run(sql, params: params) }
    }

    /// The same as `query`, off the caller's thread. The queue stays serial.
    public func execute(_ sql: String, params: [String?] = []) async throws -> ResultPage {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<ResultPage, any Error>) in
            queue.async {
                do { c.resume(returning: try self.run(sql, params: params)) } catch { c.resume(throwing: error) }
            }
        }
    }

    // Runs on `queue`.
    private func run(_ sql: String, params: [String?]) throws -> ResultPage {
        try runRaw(sql, params: params).page
    }

    /// What one statement answered: its rows (none for a command), the command tag and the rows it touched.
    struct RawResult {
        var page: ResultPage
        var commandTag: String
        var affected: Int?
        var returnsRows: Bool
    }

    // Runs on `queue`.
    fileprivate func runRaw(_ sql: String, params: [String?]) throws -> RawResult {
        guard let conn else {
            markBroken()
            throw PGError("connection is closed", isConnectionLost: true)
        }
        // C strings for the parameters, freed after the call.
        let buffers: [UnsafeMutablePointer<CChar>?] = params.map { p in
            guard let p else { return nil }
            let bytes = Array(p.utf8CString)
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            buf.initialize(from: bytes, count: bytes.count)
            return buf
        }
        defer { for b in buffers { b?.deallocate() } }
        let values: [UnsafePointer<CChar>?] = buffers.map { $0.map { UnsafePointer($0) } }

        guard let result = PQexecParams(
            conn, sql, Int32(params.count), nil, values, nil, nil, 0
        ) else {
            let lost = PQstatus(conn) == CONNECTION_BAD
            if lost { markBroken() }
            throw PGError(String(cString: PQerrorMessage(conn)).trimmingTrailingNewlines(), isConnectionLost: lost)
        }
        defer { PQclear(result) }

        func field(_ code: Character) -> String? {
            PQresultErrorField(result, Int32(code.asciiValue ?? 0)).map { String(cString: $0) }
        }
        switch PQresultStatus(result) {
        case PGRES_TUPLES_OK:
            return RawResult(
                page: Self.page(from: result), commandTag: String(cString: PQcmdStatus(result)),
                affected: Int(String(cString: PQcmdTuples(result))), returnsRows: true)
        case PGRES_COMMAND_OK, PGRES_EMPTY_QUERY:
            return RawResult(
                page: ResultPage(columns: [], rows: []), commandTag: String(cString: PQcmdStatus(result)),
                affected: Int(String(cString: PQcmdTuples(result))), returnsRows: false)
        default:
            // Not classified by SQLSTATE: a dropped socket has none.
            let lost = PQstatus(conn) == CONNECTION_BAD
            if lost { markBroken() }
            throw PGError(
                String(cString: PQresultErrorMessage(result)).trimmingTrailingNewlines(),
                sqlState: field("C"), isConnectionLost: lost,
                position: field("P").flatMap { Int($0) }, detail: field("D"), hint: field("H"), primaryMessage: field("M"))
        }
    }

    /// Asks the server to abort the statement now running on this connection (if any).
    /// Returns true when the request was delivered.
    @discardableResult
    public func cancel() -> Bool {
        guard let cancelHandle else { return false }
        var buf = [CChar](repeating: 0, count: 256)
        return PQcancel(cancelHandle, &buf, Int32(buf.count)) == 1
    }

    private static func page(from result: OpaquePointer) -> ResultPage {
        let columnCount = Int(PQnfields(result))
        let rowCount = Int(PQntuples(result))
        var columns: [ResultColumn] = []
        for c in 0..<columnCount {
            let oid = UInt32(PQftype(result, Int32(c)))
            columns.append(ResultColumn(
                name: String(cString: PQfname(result, Int32(c))),
                typeOID: oid,
                typeName: PGOID.typeName(for: oid)
            ))
        }
        var rows: [[SiftValue]] = []
        rows.reserveCapacity(rowCount)
        for r in 0..<rowCount {
            var row: [SiftValue] = []
            row.reserveCapacity(columnCount)
            for c in 0..<columnCount {
                if PQgetisnull(result, Int32(r), Int32(c)) == 1 {
                    row.append(.null)
                } else {
                    let text = String(cString: PQgetvalue(result, Int32(r), Int32(c)))
                    row.append(PGOID.decode(text, oid: columns[c].typeOID))
                }
            }
            rows.append(row)
        }
        return ResultPage(columns: columns, rows: rows)
    }
}

/// One statement's answer inside a transaction: the rows, the command tag (`SELECT 3`, `CREATE TABLE`) and the rows touched.
public struct PGStatementResult: Sendable {
    public var page: ResultPage
    public var commandTag: String
    public var affected: Int?
    /// True for a statement that returns a row set (even an empty one), false for a plain command.
    public var returnsRows: Bool
}

/// The statements of one `readOnlyTransaction`. Valid only inside its body, which runs on the connection's queue.
public struct PGTransaction: @unchecked Sendable {
    fileprivate let connection: PGConnection

    /// Runs one statement and answers with its rows and command tag. Throws `PGError` (with the position and detail).
    public func execute(_ sql: String, params: [String?] = []) throws -> PGStatementResult {
        let raw = try connection.runRaw(sql, params: params)
        return PGStatementResult(page: raw.page, commandTag: raw.commandTag, affected: raw.affected, returnsRows: raw.returnsRows)
    }
}

extension String {
    fileprivate func trimmingTrailingNewlines() -> String {
        var s = self
        while s.last == "\n" || s.last == "\r" { s.removeLast() }
        return s
    }
}
