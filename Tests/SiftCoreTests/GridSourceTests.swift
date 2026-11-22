import SiftCore
import Testing

@Suite struct GridSourceTests {
    @Test func rowCountReadsItsValueAndExactness() {
        #expect(RowCount.exact(7).value == 7)
        #expect(RowCount.estimated(9).value == 9)
        #expect(RowCount.exact(7).isExact)
        #expect(!RowCount.estimated(7).isExact)
    }

    @Test func aQueryNarrowsOnlyWithFiltersOrASearch() {
        #expect(!GridQuery().narrows)
        #expect(!GridQuery(sort: GridSort(column: 1)).narrows)
        #expect(GridQuery(filters: [GridFilter(column: 0, op: .isNull)]).narrows)
        #expect(GridQuery(search: "x").narrows)
        #expect(!GridQuery(search: "").narrows)
    }

    @Test func aJsonColumnHasNoSortComparator() {
        func column(_ type: String) -> ResultColumn { ResultColumn(name: "c", typeOID: 0, typeName: type) }
        #expect(!column("json").isSortable)
        #expect(!column("xml").isSortable)
        #expect(!column("json[]").isSortable)
        #expect(!column("point").isSortable)
        #expect(column("jsonb").isSortable)
        #expect(column("text").isSortable)
        #expect(column("int4[]").isSortable)
        #expect(column("timestamptz").isSortable)
    }

    @Test func onlyValueTakingOperatorsTakeAValue() {
        let withoutValue = FilterOp.allCases.filter { !$0.takesValue }
        #expect(Set(withoutValue) == [.isNull, .isNotNull])
    }
}
