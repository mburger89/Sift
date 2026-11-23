import Foundation
import MetalUI
import MetalUICodeBuffer
import Observation
import SiftCore

/// One connection's SQL editor: the buffer, a run in flight, the last result, and the history.
///
/// **Read-only, always.** Nothing here can run outside a read-only transaction: the runner opens every statement in
/// `BEGIN READ ONLY`, and the model has no switch to change that (edit mode is phase 7). A run is one statement at a
/// time: while one is in flight `runCurrent()` and `runAll()` do nothing and the toolbar shows Cancel.
///
/// What the editor view reads while the user types is the buffer alone: the model's own observable state (the run, the
/// result, the history) changes only when a run starts, ends or is recorded, so a keystroke rebuilds nothing but the
/// editor.
@Observable @MainActor
public final class QueryEditorModel {
    public enum State: Equatable {
        case idle
        case running(startedAt: Date)
        /// A run ended (rows, a command, a cancel or an error).
        case done
    }

    /// What the results pane says about the last run.
    public enum Summary: Equatable {
        case none
        case rows(count: Int, truncated: Bool, seconds: Double)
        case command(text: String, seconds: Double)
        case cancelled
        case failed(QueryFailure)
    }

    /// The text of the read-only refusal (SQLSTATE `25006`).
    public static let readOnlyMessage = "Sift is read-only: this statement would change the database."

    // MARK: What the views read

    public private(set) var state: State = .idle
    public private(set) var summary: Summary = .none
    /// One line per statement of the last run, when it ran several (⇧⌘Return).
    public private(set) var batchLines: [String] = []
    /// "N statements, M rows affected", for a run of several.
    public private(set) var batchSummary: String?
    /// The last row-returning statement's rows, in the grid. Nil when the last run returned none.
    public private(set) var result: GridModel?
    public var timeout: QueryTimeout = .default
    /// Newest first, at most 500.
    public private(set) var history: [QueryHistoryEntry]
    public var historySearch = ""
    public var historyShown = true

    // The completion list. Three properties, so the editor reads only `isCompletionOpen` (which changes when the list opens or
    // closes) and the list reads the rest (which change with each keystroke while it is open).
    public private(set) var isCompletionOpen = false
    var completionItems: [CompletionItem] = []
    public private(set) var completionSelected = 0

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// The history the search field leaves: entries whose SQL contains the text, ignoring case.
    public var visibleHistory: [QueryHistoryEntry] {
        let needle = historySearch.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? history : history.filter { $0.sql.lowercased().contains(needle) }
    }

    // MARK: Parts

    @ObservationIgnored public let buffer: CodeBuffer
    @ObservationIgnored public let decorations: CodeDecorations
    @ObservationIgnored let highlighter: SQLHighlighter
    @ObservationIgnored private let runnerProvider: @MainActor () -> (any QueryRunning)?
    @ObservationIgnored private let store: any QueryHistoryStoring
    @ObservationIgnored private let identity: String?
    @ObservationIgnored private let clock: any SiftClock
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var activeRunner: (any QueryRunning)?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// Set by `cancel()` for the run in flight: a Run-all stops before its next statement. Reset at each run's start.
    @ObservationIgnored private var cancelled = false
    /// Set by `close()`, for good: a run still in flight ends without history, a result or a further statement.
    @ObservationIgnored private var closed = false
    /// Whether the editor's caret blinks while it has the focus; tests turn it off so a focused idle editor draws nothing. Never changes while the app runs.
    public var caretBlink: CodeCaretBlink = .on
    @ObservationIgnored private let schema: @MainActor () -> SchemaSnapshot?
    /// Where the list was computed: accepting an item is honoured only while the buffer and caret are still there.
    @ObservationIgnored private var completionAnchor: (replacing: Range<Int>, version: UInt64, caret: Int)?

    /// - Parameters:
    ///   - runner: the runner of the session's current source, asked at each run (a reconnect gives a new one).
    ///   - identity: what the history is kept under (`DatabaseSession.mapIdentity`), or nil to keep none.
    ///   - schema: the session's current schema snapshot, what completion reads (no query is ever made for it).
    public init(
        runner: @escaping @MainActor () -> (any QueryRunning)?, store: any QueryHistoryStoring, identity: String?,
        schema: @escaping @MainActor () -> SchemaSnapshot? = { nil },
        clock: any SiftClock = SystemClock(), now: @escaping @MainActor () -> Date = { Date() }, text: String = ""
    ) {
        runnerProvider = runner
        self.schema = schema
        self.store = store
        self.identity = identity
        self.clock = clock
        self.now = now
        buffer = CodeBuffer(text)
        decorations = CodeDecorations(buffer: buffer)
        highlighter = SQLHighlighter(buffer: buffer, decorations: decorations)
        history = identity.map { store.load(identity: $0) } ?? []
    }

