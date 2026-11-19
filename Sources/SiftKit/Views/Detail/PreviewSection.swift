import MetalUI
import SiftCore

/// The first rows of a relation, read-only. Phase 2 draws the first 100 rows and the first 64 columns of
/// fixed-width cells in a two-axis `ScrollView` over a `LazyVStack` (decision D16); the virtualised `Table`
/// is MetalUI's phase 1 (gap G6). Cells are `Text`: nothing here can edit.
struct PreviewSection: Component {
    let session: DatabaseSession
    let relation: RelationInfo

    static let columnLimit = 64
    static let cellWidth: Float = 150
    static let rowHeight: Float = 24

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: 0) {
            switch session.rows[relation.id] {
            case .loaded(let page)?:
                PreviewTable(page: page)
            case .failed(let message)?:
                Text(message).foregroundColor(.secondary).padding(Edges(all: Pixels(16)))
                    .accessibilityIdentifier("preview.error")
            case .loading?, nil:
                Text("Loading rows…").foregroundColor(.secondary).padding(Edges(all: Pixels(16)))
                    .accessibilityIdentifier("preview.loading")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PreviewTable: Component {
    let page: ResultPage

    var content: some ElementGroup {
        let shown = Array(page.columns.prefix(PreviewSection.columnLimit))
        VStack(alignment: .leading, spacing: 0) {
            if page.columns.count > shown.count {
                Text("showing \(shown.count) of \(page.columns.count) columns").font(size: 12).foregroundColor(.secondary)
                    .accessibilityLabel("showing \(shown.count) of \(page.columns.count) columns")
                    .accessibilityIdentifier("preview.columnsNote")
                    .padding(inset(16, 4))
            }
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(0..<page.rows.count, id: \.self) { row in
                            PreviewRow(index: row, values: Array(page.rows[row].prefix(shown.count)))
                        }
                    } header: {
                        PreviewHeader(columns: shown)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PreviewHeader: Component {
    let columns: [ResultColumn]

    var content: some ElementGroup {
        HStack(spacing: 0) {
            ForEach(0..<columns.count, id: \.self) { i in
                Text(columns[i].name).font(size: 12).foregroundColor(.secondary)
                    .frame(width: Pixels(PreviewSection.cellWidth), alignment: .leading)
            }
        }
        .frame(height: Pixels(PreviewSection.rowHeight))
        .background(.surface)
    }
}

struct PreviewRow: Component, Equatable {
    let index: Int
    let values: [SiftValue]

    var content: some ElementGroup {
        HStack(spacing: 0) {
            ForEach(0..<values.count, id: \.self) { column in
                PreviewCell(id: "cell.\(index).\(column)", value: values[column])
            }
        }
        .frame(height: Pixels(PreviewSection.rowHeight))
    }
}

/// One cell: text, or NULL in italics (label "null"), or an empty string (label "empty").
struct PreviewCell: Component, Equatable {
    let id: String
    let value: SiftValue

    var content: some ElementGroup {
        if case .null = value {
            Text("NULL").font(size: 13).italic().foregroundColor(.secondary)
                .accessibilityLabel("null").accessibilityIdentifier(id)
                .frame(width: Pixels(PreviewSection.cellWidth), alignment: .leading)
        } else if case .text(let text) = value, text.isEmpty {
            Text(" ").font(size: 13)
                .accessibilityLabel("empty").accessibilityIdentifier(id)
                .frame(width: Pixels(PreviewSection.cellWidth), alignment: .leading)
        } else {
            Text(value.displayText).font(size: 13).lineLimit(1)
                .accessibilityIdentifier(id)
                .frame(width: Pixels(PreviewSection.cellWidth), alignment: .leading)
        }
    }
}
