import MetalUI
import SiftCore

/// What the last run came to: a line saying so (rows, a command, a cancel or the error with its detail and hint), the
/// run's list of statements when there were several, and the rows in the same grid a table uses.
struct QueryResultsPane: Component, Equatable {
    /// How many times `content` has run, for the cost pins (debug builds only).
    @MainActor static var bodyCount = 0

    let editor: QueryEditorModel
    nonisolated static func == (l: Self, r: Self) -> Bool { l.editor === r.editor }

    var content: some ElementGroup {
        // swiftlint:disable:next redundant_discardable_let - result builder: `_ = x` is not valid
        let _ = Self.countBody()
        let editor = editor
        VStack(alignment: .leading, spacing: 0) {
            QueryStatusLine(editor: editor)
            Divider()
            if editor.isRunning {
                HStack(spacing: Pixels(8)) {
                    ProgressView()
                    Text("Running\u{2026}").font(size: 12).foregroundColor(.secondary)
                    Button("Cancel") { editor.cancel() }
                        .accessibilityIdentifier("query.results.cancel")
                }
                .padding(Edges(all: Pixels(12)))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("query.running")
            } else if let grid = editor.result {
                GridContent(grid: grid)
            } else {
                Spacer()
            }
        }
        // One frame layer, with the split's limits (the pane's own answers): the grid below is deep enough already.
        .frame(maxWidth: .infinity, minHeight: Pixels(100), idealHeight: Pixels(300), maxHeight: .infinity, alignment: .topLeading)
    }
}

extension QueryResultsPane {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}

/// The lines above the rows.
struct QueryStatusLine: Component {
    let editor: QueryEditorModel

    var content: some ElementGroup {
        let editor = editor
        VStack(alignment: .leading, spacing: Pixels(3)) {
            switch editor.summary {
            case .none:
                if !editor.isRunning {
                    Text("Run a statement with \(Self.runKeys).").font(size: 12).foregroundColor(.secondary)
                        .accessibilityIdentifier("query.status.hint")
                }
            case .rows(let count, let truncated, let seconds):
                Text(verbatim: "\(QueryEditorModel.rowsText(count, truncated: truncated)) in \(Self.seconds(seconds))").font(size: 12)
                    .accessibilityLabel("\(QueryEditorModel.rowsText(count, truncated: truncated)) in \(Self.seconds(seconds))")
                    .accessibilityIdentifier("query.status.rows")
            case .command(let text, let seconds):
                Text(verbatim: "\(text) in \(Self.seconds(seconds))").font(size: 12)
                    .accessibilityLabel("\(text) in \(Self.seconds(seconds))")
                    .accessibilityIdentifier("query.status.command")
            case .cancelled:
                Text("Cancelled").font(size: 12)
                    .accessibilityLabel("Cancelled")
                    .accessibilityIdentifier("query.status.cancelled")
            case .failed(let failure):
                ForEach(Array(QueryEditorModel.display(failure).enumerated()), id: \.offset) { index, line in
                    Text(verbatim: line).font(size: 12).foregroundColor(index == 0 ? .red : .secondary)
                        .accessibilityLabel(line)
                        .accessibilityIdentifier(index == 0 ? "query.status.error" : "query.status.errorDetail.\(index)")
                }
            }
            if let summary = editor.batchSummary {
                Text(verbatim: summary).font(size: 12).foregroundColor(.secondary)
                    .accessibilityLabel(summary)
                    .accessibilityIdentifier("query.status.batch")
                ForEach(Array(editor.batchLines.enumerated()), id: \.offset) { index, line in
                    Text(verbatim: line).font(size: 11).foregroundColor(.secondary)
                        .accessibilityLabel(line)
                        .accessibilityIdentifier("query.status.batch.\(index)")
                }
            }
        }
        .padding(inset(12, 6))
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    static var runKeys: String {
        #if os(macOS)
        "\u{2318}Return"
        #else
        "Ctrl+Return"
        #endif
    }

    static func seconds(_ seconds: Double) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.1f s", seconds)
    }
}
