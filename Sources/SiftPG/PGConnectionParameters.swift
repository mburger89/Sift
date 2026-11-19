import Foundation
import SiftCore

public enum PGSSLMode: String, Sendable, Codable {
    case disable, allow, prefer, require
    case verifyCA = "verify-ca"
    case verifyFull = "verify-full"
}

/// Where and how to connect. The description never contains the password.
public struct PGConnectionParameters: Sendable, Equatable, CustomStringConvertible {
    public var host: String
    public var port: Int
    public var database: String
    public var user: String
    public var password: Secret?
    public var sslMode: PGSSLMode
    public var connectTimeoutSeconds: Int
    public var applicationName: String
    /// Asks the server for `default_transaction_read_only=on` at startup (decision D5).
    public var readOnly: Bool

    public init(
        host: String, port: Int = 5432, database: String, user: String, password: Secret? = nil,
        sslMode: PGSSLMode = .prefer, connectTimeoutSeconds: Int = 5, applicationName: String = "Sift",
        readOnly: Bool = true
    ) {
        self.host = host
        self.port = port
        self.database = database
        self.user = user
        self.password = password
        self.sslMode = sslMode
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.applicationName = applicationName
        self.readOnly = readOnly
    }

    /// Parses `postgresql://user:password@host:port/db?sslmode=...`. Components are percent-decoded.
    public init(url: String) throws(PGError) {
        guard let c = URLComponents(string: url), let scheme = c.scheme,
            scheme == "postgresql" || scheme == "postgres"
        else { throw PGError("not a postgresql:// URL") }
        self.init(
            host: c.host ?? "localhost", port: c.port ?? 5432,
            database: String(c.path.dropFirst()).removingPercentEncoding ?? "",
            user: c.user ?? "postgres", password: c.password.map(Secret.init))
        if let mode = c.queryItems?.first(where: { $0.name == "sslmode" })?.value {
            guard let m = PGSSLMode(rawValue: mode) else { throw PGError("unknown sslmode") }
            sslMode = m
        }
    }

    /// The libpq keywords and values. This is the one place the password is revealed.
    public func keywordValues() -> [(String, String)] {
        var out: [(String, String)] = [
            ("host", host), ("port", String(port)), ("dbname", database), ("user", user),
            ("sslmode", sslMode.rawValue), ("connect_timeout", String(connectTimeoutSeconds)),
            ("application_name", applicationName),
        ]
        if let password { out.append(("password", password.reveal())) }
        if readOnly { out.append(("options", "-c default_transaction_read_only=on")) }
        return out
    }

    public var description: String {
        "\(user)@\(host):\(port)/\(database) sslmode=\(sslMode.rawValue)"
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.host == b.host && a.port == b.port && a.database == b.database && a.user == b.user
            && a.password == b.password && a.sslMode == b.sslMode
            && a.connectTimeoutSeconds == b.connectTimeoutSeconds
            && a.applicationName == b.applicationName && a.readOnly == b.readOnly
    }
}
