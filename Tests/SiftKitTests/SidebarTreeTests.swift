import SiftCore
import SiftDocker
import Testing

@testable import SiftKit

@MainActor
struct SidebarTreeTests {
    @Test func sidebarHasSavedAndContainerRootsAndSchemaChildren() async throws {
        let saved = SavedConnection(name: "Local dev", host: "127.0.0.1", database: "shop", user: "app")
        let rig = Rig(saved: [saved])
        await rig.model.refreshDiscovery()
        var tree = rig.model.sidebarTree
        #expect(tree.map(\.title) == ["Saved", "Containers"])
        #expect(tree[0].children?.map(\.title) == ["Local dev"])
        #expect(tree[1].children?.map(\.title) == ["shop-db"])
        #expect(tree[1].children?.first?.children == nil, "not connected: no schema children")

        await rig.model.open(.container(name: "shop-db"))
        tree = rig.model.sidebarTree
        let schemas = try #require(tree[1].children?.first?.children)
        #expect(schemas.map(\.title) == ["shop", "tagging"])
        let shop = try #require(schemas.first?.children)
        let kinds = shop.map(\.kind)
        let firstView = try #require(kinds.firstIndex(of: .view))
        #expect(kinds[..<firstView].allSatisfy { $0 == .table }, "tables first")
        #expect(kinds[firstView...].allSatisfy { $0 == .view }, "views last")
        #expect(shop.map(\.title).contains("customers"))
        #expect(shop.last?.title == "recent_orders")
        #expect(kinds.filter { $0 == .view }.count == 2)
    }

    @Test func discoveryProblemBecomesARowNotAThrow() async throws {
        let rig = Rig(containers: [])
        rig.discovery.result = .failure(DockerError.noEndpoint(tried: ["/var/run/docker.sock"]))
        await rig.model.refreshDiscovery()
        let containers = try #require(rig.model.sidebarTree.last?.children)
        #expect(containers.count == 1)
        #expect(containers.first?.title == "Docker not found")
        #expect(containers.first?.kind == .problem)
    }

    @Test func nodeIDsAreByNameNeverByOID() {
        let key = ConnectionKey.container(name: "shop-db")
        let id = SidebarNodeID.relation(key, RelationID("shop", "orders"))
        #expect(id.token == "relation:container:shop-db:shop.orders")
        #expect(id.connection == key)
    }
}
