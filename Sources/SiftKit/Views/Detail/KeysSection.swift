import MetalUI
import SiftCore

/// The primary key, unique constraints, and foreign keys both ways. A foreign key is a button that selects
/// the other table (the sidebar does not reveal its row: gap G4).
struct KeysSection: Component {
    let model: AppModel
    let key: ConnectionKey
    let snapshot: SchemaSnapshot?
    let relation: RelationInfo

    var content: some ElementGroup {
        let id = relation.id
        let outgoing = snapshot?.outgoing(of: id) ?? []
        let incoming = snapshot?.incoming(of: id) ?? []
        VStack(alignment: .leading, spacing: Pixels(6)) {
            Text("Keys").font(size: 13).foregroundColor(.secondary)
            if let primary = relation.primaryKey {
                Text("Primary key: \(primary.columns.joined(separator: ", "))").font(size: 13)
            }
            for unique in relation.uniqueConstraints {
                Text("Unique \(unique.name): \(unique.columns.joined(separator: ", "))").font(size: 13)
            }
            if !outgoing.isEmpty {
                Text("References").font(size: 12).foregroundColor(.secondary)
                for foreignKey in outgoing {
                    Button(Self.outgoingTitle(foreignKey)) { model.select(foreignKey.to, in: key) }
                }
            }
            if !incoming.isEmpty {
                Text("Referenced by").font(size: 12).foregroundColor(.secondary)
                for foreignKey in incoming {
                    Button(Self.incomingTitle(foreignKey)) { model.select(foreignKey.from, in: key) }
                }
            }
        }
    }

    /// `customer_id → customers.id` (the schema is named only when it differs).
    static func outgoingTitle(_ foreignKey: ForeignKeyInfo) -> String {
        let target = foreignKey.to.schema == foreignKey.from.schema ? foreignKey.to.name : foreignKey.to.qualifiedName
        return "\(foreignKey.fromColumns.joined(separator: ", ")) → \(target).\(foreignKey.toColumns.joined(separator: ", "))"
    }

    /// `orders.customer_id`.
    static func incomingTitle(_ foreignKey: ForeignKeyInfo) -> String {
        let source = foreignKey.from.schema == foreignKey.to.schema ? foreignKey.from.name : foreignKey.from.qualifiedName
        return "\(source).\(foreignKey.fromColumns.joined(separator: ", "))"
    }
}
