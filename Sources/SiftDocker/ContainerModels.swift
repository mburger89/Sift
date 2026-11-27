import Foundation

/// One entry of `GET /containers/json`.
public struct ContainerSummary: Decodable, Sendable {
    public struct Port: Decodable, Sendable {
        public var privatePort: Int
        public var type: String
        enum CodingKeys: String, CodingKey { case privatePort = "PrivatePort", type = "Type" }
    }

    public var id: String
    public var names: [String]
    public var image: String
    public var state: String
    public var ports: [Port]

    enum CodingKeys: String, CodingKey { case id = "Id", names = "Names", image = "Image", state = "State", ports = "Ports" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        names = try c.decodeIfPresent([String].self, forKey: .names) ?? []
        image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        ports = try c.decodeIfPresent([Port].self, forKey: .ports) ?? []
    }

    /// The container name without Docker's leading slash.
    public var name: String { (names.first ?? id).trimmingPrefix("/") }

    /// `"5432/tcp"` style keys of every port the container lists.
    public var portKeys: Set<String> { Set(ports.map { "\($0.privatePort)/\($0.type)" }) }
}

public struct PortBinding: Decodable, Sendable, Equatable {
    public var hostIP: String
    public var hostPort: String

    public init(hostIP: String, hostPort: String) {
        self.hostIP = hostIP
        self.hostPort = hostPort
    }
    enum CodingKeys: String, CodingKey { case hostIP = "HostIp", hostPort = "HostPort" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostIP = try c.decodeIfPresent(String.self, forKey: .hostIP) ?? ""
        hostPort = try c.decodeIfPresent(String.self, forKey: .hostPort) ?? ""
    }
}

/// The `GET /containers/{id}/json` document. It carries the container's environment, so it
/// prints as its name only.
public struct ContainerDetails: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public struct Config: Decodable, Sendable {
        public var image: String
        public var env: [String]
        public var exposedPorts: [String]
        public var labels: [String: String]
        enum CodingKeys: String, CodingKey { case image = "Image", env = "Env", exposedPorts = "ExposedPorts", labels = "Labels" }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            image = try c.decodeIfPresent(String.self, forKey: .image) ?? ""
            env = try c.decodeIfPresent([String].self, forKey: .env) ?? []
            let exposed = try c.decodeIfPresent([String: [String: String]?].self, forKey: .exposedPorts) ?? [:]
            exposedPorts = exposed.keys.sorted()
            labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        }
    }

    public struct State: Decodable, Sendable {
        public var running: Bool
        enum CodingKeys: String, CodingKey { case running = "Running" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        }
    }

    public struct Network: Decodable, Sendable {
        public var ipAddress: String
        enum CodingKeys: String, CodingKey { case ipAddress = "IPAddress" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ipAddress = try c.decodeIfPresent(String.self, forKey: .ipAddress) ?? ""
        }
    }

    public struct NetworkSettings: Decodable, Sendable {
        public var ports: [String: [PortBinding]?]
        public var ipAddress: String
        public var networks: [String: Network]
        enum CodingKeys: String, CodingKey { case ports = "Ports", ipAddress = "IPAddress", networks = "Networks" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ports = try c.decodeIfPresent([String: [PortBinding]?].self, forKey: .ports) ?? [:]
            ipAddress = try c.decodeIfPresent(String.self, forKey: .ipAddress) ?? ""
            networks = try c.decodeIfPresent([String: Network].self, forKey: .networks) ?? [:]
        }
    }

    public struct HostConfig: Decodable, Sendable {
        public var portBindings: [String: [PortBinding]?]
        enum CodingKeys: String, CodingKey { case portBindings = "PortBindings" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            portBindings = try c.decodeIfPresent([String: [PortBinding]?].self, forKey: .portBindings) ?? [:]
        }
    }

    public var id: String
    public var name: String
    public var config: Config
    public var state: State
    public var networkSettings: NetworkSettings
    public var hostConfig: HostConfig

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", config = "Config", state = "State", networkSettings = "NetworkSettings", hostConfig = "HostConfig"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try c.decodeIfPresent(String.self, forKey: .name) ?? id).trimmingPrefix("/")
        config = try c.decode(Config.self, forKey: .config)
        state = try c.decodeIfPresent(State.self, forKey: .state) ?? State.empty
        networkSettings = try c.decodeIfPresent(NetworkSettings.self, forKey: .networkSettings) ?? NetworkSettings.empty
        hostConfig = try c.decodeIfPresent(HostConfig.self, forKey: .hostConfig) ?? HostConfig.empty
    }

    public var description: String { "ContainerDetails(\(name))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension ContainerDetails.State {
    // swiftlint:disable:next force_try - decoding the literal `{}` cannot fail: every field of this type has a default
    static var empty: Self { try! JSONDecoder().decode(Self.self, from: Data("{}".utf8)) }
}
extension ContainerDetails.NetworkSettings {
    // swiftlint:disable:next force_try - decoding the literal `{}` cannot fail: every field of this type has a default
    static var empty: Self { try! JSONDecoder().decode(Self.self, from: Data("{}".utf8)) }
}
extension ContainerDetails.HostConfig {
    // swiftlint:disable:next force_try - decoding the literal `{}` cannot fail: every field of this type has a default
    static var empty: Self { try! JSONDecoder().decode(Self.self, from: Data("{}".utf8)) }
}

extension String {
    fileprivate func trimmingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
