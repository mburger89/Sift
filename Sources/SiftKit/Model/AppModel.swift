import Foundation
import Observation
import SiftCore
import SiftDocker

/// What the detail area shows for a selected table. The map arrives with phase 2b.
public enum DetailMode: Sendable, Equatable {
    case table
}

/// The app's state, one `@Observable` class created in `main.swift` and handed to the views.
@MainActor
@Observable
public final class AppModel {
    public private(set) var connections: [SavedConnection] = []
    public private(set) var discovered: [DiscoveredDatabase] = []
    /// The title of why discovery found nothing ("Docker not found"), shown as a row, never thrown.
    public private(set) var discoveryProblem: String?
    public private(set) var discoveryProblemDetail: String?
    public private(set) var sessions: [ConnectionKey: DatabaseSession] = [:]
    /// What the sidebar has selected.
    public var selection: SidebarNodeID?
    public var detailMode: DetailMode = .table
    /// Why saved connections could not be read or written, if they could not.
    public private(set) var storageProblem: String?
    /// The form's fields while the inline connection form is open.
    public var draft: ConnectionDraft?

    @ObservationIgnored public let environment: SiftEnvironment
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?

    public init(environment: SiftEnvironment) {
        self.environment = environment
    }

    /// Reads the saved connections and looks for containers in the background.
    public func start() {
        do {
            connections = try environment.connections.load()
        } catch {
            storageProblem = "Saved connections could not be read"
        }
        discoveryTask = Task { [weak self] in await self?.refreshDiscovery() }
    }

    /// Asks Docker (or OrbStack) for Postgres containers again.
    public func refreshDiscovery() async {
        do {
            discovered = try await environment.discovery.listPostgresContainers()
            discoveryProblem = nil
            discoveryProblemDetail = nil
        } catch {
            discovered = []
            (discoveryProblem, discoveryProblemDetail) = Self.describe(discovery: error)
        }
    }

    /// Refresh (⌘R): looks for containers again and re-reads the schema of every open connection.
    public func refresh() async {
        await refreshDiscovery()
        for session in sessions.values.sorted(by: { $0.title < $1.title }) { await session.refreshSchema() }
    }

    static func describe(discovery error: any Error) -> (String, String?) {
        switch error as? DockerError {
        case .noEndpoint: return ("Docker not found", "No Docker or OrbStack socket was found")
        case .unsupportedScheme(let scheme): return ("Docker host not supported", "\(scheme) hosts are not supported")
        case .connectFailed, .timedOut: return ("Docker not reachable", "The Docker socket did not answer")
        default: return ("Docker did not answer as expected", nil)
        }
    }

    // MARK: Sessions

    /// The sidebar's rows.
    public var sidebarTree: [SidebarNode] {
        SidebarTree.build(
            connections: connections, discovered: discovered, discoveryProblem: discoveryProblem,
            discoveryProblemDetail: discoveryProblemDetail, sessions: sessions)
    }

    /// Connects to a saved connection or a container, unless it is already open.
    public func open(_ key: ConnectionKey) async {
        if let existing = sessions[key] {
            switch existing.state {
            case .failed, .stopped: break
            default: return
            }
        }
        guard let session = makeSession(for: key) else { return }
        sessions[key]?.close()
        sessions[key] = session
        await session.connect()
    }

    private func makeSession(for key: ConnectionKey) -> DatabaseSession? {
        let environment = environment
        switch key {
        case .saved(let id):
            guard let connection = connections.first(where: { $0.id == id }) else { return nil }
            return DatabaseSession(
                key: key, title: connection.name, connector: environment.connector, clock: environment.clock
            ) { _ in
                .saved(connection, password: environment.credentials.password(for: CredentialKey(connectionID: id)))
            }
        case .container(let name):
            guard let database = discovered.first(where: { $0.containerName == name }) else { return nil }
            return DatabaseSession(
                key: key, title: name, connector: environment.connector, clock: environment.clock
            ) { refreshing in
                guard refreshing else { return .discovered(database) }
                // A reconnect looks the container up again: it may have been recreated on another port.
                let found = try await environment.discovery.listPostgresContainers()
                guard let fresh = found.first(where: { $0.containerName == name }) else {
                    throw SourceError(.other, "Container \(name) was not found")
                }
                return .discovered(fresh)
            }
        }
    }

    /// The selected relation, looked up by name in the session's **current** snapshot (never by OID).
    public var selectedRelation: RelationInfo? {
        guard case .relation(let key, let id)? = selection else { return nil }
        return sessions[key]?.snapshot?.relation(id)
    }

    /// Selects a relation (a foreign key navigates here). The sidebar does not reveal the row (gap G4).
    public func select(_ relation: RelationID, in key: ConnectionKey) {
        selection = .relation(key, relation)
    }

    // MARK: Saved connections

    /// Adds or updates a saved connection. `password` is kept in memory only.
    public func addConnection(_ connection: SavedConnection, password: Secret?) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        if let password {
            environment.credentials.setPassword(password, for: CredentialKey(connectionID: connection.id))
        }
        persistConnections()
    }

    public func removeConnection(_ id: UUID) {
        connections.removeAll { $0.id == id }
        environment.credentials.removePassword(for: CredentialKey(connectionID: id))
        sessions[.saved(id)]?.close()
        sessions[.saved(id)] = nil
        if selection?.connection == .saved(id) { selection = nil }
        persistConnections()
    }

    /// Opens the inline form for a new connection (New Connection, ⌘N).
    public func beginNewConnection() { draft = ConnectionDraft() }

    /// Opens the inline form for an existing connection.
    public func beginEditing(_ id: UUID) {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        draft = ConnectionDraft(connection)
    }

    /// Saves the form's connection, selects it and closes the form; a refusal stays in `draft.problem`.
    public func saveDraft() {
        guard let draft else { return }
        switch draft.connection() {
        case .success(let connection):
            addConnection(connection, password: nil)
            selection = .saved(connection.id)
            self.draft = nil
        case .failure(let error):
            draft.problem = error.message
        }
    }

    public func cancelDraft() { draft = nil }

    private func persistConnections() {
        do {
            try environment.connections.save(connections)
            storageProblem = nil
        } catch {
            storageProblem = "Saved connections could not be written"
        }
    }
}
