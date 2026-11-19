import Foundation
import SiftCore
import SiftDocker
import SiftTestSupport
import Testing

@testable import SiftKit

@MainActor
struct SessionModelTests {
    let key = ConnectionKey.container(name: "shop-db")
    let orders = RelationID("shop", "orders")

    func port(of target: ConnectionTarget?) -> Int? {
        if case .discovered(let database)? = target { return database.port }
        return nil
    }

    @Test func connectingLoadsTheSnapshotThroughTheConnector() async throws {
        let rig = Rig()
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        let session = try #require(rig.model.sessions[key])
        #expect(session.state == .ready)
        #expect(session.snapshot?.relations.count == 13)
        #expect(rig.connector.targets.count == 1)
        #expect(port(of: rig.connector.targets.first) == 55432)
        #expect(session.readOnly)
    }

    @Test func lostConnectionBacksOffThenReconnectsWithFreshDiscovery() async throws {
        let first = fakeShopSource()
        let second = fakeShopSource(oidShift: 1000)
        let rig = Rig(sources: [first, second])
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        let session = try #require(rig.model.sessions[key])
        rig.model.select(orders, in: key)
        await session.loadRows(orders)
        #expect(session.rows[orders]?.value?.rows.count == 3)
        let oldOID = try #require(session.snapshot?.relation(orders)?.oid)

        // The server drops the connection under a read; the container is recreated on another port.
        first.failNext = SourceError(.connectionLost, "server closed the connection unexpectedly")
        await session.loadRows(orders, force: true)
        #expect(session.state == .lost("server closed the connection unexpectedly"))
        rig.discovery.result = .success([shopContainer(port: 55433)])

        try await rig.sleeperPending()
        #expect(await rig.clock.sleeps.prefix(1) == [0.5])
        await rig.clock.advance(by: 0.5)
        try await rig.until("ready again") { session.state == .ready }

        #expect(port(of: rig.connector.targets.last) == 55433, "reconnect looked the container up again")
        #expect(rig.connector.targets.count == 2)
        // Selection is by name: it survives while the new snapshot's OIDs all differ.
        #expect(rig.model.selection == .relation(key, orders))
        let newOID = try #require(session.snapshot?.relation(orders)?.oid)
        #expect(newOID != oldOID)
        #expect(rig.model.selectedRelation?.oid == newOID)
        // The preview that was showing was read again from the new source.
        #expect(second.rowRequests == [orders])
        #expect(first.isClosed)
    }

    @Test func aContainerThatStaysGoneBacksOff() async throws {
        let rig = Rig()
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        let session = try #require(rig.model.sessions[key])
        await session.loadRows(orders)
        rig.sources[0].failNext = SourceError(.connectionLost, "gone")
        await session.loadRows(orders, force: true)
        rig.discovery.result = .success([])

        for _ in 0..<6 {
            try await rig.sleeperPending()
            await rig.clock.advance(by: 100)
        }
        try await rig.sleeperPending()
        #expect(await rig.clock.sleeps.prefix(6) == [0.5, 1, 2, 4, 5, 5])
        #expect(session.state == .lost("Container shop-db was not found"))
        #expect(rig.connector.targets.count == 1, "nothing to connect to while the container is gone")
    }

    @Test func stopTryingEndsTheLoop() async throws {
        let rig = Rig()
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        let session = try #require(rig.model.sessions[key])
        await session.loadRows(orders)
        rig.sources[0].failNext = SourceError(.connectionLost, "gone")
        await session.loadRows(orders, force: true)
        try await rig.sleeperPending()  // not vacuous: a retry really is pending

        session.stopTrying()
        #expect(session.state == .stopped)
        await rig.clock.advance(by: 60)
        for _ in 0..<50 { await Task.yield() }
        #expect(session.state == .stopped)
        #expect(rig.connector.targets.count == 1, "no connect after Stop")
    }

    @Test func reconnectNowTriesAtOnce() async throws {
        let rig = Rig(sources: [fakeShopSource(), fakeShopSource(oidShift: 7)])
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        let session = try #require(rig.model.sessions[key])
        await session.loadRows(orders)
        rig.sources[0].failNext = SourceError(.connectionLost, "gone")
        await session.loadRows(orders, force: true)
        try await rig.sleeperPending()

        await session.reconnectNow()
        #expect(session.state == .ready, "no clock advance was needed")
        #expect(rig.connector.targets.count == 2)
    }

    @Test func readOnlyRefusalIsAFailedState() async throws {
        let rig = Rig()
        rig.connector.failNext([SourceError(.readOnlyNotEnforced, "The server did not enforce a read-only session")])
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        let session = try #require(rig.model.sessions[key])
        guard case .failed(let message) = session.state else {
            Issue.record("expected .failed, got \(session.state)")
            return
        }
        #expect(message.contains("read-only"))
        #expect(message.contains("refused"))
        #expect(session.snapshot == nil)
    }

    @Test func aFailedSessionConnectsAgainOnOpen() async throws {
        let rig = Rig()
        rig.connector.failNext([SourceError(.other, "password authentication failed")])
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        #expect(rig.model.sessions[key]?.state == .failed("password authentication failed"))
        await rig.model.open(key)
        #expect(rig.model.sessions[key]?.state == .ready)
    }

    @Test func aPasswordNeverReachesAStateOrATarget() async throws {
        let rig = Rig()
        await rig.model.refreshDiscovery()
        await rig.model.open(key)
        let session = try #require(rig.model.sessions[key])
        let target = try #require(rig.connector.targets.first)
        #expect(!String(describing: target).contains("s3cret"))
        #expect(!String(reflecting: target).contains("s3cret"))
        #expect(!String(describing: session.state).contains("s3cret"))
        // The password did reach the connector: it is masked, not absent.
        guard case .discovered(let database) = target else {
            Issue.record("not a container target")
            return
        }
        #expect(database.password?.reveal() == "s3cret")
    }

    @Test func savedConnectionsTakeTheirPasswordFromTheCredentialStore() async throws {
        let saved = SavedConnection(name: "Local dev", host: "db.example", database: "shop", user: "app")
        let rig = Rig(saved: [saved], containers: [])
        rig.credentials.setPassword(Secret("s3cret"), for: CredentialKey(connectionID: saved.id))
        await rig.model.open(.saved(saved.id))
        guard case .saved(let used, let password)? = rig.connector.targets.first else {
            Issue.record("no saved target")
            return
        }
        #expect(used == saved)
        #expect(password?.reveal() == "s3cret")
    }

    @Test func addingAndRemovingAConnectionPersistsAndForgetsItsPassword() throws {
        let rig = Rig(containers: [])
        let saved = SavedConnection(name: "A", host: "a", database: "d", user: "u")
        rig.model.addConnection(saved, password: Secret("s3cret"))
        #expect(rig.connectionStore.saved.last == [saved])
        #expect(rig.credentials.password(for: CredentialKey(connectionID: saved.id)) != nil)
        rig.model.removeConnection(saved.id)
        #expect(rig.connectionStore.saved.last == [])
        #expect(rig.credentials.password(for: CredentialKey(connectionID: saved.id)) == nil)
    }
}
