/// The input graph in a form that does not depend on the order it was given in.
///
/// Nodes are sorted by id and renumbered densely (`0..<count`), so every later
/// stage can iterate plain arrays. Parallel edges collapse to one *pair*.
/// Edges that name an unknown node are ignored.
struct Canonical {
    /// Sorted, unique node ids; the dense index of a node is its position here.
    var ids: [Int]
    var widths: [Double]
    var heights: [Double]
    /// The unique, sorted (from, to) pairs between different nodes, in dense indexes.
    var pairs: [(from: Int, to: Int)]
    /// For each input edge: its index in `pairs`, or -1 for a self-loop or an ignored edge.
    var edgePair: [Int]
    /// The input edges that run from a node to itself, ascending.
    var selfLoops: [Int]

    init(_ graph: LayoutGraph) {
        let sorted = graph.nodes.sorted {
            ($0.id, $0.width, $0.height) < ($1.id, $1.width, $1.height)
        }
        var ids: [Int] = []
        var widths: [Double] = []
        var heights: [Double] = []
        for node in sorted where ids.last != node.id {
            ids.append(node.id)
            widths.append(node.width)
            heights.append(node.height)
        }
        self.ids = ids
        self.widths = widths
        self.heights = heights

        // Lookup only; nothing iterates this dictionary.
        var denseOf: [Int: Int] = [:]
        for (index, id) in ids.enumerated() { denseOf[id] = index }

        var keyed: [(from: Int, to: Int)?] = []
        var selfLoops: [Int] = []
        var found: [(from: Int, to: Int)] = []
        for (index, edge) in graph.edges.enumerated() {
            guard let from = denseOf[edge.from], let to = denseOf[edge.to] else {
                keyed.append(nil)
                continue
            }
            if from == to {
                selfLoops.append(index)
                keyed.append(nil)
            } else {
                keyed.append((from, to))
                found.append((from, to))
            }
        }
        found.sort { ($0.from, $0.to) < ($1.from, $1.to) }
        var pairs: [(from: Int, to: Int)] = []
        for pair in found where pairs.last.map({ $0 != (pair.from, pair.to) }) ?? true {
            pairs.append(pair)
        }
        let count = ids.count
        var pairIndex: [Int: Int] = [:]
        for (index, pair) in pairs.enumerated() { pairIndex[pair.from * count + pair.to] = index }
        self.pairs = pairs
        self.selfLoops = selfLoops
        self.edgePair = keyed.map { pair in
            pair.flatMap { pairIndex[$0.from * count + $0.to] } ?? -1
        }
    }
}
