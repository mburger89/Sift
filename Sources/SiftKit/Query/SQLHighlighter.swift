import MetalUI
import MetalUICodeBuffer
import SiftCore

/// Colours a `CodeBuffer` as SQL and marks an error in it.
///
/// It is MetalUI's highlight provider for the buffer's `CodeDecorations`: the view asks for the rows it shows whose
/// highlights are unknown or stale, and the answer comes from an `SQLTokenCache` kept between edits. An edit is read
/// from the buffer's own edit stream, so one keystroke lexes the lines it touched and, when it opens or closes a
/// comment or a string, the lines whose state it changed; those that are off screen are marked stale and answered when
/// they come into view.
///
/// An error is one wavy underline (the diagnostics layer, an owner of its own, so it never mixes with the syntax
/// colours) and a mark in the gutter. It follows edits above it and goes away with the first edit on its line.
@MainActor
final class SQLHighlighter: CodeHighlightProvider {
    let buffer: CodeBuffer
    let decorations: CodeDecorations
    let cache = SQLTokenCache()

    /// The row ranges the view asked for, in order. For cost tests.
    private(set) var requests: [Range<Int>] = []
    /// How many lines have been lexed in all: for cost tests.
    var lexedLines: Int { cache.relexedTotal }

    private let cursor: CodeEditCursor
    private var primed = false
    private let styles: Styles

    /// The row the error is on, kept through edits above it.
    private(set) var errorRow: Int?
    static let owner = CodeDecorationOwner("sift.sql.error", priority: 10)

    private struct Styles {
        var byKind: [SQLTokenKind: CodeStyleID] = [:]
        var error: CodeStyleID
    }

    /// Becomes `decorations`' highlight provider (which holds it weakly: the caller keeps it).
    init(buffer: CodeBuffer, decorations: CodeDecorations) {
        self.buffer = buffer
        self.decorations = decorations
        cursor = buffer.makeEditCursor()
        var byKind: [SQLTokenKind: CodeStyleID] = [:]
        for kind in [SQLTokenKind.keyword, .string, .number, .comment, .parameter] {
            if let color = SQLTheme.color(for: kind) { byKind[kind] = decorations.register(CodeStyle(foreground: color)) }
        }
        styles = Styles(byKind: byKind, error: decorations.register(CodeStyle(underline: .wavy(SQLTheme.error))))
        decorations.highlightProvider = self
    }

    // MARK: Answering the view

    func decorations(_ decorations: CodeDecorations, needHighlightsForRows rows: Range<Int>, in snapshot: CodeSnapshot) {
        requests.append(rows)
        refresh(snapshot)
        answer(rows, snapshot)
    }

    /// Reads the edits since the last look into the token cache, clears the error an edit touched, and marks stale the
    /// rows below an edit whose colours changed with it.
    private func refresh(_ snapshot: CodeSnapshot) {
        let lines: (Int) -> Substring = { Substring(snapshot.line($0)) }
        let count = snapshot.lineCount
        switch cursor.drain() {
        case .resync:
            cache.updateAll(lines: lines, lineCount: count, from: 0)
            primed = true
            clearError()
        case .edits(let edits):
            if !primed || cache.lineCount == 0 {
                cache.updateAll(lines: lines, lineCount: count, from: 0)
                primed = true
                clearError()
                return
            }
            guard !edits.isEmpty else { return }
            for edit in edits { trackError(through: edit) }
            let relexed: Range<Int>
            var editedEnd: Int
            if edits.count == 1, let edit = edits.first {
                let first = edit.startPoint.row
                let replaced = edit.oldEndPoint.row - first + 1
                relexed = cache.update(lines: lines, lineCount: count, editedFrom: first, replacing: replaced)
                editedEnd = edit.newEndPoint.row + 1
            } else {
                let first = edits.map(\.startPoint.row).min() ?? 0
                relexed = cache.updateAll(lines: lines, lineCount: count, from: first)
                editedEnd = relexed.upperBound
            }
            editedEnd = min(editedEnd, relexed.upperBound)
            if editedEnd < relexed.upperBound {
                // Rows below the edit changed colour (a comment or a string opened or closed): the visible ones are
                // answered now, the rest when they are scrolled to.
                let from = snapshot.lineRange(editedEnd).lowerBound
                let to = snapshot.lineRange(relexed.upperBound - 1).upperBound
                decorations.invalidateHighlights(in: from..<to, layer: .syntax)
            }
        }
    }

