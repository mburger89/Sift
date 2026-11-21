import Foundation
import MetalUI
import SiftCore
import SiftLayout
import SiftTestSupport
import Testing

@testable import SiftKit

@MainActor
struct MapModelTests {
    let orders = RelationID("shop", "orders")
    let identity = "container:shop-db:app"

    @Test func pinnedPositionsSurviveARecreatedDatabase() async {
        let store = InMemoryMapPositionsStore([identity: ["shop.orders": [1234, -567]]])
        let model = MapModel(store: store)
        await model.load(snapshot: shopSnapshot(oidShift: 5_000), identity: identity)
        let layout = model.layout!
        let node = layout.graph.node(of: orders)!
        #expect(layout.positions[node] == LayoutPoint(x: 1234, y: -567))
        // Every other card kept the layout's place, and the layout is the one a fresh run gives.
        let fresh = LayeredLayout.layout(layout.graph.graph)
        let other = layout.graph.node(of: RelationID("shop", "customers"))!
        #expect(layout.positions[other] == fresh.positions[other])
        #expect(layout.bounds.contains(layout.rect(of: node)))
    }

    @Test func savingHappensOnDragEndOnly() async {
        let store = InMemoryMapPositionsStore()
        let model = MapModel(store: store)
        await model.load(snapshot: shopSnapshot(), identity: identity)
        model.beginDrag(orders)
        for step in 1...8 { model.drag(orders, to: LayoutPoint(x: Double(step) * 10, y: 5)) }
        #expect(store.saves == 0)
        model.endDrag()
        #expect(store.saves == 1)
        #expect(store.all[identity]?["shop.orders"] == [80, 5])
        #expect(model.pin(of: orders) == LayoutPoint(x: 80, y: 5))
    }

    @Test func filterChangeRelayoutsOnce() async {
        let model = MapModel(store: InMemoryMapPositionsStore())
        await model.load(snapshot: shopSnapshot(), identity: identity)
        #expect(model.layoutRuns == 1)
        await model.setFilter(MapFilter(schemas: ["shop"]))
        #expect(model.layoutRuns == 2)
        #expect(model.layout!.graph.ids.allSatisfy { $0.schema == "shop" })
        // The same filter again is not a change.
        await model.setFilter(MapFilter(schemas: ["shop"]))
        #expect(model.layoutRuns == 2)
    }

    @Test func positionsFileIsKeyedByIdentityHash() throws {
        let directory = NSTemporaryDirectory() + "sift-map-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = MapPositionsStore(directory: directory)
        store.save(identity: identity, positions: ["shop.orders": [10, 20.5]])
        let path = store.path(identity: identity)
        #expect(path.hasSuffix(FNV1a64.hex(identity) + ".json"))
        #expect(path.contains("/map-positions/"))
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains(identity))
        #expect(store.load(identity: identity) == ["shop.orders": [10, 20.5]])
        // Another database has its own file.
        #expect(store.load(identity: "container:other:app").isEmpty)
        // A hash of known text: FNV-1a 64 of "" and "a".
        #expect(FNV1a64.hex("") == "cbf29ce484222325")
        #expect(FNV1a64.hex("a") == "af63dc4c8601ec8c")
    }

    @Test func aCorruptPositionsFileIsSetAside() throws {
        let directory = NSTemporaryDirectory() + "sift-map-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = MapPositionsStore(directory: directory)
        store.save(identity: identity, positions: ["shop.orders": [1, 2]])
        try "not json".write(toFile: store.path(identity: identity), atomically: true, encoding: .utf8)
        #expect(store.load(identity: identity).isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.path(identity: identity) + ".corrupt-1"))
    }

    @Test func resetLayoutForgetsPins() async {
        let store = InMemoryMapPositionsStore([identity: ["shop.orders": [1234, -567]]])
        let model = MapModel(store: store)
        await model.load(snapshot: shopSnapshot(), identity: identity)
        await model.resetLayout()
        let node = model.layout!.graph.node(of: orders)!
        #expect(model.layout!.positions[node] != LayoutPoint(x: 1234, y: -567))
        #expect(store.all[identity] == [:])
        #expect(model.pin(of: orders) == nil)
    }
}
