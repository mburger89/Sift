/// The real clock: `sleep` waits on the wall clock. Tests inject a manual one instead.
public struct SystemClock: SiftClock {
    public init() {}

    public func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
