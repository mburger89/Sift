import MetalUI
import MetalUITesting
import SiftCore
import SiftDocker
import SiftTestSupport
import Testing

@testable import SiftKit

@MainActor
struct ConnectionDetailTests {
    let key = ConnectionKey.container(name: "shop-db")

    func openWindow(_ rig: Rig) async throws -> TestWindow {
        await rig.model.refreshDiscovery()
        let window = try siftWindow(model: rig.model)
        try await window.runUntilIdle()
        return window
    }

    @Test func discoveredDatabaseShowsAMaskedPassword() async throws {
        let rig = Rig()
        let window = try await openWindow(rig)
        rig.model.selection = .container(name: "shop-db")
        try await window.runUntilIdle()

        let password = try window.element(identifier: "discovered.password")
        #expect(password.value == "from container env, hidden")
        // Not vacuous: the detail really is the container's, with its address.
        _ = try window.element(label: "127.0.0.1:55432")
        // The secret appears in no label, value or identifier anywhere in the tree.
        #expect(try window.elementsContaining("s3cret").isEmpty)
        // Not vacuous: the walk does see text (the container's name is in the tree).
        #expect(try !window.elementsContaining("shop-db").isEmpty)
    }

    @Test func clickingConnectOpensTheSession() async throws {
        let rig = Rig()
        let window = try await openWindow(rig)
        rig.model.selection = .container(name: "shop-db")
        try await window.runUntilIdle()
        try window.click(window.element(label: "Connect"))
        try await rig.until("connected") { rig.connector.targets.count == 1 }
        try await window.runUntilIdle()
        #expect(rig.model.sessions[key]?.state == .ready)
        // A connected database opens its map; the connection's details are the Table mode of the same node.
        #expect(rig.model.detailMode == .map)
        _ = try window.element(identifier: "map")
        rig.model.setDetailMode(.table)
        try await window.runUntilIdle()
        // The button is disabled while connected, and the detail says so.
        #expect(try window.element(label: "Connect").isEnabled == false)
        _ = try window.element(label: "Connected, read-only")
    }

    @Test func unpublishedContainerCannotConnect() async throws {
        let rig = Rig(containers: [shopContainer(route: .unreachable)])
        let window = try await openWindow(rig)
        rig.model.selection = .container(name: "shop-db")
        try await window.runUntilIdle()
        #expect(try window.element(label: "Connect").isEnabled == false)
        #expect(try window.element(identifier: "discovered.reason").value == "5432 not published")
        // Pressing it anyway connects nothing.
        try? window.click(window.element(label: "Connect"))
        try await window.runUntilIdle()
        #expect(rig.connector.targets.isEmpty)
    }

    @Test func savingTheFormPersists() async throws {
        let rig = Rig(containers: [])
        let window = try await openWindow(rig)
        rig.model.beginNewConnection()
        try await window.runUntilIdle()

        func fill(_ identifier: String, _ text: String) throws {
            let field = try window.element(identifier: identifier)
            try window.click(field)
            window.typeKey("a", modifierFlags: .primary)
            window.typeText(text)
        }
        try fill("form.name", "Staging")
        try fill("form.host", "db.example")
        try fill("form.port", "6543")
        try fill("form.database", "shop")
        try fill("form.user", "app")
        try window.click(window.element(label: "Save"))
        try await window.runUntilIdle()

        let saved = try #require(rig.connectionStore.saved.last?.first)
        #expect(saved.host == "db.example")
        #expect(saved.name == "Staging")
        #expect(saved.port == 6543)
        #expect(saved.database == "shop")
        #expect(saved.user == "app")
        #expect(rig.model.draft == nil, "the form closes")
        #expect(rig.model.selection == .saved(saved.id))
        #expect(try window.element(identifier: "detail.title").value == "Staging")
    }

    @Test func aBadPortIsRefusedAndNothingIsSaved() async throws {
        let rig = Rig(containers: [])
        let window = try await openWindow(rig)
        rig.model.beginNewConnection()
        try await window.runUntilIdle()
        let port = try window.element(identifier: "form.port")
        try window.click(port)
        window.typeKey("a", modifierFlags: .primary)
        window.typeText("70000")
        try window.click(window.element(label: "Save"))
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "form.error").value == "Port must be a number from 1 to 65535")
        #expect(rig.connectionStore.saved.isEmpty)
        #expect(rig.model.draft != nil)
    }

    @Test func theFormHasNoPasswordField() async throws {
        let rig = Rig(containers: [])
        let window = try await openWindow(rig)
        rig.model.beginNewConnection()
        try await window.runUntilIdle()
        // Five plain fields (name, host, port, database, user): none of them takes a password.
        #expect(try window.elements(role: .textField).count == 5)
        #expect(try window.element(identifier: "form.passwordNote").value == "Password entry needs SecureField (MetalUI)")
    }

    @Test func aSavedConnectionConnectsWithItsStoredPassword() async throws {
        let saved = SavedConnection(name: "Local dev", host: "127.0.0.1", database: "shop", user: "app")
        let rig = Rig(saved: [saved], containers: [])
        rig.credentials.setPassword(Secret("s3cret"), for: CredentialKey(connectionID: saved.id))
        let window = try await openWindow(rig)
        rig.model.selection = .saved(saved.id)
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "detail.title").value == "Local dev")
        try window.click(window.element(label: "Connect"))
        try await rig.until("connected") { rig.connector.targets.count == 1 }
        guard case .saved(_, let password)? = rig.connector.targets.first else {
            Issue.record("no saved target")
            return
        }
        #expect(password?.reveal() == "s3cret")
        try await window.runUntilIdle()
        #expect(try window.elementsContaining("s3cret").isEmpty)
    }
}
