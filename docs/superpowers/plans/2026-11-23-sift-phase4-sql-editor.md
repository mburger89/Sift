# Sift phase 4: SQL editor — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a SQL editor per connection: write SQL with highlighting and completion, run it (read-only) with ⌘Return, see results in the phase-3 grid, cancel it, see errors at their position, and reuse queries from history.

**Architecture:**
- A pure `SQLTokenizer` in `SiftCore` lexes incrementally, line by line, from a cached per-line state. It feeds MetalUI `CodeDecorations` highlight runs, splits statements, and supplies completion context.
- `PGQueryRunner` in `SiftPG` runs one statement in a read-only transaction:
  - a row-returning statement goes through a server-side cursor, fetching up to a cap into memory, then closes;
  - any other statement runs plainly.
- A `QueryResultSource: GridSource` serves the captured rows to the existing `GridModel`/`GridView`.
- `SiftKit` holds a `QueryEditorModel` per session (`@Observable`), the editor view (MetalUI `CodeView`, editable), the results pane and the history.

**Tech stack:** Swift 6.4, MetalUI at master (bump `METALUI_REF` to whatever master is when the PR opens; at least `3f1b2bb7`), libpq, swift-testing and MetalUITesting.

**Spec:** `docs/superpowers/specs/2026-11-18-sift-design.md`: the "SQL editor" goal, read-only by default, and the anti-goals. The MetalUI contracts used are `CodeView`, `CodeBuffer`, `CodeDecorations` (`setHighlights`, the row-request model, underlines) and `suggestionOverlay(attachmentAnchor:)`. Read `../MetalUI/Sources/MetalUI/Code/` and the `CV-` rulings (`../MetalUI/docs/rules/decision-prefixes.md` gives the document) before using them.

## Global constraints

- **Read-only, always.**
  - Every statement runs in `BEGIN READ ONLY`.
  - A statement the server refuses because the transaction is read-only (SQLSTATE `25006`) shows: "Sift is read-only: this statement would change the database." Nothing else changes.
  - There is no way to run outside read-only in this phase (edit mode is phase 7).
- **Timeouts:**
  - The default editor statement timeout is **60 s**.
  - The setting is per connection, from a fixed menu: 15 s, 60 s, 5 min, none.
  - It is passed to `executeInReadOnlyTransaction`'s `statementTimeout`; "none" is `0`.
- **Cancelling:**
  - Escape in the editor, or the Cancel button, calls `PQcancel` on the editor's **own** connection. That is a third connection per session, opened lazily and separate from the grid's and the schema's.
  - A cancel shows "Cancelled" (SQLSTATE `57014`), not an error.
- **Result cap:**
  - A row-returning statement captures at most **100 000 rows** (`FETCH 1000` repeatedly from a `NO SCROLL` cursor in the same transaction), then `CLOSE` and `COMMIT`.
  - When more exist, the results pane says "first 100 000 rows". The transaction never stays open after a run.
- **Secrets:**
  - Never log SQL text. The history file is the only place SQL is stored.
  - The history lives under `AppPaths` with the user's file permissions (0600) and holds no connection passwords.
- **CI:** CI must stay green on macOS, Linux and Windows. Keep the Windows STL flag. Off-Darwin test pitfalls:
  - use `runUntilIdle()`;
  - sum `frameWork`;
  - use `Modifiers.primary`.
- **No hacks around MetalUI:**
  - Record any MetalUI gap in the spec's section 11 table, continuing from G14, with a minimal repro.
  - Do not edit `../MetalUI`.

## Decisions (coordinator's calls; continue the D-series from the last D in the phase-2 and phase-3 plans)

- **Tokens:**
  - `keyword` (a fixed list of PostgreSQL 17 reserved and common non-reserved words, case-insensitive);
  - `identifier`;
  - `quotedIdentifier` (`"…"` with `""` escapes);
  - `string` (`'…'` with `''`, `E'…'` with backslash escapes, `U&'…'`, and dollar-quoted `$$…$$` / `$tag$…$tag$`);
  - `number`;
  - `comment` (`--` to end of line, and `/* … */` **nested**);
  - `parameter` (`$1`);
  - `operator`;
  - `punctuation` (`, ; ( ) .`);
  - `whitespace`.
  - Unterminated strings, comments and dollar quotes run to the end of the buffer.
