import Dispatch
import Foundation
import SiftCore

/// Runs the SQL editor's statements, one at a time, on a connection of its own.
///
/// **Read-only, always.** Every statement runs inside `BEGIN READ ONLY` (`readOnlyTransaction`), so the server refuses a
/// write with SQLSTATE `25006`. **A run never leaves a transaction open:** the statement ends in `COMMIT`, or in
/// `ROLLBACK` when anything failed, was cancelled or timed out.
///
/// - A statement that starts with `SELECT`, `WITH`, `VALUES`, `TABLE` or `SHOW` goes through
///   `DECLARE sift_q NO SCROLL CURSOR FOR …`, and `FETCH 1000` brings up to `rowCap` rows into memory, then `CLOSE`.
///   If the server refuses the `DECLARE` as a syntax error (`42601`, as `SHOW` is) or as not allowed (`0A000`, a
///   data-modifying `WITH`), the statement runs plainly, under a savepoint, in the same transaction; its own error then
///   carries a position in the text the user wrote.
/// - Any other statement runs plainly.
///
/// SQL text is never logged here, and it only ever reaches the server as the statement itself.
public final class PGQueryRunner: QueryRunning, @unchecked Sendable {
    /// A row-returning statement keeps at most this many rows (decision: 100 000).
    public static let rowCap = 100_000
    /// Rows asked of the cursor per `FETCH`.
    static let fetchSize = 1000
    static let cursorKeywords: Set<String> = ["SELECT", "WITH", "VALUES", "TABLE", "SHOW"]
    static let declarePrefix = "DECLARE sift_q NO SCROLL CURSOR FOR "

    private let lock = NSLock()
    private var connection: PGConnection?
    private let parameters: PGConnectionParameters?
    private var closed = false
    private var running = false
    private var cancelRequested = false

    /// Runs over a connection the caller owns. `close()` closes it.
    public init(connection: PGConnection) {
        self.connection = connection
        self.parameters = nil
    }

    /// Runs over a connection opened read-only at the first run, and opened again after it breaks.
    public init(parameters: PGConnectionParameters) {
        var p = parameters
        p.readOnly = true
        self.parameters = p
    }

    /// The server process of the connection, once there is one. For tests.
    public var backendPID: Int32? { lock.withLock { connection }?.backendPID }

    private enum Done: Sendable {
        case rows(columns: [ResultColumn], rows: [[SiftValue]], truncated: Bool)
        case command(tag: String, affected: Int?)
    }

    // MARK: Running

    public func run(_ sql: String, statementTimeout: String) async -> QueryOutcome {
        let started = ContinuousClock.now
        func outcome(_ kind: QueryOutcome.Kind) -> QueryOutcome {
            let elapsed = ContinuousClock.now - started
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return QueryOutcome(kind: kind, duration: seconds)
        }
        // The flag is cleared here and nowhere else: a `cancel()` that came before this run started it, so it is
        // dropped; one that comes after is kept, whatever the run is doing.
        lock.withLock {
            running = true
            cancelRequested = false
        }
        defer { lock.withLock { running = false } }
        let connection: PGConnection
        do { connection = try await ready() } catch let e as PGError {
            return outcome(.failed(QueryFailure(message: e.primaryMessage ?? e.message, sqlState: e.sqlState)))
        } catch {
            return outcome(.failed(QueryFailure(message: String(describing: error))))
        }
        if lock.withLock({ cancelRequested }) { return outcome(.cancelled) }
        do {
            let done = try await connection.readOnlyTransaction(statementTimeout: statementTimeout) { tx in
                // Last look before the statement goes out: a cancel that landed before it reached the server would
                // otherwise find nothing to stop. Throwing rolls the transaction back.
                if self.lock.withLock({ self.cancelRequested }) { throw SourceError(.cancelled, "Cancelled") }
                return try Self.execute(sql, in: tx)
            }
            switch done {
            case .rows(let columns, let rows, let truncated): return outcome(.rows(columns: columns, rows: rows, truncated: truncated))
            case .command(let tag, let affected): return outcome(.command(tag: tag, affected: affected))
            }
        } catch let e as SourceError where e.kind == .cancelled {
            return outcome(.cancelled)
        } catch let e as PGError {
            if e.sqlState == QueryFailure.queryCanceled, lock.withLock({ cancelRequested }) { return outcome(.cancelled) }
            return outcome(.failed(Self.failure(e)))
        } catch {
            return outcome(.failed(QueryFailure(message: String(describing: error))))
        }
    }

