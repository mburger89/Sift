/// Why a source call failed. The message never contains a password.
public struct SourceError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case connectionLost
        case readOnlyNotEnforced
        case cancelled
        case server(sqlState: String)
        case other
    }

    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// A read-only view of one database, as the UI sees it.
public protocol DatabaseSource: AnyObject, Sendable {
    func snapshot() async throws -> SchemaSnapshot
    func firstRows(of relation: RelationID, limit: Int) async throws -> ResultPage
    func exactRowCount(of relation: RelationID) async throws -> Int64
    func cancelCurrent()
    var isBroken: Bool { get }
    func close()
    /// A grid over `relation`, on a connection of its own so cancelling a grid never cancels a schema refresh,
    /// or nil when the source cannot page rows. The source closes it with itself.
    func gridSource(for relation: RelationInfo) -> (any GridSource)?
}

extension DatabaseSource {
    public func gridSource(for relation: RelationInfo) -> (any GridSource)? { nil }
}
