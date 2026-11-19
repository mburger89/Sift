import SiftCore

/// A clock that only moves when a test says so. `sleep` suspends until
/// `advance(by:)` has moved time past the sleeper's deadline.
public actor ManualClock: SiftClock {
    private struct Sleeper {
        var id: Int
        var deadline: Double
        var continuation: CheckedContinuation<Void, any Error>
    }

    private var now: Double = 0
    private var nextID = 0
    private var sleepers: [Sleeper] = []
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Every duration passed to `sleep`, in call order.
    public private(set) var sleeps: [Double] = []

    public init() {}

    public func sleep(seconds: Double) async throws {
        sleeps.append(seconds)
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    c.resume(throwing: CancellationError())
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: now + seconds, continuation: c))
                wake()
            }
        } onCancel: {
            Task { await self.cancelSleeper(id) }
        }
    }

    /// Moves time forward and resumes every sleeper whose deadline has passed.
    public func advance(by seconds: Double) {
        now += seconds
        let due = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        for s in due { s.continuation.resume() }
    }

    /// Returns once at least `n` tasks are suspended in `sleep`.
    public func waitForSleepers(_ n: Int) async {
        if sleepers.count >= n { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            watchers.append((n, c))
        }
    }

    private func cancelSleeper(_ id: Int) {
        guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: i).continuation.resume(throwing: CancellationError())
    }

    private func wake() {
        let ready = watchers.filter { $0.count <= sleepers.count }
        watchers.removeAll { $0.count <= sleepers.count }
        for w in ready { w.continuation.resume() }
    }
}
