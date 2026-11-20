import Foundation

/// Where the positions of dragged tables are kept, per database (decision D22).
///
/// A position is `[x, y]` in canvas units, keyed by `"schema.table"` (a name, never an OID, so a recreated
/// container keeps its layout).
public protocol MapPositionsStoring: Sendable {
    func load(identity: String) -> [String: [Double]]
    func save(identity: String, positions: [String: [Double]])
}

/// FNV-1a over the UTF-8 bytes: a stable name for a file, the same on every platform and every run.
public enum FNV1a64 {
    public static func hash(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }

    /// Sixteen lowercase hex digits.
    public static func hex(_ text: String) -> String {
        let digits = String(hash(text), radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}

/// `<directory>/map-positions/<fnv1a64(identity)>.json`: `{"version":1,"identity":...,"positions":{"shop.orders":[x,y]}}`.
///
/// The identity is `saved:<uuid>:<database>` or `container:<name>:<database>`. Writes are atomic; a file
/// that cannot be read is set aside as `*.corrupt-N` and the map starts with no pins, so nothing is overwritten.
public struct MapPositionsStore: MapPositionsStoring {
    private struct File: Codable {
        var version: Int
        var identity: String
        var positions: [String: [Double]]
    }

    private let directory: String

    /// `directory` is the app's support directory; the files go in its `map-positions` folder.
    public init(directory: String) { self.directory = directory }

    private var folder: String { (directory as NSString).appendingPathComponent("map-positions") }

    /// The file for an identity.
    public func path(identity: String) -> String {
        (folder as NSString).appendingPathComponent(FNV1a64.hex(identity) + ".json")
    }

    public func load(identity: String) -> [String: [Double]] {
        let path = path(identity: identity)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [:] }
        if let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1, file.identity == identity {
            return file.positions.filter { $0.value.count == 2 }
        }
        var n = 1
        while fm.fileExists(atPath: path + ".corrupt-\(n)") { n += 1 }
        try? fm.moveItem(atPath: path, toPath: path + ".corrupt-\(n)")
        return [:]
    }

    public func save(identity: String, positions: [String: [Double]]) {
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(File(version: 1, identity: identity, positions: positions))
            try data.write(to: URL(fileURLWithPath: path(identity: identity)), options: .atomic)
        } catch {
            // Remembering a position is a convenience: a full disk must not break the map.
        }
    }
}
