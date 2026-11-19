import SiftCore

public enum PasswordSource: Sendable, Equatable {
    case containerEnv
    case file(String)
    case none
}

public enum ContainerRoute: Sendable, Equatable {
    case publishedPort, orbStackNetwork, unreachable
}

/// A Postgres container and how to reach it. The password is a `Secret`, so printing
/// this value never shows it.
public struct DiscoveredDatabase: Sendable, Equatable, Identifiable {
    /// The container name: stable across a recreated container (the id and OIDs are not).
    public var id: String { containerName }
    public var containerID: String
    public var containerName: String
    public var image: String
    public var isRunning: Bool
    public var engine: DockerEngine
    public var route: ContainerRoute
    public var host: String?
    public var port: Int?
    public var user: String
    public var database: String
    public var password: Secret?
    public var passwordSource: PasswordSource
    public var composeProject: String?

    public init(
        containerID: String, containerName: String, image: String, isRunning: Bool, engine: DockerEngine,
        route: ContainerRoute, host: String?, port: Int?, user: String, database: String,
        password: Secret?, passwordSource: PasswordSource, composeProject: String?
    ) {
        self.containerID = containerID
        self.containerName = containerName
        self.image = image
        self.isRunning = isRunning
        self.engine = engine
        self.route = route
        self.host = host
        self.port = port
        self.user = user
        self.database = database
        self.password = password
        self.passwordSource = passwordSource
        self.composeProject = composeProject
    }
}
