import MetalUI
import MetalUITesting
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

/// A small database to complete against: public.users, orders, user_roles, bonus, "Weird Name" and "order", and sales.invoices.
private func database(extra: [RelationInfo] = []) -> SchemaSnapshot {
    func column(_ name: String, _ n: Int, _ type: String) -> ColumnInfo { ColumnInfo(name: name, ordinal: n, typeName: type) }
    func table(_ schema: String, _ name: String, _ columns: [ColumnInfo]) -> RelationInfo {
        RelationInfo(id: RelationID(schema, name), kind: .table, columns: columns)
    }
    return SchemaSnapshot(
        serverVersion: 170_000, schemas: ["public", "sales"],
        relations: [
            table("public", "users", [column("id", 1, "integer"), column("name", 2, "text"), column("Email", 3, "text")]),
            table("public", "orders", [column("id", 1, "integer"), column("user_id", 2, "integer"), column("total", 3, "numeric")]),
            table("public", "user_roles", [column("user_id", 1, "integer"), column("role", 2, "text")]),
            table("public", "bonus", [column("amount", 1, "numeric")]),
            table("public", "Weird Name", [column("id", 1, "integer")]),
            table("public", "order", [column("id", 1, "integer")]),
            table("sales", "invoices", [column("id", 1, "integer"), column("user_id", 2, "integer")]),
        ] + extra,
        foreignKeys: [])
}

/// Completes `text` with the caret at the `|` in it.
private func complete(_ marked: String, _ snapshot: SchemaSnapshot = database()) -> CompletionResult? {
    let caret = marked.range(of: "|")!
    let text = marked.replacingCharacters(in: caret, with: "")
    return SQLCompletion.complete(text: text, caret: marked.utf8.distance(from: marked.utf8.startIndex, to: caret.lowerBound), snapshot: snapshot)
}

private func names(_ result: CompletionResult?) -> [String] { result?.items.map(\.name) ?? [] }

@Suite struct SQLCompletionTests {
    @Test func afterTwoCharactersOffersRelationsByPrefixThenSubstring() {
        // Prefix matches (in schema order: `user_roles` sorts before `users`), then names that only contain "us".
        #expect(names(complete("select * from us|")) == ["user_roles", "users", "bonus"])
        // One character is not enough; two are.
        #expect(complete("select * from u|") == nil)
        #expect(names(complete("select * from or|")) == ["order", "orders"])
        // The text typed is what accepting replaces.
        let result = complete("select * from us|")
        #expect(result?.replacing == 14..<16)
    }

    @Test func schemasAreOfferedToo() {
        let items = complete("select * from sa|")?.items ?? []
        #expect(items.map(\.name) == ["sales"] && items.first?.kind == .schema)
        // A relation shows its schema beside it.
        #expect(complete("select * from inv|")?.items.first?.detail == "sales")
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(names(complete("select * from USE|")) == ["user_roles", "users"])
        #expect(names(complete("select * from weird|")) == ["Weird Name"])
    }

    @Test func afterAliasDotOffersThatRelationsColumns() {
        #expect(names(complete("SELECT u.| FROM public.users u")) == ["id", "name", "Email"])
        #expect(complete("SELECT u.| FROM public.users u")?.items.map(\.detail) == ["integer", "text", "text"])
        // A start narrows them.
        #expect(names(complete("SELECT u.na| FROM public.users u")) == ["name"])
        #expect(names(complete("SELECT u.AM| FROM users u")) == ["name"], "a substring, any case")
        #expect(names(complete("SELECT u.em| FROM users u")) == ["Email"])
    }

    @Test func aliasesComeFromFromAndJoinClauses() {
        let join = "SELECT o.| FROM users u JOIN orders o ON o.user_id = u.id"
        #expect(names(complete(join)) == ["id", "user_id", "total"])
        #expect(names(complete("SELECT x.| FROM users AS u JOIN sales.invoices AS x ON true")) == ["id", "user_id"])
        #expect(names(complete("SELECT b.| FROM users u, orders o, bonus b")) == ["amount"])
        #expect(names(complete("SELECT u.| FROM users u LEFT JOIN orders o ON o.user_id = u.id WHERE u.id > 1")) == ["id", "name", "Email"])
        // The alias is read from the statement the caret is in, not from another one.
        #expect(complete("select 1 from users u; select u.| from orders") == nil)
        #expect(names(complete("select 1 from users u; select o.| from orders o")) == ["id", "user_id", "total"])
    }

    @Test func afterRelationDotOffersItsColumns() {
        #expect(names(complete("SELECT users.| FROM users")) == ["id", "name", "Email"])
        #expect(names(complete("SELECT orders.to| FROM orders")) == ["total"])
        // Before the clause is written, the relation of that name.
        #expect(names(complete("SELECT bonus.|")) == ["amount"])
    }

    @Test func moreThanTwoQualifierPartsUseTheLastTwo() {
        // `db.schema.table.` is `schema.table`.
        #expect(names(complete("SELECT x.public.orders.| FROM public.orders")) == ["id", "user_id", "total"])
        // Not resolved: nothing, and never the first part read as an alias (`o` here is public.users).
        #expect(names(complete("SELECT x.nope.orders.| FROM public.orders")).isEmpty)
        #expect(names(complete("SELECT o.nope.orders.| FROM public.users o")).isEmpty)
    }

