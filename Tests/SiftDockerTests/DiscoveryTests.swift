import Foundation
import SiftTestSupport
import Testing

@testable import SiftDocker

@Suite struct DiscoveryTests {
    static func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static let idShop = String(repeating: "a", count: 64)
    static let idOld = String(repeating: "b", count: 64)
    static let idCache = String(repeating: "c", count: 64)

    static func daemon() throws -> FakeDockerDaemon {
        try FakeDockerDaemon(routes: [
            "/containers/json?all=1": .init(body: try fixture("containers-list")),
            "/containers/\(idShop)/json": .init(body: try fixture("inspect-postgres16"), chunked: true),
            "/containers/\(idOld)/json": .init(body: try fixture("inspect-old-db"))
        ])
    }

    @Test func listsOnlyPostgresAndInspectsOnlyCandidates() async throws {
        let daemon = try Self.daemon()
        defer { daemon.stop() }
        let discovery = DockerDiscovery(client: DockerClient(endpoint: daemon.endpoint), engine: .orbStack)
        let found = try await discovery.listPostgresContainers()
        #expect(found.map(\.containerName) == ["old-db", "shop-db"])
        #expect(found.first?.isRunning == false)
        #expect(found.last?.password?.reveal() == "s3cret")
        #expect(daemon.requests == ["GET /containers/json?all=1", "GET /containers/\(Self.idOld)/json", "GET /containers/\(Self.idShop)/json"])
    }

    @Test func aContainerRemovedMidWayIsSkipped() async throws {
        let daemon = try FakeDockerDaemon(routes: [
            "/containers/json?all=1": .init(body: try Self.fixture("containers-list")),
            "/containers/\(Self.idShop)/json": .init(body: try Self.fixture("inspect-postgres16"))
        ])
        defer { daemon.stop() }
        let found = try await DockerDiscovery(client: DockerClient(endpoint: daemon.endpoint), engine: .other).listPostgresContainers()
        #expect(found.map(\.containerName) == ["shop-db"])
    }

    #if !os(Windows)
    @Test func theEnvironmentPicksTheEndpointAndEngine() async throws {
        let daemon = try Self.daemon()
        defer { daemon.stop() }
        let env = EndpointResolverTests.env(["DOCKER_HOST": "unix://\(daemon.endpoint.path)"], sockets: [daemon.endpoint.path])
        let found = try await DockerDiscovery(environment: env).listPostgresContainers()
        #expect(found.count == 2)
    }

    @Test func noDockerReportsWhatWasTried() async {
        let env = EndpointResolverTests.env()
        await #expect(throws: DockerError.noEndpoint(tried: ["/h/.orbstack/run/docker.sock", "/var/run/docker.sock"])) {
            try await DockerDiscovery(environment: env).listPostgresContainers()
        }
    }

    #endif

    @Test func badJSONNamesThePathNotTheValue() async throws {
        let daemon = try FakeDockerDaemon(routes: ["/containers/json?all=1": .init(body: #"{"Id":"s3cret"}"#)])
        defer { daemon.stop() }
        do {
            _ = try await DockerDiscovery(client: DockerClient(endpoint: daemon.endpoint), engine: .other).listPostgresContainers()
            Issue.record("expected a decoding error")
        } catch {
            #expect(!String(describing: error).contains("s3cret"))
            #expect(error is DockerError)
        }
    }

    @Test func fakeDiscoveryCountsCallsAndReturnsItsResult() async throws {
        let fake = FakeDockerDiscovery()
        #expect(try await fake.listPostgresContainers().isEmpty)
        fake.result = .failure(DockerError.timedOut)
        await #expect(throws: DockerError.timedOut) { try await fake.listPostgresContainers() }
        #expect(fake.calls == 2)
    }

    #if os(Windows)
    @Test func namedPipeEndToEnd() async throws {
        let daemon = try Self.daemon()
        defer { daemon.stop() }
        guard case .namedPipe = daemon.endpoint else { Issue.record("expected a named pipe"); return }
        let found = try await DockerDiscovery(client: DockerClient(endpoint: daemon.endpoint), engine: .other).listPostgresContainers()
        #expect(found.map(\.containerName) == ["old-db", "shop-db"])
        #expect(daemon.requests == ["GET /containers/json?all=1", "GET /containers/\(Self.idOld)/json", "GET /containers/\(Self.idShop)/json"])
    }
    #endif

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIFT_DOCKER_LIVE"] == "1", "SIFT_DOCKER_LIVE is not 1"))
    func liveDockerAnswers() async throws {
        _ = try await DockerDiscovery().listPostgresContainers()
    }
}
