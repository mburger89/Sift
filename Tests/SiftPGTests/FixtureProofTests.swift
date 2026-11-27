import SiftCore
import SiftTestSupport
import Testing

@testable import SiftPG

@Suite struct FixtureProofTests {
    @Test(.enabled(if: PGFixture.url != nil, gate))
    func theHandBuiltSnapshotMatchesTheLiveFixture() async throws {
        try await withSnapshot { live, n in
            func normalised(_ s: SchemaSnapshot) -> SchemaSnapshot {
                SchemaSnapshot(
                    serverVersion: 0, schemas: s.schemas,
                    relations: s.relations.map { r in
                        var r = r
                        r.oid = 0
                        if case .estimated = r.rowEstimate { r.rowEstimate = .estimated(0) }
                        return r
                    },
                    foreignKeys: s.foreignKeys)
            }
            let expected = normalised(FixtureSnapshot.shop(schemaA: n.a, schemaB: n.b, withPagerTables: true))
            let actual = normalised(live)
            #expect(actual.schemas == expected.schemas)
            for r in expected.relations {
                #expect(actual.relation(r.id) == r, "relation \(r.id.qualifiedName)")
            }
            #expect(actual.relations.map(\.id) == expected.relations.map(\.id))
            #expect(actual.foreignKeys == expected.foreignKeys)
            #expect(actual == expected)
        }
    }
}
