import Foundation
import SiftCore
import SiftDocker

/// A node's identity: by **name** (decision D7), never by OID, so a recreated container keeps its selection.
public enum SidebarNodeID: Hashable, Sendable {
    case savedRoot
    case containersRoot
    case saved(UUID)
    case container(name: String)
    case containersProblem
    case schema(ConnectionKey, String)
    case relation(ConnectionKey, RelationID)

    /// A stable string for accessibility identifiers (`sidebar.<token>`).
    public var token: String {
        switch self {
        case .savedRoot: return "saved-root"
        case .containersRoot: return "containers-root"
        case .saved(let id): return ConnectionKey.saved(id).token
        case .container(let name): return ConnectionKey.container(name: name).token
        case .containersProblem: return "containers-problem"
        case .schema(let key, let schema): return "schema:\(key.token):\(schema)"
        case .relation(let key, let id): return "relation:\(key.token):\(id.qualifiedName)"
        }
    }

    /// The connection a node belongs to, if any.
    public var connection: ConnectionKey? {
        switch self {
        case .saved(let id): return .saved(id)
        case .container(let name): return .container(name: name)
        case .schema(let key, _), .relation(let key, _): return key
        default: return nil
        }
    }
}

/// One row of the sidebar's outline.
public struct SidebarNode: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case root, savedConnection, container, problem, schema, table, view
    }

    public var id: SidebarNodeID
    public var title: String
    public var subtitle: String?
    public var kind: Kind
    /// `nil` for a leaf; an empty array is still a group (the outline shows a chevron).
    public var children: [SidebarNode]?

    public init(id: SidebarNodeID, title: String, subtitle: String? = nil, kind: Kind, children: [SidebarNode]? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.children = children
    }
}

/// Builds the sidebar's tree from the model's state. Pure.
public enum SidebarTree {
    @MainActor
    public static func build(
        connections: [SavedConnection], discovered: [DiscoveredDatabase], discoveryProblem: String?,
        discoveryProblemDetail: String? = nil, sessions: [ConnectionKey: DatabaseSession]
    ) -> [SidebarNode] {
        let saved = connections.map { connection in
            let key = ConnectionKey.saved(connection.id)
            return SidebarNode(
                id: .saved(connection.id), title: connection.name,
                subtitle: "\(connection.host):\(connection.port)", kind: .savedConnection,
                children: schemaNodes(key: key, session: sessions[key]))
        }
        var containers: [SidebarNode]
        if discovered.isEmpty, let discoveryProblem {
            containers = [SidebarNode(id: .containersProblem, title: discoveryProblem, subtitle: discoveryProblemDetail, kind: .problem)]
        } else {
            containers = discovered.map { database in
                let key = ConnectionKey.container(name: database.containerName)
                return SidebarNode(
                    id: .container(name: database.containerName), title: database.containerName,
                    subtitle: database.isRunning ? database.image : "\(database.image) (stopped)", kind: .container,
                    children: schemaNodes(key: key, session: sessions[key]))
            }
        }
        return [
            SidebarNode(id: .savedRoot, title: "Saved", kind: .root, children: saved),
            SidebarNode(id: .containersRoot, title: "Containers", kind: .root, children: containers),
        ]
    }

    /// Schemas of a connected session: each holds its tables, then its views (alphabetically within each).
    @MainActor
    static func schemaNodes(key: ConnectionKey, session: DatabaseSession?) -> [SidebarNode]? {
        guard let snapshot = session?.snapshot else { return nil }
        return snapshot.schemas.compactMap { schema in
            let inSchema = snapshot.relations.filter { $0.id.schema == schema }
            guard !inSchema.isEmpty else { return nil }
            func node(_ relation: RelationInfo) -> SidebarNode {
                SidebarNode(
                    id: .relation(key, relation.id), title: relation.id.name, kind: isTable(relation.kind) ? .table : .view)
            }
            let tables = inSchema.filter { isTable($0.kind) }.map(node)
            let views = inSchema.filter { !isTable($0.kind) }.map(node)
            return SidebarNode(id: .schema(key, schema), title: schema, kind: .schema, children: tables + views)
        }
    }

    private static func isTable(_ kind: RelationKind) -> Bool {
        kind == .table || kind == .partitionedTable || kind == .foreignTable
    }
}
