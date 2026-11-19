import Testing

@testable import SiftLayout

@Suite struct PlacementTests {
    @Test func diamondIsBalanced() {
        let result = LayeredLayout.layout(graph(4, [(0, 1), (0, 2), (1, 3), (2, 3)]))
        #expect(result.positions == [0: point(0, 70), 1: point(320, 0), 2: point(320, 140), 3: point(640, 70)])
    }

    @Test func isotonicPoolsViolators() {
        #expect(Placement.isotonic(desired: [0, 0], extents: [100, 100], gap: 40) == [-70, 70])
        // Already apart: nothing moves.
        #expect(Placement.isotonic(desired: [0, 500], extents: [100, 100], gap: 40) == [0, 500])
        // Three nodes pool into one block around their mean.
        #expect(Placement.isotonic(desired: [10, 10, 10], extents: [100, 100, 100], gap: 40) == [-130, 10, 150])
    }

    @Test(arguments: 0..<200)
    func noTwoNodesOverlap(seed: Int) {
        let g = randomGraph(seed: UInt64(seed), n: 30, e: 50)
        let result = LayeredLayout.layout(g)
        let slack = LayoutOptions().nodeGap / 2 - 1e-9
        let rects = g.nodes.map { node -> (Double, Double, Double, Double) in
            let p = result.positions[node.id]!
            return (p.x - slack, p.y - slack, p.x + node.width + slack, p.y + node.height + slack)
        }
        for a in rects.indices {
            for b in rects.indices where a < b {
                let (r, s) = (rects[a], rects[b])
                let disjoint = r.2 <= s.0 || s.2 <= r.0 || r.3 <= s.1 || s.3 <= r.1
                #expect(disjoint)
            }
        }
    }

    @Test(arguments: 0..<200)
    func edgesAreRankOrdered(seed: Int) {
        let g = randomGraph(seed: UInt64(seed), n: 30, e: 50)
        let result = LayeredLayout.layout(g)
        let reversed = Set(result.reversedEdges)
        let widths = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0.width) })
        var checked = 0
        for (index, edge) in g.edges.enumerated() where edge.from != edge.to {
            let (from, to) = reversed.contains(index) ? (edge.to, edge.from) : (edge.from, edge.to)
            #expect(result.positions[to]!.x >= result.positions[from]!.x + widths[from]! + LayoutOptions().layerGap - 1e-9)
            checked += 1
        }
        #expect(checked > 0)
    }
}
