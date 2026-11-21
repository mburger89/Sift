import SiftCore
import Testing

@testable import SiftPG

@Suite struct PGRelationQueryTests {
    static func col(_ name: String, _ type: String = "text", null: Bool = false) -> ColumnInfo {
        ColumnInfo(name: name, ordinal: 1, typeName: type, isNullable: null)
    }

    /// A table `s.t(id bigint pk, name text null, created timestamptz, "we\"ird" text)`.
    static func relation(
        pk: [String]? = ["id"], indexes: [IndexInfo] = [], unique: [KeyConstraint] = [],
        kind: RelationKind = .table
    ) -> RelationInfo {
        RelationInfo(
            id: RelationID("s", "t"), kind: kind,
            columns: [
                col("id", "bigint"), col("name", "text", null: true), col("created", "timestamptz"),
                col("we\"ird", "text", null: true), col("b", "text"),
            ],
            primaryKey: pk.map { KeyConstraint(name: "t_pkey", columns: $0) }, uniqueConstraints: unique, indexes: indexes)
    }

    static func query(_ relation: RelationInfo = relation()) -> PGRelationQuery {
        let key = PGRelationQuery.orderKey(for: relation)
        return PGRelationQuery(relation: relation, orderKey: key.columns, keyKind: key.kind)
    }

    @Test func orderKeyPrefersThePrimaryKeyThenAUniqueNotNullIndexThenCtid() {
        let pk = PGRelationQuery.orderKey(for: Self.relation())
        #expect(pk.columns == [0] && pk.kind == .primaryKey)

        let unique = IndexInfo(name: "u", columns: ["created"], isUnique: true, isPrimary: false, method: "btree", definition: "")
        let viaIndex = PGRelationQuery.orderKey(for: Self.relation(pk: nil, indexes: [unique]))
        #expect(viaIndex.columns == [2] && viaIndex.kind == .uniqueNotNull)

        // A unique index over a nullable column is no key, and neither is a partial one.
        let nullable = IndexInfo(name: "n", columns: ["name"], isUnique: true, isPrimary: false, method: "btree", definition: "")
        let partial = IndexInfo(name: "p", columns: ["id"], isUnique: true, isPrimary: false, method: "btree", predicate: "id > 1", definition: "")
        let none = PGRelationQuery.orderKey(for: Self.relation(pk: nil, indexes: [nullable, partial]))
        #expect(none.columns.isEmpty && none.kind == .ctid)

        let view = PGRelationQuery.orderKey(for: Self.relation(pk: nil, kind: .view))
        #expect(view.kind == .unordered)
    }

    @Test func aFirstPageUsesNoOffsetAndOrdersByTheKey() {
        let (sql, params) = Self.query().pageSQL(index: 0, size: 500, query: GridQuery(), after: nil)
        #expect(sql.contains("ORDER BY \"id\" LIMIT 500"))
        #expect(!sql.contains("OFFSET"))
        #expect(params.isEmpty)
        #expect(sql.hasPrefix("SELECT \"id\", \"name\", \"created\", \"we\"\"ird\", \"b\" FROM \"s\".\"t\""))
    }

    @Test func aPageAfterALoadedPageUsesKeyset() {
        let relation = Self.relation(pk: ["id", "b"])
        let after: [SiftValue] = [.int(7), .null, .text("t"), .null, .text("x")]
        let (sql, params) = Self.query(relation).pageSQL(index: 3, size: 500, query: GridQuery(), after: after)
        #expect(sql.contains("WHERE (\"id\",\"b\") > ($1,$2)"), "\(sql)")
        #expect(params == ["7", "x"])
        #expect(!sql.contains("OFFSET"))
        #expect(sql.contains("ORDER BY \"id\", \"b\" LIMIT 500"))
    }

    @Test func aJumpUsesOffset() {
        let (sql, _) = Self.query().pageSQL(index: 40, size: 500, query: GridQuery(), after: nil)
        #expect(sql.hasSuffix("LIMIT 500 OFFSET 20000"), "\(sql)")
    }

