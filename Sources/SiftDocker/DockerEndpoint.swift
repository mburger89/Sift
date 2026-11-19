import Foundation

/// Where the Docker daemon listens: a unix socket (macOS, Linux) or a named pipe (Windows).
public enum DockerEndpoint: Sendable, Equatable {
    case unixSocket(path: String)
    case namedPipe(path: String)

    /// The socket or pipe path.
    public var path: String {
        switch self {
        case .unixSocket(let path), .namedPipe(let path): path
        }
    }
}

/// Which engine answers, guessed from the socket path.
public enum DockerEngine: Sendable, Equatable {
    case orbStack, dockerDesktop, other
}

/// An endpoint and the reason Sift considers it.
public struct DockerEndpointCandidate: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case dockerHost, context(String), orbStack, system, rootless, windowsDefault
    }

    public var endpoint: DockerEndpoint
    public var source: Source

    public init(_ endpoint: DockerEndpoint, _ source: Source) {
        self.endpoint = endpoint
        self.source = source
    }

    public var engine: DockerEngine {
        let path = endpoint.path
        if path.contains("/.orbstack/") { return .orbStack }
        if path.contains("/.docker/run/") || path.contains("com.docker.docker") { return .dockerDesktop }
        return .other
    }
}

public enum DockerError: Error, Sendable, Equatable {
    case noEndpoint(tried: [String])
    case unsupportedScheme(String)
    case socketPathTooLong(String)
    case connectFailed(String)
    case timedOut
    case http(status: Int, message: String)
    case malformedResponse(String)
    case decoding(String)
}

/// Everything endpoint resolution reads from the machine, so tests can fake it.
public struct DockerHostEnvironment: Sendable {
    public var variables: [String: String]
    public var home: String
    public var isWindows: Bool
    public var fileExists: @Sendable (String) -> Bool
    public var readFile: @Sendable (String) -> [UInt8]?
    public var listDirectory: @Sendable (String) -> [String]

    public init(
        variables: [String: String],
        home: String,
        isWindows: Bool,
        fileExists: @escaping @Sendable (String) -> Bool,
        readFile: @escaping @Sendable (String) -> [UInt8]?,
        listDirectory: @escaping @Sendable (String) -> [String]
    ) {
        self.variables = variables
        self.home = home
        self.isWindows = isWindows
        self.fileExists = fileExists
        self.readFile = readFile
        self.listDirectory = listDirectory
    }

    public static var live: Self {
        #if os(Windows)
        let windows = true
        #else
        let windows = false
        #endif
        return Self(
            variables: ProcessInfo.processInfo.environment,
            home: NSHomeDirectory(),
            isWindows: windows,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            readFile: { path in FileManager.default.contents(atPath: path).map { [UInt8]($0) } },
            listDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
        )
    }
}

public enum DockerEndpointResolver {
    static let windowsPipe = #"\\.\pipe\docker_engine"#

    #if os(macOS)
    static let socketPathLimit = 104
    #else
    static let socketPathLimit = 108
    #endif

    /// Every endpoint worth trying, in order. A `DOCKER_HOST` is the only candidate when set.
    public static func candidates(in env: DockerHostEnvironment) throws(DockerError) -> [DockerEndpointCandidate] {
        if let host = env.variables["DOCKER_HOST"], !host.isEmpty {
            return [DockerEndpointCandidate(try parse(host), .dockerHost)]
        }
        var result: [DockerEndpointCandidate] = []
        if let (name, endpoint) = currentContext(in: env) {
            result.append(DockerEndpointCandidate(endpoint, .context(name)))
        }
        if env.isWindows {
            result.append(DockerEndpointCandidate(.namedPipe(path: windowsPipe), .windowsDefault))
        } else {
            result.append(DockerEndpointCandidate(.unixSocket(path: env.home + "/.orbstack/run/docker.sock"), .orbStack))
            result.append(DockerEndpointCandidate(.unixSocket(path: "/var/run/docker.sock"), .system))
            if let runtime = env.variables["XDG_RUNTIME_DIR"], !runtime.isEmpty {
                result.append(DockerEndpointCandidate(.unixSocket(path: runtime + "/docker.sock"), .rootless))
            }
        }
        var seen: [DockerEndpoint] = []
        return result.filter { candidate in
            if seen.contains(candidate.endpoint) { return false }
            seen.append(candidate.endpoint)
            return true
        }
    }

    /// The first candidate whose socket or pipe exists.
    public static func resolve(in env: DockerHostEnvironment) throws(DockerError) -> DockerEndpointCandidate {
        let all = try candidates(in: env)
        var tooLong: DockerError?
        for candidate in all {
            if case .unixSocket(let path) = candidate.endpoint, path.utf8.count + 1 > socketPathLimit {
                tooLong = tooLong ?? .socketPathTooLong(path)
                continue
            }
            if env.fileExists(candidate.endpoint.path) { return candidate }
        }
        if let tooLong { throw tooLong }
        throw .noEndpoint(tried: all.map(\.endpoint.path))
    }

    static func parse(_ host: String) throws(DockerError) -> DockerEndpoint {
        guard let range = host.range(of: "://") else { throw .unsupportedScheme(host) }
        let scheme = String(host[..<range.lowerBound])
        let rest = String(host[range.upperBound...])
        switch scheme {
        case "unix":
            return .unixSocket(path: rest)
        case "npipe":
            // npipe:////./pipe/docker_engine -> \\.\pipe\docker_engine
            return .namedPipe(path: rest.replacingOccurrences(of: "/", with: "\\"))
        default:
            throw .unsupportedScheme(scheme)
        }
    }

    private static func currentContext(in env: DockerHostEnvironment) -> (String, DockerEndpoint)? {
        let configDir = env.variables["DOCKER_CONFIG"].flatMap { $0.isEmpty ? nil : $0 } ?? env.home + "/.docker"
        var name = env.variables["DOCKER_CONTEXT"] ?? ""
        if name.isEmpty {
            guard let bytes = env.readFile(configDir + "/config.json"),
                  let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                  let current = object["currentContext"] as? String else { return nil }
            name = current
        }
        if name.isEmpty || name == "default" { return nil }
        let metaDir = configDir + "/contexts/meta"
        for entry in env.listDirectory(metaDir).sorted() {
            guard let bytes = env.readFile(metaDir + "/" + entry + "/meta.json"),
                  let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                  object["Name"] as? String == name,
                  let endpoints = object["Endpoints"] as? [String: Any],
                  let docker = endpoints["docker"] as? [String: Any],
                  let host = docker["Host"] as? String,
                  let endpoint = try? parse(host) else { continue }
            return (name, endpoint)
        }
        return nil
    }
}
