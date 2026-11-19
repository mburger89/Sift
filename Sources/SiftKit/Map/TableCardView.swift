import MetalUI
import SiftCore

/// One table on the map, in canvas units. It is placed by `.offset(origin)`; the map's one transform scales it
/// and moves it, so a pan or a zoom step does not run this body (decision D18).
///
/// **`.equatable()`** (where the card is placed): `==` compares everything the body reads, so a card is rebuilt only
/// when its table, its place, the level of detail, its selection or its label changes. `bodyCount` is what the
/// cost pins read.
struct TableCardView: Component, @MainActor Equatable {
    let relation: RelationInfo
    let keyColumns: [String]
    let origin: LayoutPoint
    let lod: MapLOD
    let isJoin: Bool
    let hasSelfLoop: Bool
    var isSelected = false
    /// What a screen reader says (see `MapCardLabel`).
    var label = ""
    /// `map.card` for the card on the map, `map.spot` for its copy in the spotlight.
    var idPrefix = "map.card"

    /// How many times a card's `content` has run, for the pins that a pan or a zoom step rebuilds none.
    @MainActor static var bodyCount = 0

    var identifier: String { "\(idPrefix).\(relation.id.schema).\(relation.id.name)" }

    var content: some ElementGroup {
        let _ = Self.countBody()
        let size = MapCardMetrics.size(keyColumns: keyColumns)
        let w = Pixels(Float(size.w)), h = Pixels(Float(size.h))
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(relation: relation, lod: lod, isJoin: isJoin, identifier: identifier)
                if lod == .full, !keyColumns.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(keyColumns, id: \.self) { name in
                            CardRow(relation: relation, column: name)
                        }
                    }
                    .accessibilityIdentifier("\(identifier).rows")
                }
            }
            .frame(width: w, height: h, alignment: .topLeading)
            .background(.mapCardFill)
            .roundedBorder(isSelected ? .mapAccent : .mapCardBorder, radius: Pixels(8), width: Pixels(isSelected ? 2 : 1))
            if hasSelfLoop {
                SelfLoopMark(height: size.h, identifier: "\(identifier).selfLoop")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label.isEmpty ? relation.id.name : label)
        .accessibilityIdentifier(identifier)
        .offset(x: Pixels(Float(origin.x)), y: Pixels(Float(origin.y)))
    }

    nonisolated static func == (l: Self, r: Self) -> Bool {
        l.relation == r.relation && l.keyColumns == r.keyColumns && l.origin == r.origin && l.lod == r.lod
            && l.isJoin == r.isJoin && l.hasSelfLoop == r.hasSelfLoop && l.isSelected == r.isSelected && l.label == r.label
            && l.idPrefix == r.idPrefix
    }
}

extension TableCardView {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}

/// The name, and under it what the level of detail shows: the schema, or the row count.
struct CardHeader: Component {
    let relation: RelationInfo
    let lod: MapLOD
    let isJoin: Bool
    let identifier: String

    var content: some ElementGroup {
        let id = relation.id
        VStack(alignment: .leading, spacing: Pixels(1)) {
            switch lod {
            case .nameOnly:
                Text(verbatim: id.name).font(size: 30).lineLimit(1)
            case .compact:
                HStack(spacing: Pixels(6)) {
                    Text(verbatim: id.name).font(size: 14).lineLimit(1)
                    if isJoin { JoinBadge() }
                }
                Text(verbatim: relation.rowEstimate.displayText).font(size: 11).foregroundColor(.secondary).lineLimit(1)
                    .accessibilityIdentifier("\(identifier).count")
            case .full:
                HStack(spacing: Pixels(6)) {
                    Text(verbatim: id.name).font(size: 14).lineLimit(1)
                    if isJoin { JoinBadge() }
                }
                Text(verbatim: "\(relation.kind.displayName) in \(id.schema)").font(size: 11).foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(inset(10, 0))
        .frame(width: Pixels(Float(MapCardMetrics.width)), height: Pixels(Float(MapCardMetrics.headerHeight)), alignment: .leading)
    }
}

/// The small "join" tag on a table that only links others.
struct JoinBadge: Component {
    var content: some ElementGroup {
        HStack(spacing: 0) {
            Text("join").font(size: 10).foregroundColor(.secondary)
        }
        .padding(inset(5, 1))
        .roundedBorder(.mapCardBorder, radius: Pixels(4), width: Pixels(1))
            .accessibilityLabel("join table")
            .accessibilityIdentifier("map.badge.join")
    }
}

/// One key column: its name, and its type at the right.
struct CardRow: Component {
    let relation: RelationInfo
    let column: String

    var content: some ElementGroup {
        let info = relation.columns.first { $0.name == column }
        let isKey = relation.primaryKey?.columns.contains(column) == true
        HStack(spacing: Pixels(8)) {
            Text(verbatim: column).font(size: 12).foregroundColor(isKey ? .primary : .secondary).lineLimit(1)
            Spacer()
            Text(verbatim: info?.typeName ?? "").font(size: 10).foregroundColor(.secondary).lineLimit(1)
        }
        .padding(inset(10, 0))
        .frame(width: Pixels(Float(MapCardMetrics.width)), height: Pixels(Float(MapCardMetrics.rowHeight)), alignment: .leading)
    }
}

/// A loop on a card's right side: the table references itself.
struct SelfLoopMark: Component {
    let height: Double
    let identifier: String

    var content: some ElementGroup {
        let w = Float(MapCardMetrics.width)
        let top = Float(MapCardMetrics.headerHeight / 2)
        let path = Path { p in
            p.move(to: Point(x: Pixels(w), y: Pixels(top)))
            p.addCurve(
                to: Point(x: Pixels(w), y: Pixels(top + 22)),
                control1: Point(x: Pixels(w + 36), y: Pixels(top - 6)),
                control2: Point(x: Pixels(w + 36), y: Pixels(top + 28)))
        }
        path.stroke(.mapEdge, lineWidth: Pixels(1.5))
            .frame(width: Pixels(w + 40), height: Pixels(Float(height)), alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityLabel("references itself")
            .accessibilityIdentifier(identifier)
    }
}

/// The accessibility label of a card: `orders, table, about 4 rows, references customers; referenced by order_items, shipments`.
enum MapCardLabel {
    static func make(_ relation: RelationInfo, in snapshot: SchemaSnapshot) -> String {
        var parts = [relation.id.name, relation.kind.displayName.lowercased()]
        if case .estimated(let n) = relation.rowEstimate { parts.append("about \(n) rows") }
        func names(_ ids: [RelationID]) -> String {
            var seen = Set<RelationID>()
            return ids.filter { seen.insert($0).inserted }.map {
                $0.schema == relation.id.schema ? $0.name : $0.qualifiedName
            }.joined(separator: ", ")
        }
        let outgoing = names(snapshot.outgoing(of: relation.id).map(\.to))
        let incoming = names(snapshot.incoming(of: relation.id).map(\.from))
        var links: [String] = []
        if !outgoing.isEmpty { links.append("references \(outgoing)") }
        if !incoming.isEmpty { links.append("referenced by \(incoming)") }
        return (parts + [links.joined(separator: "; ")].filter { !$0.isEmpty }).joined(separator: ", ")
    }
}
