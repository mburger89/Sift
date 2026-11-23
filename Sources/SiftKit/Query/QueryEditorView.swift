import MetalUI
import SiftCore

/// The Query tab of a connection: the toolbar, the editor over the results in a vertical split (its divider kept for
/// the session), and the history column on the right.
struct QueryDetailView: Component {
    let model: AppModel
    let key: ConnectionKey
    let session: DatabaseSession

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: 0) {
            ConnectionBanner(model: model, key: key)
            if let editor = session.queryEditor() {
                QueryToolbar(model: model, editor: editor).equatable()
                Divider()
                HStack(spacing: 0) {
                    QuerySplit(editor: editor, store: session.querySplitStore).equatable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    QueryHistoryColumn(editor: editor).equatable()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("This connection cannot run SQL.").foregroundColor(.secondary)
                    .padding(Edges(all: Pixels(16)))
                    .accessibilityIdentifier("query.unavailable")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("query")
    }
}

/// The editor above the results, with a draggable divider between them.
struct QuerySplit: Component, Equatable {
    let editor: QueryEditorModel
    let store: SplitSizesStore
    nonisolated static func == (l: Self, r: Self) -> Bool { l.editor === r.editor && l.store === r.store }

    var content: some ElementGroup {
        VSplitView {
            QueryEditorPane(editor: editor).equatable()
                .frame(minHeight: Pixels(120), idealHeight: Pixels(300))
            QueryResultsPane(editor: editor).equatable()
                .frame(minHeight: Pixels(100), idealHeight: Pixels(300))
        }
        .splitViewDividerIdentifier("query.divider")
        .splitViewAutosaveName("sift.query", store: store)
    }
}

/// Where a connection's split divider is kept: in memory, for the session (the history and the text are the persisted parts).
@MainActor
public final class SplitSizesStore: SplitViewAutosaveStore {
    private var sizes: [String: [Double]] = [:]
    public init() {}
    public func paneSizes(forName name: String) -> [Double]? { sizes[name] }
    public func setPaneSizes(_ sizes: [Double], forName name: String) { self.sizes[name] = sizes }
}

/// The strip above the editor: the Table | Map | Query switch, Run or Cancel, Run all, the timeout and the history toggle.
struct QueryToolbar: Component, Equatable {
    /// How many times `content` has run, for the cost pins (debug builds only).
    @MainActor static var bodyCount = 0

    let model: AppModel
    let editor: QueryEditorModel
    nonisolated static func == (l: Self, r: Self) -> Bool { l.model === r.model && l.editor === r.editor }

    var content: some ElementGroup {
        let _ = Self.countBody()
        let editor = editor
        let model = model
        HStack(spacing: Pixels(8)) {
            Picker("View", selection: Binding(get: { model.detailMode }, set: { model.setDetailMode($0) })) {
                Text("Table").tag(DetailMode.table)
                Text("Map").tag(DetailMode.map)
                Text("Query").tag(DetailMode.query)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("query.mode")
            if editor.isRunning {
                Button("Cancel") { editor.cancel() }
                    .accessibilityIdentifier("query.cancel")
            } else {
                Button("Run") { editor.runCurrent() }
                    .keyboardShortcut(.return, modifiers: .primary)
                    .accessibilityIdentifier("query.run")
            }
            Button("Run all") { editor.runAll() }
                .keyboardShortcut(.return, modifiers: [.primary, .shift])
                .disabled(editor.isRunning)
                .accessibilityIdentifier("query.runAll")
            Picker("Timeout", selection: Binding(get: { editor.timeout }, set: { editor.timeout = $0 })) {
                ForEach(QueryTimeout.allCases, id: \.self) { option in
                    Text(verbatim: option.title).tag(option)
                }
            }
            .accessibilityIdentifier("query.timeout")
            Spacer()
            Button(editor.historyShown ? "Hide history" : "History") { editor.historyShown.toggle() }
                .accessibilityIdentifier("query.historyToggle")
        }
        .padding(inset(12, 0))
        // A fixed height: the editor under it must not change size when a label (Run, Cancel) changes width.
        .frame(maxWidth: .infinity, minHeight: Pixels(44), maxHeight: Pixels(44))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("query.toolbar")
    }
}

extension QueryToolbar {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}

/// The editor: a `CodeView` over the model's buffer. **It reads no observable state of the model**, so a keystroke
/// (which changes only the buffer, that the `CodeView` draws itself) rebuilds nothing else.
struct QueryEditorPane: Component, Equatable {
    /// How many times `content` has run, for the cost pins (debug builds only).
    @MainActor static var bodyCount = 0

    let editor: QueryEditorModel
    nonisolated static func == (l: Self, r: Self) -> Bool { l.editor === r.editor }

    var content: some ElementGroup {
        let _ = Self.countBody()
        let editor = editor
        CodeView(buffer: editor.buffer, decorations: editor.decorations)
            .font(size: 13)
            .tabWidth(2)
            .indentUsingSpaces(true)
            .gutterMarkerLane(true)
            .codeCaretBlink(editor.caretBlink)
            .accessibilityIdentifier("query.editor")
            .onKeyPress { press in
                editor.handleKey(press.key, modifiers: press.modifiers) ? .handled : .ignored
            }
            // The list follows the caret; nothing but the editor's own key handler closes it (a suggestion overlay takes no key).
            .suggestionOverlay(
                isPresented: Binding(get: { editor.isCompletionOpen }, set: { _ in }), attachmentAnchor: .caret
            ) {
                CompletionList(editor: editor).equatable()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension QueryEditorPane {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}
