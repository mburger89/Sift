import Foundation
import SiftCore

/// A `ConnectionStoring` that keeps the list in memory and records every save.
public final class InMemoryConnectionStore: ConnectionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _connections: [SavedConnection]
    private var _saves: [[SavedConnection]] = []

    public init(_ connections: [SavedConnection] = []) { _connections = connections }

    /// The list as last saved (or as given at init).
    public var connections: [SavedConnection] { lock.withLock { _connections } }
    /// Every list `save` was called with, oldest first.
    public var saved: [[SavedConnection]] { lock.withLock { _saves } }

    public func load() throws -> [SavedConnection] { connections }

    public func save(_ connections: [SavedConnection]) throws {
        lock.withLock {
            _connections = connections
            _saves.append(connections)
        }
    }
}
