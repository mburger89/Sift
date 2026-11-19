/// A password or token. It prints and reflects as a mask, and is deliberately
/// not `Codable`, so it cannot reach a log, a JSON file or a test failure message
/// by accident. Call `reveal()` only where the value is handed to libpq.
public struct Secret: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init(_ value: String) { self.value = value }

    /// The real value.
    public func reveal() -> String { value }

    public var description: String { "••••••" }
    public var debugDescription: String { "Secret(••••••)" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
