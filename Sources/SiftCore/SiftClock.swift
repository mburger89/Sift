/// Time as an injected dependency, so reconnect back-off is testable.
public protocol SiftClock: Sendable {
    func sleep(seconds: Double) async throws
}
