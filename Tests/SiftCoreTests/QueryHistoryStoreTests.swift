import Foundation
import SiftCore
import Testing

@Suite struct QueryHistoryStoreTests {
    static func directory() -> String {
        NSTemporaryDirectory() + "sift-history-\(UUID().uuidString)"
    }

    static func entry(_ n: Int) -> QueryHistoryEntry {
        QueryHistoryEntry(sql: "select \(n)", ranAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)), duration: 0.25, rowCount: n)
    }

    @Test func historyPersistsAcrossLaunches() {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let identity = "saved:1234:shop"
        QueryHistoryStore(directory: dir).save(identity: identity, entries: [Self.entry(2), Self.entry(1)])
        // A new store over the same folder: the next launch.
        let loaded = QueryHistoryStore(directory: dir).load(identity: identity)
        #expect(loaded == [Self.entry(2), Self.entry(1)])
        // Each identity has its own file.
        #expect(QueryHistoryStore(directory: dir).load(identity: "saved:1234:other").isEmpty)
    }

    @Test func entriesKeepEveryField() {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let all = [
            QueryHistoryEntry(sql: "select 1", ranAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 1.5, rowCount: 7),
            QueryHistoryEntry(sql: "set x = 1", ranAt: Date(timeIntervalSince1970: 1_700_000_100), duration: 0.01, affected: 3),
            QueryHistoryEntry(sql: "select ,,", ranAt: Date(timeIntervalSince1970: 1_700_000_200), duration: 0, error: "syntax error"),
        ]
        let store = QueryHistoryStore(directory: dir)
        store.save(identity: "i", entries: all)
        #expect(store.load(identity: "i") == all)
    }

    #if !os(Windows)
    @Test func theFileIsReadableByItsOwnerOnly() throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = QueryHistoryStore(directory: dir)
        store.save(identity: "i", entries: [Self.entry(1)])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.path(identity: "i"))
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(mode & 0o777 == 0o600, "mode \(String(mode & 0o777, radix: 8))")
        let folder = try FileManager.default.attributesOfItem(atPath: (store.path(identity: "i") as NSString).deletingLastPathComponent)
        #expect(((folder[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o700)
        // Saving again keeps it private, and leaves no temporary file.
        store.save(identity: "i", entries: [Self.entry(2)])
        let again = try FileManager.default.attributesOfItem(atPath: store.path(identity: "i"))
        #expect(((again[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600)
        let files = try FileManager.default.contentsOfDirectory(atPath: (store.path(identity: "i") as NSString).deletingLastPathComponent)
        #expect(files.count == 1)
    }
    #endif

    @Test func historyCapsAt500() {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = QueryHistoryStore(directory: dir)
        store.save(identity: "i", entries: (0..<650).map(Self.entry))
        let loaded = store.load(identity: "i")
        #expect(loaded.count == 500)
        #expect(loaded.first == Self.entry(0))
        #expect(QueryHistoryStore.limit == 500)
    }

    @Test func aCorruptFileIsSetAsideAndTheHistoryStartsEmpty() throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = QueryHistoryStore(directory: dir)
        store.save(identity: "i", entries: [Self.entry(1)])
        let path = store.path(identity: "i")
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        #expect(store.load(identity: "i").isEmpty)
        #expect(FileManager.default.fileExists(atPath: path + ".corrupt-1"))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func theFileHoldsNoPasswordKeyAndNamesNoHost() throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = QueryHistoryStore(directory: dir)
        store.save(identity: "saved:0000:shop", entries: [Self.entry(1)])
        let text = try String(contentsOfFile: store.path(identity: "saved:0000:shop"), encoding: .utf8)
        #expect(!text.lowercased().contains("password"))
        #expect(text.contains("select 1"))
    }
}
