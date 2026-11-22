import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

@MainActor
struct FrameCostTests {
    let key = ConnectionKey.container(name: "shop-db")
    let orders = RelationID("shop", "orders")

    @Test func aSteadyFrameDoesNoWork() async throws {
        let rig = Rig()
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        let window = try siftWindow(model: rig.model, recordsLayout: false)
        rig.model.select(orders, in: key)
        try await window.runUntil { rig.model.sessions[key]?.grid(for: orders)?.cachedPages.contains(0) == true }
        for _ in 0..<3 { window.tick() }

        // Not vacuous: the window really shows the table and its rows.
        #expect(window.shows("orders"))
        #expect(window.shows("done"))
        #expect(window.lastFrameWork.rects > 0)

        window.resetFrameWork()
        for _ in 0..<5 {
            window.window.setNeedsRedraw()
            window.tick()
        }
        let frames = window.frameWork
        #expect(frames.count == 5, "five frames were drawn: \(frames.count)")
        #expect(frames.map(\.rasterizedPixels).reduce(0, +) == 0)
        #expect(frames.map(\.atlasUploadPixels).reduce(0, +) == 0)
        #expect(frames.map(\.newTextures).reduce(0, +) == 0)
        // Not zero: a forced redraw measures the window's chrome (the outline, the grid's toolbar, status bar and the
        // table's header and cells) once each, whatever the schema holds (see the next test). The pin is that it is bounded.
        let measures = frames.map(\.layoutMeasureCalls)
        #expect(measures.allSatisfy { $0 <= Self.steadyMeasureBudget }, "measure calls per frame: \(measures)")
    }

    /// What one forced redraw of the whole window measures: a fixed number, set by the chrome and the grid's window of
    /// cells (74 with a three-row grid, 59 with an empty one), never by how many tables the schema has.
    static let steadyMeasureBudget = 80

    @Test func aSteadyFrameCostsTheSameFor500TablesAsFor13() async throws {
        let big = FakeSource(schema: SyntheticSchema.make(tables: 500, foreignKeys: 800, seed: 3))
        let rig = Rig(sources: [big])
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        let window = try siftWindow(model: rig.model, recordsLayout: false)
        let first = RelationID("s0", "t0000")
        rig.model.select(first, in: key)
        try await window.runUntil { rig.model.sessions[key]?.grid(for: first).map { $0.count != .estimated(0) && !$0.isLoading } == true }
        for _ in 0..<3 { window.tick() }
        // Not vacuous: a 500-table schema is open, and its table is on screen.
        #expect(rig.model.sessions[key]?.snapshot?.relations.count == 500)
        #expect(window.shows("t0000"))

        window.resetFrameWork()
        for _ in 0..<3 {
            window.window.setNeedsRedraw()
            window.tick()
        }
        let frames = window.frameWork
        let measures = frames.map(\.layoutMeasureCalls)
        #expect(measures.allSatisfy { $0 <= Self.steadyMeasureBudget }, "measure calls per frame: \(measures)")
        #expect(frames.map(\.rasterizedPixels).reduce(0, +) == 0)
        #expect(frames.map(\.atlasUploadPixels).reduce(0, +) == 0)
    }

    @Test func refreshShortcutRefreshesDiscovery() async throws {
        let rig = Rig(started: false)
        let (_, window) = try siftApp(model: rig.model)
        rig.model.start()
        try await rig.until("first discovery") { rig.discovery.calls == 1 }
        try await window.runUntilIdle()
        let before = rig.discovery.calls

        window.typeKey("r", modifierFlags: .primary)
        try await window.runUntil { rig.discovery.calls == before + 1 }
        #expect(rig.discovery.calls == before + 1)
    }

    @Test func newConnectionShortcutOpensTheForm() async throws {
        let rig = Rig()
        let (_, window) = try siftApp(model: rig.model)
        #expect(rig.model.draft == nil)
        window.typeKey("n", modifierFlags: .primary)
        try await window.runUntilIdle()
        #expect(rig.model.draft != nil)
        _ = try window.element(identifier: "form.host")
    }

    @Test func refreshReadsTheSchemaOfOpenConnectionsAgain() async throws {
        let rig = Rig()
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        let session = try #require(rig.model.sessions[key])
        #expect(session.snapshot?.relations.count == 13)
        rig.sources[0].schema = SchemaSnapshot(
            serverVersion: 170_000, schemas: ["shop"],
            relations: Array(rig.sources[0].schema.relations.prefix(2)), foreignKeys: [])
        await rig.model.refresh()
        #expect(session.snapshot?.relations.count == 2)
    }
}
