import MetalUI
import SiftDocker

/// A discovered Postgres container: what Sift found, and a Connect button. The password is never shown.
struct DiscoveredDetailView: Component {
    let model: AppModel
    let name: String

    var content: some ElementGroup {
        let key = ConnectionKey.container(name: name)
        if let database = model.discovered.first(where: { $0.containerName == name }) {
            let reason = Self.unavailableReason(database)
            let session = model.sessions[key]
            VStack(alignment: .leading, spacing: Pixels(10)) {
                ConnectionBanner(model: model, key: key)
                Text(name).font(size: 20).accessibilityIdentifier("detail.title")
                DetailLine(caption: "Image", value: database.image)
                DetailLine(caption: "Engine", value: Self.engineName(database.engine))
                DetailLine(caption: "Address", value: Self.address(database))
                DetailLine(caption: "User", value: database.user)
                DetailLine(caption: "Database", value: database.database)
                // The password is never drawn: only where it came from.
                DetailLine(caption: "Password", value: Self.passwordText(database), identifier: "discovered.password")
                HStack(spacing: Pixels(12)) {
                    Button("Connect") { Task { @MainActor in await model.open(key) } }
                        .disabled(reason != nil || Self.isBusy(session))
                    if let reason {
                        Text(reason).font(size: 12).foregroundColor(.secondary).accessibilityIdentifier("discovered.reason")
                    } else if let session, session.state == .ready {
                        Text("Connected, read-only").font(size: 12).foregroundColor(.secondary)
                    }
                }
            }
            .padding(Edges(all: Pixels(16)))
        } else {
            VStack(alignment: .leading, spacing: Pixels(8)) {
                Text(name).font(size: 20).accessibilityIdentifier("detail.title")
                Text("This container is no longer running or was removed.").foregroundColor(.secondary)
            }
            .padding(Edges(all: Pixels(16)))
        }
    }

    static func isBusy(_ session: DatabaseSession?) -> Bool {
        switch session?.state {
        case .connecting?, .ready?, .reconnecting?, .lost?: return true
        default: return false
        }
    }

    /// Why Connect is unavailable, or nil.
    static func unavailableReason(_ database: DiscoveredDatabase) -> String? {
        if !database.isRunning { return "The container is not running" }
        if database.route == .unreachable || database.host == nil || database.port == nil { return "5432 not published" }
        return nil
    }

    static func address(_ database: DiscoveredDatabase) -> String {
        guard let host = database.host, let port = database.port else { return "5432 not published" }
        return "\(host):\(port)"
    }

    static func engineName(_ engine: DockerEngine) -> String {
        switch engine {
        case .orbStack: return "OrbStack"
        case .dockerDesktop: return "Docker Desktop"
        case .other: return "Docker"
        }
    }

    static func passwordText(_ database: DiscoveredDatabase) -> String {
        switch database.passwordSource {
        case .containerEnv: return database.password == nil ? "none set" : "from container env, hidden"
        case .file: return "in a file in the container (not read)"
        case .none: return "none needed (trust)"
        }
    }
}