- **Incremental lexing:**
  - The lexer state at each line start (`normal`, `inBlockComment(depth)`, `inString(kind)`, `inDollar(tag)`, `inQuotedIdent`) is cached per line.
  - After an edit, re-lex from the first edited line until a line's start state equals its cached state, and stop there.
  - Answer MetalUI's highlight requests from the token cache by row.
  - Cost: a keystroke on line 5 000 of a 10 000-line buffer re-lexes O(changed lines), not the buffer.
- **Colours:** keywords use the accent colour, strings green, numbers orange, comments `.secondary` italic, and parameters purple. Each has light and dark tokens in one `SQLTheme` place.
- **What ⌘Return (`Modifiers.primary` + Return) runs:**
  - the selection, if there is one;
  - otherwise the statement under the caret. Statements are split at top-level `;` by the tokenizer, ignoring `;` inside strings, comments and dollar quotes.
  - ⇧⌘Return runs every statement in order and stops at the first error. The results pane shows the last row-returning statement's result, plus a list of "N statements, M rows affected" lines.
- **Cursor or plain run:** a statement whose first keyword is `SELECT`, `WITH`, `VALUES`, `TABLE` or `SHOW` runs through `DECLARE sift_q NO SCROLL CURSOR FOR <stmt>`. If DECLARE is refused with `42601` or `0A000` (for example `SHOW`), it runs plainly instead. Every other statement runs plainly.
- **Errors:**
  - A server error with a position (`PG_DIAG_STATEMENT_POSITION`, a 1-based character offset in the sent text) is mapped back to the buffer. Account for the selection's or statement's offset, and use characters, not bytes; convert to UTF-8 offsets for `CodeDecorations`.
  - The mapped error gets a red wavy underline over the token at that position, plus a gutter marker on its line, plus the message (and `DETAIL`/`HINT`) in the results pane.
  - The underline clears on the next edit of that line or the next run.
- **History:**
  - Kept per connection identity (`mapIdentity`), newest first, up to 500 entries.
  - Each entry is `{sql, ranAt, duration, rowCount or affected, error message?}`.
  - Running identical SQL again moves the entry to the top and does not duplicate it.
  - A history list sits beside the editor with a search field. Clicking an entry loads it into the editor, replacing the buffer as one undoable edit. Double-clicking runs it.
  - Persisted as JSON under `AppPaths`, through the same injected-store pattern as `MapPositionsStore`.
- **Completion:**
  - A `suggestionOverlay` at the caret offers schema names, relation names and, after `alias.` or `relation.`, that relation's columns. The data comes from the session's `SchemaSnapshot`, with no query.
  - It appears after 2 identifier characters, or immediately after `.`.
  - ↑↓ move, Return or Tab accept, and Escape closes (and does not cancel a running query while the overlay is open).
  - Matching is case-insensitive prefix first, then substring, capped at 50 items.
  - Aliases are resolved by a light scan of the statement's `FROM`/`JOIN` clauses with the tokenizer, not a parser.
- **Layout:**
  - A new "Query" tab per connection, beside the relation detail tabs, opened with ⌘T (`Modifiers.primary`+T) or a toolbar button.
  - Editor on top, results below, in a vertical split with the divider position remembered per session.
  - The history list is in a trailing collapsible column.
- **One query at a time per editor:** while a run is in flight, the Run button becomes Cancel, and ⌘Return is disabled.

## Review focus

1. **Statement splitting is wrong inside dollar quotes or nested comments:** ⌘Return runs half a function body. Test a `DO $fn$ … ; … $fn$` block and `/* /* ; */ ; */`.
2. **An error position off by one or in bytes:** with non-ASCII text before the error (`'héllo' ,, 1`) and with a selection run from mid-buffer, the underline must land on the offending token.
3. **A run leaves a transaction open:** after a cancel, an error mid-FETCH or the 100 000 cap, `pg_stat_activity` must show the editor connection `idle`, not `idle in transaction`. Integration-test all three.
4. **Re-lexing on each keystroke does the whole buffer:** pin the re-lexed line count for an edit at line 5 000 of 10 000. Also pin the case where opening a block comment re-lexes to the end, then closing it re-lexes back only as far as needed.
5. **Escape during completion cancels the query, or Escape while running only closes the overlay:** define both, as Decisions says, and test both.

