import SiftCore

/// Where following a key leads: the target relation, the filters that select the referenced (or referencing) rows,
/// the chip-less title, and the data column of the target the cursor lands on.
public struct GridFollow: Equatable, Sendable {
    public var target: RelationID
    public var filters: [GridFilter]
    public var title: String
    /// The first filtered column of the target: where the active cell lands (a data-column index, "#" not counted).
    public var targetColumn: Int

    public init(target: RelationID, filters: [GridFilter], title: String, targetColumn: Int) {
        self.target = target
        self.filters = filters
        self.title = title
        self.targetColumn = targetColumn
    }
}

/// One foreign key of one row, seen from the row's relation.
public struct ReferenceLink: Equatable, Sendable {
    public var foreignKey: ForeignKeyInfo
    /// True when the row's relation holds the key (`from`); false when another relation refers to it.
    public var outgoing: Bool
    /// Nil when the link is disabled: a NULL or a value that is not loaded.
    public var follow: GridFollow?
    /// `customer_id → customers (id = 42)`, `orders.customer_id (= 42)`, or `customer_id is NULL`.
    public var title: String
}

/// The links of a relation's rows, pure over the schema snapshot. The value text is `CellFormat.rawText`, which the
/// grid's bound `::type` filter accepts back; a value is never part of SQL text.
public struct GridLinks: Sendable {
    private let snapshot: SchemaSnapshot
    private let relation: RelationID
    private let columns: [String]

    public init(snapshot: SchemaSnapshot, relation: RelationID) {
        self.snapshot = snapshot
        self.relation = relation
        columns = snapshot.relation(relation)?.columns.map(\.name) ?? []
    }

    /// The columns (of this relation) that start an outgoing key: they draw in the link colour.
    public var outgoingColumns: Set<Int> {
        var out = Set<Int>()
        for key in snapshot.outgoing(of: relation) {
            for name in key.fromColumns { if let i = columns.firstIndex(of: name) { out.insert(i) } }
        }
        return out
    }

    /// Every link of row `row`: outgoing keys first, then the keys that refer to it. `value` reads the row's cells
    /// by data column and answers nil while the row's page is not loaded.
    public func links(row: Int, value: (Int) -> SiftValue?) -> [ReferenceLink] {
        snapshot.outgoing(of: relation).map { link($0, outgoing: true, value: value) }
            + snapshot.incoming(of: relation).map { link($0, outgoing: false, value: value) }
    }

    /// The follow of the active cell: its column must belong to exactly one outgoing key, and that key must be enabled.
    public func primaryFollow(row: Int, column: Int, value: (Int) -> SiftValue?) -> GridFollow? {
        guard columns.indices.contains(column) else { return nil }
        let keys = snapshot.outgoing(of: relation).filter { $0.fromColumns.contains(columns[column]) }
        guard keys.count == 1 else { return nil }
        return link(keys[0], outgoing: true, value: value).follow
    }

    // MARK: One link

    private func link(_ key: ForeignKeyInfo, outgoing: Bool, value: (Int) -> SiftValue?) -> ReferenceLink {
        let mine = outgoing ? key.fromColumns : key.toColumns
        let theirs = outgoing ? key.toColumns : key.fromColumns
        let target = outgoing ? key.to : key.from
        let base = outgoing ? Self.outgoingBase(key) : Self.incomingBase(key)
        let disabled = { (title: String) in ReferenceLink(foreignKey: key, outgoing: outgoing, follow: nil, title: title) }

        var texts: [String] = []
        for name in mine {
            guard let at = columns.firstIndex(of: name) else { return disabled(base) }
            guard let cell = value(at) else { return disabled("\(base) (not loaded)") }
            if case .null = cell {
                return disabled(outgoing ? "\(mine.joined(separator: ", ")) is NULL" : "\(base) (\(name) is NULL)")
            }
            texts.append(CellFormat.rawText(cell))
        }
        guard let targetColumns = snapshot.relation(target)?.columns.map(\.name) else { return disabled(base) }
        var filters: [GridFilter] = []
        for (name, text) in zip(theirs, texts) {
            guard let at = targetColumns.firstIndex(of: name) else { return disabled(base) }
            filters.append(GridFilter(column: at, op: .eq, value: text))
        }
        let title =
            outgoing
            ? "\(mine.joined(separator: ", ")) → \(Self.name(target, relativeTo: key.from)) (\(zip(theirs, texts).map { "\($0) = \($1)" }.joined(separator: ", ")))"
            : "\(Self.name(target, relativeTo: key.to)).\(theirs.joined(separator: ", ")) (= \(texts.joined(separator: ", ")))"
        guard let first = filters.first else { return disabled(base) }
        return ReferenceLink(
            foreignKey: key, outgoing: outgoing,
            follow: GridFollow(target: target, filters: filters, title: title, targetColumn: first.column), title: title)
    }

    private static func name(_ id: RelationID, relativeTo other: RelationID) -> String {
        id.schema == other.schema ? id.name : id.qualifiedName
    }

    /// `customer_id → customers.id`, as `KeysSection` writes it.
    static func outgoingBase(_ key: ForeignKeyInfo) -> String {
        "\(key.fromColumns.joined(separator: ", ")) → \(name(key.to, relativeTo: key.from)).\(key.toColumns.joined(separator: ", "))"
    }

    /// `orders.customer_id`.
    static func incomingBase(_ key: ForeignKeyInfo) -> String {
        "\(name(key.from, relativeTo: key.to)).\(key.fromColumns.joined(separator: ", "))"
    }
}