    @Test func afterSchemaDotOffersItsRelations() {
        #expect(names(complete("select * from sales.|")) == ["invoices"])
        #expect(names(complete("select * from public.us|")) == ["user_roles", "users", "bonus"])
        #expect(names(complete("select * from sales.us|")) == [])
        // schema.relation. gives the columns.
        #expect(names(complete("select sales.invoices.| from sales.invoices")) == ["id", "user_id"])
    }

    @Test func nothingIsOfferedInsideStringsOrComments() {
        #expect(complete("select 'us|") == nil)
        #expect(complete("select 'us|er' from t") == nil)
        #expect(complete("select 1 -- us|") == nil)
        #expect(complete("select 1 /* us|") == nil)
        #expect(complete("select \"us|") == nil)
        #expect(complete("do $$ select us|") == nil)
        #expect(complete("select 'a.|b'") == nil)
        // Outside them it works again, on the same line.
        #expect(!names(complete("select 'abc' from us|")).isEmpty)
        #expect(!names(complete("select 1 /* x */ from us|")).isEmpty)
        #expect(!names(complete("-- note\nselect * from us|")).isEmpty)
    }

    @Test func aMatchOfNothingOffersNothing() {
        #expect(complete("select * from zz|") == nil)
        #expect(complete("select 1 + |") == nil)
        #expect(complete("select u.| from nowhere u") == nil)
    }

    @Test func theListIsCappedAt50() {
        let many = (0..<120).map { RelationInfo(id: RelationID("public", "tbl\(String(format: "%03d", $0))"), kind: .table) }
        let result = complete("select * from tb|", database(extra: many))
        #expect(result?.items.count == 50)
        #expect(result?.items.first?.name == "tbl000" && result?.items.last?.name == "tbl049")
        // Prefix matches fill the list before substring ones are looked at.
        #expect(complete("select * from bl|", database(extra: many))?.items.count == 50)
        #expect(complete("select * from bl|", database(extra: many))?.items.allSatisfy { $0.name.contains("bl") } == true)
    }

    @Test func namesAreQuotedOnlyWhenSQLWouldReadThemDifferently() {
        #expect(SQLCompletion.insertText("users") == "users")
        #expect(SQLCompletion.insertText("user_roles2") == "user_roles2")
        #expect(SQLCompletion.insertText("Email") == "\"Email\"")
        #expect(SQLCompletion.insertText("Weird Name") == "\"Weird Name\"")
        #expect(SQLCompletion.insertText("order") == "\"order\"", "a keyword")
        #expect(SQLCompletion.insertText("1abc") == "\"1abc\"")
        #expect(SQLCompletion.insertText("we\"ird") == "\"we\"\"ird\"")
        let items = complete("select * from wei|")?.items
        #expect(items?.first?.insertText == "\"Weird Name\"")
    }

    @Test func aQuotedAliasAndQuotedNamesResolve() {
        #expect(names(complete("SELECT \"U\".| FROM users \"U\"")) == ["id", "name", "Email"])
        #expect(names(complete("SELECT w.| FROM public.\"Weird Name\" w")) == ["id"])
    }
}

/// The overlay in the real window.
@MainActor
struct CompletionViewTests {
    let key = ConnectionKey.container(name: "shop-db")
    let view = QueryViewTests()

    func typed(_ window: TestWindow, _ text: String) async throws {
        window.typeText(text)
        try await window.runUntilIdle()
        for _ in 0..<5 { await Task.yield() }
        try await window.runUntilIdle()
    }

    @Test func downAndReturnAcceptAndReplaceThePrefix() async throws {
        let (_, window, editor, _) = try await view.openQuery()
        try window.click(window.element(identifier: "query.editor"))
        try await typed(window, "select * from shop.cu")
        // Not vacuous: the list is open, the editor has the text, and the first item is the best prefix match.
        #expect(editor.isCompletionOpen)
        let first = try window.element(identifier: "completion.item.0")
        #expect(first.value == "customer_totals")
        _ = try window.element(identifier: "completion.item.1")
        // ↓ moves, Return accepts: the prefix is replaced, no newline is typed, the list closes.
        window.typeKey(.downArrow)
        try await window.runUntilIdle()
        #expect(editor.completionSelected == 1)
        window.typeKey(.return)
        try await window.runUntilIdle()
        #expect(editor.buffer.snapshot().text == "select * from shop.customers")
        #expect(!editor.isCompletionOpen)
        #expect(!window.hasElement(identifier: "completion"))
        // The caret is after the name: the next typing continues from there.
        try await typed(window, " c")
        #expect(editor.buffer.snapshot().text == "select * from shop.customers c")
    }