---

### Task 1: `SQLTokenizer` and statement splitting (SiftCore)

**Files:**
- Create `Sources/SiftCore/SQL/SQLTokenizer.swift`, `Sources/SiftCore/SQL/SQLKeywords.swift` and `Sources/SiftCore/SQL/SQLStatements.swift`.
- Test: `Tests/SiftCoreTests/SQLTokenizerTests.swift` and `SQLStatementsTests.swift`.

**Interfaces:**
```swift
public enum SQLTokenKind: UInt8, Sendable { case keyword, identifier, quotedIdentifier, string, number, comment, parameter, operator_, punctuation, whitespace }
public struct SQLToken: Sendable, Equatable { public var kind: SQLTokenKind; public var range: Range<Int> }   // UTF-8 offsets in the line/text
public enum SQLLexState: Sendable, Hashable { case normal, blockComment(depth: Int), string(SQLStringKind), dollar(tag: String), quotedIdent }
public struct SQLLineLexer { public static func lex(_ line: Substring.UTF8View, from: SQLLexState) -> (tokens: [SQLToken], end: SQLLexState) }
public final class SQLTokenCache {    // per buffer; lines indexed 0..<n
    public init()
    public func update(lines: (Int) -> Substring, lineCount: Int, editedFrom: Int) -> Range<Int>   // returns re-lexed lines
    public func tokens(line: Int) -> [SQLToken]
}
public enum SQLStatements {
    public static func split(_ text: String) -> [Range<String.Index>]           // top-level ';'
    public static func statement(at offset: String.Index, in text: String) -> Range<String.Index>?
    public static func leadingKeyword(_ statement: Substring) -> String?        // skips comments/whitespace, uppercased
}
```

- [ ] **Step 1: write the failing tests**, with exact token ranges:
  - one test per token kind;
  - `nestedBlockCommentsCloseAtDepthZero`;
  - `dollarQuotesWithTagsDoNotEndAtADifferentTag`;
  - `eStringsHonourBackslashEscapes`;
  - `unterminatedStringRunsToTheEnd`;
  - `keywordsAreCaseInsensitive`;
  - `splitIgnoresSemicolonsInStringsCommentsAndDollarQuotes` (the Review focus 1 inputs);
  - `statementAtCaretBetweenTwoStatements` (the caret after `;` belongs to the next statement; whitespace-only gives nil);
  - `leadingKeywordSkipsCommentsAndParens` (`(SELECT 1)` gives `SELECT`; `/*x*/ with` gives `WITH`).
  - Incremental tests:
    - `anEditOnOneLineReLexesOnlyThatLine` (returns `5000..<5001`);
    - `openingABlockCommentReLexesToTheEnd`;
    - `closingItAgainReLexesOnlyUntilTheStateConverges`.
- [ ] **Step 2: run** `swift test --filter 'SQLTokenizerTests|SQLStatementsTests'`. Expect FAIL: not defined.
- [ ] **Step 3: implement.** The lexer works on UTF-8 bytes. It is a hand-written state machine: no regex, no Foundation scanners.
- [ ] **Step 4: run.** Expect PASS.
- [ ] **Step 5: commit** "SQL: tokenizer, incremental cache and statement splitting".

### Task 2: `PGQueryRunner` and `QueryResultSource` (SiftPG and SiftCore)

**Files:**
- Create `Sources/SiftPG/PGQueryRunner.swift` and `Sources/SiftCore/QueryResultSource.swift`.
- Modify `Sources/SiftPG/PGConnection.swift`: expose the error position and detail/hint fields on `PGError` (`PQresultErrorField` `P`, `D`, `H`), and add a way to run several statements inside one read-only transaction on the connection's queue. For example, `readOnlyTransaction(statementTimeout:_ body: (Txn) throws -> T)`, where `Txn.run(sql, params)` uses the connection's private `run`.
- Test: `Tests/SiftPGTests/PGQueryRunnerTests.swift` (an integration test that skips without `SIFT_PG_URL`) and `Tests/SiftCoreTests/QueryResultSourceTests.swift`.

