import Foundation

/// The catalog queries, public so a reviewer can read them. Each runs on one read-only connection.
///
/// Multi-valued catalog fields (`conkey`, `confkey`) are `unnest(...) WITH ORDINALITY` into rows and
/// index columns come from `pg_get_indexdef(oid, k, true)`, so no Postgres array text is ever decoded
/// (decision D8). Everything that is not text is cast in SQL so the result decodes to a plain value.
///
/// Every query takes one parameter, `$1`: a text array literal of schema names, or NULL for every
/// visible schema (`PGCatalog.arrayLiteral`). Filtering in SQL keeps the catalog functions
/// (`pg_get_indexdef`, ...) from touching relations in schemas nobody asked for, which another
/// session may be dropping at that moment.
public enum PGCatalog {
    static let hiddenSchemas = #"""
        n.nspname NOT IN ('pg_catalog', 'information_schema')
        AND n.nspname NOT LIKE 'pg\_toast%' AND n.nspname NOT LIKE 'pg\_temp\_%'
        AND has_schema_privilege(n.oid, 'USAGE')
        AND ($1::text[] IS NULL OR n.nspname = ANY($1::text[]))
        """#

    /// A text-array literal for `$1`: `{"a","b"}` with `\` and `"` escaped.
    public static func arrayLiteral(_ names: [String]) -> String {
        "{" + names.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            .joined(separator: ",") + "}"
    }

    /// Relation kinds Sift lists. Partitions (`relispartition`) are hidden: the partitioned parent stands for them.
    static let listedRelations = "c.relkind IN ('r', 'p', 'v', 'm', 'f') AND NOT c.relispartition"

    /// Columns: schema.
    public static let schemas = """
        SELECT n.nspname::text FROM pg_namespace n WHERE \(hiddenSchemas) ORDER BY 1
        """

    /// Columns: schema, name, kind, oid, reltuples, comment. For a partitioned table `reltuples`
    /// is the sum over its leaf partitions (-1 when none has been analyzed).
    public static let relations = """
        SELECT n.nspname::text, c.relname::text, c.relkind::text, c.oid::int8,
          CASE WHEN c.relkind = 'p' THEN
            (SELECT CASE WHEN count(*) FILTER (WHERE l.reltuples >= 0) = 0 THEN -1
                         ELSE sum(greatest(l.reltuples, 0)) END
             FROM pg_partition_tree(c.oid) t JOIN pg_class l ON l.oid = t.relid WHERE t.isleaf)::float8
          ELSE c.reltuples::float8 END,
          obj_description(c.oid, 'pg_class')
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE \(hiddenSchemas) AND \(listedRelations)
        ORDER BY n.nspname, c.relname
        """

    /// Columns: schema, relation, ordinal, name, type (`format_type`), nullable, default, identity,
    /// generated, is enum, comment. The ordinal counts live columns, so a dropped column leaves no gap.
    public static let columns = """
        SELECT n.nspname::text, c.relname::text,
          (row_number() OVER (PARTITION BY a.attrelid ORDER BY a.attnum))::int4,
          a.attname::text, format_type(a.atttypid, a.atttypmod), NOT a.attnotnull,
          CASE WHEN a.attgenerated::text = '' THEN pg_get_expr(d.adbin, d.adrelid) END,
          a.attidentity::text, a.attgenerated::text <> '', t.typtype::text = 'e',
          col_description(c.oid, a.attnum::int4)
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_type t ON t.oid = a.atttypid
        LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE \(hiddenSchemas) AND \(listedRelations) AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY n.nspname, c.relname, a.attnum
        """

    /// One row per constraint column: schema, relation, constraint, type (p, u, f), position,
    /// column, referenced schema, referenced relation, referenced column, update action, delete action.
    /// Position comes from `ordinality`, never from `attnum`. `conparentid = 0` drops partition clones.
    public static let constraints = """
        SELECT n.nspname::text, c.relname::text, con.conname::text, con.contype::text, k.ord::int4,
          a.attname::text, fn.nspname::text, fc.relname::text, fa.attname::text,
          con.confupdtype::text, con.confdeltype::text
        FROM pg_constraint con
        JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        CROSS JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
        LEFT JOIN LATERAL unnest(con.confkey) WITH ORDINALITY AS fk(attnum, ord)
          ON con.contype = 'f' AND fk.ord = k.ord
        LEFT JOIN pg_class fc ON fc.oid = con.confrelid
        LEFT JOIN pg_namespace fn ON fn.oid = fc.relnamespace
        LEFT JOIN pg_attribute fa ON fa.attrelid = con.confrelid AND fa.attnum = fk.attnum
        WHERE con.contype IN ('p', 'u', 'f') AND con.conparentid = 0
          AND \(hiddenSchemas) AND \(listedRelations)
        ORDER BY n.nspname, c.relname, con.conname, k.ord
        """

    /// One row per index key column: schema, relation, index, unique, primary, method, definition,
    /// predicate, position, column definition (an expression for an expression column).
    public static let indexes = """
        SELECT n.nspname::text, c.relname::text, ic.relname::text, i.indisunique, i.indisprimary,
          am.amname::text, pg_get_indexdef(i.indexrelid), pg_get_expr(i.indpred, i.indrelid),
          k.n::int4, pg_get_indexdef(i.indexrelid, k.n, true)
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam
        CROSS JOIN LATERAL generate_series(1, i.indnkeyatts::int) AS k(n)
        WHERE \(hiddenSchemas) AND \(listedRelations)
        ORDER BY n.nspname, c.relname, i.indisprimary DESC, ic.relname, k.n
        """
}
