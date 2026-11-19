import Testing

@testable import SiftLayout

@Suite struct RankingTests {
    @Test func chainGoesLeftToRight() {
        let result = LayeredLayout.layout(graph(3, [(0, 1), (1, 2)]))
        #expect(result.positions == [0: point(0, 0), 1: point(320, 0), 2: point(640, 0)])
    }

    @Test func aLongEdgeGetsOneDummy() throws {
        let result = LayeredLayout.layout(graph(3, [(0, 1), (1, 2), (0, 2)]))
        #expect(result.stats.dummyNodes == 1)
        let route = try #require(result.routes[2])
        #expect(route.count == 1)
        let bend = try #require(route.first)
        #expect(bend.x >= 320 && bend.x <= 520)
        let middle = try #require(result.positions[1])
        #expect(bend.y < middle.y || bend.y > middle.y + 100)
    }

    @Test(arguments: 0..<100)
    func routesHaveOnePointPerSpannedGap(seed: Int) {
        let g = randomGraph(seed: UInt64(seed), n: 25, e: 50)
        let result = LayeredLayout.layout(g)
        for (index, edge) in g.edges.enumerated() where edge.from != edge.to {
            let span = abs(result.ranks[edge.to]! - result.ranks[edge.from]!)
            #expect(result.routes[index]?.count == span - 1)
        }
    }
}
