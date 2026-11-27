import Foundation
#if os(Windows)
import WinSDK
#endif

/// One run in the history: the SQL, when it ran, how long it took, and what came of it.
public struct QueryHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var sql: String
    public var ranAt: Date
    /// Seconds.
    public var duration: Double
    /// The rows a row-returning statement came back with.
    public var rowCount: Int?
    /// The rows a command touched.
    public var affected: Int?
    /// The message of the error, or "Cancelled"; nil for a run that worked.
    public var error: String?

    /// The SQL is the identity: running the same text again is the same entry.
    public var id: String { sql }

    public init(sql: String, ranAt: Date, duration: Double, rowCount: Int? = nil, affected: Int? = nil, error: String? = nil) {
        self.sql = sql
        self.ranAt = ranAt
        self.duration = duration
        self.rowCount = rowCount
        self.affected = affected
        self.error = error
    }
}

/// Where each connection's query history is kept, per database identity (`DatabaseSession.mapIdentity`).
///
/// The history file is the only place SQL text is stored. It holds no connection password: an entry is the SQL and how
/// the run went.
public protocol QueryHistoryStoring: Sendable {
    /// Newest first.
    func load(identity: String) -> [QueryHistoryEntry]
    func save(identity: String, entries: [QueryHistoryEntry])
}

/// `<directory>/query-history/<fnv1a64(identity)>.json`: `{"version":1,"identity":...,"entries":[...]}`.
///
/// Writes are atomic and the file is readable by its owner only (0600, in a 0700 folder) where the platform has
/// permissions. A file that cannot be read is set aside as `*.corrupt-N`, so nothing is overwritten.
public struct QueryHistoryStore: QueryHistoryStoring {
    /// A connection's history keeps at most this many entries (decision: 500).
    public static let limit = 500

    private struct File: Codable {
        var version: Int
        var identity: String
        var entries: [QueryHistoryEntry]
    }

    private let directory: String

    /// `directory` is the app's support directory; the files go in its `query-history` folder.
    public init(directory: String) { self.directory = directory }

    private var folder: String { (directory as NSString).appendingPathComponent("query-history") }

    /// The file for an identity.
    public func path(identity: String) -> String {
        (folder as NSString).appendingPathComponent(FNV1a64.hex(identity) + ".json")
    }

    public func load(identity: String) -> [QueryHistoryEntry] {
        let path = path(identity: identity)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(File.self, from: data), file.version == 1, file.identity == identity {
            return Array(file.entries.prefix(Self.limit))
        }
        var n = 1
        while fm.fileExists(atPath: path + ".corrupt-\(n)") { n += 1 }
        try? fm.moveItem(atPath: path, toPath: path + ".corrupt-\(n)")
        return []
    }

    public func save(identity: String, entries: [QueryHistoryEntry]) {
        do {
            let fm = FileManager.default
            #if os(Windows)
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            #else
            try fm.createDirectory(
                atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            #endif
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(File(version: 1, identity: identity, entries: Array(entries.prefix(Self.limit))))
            let target = path(identity: identity)
            // Written to a temporary file that is already private, then swapped in for the old one in one step, so a crash
            // leaves either the old history or the new, never none.
            let temporary = target + ".tmp"
            try? fm.removeItem(atPath: temporary)
            #if os(Windows)
            guard fm.createFile(atPath: temporary, contents: data) else { return }
            #else
            guard fm.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
            #endif
            #if os(Windows)
            // swift-corelibs-foundation has not implemented `replaceItemAt` on Windows (it traps); the Win32 call swaps in one step.
            let swapped = temporary.withCString(encodedAs: UTF16.self) { from in
                target.withCString(encodedAs: UTF16.self) { to in
                    MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                }
            }
            if !swapped { try? fm.removeItem(atPath: temporary) }
            #else
            if fm.fileExists(atPath: target) {
                _ = try fm.replaceItemAt(URL(fileURLWithPath: target), withItemAt: URL(fileURLWithPath: temporary))
            } else {
                try fm.moveItem(atPath: temporary, toPath: target)
            }
            #endif
        } catch {
            // A history that cannot be kept is not worth breaking the editor for.
        }
    }
}