    // MARK: Running

    /// A statement to send: its text and where it starts in the buffer (UTF-8 offset).
    struct Job: Equatable {
        var sql: String
        var offset: Int
    }

    /// ⌘Return: the selection, or else the statement under the caret.
    public func runCurrent() {
        guard !isRunning, let job = currentJob() else { return }
        start([job])
    }

    /// ⇧⌘Return: every statement of the selection (or of the buffer, with no selection) in order, stopping at the first
    /// error.
    public func runAll() {
        guard !isRunning else { return }
        let jobs = allJobs()
        guard !jobs.isEmpty else { return }
        start(jobs)
    }

    /// Runs `sql` as it is, not looking at the buffer: a history entry.
    public func run(sql: String) {
        guard !isRunning else { return }
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        start([Job(sql: sql, offset: 0)])
    }

    func currentJob() -> Job? {
        let snapshot = buffer.snapshot()
        let selection = buffer.primarySelection
        if !selection.isEmpty {
            let sql = snapshot.text(in: selection.range)
            guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Job(sql: sql, offset: selection.range.lowerBound)
        }
        let text = snapshot.text
        let utf8 = text.utf8
        let caret = utf8.index(utf8.startIndex, offsetBy: min(selection.head, utf8.count))
        guard let range = SQLStatements.statement(at: caret, in: text) else { return nil }
        return Job(sql: String(text[range]), offset: utf8.distance(from: utf8.startIndex, to: range.lowerBound))
    }

    func allJobs() -> [Job] {
        let snapshot = buffer.snapshot()
        let selection = buffer.primarySelection
        let base = selection.isEmpty ? 0 : selection.range.lowerBound
        let text = selection.isEmpty ? snapshot.text : snapshot.text(in: selection.range)
        let utf8 = text.utf8
        return SQLStatements.split(text).map {
            Job(sql: String(text[$0]), offset: base + utf8.distance(from: utf8.startIndex, to: $0.lowerBound))
        }
    }

    private func start(_ jobs: [Job]) {
        closeCompletion()
        highlighter.clearError()
        summary = .none
        batchLines = []
        batchSummary = nil
        guard let runner = runnerProvider() else {
            summary = .failed(QueryFailure(message: "This connection cannot run SQL."))
            state = .done
            return
        }
        activeRunner = runner
        cancelled = false
        state = .running(startedAt: now())
        let version = buffer.version
        let setting = timeout.setting
        runTask = Task { @MainActor [weak self] in
            var done: [(job: Job, outcome: QueryOutcome)] = []
            for job in jobs {
                // A cancel that arrived between two statements has nothing to interrupt: skip the rest instead.
                guard let live = self?.mayStartAnother, live else { break }
                let outcome = await runner.run(job.sql, statementTimeout: setting)
                guard let self, !self.closed else { return }
                done.append((job, outcome))
                self.record(job, outcome)
                switch outcome.kind {
                case .failed, .cancelled: break
                default: continue
                }
                break
            }
            guard let self, !self.closed else { return }
            self.finish(done, count: jobs.count, version: version)
        }
    }

    private var mayStartAnother: Bool { !closed && !cancelled }

    /// Asks the server to stop the statement now running. The run ends as "Cancelled".
    public func cancel() {
        guard isRunning else { return }
        cancelled = true
        activeRunner?.cancel()
    }

    /// Stops what runs and releases the grid: the connection is going away.
    public func close() {
        closed = true
        cancelled = true
        activeRunner?.cancel()
        runTask?.cancel()
        result?.close()
        result = nil
    }

    // MARK: Finishing

