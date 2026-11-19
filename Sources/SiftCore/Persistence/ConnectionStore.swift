import Foundation

/// Where the saved connections are kept.
public protocol ConnectionStoring: Sendable {
    func load() throws -> [SavedConnection]
    func save(_ connections: [SavedConnection]) throws
}

/// `<directory>/connections.json`: `{"version":1,"connections":[...]}`, written atomically. A file
/// that cannot be read is set aside as `connections.json.corrupt-N` and Sift starts empty, so a
/// user's list is never overwritten (decision D13).
public struct ConnectionStore: ConnectionStoring {
    private struct File: Codable {
        var version: Int
        var connections: [SavedConnection]
    }

    private let directory: String

    public init(directory: String) { self.directory = directory }

    private var path: String { (directory as NSString).appendingPathComponent("connections.json") }

    public func load() throws -> [SavedConnection] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return [] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if let file = try? JSONDecoder().decode(File.self, from: data), file.version == 1 {
            return file.connections
        }
        var n = 1
        while fm.fileExists(atPath: path + ".corrupt-\(n)") { n += 1 }
        try fm.moveItem(atPath: path, toPath: path + ".corrupt-\(n)")
        return []
    }

    public func save(_ connections: [SavedConnection]) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(version: 1, connections: connections))
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
