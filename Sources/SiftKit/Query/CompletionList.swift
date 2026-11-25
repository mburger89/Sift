import MetalUI
import SiftCore

/// The list under the caret: the items completion found, the chosen one highlighted. It never takes focus or keys (the
/// editor keeps both; its key handler moves the choice). At most ten rows show, the window following the choice.
///
/// It draws its own background and border: a suggestion overlay has no chrome.
struct CompletionList: Component, Equatable {
    /// How many times `content` has run, for the cost pins (debug builds only).
    @MainActor static var bodyCount = 0
    static let visibleRows = 10

    let editor: QueryEditorModel
    nonisolated static func == (l: Self, r: Self) -> Bool { l.editor === r.editor }

    var content: some ElementGroup {
        // swiftlint:disable:next redundant_discardable_let - result builder: `_ = x` is not valid
        let _ = Self.countBody()
        let editor = editor
        let items = editor.completionItems
        let selected = editor.completionSelected
        let first = Self.firstVisible(selected: selected, count: items.count)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items[first..<min(items.count, first + Self.visibleRows)].enumerated()), id: \.offset) { offset, item in
                let index = first + offset
                HStack(spacing: Pixels(12)) {
                    Text(verbatim: item.name).font(size: 12).monospaced()
                        .accessibilityLabel(item.name)
                        .accessibilityIdentifier("completion.item.\(index)")
                    Spacer()
                    Text(verbatim: item.detail).font(size: 11).foregroundColor(.secondary)
                }
                .padding(inset(8, 3))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(index == selected ? Color.accent.opacity(0.25) : Color.clear)
                .onTapGesture { editor.acceptCompletion(at: index) }
            }
        }
        .frame(width: Pixels(320))
        .padding(Edges(all: Pixels(2)))
        .background(.surface)
        .cornerRadius(Pixels(6))
        .roundedBorder(.secondary, radius: Pixels(6), width: Pixels(1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("completion")
    }

    /// The first row shown: the window follows the choice, which sits in its middle once the list is long enough.
    static func firstVisible(selected: Int, count: Int) -> Int {
        guard count > visibleRows else { return 0 }
        return min(max(0, selected - visibleRows / 2), count - visibleRows)
    }
}

extension CompletionList {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}
