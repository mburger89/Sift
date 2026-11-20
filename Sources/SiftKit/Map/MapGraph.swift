import SiftCore
import SiftLayout

/// How much of a card is drawn. Chosen from the zoom (decision D21) with hysteresis, so a zoom
/// that hovers at a boundary does not rebuild every card on each step.
enum MapLOD: Equatable, Sendable {
    case full, compact, nameOnly

    /// The zoom above which cards show their key columns, and above which they show a row count.
    static let fullThreshold = 0.55
    static let compactThreshold = 0.25
    static let hysteresis = 0.03

    /// The level for zoom `z`, given the level in force. Leaving a level takes `hysteresis` more
    /// than entering it.
    static func forZoom(_ z: Double, previous: MapLOD) -> MapLOD {
        // A boundary is crossed upward at `b + h` when we are below it and downward at `b - h` when above.
        func above(_ boundary: Double, wasAbove: Bool) -> Bool {
            wasAbove ? z >= boundary - hysteresis : z >= boundary + hysteresis
        }
        let wasFull = previous == .full
        let wasCompactOrBetter = previous != .nameOnly
        if above(fullThreshold, wasAbove: wasFull) { return .full }
        if above(compactThreshold, wasAbove: wasCompactOrBetter) { return .compact }
        return .nameOnly
    }
}

/// The sizes of cards, in canvas units. Computed, never measured, so the layout, the drawing and
/// the hit tests agree.
enum MapCardMetrics {
    static let width = 220.0
    static let headerHeight = 36.0
    static let rowHeight = 20.0
    static let bottomPadding = 8.0
    static let maxKeyColumns = 8

    /// The primary key's columns and every foreign key's columns, in column order, at most eight.
    static func keyColumns(of relation: RelationInfo, in snapshot: SchemaSnapshot) -> [String] {
        var keys = Set(relation.primaryKey?.columns ?? [])
        for foreignKey in snapshot.outgoing(of: relation.id) { keys.formUnion(foreignKey.fromColumns) }
        return relation.columns.filter { keys.contains($0.name) }.sorted { $0.ordinal < $1.ordinal }
            .prefix(maxKeyColumns).map(\.name)
    }

    /// The size of the card for a relation with these key columns.
    static func size(keyColumns: [String]) -> (w: Double, h: Double) {
        (width, headerHeight + Double(keyColumns.count) * rowHeight + bottomPadding)
    }

    /// The height of a column's row centre below the card's top, or nil when the column is not shown.
    static func portY(column: String, in keyColumns: [String]) -> Double? {
        keyColumns.firstIndex(of: column).map { headerHeight + (Double($0) + 0.5) * rowHeight }
    }
}

/// Which relations the map shows.
struct MapFilter: Equatable, Sendable {
    /// `nil` shows every schema.
    var schemas: Set<String>?
    var showViews = true

    init(schemas: Set<String>? = nil, showViews: Bool = true) {
        self.schemas = schemas
        self.showViews = showViews
    }
}

/// The schema as a graph for the layout: node `i` is `ids[i]`, edge `j` is the foreign key `edgeFK[j]`.
struct MapGraph: Equatable, Sendable {
    var graph: LayoutGraph
    /// Sorted, so node ids are the same on every run.
    var ids: [RelationID]
    var edgeFK: [ForeignKeyInfo.ID]
    var joinTables: Set<RelationID>
    /// The key columns shown on each card, by node.
    var keyColumns: [[String]]
    var index: [RelationID: Int]
    /// For each edge, the first column of the key on each side (where the edge meets its cards) and its caption.
    var edgeFromColumn: [String] = []
    var edgeToColumn: [String] = []
    var edgeLabel: [String] = []

    func node(of id: RelationID) -> Int? { index[id] }
}

enum MapGraphBuilder {
    static func isView(_ kind: RelationKind) -> Bool { kind == .view || kind == .materializedView }

    static func build(_ snapshot: SchemaSnapshot, filter: MapFilter) -> MapGraph {
        let shown = snapshot.relations.filter { relation in
            if let schemas = filter.schemas, !schemas.contains(relation.id.schema) { return false }
            if !filter.showViews && isView(relation.kind) { return false }
            return true
        }
        let ids = shown.map(\.id)  // relations are already sorted
        var index: [RelationID: Int] = [:]
        for (node, id) in ids.enumerated() { index[id] = node }

        var nodes: [LayoutGraph.Node] = []
        var keyColumns: [[String]] = []
        var joinTables: Set<RelationID> = []
        for (node, relation) in shown.enumerated() {
            let keys = MapCardMetrics.keyColumns(of: relation, in: snapshot)
            keyColumns.append(keys)
            let size = MapCardMetrics.size(keyColumns: keys)
            nodes.append(LayoutGraph.Node(id: node, width: size.w, height: size.h))
            if isJoinTable(relation, in: snapshot) { joinTables.insert(relation.id) }
        }
        var edges: [LayoutGraph.Edge] = []
        var edgeFK: [ForeignKeyInfo.ID] = []
        var fromColumn: [String] = [], toColumn: [String] = [], label: [String] = []
        for foreignKey in snapshot.foreignKeys {
            guard let from = index[foreignKey.from], let to = index[foreignKey.to] else { continue }
            edges.append(LayoutGraph.Edge(from: from, to: to))
            edgeFK.append(foreignKey.id)
            fromColumn.append(foreignKey.fromColumns.first ?? "")
            toColumn.append(foreignKey.toColumns.first ?? "")
            label.append(
                "\(foreignKey.from.name).\(foreignKey.fromColumns.joined(separator: ", ")) → "
                    + "\(foreignKey.to.name).\(foreignKey.toColumns.joined(separator: ", "))")
        }
        return MapGraph(
            graph: LayoutGraph(nodes: nodes, edges: edges), ids: ids, edgeFK: edgeFK, joinTables: joinTables,
            keyColumns: keyColumns, index: index, edgeFromColumn: fromColumn, edgeToColumn: toColumn,
            edgeLabel: label)
    }

    /// A table that only links others: two or more foreign keys, and every column is in the primary key or a foreign key.
    static func isJoinTable(_ relation: RelationInfo, in snapshot: SchemaSnapshot) -> Bool {
        guard relation.kind == .table || relation.kind == .partitionedTable else { return false }
        let outgoing = snapshot.outgoing(of: relation.id)
        guard outgoing.count >= 2 else { return false }
        var keys = Set(relation.primaryKey?.columns ?? [])
        for foreignKey in outgoing { keys.formUnion(foreignKey.fromColumns) }
        return relation.columns.allSatisfy { keys.contains($0.name) }
    }
}

/// Finds tables by name for the map's search field.
enum MapSearch {
    /// Names that start with the query, then names that contain it, then qualified names that contain it;
    /// case-insensitive. Within a tier the shorter name comes first, then the sorted order.
    static func matches(_ query: String, in ids: [RelationID], limit: Int = 8) -> [RelationID] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var tiers: [[RelationID]] = [[], [], []]
        for id in ids {
            let name = id.name.lowercased()
            if name.hasPrefix(q) {
                tiers[0].append(id)
            } else if name.contains(q) {
                tiers[1].append(id)
            } else if id.qualifiedName.lowercased().contains(q) {
                tiers[2].append(id)
            }
        }
        var out: [RelationID] = []
        for tier in tiers {
            // `ids` is in sorted order, and a stable sort by length keeps it within one length.
            out += tier.enumerated().sorted { ($0.element.name.count, $0.offset) < ($1.element.name.count, $1.offset) }
                .map(\.element)
        }
        return Array(out.prefix(limit))
    }
}
