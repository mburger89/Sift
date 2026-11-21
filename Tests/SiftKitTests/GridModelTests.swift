import Foundation
import Observation
import SiftCore
import SiftTestSupport
import Testing

@testable import SiftKit

@MainActor
struct GridModelTests {
    /// Yields to the main actor until `condition` holds (bounded, so a broken build fails instead of hanging).
    func settle(_ what: String = "condition", _ condition: () -> Bool) async throws {
        for _ in 0..<3000 where !condition() { await Task.yield() }
        if !condition() { throw GridTestError.timedOut(what) }
    }

    /// A model over `source`, with its count loaded.
    func loaded(_ source: FakeGridSource) async throws -> GridModel {
        let model = GridModel(source: source)
        try await settle("the count") { model.count != .estimated(0) || source.calls.count > 0 && !model.isLoading }
        try await settle("the count call") { !source.calls.isEmpty }
        try await settle("idle") { !model.isLoading }
        return model
    }

    @Test func readingAMissingRowRequestsItsPageOnceAndDrawsAPlaceholder() async throws {
        let source = FakeGridSource(trueCount: 2000)
        let model = try await loaded(source)
        #expect(model.count == .exact(2000))
        // Many reads in one build: one request.
        for column in 0..<5 { #expect(model.value(row: 3, column: column) == nil) }
        #expect(model.value(row: 10, column: 0) == nil)
        try await settle("page 0") { model.cachedPages == [0] }
        #expect(source.pageCalls.map(\.index) == [0])
        #expect(model.value(row: 3, column: 0) == .int(3))
        #expect(model.value(row: 3, column: 2) == .text("r3c2"))
        // A cached read asks for nothing.
        for _ in 0..<5 { _ = model.value(row: 4, column: 1) }
        try await settle("settled") { !model.isLoading }
        #expect(source.pageCalls.map(\.index) == [0])
    }

    @Test func aBuildNeverWritesObservableState() async throws {
        let source = FakeGridSource(trueCount: 2000)
        let model = try await loaded(source)
        let changed = Flag()
        withObservationTracking {
            // A read of a missing page, as a cell's build makes it: it must write nothing observable.
            _ = model.value(row: 600, column: 1)
            _ = model.count
            _ = model.isLoading
            _ = model.error
        } onChange: { changed.set() }
        #expect(!changed.value, "the read wrote observable state during the build")
        #expect(source.pageCalls.isEmpty)
        // The fetch happens on a later turn, and its arrival is what redraws.
        try await settle("page 1") { model.cachedPages == [1] }
        #expect(changed.value)
    }

    @Test func aJumpToTheEndOf10MFetchesOnePage() async throws {
        let source = FakeGridSource(trueCount: 10_000_000)
        let model = try await loaded(source)
        #expect(model.count == .exact(10_000_000))
        model.resetReadCount()
        // The window at End: 30 rows, 5 columns.
        for row in 9_999_970..<10_000_000 { for column in 0..<5 { _ = model.value(row: row, column: column) } }
        #expect(model.valueReads == 150)
        try await settle("the last page") { model.cachedPages == [19_999] }
        let pages = source.pageCalls
        #expect(pages.count == 1 && pages[0].index == 19_999 && !pages[0].keyset, "\(pages)")
        #expect(model.value(row: 9_999_999, column: 0) == .int(9_999_999))
    }

    @Test func aStalePageAfterApplyIsDropped() async throws {
        let source = FakeGridSource(trueCount: 2000)
        let model = try await loaded(source)
        source.holdsPages = true
        _ = model.value(row: 0, column: 0)
        try await settle("the old query's page") { source.pageCalls.count == 1 }
        // The user sorts descending while the old query is still answering.
        model.apply(GridQuery(sort: GridSort(column: 0, ascending: false)))
        #expect(source.cancelCalls == 1)
        #expect(model.value(row: 0, column: 0) == nil)
        try await settle("the new query's page") { source.pageCalls.count == 2 }
        // The old answer lands first, in the old order. It must not show.
        source.release(callAt: source.calls.count - 2)
        for _ in 0..<50 { await Task.yield() }
        #expect(model.cachedPages.isEmpty)
        #expect(model.value(row: 0, column: 0) == nil)
        // The new answer lands, descending.
        source.release(callAt: source.calls.count - 1)
        try await settle("the sorted page") { model.cachedPages == [0] }
        #expect(model.value(row: 0, column: 0) == .int(1999))
    }

    @Test func aShortPageFixesTheCount() async throws {
        let source = FakeGridSource(trueCount: 1730, count: .estimated(5000))
        let model = try await loaded(source)
        #expect(model.count == .estimated(5000))
        _ = model.value(row: 1600, column: 0)
        try await settle("page 3") { model.cachedPages == [3] }
        #expect(model.count == .exact(1730))
        #expect(model.rows.count == 1730)
    }

    @Test func aShortPageCanAlsoShrinkAnExactCount() async throws {
        // Rows were deleted since the count: the page answers fewer than the count said.
        let source = FakeGridSource(trueCount: 800, count: .exact(1000))
        let model = try await loaded(source)
        _ = model.value(row: 600, column: 0)
        try await settle("page 1") { model.cachedPages == [1] }
        #expect(model.count == .exact(800))
    }

    @Test func aFullLastEstimatedPageGrowsTheCount() async throws {
        let source = FakeGridSource(trueCount: 2300, count: .estimated(1000))
        let model = try await loaded(source)
        // The last estimated page (rows 500..<1000) comes back full: the count grows by a page.
        _ = model.value(row: 900, column: 0)
        try await settle("page 1") { model.cachedPages == [1] }
        #expect(model.count == .estimated(1500))
        _ = model.value(row: 1400, column: 0)
        try await settle("page 2") { model.cachedPages == [1, 2] }
        #expect(model.count == .estimated(2000))
        // Page 4 is the true end: short, so exact.
        _ = model.value(row: 1999, column: 0)
        try await settle("page 3") { model.cachedPages.contains(3) }
        #expect(model.count == .estimated(2500))
        _ = model.value(row: 2400, column: 0)
        try await settle("page 4") { model.cachedPages.contains(4) }
        #expect(model.count == .exact(2300))
    }

    @Test func theLRUKeepsAtMost40PagesAndNeverEvictsAVisibleOne() async throws {
        let source = FakeGridSource(trueCount: 100 * 500)
        let model = try await loaded(source)
        // Read pages 0 ... 59 one turn at a time, always keeping page 0 (the visible one) in view.
        for page in 0..<60 {
            _ = model.value(row: 0, column: 0)
            _ = model.value(row: page * 500, column: 0)
            try await settle("page \(page)") { model.cachedPages.contains(page) || page == 0 }
            try await settle("quiet") { !model.isLoading }
            #expect(model.cachedPages.count <= GridPaging.cachedPages, "page \(page): \(model.cachedPages.count) pages")
        }
        #expect(model.cachedPages.contains(0), "the visible page was evicted")
        #expect(model.cachedPages.contains(59))
        #expect(model.cachedPages.count == GridPaging.cachedPages)
        // The oldest unread pages went first.
        #expect(!model.cachedPages.contains(1))
    }

    @Test func applyCancelsTheInFlightQuery() async throws {
        let source = FakeGridSource(trueCount: 2000)
        let model = try await loaded(source)
        // Nothing in flight: nothing to cancel.
        model.apply(GridQuery(sort: GridSort(column: 1, ascending: true)))
        #expect(source.cancelCalls == 0)
        source.holdsPages = true
        _ = model.value(row: 0, column: 0)
        try await settle("a page in flight") { source.pageCalls.count == 1 }
        model.apply(GridQuery(sort: GridSort(column: 1, ascending: false)))
        #expect(source.cancelCalls == 1)
        // A page that nobody looks at any more is cancelled too.
        _ = model.value(row: 0, column: 0)
        try await settle("the new page in flight") { source.pageCalls.count == 2 }
        _ = model.value(row: 1500, column: 0)
        try await settle("the jump") { source.cancelCalls == 2 && source.pageCalls.count == 3 }
        #expect(source.pageCalls.last?.index == 3)
        source.releaseAll()
    }

    @Test func aSortKeepsTheCountButAFilterAsksAgain() async throws {
        let source = FakeGridSource(trueCount: 2000)
        let model = try await loaded(source)
        model.apply(GridQuery(sort: GridSort(column: 0, ascending: false)))
        #expect(model.count == .exact(2000))
        try await settle("idle") { !model.isLoading }
        #expect(source.calls.filter { if case .count = $0 { return true } else { return false } }.count == 1)
        source.trueCount = 40
        model.apply(GridQuery(sort: GridSort(column: 0, ascending: false), filters: [GridFilter(column: 0, op: .lt, value: "40")]))
        try await settle("the filtered count") { model.count == .exact(40) }
        #expect(model.rows.count == 40)
    }

    @Test func aFilterErrorIsReportedWithoutClearingTheGrid() async throws {
        let source = FakeGridSource(trueCount: 2000)
        let model = try await loaded(source)
        _ = model.value(row: 0, column: 0)
        try await settle("page 0") { model.cachedPages == [0] }
        let bad = GridQuery(filters: [GridFilter(column: 0, op: .eq, value: "abc")])
        source.failNext([SourceError(.server(sqlState: "22P02"), "invalid input syntax for type integer: \"abc\"")])
        model.apply(bad)
        try await settle("the error") { model.error != nil }
        #expect(model.error == "invalid input syntax for type integer: \"abc\"")
        #expect(model.errorIsFilter)
        // The last good rows are back, under the last good query.
        #expect(model.query == GridQuery())
        #expect(model.count == .exact(2000))
        #expect(model.value(row: 0, column: 0) == .int(0))
        // And the grid still works.
        _ = model.value(row: 700, column: 0)
        try await settle("page 1") { model.cachedPages.contains(1) }
        #expect(model.error == nil || model.errorIsFilter)
    }

    @Test func aFailedPageIsReportedAndNotRetriedUntilAsked() async throws {
        let source = FakeGridSource(trueCount: 2000)
        let model = try await loaded(source)
        source.failNext([SourceError(.other, "boom")])
        _ = model.value(row: 0, column: 0)
        try await settle("the error") { model.error == "boom" }
        #expect(!model.errorIsFilter)
        for _ in 0..<5 { _ = model.value(row: 0, column: 0) }
        for _ in 0..<50 { await Task.yield() }
        #expect(source.pageCalls.count == 1, "a failed page was asked again by itself")
        model.retry()
        _ = model.value(row: 0, column: 0)
        try await settle("the page") { model.cachedPages == [0] }
        #expect(model.error == nil)
    }

    @Test func keysetIsOfferedWhenThePreviousPageIsLoaded() async throws {
        let source = FakeGridSource(trueCount: 5000)
        let model = try await loaded(source)
        _ = model.value(row: 0, column: 0)
        try await settle("page 0") { model.cachedPages == [0] }
        _ = model.value(row: 500, column: 0)
        try await settle("page 1") { model.cachedPages == [0, 1] }
        _ = model.value(row: 3000, column: 0)
        try await settle("page 6") { model.cachedPages.contains(6) }
        #expect(source.pageCalls.map(\.keyset) == [false, true, false])
    }

    @Test func anExactCountReplacesTheEstimateAndCanBeCancelled() async throws {
        let source = FakeGridSource(trueCount: 3_000_000, count: .estimated(2_500_000))
        let model = try await loaded(source)
        #expect(model.count == .estimated(2_500_000))
        model.countExactly()
        #expect(model.isCountingExactly)
        try await settle("exact") { model.count == .exact(3_000_000) }
        #expect(!model.isCountingExactly)

        let other = FakeGridSource(trueCount: 3_000_000, count: .estimated(2_500_000))
        let second = try await loaded(other)
        other.holdsCounts = true
        second.countExactly()
        try await settle("in flight") { other.calls.contains(.exactCount(GridQuery())) }
        second.cancelExactCount()
        #expect(other.cancelCalls == 1 && !second.isCountingExactly)
        other.releaseAll()
        for _ in 0..<50 { await Task.yield() }
        #expect(second.count == .estimated(2_500_000), "a cancelled count still landed")
    }
}

enum GridTestError: Error { case timedOut(String) }

/// A flag an `onChange` closure (which is `@Sendable`) can set.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
