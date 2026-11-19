import Foundation
import SiftCore
import Testing

struct PersistenceTests {
    @Test func supportDirectoryPerPlatform() {
        #expect(AppPaths.supportDirectory(platform: .macOS, env: [:], home: "/Users/u")
            == "/Users/u/Library/Application Support/Sift")
        #expect(AppPaths.supportDirectory(platform: .linux, env: [:], home: "/home/u") == "/home/u/.local/share/sift")
        #expect(AppPaths.supportDirectory(platform: .linux, env: ["XDG_DATA_HOME": "/data"], home: "/home/u")
            == "/data/sift")
        #expect(AppPaths.supportDirectory(platform: .linux, env: ["XDG_DATA_HOME": ""], home: "/home/u")
            == "/home/u/.local/share/sift")
        #expect(AppPaths.supportDirectory(platform: .windows, env: ["APPDATA": "C:\\Users\\u\\AppData\\Roaming"], home: "C:\\Users\\u")
            == "C:\\Users\\u\\AppData\\Roaming\\Sift")
    }

    @Test func savedConnectionsNeverContainAPassword() throws {
        let connection = SavedConnection(name: "Local dev", host: "127.0.0.1", port: 5432, database: "shop", user: "app")
        let json = try String(decoding: JSONEncoder().encode(connection), as: UTF8.self)
        #expect(!json.contains("password"))
        #expect(!json.contains("s3cret"))
        let back = try JSONDecoder().decode(SavedConnection.self, from: Data(json.utf8))
        #expect(back == connection)
    }

    @Test func saveIsAtomicAndRoundTrips() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = ConnectionStore(directory: directory)
        #expect(try store.load() == [])
        let a = SavedConnection(name: "A", host: "a.example", database: "a", user: "u")
        let b = SavedConnection(name: "B", host: "b.example", port: 6543, database: "b", user: "v", sslMode: "require")
        try store.save([a, b])
        #expect(try ConnectionStore(directory: directory).load() == [a, b])
        try store.save([b])
        #expect(try store.load() == [b])
        // Atomic: no temporary file is left beside the list.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        #expect(names == ["connections.json"], "\(names)")
        let text = try String(contentsOfFile: directory + "/connections.json", encoding: .utf8)
        #expect(text.contains("\"version\""))
    }

    @Test func aCorruptFileIsSetAsideNotOverwritten() throws {
        let directory = scratchDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let garbage = Data("not json {{{".utf8)
        try garbage.write(to: URL(fileURLWithPath: directory + "/connections.json"))
        let store = ConnectionStore(directory: directory)
        #expect(try store.load() == [])
        #expect(try Data(contentsOf: URL(fileURLWithPath: directory + "/connections.json.corrupt-1")) == garbage)
        // The next corrupt file does not clobber the first.
        try garbage.write(to: URL(fileURLWithPath: directory + "/connections.json"))
        #expect(try store.load() == [])
        #expect(FileManager.default.fileExists(atPath: directory + "/connections.json.corrupt-2"))
    }

    @Test func inMemoryCredentialsForgetOnRemove() {
        let store = InMemoryCredentialStore()
        let key = CredentialKey(connectionID: UUID())
        #expect(store.password(for: key) == nil)
        store.setPassword(Secret("s3cret"), for: key)
        #expect(store.password(for: key)?.reveal() == "s3cret")
        store.removePassword(for: key)
        #expect(store.password(for: key) == nil)
    }

    private func scratchDirectory() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("sift-test-\(UUID().uuidString)").path
    }
}
