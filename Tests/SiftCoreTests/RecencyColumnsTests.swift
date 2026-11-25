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
                Self.col("created_at", "timestamp with time zone")
            ], pk: ["id"])
        #expect(RecencyColumns.candidates(for: relation) == [3, 2, 1, 0])
    }

    @Test func namesMatchCaseInsensitivelyAndOnlyOnTimestampLikeTypes() {
        let relation = Self.relation([
            Self.col("Created_At", "text"),
            Self.col("Inserted_At", "timestamp without time zone"),
            Self.col("LAST_MODIFIED", "date"),
            Self.col("created", "timestamptz")
        ])
        #expect(RecencyColumns.candidates(for: relation) == [1, 3, 2])
    }

    @Test func anIdentityOrNextvalIntegerIsACandidatePrimaryKeyFirst() {
        let relation = Self.relation(
            [
                Self.col("a", "bigint", identity: .byDefault),
                Self.col("b", "integer", def: "nextval('x'::regclass)"),
                Self.col("c", "smallint"),
                Self.col("d", "text", def: "nextval('y'::regclass)")
            ], pk: ["b"])
        #expect(RecencyColumns.candidates(for: relation) == [1, 0])
    }

    @Test func noCandidatesMeansNoDefault() {
        let relation = Self.relation([Self.col("name", "text"), Self.col("n", "integer")])
        #expect(RecencyColumns.candidates(for: relation).isEmpty)
        #expect(RecencyColumns.defaultSort(for: relation) == nil)
    }

    static func created(null: Bool, type: String = "timestamptz") -> [ColumnInfo] {
        [
            Self.col("id", "bigint"),
            ColumnInfo(name: "created_at", ordinal: 2, typeName: type, isNullable: null)
        ]
    }

    @Test func theDefaultIsOnOnlyWhenIndexedOrSmall() {
        let index = IndexInfo(name: "i", columns: ["created_at"], isUnique: false, isPrimary: false, method: "btree", definition: "")
        let big = RowEstimate.estimated(5_000_000)

        // NOT NULL: an index leading on it makes it cheap, and the sort reads DESC NULLS FIRST.
        let notNull = Self.created(null: false)
        #expect(RecencyColumns.defaultSort(for: Self.relation(notNull, estimate: big)) == nil)
        #expect(RecencyColumns.defaultSort(for: Self.relation(notNull, indexes: [index], estimate: big)) == GridSort(column: 1, ascending: false, nullsLast: false))
        let hash = IndexInfo(name: "h", columns: ["created_at"], isUnique: false, isPrimary: false, method: "hash", definition: "")
        #expect(RecencyColumns.defaultSort(for: Self.relation(notNull, indexes: [hash], estimate: big)) == nil)

        // Nullable: an index cannot serve NULLS LAST, so only a small or unknown estimate is cheap.
        let nullable = Self.created(null: true)
        #expect(RecencyColumns.defaultSort(for: Self.relation(nullable, indexes: [index], estimate: big)) == nil)
        #expect(RecencyColumns.defaultSort(for: Self.relation(nullable, estimate: .estimated(50_000))) == GridSort(column: 1, ascending: false, nullsLast: true))
        #expect(RecencyColumns.defaultSort(for: Self.relation(nullable)) == GridSort(column: 1, ascending: false, nullsLast: true))
    }

    @Test func newestSortPutsNullsLastOnlyForNullableColumns() {
        let relation = Self.relation(Self.created(null: true) + [ColumnInfo(name: "seen", ordinal: 3, typeName: "date", isNullable: false)])
        #expect(RecencyColumns.newestSort(column: 1, in: relation) == GridSort(column: 1, ascending: false, nullsLast: true))
        #expect(RecencyColumns.newestSort(column: 2, in: relation) == GridSort(column: 2, ascending: false, nullsLast: false))
    }

    @Test func aPrecisionQualifiedTimestampIsTimestampLike() {
        let relation = Self.relation(Self.created(null: false, type: "timestamp(3) with time zone"))
        #expect(RecencyColumns.candidates(for: relation) == [1])
    }

    @Test func aPartialIndexDoesNotMakeItCheap() {
        let partial = IndexInfo(name: "p", columns: ["created_at"], isUnique: false, isPrimary: false, method: "btree", predicate: "id > 1", definition: "")
        let relation = Self.relation(Self.created(null: false), indexes: [partial], estimate: .estimated(5_000_000))
        #expect(RecencyColumns.defaultSort(for: relation) == nil)
    }

    @Test func aPrimaryKeyIntegerIsCheapToSortOn() {
        let id = ColumnInfo(name: "id", ordinal: 1, typeName: "bigint", isNullable: false, identity: .always)
        let relation = Self.relation([id], pk: ["id"], estimate: .estimated(9_000_000))
        #expect(RecencyColumns.defaultSort(for: relation) == GridSort(column: 0, ascending: false, nullsLast: false))
    }

    @Test func anExpensiveFirstCandidateFallsBackToTheFirstCheapOne() {
        // An unindexed created_at on a big table, and a bigserial primary key: id DESC is the cheap newest-first.
        let relation = Self.relation(
            [
                ColumnInfo(name: "id", ordinal: 1, typeName: "bigint", isNullable: false, defaultExpression: "nextval('t_id_seq'::regclass)"),
                ColumnInfo(name: "created_at", ordinal: 2, typeName: "timestamp with time zone", isNullable: false, defaultExpression: "now()")
            ], pk: ["id"], estimate: .estimated(5_000_000))
        #expect(RecencyColumns.candidates(for: relation) == [1, 0])
        #expect(RecencyColumns.defaultColumn(for: relation) == 0)
        #expect(RecencyColumns.defaultSort(for: relation)?.column == 0)
        // Nothing cheap: as before, no default.
        let nothing = Self.relation([ColumnInfo(name: "created_at", ordinal: 1, typeName: "timestamptz", isNullable: false)], estimate: .estimated(5_000_000))
        #expect(RecencyColumns.defaultColumn(for: nothing) == nil && RecencyColumns.defaultSort(for: nothing) == nil)
    }
}
