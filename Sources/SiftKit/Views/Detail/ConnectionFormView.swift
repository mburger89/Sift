import MetalUI

/// The saved-connection form, inline in the detail area because MetalUI has no `.sheet` (gap G2).
///
/// There is no password field: password entry is gated on MetalUI's `SecureField` (gap G1), and a plain
/// `TextField` is never used for a secret. Connections rely on trust auth, `.pgpass` or `PGPASSWORD`,
/// which libpq reads itself.
struct ConnectionFormView: Component {
    let model: AppModel
    let draft: ConnectionDraft

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: Pixels(10)) {
            Text(draft.editing == nil ? "New connection" : "Edit connection").font(size: 20)
                .accessibilityIdentifier("detail.title")
            field("Name", \.name, id: "form.name")
            field("Host", \.host, id: "form.host")
            field("Port", \.port, id: "form.port")
            field("Database", \.database, id: "form.database")
            field("User", \.user, id: "form.user")
            Picker("SSL mode", selection: Binding(get: { draft.sslMode }, set: { draft.sslMode = $0 })) {
                ForEach(ConnectionDraft.sslModes, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("form.ssl")
            Text("Password entry needs SecureField (MetalUI)").font(size: 12).foregroundColor(.secondary)
                .accessibilityIdentifier("form.passwordNote")
            if let problem = draft.problem {
                Text(problem).font(size: 12).foregroundColor(.secondary).accessibilityIdentifier("form.error")
            }
            HStack(spacing: Pixels(12)) {
                Button("Save") { model.saveDraft() }
                Button("Cancel") { model.cancelDraft() }
                if let editing = draft.editing {
                    Button("Delete") {
                        model.cancelDraft()
                        model.removeConnection(editing)
                    }
                }
            }
        }
        .padding(Edges(all: Pixels(16)))
    }

    @ElementBuilder
    private func field(_ title: String, _ keyPath: ReferenceWritableKeyPath<ConnectionDraft, String>, id: String) -> some ElementGroup {
        HStack(spacing: Pixels(12)) {
            Text(title).font(size: 12).foregroundColor(.secondary).frame(width: Pixels(90), alignment: .leading)
            TextField(title, text: Binding(get: { draft[keyPath: keyPath] }, set: { draft[keyPath: keyPath] = $0 }))
                .frame(width: Pixels(280))
                .accessibilityIdentifier(id)
        }
    }
}
