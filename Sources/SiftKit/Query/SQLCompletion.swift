import SiftCore
import SiftPG

/// One thing the completion list offers.
struct CompletionItem: Equatable {
    enum Kind: Equatable { case schema, relation, column }

    var kind: Kind
    /// The name as the schema has it.
    var name: String
    /// What goes into the buffer: the name, quoted only when SQL would read it as something else.
    var insertText: String
    /// A quiet second column: the schema of a relation, the type of a column.
    var detail: String
}

/// What completion answers for a caret: the items, and the bytes of the text typed so far, which accepting one replaces.
struct CompletionResult: Equatable {
    var items: [CompletionItem]
    var replacing: Range<Int>
}

/// Schema-aware completion, pure: the text, the caret and the session's `SchemaSnapshot`; no query, no parser.
///
/// - It starts after two identifier characters, or immediately after a `.`.
/// - It offers schema names and relation names; after `alias.` or `relation.` that relation's columns; after `schema.`
///   that schema's relations; after `schema.relation.` its columns.
/// - Aliases and relations are found by a light scan of the statement's `FROM` and `JOIN` clauses with the tokenizer.
/// - Matching is case-insensitive prefix first, then substring; at most 50 items.
/// - Nothing is offered inside a string, a comment, a dollar quote or a quoted identifier.
enum SQLCompletion {
    static let limit = 50
    /// An identifier needs this many characters before completion starts (a `.` starts it at once).
    static let minimumPrefix = 2

    /// - Parameters:
    ///   - text: the text to read, usually the statement around the caret and a bit more.
    ///   - caret: the caret's UTF-8 offset in `text`.
    static func complete(text: String, caret: Int, snapshot: SchemaSnapshot) -> CompletionResult? {
        let tokens = lex(text)
        // Inside a string, a comment, a dollar quote or a quoted identifier: nothing. A token that ends exactly at the caret
        // still holds it unless it was closed (a line comment never is).
        if let inside = tokens.first(where: { $0.range.lowerBound < caret && caret <= $0.range.upperBound }) {
            switch inside.kind {
            case .string, .comment, .quotedIdentifier:
                if caret < inside.range.upperBound || !closes(inside, in: text) { return nil }
            default: break
            }
        }
        let bytes = Array(text.utf8)
        // The identifier being typed: a word token that ends at the caret.
        var prefixRange = caret..<caret
        var before = tokens.filter { $0.range.upperBound <= caret && $0.kind != .whitespace }
        if let last = before.last, last.range.upperBound == caret, last.kind == .identifier || last.kind == .keyword {
            prefixRange = last.range
            before.removeLast()
        }
        let prefix = String(decoding: bytes[prefixRange], as: UTF8.self)
        // A qualifier: `a .` or `a . b .` right before the prefix.
        var qualifier: [String] = []
        if let dot = before.last, dot.kind == .punctuation, bytes[dot.range.lowerBound] == 0x2E {
            var rest = before.dropLast()
            while let name = rest.last, name.kind == .identifier || name.kind == .quotedIdentifier || name.kind == .keyword {
                qualifier.insert(String(decoding: bytes[name.range], as: UTF8.self), at: 0)
                rest = rest.dropLast()
                guard let again = rest.last, again.kind == .punctuation, bytes[again.range.lowerBound] == 0x2E else { break }
                rest = rest.dropLast()
            }
            if qualifier.isEmpty { return nil }
        } else if prefix.count < minimumPrefix {
            return nil
        }
        let items: [CompletionItem]
        if qualifier.isEmpty {
            items = names(snapshot: snapshot)
        } else {
            let scan = scanFrom(text: text, caret: caret, snapshot: snapshot)
            items = members(of: qualifier, scan: scan, snapshot: snapshot)
        }
        let matched = match(items, prefix: prefix)
        return matched.isEmpty ? nil : CompletionResult(items: matched, replacing: prefixRange)
    }

    // MARK: Matching

    /// Prefix matches first, then substring matches, each in the schema's own order, capped.
    static func match(_ items: [CompletionItem], prefix: String) -> [CompletionItem] {
        guard !prefix.isEmpty else { return Array(items.prefix(limit)) }
        let needle = prefix.lowercased()
        var starts: [CompletionItem] = [], contains: [CompletionItem] = []
        var seen = Set<String>()
        for item in items {
            let key = "\(item.kind):\(item.name):\(item.detail)"
            guard seen.insert(key).inserted else { continue }
            let name = item.name.lowercased()
            if name.hasPrefix(needle) { starts.append(item) } else if name.contains(needle) { contains.append(item) }
        }
        return Array((starts + contains).prefix(limit))
    }

