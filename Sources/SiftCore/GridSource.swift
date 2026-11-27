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
    /// Where NULLs go. Defaults to `ascending` (`NULLS LAST` ascending, `NULLS FIRST` descending), which is
    /// what Postgres does; newest-first sets it to true while descending, so a row with no timestamp is not "newest".
    public var nullsLast: Bool

    public init(column: Int, ascending: Bool = true, nullsLast: Bool? = nil) {
        self.column = column
        self.ascending = ascending
        self.nullsLast = nullsLast ?? ascending
    }
}

/// Highlight (and optionally keep only) the rows written since a marker: the decimal text of a 32-bit xid,
/// taken from `GridSource.changeMarker()`. Always bound as a parameter, never spliced into SQL.
public struct ChangeFilter: Sendable, Equatable {
    public var since: String
    public var only: Bool

    public init(since: String, only: Bool = false) {
        self.since = since
        self.only = only
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
    /// With it set, each row has one extra trailing `.bool(changed)` value, after `ctid`.
    /// A source whose `supportsChanges` is false ignores it, so callers gate on `supportsChanges`.
    public var changes: ChangeFilter?

    public init(sort: GridSort? = nil, filters: [GridFilter] = [], search: String? = nil, changes: ChangeFilter? = nil) {
        self.sort = sort
        self.filters = filters
        self.search = search
        self.changes = changes
    }

    /// True when rows are narrowed (filters, a search or only-changes), so the catalog's estimate no longer applies.
    /// Only-changes counts even for a source that ignores `changes` (`supportsChanges` false): callers gate on that.
    public var narrows: Bool { !filters.isEmpty || !(search ?? "").isEmpty || changes?.only == true }
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
    /// Whether rows can be flagged as changed since a marker (`changes` on a query, `changeMarker()`).
    var supportsChanges: Bool { get }
    /// The columns (indexes into `columns`) that identify a row across refreshes. Empty for none or `ctid`.
    var keyColumns: [Int] { get }
    /// The marker to pass as `ChangeFilter.since` later. Taken before the pages it is compared against.
    func changeMarker() async throws -> String
    /// Releases the connection the source holds, if any.
    func close()
    /// The relation as the latest schema read has it, handed to a source whose grid was kept across that read (the
    /// structure is the same; its row estimate may have moved). A source with no use for it ignores it.
    func relationRefreshed(_ relation: RelationInfo)
}

extension GridSource {
    public var orderNote: String? { nil }
    public func close() {}
    public func relationRefreshed(_ relation: RelationInfo) {}
    public var supportsChanges: Bool { false }
    public var keyColumns: [Int] { [] }
    public func changeMarker() async throws -> String {
        throw SourceError(.other, "changes are not supported")
    }
}

extension ResultColumn {
    /// Whether the column's type has a btree ordering. `json`, `xml` and the geometric types have none:
    /// such a column gets no sort comparator, so its header click does nothing.
    public var isSortable: Bool {
        let base = typeName.hasSuffix("[]") ? String(typeName.dropLast(2)) : typeName
        return !Self.unorderedTypes.contains(base.lowercased())
    }

    static let unorderedTypes: Set<String> = [
        "json", "xml", "point", "lseg", "path", "box", "polygon", "line", "circle"
    ]
}
