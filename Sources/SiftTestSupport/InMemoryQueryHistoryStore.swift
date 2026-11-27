import Foundation
import SiftCore

/// A `QueryHistoryStoring` that keeps the entries in memory and counts every save.
public final class InMemoryQueryHistoryStore: QueryHistoryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [String: [QueryHistoryEntry]]
    private var _saves = 0

    public init(_ entries: [String: [QueryHistoryEntry]] = [:]) { _entries = entries }

    public var saves: Int { lock.withLock { _saves } }
    public var all: [String: [QueryHistoryEntry]] { lock.withLock { _entries } }

    public func load(identity: String) -> [QueryHistoryEntry] { lock.withLock { _entries[identity] ?? [] } }

    public func save(identity: String, entries: [QueryHistoryEntry]) {
        lock.withLock {
            _entries[identity] = entries
            _saves += 1
        }
    }
}
