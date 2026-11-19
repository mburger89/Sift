import Foundation
import SiftCore
import SiftDocker

/// Everything the app talks to, injected so tests can replace each piece.
public struct SiftEnvironment: Sendable {
    public var connections: any ConnectionStoring
    public var credentials: any CredentialStore
    public var discovery: any DockerDiscovering
    public var connector: any DatabaseConnecting
    public var clock: any SiftClock
    /// Where dragged tables' positions are remembered, per database.
    public var mapPositions: any MapPositionsStoring

    public init(
        connections: any ConnectionStoring, credentials: any CredentialStore, discovery: any DockerDiscovering,
        connector: any DatabaseConnecting, clock: any SiftClock,
        mapPositions: any MapPositionsStoring
    ) {
        self.connections = connections
        self.credentials = credentials
        self.discovery = discovery
        self.connector = connector
        self.clock = clock
        self.mapPositions = mapPositions
    }

    /// The real thing: the app's support directory, in-memory passwords, Docker or OrbStack, libpq.
    public static func live() -> Self {
        let directory = AppPaths.supportDirectory(
            platform: AppPaths.currentPlatform, env: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
        return SiftEnvironment(
            connections: ConnectionStore(directory: directory), credentials: InMemoryCredentialStore(),
            discovery: DockerDiscovery(), connector: PGConnector(), clock: SystemClock(),
            mapPositions: MapPositionsStore(directory: directory))
    }
}
