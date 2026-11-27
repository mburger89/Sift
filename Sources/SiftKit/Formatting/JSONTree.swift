/// A JSON value with its object keys in the order the server wrote them and its numbers spelled as written.
/// The inspector draws it as expandable objects and arrays.
public indirect enum JSONNode: Equatable, Sendable {
    case object([(key: String, value: JSONNode)])
    case array([JSONNode])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static func == (lhs: JSONNode, rhs: JSONNode) -> Bool {
        switch (lhs, rhs) {
        case (.object(let a), .object(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case (.array(let a), .array(let b)): return a == b
        case (.string(let a), .string(let b)), (.number(let a), .number(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }

    /// Parses `text`, or nil when it is not one complete JSON value.
    public static func parse(_ text: String) -> JSONNode? {
        var parser = Parser(Array(text.unicodeScalars))
        guard let node = parser.value(depth: 0) else { return nil }
        parser.skipSpace()
        return parser.index == parser.scalars.count ? node : nil
    }

    /// How a container is labelled when collapsed: `{3}` or `[2]`.
    public var summary: String {
        switch self {
        case .object(let members): return "{\(members.count)}"
        case .array(let items): return "[\(items.count)]"
        default: return text
        }
    }

    /// The text of a scalar, or the compact JSON of a container.
    public var text: String {
        switch self {
        case .string(let s): return "\"" + s + "\""
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .object(let members): return "{" + members.map { "\"\($0.key)\":\($0.value.text)" }.joined(separator: ",") + "}"
        case .array(let items): return "[" + items.map(\.text).joined(separator: ",") + "]"
        }
    }

    /// Indented by two spaces per level.
    public func pretty(indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        switch self {
        case .object(let members):
            if members.isEmpty { return "{}" }
            let body = members.map { "\(inner)\"\($0.key)\": \($0.value.pretty(indent: indent + 2))" }.joined(separator: ",\n")
            return "{\n" + body + "\n\(pad)}"
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { "\(inner)\($0.pretty(indent: indent + 2))" }.joined(separator: ",\n") + "\n\(pad)]"
        default:
            return text
        }
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0
        static let maxDepth = 200

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        mutating func skipSpace() {
            while index < scalars.count, [" ", "\n", "\r", "\t"].contains(scalars[index]) { index += 1 }
        }

        mutating func value(depth: Int) -> JSONNode? {
            guard depth < Self.maxDepth else { return nil }
            skipSpace()
            guard index < scalars.count else { return nil }
            switch scalars[index] {
            case "{": return object(depth: depth)
            case "[": return array(depth: depth)
            case "\"": return string().map(JSONNode.string)
            case "t": return literal("true", .bool(true))
            case "f": return literal("false", .bool(false))
            case "n": return literal("null", .null)
            default: return number()
            }
        }

        mutating func literal(_ word: String, _ node: JSONNode) -> JSONNode? {
            let w = Array(word.unicodeScalars)
            guard index + w.count <= scalars.count, Array(scalars[index..<index + w.count]) == w else { return nil }
            index += w.count
            return node
        }

        mutating func number() -> JSONNode? {
            let start = index
            while index < scalars.count, "+-0123456789.eE".unicodeScalars.contains(scalars[index]) { index += 1 }
            guard index > start else { return nil }
            var text = String.UnicodeScalarView()
            text.append(contentsOf: scalars[start..<index])
            return .number(String(text))
        }

        /// The string's text with its escapes kept as written, so it prints back as it came.
        mutating func string() -> String? {
            guard index < scalars.count, scalars[index] == "\"" else { return nil }
            index += 1
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let ch = scalars[index]
                index += 1
                if ch == "\"" { return String(out) }
                out.append(ch)
                if ch == "\\", index < scalars.count {
                    out.append(scalars[index])
                    index += 1
                }
            }
            return nil
        }

        mutating func array(depth: Int) -> JSONNode? {
            index += 1
            var items: [JSONNode] = []
            skipSpace()
            if index < scalars.count, scalars[index] == "]" {
                index += 1
                return .array([])
            }
            while true {
                guard let item = value(depth: depth + 1) else { return nil }
                items.append(item)
                skipSpace()
                guard index < scalars.count else { return nil }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "]" { index += 1; return .array(items) }
                return nil
            }
        }

        mutating func object(depth: Int) -> JSONNode? {
            index += 1
            var members: [(key: String, value: JSONNode)] = []
            skipSpace()
            if index < scalars.count, scalars[index] == "}" {
                index += 1
                return .object([])
            }
            while true {
                skipSpace()
                guard let key = string() else { return nil }
                skipSpace()
                guard index < scalars.count, scalars[index] == ":" else { return nil }
                index += 1
                guard let member = value(depth: depth + 1) else { return nil }
                members.append((key, member))
                skipSpace()
                guard index < scalars.count else { return nil }
                if scalars[index] == "," { index += 1; continue }
                if scalars[index] == "}" { index += 1; return .object(members) }
                return nil
            }
        }
    }
}
