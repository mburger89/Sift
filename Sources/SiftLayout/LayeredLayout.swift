/// A deterministic layered (Sugiyama-style) layout.
///
/// The result depends only on the nodes, their sizes and the set of edges: the
/// order of the input arrays and Swift's per-process hash seed change nothing.
public enum LayeredLayout {
    public static func layout(_ graph: LayoutGraph, options: LayoutOptions = .init()) -> LayoutResult {
        let canonical = Canonical(graph)
        let reversedPairs = Set(
            CycleBreaker.reversedEdges(nodeCount: canonical.ids.count, edges: canonical.pairs))
        let dag = canonical.pairs.enumerated().map { index, pair in
            reversedPairs.contains(index) ? (from: pair.to, to: pair.from) : pair
        }
        let ranks = Layering.longestPath(nodeCount: canonical.ids.count, edges: dag)

        var result = LayoutResult()
        for (index, id) in canonical.ids.enumerated() { result.ranks[id] = ranks[index] }
        result.selfLoops = canonical.selfLoops
        result.reversedEdges = canonical.edgePair.indices.filter {
            canonical.edgePair[$0] >= 0 && reversedPairs.contains(canonical.edgePair[$0])
        }
        return result
    }
}