**Interfaces:**
```swift
public struct QueryOutcome: Sendable {
    public enum Kind: Sendable, Equatable { case rows(columns: [ResultColumn], rows: [[SiftValue]], truncated: Bool), command(tag: String, affected: Int?), cancelled, failed(QueryFailure) }
    public var kind: Kind; public var duration: Double
}
public struct QueryFailure: Sendable, Equatable { public var message: String; public var sqlState: String?; public var position: Int?; public var detail: String?; public var hint: String? }  // position: 1-based character offset in the sent text
public final class PGQueryRunner: @unchecked Sendable {
    public init(connection: PGConnection)
    public static let rowCap = 100_000
    public func run(_ sql: String, statementTimeout: String) async -> QueryOutcome
    public func cancel()
}
public final class QueryResultSource: GridSource { public init(columns: [ResultColumn], rows: [[SiftValue]]) }  // sort/filter/search in memory
```

**Notes:**
- `QueryResultSource` sorts, filters and searches in memory, with the same semantics as the pager. It sorts off the main actor. It reuses `GridQuery`, so `GridView` works unchanged.
- `DatabaseSource` gains `queryRunner() -> PGQueryRunner?`, defaulting to nil. `PGSource` opens the editor connection lazily.

- [ ] **Step 1: write the failing tests.**
  - `aSelectReturnsRowsThroughACursorAndCommits`: afterwards, `pg_stat_activity.state` is `idle`.
  - `theCapTruncatesAt100000AndCloses`: use `generate_series(1,100005)`; expect `truncated`, 100 000 rows, and the connection idle.
  - `aWriteIsRefusedAsReadOnly`: `sqlState` is `25006`.
  - `showFallsBackToAPlainRun`.
  - `aSyntaxErrorCarriesItsPosition`: `SELECT 1 ,, 2` gives `position` 10.
  - `cancelReturnsCancelledAndLeavesNoOpenTransaction`: use `pg_sleep(30)` and cancel after 200 ms.
  - `anErrorMidFetchRollsBack`: `SELECT 1/(g-50000) FROM generate_series(1,100000) g` fails during a FETCH; expect idle afterwards.
  - `theTimeoutIsApplied`: timeout `'1s'` with `pg_sleep(3)` gives `57014`.
  - `QueryResultSource` sort, filter and search over captured rows, matching `PGRelationPager`'s results on the same fixture.
- [ ] **Steps 2–4:** fail, implement, pass. Clean up any container you start (prefix `sift-sql-`) and its image if you pulled it.
- [ ] **Step 5: commit** "SQL: the read-only query runner and the in-memory result source".

### Task 3: highlighting and error marks in `CodeView` (SiftKit)

**Files:**
- Create `Sources/SiftKit/Query/SQLHighlighter.swift`. It bridges `SQLTokenCache` to `CodeDecorations`: register the styles once, answer row requests with `setHighlights(_:in:asOf:)`, and update on buffer edits.
- Create `Sources/SiftKit/Query/SQLTheme.swift`.
- Test: `Tests/SiftKitTests/SQLHighlighterTests.swift`.

**Steps:**
- [ ] **Step 1: write the failing tests.**
  - `keywordsStringsAndCommentsGetTheirStyles`: read the runs back from the decorations, or render and check the glyph colours, the same way MetalUI's own `CodeView` highlight tests do.
  - `aKeystrokeReLexesOneLineAndAsksForNoOtherRows`: count re-lexed lines and the `setHighlights` calls.
  - `anErrorUnderlineLandsOnTheTokenAtACharacterPosition`: put non-ASCII text before the error.
  - `anErrorUnderlineFromASelectionRunIsOffsetBySelectionStart`.
  - `editingTheErrorLineClearsTheUnderline`.
  - `anIdleEditorAsksNoFrames` (caret blink aside): use `codeCaretBlink(.off)` in the test, then check zero frames.
- [ ] **Steps 2–4:** fail, implement, pass.
- [ ] **Step 5: commit** "SQL: highlighting and error marks".

### Task 4: `QueryEditorModel`, history store and the Query tab

