/// A table, view or similar, identified by name and never by OID, so a
/// recreated database keeps the same identities.
public struct RelationID: Hashable, Comparable, Sendable, Codable {
    public var schema: String
    public var name: String

    public init(_ schema: String, _ name: String) {
        self.schema = schema
        self.name = name
    }

    /// `schema.name`, for display only. It is not quoted and not safe for SQL.
    public var qualifiedName: String { "\(schema).\(name)" }

    public static func < (lhs: RelationID, rhs: RelationID) -> Bool {
        (lhs.schema, lhs.name) < (rhs.schema, rhs.name)
    }
}

public enum RelationKind: String, Sendable, Codable {
    case table, partitionedTable, view, materializedView, foreignTable
}

public enum RowEstimate: Sendable, Equatable {
    case estimated(Int64)
    case unknown
}

public enum IdentityKind: Sendable, Equatable {
    case always, byDefault
}

public enum ForeignKeyAction: Sendable, Equatable {
    case noAction, restrict, cascade, setNull, setDefault
}

public struct ColumnInfo: Sendable, Equatable {
    public var name: String
    public var ordinal: Int
    public var typeName: String
    public var isNullable: Bool
    public var defaultExpression: String?
    public var identity: IdentityKind?
    public var isGenerated: Bool
    public var isEnum: Bool
    public var comment: String?

    public init(
        name: String, ordinal: Int, typeName: String, isNullable: Bool = true,
        defaultExpression: String? = nil, identity: IdentityKind? = nil,
        isGenerated: Bool = false, isEnum: Bool = false, comment: String? = nil
    ) {
        self.name = name
        self.ordinal = ordinal
        self.typeName = typeName
        self.isNullable = isNullable
        self.defaultExpression = defaultExpression
        self.identity = identity
        self.isGenerated = isGenerated
        self.isEnum = isEnum
        self.comment = comment
    }
}

public struct KeyConstraint: Sendable, Equatable {
    public var name: String
    public var columns: [String]

    public init(name: String, columns: [String]) {
        self.name = name
        self.columns = columns
    }
}

public struct IndexInfo: Sendable, Equatable {
    public var name: String
    public var columns: [String]
    public var isUnique: Bool
    public var isPrimary: Bool
    public var method: String
    public var predicate: String?
    public var definition: String

    public init(
        name: String, columns: [String], isUnique: Bool, isPrimary: Bool,
        method: String, predicate: String? = nil, definition: String
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.method = method
        self.predicate = predicate
        self.definition = definition
    }
}

public struct ForeignKeyInfo: Sendable, Equatable, Identifiable {
    /// `"<from.schema>.<from.name>.<constraint name>"`.
    public var id: String
    public var name: String
    public var from: RelationID
    public var fromColumns: [String]
    public var to: RelationID
    public var toColumns: [String]
    public var onDelete: ForeignKeyAction
    public var onUpdate: ForeignKeyAction

    public init(
        name: String, from: RelationID, fromColumns: [String], to: RelationID, toColumns: [String],
        onDelete: ForeignKeyAction = .noAction, onUpdate: ForeignKeyAction = .noAction
    ) {
        self.id = "\(from.schema).\(from.name).\(name)"
        self.name = name
        self.from = from
        self.fromColumns = fromColumns
        self.to = to
        self.toColumns = toColumns
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }
}

public struct RelationInfo: Sendable, Equatable, Identifiable {
    public var id: RelationID
    public var kind: RelationKind
    /// Information only. Never a key (a recreated database has new OIDs).
    public var oid: UInt32
    public var rowEstimate: RowEstimate
    public var columns: [ColumnInfo]
    public var primaryKey: KeyConstraint?
    public var uniqueConstraints: [KeyConstraint]
    public var indexes: [IndexInfo]
    public var comment: String?

    public init(
        id: RelationID, kind: RelationKind, oid: UInt32 = 0, rowEstimate: RowEstimate = .unknown,
        columns: [ColumnInfo] = [], primaryKey: KeyConstraint? = nil,
        uniqueConstraints: [KeyConstraint] = [], indexes: [IndexInfo] = [], comment: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.oid = oid
        self.rowEstimate = rowEstimate
        self.columns = columns
        self.primaryKey = primaryKey
        self.uniqueConstraints = uniqueConstraints
        self.indexes = indexes
        self.comment = comment
    }
}

extension RelationInfo {
    /// Whether `other` has the same structure: `kind`, `columns`, `primaryKey`, `uniqueConstraints` and `indexes`.
    /// `rowEstimate` (it moves with every autovacuum), `oid` and the relation's own `comment` are ignored; column comments
    /// and defaults are part of `columns`, so changing them still counts. A grid built over a relation
    /// stays valid as long as this holds; its filters, sort and cursor index the columns.
    public func sameStructure(as other: RelationInfo) -> Bool {
        kind == other.kind && columns == other.columns && primaryKey == other.primaryKey
            && uniqueConstraints == other.uniqueConstraints && indexes == other.indexes
    }
}

/// Everything Sift knows about one database's structure. Relations and foreign
/// keys are sorted on creation, so iteration order is deterministic.
public struct SchemaSnapshot: Sendable, Equatable {
    public let serverVersion: Int
    public let schemas: [String]
    public let relations: [RelationInfo]
    public let foreignKeys: [ForeignKeyInfo]

    private let relationIndex: [RelationID: Int]
    private let outgoingIndex: [RelationID: [ForeignKeyInfo]]
    private let incomingIndex: [RelationID: [ForeignKeyInfo]]

    public init(serverVersion: Int, schemas: [String], relations: [RelationInfo], foreignKeys: [ForeignKeyInfo]) {
        self.serverVersion = serverVersion
        self.schemas = schemas.sorted()
        let sortedRelations = relations.sorted { $0.id < $1.id }
        self.relations = sortedRelations
        let sortedKeys = foreignKeys.sorted { $0.id < $1.id }
        self.foreignKeys = sortedKeys
        self.relationIndex = Dictionary(
            sortedRelations.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.outgoingIndex = Dictionary(grouping: sortedKeys, by: \.from)
        self.incomingIndex = Dictionary(grouping: sortedKeys, by: \.to)
    }

    public func relation(_ id: RelationID) -> RelationInfo? {
        relationIndex[id].map { relations[$0] }
    }

    /// Foreign keys that start at `id`, in sorted order.
    public func outgoing(of id: RelationID) -> [ForeignKeyInfo] { outgoingIndex[id] ?? [] }

    /// Foreign keys that point at `id`, in sorted order.
    public func incoming(of id: RelationID) -> [ForeignKeyInfo] { incomingIndex[id] ?? [] }

    public static func == (lhs: SchemaSnapshot, rhs: SchemaSnapshot) -> Bool {
        lhs.serverVersion == rhs.serverVersion && lhs.schemas == rhs.schemas
            && lhs.relations == rhs.relations && lhs.foreignKeys == rhs.foreignKeys
    }
}
