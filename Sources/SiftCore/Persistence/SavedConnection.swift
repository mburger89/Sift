import Foundation

/// A connection the user saved. It has **no password field** (decision D12): a password lives in a
/// `CredentialStore` under the connection's id, never in this value or in `connections.json`.
public struct SavedConnection: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var database: String
    public var user: String
    /// A libpq `sslmode` keyword (`PGSSLMode`'s raw value).
    public var sslMode: String

    public init(
        id: UUID = UUID(), name: String, host: String, port: Int = 5432, database: String, user: String,
        sslMode: String = "prefer"
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.sslMode = sslMode
    }
}