    private func answer(_ rows: Range<Int>, _ snapshot: CodeSnapshot) {
        let rows = max(0, rows.lowerBound)..<min(snapshot.lineCount, rows.upperBound)
        guard !rows.isEmpty else { return }
        var runs: [CodeStyleRun] = []
        for row in rows {
            let start = snapshot.lineRange(row).lowerBound
            for token in cache.tokens(line: row) {
                guard let style = styles.byKind[token.kind] else { continue }
                runs.append(CodeStyleRun(range: (start + token.range.lowerBound)..<(start + token.range.upperBound), style: style))
            }
        }
        let from = snapshot.lineRange(rows.lowerBound).lowerBound
        let to = snapshot.lineRange(rows.upperBound - 1).upperBound
        decorations.setHighlights(runs, in: from..<to, layer: .syntax, asOf: snapshot.version)
    }

    // MARK: Errors

    /// Underlines the token the server's `position` (1-based, in characters of `sent`) points at. `sent` is the text that
    /// was run and `offset` the UTF-8 offset in the buffer, as of `version`, where it started: the selection's start for
    /// a selection, the statement's start otherwise.
    func showError(position: Int, in sent: String, startingAt offset: Int, asOf version: UInt64) {
        let inSent = SQLStatements.errorRange(position: position, in: sent)
        showError((offset + inSent.lowerBound)..<(offset + inSent.upperBound), asOf: version)
    }

    /// Underlines `range` (UTF-8 offsets into the text as of `version`) and marks its row in the gutter, replacing any
    /// earlier error.
    func showError(_ range: Range<Int>, asOf version: UInt64) {
        // Edits made before the error arrived are not its business.
        refresh(buffer.snapshot())
        clearError()
        guard let lower = buffer.map(range.lowerBound, from: version, bias: .after),
              let upper = buffer.map(range.upperBound, from: version, bias: .before) else { return }
        let now = buffer.snapshot()
        let total = now.utf8Count
        let at = min(lower, total)
        let end = min(max(upper, at), total)
        let row = now.point(at: at).row
        decorations.setHighlights(
            [CodeStyleRun(range: at..<end, style: styles.error)], in: 0..<total, layer: .diagnostics,
            asOf: now.version, owner: Self.owner)
        decorations.setLineDecorations(
            [CodeLineDecoration(lines: row..<(row + 1), gutterMarker: CodeGutterMarker("!", color: SQLTheme.error, severity: 2))],
            asOf: now.version, owner: Self.owner)
        errorRow = row
    }

    /// Removes the error mark, if there is one.
    func clearError() {
        guard errorRow != nil else { return }
        errorRow = nil
        let total = buffer.utf8Count
        decorations.setHighlights([], in: 0..<total, layer: .diagnostics, asOf: buffer.version, owner: Self.owner)
        decorations.removeDecorations(of: Self.owner)
    }

    /// The underlined byte ranges now, for tests.
    var errorRanges: [Range<Int>] {
        decorations.highlights(in: 0..<buffer.utf8Count, layer: .diagnostics, owner: Self.owner).map(\.range)
    }

    /// Follows the error's row through one edit: an edit on its row clears it, one above shifts it.
    private func trackError(through edit: CodeEdit) {
        guard let row = errorRow else { return }
        let first = edit.startPoint.row, oldLast = edit.oldEndPoint.row
        if row >= first && row <= oldLast {
            clearError()
        } else if row > oldLast {
            errorRow = row + (edit.newEndPoint.row - first) - (oldLast - first)
        }
    }
}
