/// A deterministic layered (Sugiyama-style) layout.
///
/// The result depends only on the nodes, their sizes and the set of edges: the
/// order of the input arrays and Swift's per-process hash seed change nothing.
public enum LayeredLayout {
    public static func layout(_ graph: LayoutGraph, options: LayoutOptions = .init()) -> LayoutResult {
        let canonical = Canonical(graph)
        let count = canonical.ids.count
        let reversedPairs = CycleBreaker.reversedEdges(nodeCount: count, edges: canonical.pairs)
        var isReversed = [Bool](repeating: false, count: canonical.pairs.count)
        for index in reversedPairs { isReversed[index] = true }

        // The acyclic edges, unique and sorted; `dagOf` maps a pair to its entry.
        var dag = canonical.pairs.indices.map { index -> (from: Int, to: Int) in
            let pair = canonical.pairs[index]
            return isReversed[index] ? (pair.to, pair.from) : pair
        }
        dag.sort { ($0.from, $0.to) < ($1.from, $1.to) }
        dag = dag.enumerated().filter { $0.offset == 0 || dag[$0.offset - 1] != $0.element }.map(\.element)
        var dagIndex: [Int: Int] = [:]
        for (index, edge) in dag.enumerated() { dagIndex[edge.from * count + edge.to] = index }

        let ranks = Layering.longestPath(nodeCount: count, edges: dag)
        let expansion = Dummies.insert(ranks: ranks, edges: dag)
        var initial = [[Int]](repeating: [], count: (expansion.rank.max() ?? -1) + 1)
        for node in expansion.rank.indices { initial[expansion.rank[node]].append(node) }
        let reduction = CrossingReduction.reduce(
            order: initial, predecessors: expansion.predecessors,
            successors: expansion.successors, sweeps: options.sweeps)
        let placed = place(
            canonical: canonical, expansion: expansion, layers: reduction.order, options: options)

        var result = LayoutResult()
        for (index, id) in canonical.ids.enumerated() {
            result.ranks[id] = ranks[index]
            result.positions[id] = placed.positions[index]
        }
        result.selfLoops = canonical.selfLoops
        for (edge, pair) in canonical.edgePair.enumerated() where pair >= 0 {
            if isReversed[pair] { result.reversedEdges.append(edge) }
            let oriented = isReversed[pair]
                ? (from: canonical.pairs[pair].to, to: canonical.pairs[pair].from)
                : canonical.pairs[pair]
            let route = expansion.chains[dagIndex[oriented.from * count + oriented.to]!].map { placed.points[$0] }
            result.routes[edge] = isReversed[pair] ? route.reversed() : route
        }
        result.stats.dummyNodes = expansion.dummyCount
        result.stats.crossingsBefore = reduction.crossingsBefore
        result.stats.crossingsAfter = reduction.crossingsAfter
        result.stats.sweepsRun = reduction.sweepsRun
        result.stats.components = count == 0 ? 0 : 1
        return result
    }

    /// Coordinates for the real nodes and the centre point of every dummy.
    private static func place(
        canonical: Canonical, expansion: Dummies.Expansion, layers: [[Int]], options: LayoutOptions
    ) -> (positions: [LayoutPoint], points: [LayoutPoint]) {
        let total = expansion.rank.count
        func height(_ node: Int) -> Double { node < expansion.realCount ? canonical.heights[node] : 0 }
        let rankCount = (expansion.rank.max() ?? -1) + 1

        var center = Placement.assign(
            order: layers, heights: (0..<total).map(height), predecessors: expansion.predecessors,
            successors: expansion.successors, gap: options.nodeGap, passes: options.placementPasses)
        var top = Double.infinity
        for node in 0..<total { top = min(top, node < expansion.realCount ? center[node] - height(node) / 2 : center[node]) }
        for node in 0..<total { center[node] -= top }

        var columnX = [Double](repeating: 0, count: rankCount)
        var columnWidth = [Double](repeating: 0, count: rankCount)
        for node in 0..<expansion.realCount {
            columnWidth[expansion.rank[node]] = max(columnWidth[expansion.rank[node]], canonical.widths[node])
        }
        for rank in 1..<max(rankCount, 1) {
            columnX[rank] = columnX[rank - 1] + columnWidth[rank - 1] + options.layerGap
        }

        var positions: [LayoutPoint] = []
        var points = [LayoutPoint](repeating: LayoutPoint(x: 0, y: 0), count: total)
        for node in 0..<total {
            let rank = expansion.rank[node]
            if node < expansion.realCount {
                positions.append(LayoutPoint(x: columnX[rank], y: center[node] - height(node) / 2))
            } else {
                points[node] = LayoutPoint(x: columnX[rank] + columnWidth[rank] / 2, y: center[node])
            }
        }
        return (positions, points)
    }
}
