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
    static let jsonLines = 400
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
                JSONLines(grid: grid, lines: JSONLine.flatten(tree, open: grid.inspectorOpen))
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

/// One visible line of a JSON tree.
struct JSONLine: Equatable {
    var path: String
    var depth: Int
    var key: String?
    var summary: String
    var isContainer: Bool
    var isOpen: Bool

    /// The lines a tree shows when only the containers in `open` are open (the root always is).
    static func flatten(_ root: JSONNode, open: Set<String>) -> [JSONLine] {
        var lines: [JSONLine] = []
        func walk(_ node: JSONNode, key: String?, path: String, depth: Int) {
            guard lines.count < InspectorLimits.jsonLines else { return }
            switch node {
            case .object(let members):
                let isOpen = path.isEmpty || open.contains(path)
                lines.append(JSONLine(path: path, depth: depth, key: key, summary: node.summary, isContainer: true, isOpen: isOpen))
                if isOpen { for member in members { walk(member.value, key: member.key, path: path + "/" + member.key, depth: depth + 1) } }
            case .array(let items):
                let isOpen = path.isEmpty || open.contains(path)
                lines.append(JSONLine(path: path, depth: depth, key: key, summary: node.summary, isContainer: true, isOpen: isOpen))
                if isOpen { for (i, item) in items.enumerated() { walk(item, key: "\(i)", path: path + "/\(i)", depth: depth + 1) } }
            default:
                lines.append(JSONLine(path: path, depth: depth, key: key, summary: node.text, isContainer: false, isOpen: false))
            }
        }
        walk(root, key: nil, path: "", depth: 0)
        return lines
    }
}

struct JSONLines: Component {
    let grid: GridModel
    let lines: [JSONLine]

    var content: some ElementGroup {
        let grid = grid
        VStack(alignment: .leading, spacing: Pixels(2)) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(spacing: Pixels(4)) {
                    if line.isContainer, !line.path.isEmpty {
                        Button(line.isOpen ? "\u{25BE}" : "\u{25B8}") {
                            if grid.inspectorOpen.contains(line.path) { grid.inspectorOpen.remove(line.path) } else { grid.inspectorOpen.insert(line.path) }
                        }
                        .accessibilityLabel(line.isOpen ? "Collapse" : "Expand")
                        .accessibilityIdentifier("inspector.json.toggle.\(index)")
                    } else {
                        Text(verbatim: " ").font(size: 12)
                    }
                    if let key = line.key {
                        Text(verbatim: key + ":").font(size: 12).foregroundColor(.secondary)
                    }
                    Text(verbatim: line.summary).font(size: 12).monospaced()
                        .accessibilityLabel(line.summary)
                        .accessibilityIdentifier("inspector.json.line.\(index)")
                }
                .padding(Edges(top: Pixels(0), right: Pixels(0), bottom: Pixels(0), left: Pixels(Float(line.depth) * 14)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.json")
    }
}

extension ValueInspector {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}
