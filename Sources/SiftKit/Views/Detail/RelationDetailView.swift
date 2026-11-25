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
                RelationHeader(session: session, relation: relation).equatable()
                HStack(spacing: Pixels(12)) {
                    HistoryButtons(model: model).equatable()
                    Picker("Tab", selection: Binding(get: { model.relationTab }, set: { model.relationTab = $0 })) {
                        Text("Rows").tag(RelationTab.rows)
                        Text("Structure").tag(RelationTab.structure)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: Pixels(220))
                    .accessibilityIdentifier("detail.tabs")
                    Button("Query") { model.openQuery() }
                        .accessibilityIdentifier("detail.query")
                    Spacer()
                }
                .padding(inset(16, 4))
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
                HistoryButtons(model: model).equatable()
                Text(id.name).font(size: 20).accessibilityIdentifier("detail.title")
                Text(model.sessions[key] == nil ? "Not connected." : "This table is not in the current schema.")
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("detail.notice")
            }
            .padding(Edges(all: Pixels(16)))
        }
    }
}

/// ‹ and ›: back and forward through the relations visited. `==` is the model's identity: what the body reads of it
/// (`canGoBack`, `canGoForward`) is observed on its own, so a refresh or a keystroke in the grid does not rebuild it.
struct HistoryButtons: Component, Equatable {
    let model: AppModel
    nonisolated static func == (l: Self, r: Self) -> Bool { l.model === r.model }

    var content: some ElementGroup {
        HStack(spacing: Pixels(4)) {
            Button("‹") { model.goBack() }
                .disabled(!model.canGoBack)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("detail.back")
            Button("›") { model.goForward() }
                .disabled(!model.canGoForward)
                .accessibilityLabel("Forward")
                .accessibilityIdentifier("detail.forward")
        }
    }
}

/// The name, kind, the read-only badge, and the row count with its button.
///
/// **`.equatable()`**: a row selected or a key typed in the grid rebuilt the detail view, and with it this header. `==` is
/// the session's identity and the relation; what the body reads of the session (the exact count, the read-only badge) is
/// observed on its own and still rebuilds it.
struct RelationHeader: Component, Equatable {
    /// How many times `content` has run, for the cost pins (debug builds only).
    @MainActor static var bodyCount = 0

    let session: DatabaseSession
    let relation: RelationInfo
    nonisolated static func == (l: Self, r: Self) -> Bool { l.session === r.session && l.relation == r.relation }

    var content: some ElementGroup {
        // swiftlint:disable:next redundant_discardable_let - result builder: `_ = x` is not valid
        let _ = Self.countBody()
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

extension RelationHeader {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}
