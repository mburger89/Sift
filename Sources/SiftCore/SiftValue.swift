/// A decoded database value.
public enum SiftValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case text(String)
    case bytes([UInt8])
    /// The server's text form of a type that is not decoded yet (jsonb, arrays, ...).
    case raw(String)
}

/// One column of a result.
public struct ResultColumn: Sendable, Equatable {
    public var name: String
    public var typeOID: UInt32
    public var typeName: String
    /// True for a user-defined enum type: its values arrive as text and draw as a label.
    public var isEnum: Bool

    public init(name: String, typeOID: UInt32, typeName: String, isEnum: Bool = false) {
        self.name = name
        self.typeOID = typeOID
        self.typeName = typeName
        self.isEnum = isEnum
    }
}

/// A page of rows with their columns.
public struct ResultPage: Sendable, Equatable {
    public var columns: [ResultColumn]
    public var rows: [[SiftValue]]

    public init(columns: [ResultColumn], rows: [[SiftValue]]) {
        self.columns = columns
        self.rows = rows
    }
}
