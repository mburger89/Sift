import MetalUI
import SiftCore

/// One cell: a single line of read-only `Text` (it truncates, TBL-K), styled by `CellText`. A cell whose page is not
/// loaded draws a faint placeholder. Equatable, so a cell whose text did not change is not rebuilt.
struct GridCell: Component, Equatable {
    /// Nil for a placeholder.
    let text: CellText?
    let id: String

    var content: some ElementGroup {
        if let text {
            switch text.style {
            case .null:
                Text(verbatim: "NULL").font(size: 13).italic().foregroundStyle(.tertiary)
                    .accessibilityLabel("null").accessibilityIdentifier(id)
            case .empty:
                Text(verbatim: text.text).font(size: 13).foregroundStyle(.tertiary)
                    .accessibilityLabel("empty").accessibilityIdentifier(id)
            case .number:
                Text(verbatim: text.text).font(size: 13).accessibilityIdentifier(id)
            case .mono:
                Text(verbatim: text.text).font(size: 12).monospaced().accessibilityIdentifier(id)
            case .enumLabel:
                Text(verbatim: text.text).font(size: 12)
                    .padding(inset(6, 1))
                    .background(.surfaceSecondary)
                    .cornerRadius(Pixels(8))
                    .accessibilityLabel(text.text).accessibilityIdentifier(id)
            case .plain:
                Text(verbatim: text.text).font(size: 13).accessibilityIdentifier(id)
            }
        } else {
            Text(verbatim: "\u{2026}").font(size: 13).foregroundStyle(.tertiary)
                .accessibilityLabel("loading").accessibilityIdentifier(id)
        }
    }
}
