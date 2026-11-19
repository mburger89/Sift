/// Splits every edge that spans more than one rank into a chain of unit-span edges
/// through dummy nodes, so that crossing reduction and placement see only adjacent ranks.
enum Dummies {
    struct Expansion {
        /// Real nodes first (`0..<realCount`), then the dummies in creation order.
        var rank: [Int]
        /// Predecessors and successors of every node, real or dummy (all one rank apart).
        var predecessors: [[Int]]
        var successors: [[Int]]
        /// For each input edge, the dummy nodes it passes through, in rank order.
        var chains: [[Int]]
        var dummyCount: Int { rank.count - realCount }
        var realCount: Int
    }

    /// `edges` must be unique and sorted, and every edge must run to a higher rank.
    /// Dummy ids follow the sorted edge order, so they are the same on every run.
    static func insert(ranks: [Int], edges: [(from: Int, to: Int)]) -> Expansion {
        var expansion = Expansion(
            rank: ranks,
            predecessors: [[Int]](repeating: [], count: ranks.count),
            successors: [[Int]](repeating: [], count: ranks.count),
            chains: [],
            realCount: ranks.count)
        for edge in edges {
            var previous = edge.from
            var chain: [Int] = []
            let first = ranks[edge.from] + 1
            if first < ranks[edge.to] {
                for rank in first..<ranks[edge.to] {
                    let dummy = expansion.rank.count
                    expansion.rank.append(rank)
                    expansion.predecessors.append([previous])
                    expansion.successors.append([])
                    expansion.successors[previous].append(dummy)
                    chain.append(dummy)
                    previous = dummy
                }
            }
            expansion.successors[previous].append(edge.to)
            expansion.predecessors[edge.to].append(previous)
            expansion.chains.append(chain)
        }
        return expansion
    }
}
