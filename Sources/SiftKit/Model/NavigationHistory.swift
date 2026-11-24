import SiftCore

/// A place the user was looking at: a relation, and the query and cursor of its grid when it had one.
public struct NavigationEntry: Equatable, Sendable {
    public var key: ConnectionKey
    public var relation: RelationID
    public var query: GridQuery?
    public var active: GridPosition?

    public init(key: ConnectionKey, relation: RelationID, query: GridQuery?, active: GridPosition?) {
        self.key = key
        self.relation = relation
        self.query = query
        self.active = active
    }
}

/// Back and forward over the places visited. Pure: the model decides when to push and how to restore.
public struct NavigationHistory: Sendable {
    public static let limit = 100
    private var backStack: [NavigationEntry] = []
    private var forwardStack: [NavigationEntry] = []

    public init() {}

    /// Records the place being left. A new push clears forward.
    public mutating func push(_ leaving: NavigationEntry) {
        backStack.append(leaving)
        if backStack.count > Self.limit { backStack.removeFirst(backStack.count - Self.limit) }
        forwardStack.removeAll()
    }

    /// The place to go back to, remembering `current` for forward.
    public mutating func back(from current: NavigationEntry) -> NavigationEntry? {
        guard let target = backStack.popLast() else { return nil }
        forwardStack.append(current)
        return target
    }

    public mutating func forward(from current: NavigationEntry) -> NavigationEntry? {
        guard let target = forwardStack.popLast() else { return nil }
        backStack.append(current)
        return target
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }
}
