import SiftCore

public enum PostgresContainerMatcher {
    private static let imageWords = ["postgres", "postgis", "timescaledb", "pgvector"]

    /// True when the image's repository name looks like Postgres, or `5432/tcp` is exposed or published.
    public static func isPostgres(image: String, ports: Set<String>) -> Bool {
        if ports.contains("5432/tcp") { return true }
        var reference = image.lowercased()
        if let at = reference.firstIndex(of: "@") { reference = String(reference[..<at]) }
        let last = reference.split(separator: "/").last.map(String.init) ?? reference
        let repository = last.split(separator: ":", maxSplits: 1).first.map(String.init) ?? last
        return imageWords.contains { repository.contains($0) }
    }

    public static func database(from details: ContainerDetails, engine: DockerEngine) -> DiscoveredDatabase? {
        let bindings = publishedBindings(details)
        var ports = Set(details.config.exposedPorts)
        ports.formUnion(details.networkSettings.ports.keys)
        ports.formUnion(details.hostConfig.portBindings.keys)
        guard isPostgres(image: details.config.image, ports: ports) else { return nil }

        var env: [String: String] = [:]
        for entry in details.config.env {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        let user = nonEmpty(env["POSTGRES_USER"]) ?? "postgres"
        let database = nonEmpty(env["POSTGRES_DB"]) ?? user

        let password: Secret?
        let source: PasswordSource
        if env["POSTGRES_HOST_AUTH_METHOD"] == "trust" {
            (password, source) = (nil, .none)
        } else if let value = nonEmpty(env["POSTGRES_PASSWORD"]) {
            (password, source) = (Secret(value), .containerEnv)
        } else if let file = nonEmpty(env["POSTGRES_PASSWORD_FILE"]) {
            (password, source) = (nil, .file(file))
        } else {
            (password, source) = (nil, .none)
        }

        var route = ContainerRoute.unreachable
        var host: String?
        var port: Int?
        if let binding = preferred(bindings), let published = Int(binding.hostPort) {
            route = .publishedPort
            host = hostAddress(binding.hostIP)
            port = published
        } else if engine == .orbStack, details.state.running, let ip = networkIP(details) {
            route = .orbStackNetwork
            host = ip
            port = 5432
        }

        return DiscoveredDatabase(
            containerID: details.id, containerName: details.name, image: details.config.image,
            isRunning: details.state.running, engine: engine, route: route, host: host, port: port,
            user: user, database: database, password: password, passwordSource: source,
            composeProject: details.config.labels["com.docker.compose.project"]
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Bindings of 5432/tcp: the live ones, or the configured ones for a stopped container.
    private static func publishedBindings(_ details: ContainerDetails) -> [PortBinding] {
        if let live = details.networkSettings.ports["5432/tcp"] ?? nil, !live.isEmpty { return live }
        return (details.hostConfig.portBindings["5432/tcp"] ?? nil) ?? []
    }

    private static func preferred(_ bindings: [PortBinding]) -> PortBinding? {
        let usable = bindings.filter { Int($0.hostPort) != nil }
        return usable.first { !$0.hostIP.contains(":") } ?? usable.first
    }

    private static func hostAddress(_ ip: String) -> String {
        switch ip {
        case "", "0.0.0.0": "127.0.0.1"
        case "::": "::1"
        default: ip
        }
    }

    private static func networkIP(_ details: ContainerDetails) -> String? {
        if !details.networkSettings.ipAddress.isEmpty { return details.networkSettings.ipAddress }
        for name in details.networkSettings.networks.keys.sorted() {
            let ip = details.networkSettings.networks[name]?.ipAddress ?? ""
            if !ip.isEmpty { return ip }
        }
        return nil
    }
}
