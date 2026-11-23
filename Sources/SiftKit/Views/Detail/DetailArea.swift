import MetalUI

/// The area right of the sidebar: the form when it is open, else what the sidebar's selection names.
struct DetailArea: Component {
    let model: AppModel

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: 0) {
            if let draft = model.draft {
                ConnectionFormView(model: model, draft: draft)
            } else if model.detailMode == .query, let key = model.selection?.connection, let session = model.sessions[key] {
                QueryDetailView(model: model, key: key, session: session)
            } else if model.detailMode == .map, let key = model.selection?.connection,
                      let session = model.sessions[key], session.snapshot != nil {
                MapDetailView(model: model, key: key, session: session)
            } else if case .container(let name)? = model.selection {
                DiscoveredDetailView(model: model, name: name)
            } else if case .saved(let id)? = model.selection {
                SavedConnectionDetailView(model: model, id: id)
            } else if case .relation(let key, let id)? = model.selection {
                RelationDetailView(model: model, key: key, id: id)
            } else if case .schema(let key, let schema)? = model.selection {
                SchemaDetailView(model: model, key: key, schema: schema)
            } else {
                EmptyDetailView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Nothing selected: say what to do.
struct EmptyDetailView: Component {
    let model: AppModel

    var content: some ElementGroup {
        VStack(spacing: Pixels(8)) {
            Text("Select a connection").font(size: 15).foregroundColor(.secondary)
            Text("Saved connections and Postgres containers are in the sidebar. Open a group to see them.")
                .font(size: 12).foregroundColor(.secondary)
            if let problem = model.storageProblem {
                Text(problem).font(size: 12).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A schema node: its table count.
struct SchemaDetailView: Component {
    let model: AppModel
    let key: ConnectionKey
    let schema: String

    var content: some ElementGroup {
        let count = model.sessions[key]?.snapshot?.relations.filter { $0.id.schema == schema }.count ?? 0
        VStack(alignment: .leading, spacing: Pixels(8)) {
            ConnectionBanner(model: model, key: key)
            Text(schema).font(size: 20).accessibilityIdentifier("detail.title")
            Text("\(count) tables and views").foregroundColor(.secondary)
        }
        .padding(Edges(all: Pixels(16)))
    }
}

/// A labelled line of the detail: a caption, then the value.
struct DetailLine: Component {
    let caption: String
    let value: String
    var identifier: String?

    var content: some ElementGroup {
        HStack(alignment: .firstTextBaseline, spacing: Pixels(12)) {
            Text(caption).font(size: 12).foregroundColor(.secondary).frame(width: Pixels(90), alignment: .leading)
            if let identifier {
                Text(value).font(size: 13).accessibilityLabel(value).accessibilityIdentifier(identifier)
            } else {
                Text(value).font(size: 13)
            }
        }
    }
}
