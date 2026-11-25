import SiftCore

/// Reads a `SchemaSnapshot` from the catalogs of one connection.
public struct PGIntrospector: Sendable {
    private let connection: PGConnection

    public init(connection: PGConnection) { self.connection = connection }

    /// `schemas` limits the result to those schema names (nil means every visible schema).
    /// Foreign keys whose far end is outside the result are dropped, so no edge dangles.
    public func snapshot(schemas wanted: [String]? = nil) async throws -> SchemaSnapshot {
        // A relation dropped by another session while the catalog functions run fails the whole
        // read with XX000 ("could not open relation with OID"); a second read sees the new state.
        var attempt = 1
        while true {
            do { return try await read(schemas: wanted) } catch let e as PGError
                where attempt < 3 && !e.isConnectionLost && (e.sqlState == "XX000" || e.sqlState == "42P01") { attempt += 1 }
        }
    }

    private func read(schemas wanted: [String]?) async throws -> SchemaSnapshot {
        let version = connection.serverVersion
        guard version >= 120_000 else { throw SourceError(.other, "Postgres 12 or later is needed") }
        let filter: [String?] = [wanted.map(PGCatalog.arrayLiteral)]

        let schemaNames = try await connection.execute(PGCatalog.schemas, params: filter).rows.map { $0[0].string }
        var order: [RelationID] = []
        var infos: [RelationID: RelationInfo] = [:]
        for r in try await connection.execute(PGCatalog.relations, params: filter).rows {
            let id = RelationID(r[0].string, r[1].string)
            let tuples = r[4].double
            order.append(id)
            infos[id] = RelationInfo(
                id: id, kind: Self.kind(r[2].string), oid: UInt32(truncatingIfNeeded: r[3].int),
                rowEstimate: tuples < 0 ? .unknown : .estimated(Int64(tuples)), comment: r[5].optionalString)
        }
        for r in try await connection.execute(PGCatalog.columns, params: filter).rows {
            let id = RelationID(r[0].string, r[1].string)
            guard infos[id] != nil else { continue }
            infos[id]!.columns.append(ColumnInfo(
                name: r[3].string, ordinal: Int(r[2].int), typeName: r[4].string, isNullable: r[5].bool,
                defaultExpression: r[6].optionalString, identity: Self.identity(r[7].string),
                isGenerated: r[8].bool, isEnum: r[9].bool, comment: r[10].optionalString))
        }

        // Constraint rows arrive grouped by (relation, constraint) and in key order.
        var foreignKeys: [ForeignKeyInfo] = []
        var currentKey: (rel: RelationID, name: String)?
        var keyColumns: [String] = []
        var refColumns: [String] = []
        var refTarget = RelationID("", "")
        var actions: (ForeignKeyAction, ForeignKeyAction) = (.noAction, .noAction)
        var currentType = ""
        func flush() {
            guard let k = currentKey else { return }
            switch currentType {
            case "p": infos[k.rel]?.primaryKey = KeyConstraint(name: k.name, columns: keyColumns)
            case "u": infos[k.rel]?.uniqueConstraints.append(KeyConstraint(name: k.name, columns: keyColumns))
            default:
                if infos[k.rel] != nil, infos[refTarget] != nil {
                    foreignKeys.append(ForeignKeyInfo(
                        name: k.name, from: k.rel, fromColumns: keyColumns, to: refTarget,
                        toColumns: refColumns, onDelete: actions.1, onUpdate: actions.0))
                }
            }
            keyColumns = []
            refColumns = []
        }
        for r in try await connection.execute(PGCatalog.constraints, params: filter).rows {
            let rel = RelationID(r[0].string, r[1].string)
            guard infos[rel] != nil else { continue }
            if currentKey?.rel != rel || currentKey?.name != r[2].string {
                flush()
                currentKey = (rel, r[2].string)
                currentType = r[3].string
                if currentType == "f" {
                    refTarget = RelationID(r[6].string, r[7].string)
                    actions = (Self.action(r[9].string), Self.action(r[10].string))
                }
            }
            keyColumns.append(r[5].string)
            if currentType == "f" { refColumns.append(r[8].string) }
        }
        flush()

        // Index rows: one per key column.
        var currentIndex: (rel: RelationID, name: String)?
        var indexColumns: [String] = []
        var pending: IndexInfo?
        func flushIndex() {
            guard let k = currentIndex, var index = pending else { return }
            index.columns = indexColumns
            infos[k.rel]?.indexes.append(index)
            indexColumns = []
            pending = nil
        }
        for r in try await connection.execute(PGCatalog.indexes, params: filter).rows {
            let rel = RelationID(r[0].string, r[1].string)
            guard infos[rel] != nil else { continue }
            if currentIndex?.rel != rel || currentIndex?.name != r[2].string {
                flushIndex()
                currentIndex = (rel, r[2].string)
                pending = IndexInfo(
                    name: r[2].string, columns: [], isUnique: r[3].bool, isPrimary: r[4].bool,
                    method: r[5].string, predicate: r[7].optionalString, definition: r[6].string)
            }
            indexColumns.append(r[9].string)
        }
        flushIndex()

        return SchemaSnapshot(
            serverVersion: version, schemas: schemaNames, relations: order.compactMap { infos[$0] },
            foreignKeys: foreignKeys)
    }

    static func kind(_ s: String) -> RelationKind {
        switch s {
        case "p": .partitionedTable
        case "v": .view
        case "m": .materializedView
        case "f": .foreignTable
        default: .table
        }
    }

    static func identity(_ s: String) -> IdentityKind? {
        switch s {
        case "a": .always
        case "d": .byDefault
        default: nil
        }
    }

    static func action(_ s: String) -> ForeignKeyAction {
        switch s {
        case "r": .restrict
        case "c": .cascade
        case "n": .setNull
        case "d": .setDefault
        default: .noAction
        }
    }
}

extension SiftValue {
    fileprivate var string: String {
        switch self {
        case .text(let s), .raw(let s): s
        default: ""
        }
    }
    fileprivate var optionalString: String? {
        switch self {
        case .text(let s), .raw(let s): s
        default: nil
        }
    }
    fileprivate var int: Int64 {
        if case .int(let i) = self { return i }
        return 0
    }
    fileprivate var double: Double {
        if case .double(let d) = self { return d }
        return -1
    }
    fileprivate var bool: Bool {
        if case .bool(let b) = self { return b }
        return false
    }
}
