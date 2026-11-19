import MetalUI
import SiftCore

/// The indexes: name, columns and the method, with a partial index's predicate.
struct IndexesSection: Component {
    let relation: RelationInfo

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: Pixels(6)) {
            Text("Indexes").font(size: 13).foregroundColor(.secondary)
            if relation.indexes.isEmpty {
                Text("No indexes").font(size: 13).foregroundColor(.secondary)
            }
            for index in relation.indexes {
                VStack(alignment: .leading, spacing: Pixels(2)) {
                    Text(index.name).font(size: 13)
                    Text(Self.summary(index)).font(size: 12).foregroundColor(.secondary)
                }
            }
        }
    }

    static func summary(_ index: IndexInfo) -> String {
        var text = "\(index.method) (\(index.columns.joined(separator: ", ")))"
        if index.isPrimary { text += ", primary" } else if index.isUnique { text += ", unique" }
        if let predicate = index.predicate { text += ", where \(predicate)" }
        return text
    }
}
