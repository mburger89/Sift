import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

@MainActor
struct MapDragTests {
    let orders = RelationID("shop", "orders")

    /// A press at `from`, `steps` drag events towards `to` with a frame after each, no release: the work of each step.
    func dragSteps(_ rig: MapRig, from: Point<Pixels>, to: Point<Pixels>, steps: Int) async -> [Work] {
        let window = rig.window
        window.send(.mouseMoved(MouseEvent(position: from, timestamp: window.now)))
        window.send(.mouseDown(MouseEvent(position: from, timestamp: window.now)))
        var out: [Work] = []
        for step in 1...steps {
            let t = Float(step) / Float(steps)
            let position = Point(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            out.append(await Work.of(rig) {
                window.send(.mouseDragged(MouseEvent(position: position, timestamp: window.now)))
                window.advanceFrames(1)
            })
        }
        return out
    }

    func release(_ rig: MapRig, at point: Point<Pixels>) {
        rig.window.send(.mouseUp(MouseEvent(position: point, timestamp: rig.window.now)))
        rig.window.tick()
    }

    @Test func dragMovesTheCardAndRedrawsEveryStep() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        let card = try rig.window.element(identifier: "map.card.shop.orders")
        let from = try rig.centre(of: orders)
        let delta = Point(x: Pixels(120), y: Pixels(60))
        let to = Point(x: from.x + delta.x, y: from.y + delta.y)
        let before = card.frame.origin
        let customersBefore = try rig.window.element(identifier: "map.card.shop.customers").frame.origin
        rig.window.resetFrameWork()
        rig.window.drag(from: from, to: to, steps: 8)
        // One frame per step and one for the release.
        #expect(rig.window.frameWork.count == 9, "frames \(rig.window.frameWork.count)")
        let moved = try rig.window.element(identifier: "map.card.shop.orders").frame.origin
        #expect(abs(moved.x.value - before.x.value - delta.x.value) <= 1)
        #expect(abs(moved.y.value - before.y.value - delta.y.value) <= 1)
        // Not vacuous: the other cards did not move.
        let customers = try rig.window.element(identifier: "map.card.shop.customers")
        #expect(customers.frame.origin == customersBefore)
    }

    @Test func aDragStepRebuildsOnlyTheDraggedCard() async throws {
        let rig = try await MapRig.atTable("t0100")
        let id = RelationID("s0", "t0100")
        #expect(rig.map.culled.nodes.count > 20)
        #expect(rig.map.culled.tiles.count > 10)
        let from = try rig.centre(of: id)
        let steps = await dragSteps(rig, from: from, to: Point(x: from.x + 160, y: from.y + 80), steps: 8)
        #expect(rig.map.dragged == id)
        // The first step moves the card's edges out of the tiles (a tile rebuild); each later one rebuilds only the card.
        for (n, work) in steps.enumerated() where n >= 1 {
            #expect(work.cards == 1, "step \(n + 1): cards \(work.cards)")
            #expect(work.tiles == 0, "step \(n + 1): tiles \(work.tiles)")
            #expect(work.rasterized < 1280 * 800 / 4, "step \(n + 1): rasterized \(work.rasterized)")
            // A frame per step; the Observation hop on Linux and Windows can split one step's redraw across two.
            #expect((1...2).contains(work.frames.count), "step \(n + 1): frames \(work.frames.count)")
        }
        #expect(!rig.map.liveEdges.isEmpty)
        release(rig, at: Point(x: from.x + 160, y: from.y + 80))
        #expect(rig.map.dragged == nil)
        #expect(rig.map.liveEdges.isEmpty)
    }

    @Test func releasedPositionIsRemembered() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        let from = try rig.centre(of: orders)
        let to = Point(x: from.x + 90, y: from.y + 45)
        rig.window.drag(from: from, to: to, steps: 8)
        try await rig.window.runUntilIdle()
        let identity = "container:shop-db:shop"
        let saved = try #require(rig.rig.mapPositions.all[identity]?["shop.orders"])
        // The card moved by 90 and 45 screen points, which is that over the zoom in canvas units.
        let node = rig.map.layout!.graph.node(of: orders)!
        #expect(saved == [rig.map.layout!.positions[node].x, rig.map.layout!.positions[node].y])
        #expect(rig.rig.mapPositions.saves == 1)
        // A reopened model places the card there.
        let reopened = MapModel(store: rig.rig.mapPositions)
        await reopened.load(snapshot: shopSnapshot(), identity: identity)
        let reopenedNode = reopened.layout!.graph.node(of: orders)!
        #expect(reopened.layout!.positions[reopenedNode] == LayoutPoint(x: saved[0], y: saved[1]))
        // And the card's place on screen is where it was dropped.
        let card = try rig.window.element(identifier: "map.card.shop.orders")
        let centre = rig.window.centre(of: card)
        #expect(abs(centre.x.value - to.x.value) <= 1 && abs(centre.y.value - to.y.value) <= 1)
    }

    @Test func draggingEmptyCanvasPans() async throws {
        let rig = try await MapRig(schema: FixtureSnapshot.shop())
        let origin = try rig.mapOrigin()
        let from = Point(x: origin.x + 4, y: origin.y + 4)
        #expect(rig.map.table(at: Point(x: 4, y: 4)) == nil)
        let before = rig.map.geometry.pan
        rig.window.drag(from: from, to: Point(x: from.x + 50, y: from.y + 30), steps: 5)
        #expect(rig.map.geometry.pan.x.value - before.x.value == 50)
        #expect(rig.map.geometry.pan.y.value - before.y.value == 30)
        #expect(rig.rig.mapPositions.saves == 0)
    }
}
