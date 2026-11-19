/// Vertical placement by pool-adjacent-violators (isotonic regression).
///
/// Within one rank the nodes keep their order and must stay `gap` apart. Each
/// node wants to sit at the mean centre of its neighbours; the closest feasible
/// placement pools nodes that would collide into one block at their mean, so
/// nothing overlaps by construction.
enum Placement {
    /// The centres closest (least squares) to `desired` that keep consecutive
    /// nodes at least `gap` apart, edge to edge. `extents` are the node heights.
    static func isotonic(desired: [Double], extents: [Double], gap: Double) -> [Double] {
        let count = desired.count
        guard count > 0 else { return [] }
        // The smallest centre distance from the first node, so the constraint becomes "non-decreasing".
        var offset = [Double](repeating: 0, count: count)
        for index in 1..<max(count, 1) {
            offset[index] = offset[index - 1] + (extents[index - 1] + extents[index]) / 2 + gap
        }
        var sums: [Double] = []
        var sizes: [Int] = []
        for index in 0..<count {
            sums.append(desired[index] - offset[index])
            sizes.append(1)
            while sums.count > 1,
                sums[sums.count - 2] / Double(sizes[sizes.count - 2])
                    > sums[sums.count - 1] / Double(sizes[sizes.count - 1])
            {
                let sum = sums.removeLast()
                let size = sizes.removeLast()
                sums[sums.count - 1] += sum
                sizes[sizes.count - 1] += size
            }
        }
        var centres: [Double] = []
        for (sum, size) in zip(sums, sizes) {
            let mean = sum / Double(size)
            for _ in 0..<size { centres.append(mean + offset[centres.count]) }
        }
        return centres
    }

    /// The centre of every node, found by alternating passes over the ranks. Each rank
    /// is first stacked about 0, then aligned to the rank before it (downward) and
    /// to the rank after it (upward), `passes` times.
    static func assign(
        order: [[Int]], heights: [Double], predecessors: [[Int]], successors: [[Int]],
        gap: Double, passes: Int
    ) -> [Double] {
        var centre = [Double](repeating: 0, count: heights.count)
        func place(_ layer: [Int], neighbours: [[Int]]) {
            let desired = layer.map { node -> Double in
                let adjacent = neighbours[node]
                guard !adjacent.isEmpty else { return centre[node] }
                return adjacent.reduce(0) { $0 + centre[$1] } / Double(adjacent.count)
            }
            let placed = isotonic(desired: desired, extents: layer.map { heights[$0] }, gap: gap)
            for (node, value) in zip(layer, placed) { centre[node] = value }
        }
        for layer in order { place(layer, neighbours: [[Int]](repeating: [], count: heights.count)) }
        for _ in 0..<passes {
            for rank in order.indices.dropFirst() { place(order[rank], neighbours: predecessors) }
            for rank in order.indices.dropLast().reversed() { place(order[rank], neighbours: successors) }
        }
        return centre
    }
}
