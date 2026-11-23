/// Why a statement failed, as the editor shows it. The message never carries a password or the SQL text.
public struct QueryFailure: Sendable, Equatable {
    public var message: String
    public var sqlState: String?
    /// The 1-based character offset in the text that was sent, when the server pointed at one.
    public var position: Int?
    public var detail: String?
    public var hint: String?

    public init(message: String, sqlState: String? = nil, position: Int? = nil, detail: String? = nil, hint: String? = nil) {
        self.message = message
        self.sqlState = sqlState
        self.position = position
        self.detail = detail
        self.hint = hint
    }

    /// The SQLSTATE a read-only transaction answers a write with.
    public static let readOnlyViolation = "25006"
    /// The SQLSTATE of a cancel or a statement timeout.
    public static let queryCanceled = "57014"
}

/// What one run of one statement came to.
public struct QueryOutcome: Sendable {
    public enum Kind: Sendable, Equatable {
        /// A row-returning statement: the rows captured (at most the runner's cap), and whether more existed.
        case rows(columns: [ResultColumn], rows: [[SiftValue]], truncated: Bool)
        /// Any other statement: its command tag (`CREATE TABLE`) and the rows it touched, when it says.
        case command(tag: String, affected: Int?)
        /// The user cancelled the statement.
        case cancelled
        case failed(QueryFailure)
    }

    public var kind: Kind
    /// Seconds from sending the statement to the transaction's end.
    public var duration: Double

    public init(kind: Kind, duration: Double) {
        self.kind = kind
        self.duration = duration
    }
}

/// What the editor runs SQL through: one statement at a time, read-only, cancellable. Postgres implements it with
/// `PGQueryRunner`; tests use a fake.
public protocol QueryRunning: AnyObject, Sendable {
    /// Runs `sql` and answers; it never throws, a failure is an outcome. `statementTimeout` is a server interval
    /// such as `60s`, or `0` for none.
    func run(_ sql: String, statementTimeout: String) async -> QueryOutcome
    /// Asks the server to stop the statement now running, if any.
    func cancel()
    /// Releases the connection.
    func close()
}

/// The statement timeouts the editor offers (decision: per connection, from a fixed menu).
public enum QueryTimeout: String, Sendable, CaseIterable, Equatable {
    case s15, s60, m5, none

    /// The default: 60 seconds.
    public static let `default` = QueryTimeout.s60

    /// The value of `SET LOCAL statement_timeout`: `0` is none.
    public var setting: String {
        switch self {
        case .s15: return "15s"
        case .s60: return "60s"
        case .m5: return "5min"
        case .none: return "0"
        }
    }

    public var title: String {
        switch self {
        case .s15: return "15 s"
        case .s60: return "60 s"
        case .m5: return "5 min"
        case .none: return "No timeout"
        }
    }
}
