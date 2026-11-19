import MetalUI
import SiftCore

/// The column list as a `Grid`: name, type, nullability and the default.
struct ColumnsSection: Component {
    let relation: RelationInfo

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: Pixels(6)) {
            Text("Columns").font(size: 13).foregroundColor(.secondary)
            Grid(alignment: .leading, horizontalSpacing: Pixels(16), verticalSpacing: Pixels(4)) {
                for column in relation.columns {
                    GridRow {
                        Text(column.name).font(size: 13)
                        Text(column.typeName).font(size: 13).foregroundColor(.secondary)
                        Text(Self.notes(column)).font(size: 12).foregroundColor(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("columns")
        }
    }

    /// `not null`, the default, identity and generated, as one line.
    static func notes(_ column: ColumnInfo) -> String {
        var parts: [String] = []
        if !column.isNullable { parts.append("not null") }
        if let identity = column.identity { parts.append(identity == .always ? "identity always" : "identity by default") }
        if column.isGenerated { parts.append("generated") }
        if let expression = column.defaultExpression { parts.append("default \(expression)") }
        return parts.joined(separator: ", ")
    }
}
