import Foundation
import Testing

@testable import SiftLayout

@Suite struct DeterminismTests {
    @Test func componentsArePackedApart() throws {
        let result = LayeredLayout.layout(graph(5, [(0, 1), (2, 3)]))
        #expect(result.stats.components == 3)
        #expect(result.positions[0] == point(0, 0))
        // The boxes of the three components: {0,1}, {2,3} and {4}.
        let boxes: [(Double, Double, Double, Double)] = [[0, 1], [2, 3], [4]].map { ids in
            let points = ids.map { result.positions[$0]! }
            return (
                points.map(\.x).min()!, points.map(\.y).min()!,
                points.map(\.x).max()! + 200, points.map(\.y).max()! + 100
            )
        }
        for a in boxes.indices {
            for b in boxes.indices where a < b {
                let (r, s) = (boxes[a], boxes[b])
                #expect(r.2 <= s.0 || s.2 <= r.0 || r.3 <= s.1 || s.3 <= r.1)
            }
        }
    }

    @Test(arguments: 0..<40)
    func permutingTheInputChangesNothing(seed: Int) {
        let g = randomGraph(seed: UInt64(seed), n: 30, e: 45)
        var rng = SplitMix64(seed: UInt64(seed) &+ 1000)
        let nodeOrder = Array(g.nodes.indices).shuffled(using: &rng)
        let edgeOrder = Array(g.edges.indices).shuffled(using: &rng)  // new index j holds old edge edgeOrder[j]
        let shuffled = LayoutGraph(
            nodes: nodeOrder.map { g.nodes[$0] }, edges: edgeOrder.map { g.edges[$0] })
        var newIndex = [Int](repeating: 0, count: g.edges.count)
        for (new, old) in edgeOrder.enumerated() { newIndex[old] = new }

        let a = LayeredLayout.layout(g)
        let b = LayeredLayout.layout(shuffled)
        #expect(a.positions == b.positions)
        #expect(a.ranks == b.ranks)
        #expect(a.bounds == b.bounds)
        #expect(a.stats == b.stats)
        #expect(a.reversedEdges.map { newIndex[$0] }.sorted() == b.reversedEdges)
        #expect(a.selfLoops.map { newIndex[$0] }.sorted() == b.selfLoops)
        #expect(Set(a.routes.keys.map { newIndex[$0] }) == Set(b.routes.keys))
        for (old, route) in a.routes { #expect(b.routes[newIndex[old]] == route) }
    }

    @Test func runningTwiceIsIdentical() {
        let g = randomGraph(seed: 7, n: 60, e: 100)
        #expect(LayeredLayout.layout(g) == LayeredLayout.layout(g))
    }

    @Test func fiveHundredTablesStayBounded() {
        let g = randomGraph(seed: 42, n: 500, e: 1000)
        let result = LayeredLayout.layout(g)
        #expect(result.positions.count == 500)
        #expect(result.stats.dummyNodes <= 20_000)
        #expect(result.stats.sweepsRun <= 24)
        #expect(result.stats.crossingsAfter <= result.stats.crossingsBefore)
    }

    /// Opt in with `SIFT_RUN_LAYOUT_BENCH=1` and a release build; prints the time, which no CI job asserts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIFT_RUN_LAYOUT_BENCH"] == "1"))
    func fiveHundredTablesTakeUnder250Milliseconds() {
        let g = randomGraph(seed: 42, n: 500, e: 1000)
        let start = ContinuousClock.now
        let result = LayeredLayout.layout(g)
        let elapsed = ContinuousClock.now - start
        print("layout of 500 tables, 1000 edges: \(elapsed), dummies \(result.stats.dummyNodes)")
        #expect(elapsed < .milliseconds(250))
    }
}
