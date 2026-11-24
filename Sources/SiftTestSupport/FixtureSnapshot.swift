import SiftCore

/// The schema snapshot of the integration fixture, built by hand. It mirrors the
/// fixture DDL (plan section 6, task B4); the live introspection test proves the
/// two agree, with OIDs and estimates zeroed.
public enum FixtureSnapshot {
    /// 13 relations (partitions are hidden) and 8 foreign keys. With `withPagerTables`, the three tables the live
    /// fixture also holds for pager tests (`notes`, `codes`, `code_uses`) and their 2 foreign keys: 16 and 10.
    /// The UI tests that lay out the shop leave them out.
    public static func shop(
        schemaA: String = "shop", schemaB: String = "tagging", withPagerTables: Bool = false
    ) -> SchemaSnapshot {
        let a = schemaA
        let b = schemaB
        func id(_ name: String) -> RelationID { RelationID(a, name) }

        func col(
            _ name: String, _ n: Int, _ type: String, null: Bool = true, def: String? = nil,
            identity: IdentityKind? = nil, generated: Bool = false, isEnum: Bool = false
        ) -> ColumnInfo {
            ColumnInfo(
                name: name, ordinal: n, typeName: type, isNullable: null, defaultExpression: def,
                identity: identity, isGenerated: generated, isEnum: isEnum)
        }
        // `pg_get_indexdef` qualifies the table with its schema (the fixture schema is not on the
        // search path), quotes a name only when it needs it, and writes `ON ONLY` for a
        // partitioned table.
        func q(_ name: String) -> String {
            name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" } && !(name.first?.isNumber ?? true)
                ? name : "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        func pkIndex(_ table: String, _ cols: [String], schema: String, only: Bool) -> IndexInfo {
            IndexInfo(
                name: "\(table)_pkey", columns: cols, isUnique: true, isPrimary: true, method: "btree",
                definition:
                    "CREATE UNIQUE INDEX \(q("\(table)_pkey")) ON \(only ? "ONLY " : "")\(schema).\(q(table)) USING btree (\(cols.joined(separator: ", ")))"
            )
        }
        func table(
            _ name: String, schema: String? = nil, kind: RelationKind = .table,
            estimate: RowEstimate = .estimated(0), columns: [ColumnInfo], pk: [String]? = nil,
            unique: [KeyConstraint] = [], indexes: [IndexInfo] = []
        ) -> RelationInfo {
            RelationInfo(
                id: RelationID(schema ?? a, name), kind: kind, rowEstimate: estimate, columns: columns,
                primaryKey: pk.map { KeyConstraint(name: "\(name)_pkey", columns: $0) },
                uniqueConstraints: unique,
                indexes: (pk.map { [pkIndex(name, $0, schema: schema ?? a, only: kind == .partitionedTable)] } ?? []) + indexes)
        }
        func fk(
            _ name: String, _ from: String, _ fromCols: [String], to: RelationID, _ toCols: [String],
            onDelete: ForeignKeyAction = .noAction
        ) -> ForeignKeyInfo {
            ForeignKeyInfo(
                name: name, from: id(from), fromColumns: fromCols, to: to, toColumns: toCols, onDelete: onDelete)
        }

        let tags = table(
            "tags", schema: b,
            columns: [col("id", 1, "integer", null: false, def: "nextval('\(b).tags_id_seq'::regclass)"), col("label", 2, "text")],
            pk: ["id"], unique: [KeyConstraint(name: "tags_label_key", columns: ["label"])],
            indexes: [
                IndexInfo(
                    name: "tags_label_key", columns: ["label"], isUnique: true, isPrimary: false, method: "btree",
                    definition: "CREATE UNIQUE INDEX tags_label_key ON \(b).tags USING btree (label)")
            ])
        let customers = table(
            "customers",
            columns: [
                col("id", 1, "bigint", null: false, def: "nextval('\(a).customers_id_seq'::regclass)"),
                col("email", 2, "text", null: false),
                col("created_at", 3, "timestamp with time zone", null: false, def: "now()"),
            ],
            pk: ["id"], unique: [KeyConstraint(name: "customers_email_key", columns: ["email"])],
            indexes: [
                IndexInfo(
                    name: "customers_email_key", columns: ["email"], isUnique: true, isPrimary: false, method: "btree",
                    definition: "CREATE UNIQUE INDEX customers_email_key ON \(a).customers USING btree (email)")
            ])
        let products = table(
            "products",
            columns: [
                col("id", 1, "uuid", null: false), col("name", 2, "character varying(200)", null: false),
                col("tags", 3, "text[]"), col("price", 4, "numeric(12,2)"),
            ],
            pk: ["id"],
            indexes: [
                IndexInfo(
                    name: "products_lower_name_idx", columns: ["lower(name::text)"], isUnique: false, isPrimary: false, method: "btree",
                    definition: "CREATE INDEX products_lower_name_idx ON \(a).products USING btree (lower((name)::text))")
            ])
        let orders = table(
            "orders",
            columns: [
                col("id", 1, "bigint", null: false, identity: .always),
                col("customer_id", 2, "bigint", null: false),
                col("status", 3, "\(a).order_status", null: false, def: "'new'::\(a).order_status", isEnum: true),
                col("total", 4, "numeric(12,2)"),
                col("total_cents", 5, "bigint", generated: true),
            ],
            pk: ["id"],
            indexes: [
                IndexInfo(
                    name: "orders_open_idx", columns: ["customer_id"], isUnique: false, isPrimary: false,
                    method: "btree", predicate: "(status <> 'done'::\(a).order_status)",
                    definition:
                        "CREATE INDEX orders_open_idx ON \(a).orders USING btree (customer_id) WHERE (status <> 'done'::\(a).order_status)")
            ])
        let orderItems = table(
            "order_items",
            columns: [
                col("order_id", 1, "bigint", null: false), col("product_id", 2, "uuid", null: false),
                col("qty", 3, "integer", null: false),
            ],
            pk: ["product_id", "order_id"])
        let shipments = table(
            "shipments",
            columns: [
                col("id", 1, "integer", null: false, def: "nextval('\(a).shipments_id_seq'::regclass)"),
                col("order_id", 2, "bigint", null: false), col("product_id", 3, "uuid", null: false),
            ],
            pk: ["id"])
        let employees = table(
            "employees",
            columns: [
                col("id", 1, "integer", null: false, def: "nextval('\(a).employees_id_seq'::regclass)"),
                col("manager_id", 2, "integer"),
            ],
            pk: ["id"])
        let productTags = table(
            "product_tags",
            columns: [col("product_id", 1, "uuid", null: false), col("tag_id", 2, "integer", null: false)],
            pk: ["product_id", "tag_id"])
        let events = table(
            "events", kind: .partitionedTable,
            columns: [
                col("id", 1, "bigint", null: false), col("customer_id", 2, "bigint"),
                col("at", 3, "timestamp with time zone", null: false),
            ],
            pk: ["id", "at"])
        let weird = table("Weird \"Name\"", columns: [col("id", 1, "integer", null: false)], pk: ["id"])
        let notes = table(
            "notes",
            columns: [
                col("id", 1, "integer", null: false, def: "nextval('\(a).notes_id_seq'::regclass)"),
                col("body", 2, "text"), col("created_at", 3, "timestamp with time zone"),
            ],
            pk: ["id"])
        let codes = table(
            "codes",
            columns: [col("code", 1, "bytea", null: false), col("amount", 2, "numeric(12,2)", null: false)],
            pk: ["code"], unique: [KeyConstraint(name: "codes_amount_key", columns: ["amount"])],
            indexes: [
                IndexInfo(
                    name: "codes_amount_key", columns: ["amount"], isUnique: true, isPrimary: false, method: "btree",
                    definition: "CREATE UNIQUE INDEX codes_amount_key ON \(a).codes USING btree (amount)")
            ])
        let codeUses = table(
            "code_uses",
            columns: [
                col("id", 1, "integer", null: false, def: "nextval('\(a).code_uses_id_seq'::regclass)"),
                col("code", 2, "bytea"), col("amount", 3, "numeric(12,2)"),
            ],
            pk: ["id"])
        let neverAnalyzed = table(
            "never_analyzed", estimate: .unknown, columns: [col("id", 1, "integer")])
        let recentOrders = table(
            "recent_orders", kind: .view, estimate: .unknown, columns: [col("id", 1, "bigint"), col("customer_id", 2, "bigint")])
        let customerTotals = table(
            "customer_totals", kind: .materializedView,
            columns: [col("customer_id", 1, "bigint"), col("total", 2, "numeric")])

        let pagerTables = withPagerTables ? [notes, codes, codeUses] : []
        let foreignKeys = [
            fk("orders_customer_id_fkey", "orders", ["customer_id"], to: id("customers"), ["id"], onDelete: .cascade),
            fk("order_items_order_id_fkey", "order_items", ["order_id"], to: id("orders"), ["id"]),
            fk("order_items_product_id_fkey", "order_items", ["product_id"], to: id("products"), ["id"]),
            fk(
                "shipments_product_id_order_id_fkey", "shipments", ["product_id", "order_id"],
                to: id("order_items"), ["product_id", "order_id"]),
            fk("employees_manager_id_fkey", "employees", ["manager_id"], to: id("employees"), ["id"]),
            fk("product_tags_product_id_fkey", "product_tags", ["product_id"], to: id("products"), ["id"]),
            fk("product_tags_tag_id_fkey", "product_tags", ["tag_id"], to: RelationID(b, "tags"), ["id"]),
            fk("events_customer_id_fkey", "events", ["customer_id"], to: id("customers"), ["id"]),
        ]
        let pagerForeignKeys =
            withPagerTables
            ? [
                fk("code_uses_code_fkey", "code_uses", ["code"], to: id("codes"), ["code"]),
                fk("code_uses_amount_fkey", "code_uses", ["amount"], to: id("codes"), ["amount"]),
            ] : []
        return SchemaSnapshot(
            serverVersion: 170000, schemas: [a, b],
            relations: [
                tags, customers, products, orders, orderItems, shipments, employees, productTags, events, weird,
                ] + pagerTables + [
                neverAnalyzed, recentOrders, customerTotals,
            ],
            foreignKeys: foreignKeys + pagerForeignKeys)
    }
}
