import SiftLayout

/// A small deterministic generator (SplitMix64), so random graphs are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// `n` nodes (ids `0..<n`, widths 160...260, heights 60...300) and `e` random edges.
/// Cycles, self-loops and parallel edges are all possible.
func randomGraph(seed: UInt64, n: Int, e: Int) -> LayoutGraph {
    var rng = SplitMix64(seed: seed)
    let nodes = (0..<n).map { id in
        LayoutGraph.Node(
            id: id, width: Double(Int.random(in: 160...260, using: &rng)),
            height: Double(Int.random(in: 60...300, using: &rng)))
    }
    let edges = (0..<e).map { _ in
        LayoutGraph.Edge(from: Int.random(in: 0..<n, using: &rng), to: Int.random(in: 0..<n, using: &rng))
    }
    return LayoutGraph(nodes: nodes, edges: edges)
}

/// Default-sized nodes `0..<count` and the given edges.
func graph(_ count: Int, _ edges: [(Int, Int)]) -> LayoutGraph {
    LayoutGraph(
        nodes: (0..<count).map { LayoutGraph.Node(id: $0) },
        edges: edges.map { LayoutGraph.Edge(from: $0.0, to: $0.1) })
}

func point(_ x: Double, _ y: Double) -> LayoutPoint { LayoutPoint(x: x, y: y) }
