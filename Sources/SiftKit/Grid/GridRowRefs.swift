/// One row of a grid: only its ordinal. The cells' values are read from the model by `(ordinal, column)`, so
/// a row is a cheap handle and a million of them cost nothing (MetalUI's `Table` reads only realised rows).
public struct GridRowRef: Identifiable, Hashable, Sendable {
    public let ordinal: Int
    public var id: Int { ordinal }

    public init(ordinal: Int) { self.ordinal = ordinal }
}

/// The rows `Table` reads: `count` handles. Every read is O(1) and touches no data.
public struct GridRowRefs: RandomAccessCollection, Sendable {
    public let count: Int

    public init(count: Int) { self.count = Swift.max(0, count) }

    public var startIndex: Int { 0 }
    public var endIndex: Int { count }

    public subscript(position: Int) -> GridRowRef { GridRowRef(ordinal: position) }
}