    private func finish(_ done: [(job: Job, outcome: QueryOutcome)], count: Int, version: UInt64) {
        defer { state = .done; runTask = nil; activeRunner = nil }
        // The user cancelled, and the run ended some other way: a statement finished and the rest were skipped.
        var skipped = cancelled && !done.isEmpty && done.count < count
        if let kind = done.last?.outcome.kind {
            switch kind {
            case .failed, .cancelled: skipped = false
            default: break
            }
        }
        guard let last = done.last else {
            if cancelled { summary = .cancelled }
            return
        }
        var lastRows: (columns: [ResultColumn], rows: [[SiftValue]], truncated: Bool, seconds: Double)?
        var affected = 0
        var lines: [String] = []
        for (index, step) in done.enumerated() {
            let number = count > 1 ? "\(index + 1). " : ""
            switch step.outcome.kind {
            case .rows(let columns, let rows, let truncated):
                lastRows = (columns, rows, truncated, step.outcome.duration)
                lines.append("\(number)\(Self.rowsText(rows.count, truncated: truncated))")
            case .command(let tag, let n):
                affected += n ?? 0
                lines.append("\(number)\(tag.isEmpty ? "OK" : tag)")
            case .cancelled:
                lines.append("\(number)Cancelled")
            case .failed(let failure):
                lines.append("\(number)\(Self.display(failure).first ?? "Failed")")
            }
        }
        if skipped { lines.append("\(count > 1 ? "\(done.count + 1). " : "")Cancelled") }
        result?.close()
        result = nil
        if let rows = lastRows {
            result = GridModel(source: QueryResultSource(columns: rows.columns, rows: rows.rows), clock: clock)
        }
        if count > 1 {
            batchLines = lines
            let ran = done.count
            batchSummary = "\(ran) statement\(ran == 1 ? "" : "s"), \(affected) row\(affected == 1 ? "" : "s") affected"
        }
        switch last.outcome.kind {
        case _ where skipped:
            summary = .cancelled
        case .rows(_, let rows, let truncated):
            summary = .rows(count: rows.count, truncated: truncated, seconds: last.outcome.duration)
        case .command(let tag, let n):
            let text = n.map { "\(tag.isEmpty ? "OK" : tag): \($0) row\($0 == 1 ? "" : "s") affected" } ?? (tag.isEmpty ? "OK" : tag)
            summary = .command(text: text, seconds: last.outcome.duration)
            if let rows = lastRows, count > 1 {
                summary = .rows(count: rows.rows.count, truncated: rows.truncated, seconds: rows.seconds)
            }
        case .cancelled:
            summary = .cancelled
        case .failed(let failure):
            summary = .failed(failure)
            if let position = failure.position, let job = done.last?.job {
                highlighter.showError(position: position, in: job.sql, startingAt: job.offset, asOf: version)
            }
        }
    }

    /// The text of a run's rows: "1 row", "1,234 rows", and when the cap cut the result "first 100 000 rows" (the words
    /// the decision gives, with the space between thousands it writes).
    static func rowsText(_ count: Int, truncated: Bool) -> String {
        if truncated { return "first \(RowEstimate.grouped(Int64(count)).replacingOccurrences(of: ",", with: " ")) rows" }
        return "\(RowEstimate.grouped(Int64(count))) \(count == 1 ? "row" : "rows")"
    }

    /// The lines the pane shows for a failure: the message (the read-only refusal in Sift's words), then the server's
    /// detail and hint.
    public static func display(_ failure: QueryFailure) -> [String] {
        var lines = [failure.sqlState == QueryFailure.readOnlyViolation ? readOnlyMessage : failure.message]
        if let detail = failure.detail, !detail.isEmpty { lines.append("DETAIL: \(detail)") }
        if let hint = failure.hint, !hint.isEmpty { lines.append("HINT: \(hint)") }
        return lines
    }

    // MARK: History

    private func record(_ job: Job, _ outcome: QueryOutcome) {
        var entry = QueryHistoryEntry(
            sql: job.sql.trimmingCharacters(in: .whitespacesAndNewlines), ranAt: now(), duration: outcome.duration)
        switch outcome.kind {
        case .rows(_, let rows, _): entry.rowCount = rows.count
        case .command(_, let affected): entry.affected = affected
        case .cancelled: entry.error = "Cancelled"
        case .failed(let failure): entry.error = Self.display(failure).first
        }
        guard !entry.sql.isEmpty else { return }
        var next = history.filter { $0.sql != entry.sql }
        next.insert(entry, at: 0)
        if next.count > QueryHistoryStore.limit { next.removeLast(next.count - QueryHistoryStore.limit) }
        history = next
        if let identity { store.save(identity: identity, entries: next) }
    }

    /// Puts a history entry in the editor, replacing the text as one undoable edit.
    public func load(_ entry: QueryHistoryEntry) {
        buffer.breakUndoCoalescing()
        buffer.replace(0..<buffer.utf8Count, with: entry.sql, origin: .programmatic)
        let end = entry.sql.utf8.count
        buffer.select(end..<end)
    }

