import Foundation

/// Which connection a session or a tree node belongs to. A container is keyed by its **name**, which
/// survives the container being recreated (decision D7).
public enum ConnectionKey: Hashable, Sendable {
    case saved(UUID)
    case container(name: String)

    /// A stable string, used in accessibility identifiers.
    public var token: String {
        switch self {
        case .saved(let id): return "saved:\(id.uuidString)"
        case .container(let name): return "container:\(name)"
        }
    }
}

/// A value the UI is waiting for, has, or failed to get.
public enum Loadable<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    case failed(String)

    public var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}
