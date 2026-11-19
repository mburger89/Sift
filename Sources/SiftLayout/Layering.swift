/// Longest-path layering: a node's rank is the length of the longest path that ends at it.
enum Layering {
    /// The rank of each node. The edges must form a DAG; nodes on a cycle keep rank 0.
    static func longestPath(nodeCount: Int, edges: [(from: Int, to: Int)]) -> [Int] {
        var outgoing = [[Int]](repeating: [], count: nodeCount)
        var inDegree = [Int](repeating: 0, count: nodeCount)
        for edge in edges {
            outgoing[edge.from].append(edge.to)
            inDegree[edge.to] += 1
        }
        var rank = [Int](repeating: 0, count: nodeCount)
        var queue = (0..<nodeCount).filter { inDegree[$0] == 0 }
        var head = 0
        while head < queue.count {
            let node = queue[head]
            head += 1
            for target in outgoing[node] {
                rank[target] = max(rank[target], rank[node] + 1)
                inDegree[target] -= 1
                if inDegree[target] == 0 { queue.append(target) }
            }
        }
        return rank
    }
}