    /// Loads an entry and runs it exactly as written (a double click).
    public func runHistory(_ entry: QueryHistoryEntry) {
        guard !isRunning else { return }
        load(entry)
        run(sql: entry.sql)
    }

    // MARK: Keys

    /// What the editor's keys do:
    /// - ⌘Return runs, ⇧⌘Return runs all.
    /// - With the completion list open, ↑ and ↓ move in it, Return and Tab accept, and Escape closes it, **and does not
    ///   cancel a run** (one Escape for the list, the next for the query).
    /// - With the list closed, Escape cancels a run in flight.
    /// - Any other key is the editor's own, and the list is worked out again once it has typed.
    ///
    /// Returns whether the key was taken.
    public func handleKey(_ key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        switch key {
        case .return where modifiers.contains(.primary):
            // Taken even while running: the key must not type a newline into the buffer then.
            if modifiers.contains(.shift) { runAll() } else { runCurrent() }
            return true
        case .escape:
            if closeCompletion() { return true }
            if isRunning {
                cancel()
                return true
            }
            return false
        case .downArrow where isCompletionOpen && modifiers.isEmpty:
            moveCompletion(by: 1)
            return true
        case .upArrow where isCompletionOpen && modifiers.isEmpty:
            moveCompletion(by: -1)
            return true
        case .return where isCompletionOpen && modifiers.isEmpty, .tab where isCompletionOpen && modifiers.isEmpty:
            if acceptCompletion() { return true }
            closeCompletion()
            return false
        default:
            // The editor types, deletes or moves the caret; the list follows once it has.
            if modifiers.intersection([.primary, .control]).isEmpty { scheduleCompletionRefresh() }
            return false
        }
    }

    // MARK: Completion

    /// Works the list out again on the next main-actor turn, after the editor has handled the key.
    func scheduleCompletionRefresh() {
        Task { @MainActor [weak self] in self?.refreshCompletion() }
    }

    /// Opens, updates or closes the list for the caret now.
    func refreshCompletion() {
        guard buffer.selections.count == 1, buffer.primarySelection.isEmpty, let snapshot = schema() else {
            closeCompletion()
            return
        }
        let text = buffer.snapshot()
        let caret = buffer.primarySelection.head
        let (window, base) = Self.window(of: text, around: caret)
        guard let found = SQLCompletion.complete(text: window, caret: caret - base, snapshot: snapshot) else {
            closeCompletion()
            return
        }
        let replacing = (found.replacing.lowerBound + base)..<(found.replacing.upperBound + base)
        completionAnchor = (replacing, buffer.version, caret)
        if completionItems != found.items { completionItems = found.items }
        if completionSelected != 0 { completionSelected = 0 }
        if !isCompletionOpen { isCompletionOpen = true }
    }

    /// The text completion reads: the whole buffer, or for a long one the 600 rows around the caret.
    static func window(of snapshot: CodeSnapshot, around caret: Int) -> (text: String, base: Int) {
        guard snapshot.lineCount > 1200 else { return (snapshot.text, 0) }
        let row = snapshot.point(at: caret).row
        let from = max(0, row - 300), to = min(snapshot.lineCount, row + 300)
        let lower = snapshot.lineRange(from).lowerBound
        let upper = snapshot.lineRange(to - 1).upperBound
        return (snapshot.text(in: lower..<upper), lower)
    }

    func moveCompletion(by step: Int) {
        guard isCompletionOpen, !completionItems.isEmpty else { return }
        completionSelected = ((completionSelected + step) % completionItems.count + completionItems.count) % completionItems.count
    }

    /// Replaces what was typed with the chosen item and puts the caret after it. False (and nothing changes) when the
    /// buffer or the caret has moved since the list was worked out.
    @discardableResult
    func acceptCompletion(at index: Int? = nil) -> Bool {
        let chosen = index ?? completionSelected
        guard let anchor = completionAnchor, completionItems.indices.contains(chosen),
              buffer.version == anchor.version, buffer.primarySelection.head == anchor.caret else { return false }
        let text = completionItems[chosen].insertText
        buffer.replace(anchor.replacing, with: text, origin: .typing)
        let end = anchor.replacing.lowerBound + text.utf8.count
        buffer.select(end..<end)
        closeCompletion()
        return true
    }

    /// Closes the list when it is open; returns whether it was.
    @discardableResult
    func closeCompletion() -> Bool {
        completionAnchor = nil
        guard isCompletionOpen else { return false }
        isCompletionOpen = false
        completionItems = []
        completionSelected = 0
        return true
    }
}