    // MARK: Names

    /// Every schema and relation, relations first by schema then name.
    static func names(snapshot: SchemaSnapshot) -> [CompletionItem] {
        var items: [CompletionItem] = []
        for relation in snapshot.relations {
            items.append(CompletionItem(kind: .relation, name: relation.id.name, insertText: insertText(relation.id.name), detail: relation.id.schema))
        }
        for schema in snapshot.schemas {
            items.append(CompletionItem(kind: .schema, name: schema, insertText: insertText(schema), detail: "schema"))
        }
        return items
    }

    static func columns(of relation: RelationInfo) -> [CompletionItem] {
        relation.columns.map { CompletionItem(kind: .column, name: $0.name, insertText: insertText($0.name), detail: $0.typeName) }
    }

    /// What follows `qualifier.`: an alias or a relation of the statement gives its columns; a schema gives its
    /// relations; `schema.relation` gives the columns.
    static func members(of qualifier: [String], scan: FromScan, snapshot: SchemaSnapshot) -> [CompletionItem] {
        if qualifier.count == 2 {
            let id = RelationID(unquote(qualifier[0]), unquote(qualifier[1]))
            if let relation = snapshot.relation(id) { return columns(of: relation) }
            return []
        }
        let name = qualifier[0]
        let key = fold(name)
        if let id = scan.aliases[key] ?? scan.relations[key], let relation = snapshot.relation(id) { return columns(of: relation) }
        let schema = unquote(name)
        if snapshot.schemas.contains(schema) {
            return snapshot.relations.filter { $0.id.schema == schema }.map {
                CompletionItem(kind: .relation, name: $0.id.name, insertText: insertText($0.id.name), detail: $0.id.schema)
            }
        }
        // A relation named in no FROM yet (`users.` before the clause is written): the one the schema has.
        let candidates = snapshot.relations.filter { $0.id.name == schema || $0.id.name.lowercased() == key }
        if let relation = preferred(candidates) { return columns(of: relation) }
        return []
    }

    private static func preferred(_ relations: [RelationInfo]) -> RelationInfo? {
        relations.first { $0.id.schema == "public" } ?? relations.first
    }

    // MARK: The FROM scan

    /// What a light read of a statement's `FROM` and `JOIN` clauses finds: alias to relation, and relation name to relation.
    struct FromScan: Equatable {
        var aliases: [String: RelationID] = [:]
        var relations: [String: RelationID] = [:]
    }

    /// Reads the statement around the caret, with the tokenizer, for `FROM a`, `FROM a x`, `FROM a AS x`, `JOIN s.a x`,
    /// and comma lists after `FROM`. No parser: a subquery is skipped.
    static func scanFrom(text: String, caret: Int, snapshot: SchemaSnapshot) -> FromScan {
        let utf8 = text.utf8
        let at = utf8.index(utf8.startIndex, offsetBy: min(caret, utf8.count))
        let statement = SQLStatements.statement(at: at, in: text) ?? text.startIndex..<text.endIndex
        let source = String(text[statement])
        let bytes = Array(source.utf8)
        let tokens = lex(source).filter { $0.kind != .whitespace && $0.kind != .comment }
        var scan = FromScan()
        func word(_ t: SQLToken) -> String { String(decoding: bytes[t.range], as: UTF8.self) }
        func isDot(_ t: SQLToken) -> Bool { t.kind == .punctuation && bytes[t.range.lowerBound] == 0x2E }
        func isComma(_ t: SQLToken) -> Bool { t.kind == .punctuation && bytes[t.range.lowerBound] == 0x2C }
        func isName(_ t: SQLToken) -> Bool { t.kind == .identifier || t.kind == .quotedIdentifier }
        // Words that end a FROM list; the next relation comes only after a JOIN or the comma of a list.
        let clauseWords: Set<String> = [
            "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION", "INTERSECT", "EXCEPT", "WINDOW", "FETCH", "FOR",
            "ON", "USING", "RETURNING", "SET", "SELECT", "VALUES",
        ]
        var i = 0
        var inFromList = false
        while i < tokens.count {
            let t = tokens[i]
            let upper = t.kind == .keyword ? word(t).uppercased() : ""
            if upper == "FROM" || upper == "JOIN" || upper == "UPDATE" || upper == "INTO" {
                inFromList = upper == "FROM"
                i += 1
                i = readReference(tokens, i, bytes, snapshot, &scan, isName: isName, isDot: isDot, word: word)
                // A comma list continues the FROM.
                while inFromList, i < tokens.count, isComma(tokens[i]) {
                    i = readReference(tokens, i + 1, bytes, snapshot, &scan, isName: isName, isDot: isDot, word: word)
                }
                continue
            }
            if clauseWords.contains(upper) { inFromList = false }
            i += 1
        }
        return scan
    }

