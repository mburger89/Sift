import Foundation
import SiftCore

/// A `QueryRunning` for editor tests: it records the SQL it is given, answers from a script, and can hold an answer
/// until the test releases it (or the editor cancels it).
public final class FakeQueryRunner: QueryRunning, @unchecked Sendable {
    public struct Call: Equatable, Sendable {
        public var sql: String
        public var statementTimeout: String
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _cancelCalls = 0
    private var _closed = false
    private var _holds = false
    private var _script: [QueryOutcome.Kind] = []
    private var _fallback: QueryOutcome.Kind = .command(tag: "OK", affected: nil)
    private var _answer: (@Sendable (String) -> QueryOutcome.Kind)?
    private var waiting: CheckedContinuation<QueryOutcome.Kind?, Never>?

    public init() {}

    /// Every statement it was asked to run, in order.
    public var calls: [Call] { lock.withLock { _calls } }
    public var sql: [String] { calls.map(\.sql) }
    public var cancelCalls: Int { lock.withLock { _cancelCalls } }
    public var isClosed: Bool { lock.withLock { _closed } }

    /// While true, a run waits until `release(_:)` or `cancel()`.
    public var holds: Bool {
        get { lock.withLock { _holds } }
        set { lock.withLock { _holds = newValue } }
    }

    /// The outcomes the next runs answer, in order; after them `fallback` repeats.
    public func script(_ kinds: QueryOutcome.Kind...) { lock.withLock { _script = kinds } }
    public var fallback: QueryOutcome.Kind {
        get { lock.withLock { _fallback } }
        set { lock.withLock { _fallback = newValue } }
    }
    /// Answers by looking at the SQL; wins over the script.
    public func answer(_ body: @escaping @Sendable (String) -> QueryOutcome.Kind) { lock.withLock { _answer = body } }

    /// Whether a run is waiting on a hold.
    public var isHolding: Bool { lock.withLock { waiting != nil } }

    /// Lets a held run finish with `kind`.
    public func release(_ kind: QueryOutcome.Kind = .command(tag: "OK", affected: nil)) {
        let c = lock.withLock { () -> CheckedContinuation<QueryOutcome.Kind?, Never>? in
            defer { waiting = nil }
            return waiting
        }
        c?.resume(returning: kind)
    }

    public func run(_ sql: String, statementTimeout: String) async -> QueryOutcome {
        let (held, planned): (Bool, QueryOutcome.Kind) = lock.withLock {
            _calls.append(Call(sql: sql, statementTimeout: statementTimeout))
            let kind = _answer?(sql) ?? (_script.isEmpty ? _fallback : _script.removeFirst())
            return (_holds, kind)
        }
        if held {
            let released: QueryOutcome.Kind? = await withCheckedContinuation { c in lock.withLock { waiting = c } }
            return QueryOutcome(kind: released ?? .cancelled, duration: 0.01)
        }
        return QueryOutcome(kind: planned, duration: 0.01)
    }

    /// Counts the call, and ends a held run as cancelled.
    public func cancel() {
        let c = lock.withLock { () -> CheckedContinuation<QueryOutcome.Kind?, Never>? in
            _cancelCalls += 1
            defer { waiting = nil }
            return waiting
        }
        c?.resume(returning: nil)
    }

    public func close() { lock.withLock { _closed = true } }
}
