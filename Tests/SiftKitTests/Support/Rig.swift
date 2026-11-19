import Foundation
import SiftCore
import SiftDocker
import SiftKit
import SiftTestSupport

/// A container the way discovery reports one: the password is a `Secret`, so a failure message never shows it.
func shopContainer(port: Int = 55432, name: String = "shop-db", route: ContainerRoute = .publishedPort) -> DiscoveredDatabase {
    DiscoveredDatabase(
        containerID: "id-\(name)-\(port)", containerName: name, image: "postgres:17", isRunning: true, engine: .orbStack,
        route: route, host: route == .publishedPort ? "127.0.0.1" : nil, port: route == .publishedPort ? port : nil,
        user: "postgres", database: "shop", password: Secret("s3cret"), passwordSource: .containerEnv, composeProject: nil)
}

/// The fixture shop with `orders` estimated at `ordersEstimate` rows and every OID shifted by `oidShift`
/// (a recreated container hands out new OIDs).
func shopSnapshot(ordersEstimate: Int64 = 3, oidShift: UInt32 = 0) -> SchemaSnapshot {
    let base = FixtureSnapshot.shop()
    let relations = base.relations.map { relation -> RelationInfo in
        var relation = relation
        relation.oid += oidShift
        if relation.id == RelationID("shop", "orders") { relation.rowEstimate = .estimated(ordersEstimate) }
        return relation
    }
    return SchemaSnapshot(serverVersion: base.serverVersion, schemas: base.schemas, relations: relations, foreignKeys: base.foreignKeys)
}

/// Preview rows for `orders`: a NULL and an empty string in the `status` column, to tell them apart.
func ordersRows() -> ResultPage {
    ResultPage(
        columns: [
            ResultColumn(name: "id", typeOID: 20, typeName: "bigint"),
            ResultColumn(name: "customer_id", typeOID: 20, typeName: "bigint"),
            ResultColumn(name: "status", typeOID: 25, typeName: "text"),
        ],
        rows: [
            [.int(1), .int(10), .null],
            [.int(2), .int(11), .text("")],
            [.int(3), .int(10), .text("done")],
        ])
}

func fakeShopSource(oidShift: UInt32 = 0) -> FakeSource {
    FakeSource(
        schema: shopSnapshot(oidShift: oidShift), rows: [RelationID("shop", "orders"): ordersRows()],
        counts: [RelationID("shop", "orders"): 3])
}

/// The whole environment of fakes, and the model over it.
@MainActor
struct Rig {
    let model: AppModel
    let connector: FakeConnector
    let discovery: FakeDockerDiscovery
    let clock: ManualClock
    let connectionStore: InMemoryConnectionStore
    let credentials: InMemoryCredentialStore
    let sources: [FakeSource]

    init(
        saved: [SavedConnection] = [], containers: [DiscoveredDatabase] = [shopContainer()],
        sources: [FakeSource]? = nil, started: Bool = true
    ) {
        let sources = sources ?? [fakeShopSource()]
        self.sources = sources
        connector = FakeConnector(sources)
        discovery = FakeDockerDiscovery(result: .success(containers))
        clock = ManualClock()
        connectionStore = InMemoryConnectionStore(saved)
        credentials = InMemoryCredentialStore()
        model = AppModel(
            environment: SiftEnvironment(
                connections: connectionStore, credentials: credentials, discovery: discovery, connector: connector,
                clock: clock))
        if started { model.start() }
    }

    /// Waits (bounded, so a broken build fails instead of hanging) until `n` tasks sleep on the manual clock.
    func sleeperPending(_ n: Int = 1) async throws {
        for _ in 0..<5000 {
            if await clock.pendingSleepers >= n { return }
            await Task.yield()
        }
        throw RigError.timedOut("a sleeper on the manual clock")
    }

    /// Waits until `condition` holds, yielding to the main actor between looks (no wall clock).
    func until(_ what: String = "condition", _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2000 where !condition() { await Task.yield() }
        if !condition() { throw RigError.timedOut(what) }
    }
}

enum RigError: Error { case timedOut(String) }
