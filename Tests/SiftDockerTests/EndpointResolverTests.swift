import Foundation
import Testing

@testable import SiftDocker

@Suite struct EndpointResolverTests {
    /// A fake machine: `files` maps a path to its contents, directories are derived from them.
    static func env(
        _ variables: [String: String] = [:],
        files: [String: String] = [:],
        sockets: Set<String> = [],
        windows: Bool = false
    ) -> DockerHostEnvironment {
        DockerHostEnvironment(
            variables: variables,
            home: "/h",
            isWindows: windows,
            fileExists: { files.keys.contains($0) || sockets.contains($0) },
            readFile: { files[$0].map { Array($0.utf8) } },
            listDirectory: { dir in
                let prefix = dir + "/"
                return Set(files.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count).split(separator: "/")[0]) })
                    .sorted()
            }
        )
    }

    static let orbContext: [String: String] = [
        "/h/.docker/config.json": #"{"currentContext":"orbstack"}"#,
        "/h/.docker/contexts/meta/abc/meta.json":
            #"{"Name":"orbstack","Endpoints":{"docker":{"Host":"unix:///u/.orbstack/run/docker.sock"}}}"#,
        "/h/.docker/contexts/meta/def/meta.json":
            #"{"Name":"other","Endpoints":{"docker":{"Host":"unix:///other.sock"}}}"#
    ]

    @Test func dockerHostIsTheOnlyCandidate() throws {
        let env = Self.env(["DOCKER_HOST": "unix:///tmp/x.sock", "XDG_RUNTIME_DIR": "/run/user/501"])
        let found = try DockerEndpointResolver.candidates(in: env)
        #expect(found == [DockerEndpointCandidate(.unixSocket(path: "/tmp/x.sock"), .dockerHost)])
    }

    @Test func tcpDockerHostIsUnsupported() {
        #expect(throws: DockerError.unsupportedScheme("tcp")) {
            try DockerEndpointResolver.candidates(in: Self.env(["DOCKER_HOST": "tcp://10.0.0.1:2375"]))
        }
    }

    @Test func currentContextComesFromConfigAndMeta() throws {
        let found = try DockerEndpointResolver.candidates(in: Self.env(files: Self.orbContext))
        #expect(found[0].source == .context("orbstack"))
        #expect(found[0].endpoint == .unixSocket(path: "/u/.orbstack/run/docker.sock"))
    }

    @Test func dockerContextEnvironmentWinsOverConfig() throws {
        let found = try DockerEndpointResolver.candidates(in: Self.env(["DOCKER_CONTEXT": "other"], files: Self.orbContext))
        #expect(found[0].source == .context("other"))
        #expect(found[0].endpoint == .unixSocket(path: "/other.sock"))
    }

    @Test func dockerConfigEnvironmentMovesTheConfigDirectory() throws {
        let files = [
            "/cfg/config.json": #"{"currentContext":"moved"}"#,
            "/cfg/contexts/meta/x/meta.json": #"{"Name":"moved","Endpoints":{"docker":{"Host":"unix:///moved.sock"}}}"#
        ]
        let found = try DockerEndpointResolver.candidates(in: Self.env(["DOCKER_CONFIG": "/cfg"], files: files))
        #expect(found[0].source == .context("moved"))
    }

    @Test func defaultOrderWithoutAContext() throws {
        let found = try DockerEndpointResolver.candidates(in: Self.env(["XDG_RUNTIME_DIR": "/run/user/501"]))
        #expect(found.map(\.endpoint.path) == ["/h/.orbstack/run/docker.sock", "/var/run/docker.sock", "/run/user/501/docker.sock"])
        #expect(found.map(\.source) == [.orbStack, .system, .rootless])
    }

    @Test func rootlessNeedsXDGRuntimeDir() throws {
        #expect(try DockerEndpointResolver.candidates(in: Self.env()).count == 2)
    }

    @Test func defaultContextIsSkipped() throws {
        let files = ["/h/.docker/config.json": #"{"currentContext":"default"}"#]
        let found = try DockerEndpointResolver.candidates(in: Self.env(files: files))
        #expect(found[0].source == .orbStack)
    }

    @Test func windowsUsesTheEnginePipe() throws {
        let pipe = DockerEndpoint.namedPipe(path: #"\\.\pipe\docker_engine"#)
        #expect(try DockerEndpointResolver.candidates(in: Self.env(windows: true)).map(\.endpoint) == [pipe])
        let viaHost = try DockerEndpointResolver.candidates(
            in: Self.env(["DOCKER_HOST": "npipe:////./pipe/docker_engine"], windows: true)
        )
        #expect(viaHost.map(\.endpoint) == [pipe])
    }

    @Test func resolvePicksTheFirstThatExists() throws {
        let found = try DockerEndpointResolver.resolve(in: Self.env(sockets: ["/var/run/docker.sock"]))
        #expect(found.source == .system)
    }

    @Test func nothingExistsListsWhatWasTried() {
        #expect(
            throws: DockerError.noEndpoint(tried: ["/h/.orbstack/run/docker.sock", "/var/run/docker.sock", "/run/user/1/docker.sock"])
        ) {
            try DockerEndpointResolver.resolve(in: Self.env(["XDG_RUNTIME_DIR": "/run/user/1"]))
        }
    }

    @Test func socketPathTooLongIsReported() {
        let long = "/" + String(repeating: "a", count: 119)
        #expect(throws: DockerError.socketPathTooLong(long)) {
            try DockerEndpointResolver.resolve(in: Self.env(["DOCKER_HOST": "unix://" + long], sockets: [long]))
        }
    }

    @Test func engineFollowsThePath() {
        #expect(DockerEndpointCandidate(.unixSocket(path: "/h/.orbstack/run/docker.sock"), .orbStack).engine == .orbStack)
        #expect(DockerEndpointCandidate(.unixSocket(path: "/h/.docker/run/docker.sock"), .system).engine == .dockerDesktop)
        #expect(DockerEndpointCandidate(.unixSocket(path: "/var/run/docker.sock"), .system).engine == .other)
    }
}
