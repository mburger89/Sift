import Testing

@testable import SiftLayout

@Suite struct CrossingReductionTests {
    @Test func barycenterUncrossesTheSecondLayer() throws {
        let result = LayeredLayout.layout(graph(4, [(0, 3), (1, 2), (0, 2)]))
        #expect(result.stats.crossingsBefore == 1)
        #expect(result.stats.crossingsAfter == 0)
        let three = try #require(result.positions[3])
        let two = try #require(result.positions[2])
        #expect(three.y < two.y)
    }

    @Test(arguments: 0..<200)
    func crossingsNeverIncrease(seed: Int) {
        let result = LayeredLayout.layout(randomGraph(seed: UInt64(seed), n: 40, e: 80))
        #expect(result.stats.crossingsAfter <= result.stats.crossingsBefore)
    }

    @Test(arguments: 0..<40)
    func moreSweepsNeverLeaveMoreCrossings(seed: Int) {
        let g = randomGraph(seed: UInt64(seed), n: 40, e: 80)
        var previous = Int.max
        for sweeps in 0...24 {
            var options = LayoutOptions()
            options.sweeps = sweeps
            let after = LayeredLayout.layout(g, options: options).stats.crossingsAfter
            #expect(after <= previous)
            previous = after
        }
    }

    @Test(arguments: 0..<200)
    func bjmMatchesBruteForce(seed: Int) {
        var rng = SplitMix64(seed: UInt64(seed))
        let upper = Int.random(in: 1...12, using: &rng)
        let lower = Int.random(in: 1...12, using: &rng)
        let edges = (0..<Int.random(in: 0...40, using: &rng)).map { _ in
            (upper: Int.random(in: 0..<upper, using: &rng), lower: Int.random(in: 0..<lower, using: &rng))
        }
        var brute = 0
        for a in edges.indices { for b in edges.indices where a < b {
            let x = edges[a], y = edges[b]
            if (x.upper < y.upper && x.lower > y.lower) || (x.upper > y.upper && x.lower < y.lower) { brute += 1 }
        } }
        #expect(CrossingReduction.crossings(edges: edges, lowerCount: lower) == brute)
    }
}
