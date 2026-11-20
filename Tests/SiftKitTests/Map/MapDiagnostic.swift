import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

@MainActor
struct MapDiagnostic {
    @Test func portableDiagnostics() async throws {
        let rig = try await MapRig(schema: MapRig.big)
        print("DIAG viewSize", rig.map.viewSize as Any, "zoom", rig.map.geometry.zoom, "culled", rig.map.culled.nodes.count)
        for id in ["map", "map.toolbar", "map.minimap"] {
            print("DIAG", id, (try? rig.window.element(identifier: id).frame) as Any)
        }
        rig.map.flyTo(RelationID("s0", "t0100"), size: rig.map.viewSize!)
        for _ in 0..<3 { rig.window.tick() }
        print("DIAG after fly: viewSize", rig.map.viewSize as Any, "zoom", rig.map.geometry.zoom, "culled", rig.map.culled.nodes.count, "pan", rig.map.geometry.pan)
        let w = Work.of(rig) { rig.window.window.setNeedsRedraw(); rig.window.tick() }
        print("DIAG steady cards", w.cards, "frames", w.frames.count, "viewSize", rig.map.viewSize as Any)
    }
}
