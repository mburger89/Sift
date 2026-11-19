import Foundation
import SiftCore
import SiftPG

/// The two schema names of one fixture run.
public struct FixtureNames: Sendable {
    public var a: String
    public var b: String
}

/// The integration fixture: a throwaway pair of schemas in the server named by `SIFT_PG_URL`.
/// This is the only place Sift opens a writable connection.
public enum PGFixture {
    public static let url: String? = {
        guard let v = ProcessInfo.processInfo.environment["SIFT_PG_URL"], !v.isEmpty else { return nil }
        return v
    }()

    /// Creates the schemas with a writable test-only connection, runs `body` with **read-only**
    /// parameters (so the app path is what is under test), then drops both schemas.
    public static func withSchemas<T>(
        _ body: (FixtureNames, PGConnectionParameters) async throws -> T
    ) async throws -> T {
        guard let url else { throw PGError("SIFT_PG_URL is not set") }
        let readOnly = try PGConnectionParameters(url: url)
        var writable = readOnly
        writable.readOnly = false
        writable.applicationName = "Sift fixture"

        let hex = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        let names = FixtureNames(a: "sift_fx_\(hex)", b: "sift_fx_\(hex)_b")
        let admin = try PGConnection(parameters: writable)
        _ = try admin.query("SET client_min_messages = warning")
        defer {
            _ = try? admin.query("DROP SCHEMA IF EXISTS \(names.a) CASCADE")
            _ = try? admin.query("DROP SCHEMA IF EXISTS \(names.b) CASCADE")
        }
        for statement in ddl(a: names.a, b: names.b).before { _ = try admin.query(statement) }
        for table in ["customers", "products", "orders", "order_items", "shipments", "employees", "product_tags", "events", "customer_totals", "\"Weird \"\"Name\"\"\""] {
            _ = try admin.query("ANALYZE \(names.a).\(table)")
        }
        _ = try admin.query("ANALYZE \(names.b).tags")
        // Created after ANALYZE on purpose: its row estimate stays unknown.
        for statement in ddl(a: names.a, b: names.b).after { _ = try admin.query(statement) }
        return try await body(names, readOnly)
    }

    /// The fixture statements, one per element (libpq cannot run several in one parameterised call).
    public static func ddl(a: String, b: String) -> (before: [String], after: [String]) {
        let before = [
            "CREATE SCHEMA \(a)",
            "CREATE SCHEMA \(b)",
            "CREATE TABLE \(b).tags (id serial PRIMARY KEY, label text UNIQUE)",
            "CREATE TYPE \(a).order_status AS ENUM ('new', 'paid', 'done')",
            """
            CREATE TABLE \(a).customers (
              id bigserial PRIMARY KEY, email text NOT NULL UNIQUE,
              created_at timestamptz NOT NULL DEFAULT now(), legacy text)
            """,
            "ALTER TABLE \(a).customers DROP COLUMN legacy",
            """
            CREATE TABLE \(a).products (
              id uuid PRIMARY KEY, name varchar(200) NOT NULL, tags text[], price numeric(12,2))
            """,
            "CREATE INDEX products_lower_name_idx ON \(a).products (lower(name))",
            """
            CREATE TABLE \(a).orders (
              id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
              customer_id bigint NOT NULL REFERENCES \(a).customers ON DELETE CASCADE,
              status \(a).order_status NOT NULL DEFAULT 'new',
              total numeric(12,2),
              total_cents bigint GENERATED ALWAYS AS ((total * 100)::bigint) STORED)
            """,
            "CREATE INDEX orders_open_idx ON \(a).orders (customer_id) WHERE status <> 'done'",
            """
            CREATE TABLE \(a).order_items (
              order_id bigint REFERENCES \(a).orders, product_id uuid REFERENCES \(a).products,
              qty int NOT NULL, PRIMARY KEY (product_id, order_id))
            """,
            """
            CREATE TABLE \(a).shipments (
              id serial PRIMARY KEY, order_id bigint NOT NULL, product_id uuid NOT NULL,
              FOREIGN KEY (product_id, order_id) REFERENCES \(a).order_items (product_id, order_id))
            """,
            "CREATE TABLE \(a).employees (id serial PRIMARY KEY, manager_id int REFERENCES \(a).employees)",
            """
            CREATE TABLE \(a).product_tags (
              product_id uuid REFERENCES \(a).products, tag_id int REFERENCES \(b).tags,
              PRIMARY KEY (product_id, tag_id))
            """,
            """
            CREATE TABLE \(a).events (
              id bigint, customer_id bigint REFERENCES \(a).customers, at timestamptz NOT NULL,
              PRIMARY KEY (id, at)) PARTITION BY RANGE (at)
            """,
            "CREATE TABLE \(a).events_2025 PARTITION OF \(a).events FOR VALUES FROM ('2025-01-01') TO ('2026-01-01')",
            "CREATE TABLE \(a).events_2026 PARTITION OF \(a).events FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')",
            "CREATE TABLE \(a).\"Weird \"\"Name\"\"\" (id int PRIMARY KEY)",
            "INSERT INTO \(b).tags (label) VALUES ('red'), ('blue')",
            "INSERT INTO \(a).customers (email) VALUES ('a@x.test'), ('b@x.test'), ('c@x.test')",
            """
            INSERT INTO \(a).products VALUES
              ('00000000-0000-0000-0000-000000000001', 'Pen', '{office}', 1.50),
              ('00000000-0000-0000-0000-000000000002', 'Ink', NULL, 4.00)
            """,
            "INSERT INTO \(a).orders (customer_id, total) VALUES (1, 10), (1, 20), (2, 30), (3, 40)",
            """
            INSERT INTO \(a).order_items VALUES
              (1, '00000000-0000-0000-0000-000000000001', 2),
              (2, '00000000-0000-0000-0000-000000000002', 1),
              (3, '00000000-0000-0000-0000-000000000001', 5)
            """,
            "INSERT INTO \(a).shipments (order_id, product_id) VALUES (1, '00000000-0000-0000-0000-000000000001')",
            "INSERT INTO \(a).employees (manager_id) VALUES (NULL), (1)",
            "CREATE VIEW \(a).recent_orders AS SELECT id, customer_id FROM \(a).orders",
            """
            CREATE MATERIALIZED VIEW \(a).customer_totals AS
              SELECT customer_id, sum(total) AS total FROM \(a).orders GROUP BY customer_id
            """,
        ]
        let after = ["CREATE TABLE \(a).never_analyzed (id int)"]
        return (before, after)
    }
}