    /// The statements of one run, inside the transaction. Runs on the connection's queue.
    private static func execute(_ sql: String, in tx: PGTransaction) throws -> Done {
        if startsCursor(sql) {
            _ = try tx.execute("SAVEPOINT sift_decl")
            do {
                do {
                    _ = try tx.execute(declarePrefix + stripTrailingSemicolons(sql))
                } catch var e as PGError {
                    // A position counts the whole `DECLARE … FOR` text: take its prefix off, so it points into the user's text.
                    if let p = e.position { e.position = p > declarePrefix.count ? p - declarePrefix.count : nil }
                    throw e
                }
                return try fetchAll(in: tx)
            } catch let e as PGError where e.sqlState == "42601" || e.sqlState == "0A000" {
                // Not a cursor-able statement (or not valid at all: the plain run reports the same error, with a position in the
                // text as written).
                _ = try tx.execute("ROLLBACK TO SAVEPOINT sift_decl")
            }
        }
        let result = try tx.execute(sql)
        if result.returnsRows {
            let columns = result.page.columns
            var rows = result.page.rows
            let truncated = rows.count > rowCap
            if truncated { rows.removeLast(rows.count - rowCap) }
            return .rows(columns: columns, rows: rows, truncated: truncated)
        }
        return .command(tag: result.commandTag, affected: result.affected)
    }

    private static func fetchAll(in tx: PGTransaction) throws -> Done {
        var columns: [ResultColumn] = []
        var rows: [[SiftValue]] = []
        // One more than the cap tells whether more exist.
        let want = rowCap + 1
        while rows.count < want {
            let n = min(fetchSize, want - rows.count)
            let batch = try tx.execute("FETCH \(n) FROM sift_q").page
            if columns.isEmpty { columns = batch.columns }
            rows.append(contentsOf: batch.rows)
            if batch.rows.count < n { break }
        }
        _ = try tx.execute("CLOSE sift_q")
        let truncated = rows.count > rowCap
        if truncated { rows.removeLast(rows.count - rowCap) }
        return .rows(columns: columns, rows: rows, truncated: truncated)
    }

    static func startsCursor(_ sql: String) -> Bool {
        guard let word = SQLStatements.leadingKeyword(Substring(sql)) else { return false }
        return cursorKeywords.contains(word)
    }

    /// `select 1;` becomes `select 1`: after `FOR` the server takes one statement and no terminator. Offsets are unchanged
    /// because only the end is cut.
    static func stripTrailingSemicolons(_ sql: String) -> String {
        var end = sql.endIndex
        while end > sql.startIndex {
            let before = sql.index(before: end)
            let c = sql[before]
            if c == ";" || c == " " || c == "\t" || c == "\n" || c == "\r" { end = before } else { break }
        }
        return String(sql[..<end])
    }

    private static func failure(_ e: PGError) -> QueryFailure {
        QueryFailure(
            message: e.primaryMessage ?? e.message, sqlState: e.sqlState, position: e.position, detail: e.detail, hint: e.hint)
    }

    // MARK: Cancelling and closing

    /// `PQcancel` on this runner's own connection: it stops the statement now running, and nothing else. A cancel with
    /// nothing running is ignored by the server.
    public func cancel() {
        let connection = lock.withLock { () -> PGConnection? in
            cancelRequested = true
            return self.connection
        }
        connection?.cancel()
    }

    public func close() {
        let connection = lock.withLock { () -> PGConnection? in
            closed = true
            defer { self.connection = nil }
            return self.connection
        }
        connection?.close()
    }

    // MARK: Connection

    private func ready() async throws -> PGConnection {
        let (existing, params): (PGConnection?, PGConnectionParameters?) = try lock.withLock {
            if closed { throw PGError("The editor was closed", isConnectionLost: true) }
            if let connection, !connection.isBroken { return (connection, nil) }
            return (nil, parameters)
        }
        if let existing { return existing }
        guard let params else { throw PGError("The editor has no connection", isConnectionLost: true) }
        let opened: PGConnection = try await withCheckedThrowingContinuation { c in
            DispatchQueue.global().async {
                do { c.resume(returning: try PGConnection(parameters: params)) } catch { c.resume(throwing: error) }
            }
        }
        let usable = lock.withLock { () -> Bool in
            if closed { return false }
            connection = opened
            return true
        }
        if !usable {
            opened.close()
            throw PGError("The editor was closed", isConnectionLost: true)
        }
        return opened
    }
}