    @Test func aUserSortAppendsTheKeyAsATieBreaker() {
        let descending = GridQuery(sort: GridSort(column: 1, ascending: false))
        let (sql, _) = Self.query().pageSQL(index: 0, size: 500, query: descending, after: nil)
        #expect(sql.contains("ORDER BY \"name\" DESC NULLS FIRST, \"id\" DESC LIMIT 500"), "\(sql)")
        let ascending = GridQuery(sort: GridSort(column: 2, ascending: true))
        let (up, _) = Self.query().pageSQL(index: 0, size: 500, query: ascending, after: nil)
        #expect(up.contains("ORDER BY \"created\" ASC NULLS LAST, \"id\" LIMIT 500"), "\(up)")
    }

    @Test func aSortedKeysetUsesTheSameTupleAndDirection() {
        let query = GridQuery(sort: GridSort(column: 2, ascending: false))
        let after: [SiftValue] = [.int(5), .null, .text("2026-01-01"), .null, .text("x")]
        let (sql, params) = Self.query().pageSQL(index: 2, size: 500, query: query, after: after)
        #expect(sql.contains("WHERE (\"created\",\"id\") < ($1,$2)"), "\(sql)")
        #expect(params == ["2026-01-01", "5"])
    }

    @Test func aNullableSortColumnNeverUsesKeyset() {
        let query = GridQuery(sort: GridSort(column: 1, ascending: true))
        let after: [SiftValue] = [.int(5), .text("n"), .text("t"), .null, .text("x")]
        let (sql, params) = Self.query().pageSQL(index: 2, size: 500, query: query, after: after)
        #expect(!sql.contains(" > ") && !sql.contains(" < "), "\(sql)")
        #expect(sql.hasSuffix("LIMIT 500 OFFSET 1000"), "\(sql)")
        #expect(params.isEmpty)
    }

    @Test func ctidPagesByTheHiddenColumn() {
        let relation = Self.relation(pk: nil)
        let q = Self.query(relation)
        #expect(q.keyKind == .ctid && q.selectedColumnCount == 6)
        let after: [SiftValue] = [.int(1), .null, .text("t"), .null, .text("x"), .text("(3,7)")]
        let (sql, params) = q.pageSQL(index: 1, size: 500, query: GridQuery(), after: after)
        #expect(sql.contains("ctid::text AS \"_sift_ctid\" FROM"))
        #expect(sql.contains("WHERE ctid > $1::tid ORDER BY ctid LIMIT 500"), "\(sql)")
        #expect(params == ["(3,7)"])
    }

    @Test func aViewHasNoOrderByAndOnlyOffset() {
        let q = Self.query(Self.relation(pk: nil, kind: .view))
        let (sql, _) = q.pageSQL(index: 2, size: 500, query: GridQuery(), after: [.int(1)])
        #expect(!sql.contains("ORDER BY") && sql.hasSuffix("LIMIT 500 OFFSET 1000"), "\(sql)")
    }

