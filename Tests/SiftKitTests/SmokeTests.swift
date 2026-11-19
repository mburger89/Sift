import MetalUITesting
import Testing

@testable import SiftKit

@MainActor
struct SmokeTests {
    @Test func theRootViewOpensHeadless() throws {
        let window = try siftWindow(model: Rig(started: false).model)
        _ = try window.element(identifier: "sidebar")
    }
}
