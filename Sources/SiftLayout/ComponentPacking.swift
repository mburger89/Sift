/// Shelf packing of the laid-out components.
enum ComponentPacking {
    /// The top-left offset of each box, in the order given (callers pass the largest first).
    /// Boxes fill a row until the next one would pass the target width, then start a new row.
    /// The target width is that of a square-ish arrangement stretched by `targetAspect`,
    /// and never narrower than the widest box.
    static func pack(
        sizes: [(width: Double, height: Double)], gap: Double, targetAspect: Double
    ) -> [LayoutPoint] {
        let area = sizes.reduce(0) { $0 + $1.width * $1.height }
        let widest = sizes.reduce(0) { max($0, $1.width) }
        let target = max(widest, (area * targetAspect).squareRoot())
        var offsets: [LayoutPoint] = []
        var x = 0.0
        var y = 0.0
        var rowHeight = 0.0
        for size in sizes {
            if x > 0 && x + size.width > target {
                y += rowHeight + gap
                x = 0
                rowHeight = 0
            }
            offsets.append(LayoutPoint(x: x, y: y))
            x += size.width + gap
            rowHeight = max(rowHeight, size.height)
        }
        return offsets
    }
}
