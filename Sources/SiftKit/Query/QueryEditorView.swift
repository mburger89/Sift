import MetalUI
import SiftCore

/// The Query tab of a connection: the toolbar, then the editor over the results in a vertical split (its divider kept for
/// the session), the history column beside the editor.
///
/// **It is kept shallow on purpose.** The grid in the results sits below this view, the window, `DetailArea` and the split, and
/// on Windows the test process has a 1 MB main-thread stack that a debug build's nested builders nearly fill: so this view adds
/// no stack of its own (its children are `DetailArea`'s own), and the split is built here, not in a component of its own.
struct QueryDetailView: Component {
    let model: AppModel
    let key: ConnectionKey
    let session: DatabaseSession
    let editor: QueryEditorModel

    var content: some ElementGroup {
        ConnectionBanner(model: model, key: key)
        QueryToolbar(model: model, editor: editor).equatable()
        Divider()
        VSplitView {
            HStack(spacing: 0) {
                QueryEditorPane(editor: editor).equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                QueryHistoryColumn(editor: editor).equatable()
            }
            .frame(minHeight: Pixels(120), idealHeight: Pixels(300))
            QueryResultsPane(editor: editor).equatable()
        }
        .splitViewDividerIdentifier("query.divider")
        .splitViewAutosaveName("sift.query", store: session.querySplitStore)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // swiftlint:disable:next redundant_discardable_let - result builder: `_ = x` is not valid
        let _ = Self.countBody()
        let editor = editor
        let model = model
        HStack(spacing: Pixels(8)) {
            DetailModePicker(model: model, identifier: "query.mode").equatable()
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
        // swiftlint:disable:next redundant_discardable_let - result builder: `_ = x` is not valid
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
