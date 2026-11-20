import Foundation
import SiftCore

/// A `MapPositionsStoring` that keeps the positions in memory and counts every save.
public final class InMemoryMapPositionsStore: MapPositionsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _positions: [String: [String: [Double]]]
    private var _saves = 0

    public init(_ positions: [String: [String: [Double]]] = [:]) { _positions = positions }

    /// How many times `save` was called.
    public var saves: Int { lock.withLock { _saves } }
    /// Every identity's positions as last saved.
    public var all: [String: [String: [Double]]] { lock.withLock { _positions } }

    public func load(identity: String) -> [String: [Double]] { lock.withLock { _positions[identity] ?? [:] } }

    public func save(identity: String, positions: [String: [Double]]) {
        lock.withLock {
            _positions[identity] = positions
            _saves += 1
        }
    }
}
