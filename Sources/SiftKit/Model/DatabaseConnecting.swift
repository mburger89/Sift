import SiftCore
import SiftDocker
import SiftPG

/// What to connect to. The password of a saved connection comes from the `CredentialStore` at connect
/// time; a container's comes from its environment. Neither is ever printed (`Secret` masks it).
public enum ConnectionTarget: Sendable, Equatable {
    case saved(SavedConnection, password: Secret?)
    case discovered(DiscoveredDatabase)
}

/// Opens a read-only `DatabaseSource` for a target.
public protocol DatabaseConnecting: Sendable {
    func connect(_ target: ConnectionTarget) async throws -> any DatabaseSource
}

/// The libpq connector: every session is read-only (decision D5).
public struct PGConnector: DatabaseConnecting {
    public init() {}

    public func connect(_ target: ConnectionTarget) async throws -> any DatabaseSource {
        try await PGSource.connect(try Self.parameters(for: target))
    }

    /// The libpq parameters for a target, or a `SourceError` saying why it cannot be reached.
    static func parameters(for target: ConnectionTarget) throws -> PGConnectionParameters {
        switch target {
        case .saved(let saved, let password):
            return PGConnectionParameters(
                host: saved.host, port: saved.port, database: saved.database, user: saved.user,
                password: password, sslMode: PGSSLMode(rawValue: saved.sslMode) ?? .prefer)
        case .discovered(let container):
            guard container.isRunning else { throw SourceError(.other, "\(container.containerName) is not running") }
            guard let host = container.host, let port = container.port else {
                throw SourceError(.other, "Port 5432 is not published by \(container.containerName)")
            }
            return PGConnectionParameters(
                host: host, port: port, database: container.database, user: container.user,
                password: container.password, sslMode: .prefer)
        }
    }
}
