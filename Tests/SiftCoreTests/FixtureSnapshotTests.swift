import SiftCore
import SiftTestSupport
import Testing

@Suite struct FixtureSnapshotTests {
    @Test func shopSnapshotHasTheFixtureShape() {
        let s = FixtureSnapshot.shop()
        #expect(s.relations.count == 13)
        // The plan says 9, but its DDL has 8 foreign keys (partition clones are hidden).
        #expect(s.foreignKeys.count == 8)
        let employees = RelationID("shop", "employees")
        #expect(s.outgoing(of: employees).map(\.to) == [employees])
        #expect(s.incoming(of: RelationID("shop", "customers")).map(\.from.name) == ["events", "orders"])
    }

    @Test func schemaNamesAreParameters() {
        let s = FixtureSnapshot.shop(schemaA: "x", schemaB: "y")
        #expect(Set(s.relations.map(\.id.schema)) == ["x", "y"])
        #expect(s.relation(RelationID("y", "tags")) != nil)
    }
}

@Suite struct ManualClockTests {
    @Test func advanceWakesOnlyDueSleepers() async throws {
        let clock = ManualClock()
        let woke = Flag()
        let task = Task {
            try await clock.sleep(seconds: 2)
            await woke.set()
        }
        await clock.waitForSleepers(1)
        await clock.advance(by: 1)
        await Task.yield()
        #expect(await woke.value == false)
        await clock.advance(by: 1)
        try await task.value
        #expect(await woke.value == true)
        #expect(await clock.sleeps == [2])
    }

    @Test func cancellationEndsTheSleep() async {
        let clock = ManualClock()
        let task = Task { try await clock.sleep(seconds: 5) }
        await clock.waitForSleepers(1)
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    private actor Flag {
        var value = false
        func set() { value = true }
    }
}
