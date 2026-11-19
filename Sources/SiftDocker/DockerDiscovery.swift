import Foundation

public protocol DockerDiscovering: Sendable {
    func listPostgresContainers() async throws -> [DiscoveredDatabase]
}

/// Finds Postgres containers through the Docker Engine API (Docker, OrbStack, Colima, ...).
public struct DockerDiscovery: DockerDiscovering {
    private enum Source: Sendable {
        case environment(DockerHostEnvironment)
        case client(DockerClient, DockerEngine)
    }

    private let source: Source

    public init(environment: DockerHostEnvironment = .live) { source = .environment(environment) }
    public init(client: DockerClient, engine: DockerEngine) { source = .client(client, engine) }

    public func listPostgresContainers() async throws -> [DiscoveredDatabase] {
        let source = source
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try Self.discover(source) })
            }
        }
    }

    private static func discover(_ source: Source) throws -> [DiscoveredDatabase] {
        let client: DockerClient
        let engine: DockerEngine
        switch source {
        case .client(let c, let e):
            (client, engine) = (c, e)
        case .environment(let environment):
            let candidate = try DockerEndpointResolver.resolve(in: environment)
            (client, engine) = (DockerClient(endpoint: candidate.endpoint), candidate.engine)
        }

        let summaries = try decode([ContainerSummary].self, from: try client.get("/containers/json?all=1"))
        let candidates = summaries
            .filter { PostgresContainerMatcher.isPostgres(image: $0.image, ports: $0.portKeys) }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }

        var found: [DiscoveredDatabase] = []
        for summary in candidates {
            let response: HTTPResponse
            do {
                response = try client.get("/containers/\(summary.id)/json")
            } catch DockerError.http(status: 404, _) {
                continue  // removed between the list and the inspect
            }
            let details = try decode(ContainerDetails.self, from: response)
            if let database = PostgresContainerMatcher.database(from: details, engine: engine) {
                found.append(database)
            }
        }
        return found.sorted { $0.containerName < $1.containerName }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws(DockerError) -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(response.body))
        } catch let error as DecodingError {
            // Describe where decoding failed, never the values (an environment holds a password).
            let path: [CodingKey]
            switch error {
            case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c):
                path = c.codingPath
            @unknown default:
                path = []
            }
            throw .decoding("\(type): bad JSON at \(path.map(\.stringValue).joined(separator: "."))")
        } catch {
            throw .decoding("\(type): bad JSON")
        }
    }
}
