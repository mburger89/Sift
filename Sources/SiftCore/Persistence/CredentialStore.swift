import Foundation

/// Which saved connection a password belongs to.
public struct CredentialKey: Hashable, Sendable {
    public var connectionID: UUID

    public init(connectionID: UUID) { self.connectionID = connectionID }
}

/// Where passwords live. Version 1 ships `InMemoryCredentialStore` only; the OS stores are deferred
/// (plan section 12).
public protocol CredentialStore: Sendable {
    func password(for key: CredentialKey) -> Secret?
    func setPassword(_ password: Secret, for key: CredentialKey)
    func removePassword(for key: CredentialKey)
}

/// Passwords for the life of the process, never written anywhere.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [CredentialKey: Secret] = [:]

    public init() {}

    public func password(for key: CredentialKey) -> Secret? { lock.withLock { passwords[key] } }

    public func setPassword(_ password: Secret, for key: CredentialKey) {
        lock.withLock { passwords[key] = password }
    }

    public func removePassword(for key: CredentialKey) {
        lock.withLock { _ = passwords.removeValue(forKey: key) }
    }
}
