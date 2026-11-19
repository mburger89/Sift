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
    public init(_ message: String, sqlState: String? = nil, isConnectionLost: Bool = false) {
        self.message = message
        self.sqlState = sqlState
        self.isConnectionLost = isConnectionLost
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

    /// True once libpq reports the connection as no longer usable.
    public var isBroken: Bool {
        queue.sync { conn.map { PQstatus($0) != CONNECTION_OK } ?? true }
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
        guard let conn else { throw PGError("connection is closed", isConnectionLost: true) }
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
            throw PGError(
                String(cString: PQerrorMessage(conn)).trimmingTrailingNewlines(),
                isConnectionLost: PQstatus(conn) == CONNECTION_BAD)
        }
        defer { PQclear(result) }

        switch PQresultStatus(result) {
        case PGRES_TUPLES_OK:
            return Self.page(from: result)
        case PGRES_COMMAND_OK, PGRES_EMPTY_QUERY:
            return ResultPage(columns: [], rows: [])
        default:
            var state: String?
            if let f = PQresultErrorField(result, Int32(UInt8(ascii: "C"))) { state = String(cString: f) }
            // Not classified by SQLSTATE: a dropped socket has none.
            return try {
                throw PGError(
                    String(cString: PQresultErrorMessage(result)).trimmingTrailingNewlines(),
                    sqlState: state, isConnectionLost: PQstatus(conn) == CONNECTION_BAD)
            }()
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

extension String {
    fileprivate func trimmingTrailingNewlines() -> String {
        var s = self
        while s.last == "\n" || s.last == "\r" { s.removeLast() }
        return s
    }
}
