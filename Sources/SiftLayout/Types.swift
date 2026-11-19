/// A point in canvas units.
public struct LayoutPoint: Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rectangle in canvas units; `x` and `y` are the top-left corner.
public struct LayoutRect: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The input to the layered layout: sized nodes and directed edges between them.
///
/// An edge runs from the referencing table to the referenced one, so the
/// referenced tables end up to the right.
public struct LayoutGraph: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        public var id: Int
        public var width: Double
        public var height: Double

        public init(id: Int, width: Double = 200, height: Double = 100) {
            self.id = id
            self.width = width
            self.height = height
        }
    }

    public struct Edge: Sendable, Equatable {
        public var from: Int
        public var to: Int

        public init(from: Int, to: Int) {
            self.from = from
            self.to = to
        }
    }

    public var nodes: [Node]
    public var edges: [Edge]

    public init(nodes: [Node] = [], edges: [Edge] = []) {
        self.nodes = nodes
        self.edges = edges
    }
}

/// The knobs of the layout. Every value has a default that suits a schema map.
public struct LayoutOptions: Sendable, Equatable {
    /// The horizontal space between two adjacent ranks.
    public var layerGap = 120.0
    /// The smallest vertical space between two nodes in one rank.
    public var nodeGap = 40.0
    /// The space between two connected components.
    public var componentGap = 160.0
    /// The most barycenter sweeps (one down pass plus one up pass each) per component.
    public var sweeps = 24
    /// The number of alternating placement passes.
    public var placementPasses = 8
    /// The width-to-height ratio the packed components aim for.
    public var targetAspect = 1.6

    public init() {}
}

/// Counts that describe the work and the quality of one layout run.
public struct LayoutStats: Sendable, Equatable {
    public var components: Int
    public var dummyNodes: Int
    public var crossingsBefore: Int
    public var crossingsAfter: Int
    /// The most sweeps any one component ran.
    public var sweepsRun: Int

    public init(
        components: Int = 0, dummyNodes: Int = 0, crossingsBefore: Int = 0,
        crossingsAfter: Int = 0, sweepsRun: Int = 0
    ) {
        self.components = components
        self.dummyNodes = dummyNodes
        self.crossingsBefore = crossingsBefore
        self.crossingsAfter = crossingsAfter
        self.sweepsRun = sweepsRun
    }
}

/// The output of the layered layout.
public struct LayoutResult: Sendable, Equatable {
    /// The top-left corner of each node, keyed by node id.
    public var positions: [Int: LayoutPoint]
    /// The rank (column) of each node, keyed by node id.
    public var ranks: [Int: Int]
    /// The indexes (sorted) of the input edges that were reversed to break a cycle.
    public var reversedEdges: [Int]
    /// The indexes (sorted) of the input edges that run from a node to itself.
    public var selfLoops: [Int]
    /// The bend points of each edge, from its `from` node to its `to` node.
    /// There is one point per rank the edge spans without touching; self-loops have no entry.
    public var routes: [Int: [LayoutPoint]]
    /// The box that encloses every node and every route point.
    public var bounds: LayoutRect
    public var stats: LayoutStats

    public init(
        positions: [Int: LayoutPoint] = [:], ranks: [Int: Int] = [:],
        reversedEdges: [Int] = [], selfLoops: [Int] = [], routes: [Int: [LayoutPoint]] = [:],
        bounds: LayoutRect = LayoutRect(x: 0, y: 0, width: 0, height: 0),
        stats: LayoutStats = LayoutStats()
    ) {
        self.positions = positions
        self.ranks = ranks
        self.reversedEdges = reversedEdges
        self.selfLoops = selfLoops
        self.routes = routes
        self.bounds = bounds
        self.stats = stats
    }
}
