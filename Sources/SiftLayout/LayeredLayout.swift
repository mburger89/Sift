/// A deterministic layered (Sugiyama-style) layout.
///
/// The result depends only on the nodes, their sizes and the set of edges: the
/// order of the input arrays and Swift's per-process hash seed change nothing.
/// Every stage iterates sorted arrays; dictionaries are used for lookup only.
public enum LayeredLayout {
    public static func layout(_ graph: LayoutGraph, options: LayoutOptions = .init()) -> LayoutResult {
        let canonical = Canonical(graph)
        let count = canonical.ids.count
        let reversedPairs = CycleBreaker.reversedEdges(nodeCount: count, edges: canonical.pairs)
        var isReversed = [Bool](repeating: false, count: canonical.pairs.count)
        for index in reversedPairs { isReversed[index] = true }

        // The acyclic edges, unique and sorted.
        var dag = canonical.pairs.indices.map { index -> (from: Int, to: Int) in
            let pair = canonical.pairs[index]
            return isReversed[index] ? (pair.to, pair.from) : pair
        }
        dag.sort { ($0.from, $0.to) < ($1.from, $1.to) }
        dag = dag.enumerated().filter { $0.offset == 0 || dag[$0.offset - 1] != $0.element }.map(\.element)
        var dagIndex: [Int: Int] = [:]
        for (index, edge) in dag.enumerated() { dagIndex[edge.from * count + edge.to] = index }

        // Connected components, each laid out on its own. The largest comes first, then the lowest id.
        var parent = Array(0..<count)
        func find(_ node: Int) -> Int {
            var root = node
            while parent[root] != root { root = parent[root] }
            var current = node
            while parent[current] != root { (current, parent[current]) = (parent[current], root) }
            return root
        }
        for edge in dag {
            let (a, b) = (find(edge.from), find(edge.to))
            if a != b { parent[max(a, b)] = min(a, b) }
        }
        var componentOfRoot = [Int](repeating: -1, count: count)
        var members: [[Int]] = []
        for node in 0..<count {
            let root = find(node)
            if componentOfRoot[root] < 0 {
                componentOfRoot[root] = members.count
                members.append([])
            }
            members[componentOfRoot[root]].append(node)
        }
        var edgesOfComponent = [[Int]](repeating: [], count: members.count)
        for (index, edge) in dag.enumerated() { edgesOfComponent[componentOfRoot[find(edge.from)]].append(index) }
        let order = members.indices.sorted {
            (-members[$0].count, members[$0][0]) < (-members[$1].count, members[$1][0])
        }

        var localOf = [Int](repeating: 0, count: count)
        var layouts: [ComponentLayout] = []
        for component in order {
            for (local, node) in members[component].enumerated() { localOf[node] = local }
            layouts.append(
                ComponentLayout(
                    widths: members[component].map { canonical.widths[$0] },
                    heights: members[component].map { canonical.heights[$0] },
                    edges: edgesOfComponent[component].map {
                        (from: localOf[dag[$0].from], to: localOf[dag[$0].to])
                    },
                    options: options))
        }
        let offsets = ComponentPacking.pack(
            sizes: layouts.map { ($0.width, $0.height) }, gap: options.componentGap,
            targetAspect: options.targetAspect)

        var result = LayoutResult()
        var dagRoutes = [[LayoutPoint]](repeating: [], count: dag.count)
        for (slot, component) in order.enumerated() {
            let layout = layouts[slot]
            let offset = offsets[slot]
            for (local, node) in members[component].enumerated() {
                let point = layout.positions[local]
                result.positions[canonical.ids[node]] = LayoutPoint(x: point.x + offset.x, y: point.y + offset.y)
                result.ranks[canonical.ids[node]] = layout.ranks[local]
            }
            for (local, index) in edgesOfComponent[component].enumerated() {
                dagRoutes[index] = layout.routes[local].map { LayoutPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
            }
            result.stats.dummyNodes += layout.dummyCount
            result.stats.crossingsBefore += layout.crossingsBefore
            result.stats.crossingsAfter += layout.crossingsAfter
            result.stats.sweepsRun = max(result.stats.sweepsRun, layout.sweepsRun)
        }
        result.stats.components = members.count

        result.selfLoops = canonical.selfLoops
        for (edge, pair) in canonical.edgePair.enumerated() where pair >= 0 {
            let from = canonical.pairs[pair].from
            let to = canonical.pairs[pair].to
            if isReversed[pair] {
                result.reversedEdges.append(edge)
                result.routes[edge] = dagRoutes[dagIndex[to * count + from]!].reversed()
            } else {
                result.routes[edge] = dagRoutes[dagIndex[from * count + to]!]
            }
        }
        return result
    }
}

/// One connected component, laid out in its own coordinates (top-left at the origin).
struct ComponentLayout {
    var positions: [LayoutPoint] = []
    var ranks: [Int] = []
    /// The bend points of each input edge, from its source to its target.
    var routes: [[LayoutPoint]] = []
    var width = 0.0
    var height = 0.0
    var dummyCount = 0
    var crossingsBefore = 0
    var crossingsAfter = 0
    var sweepsRun = 0

    /// `edges` must be unique, sorted, acyclic and between different nodes.
    init(widths: [Double], heights: [Double], edges: [(from: Int, to: Int)], options: LayoutOptions) {
        let count = widths.count
        ranks = Layering.longestPath(nodeCount: count, edges: edges)
        let expansion = Dummies.insert(ranks: ranks, edges: edges)
        let total = expansion.rank.count
        var initial = [[Int]](repeating: [], count: (ranks.max() ?? -1) + 1)
        for node in 0..<total { initial[expansion.rank[node]].append(node) }
        let reduction = CrossingReduction.reduce(
            order: initial, predecessors: expansion.predecessors,
            successors: expansion.successors, sweeps: options.sweeps)
        dummyCount = expansion.dummyCount
        crossingsBefore = reduction.crossingsBefore
        crossingsAfter = reduction.crossingsAfter
        sweepsRun = reduction.sweepsRun

        func extent(_ node: Int) -> Double { node < count ? heights[node] : 0 }
        var centre = Placement.assign(
            order: reduction.order, heights: (0..<total).map(extent),
            predecessors: expansion.predecessors, successors: expansion.successors,
            gap: options.nodeGap, passes: options.placementPasses)
        var top = Double.infinity
        for node in 0..<total { top = min(top, centre[node] - extent(node) / 2) }
        for node in 0..<total { centre[node] -= top }

        // Columns are as wide as their widest node; nodes are left-aligned in them.
        let rankCount = initial.count
        var columnWidth = [Double](repeating: 0, count: rankCount)
        for node in 0..<count { columnWidth[ranks[node]] = max(columnWidth[ranks[node]], widths[node]) }
        var columnX = [Double](repeating: 0, count: rankCount)
        for rank in 1..<max(rankCount, 1) {
            columnX[rank] = columnX[rank - 1] + columnWidth[rank - 1] + options.layerGap
        }

        positions = (0..<count).map { LayoutPoint(x: columnX[ranks[$0]], y: centre[$0] - heights[$0] / 2) }
        let bends = (0..<total).map {
            LayoutPoint(x: columnX[expansion.rank[$0]] + columnWidth[expansion.rank[$0]] / 2, y: centre[$0])
        }
        routes = expansion.chains.map { chain in chain.map { bends[$0] } }
        for node in count..<max(total, count) { height = max(height, centre[node]) }
        for node in 0..<count { height = max(height, positions[node].y + heights[node]) }
        width = (columnX.last ?? 0) + (columnWidth.last ?? 0)
    }
}
