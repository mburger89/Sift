import Foundation
import MetalUI

/// A saved connection: its fields, Connect, Edit and Delete.
struct SavedConnectionDetailView: Component {
    let model: AppModel
    let id: UUID

    var content: some ElementGroup {
        let key = ConnectionKey.saved(id)
        if let connection = model.connections.first(where: { $0.id == id }) {
            let session = model.sessions[key]
            VStack(alignment: .leading, spacing: Pixels(10)) {
                ConnectionBanner(model: model, key: key)
                Text(connection.name).font(size: 20).accessibilityIdentifier("detail.title")
                DetailLine(caption: "Host", value: "\(connection.host):\(connection.port)")
                DetailLine(caption: "Database", value: connection.database)
                DetailLine(caption: "User", value: connection.user)
                DetailLine(caption: "SSL", value: connection.sslMode)
                Text("The password comes from the server's trust setting, .pgpass or PGPASSWORD.")
                    .font(size: 12).foregroundColor(.secondary)
                HStack(spacing: Pixels(12)) {
                    Button("Connect") { Task { @MainActor in await model.open(key) } }
                        .disabled(DiscoveredDetailView.isBusy(session))
                    Button("Edit") { model.beginEditing(id) }
                    Button("Delete") { model.removeConnection(id) }
                }
            }
            .padding(Edges(all: Pixels(16)))
        } else {
            Text("This connection was deleted.").foregroundColor(.secondary).padding(Edges(all: Pixels(16)))
        }
    }
}
