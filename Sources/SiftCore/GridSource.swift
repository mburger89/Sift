/// How many rows a grid pages by (decision: 500 rows per page).
public enum GridPaging {
    public static let pageSize = 500
    /// The page cache keeps at most this many pages (20 000 rows).
    public static let cachedPages = 40
}

/// A column to sort by, as an index into the source's `columns`.
public struct GridSort: Sendable, Equatable {
    public var column: Int
    public var ascending: Bool

    public init(column: Int, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

/// A filter operator. A closed set: nothing a user types ever becomes an operator in SQL.
public enum FilterOp: String, Sendable, CaseIterable {
    case eq, ne, lt, le, gt, ge, contains, startsWith, isNull, isNotNull

    /// The symbol or words the chip shows.
    public var title: String {
        switch self {
        case .eq: return "="
        case .ne: return "\u{2260}"
        case .lt: return "<"
        case .le: return "\u{2264}"
        case .gt: return ">"
        case .ge: return "\u{2265}"
        case .contains: return "contains"
        case .startsWith: return "starts with"
        case .isNull: return "is null"
        case .isNotNull: return "is not null"
        }
    }

    /// Whether the operator compares against a value (`is null` and `is not null` do not).
    public var takesValue: Bool { self != .isNull && self != .isNotNull }
}

/// One chip: a column, an operator and, for most operators, a value (always bound, never spliced into SQL).
public struct GridFilter: Sendable, Equatable {
    public var column: Int
    public var op: FilterOp
    public var value: String?

    public init(column: Int, op: FilterOp, value: String? = nil) {
        self.column = column
        self.op = op
        self.value = value
    }
}

/// What a grid shows: an order, filters (ANDed) and a text search over every column.
public struct GridQuery: Sendable, Equatable {
    public var sort: GridSort?
    public var filters: [GridFilter]
    public var search: String?

    public init(sort: GridSort? = nil, filters: [GridFilter] = [], search: String? = nil) {
        self.sort = sort
        self.filters = filters
        self.search = search
    }

    /// True when rows are narrowed (filters or a search), so the catalog's estimate no longer applies.
    public var narrows: Bool { !filters.isEmpty || !(search ?? "").isEmpty }
}

/// A row count, exact or an estimate that grows or shrinks as pages come back.
public enum RowCount: Sendable, Equatable {
    case exact(Int)
    case estimated(Int)

    public var value: Int {
        switch self {
        case .exact(let n), .estimated(let n): return n
        }
    }

    public var isExact: Bool {
        if case .exact = self { return true }
        return false
    }
}

/// A source of rows a grid pages through. UI-free: Postgres implements it now, SQL results and SQLite later.
public protocol GridSource: AnyObject, Sendable {
    var columns: [ResultColumn] { get }
    /// A note about the row order the source could not make stable, or nil.
    var orderNote: String? { get }
    func count(for query: GridQuery) async throws -> RowCount
    /// The exact count, with no short timeout. `cancelCurrent()` stops it.
    func exactCount(for query: GridQuery) async throws -> Int
    /// `after`: the last row of page index-1 when it is loaded (keyset), else nil (offset).
    func page(_ index: Int, size: Int, query: GridQuery, after: [SiftValue]?) async throws -> [[SiftValue]]
    func cancelCurrent()
    /// Releases the connection the source holds, if any.
    func close()
}

extension GridSource {
    public var orderNote: String? { nil }
    public func close() {}
}

extension ResultColumn {
    /// Whether the column's type has a btree ordering. `json`, `xml` and the geometric types have none:
    /// such a column gets no sort comparator, so its header click does nothing.
    public var isSortable: Bool {
        let base = typeName.hasSuffix("[]") ? String(typeName.dropLast(2)) : typeName
        return !Self.unorderedTypes.contains(base.lowercased())
    }

    static let unorderedTypes: Set<String> = [
        "json", "xml", "point", "lseg", "path", "box", "polygon", "line", "circle",
    ]
}
