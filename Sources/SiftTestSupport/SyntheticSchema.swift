import SiftCore

/// A deterministic, large schema for cost pins and (later) the map's benchmarks.
///
/// SplitMix64 from `seed`, five schemas (`s0`..`s4`, tables dealt round-robin), foreign-key targets
/// drawn from a power law (a few hub tables), about 5% self-references, twenty join tables (two
/// foreign keys each) and three cycles. The same arguments always give the same snapshot.
public enum SyntheticSchema {
    struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    }

    public static func make(tables: Int, foreignKeys: Int, seed: UInt64) -> SchemaSnapshot {
        var rng = SplitMix64(state: seed)
        let schemaNames = (0..<5).map { "s\($0)" }
        func id(_ i: Int) -> RelationID { RelationID(schemaNames[i % 5], "t\(pad4(i))") }

        var extraColumns = [[String]](repeating: [], count: tables)
        var edges: [(from: Int, to: Int)] = []
        func addEdge(_ from: Int, _ to: Int) {
            edges.append((from, to))
            extraColumns[from].append("ref\(extraColumns[from].count)_id")
        }

        // Join tables: the last twenty, each pointing at two distinct earlier tables.
        let joinCount = min(20, max(tables / 4, 0))
        for j in 0..<joinCount where tables > joinCount + 1 {
            let from = tables - 1 - j
            let a = rng.below(tables - joinCount)
            var b = rng.below(tables - joinCount)
            if b == a { b = (b + 1) % (tables - joinCount) }
            addEdge(from, a)
            addEdge(from, b)
        }
        // A few cycles among the first tables.
        if tables >= 6 && foreignKeys >= edges.count + 6 {
            addEdge(0, 1); addEdge(1, 2); addEdge(2, 0)
            addEdge(3, 4); addEdge(4, 5); addEdge(5, 3)
        }
        // The rest: power-law targets, about 5% pointing back at their own table.
        while edges.count < foreignKeys && tables > 1 {
            let from = rng.below(tables - joinCount > 0 ? tables - joinCount : tables)
            let to: Int
            if rng.unit() < 0.05 {
                to = from
            } else {
                let u = rng.unit()
                to = min(tables - 1, Int(Double(tables) * u * u * u))
            }
            addEdge(from, to)
        }

        let relations = (0..<tables).map { i -> RelationInfo in
            var columns = [ColumnInfo(name: "id", ordinal: 1, typeName: "bigint", isNullable: false)]
            for (n, name) in extraColumns[i].enumerated() {
                columns.append(ColumnInfo(name: name, ordinal: 2 + n, typeName: "bigint"))
            }
            columns.append(ColumnInfo(name: "label", ordinal: columns.count + 1, typeName: "text"))
            return RelationInfo(
                id: id(i), kind: .table, oid: UInt32(16_384 + i), rowEstimate: .estimated(Int64(rng.below(1_000_000))),
                columns: columns, primaryKey: KeyConstraint(name: "t\(pad4(i))_pkey", columns: ["id"]))
        }
        var seen: [Int: Int] = [:]
        let keys = edges.map { edge -> ForeignKeyInfo in
            let n = seen[edge.from, default: 0]
            seen[edge.from] = n + 1
            return ForeignKeyInfo(
                name: "t\(pad4(edge.from))_ref\(n)_fkey", from: id(edge.from), fromColumns: ["ref\(n)_id"],
                to: id(edge.to), toColumns: ["id"])
        }
        return SchemaSnapshot(serverVersion: 170_000, schemas: schemaNames, relations: relations, foreignKeys: keys)
    }
}

/// A number as at least four digits, so names sort in numeric order.
private func pad4(_ n: Int) -> String {
    let digits = String(n)
    return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
}
