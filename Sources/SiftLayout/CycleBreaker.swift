/// Greedy feedback-arc-set heuristic of Eades, Lin and Smyth.
///
/// Nodes are ordered so that few edges point backwards; the backward edges are
/// the ones to reverse. Ties go to the lowest node index, and every scan runs
/// over arrays in index order, so the answer never depends on hashing.
enum CycleBreaker {
    /// The indexes (ascending) of the edges to reverse so that the graph becomes acyclic.
    /// Nodes are `0..<nodeCount`; edges between equal nodes must not be passed.
    static func reversedEdges(nodeCount: Int, edges: [(from: Int, to: Int)]) -> [Int] {
        var outgoing = [[Int]](repeating: [], count: nodeCount)
        var incoming = [[Int]](repeating: [], count: nodeCount)
        for edge in edges {
            outgoing[edge.from].append(edge.to)
            incoming[edge.to].append(edge.from)
        }
        var outDegree = outgoing.map(\.count)
        var inDegree = incoming.map(\.count)
        var removed = [Bool](repeating: false, count: nodeCount)
        var remaining = nodeCount
        var front: [Int] = []
        var back: [Int] = []

        func remove(_ node: Int) {
            removed[node] = true
            remaining -= 1
            for target in outgoing[node] where !removed[target] { inDegree[target] -= 1 }
            for source in incoming[node] where !removed[source] { outDegree[source] -= 1 }
        }

        while remaining > 0 {
            var progress = true
            while progress {
                progress = false
                for node in 0..<nodeCount where !removed[node] && outDegree[node] == 0 {
                    back.append(node)
                    remove(node)
                    progress = true
                }
                for node in 0..<nodeCount where !removed[node] && inDegree[node] == 0 {
                    front.append(node)
                    remove(node)
                    progress = true
                }
            }
            guard remaining > 0 else { break }
            var best = -1
            var bestScore = Int.min
            for node in 0..<nodeCount where !removed[node] {
                let score = outDegree[node] - inDegree[node]
                if score > bestScore {
                    bestScore = score
                    best = node
                }
            }
            front.append(best)
            remove(best)
        }

        var position = [Int](repeating: 0, count: nodeCount)
        for (index, node) in (front + back.reversed()).enumerated() { position[node] = index }
        return edges.indices.filter { position[edges[$0].from] > position[edges[$0].to] }
    }
}