**Files:**
- Create `Sources/SiftKit/Query/QueryEditorModel.swift`, `QueryEditorView.swift`, `QueryResultsPane.swift` and `QueryHistoryList.swift`.
- Create `Sources/SiftCore/Persistence/QueryHistoryStore.swift`.
- Modify the detail area and toolbar so the Query tab opens with ⌘T.
- Test: `Tests/SiftKitTests/QueryEditorTests.swift`, `Tests/SiftCoreTests/QueryHistoryStoreTests.swift` and `Tests/SiftKitTests/QueryCostTests.swift`.

**Interfaces:**
```swift
@Observable @MainActor public final class QueryEditorModel {
    public let buffer: CodeBuffer
    public private(set) var state: State   // .idle, .running(startedAt), .done(QueryOutcome), with batch results for ⇧⌘Return
    public var timeout: QueryTimeout       // .s15, .s60, .m5, .none
    public func runCurrent()               // selection or statement at caret
    public func runAll()
    public func cancel()
    public var result: GridModel?          // over QueryResultSource for the last rows outcome
    public var history: [QueryHistoryEntry]
}
```

**Steps:**
- [ ] **Step 1: write the failing tests**, using a `FakeQueryRunner` in SiftTestSupport. It records the SQL it gets and its answers can be held.
  - `primaryReturnRunsTheStatementUnderTheCaret`.
  - `primaryReturnRunsTheSelectionWhenThereIsOne`.
  - `shiftPrimaryReturnRunsAllAndStopsAtTheFirstError`.
  - `runningDisablesRunAndShowsCancel`.
  - `escapeCancelsARunningQuery`.
  - `theResultsShowInTheGrid`: the grid cells come from `QueryResultSource`, and a header sort sorts in memory.
  - `aTruncatedResultSaysFirst100000Rows`.
  - `aReadOnlyRefusalShowsTheReadOnlyMessage`.
  - `aCancelShowsCancelledNotAnError`.
  - `historyRecordsEachRunNewestFirstAndDeduplicates`.
  - `clickingHistoryLoadsItAsOneUndoableEdit`.
  - `historyPersistsAcrossLaunchesWith0600Permissions`: the permissions check runs only on POSIX, and Windows skips it.
  - `historyCapsAt500`.

  Cost tests, each shown red under a mutation:
  - `typingInALongBufferCostsOnlyTheEditor`: 10 000 lines, one keystroke. The results grid and history list are not rebuilt.
  - `anIdleQueryTabAsksNoFrames`.
  - `aRunningSpinnerDoesNotRebuildTheEditor`.
- [ ] **Steps 2–4:** fail, implement, pass.
- [ ] **Step 5: commit** "SQL: the editor model, results, history and the Query tab".

### Task 5: completion

**Files:**
- Create `Sources/SiftKit/Query/SQLCompletion.swift`: pure, taking the token context and a `SchemaSnapshot` and returning items.
- Create `Sources/SiftKit/Query/CompletionList.swift`: the overlay content.
- Test: `Tests/SiftKitTests/SQLCompletionTests.swift`.

**Steps:**
- [ ] **Step 1: write the failing tests.**
  - `afterTwoCharactersOffersRelationsByPrefixThenSubstring`.
  - `afterAliasDotOffersThatRelationsColumns`: the input is `SELECT u. FROM public.users u`.
  - `afterSchemaDotOffersItsRelations`.
  - `nothingIsOfferedInsideStringsOrComments`.
  - `theListIsCappedAt50`.
  - On the view:
    - `downAndReturnAcceptAndReplaceThePrefix`;
    - `escapeClosesTheOverlayAndDoesNotCancel`;
    - `aKeystrokeWithTheOverlayOpenStillCostsOnlyTheEditorAndOverlay`.
- [ ] **Steps 2–4:** fail, implement, pass.
- [ ] **Step 5: commit** "SQL: schema completion".

### Task 6: CI bump, docs and the PR

- [ ] Bump `METALUI_REF` in `.github/workflows/ci.yml` to the MetalUI master commit you built against.
- [ ] Update `docs/superpowers/specs/2026-11-18-sift-design.md`:
  - mark phase 4 as built;
  - add any MetalUI gaps to the section 11 table, continuing from G14.
- [ ] Run the full `swift test --no-parallel` locally against a Postgres container that you create and **delete afterwards**.
- [ ] Push and open the PR "Phase 4: SQL editor".
- [ ] Get CI green on all three OSes. **Do not merge.**
