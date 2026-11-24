import MetalUI
import SiftCore

/// One cell: a single line of read-only `Text` (it truncates, TBL-K), styled by `CellText`. A cell whose page is not
/// loaded draws a faint placeholder. Equatable, so a cell whose text did not change is not rebuilt.
struct GridCell: Component, Equatable {
    /// Nil for a placeholder.
    let text: CellText?
    let id: String
    /// How this cell differs from the previous look, nil when it does not. Colour is never the only signal: a mark is
    /// also the cell's accessibility value.
    var mark: CellMark?
    /// The cell belongs to an outgoing foreign key: its text draws in the link colour.
    var isLink = false

    var content: some ElementGroup {
        GridCellText(text: text, id: id, value: mark?.accessibilityValue, isLink: isLink)
    }
}

/// What a cell's accessibility value says about a change.
enum CellMark: Equatable {
    /// The cell changed.
    case cell
    /// Another cell of a changed row.
    case row
    /// A row that is new, or changed with no earlier copy to compare.
    case newRow

    var accessibilityValue: String {
        switch self {
        case .cell: "changed"
        case .row: "row changed"
        case .newRow: "new or changed"
        }
    }
}

/// The cell's text, styled by `CellText`.
struct GridCellText: Component, Equatable {
    let text: CellText?
    let id: String
    /// What a change mark says; nil leaves the text itself as the cell's value.
    let value: String?
    var isLink = false

    /// The text colour: the link colour in a key column, else the default.
    private var linkColor: Color? { isLink ? Color(LinkAccent.self) : nil }

    /// `text` as the cell's `Text`, carrying `value` when there is one.
    private func shown(_ text: Text) -> Text {
        guard let value else { return text }
        return text.accessibilityValue(value)
    }

    var content: some ElementGroup {
        if let text {
            switch text.style {
            case .null:
                shown(Text(verbatim: "NULL").font(size: 13).italic().foregroundStyle(.tertiary))
                    .accessibilityLabel("null").accessibilityIdentifier(id)
            case .empty:
                shown(Text(verbatim: text.text).font(size: 13).foregroundStyle(.tertiary))
                    .accessibilityLabel("empty").accessibilityIdentifier(id)
            case .number:
                shown(Text(verbatim: text.text).font(size: 13).foregroundColor(linkColor)).accessibilityIdentifier(id)
            case .mono:
                shown(Text(verbatim: text.text).font(size: 12).monospaced().foregroundColor(linkColor)).accessibilityIdentifier(id)
            case .enumLabel:
                Text(verbatim: text.text).font(size: 12).foregroundColor(linkColor)
                    .padding(inset(6, 1))
                    .background(.surfaceSecondary)
                    .cornerRadius(Pixels(8))
                    .accessibilityLabel(text.text).accessibilityIdentifier(id)
                    .accessibilityValue(value ?? text.text)
            case .plain:
                shown(Text(verbatim: text.text).font(size: 13).foregroundColor(linkColor)).accessibilityIdentifier(id)
            }
        } else {
            Text(verbatim: "\u{2026}").font(size: 13).foregroundStyle(.tertiary)
                .accessibilityLabel("loading").accessibilityIdentifier(id)
        }
    }
}
