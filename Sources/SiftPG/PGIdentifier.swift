import Foundation
import SiftCore

/// Quotes names for SQL. Every relation name that reaches a statement goes through here.
public enum PGIdentifier {
    /// `"name"` with embedded quotes doubled.
    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// `"schema"."name"`.
    public static func qualified(_ id: RelationID) -> String {
        quote(id.schema) + "." + quote(id.name)
    }
}
