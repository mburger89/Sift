import Foundation
import SiftDocker

public final class FakeDockerDiscovery: DockerDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: Result<[DiscoveredDatabase], Error>
    private var _calls = 0

    public init(result: Result<[DiscoveredDatabase], Error> = .success([])) { _result = result }

    public var result: Result<[DiscoveredDatabase], Error> {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }

    public var calls: Int { lock.withLock { _calls } }

    public func listPostgresContainers() async throws -> [DiscoveredDatabase] {
        let current = lock.withLock { () -> Result<[DiscoveredDatabase], Error> in
            _calls += 1
            return _result
        }
        return try current.get()
    }
}
