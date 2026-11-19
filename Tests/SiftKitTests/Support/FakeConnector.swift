import Foundation
import SiftCore
import SiftKit
import SiftTestSupport

/// A `DatabaseConnecting` that hands out `FakeSource`s in order (the last one repeats) and records
/// every target it was asked for. It lives in the UI tests because the protocol is SiftKit's.
final class FakeConnector: DatabaseConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _sources: [FakeSource]
    private var _targets: [ConnectionTarget] = []
    private var _failures: [any Error] = []

    init(_ sources: [FakeSource]) { _sources = sources }

    var targets: [ConnectionTarget] { lock.withLock { _targets } }

    /// The next `count` connects throw, one after another, before sources are handed out again.
    func failNext(_ errors: [any Error]) { lock.withLock { _failures.append(contentsOf: errors) } }

    func connect(_ target: ConnectionTarget) async throws -> any DatabaseSource {
        let outcome: Result<FakeSource, any Error> = lock.withLock {
            _targets.append(target)
            if !_failures.isEmpty { return .failure(_failures.removeFirst()) }
            return .success(_sources.count > 1 ? _sources.removeFirst() : _sources[0])
        }
        return try outcome.get()
    }
}