    @Test func tabAcceptsToo() async throws {
        let (_, window, editor, _) = try await view.openQuery()
        try window.click(window.element(identifier: "query.editor"))
        try await typed(window, "select * from shop.cu")
        window.typeKey(.tab)
        try await window.runUntilIdle()
        #expect(editor.buffer.snapshot().text == "select * from shop.customer_totals")
        #expect(!editor.buffer.snapshot().text.contains("\t"))
    }

    @Test func aDotOpensTheListAtOnceWithTheColumns() async throws {
        let (_, window, editor, _) = try await view.openQuery()
        try window.click(window.element(identifier: "query.editor"))
        try await typed(window, "select c.")
        #expect(!editor.isCompletionOpen, "c is no alias yet")
        try await typed(window, " from shop.customers c")
        editor.buffer.select(9..<9)
        // The caret after `c.`: the aliased relation's columns.
        window.typeKey(.rightArrow)
        window.typeKey(.leftArrow)
        try await window.runUntilIdle()
        for _ in 0..<5 { await Task.yield() }
        try await window.runUntilIdle()
        #expect(editor.isCompletionOpen)
        #expect(editor.completionItems.map(\.name).first == "id")
        // Escape closes it.
        window.typeKey(.escape)
        try await window.runUntilIdle()
        #expect(!editor.isCompletionOpen)
    }

    @Test func escapeClosesTheOverlayAndDoesNotCancel() async throws {
        let (_, window, editor, runner) = try await view.openQuery()
        runner.holds = true
        try window.click(window.element(identifier: "query.editor"))
        try await typed(window, "select pg_sleep(30)")
        window.typeKey(.return, modifierFlags: .primary)
        try await window.runUntil { runner.isHolding }
        try await typed(window, " from shop.cu")
        #expect(editor.isRunning && editor.isCompletionOpen)
        // The first Escape is the list's: the query goes on.
        window.typeKey(.escape)
        try await window.runUntilIdle()
        #expect(!editor.isCompletionOpen)
        #expect(editor.isRunning)
        #expect(runner.cancelCalls == 0)
        // The next, with nothing open, cancels it.
        window.typeKey(.escape)
        try await window.runUntil { !editor.isRunning }
        #expect(runner.cancelCalls == 1)
        #expect(editor.summary == .cancelled)
    }

    @Test func escapeWhileRunningWithNoListCancelsAndOnlyThen() async throws {
        let (_, window, editor, runner) = try await view.openQuery(text: "select pg_sleep(30)")
        runner.holds = true
        try window.click(window.element(identifier: "query.editor"))
        window.typeKey(.return, modifierFlags: .primary)
        try await window.runUntil { runner.isHolding }
        #expect(!editor.isCompletionOpen)
        window.typeKey(.escape)
        try await window.runUntil { !editor.isRunning }
        #expect(runner.cancelCalls == 1)
    }

    @Test func clickingAnItemAcceptsIt() async throws {
        let (_, window, editor, _) = try await view.openQuery()
        try window.click(window.element(identifier: "query.editor"))
        try await typed(window, "select * from shop.cu")
        try window.click(window.element(identifier: "completion.item.1"))
        try await window.runUntilIdle()
        #expect(editor.buffer.snapshot().text == "select * from shop.customers")
        #expect(!editor.isCompletionOpen)
    }

    @Test func aStaleListIsNotAcceptedAfterTheCaretMoved() async throws {
        let (_, window, editor, _) = try await view.openQuery()
        try window.click(window.element(identifier: "query.editor"))
        try await typed(window, "select * from shop.cu")
        #expect(editor.isCompletionOpen)
        // The caret moves without a key the editor's handler saw: an accept must not paste at the old place.
        editor.buffer.select(0..<0)
        #expect(!editor.acceptCompletion())
        #expect(editor.buffer.snapshot().text == "select * from shop.cu")
    }

    @Test func aKeystrokeWithTheOverlayOpenStillCostsOnlyTheEditorAndOverlay() async throws {
        let (_, window, editor, _) = try await view.openQuery(
            text: "\n" + QueryCostTests.longBuffer(3_000), recordsLayout: false)
        editor.caretBlink = .off
        try window.click(window.element(identifier: "query.editor"))
        editor.buffer.select(0..<0)
        try await typed(window, "ord")
        // Not vacuous: the list is open over a long buffer, with items.
        #expect(editor.isCompletionOpen && Array(editor.completionItems.map(\.name).prefix(2)) == ["order_items", "orders"], "\(editor.completionItems.map(\.name))")
        // Warm.
        try await typed(window, "er")
        let before = QueryCostTests.Bodies()
        let list = CompletionList.bodyCount
        window.resetFrameWork()
        try await typed(window, "_")
        let after = QueryCostTests.Bodies()
        let work = window.frameWork.reduce(FrameWork(), +)
        #expect(editor.buffer.snapshot().line(0) == "order_")
        #expect(editor.isCompletionOpen && editor.completionItems.map(\.name) == ["order_items"], "\(editor.completionItems.map(\.name))")
        #expect(CompletionList.bodyCount > list, "the list did not follow the keystroke")
        #expect(after == before, "bodies \(before) -> \(after)")
        #expect(work.tableRowsRealized == 0 && window.frameWork.count > 0)
    }
}