    @Test(arguments: ["'; drop table x; --", "$1", "50%_\\", "it's"])
    func filterValuesAreAlwaysBound(_ value: String) {
        for op in [FilterOp.eq, .ne, .lt, .le, .gt, .ge, .contains, .startsWith] {
            let query = GridQuery(filters: [GridFilter(column: 0, op: op, value: value)])
            for built in [Self.query().pageSQL(index: 0, size: 500, query: query, after: nil),
                          Self.query().countSQL(query: query)] {
                #expect(!built.sql.contains(value) || value == "$1", "\(op): \(built.sql)")
                #expect(!built.sql.contains("drop table") && !built.sql.contains("it's"), "\(built.sql)")
                #expect(built.params.count == 1)
                #expect(built.params[0]?.contains(value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")) == true
                    || built.params[0] == value, "\(op): \(String(describing: built.params))")
            }
        }
    }

    @Test func containsEscapesLikeCharactersAndStartsWithAnchors() {
        let contains = GridQuery(filters: [GridFilter(column: 1, op: .contains, value: "50%_\\")])
        let (sql, params) = Self.query().countSQL(query: contains)
        #expect(sql == "SELECT count(*) FROM \"s\".\"t\" WHERE \"name\"::text ILIKE $1 ESCAPE '\\'", "\(sql)")
        #expect(params == ["%50\\%\\_\\\\%"])
        let starts = GridQuery(filters: [GridFilter(column: 1, op: .startsWith, value: "a_b")])
        #expect(Self.query().countSQL(query: starts).params == ["a\\_b%"])
    }

    @Test func nullChecksTakeNoParameter() {
        let query = GridQuery(filters: [GridFilter(column: 1, op: .isNull), GridFilter(column: 3, op: .isNotNull)])
        let (sql, params) = Self.query().countSQL(query: query)
        #expect(sql.hasSuffix("WHERE \"name\" IS NULL AND \"we\"\"ird\" IS NOT NULL"), "\(sql)")
        #expect(params.isEmpty)
    }

    @Test func castsUseTheColumnsType() {
        let query = GridQuery(filters: [GridFilter(column: 2, op: .ge, value: "2026-01-01")])
        let (sql, params) = Self.query().countSQL(query: query)
        #expect(sql.hasSuffix("WHERE \"created\" >= $1::timestamptz"), "\(sql)")
        #expect(params == ["2026-01-01"])
        #expect(PGRelationQuery.safeTypeName("numeric(12,2)") == "numeric(12,2)")
        #expect(PGRelationQuery.safeTypeName("character varying(200)") != nil)
        #expect(PGRelationQuery.safeTypeName("text; drop table x") == nil)
        #expect(PGRelationQuery.safeTypeName("a'b") == nil)
        #expect(PGRelationQuery.safeTypeName("a--b") == nil)
    }

    @Test func searchORsEveryColumnCastToText() {
        let (sql, params) = Self.query().countSQL(query: GridQuery(search: "a%b"))
        #expect(sql.contains("(\"id\"::text ILIKE $1 ESCAPE '\\' OR \"name\"::text ILIKE $1 ESCAPE '\\' OR"), "\(sql)")
        #expect(sql.contains("OR \"we\"\"ird\"::text ILIKE $1"))
        #expect(params == ["%a\\%b%"])
    }

    @Test func filtersAndSearchNumberParametersInOrderBeforeTheKeyset() {
        let relation = Self.relation()
        let query = GridQuery(
            filters: [GridFilter(column: 1, op: .eq, value: "n"), GridFilter(column: 2, op: .lt, value: "2026-02-01")],
            search: "q")
        let after: [SiftValue] = [.int(9), .null, .null, .null, .null]
        let (sql, params) = Self.query(relation).pageSQL(index: 1, size: 500, query: query, after: after)
        #expect(params == ["n", "2026-02-01", "%q%", "9"], "\(params)")
        #expect(sql.contains("\"name\" = $1::text AND \"created\" < $2::timestamptz AND (\"id\"::text ILIKE $3"), "\(sql)")
        #expect(sql.contains("AND \"id\" > $4"), "\(sql)")
    }

    @Test func identifiersAreQuoted() {
        let query = GridQuery(sort: GridSort(column: 3, ascending: true), filters: [GridFilter(column: 3, op: .eq, value: "v")])
        let (sql, _) = Self.query().pageSQL(index: 0, size: 500, query: query, after: nil)
        #expect(sql.contains("\"we\"\"ird\" = $1"), "\(sql)")
        #expect(sql.contains("ORDER BY \"we\"\"ird\" ASC NULLS LAST"), "\(sql)")
    }

    @Test func aFilterOnAMissingColumnOrWithNoValueIsDropped() {
        let query = GridQuery(filters: [GridFilter(column: 99, op: .eq, value: "x"), GridFilter(column: 0, op: .eq, value: nil)])
        let (sql, params) = Self.query().countSQL(query: query)
        #expect(!sql.contains("WHERE") && params.isEmpty)
    }
}
