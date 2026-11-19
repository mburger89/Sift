import CLibPQ
import Dispatch
import SiftCore

/// A failure from libpq, carrying `PQerrorMessage` (or `PQresultErrorMessage`).
public struct PGError: Error, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
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
    public init(conninfo: String) throws {
        guard let c = PQconnectdb(conninfo) else { throw PGError("PQconnectdb returned nil") }
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

    /// Runs one statement with text parameters (`nil` is NULL) and text results.
    public func query(_ sql: String, params: [String?] = []) throws -> ResultPage {
        try queue.sync {
            guard let conn else { throw PGError("connection is closed") }
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
                throw PGError(String(cString: PQerrorMessage(conn)).trimmingTrailingNewlines())
            }
            defer { PQclear(result) }

            switch PQresultStatus(result) {
            case PGRES_TUPLES_OK:
                return Self.page(from: result)
            case PGRES_COMMAND_OK, PGRES_EMPTY_QUERY:
                return ResultPage(columns: [], rows: [])
            default:
                throw PGError(String(cString: PQresultErrorMessage(result)).trimmingTrailingNewlines())
            }
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
