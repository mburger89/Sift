import MetalUI
import SiftCore

/// A table or view: the header with its row count, then two tabs: the rows in the grid, or the structure (columns,
/// keys and indexes).
/// There is no editing UI: nothing here writes to the database.
struct RelationDetailView: Component {
    let model: AppModel
    let key: ConnectionKey
    let id: RelationID

    var content: some ElementGroup {
        if let session = model.sessions[key], let relation = session.snapshot?.relation(id) {
            VStack(alignment: .leading, spacing: 0) {
                ConnectionBanner(model: model, key: key)
                RelationHeader(session: session, relation: relation)
                Picker("Tab", selection: Binding(get: { model.relationTab }, set: { model.relationTab = $0 })) {
                    Text("Rows").tag(RelationTab.rows)
                    Text("Structure").tag(RelationTab.structure)
                }
                .pickerStyle(.segmented)
                .frame(width: Pixels(220))
                .padding(inset(16, 4))
                .accessibilityIdentifier("detail.tabs")
                if model.relationTab == .structure {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Pixels(16)) {
                            ColumnsSection(relation: relation)
                            KeysSection(model: model, key: key, snapshot: session.snapshot, relation: relation)
                            IndexesSection(relation: relation)
                        }
                        .padding(Edges(all: Pixels(16)))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GridView(session: session, relation: relation)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Pixels(8)) {
                ConnectionBanner(model: model, key: key)
                Text(id.name).font(size: 20).accessibilityIdentifier("detail.title")
                Text(model.sessions[key] == nil ? "Not connected." : "This table is not in the current schema.")
                    .foregroundColor(.secondary)
            }
            .padding(Edges(all: Pixels(16)))
        }
    }
}

/// The name, kind, the read-only badge, and the row count with its button.
struct RelationHeader: Component {
    let session: DatabaseSession
    let relation: RelationInfo

    var content: some ElementGroup {
        let id = relation.id
        let count = session.exactCounts[id]
        VStack(alignment: .leading, spacing: Pixels(6)) {
            HStack(spacing: Pixels(10)) {
                Text(id.name).font(size: 20).accessibilityLabel(id.name).accessibilityIdentifier("detail.title")
                if session.readOnly {
                    Text("Read-only").font(size: 11).foregroundColor(.secondary)
                        .padding(inset(6, 2))
                        .accessibilityIdentifier("detail.readOnly")
                }
            }
            HStack(spacing: Pixels(10)) {
                Text("\(relation.kind.displayName) in \(id.schema)").font(size: 12).foregroundColor(.secondary)
                Text(Self.countText(relation, count)).font(size: 12)
                    .accessibilityLabel(Self.countText(relation, count))
                    .accessibilityIdentifier("detail.rowCount")
                if case .loading? = count {
                    Button("Cancel") { session.cancelCount() }
                } else {
                    Button("Count rows") { Task { @MainActor in await session.countExactly(id) } }
                }
            }
        }
        .padding(Edges(top: Pixels(16), right: Pixels(16), bottom: Pixels(4), left: Pixels(16)))
    }

    static func countText(_ relation: RelationInfo, _ count: Loadable<Int64>?) -> String {
        switch count {
        case .loaded(let n)?: return RowEstimate.exactText(n)
        case .loading?: return "counting…"
        case .failed(let message)?: return message
        case nil: return relation.rowEstimate.displayText
        }
    }
}
