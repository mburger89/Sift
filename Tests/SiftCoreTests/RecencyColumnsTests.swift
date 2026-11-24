import SiftCore
import Testing

@Suite struct RecencyColumnsTests {
    static func col(
        _ name: String, _ type: String, def: String? = nil, identity: IdentityKind? = nil
    ) -> ColumnInfo {
        ColumnInfo(name: name, ordinal: 1, typeName: type, isNullable: true, defaultExpression: def, identity: identity)
    }

    static func relation(
        _ columns: [ColumnInfo], pk: [String]? = nil, indexes: [IndexInfo] = [],
        estimate: RowEstimate = .unknown
    ) -> RelationInfo {
        RelationInfo(
            id: RelationID("s", "t"), kind: .table, rowEstimate: estimate, columns: columns,
            primaryKey: pk.map { KeyConstraint(name: "t_pkey", columns: $0) }, indexes: indexes)
    }

    @Test func createdAtBeatsUpdatedAtBeatsADefaultNowColumnBeatsASerialKey() {
        let relation = Self.relation(
            [
                Self.col("id", "integer", def: "nextval('t_id_seq'::regclass)"),
                Self.col("seen", "timestamp with time zone", def: "now()"),
                Self.col("updated_at", "timestamp with time zone"),
                Self.col("created_at", "timestamp with time zone"),
            ], pk: ["id"])
        #expect(RecencyColumns.candidates(for: relation) == [3, 2, 1, 0])
    }

    @Test func namesMatchCaseInsensitivelyAndOnlyOnTimestampLikeTypes() {
        let relation = Self.relation([
            Self.col("Created_At", "text"),
            Self.col("Inserted_At", "timestamp without time zone"),
            Self.col("LAST_MODIFIED", "date"),
            Self.col("created", "timestamptz"),
        ])
        #expect(RecencyColumns.candidates(for: relation) == [1, 3, 2])
    }

    @Test func anIdentityOrNextvalIntegerIsACandidatePrimaryKeyFirst() {
        let relation = Self.relation(
            [
                Self.col("a", "bigint", identity: .byDefault),
                Self.col("b", "integer", def: "nextval('x'::regclass)"),
                Self.col("c", "smallint"),
                Self.col("d", "text", def: "nextval('y'::regclass)"),
            ], pk: ["b"])
        #expect(RecencyColumns.candidates(for: relation) == [1, 0])
    }

    @Test func noCandidatesMeansNoDefault() {
        let relation = Self.relation([Self.col("name", "text"), Self.col("n", "integer")])
        #expect(RecencyColumns.candidates(for: relation).isEmpty)
        #expect(RecencyColumns.defaultSort(for: relation) == nil)
    }

    @Test func theDefaultIsOnOnlyWhenIndexedOrSmall() {
        let columns = [Self.col("id", "bigint"), Self.col("created_at", "timestamptz")]
        let unindexed = Self.relation(columns, estimate: .estimated(5_000_000))
        #expect(RecencyColumns.defaultSort(for: unindexed) == nil)

        let index = IndexInfo(name: "i", columns: ["created_at"], isUnique: false, isPrimary: false, method: "btree", definition: "")
        let indexed = Self.relation(columns, indexes: [index], estimate: .estimated(5_000_000))
        #expect(RecencyColumns.defaultSort(for: indexed) == GridSort(column: 1, ascending: false, nullsLast: true))

        let hash = IndexInfo(name: "h", columns: ["created_at"], isUnique: false, isPrimary: false, method: "hash", definition: "")
        #expect(RecencyColumns.defaultSort(for: Self.relation(columns, indexes: [hash], estimate: .estimated(5_000_000))) == nil)

        let small = Self.relation(columns, estimate: .estimated(50_000))
        #expect(RecencyColumns.defaultSort(for: small) == GridSort(column: 1, ascending: false, nullsLast: true))
        #expect(RecencyColumns.defaultSort(for: Self.relation(columns)) == GridSort(column: 1, ascending: false, nullsLast: true))
    }

    @Test func aPrimaryKeyIntegerIsCheapToSortOn() {
        let relation = Self.relation(
            [Self.col("id", "bigint", identity: .always)], pk: ["id"], estimate: .estimated(9_000_000))
        #expect(RecencyColumns.defaultSort(for: relation) == GridSort(column: 0, ascending: false, nullsLast: true))
    }
}