    /// Reads `name`, `schema.name`, then an optional `AS alias` or `alias`, starting at `index`; records them and returns
    /// where it stopped.
    private static func readReference(
        _ tokens: [SQLToken], _ start: Int, _ bytes: [UInt8], _ snapshot: SchemaSnapshot, _ scan: inout FromScan,
        isName: (SQLToken) -> Bool, isDot: (SQLToken) -> Bool, word: (SQLToken) -> String
    ) -> Int {
        var i = start
        guard i < tokens.count, isName(tokens[i]) else { return i }
        var parts = [word(tokens[i])]
        i += 1
        if i + 1 < tokens.count, isDot(tokens[i]), isName(tokens[i + 1]) {
            parts.append(word(tokens[i + 1]))
            i += 2
        }
        let relation: RelationInfo?
        if parts.count == 2 {
            relation = snapshot.relation(RelationID(unquote(parts[0]), unquote(parts[1])))
        } else {
            let name = unquote(parts[0])
            let folded = fold(parts[0])
            relation = preferred(snapshot.relations.filter { $0.id.name == name || $0.id.name == folded })
        }
        var alias: String?
        if i < tokens.count, tokens[i].kind == .keyword, word(tokens[i]).uppercased() == "AS" {
            i += 1
            if i < tokens.count, isName(tokens[i]) { alias = word(tokens[i]); i += 1 }
        } else if i < tokens.count, isName(tokens[i]) {
            alias = word(tokens[i])
            i += 1
        }
        if let relation {
            scan.relations[fold(parts.last ?? "")] = relation.id
            if let alias { scan.aliases[fold(alias)] = relation.id }
        }
        return i
    }

    // MARK: Helpers

    private static func lex(_ text: String) -> [SQLToken] {
        let bytes = Array(text.utf8)
        var tokens: [SQLToken] = []
        var state = SQLLexState.normal
        var lineStart = 0
        bytes.withUnsafeBufferPointer { all in
            while lineStart <= all.count {
                var lineEnd = lineStart
                while lineEnd < all.count, all[lineEnd] != 0x0A { lineEnd += 1 }
                let (found, end) = SQLLineLexer.lex(
                    bytes: UnsafeBufferPointer(rebasing: all[lineStart..<lineEnd]), from: state)
                state = end
                for t in found { tokens.append(SQLToken(t.kind, (lineStart + t.range.lowerBound)..<(lineStart + t.range.upperBound))) }
                lineStart = lineEnd + 1
            }
        }
        return tokens
    }

    /// Whether a string, comment or quoted identifier token ends where it should (not at the text's end unfinished).
    private static func closes(_ token: SQLToken, in text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard token.range.upperBound <= bytes.count, token.range.count >= 2 else { return false }
        let last = bytes[token.range.upperBound - 1]
        switch token.kind {
        case .comment: return bytes[token.range.lowerBound + 1] == 0x2A && token.range.count >= 4 && last == 0x2F && bytes[token.range.upperBound - 2] == 0x2A
        case .string: return (last == 0x27 || last == 0x24) && token.range.count >= 2
        case .quotedIdentifier: return last == 0x22
        default: return true
        }
    }

    /// An unquoted name folds to lower case, as the server reads it; a quoted one is exact.
    static func fold(_ name: String) -> String { name.hasPrefix("\"") ? unquote(name) : name.lowercased() }

    static func unquote(_ name: String) -> String {
        guard name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 else { return name }
        return String(name.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
    }

    /// The name as it goes into the buffer: bare when the server would read it back as the same name, quoted (through
    /// `PGIdentifier.quote`) when it has capitals, spaces or other characters, or is a keyword.
    static func insertText(_ name: String) -> String {
        let bare = !name.isEmpty && name.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x24 }
            && !(name.utf8.first.map { $0 >= 0x30 && $0 <= 0x39 || $0 == 0x24 } ?? true)
        return bare && !SQLKeywords.contains(name) ? name : PGIdentifier.quote(name)
    }
}
