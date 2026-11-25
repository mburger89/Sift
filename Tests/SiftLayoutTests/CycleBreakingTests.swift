import Testing

@testable import SiftLayout

@Suite struct CycleBreakingTests {
    @Test func twoCycleReversesTheHigherEdge() {
        let result = LayeredLayout.layout(graph(2, [(0, 1), (1, 0)]))
        #expect(result.reversedEdges == [1])
        #expect(CycleBreaker.reversedEdges(nodeCount: 2, edges: [(0, 1), (1, 0)]) == [1])
    }

    @Test func selfLoopsAreSetAside() {
        let result = LayeredLayout.layout(graph(2, [(0, 0), (0, 1)]))
        #expect(result.selfLoops == [0])
        #expect(result.ranks == [0: 0, 1: 1])
        #expect(result.reversedEdges.isEmpty)
    }

    @Test(arguments: 0..<200)
    func reversingTheReversedSetLeavesADAG(seed: Int) {
        let g = randomGraph(seed: UInt64(seed), n: 30, e: 60)
        let canonical = Canonical(g)
        let reversed = Set(CycleBreaker.reversedEdges(nodeCount: canonical.ids.count, edges: canonical.pairs))
        let dag = canonical.pairs.enumerated().map {
            reversed.contains($0.offset) ? ($0.element.to, $0.element.from) : ($0.element.from, $0.element.to)
        }
        // Kahn: a DAG is one where every node can be removed.
        var inDegree = [Int](repeating: 0, count: canonical.ids.count)
        var outgoing = [[Int]](repeating: [], count: canonical.ids.count)
        for (from, to) in dag {
            inDegree[to] += 1
            outgoing[from].append(to)
        }
        var queue = inDegree.indices.filter { inDegree[$0] == 0 }
        var seen = 0
        while let node = queue.popLast() {
            seen += 1
            for target in outgoing[node] {
                inDegree[target] -= 1
                if inDegree[target] == 0 { queue.append(target) }
            }
        }
        #expect(seen == canonical.ids.count)
    }
}
