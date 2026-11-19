/// Barycenter sweeps over the ranks, with crossings counted by the accumulator
/// tree of Barth, Jünger and Mutzel.
enum CrossingReduction {
    struct Outcome {
        var order: [[Int]]
        var crossingsBefore: Int
        var crossingsAfter: Int
        var sweepsRun: Int
    }

    /// The crossings between two adjacent ranks. Each edge is a pair of positions
    /// (in the upper rank, in the lower rank); the lower rank has `lowerCount` positions.
    static func crossings(edges: [(upper: Int, lower: Int)], lowerCount: Int) -> Int {
        guard lowerCount > 0 else { return 0 }
        let sorted = edges.sorted { ($0.upper, $0.lower) < ($1.upper, $1.lower) }
        var firstLeaf = 1
        while firstLeaf < lowerCount { firstLeaf <<= 1 }
        var tree = [Int](repeating: 0, count: 2 * firstLeaf)
        var crossings = 0
        for edge in sorted {
            var index = edge.lower + firstLeaf
            tree[index] += 1
            while index > 1 {
                // A left child's right sibling counts the earlier edges that end further down.
                if index % 2 == 0 { crossings += tree[index + 1] }
                index /= 2
                tree[index] += 1
            }
        }
        return crossings
    }

    /// The crossings of a whole ordering: the sum over every pair of adjacent ranks.
    static func crossings(order: [[Int]], successors: [[Int]]) -> Int {
        guard order.count > 1 else { return 0 }
        var position = [Int](repeating: 0, count: successors.count)
        for layer in order { for (index, node) in layer.enumerated() { position[node] = index } }
        var total = 0
        for rank in 0..<(order.count - 1) {
            var edges: [(upper: Int, lower: Int)] = []
            for (index, node) in order[rank].enumerated() {
                for target in successors[node] { edges.append((index, position[target])) }
            }
            total += crossings(edges: edges, lowerCount: order[rank + 1].count)
        }
        return total
    }

    /// One pass over the ranks: each rank is re-sorted by the mean position of its
    /// neighbours in the rank already visited. A node without such neighbours keeps its place.
    /// Ties keep the current order, so the sort key is total.
    static func sweep(
        order: inout [[Int]], predecessors: [[Int]], successors: [[Int]], downward: Bool
    ) {
        var position = [Int](repeating: 0, count: predecessors.count)
        for layer in order { for (index, node) in layer.enumerated() { position[node] = index } }
        let ranks = Array(order.indices)
        for rank in downward ? Array(ranks.dropFirst()) : Array(ranks.dropLast().reversed()) {
            let neighbours = downward ? predecessors : successors
            let keyed = order[rank].enumerated().map { index, node -> (key: Double, index: Int, node: Int) in
                let adjacent = neighbours[node]
                guard !adjacent.isEmpty else { return (Double(index), index, node) }
                let sum = adjacent.reduce(0) { $0 + position[$1] }
                return (Double(sum) / Double(adjacent.count), index, node)
            }
            let sorted = keyed.sorted { ($0.key, $0.index) < ($1.key, $1.index) }
            order[rank] = sorted.map(\.node)
            for (index, node) in order[rank].enumerated() { position[node] = index }
        }
    }

    /// Runs up to `sweeps` rounds (one downward and one upward pass each) and keeps the best order.
    static func reduce(
        order initial: [[Int]], predecessors: [[Int]], successors: [[Int]], sweeps: Int
    ) -> Outcome {
        var current = initial
        let before = crossings(order: current, successors: successors)
        var best = current
        var bestCrossings = before
        var sweepsRun = 0
        while sweepsRun < sweeps && bestCrossings > 0 {
            let previous = current
            sweep(order: &current, predecessors: predecessors, successors: successors, downward: true)
            sweep(order: &current, predecessors: predecessors, successors: successors, downward: false)
            sweepsRun += 1
            let now = crossings(order: current, successors: successors)
            if now < bestCrossings {
                bestCrossings = now
                best = current
            }
            if current == previous { break }
        }
        return Outcome(
            order: best, crossingsBefore: before, crossingsAfter: bestCrossings, sweepsRun: sweepsRun)
    }
}
