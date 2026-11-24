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
        for table in ["customers", "products", "orders", "order_items", "shipments", "employees", "product_tags", "events", "customer_totals", "\"Weird \"\"Name\"\"\"", "notes", "codes", "code_uses"] {
            _ = try admin.query("ANALYZE \(names.a).\(table)")
        }
        _ = try admin.query("ANALYZE \(names.b).tags")
        // Created after ANALYZE on purpose: its row estimate stays unknown.
        for statement in ddl(a: names.a, b: names.b).after { _ = try admin.query(statement) }
        return try await body(names, readOnly)
    }

    /// Creates one throwaway schema of tables for paging tests, runs `body` with read-only parameters, then drops it.
    ///
    /// - `big`: 20 000 rows, `id` primary key, `label` text, `n` int.
    /// - `nokey`: 1 300 rows, no key and no unique index (`ctid` paging), `a` int, `b` text.
    /// - `typed`: a jsonb, an enum, a uuid and a timestamptz column.
    /// - `sparse`: 1 000 rows with a nullable sort column `k` (every tenth is NULL).
    /// - `special`: rows whose text holds `%`, `_`, `\\` and `'`.
    /// - `sleepy`: a view that sleeps 30 seconds when read.
    public static func withGridSchema<T>(
        _ body: (String, PGConnectionParameters) async throws -> T
    ) async throws -> T {
        guard let url else { throw PGError("SIFT_PG_URL is not set") }
        let readOnly = try PGConnectionParameters(url: url)
        var writable = readOnly
        writable.readOnly = false
        writable.applicationName = "Sift grid fixture"
        let hex = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        let schema = "sift_gr_\(hex)"
        let admin = try PGConnection(parameters: writable)
        _ = try admin.query("SET client_min_messages = warning")
        defer { _ = try? admin.query("DROP SCHEMA IF EXISTS \(schema) CASCADE") }
        for statement in gridDDL(schema) { _ = try admin.query(statement) }
        for table in ["big", "nokey", "typed", "sparse", "special"] { _ = try admin.query("ANALYZE \(schema).\(table)") }
        return try await body(schema, readOnly)
    }

    static func gridDDL(_ s: String) -> [String] {
        [
            "CREATE SCHEMA \(s)",
            "CREATE TABLE \(s).big (id int PRIMARY KEY, label text NOT NULL, n int NOT NULL)",
            "INSERT INTO \(s).big SELECT i, 'row-' || i, i % 7 FROM generate_series(1, 20000) i",
            "CREATE TABLE \(s).nokey (a int, b text)",
            "INSERT INTO \(s).nokey SELECT i % 50, 'b' || i FROM generate_series(1, 1300) i",
            "CREATE TYPE \(s).mood AS ENUM ('sad', 'ok', 'happy')",
            """
            CREATE TABLE \(s).typed (
              id int PRIMARY KEY, doc jsonb, mood \(s).mood, uid uuid, at timestamptz, tags int[], price numeric(24,4))
            """,
            """
            INSERT INTO \(s).typed VALUES
              (1, '{"a": [1, 2, {"b": null}], "c": "x"}', 'ok', '00000000-0000-0000-0000-00000000000a',
               '2026-11-21 10:00:00+00', '{1,2,3}', 12345678901234.5678),
              (2, NULL, 'happy', NULL, NULL, NULL, NULL)
            """,
            "CREATE TABLE \(s).sparse (id int PRIMARY KEY, k int)",
            "INSERT INTO \(s).sparse SELECT i, CASE WHEN i % 10 = 0 THEN NULL ELSE i % 100 END FROM generate_series(1, 1000) i",
            "CREATE TABLE \(s).special (id int PRIMARY KEY, s text)",
            """
            INSERT INTO \(s).special VALUES (1, 'a%b'), (2, 'a_b'), (3, 'axb'), (4, 'it''s'), (5, '50%'), (6, 'x\\y'), (7, '$1')
            """,
            "CREATE VIEW \(s).sleepy AS SELECT x FROM generate_series(1, 1) x, pg_sleep(30)",
        ]
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
            "CREATE TABLE \(a).notes (id serial PRIMARY KEY, body text, created_at timestamptz)",
            "CREATE TABLE \(a).codes (code bytea PRIMARY KEY, amount numeric(12,2) NOT NULL UNIQUE)",
            """
            CREATE TABLE \(a).code_uses (
              id serial PRIMARY KEY, code bytea REFERENCES \(a).codes,
              amount numeric(12,2) REFERENCES \(a).codes (amount))
            """,
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
            """
            INSERT INTO \(a).notes (body, created_at) VALUES
              ('older', '2026-02-01 09:00:00+00'), ('oldest', '2026-01-01 09:00:00+00'),
              ('newest', '2026-03-01 09:00:00+00'), ('undated 1', NULL), ('undated 2', NULL), ('undated 3', NULL)
            """,
            // A binary key with a zero byte and 0xff, and a numeric key with a trailing zero.
            "INSERT INTO \(a).codes VALUES ('\\x00ff41'::bytea, 10.50), ('\\x01'::bytea, 2.00)",
            "INSERT INTO \(a).code_uses (code, amount) VALUES ('\\x00ff41'::bytea, 10.50)",
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
