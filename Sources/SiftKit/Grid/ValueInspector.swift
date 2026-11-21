import MetalUI
import SiftCore

/// The trailing panel: the active cell's column (name and type) and its full value. JSON is shown as a tree with
/// objects and arrays that open and close; long text wraps; NULL says NULL.
struct ValueInspector: Component, Equatable {
    /// How many times `content` has run, for the cost pins (debug builds only).
    @MainActor static var bodyCount = 0

    let grid: GridModel
    nonisolated static func == (l: Self, r: Self) -> Bool { l.grid === r.grid }

    var content: some ElementGroup {
        let _ = Self.countBody()
        let grid = grid
        VStack(alignment: .leading, spacing: Pixels(8)) {
            if let position = grid.activePosition {
                InspectorBody(grid: grid, position: position)
            } else {
                Text("Select a cell to see its value.").font(size: 12).foregroundColor(.secondary)
                    .accessibilityIdentifier("inspector.empty")
            }
        }
        .padding(Edges(all: Pixels(12)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector")
    }
}

/// The most the inspector draws of one value: past it a value is cut with a note.
enum InspectorLimits {
    static let text = 20_000
    static let jsonChildren = 200
}

struct InspectorBody: Component {
    let grid: GridModel
    let position: GridPosition

    var content: some ElementGroup {
        let grid = grid
        if position.column < 0 {
            Text("Row").font(size: 12).foregroundColor(.secondary)
            Text(verbatim: "\(position.row + 1)").font(size: 13).accessibilityIdentifier("inspector.value")
        } else if grid.columns.indices.contains(position.column) {
            let column = grid.columns[position.column]
            Text(verbatim: column.name).font(size: 14)
                .accessibilityLabel(column.name).accessibilityIdentifier("inspector.column")
            Text(verbatim: column.typeName).font(size: 12).foregroundColor(.secondary)
                .accessibilityLabel(column.typeName).accessibilityIdentifier("inspector.type")
            Text(verbatim: "row \(position.row + 1)").font(size: 12).foregroundColor(.secondary)
            Divider()
            let value = grid.value(row: position.row, column: position.column)
            // Only a value that is still on its way depends on the pages landing.
            let _ = value == nil ? grid.pagesVersion : 0
            ScrollView {
                InspectorValue(grid: grid, column: column, value: value)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The value itself.
struct InspectorValue: Component {
    let grid: GridModel
    let column: ResultColumn
    let value: SiftValue?

    var content: some ElementGroup {
        switch value {
        case nil:
            Text("\u{2026}").foregroundColor(.secondary).accessibilityIdentifier("inspector.value")
        case .null?:
            Text(verbatim: "NULL").italic().foregroundColor(GridPalette.tertiary)
                .accessibilityLabel("null").accessibilityIdentifier("inspector.value")
        case .some(let value):
            let raw = CellFormat.rawText(value)
            if (column.typeName == "jsonb" || column.typeName == "json"), let tree = JSONNode.parse(raw) {
                VStack(alignment: .leading, spacing: Pixels(2)) {
                    JSONNodeView(node: tree, key: nil, path: "")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("inspector.json")
            } else {
                let shown = raw.count > InspectorLimits.text
                    ? String(raw.prefix(InspectorLimits.text)) + "\n\u{2026} \(raw.count - InspectorLimits.text) more characters"
                    : raw
                Text(verbatim: shown.isEmpty ? "\"\"" : shown).font(size: 13)
                    .accessibilityLabel(shown.isEmpty ? "empty" : shown)
                    .accessibilityIdentifier("inspector.value")
                if column.typeName == "timestamptz", let local = CellFormat.timestamptz(raw, in: .current) {
                    Text(verbatim: local).font(size: 12).foregroundColor(.secondary)
                        .accessibilityIdentifier("inspector.local")
                }
            }
        }
    }
}

/// A JSON value as a tree: objects and arrays are `DisclosureGroup`s that open and close, scalars are one line. The root is
/// always open. A container shows at most `InspectorLimits.jsonChildren` children, then says how many it left out.
struct JSONNodeView: Component {
    let node: JSONNode
    let key: String?
    let path: String

    var content: some ElementGroup {
        switch node {
        case .object(let members):
            let shown = Array(members.prefix(InspectorLimits.jsonChildren))
            let more = members.count - shown.count
            if path.isEmpty {
                VStack(alignment: .leading, spacing: Pixels(2)) {
                    JSONLabel(key: key, summary: node.summary, id: "inspector.json.root")
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, member in
                        JSONNodeView(node: member.value, key: member.key, path: path + "/" + member.key)
                    }
                    if more > 0 { JSONMore(count: more) }
                }
                .padding(Edges(top: Pixels(0), right: Pixels(0), bottom: Pixels(0), left: Pixels(0)))
            } else {
                DisclosureGroup {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, member in
                        JSONNodeView(node: member.value, key: member.key, path: path + "/" + member.key)
                    }
                    if more > 0 { JSONMore(count: more) }
                } label: {
                    JSONLabel(key: key, summary: node.summary, id: "inspector.json.node.\(path)")
                }
            }
        case .array(let items):
            let shown = Array(items.prefix(InspectorLimits.jsonChildren))
            let more = items.count - shown.count
            if path.isEmpty {
                VStack(alignment: .leading, spacing: Pixels(2)) {
                    JSONLabel(key: key, summary: node.summary, id: "inspector.json.root")
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                        JSONNodeView(node: item, key: "\(index)", path: path + "/\(index)")
                    }
                    if more > 0 { JSONMore(count: more) }
                }
            } else {
                DisclosureGroup {
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
                        JSONNodeView(node: item, key: "\(index)", path: path + "/\(index)")
                    }
                    if more > 0 { JSONMore(count: more) }
                } label: {
                    JSONLabel(key: key, summary: node.summary, id: "inspector.json.node.\(path)")
                }
            }
        default:
            JSONLabel(key: key, summary: node.text, id: path.isEmpty ? "inspector.json.root" : "inspector.json.node.\(path)")
        }
    }
}

/// `key: summary`, one line.
struct JSONLabel: Component {
    let key: String?
    let summary: String
    let id: String

    var content: some ElementGroup {
        HStack(spacing: Pixels(4)) {
            if let key {
                Text(verbatim: key + ":").font(size: 12).foregroundColor(.secondary)
            }
            Text(verbatim: summary).font(size: 12).monospaced()
                .accessibilityLabel(summary)
                .accessibilityIdentifier(id)
        }
    }
}

struct JSONMore: Component {
    let count: Int

    var content: some ElementGroup {
        Text(verbatim: "\u{2026} \(count) more").font(size: 12).foregroundColor(.secondary)
    }
}

extension ValueInspector {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}
