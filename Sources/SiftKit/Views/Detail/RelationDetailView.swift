import MetalUI
import SiftCore

/// A table or view: the header with its row count, then the columns, keys and indexes, then the first rows.
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
                Divider()
                PreviewSection(session: session, relation: relation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Reads the first rows when a table is chosen (and again when the session is back after a loss).
            .task(id: LoadKey(id: id, ready: session.state == .ready)) { await session.loadRows(id) }
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

    struct LoadKey: Equatable {
        var id: RelationID
        var ready: Bool
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
