import SiftCore
import Testing

@testable import SiftKit

struct NavigationHistoryTests {
    let key = ConnectionKey.container(name: "db")

    func entry(_ n: Int) -> NavigationEntry {
        NavigationEntry(key: key, relation: RelationID("s", "t\(n)"), query: nil, active: nil)
    }

    @Test func pushClearsForward() {
        var h = NavigationHistory()
        h.push(entry(1))
        #expect(h.back(from: entry(2)) == entry(1))
        #expect(h.canGoForward)
        h.push(entry(3))
        #expect(!h.canGoForward)
        #expect(h.canGoBack)
    }

    @Test func backThenForwardReturns() {
        var h = NavigationHistory()
        #expect(!h.canGoBack && !h.canGoForward)
        #expect(h.back(from: entry(0)) == nil && h.forward(from: entry(0)) == nil)
        h.push(entry(1))
        h.push(entry(2))
        #expect(h.back(from: entry(3)) == entry(2))
        #expect(h.back(from: entry(2)) == entry(1))
        #expect(!h.canGoBack)
        #expect(h.forward(from: entry(1)) == entry(2))
        #expect(h.forward(from: entry(2)) == entry(3))
        #expect(!h.canGoForward)
    }

    @Test func theLimitDropsTheOldest() {
        var h = NavigationHistory()
        for n in 0..<(NavigationHistory.limit + 5) { h.push(entry(n)) }
        var last: NavigationEntry?
        var steps = 0
        var current = entry(999)
        while let e = h.back(from: current) { last = e; current = e; steps += 1 }
        #expect(steps == NavigationHistory.limit)
        #expect(last == entry(5))
    }
}
