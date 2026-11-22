import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

@MainActor
struct ReconnectUITests {
    let key = ConnectionKey.container(name: "shop-db")
    let orders = RelationID("shop", "orders")

    /// A rig whose second source has one more row than the first, so a reload is visible.
    func rigWithFreshSecondSource() -> Rig {
        let first = fakeShopSource()
        let second = fakeShopSource(oidShift: 500)
        var page = ordersRows()
        page.rows.append([.int(4), .int(12), .text("fresh")])
        second.rows = [orders: page]
        return Rig(sources: [first, second])
    }

    func openOrders(_ rig: Rig) async throws -> TestWindow {
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        let window = try siftWindow(model: rig.model)
        rig.model.select(orders, in: key)
        try await window.runUntil { rig.model.sessions[key]?.grid(for: orders)?.cachedPages.contains(0) == true }
        try await window.runUntilIdle()
        return window
    }

    func lose(_ rig: Rig, _ window: TestWindow) async throws {
        rig.sources[0].failNext = SourceError(.connectionLost, "server closed the connection")
        let session = try #require(rig.model.sessions[key])
        await session.loadRows(orders, force: true)
        try await window.runUntilIdle()
    }

    @Test func lostConnectionShowsABannerAndRecovers() async throws {
        let rig = rigWithFreshSecondSource()
        let window = try await openOrders(rig)
        #expect(!window.shows("fresh"))
        #expect((try? window.element(identifier: "session.banner")) == nil, "no banner while connected")

        try await lose(rig, window)
        let banner = try window.element(identifier: "session.banner")
        #expect(banner.value?.hasPrefix("Connection lost") == true, "\(banner.value ?? "nil")")

        try window.click(window.element(label: "Reconnect now"))
        try await window.runUntil { rig.model.sessions[key]?.state == .ready }
        try await window.runUntil { window.shows("fresh") }
        #expect((try? window.element(identifier: "session.banner")) == nil, "the banner is gone")
        // The preview was read again from the new connection.
        #expect(window.shows("fresh"))
        #expect(rig.model.selection == .relation(key, orders))
    }

    @Test func stopTryingHidesRetry() async throws {
        let rig = rigWithFreshSecondSource()
        let window = try await openOrders(rig)
        try await lose(rig, window)
        #expect(window.shows("Reconnect now"))
        try window.click(window.element(label: "Stop trying"))
        try await window.runUntilIdle()
        #expect(rig.model.sessions[key]?.state == .stopped)
        #expect(!window.shows("Reconnect now"))
        #expect(!window.shows("Stop trying"))
        #expect(try window.element(identifier: "session.banner").value?.hasPrefix("Connection closed") == true)
        #expect(window.shows("Try again"))
    }

    @Test func failedReadOnlyCheckIsExplained() async throws {
        let rig = Rig()
        rig.connector.failNext([SourceError(.readOnlyNotEnforced, "The server did not enforce a read-only session")])
        await rig.model.refreshDiscovery()
        let window = try siftWindow(model: rig.model)
        rig.model.selection = .container(name: "shop-db")
        await rig.model.open(key)
        try await window.runUntilIdle()
        let banner = try window.element(identifier: "session.banner")
        #expect(banner.value?.contains("read-only") == true, "\(banner.value ?? "nil")")
        // The retry is manual: the connect button is offered again.
        #expect(window.shows("Try again"))
        #expect(!window.shows("Reconnect now"))
    }
}
