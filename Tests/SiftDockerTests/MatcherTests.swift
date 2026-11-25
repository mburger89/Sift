import Foundation
import Testing

@testable import SiftDocker

@Suite struct MatcherTests {
    static func details(_ fixture: String) throws -> ContainerDetails {
        let url = try #require(Bundle.module.url(forResource: fixture, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(ContainerDetails.self, from: Data(contentsOf: url))
    }

    @Test func postgresImageVariantsMatch() {
        for image in [
            "postgres", "postgres:17", "docker.io/library/postgres:16-alpine", "postgis/postgis:16-3.4",
            "timescale/timescaledb-ha:pg16", "pgvector/pgvector:pg17", "localhost:5000/postgres:17"
        ] {
            #expect(PostgresContainerMatcher.isPostgres(image: image, ports: []), "\(image)")
        }
        #expect(PostgresContainerMatcher.isPostgres(image: "mycorp/db:1", ports: ["5432/tcp"]))
        for image in ["redis:7", "mysql:8", "dpage/pgadmin4", "adminer"] {
            #expect(!PostgresContainerMatcher.isPostgres(image: image, ports: []), "\(image)")
        }
    }

    @Test func inspectYieldsUserDatabasePasswordAndPort() throws {
        let db = try #require(PostgresContainerMatcher.database(from: Self.details("inspect-postgres16"), engine: .orbStack))
        #expect(db.containerName == "shop-db")
        #expect(db.user == "app")
        #expect(db.database == "appdb")
        #expect(db.host == "127.0.0.1")
        #expect(db.port == 55432)
        #expect(db.route == .publishedPort)
        #expect(db.password?.reveal() == "s3cret")
        #expect(db.passwordSource == .containerEnv)
        #expect(db.isRunning)
    }

    @Test func defaultsFollowTheOfficialImage() throws {
        var bare = try Self.details("inspect-postgres16")
        bare.config.env = []
        let a = try #require(PostgresContainerMatcher.database(from: bare, engine: .other))
        #expect(a.user == "postgres")
        #expect(a.database == "postgres")
        bare.config.env = ["POSTGRES_USER=app"]
        let b = try #require(PostgresContainerMatcher.database(from: bare, engine: .other))
        #expect(b.database == "app")
    }

    @Test func passwordFileIsReportedNotRead() throws {
        let db = try #require(PostgresContainerMatcher.database(from: Self.details("inspect-password-file"), engine: .other))
        #expect(db.password == nil)
        #expect(db.passwordSource == .file("/run/secrets/pg"))
    }

    @Test func trustAuthHasNoPassword() throws {
        let db = try #require(PostgresContainerMatcher.database(from: Self.details("inspect-postgis-trust"), engine: .other))
        #expect(db.password == nil)
        #expect(db.passwordSource == .none)
        #expect(db.image == "postgis/postgis:16-3.4")
    }

    @Test func unpublishedPortOnDockerIsUnreachable() throws {
        let db = try #require(PostgresContainerMatcher.database(from: Self.details("inspect-unpublished"), engine: .dockerDesktop))
        #expect(db.route == .unreachable)
        #expect(db.port == nil)
        #expect(db.host == nil)
    }

    @Test func unpublishedPortOnOrbStackUsesTheContainerIP() throws {
        let db = try #require(PostgresContainerMatcher.database(from: Self.details("inspect-unpublished"), engine: .orbStack))
        #expect(db.host == "192.168.215.2")
        #expect(db.port == 5432)
        #expect(db.route == .orbStackNetwork)
    }

    @Test func ipv4BindingIsPreferredOverIPv6() throws {
        let db = try #require(PostgresContainerMatcher.database(from: Self.details("inspect-ipv6"), engine: .other))
        #expect(db.host == "127.0.0.1")
        #expect(db.port == 55433)
        var v6only = try Self.details("inspect-ipv6")
        v6only.networkSettings.ports["5432/tcp"] = [PortBinding(hostIP: "::", hostPort: "55433")]
        #expect(PostgresContainerMatcher.database(from: v6only, engine: .other)?.host == "::1")
    }

    @Test func aStoppedContainerKeepsItsConfiguredPort() throws {
        let db = try #require(PostgresContainerMatcher.database(from: Self.details("inspect-old-db"), engine: .other))
        #expect(!db.isRunning)
        #expect(db.port == 55432)
    }

    @Test func aDiscoveredDatabaseNeverPrintsItsPassword() throws {
        let db = try #require(PostgresContainerMatcher.database(from: Self.details("inspect-postgres16"), engine: .other))
        #expect(!String(describing: db).contains("s3cret"))
        #expect(!String(reflecting: db).contains("s3cret"))
        #expect(!"\(db)".contains("s3cret"))
        var dumped = ""
        dump(db, to: &dumped)
        #expect(!dumped.contains("s3cret"))
        let details = try Self.details("inspect-postgres16")
        #expect(!String(describing: details).contains("s3cret"))
        #expect(!String(reflecting: details).contains("s3cret"))
    }
}
