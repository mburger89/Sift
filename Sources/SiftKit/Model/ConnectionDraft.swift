import Foundation
import Observation
import SiftCore

/// The saved-connection form's fields while they are being edited. Never holds a password: password entry
/// waits for MetalUI's `SecureField` (gap G1), and a plain `TextField` is never used for one.
@MainActor
@Observable
public final class ConnectionDraft {
    /// The id of the connection being edited, `nil` for a new one.
    public let editing: UUID?
    public var name: String
    public var host: String
    public var port: String
    public var database: String
    public var user: String
    public var sslMode: String
    /// Why the last Save was refused, if it was.
    public var problem: String?

    public init(
        editing: UUID? = nil, name: String = "", host: String = "127.0.0.1", port: String = "5432",
        database: String = "postgres", user: String = "postgres", sslMode: String = "prefer"
    ) {
        self.editing = editing
        self.name = name
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.sslMode = sslMode
    }

    public convenience init(_ connection: SavedConnection) {
        self.init(
            editing: connection.id, name: connection.name, host: connection.host, port: String(connection.port),
            database: connection.database, user: connection.user, sslMode: connection.sslMode)
    }

    /// The `sslmode` values the form offers.
    public static let sslModes = ["disable", "allow", "prefer", "require", "verify-ca", "verify-full"]

    /// The connection these fields describe, or why they do not describe one.
    public func connection() -> Result<SavedConnection, DraftError> {
        let host = host.trimmingCharacters(in: .whitespaces)
        let database = database.trimmingCharacters(in: .whitespaces)
        let user = user.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return .failure(DraftError("Host is required")) }
        guard let port = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
            return .failure(DraftError("Port must be a number from 1 to 65535"))
        }
        guard !database.isEmpty else { return .failure(DraftError("Database is required")) }
        guard !user.isEmpty else { return .failure(DraftError("User is required")) }
        let name = name.trimmingCharacters(in: .whitespaces)
        return .success(
            SavedConnection(
                id: editing ?? UUID(), name: name.isEmpty ? "\(user)@\(host)" : name, host: host, port: port,
                database: database, user: user, sslMode: sslMode))
    }
}

public struct DraftError: Error, Equatable {
    public var message: String
    init(_ message: String) { self.message = message }
}
