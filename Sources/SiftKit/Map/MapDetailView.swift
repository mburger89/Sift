import MetalUI
import SiftCore

/// The detail area of a connected database in Map mode: the connection banner, then the map.
struct MapDetailView: Component {
    let model: AppModel
    let key: ConnectionKey
    let session: DatabaseSession
    @FocusState private var searchFocused: Bool

    var content: some ElementGroup {
        let map = model.map(for: key)
        VStack(alignment: .leading, spacing: 0) {
            ConnectionBanner(model: model, key: key)
            MapToolbar(model: model, map: map, focus: $searchFocused)
            SchemaMapView(model: model, map: map, key: key)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Lays the schema out when it arrives, and again when a reconnect or a refresh reads a new one.
        .task(id: LoadKey(version: session.snapshotVersion, ready: session.snapshot != nil)) {
            guard let snapshot = session.snapshot, let identity = session.mapIdentity else { return }
            await map.load(snapshot: snapshot, identity: identity)
        }
    }

    struct LoadKey: Equatable {
        var version: Int
        var ready: Bool
    }
}
