import MetalUI
import SiftCore

/// The collapsible column right of the editor: a search field and the connection's earlier statements, newest first.
/// A click loads one into the editor; a double click runs it.
struct QueryHistoryColumn: Component, Equatable {
    let editor: QueryEditorModel
    nonisolated static func == (l: Self, r: Self) -> Bool { l.editor === r.editor }

    var content: some ElementGroup {
        if editor.historyShown {
            HStack(spacing: 0) {
                Divider()
                QueryHistoryList(editor: editor).equatable()
                    .frame(width: Pixels(260))
            }
        }
    }
}

struct QueryHistoryList: Component, Equatable {
    /// How many times `content` has run, for the cost pins (debug builds only).
    @MainActor static var bodyCount = 0

    let editor: QueryEditorModel
    nonisolated static func == (l: Self, r: Self) -> Bool { l.editor === r.editor }

    var content: some ElementGroup {
        let _ = Self.countBody()
        let editor = editor
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search history", text: Binding(get: { editor.historySearch }, set: { editor.historySearch = $0 }))
                .padding(inset(8, 6))
                .accessibilityIdentifier("query.history.search")
            Divider()
            let entries = editor.visibleHistory
            if entries.isEmpty {
                Text(editor.history.isEmpty ? "Nothing run yet." : "No match.").font(size: 12).foregroundColor(.secondary)
                    .padding(Edges(all: Pixels(12)))
                    .accessibilityIdentifier("query.history.empty")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        VStack(spacing: 0) {
                            QueryHistoryRow(entry: entry, index: index).equatable()
                        }
                        .onTapGesture(count: 2) { editor.runHistory(entry) }
                        .onTapGesture { editor.load(entry) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("query.history")
    }
}

extension QueryHistoryList {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}

/// One entry: the first line of its SQL, then how the run went.
struct QueryHistoryRow: Component, Equatable {
    let entry: QueryHistoryEntry
    let index: Int

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: Pixels(2)) {
            Text(verbatim: Self.preview(entry.sql)).font(size: 12).monospaced().lineLimit(2)
                .accessibilityLabel(entry.sql)
                .accessibilityIdentifier("query.history.\(index)")
            Text(verbatim: Self.detail(entry)).font(size: 11).foregroundColor(entry.error == nil ? .secondary : .red).lineLimit(1)
        }
        .padding(inset(10, 6))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func preview(_ sql: String) -> String {
        let flat = sql.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > 160 ? String(flat.prefix(160)) + "\u{2026}" : flat
    }

    static func detail(_ entry: QueryHistoryEntry) -> String {
        let took = QueryStatusLine.seconds(entry.duration)
        if let error = entry.error { return "\(error) \u{00B7} \(took)" }
        if let count = entry.rowCount { return "\(count) row\(count == 1 ? "" : "s") \u{00B7} \(took)" }
        if let affected = entry.affected { return "\(affected) affected \u{00B7} \(took)" }
        return took
    }
}
