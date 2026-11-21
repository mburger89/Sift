import Observation
import SiftCore

/// One open database: its state, schema snapshot, previews and counts, and the reconnect loop
/// (decision D14).
///
/// Everything the UI reads is `@Observable` state written on the main actor. The source's calls run
/// off it; a `connectionLost` answer (or a source that reports itself broken) moves the session to
/// `.lost` and starts retrying after 0.5, 1, 2 and 4 s, then every 5 s, through the injected clock.
/// Before each attempt on a container the target is resolved again, so a new port or password is used.
@Observable @MainActor
public final class DatabaseSession {
    public enum State: Equatable {
        case connecting
        case ready
        case lost(String)
        case reconnecting(attempt: Int)
        case failed(String)
        case stopped
    }

    /// Finds what to connect to. `refreshing` is true for a reconnect: a container is looked up again.
    public typealias TargetProvider = @Sendable (_ refreshing: Bool) async throws -> ConnectionTarget

    /// The preview shows this many rows (decision D16).
    public static let previewRowLimit = 100

    public let key: ConnectionKey
    public let title: String
    public private(set) var state: State = .connecting
    public private(set) var snapshot: SchemaSnapshot? {
        didSet { snapshotVersion += 1 }
    }
    /// Counts the snapshots installed: a cheap key for what depends on the schema (the map's layout).
    public private(set) var snapshotVersion = 0
    /// The database the session is (or was last) connected to: with the key, what a map's pins belong to.
    public private(set) var database: String?
    public private(set) var rows: [RelationID: Loadable<ResultPage>] = [:]
    public private(set) var exactCounts: [RelationID: Loadable<Int64>] = [:]
    /// Always true: every session Sift opens is read-only, and a server that will not enforce it is refused.
    public let readOnly = true

    @ObservationIgnored private let connector: any DatabaseConnecting
    @ObservationIgnored private let clock: any SiftClock
    @ObservationIgnored private let targetProvider: TargetProvider
    @ObservationIgnored private var source: (any DatabaseSource)?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// Bumped whenever a reconnect loop starts or ends, so a stale loop never installs its source.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var attempts = 0
    /// The grids opened on this session's source, by relation: a grid keeps its sort, filters and pages while the
    /// user looks at another tab. A new source (a reconnect) or a changed relation drops them.
    @ObservationIgnored private var grids: [RelationID: (model: GridModel, relation: RelationInfo)] = [:]

    public init(
        key: ConnectionKey, title: String, connector: any DatabaseConnecting, clock: any SiftClock,
        targetProvider: @escaping TargetProvider
    ) {
        self.key = key
        self.title = title
        self.connector = connector
        self.clock = clock
        self.targetProvider = targetProvider
    }

    /// What the map keys its remembered positions by: `saved:<uuid>:<db>` or `container:<name>:<db>` (decision D22).
    public var mapIdentity: String? { database.map { "\(key.token):\($0)" } }

    /// The seconds to wait before attempt number `attempt` (0-based): 0.5, 1, 2, 4, then 5.
    nonisolated static func backoff(attempt: Int) -> Double {
        let steps: [Double] = [0.5, 1, 2, 4]
        return attempt < steps.count ? steps[attempt] : 5
    }

    // MARK: Connecting

    /// Connects (or connects again after a failure) and loads the schema.
    public func connect() async {
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        attempts = 0
        state = .connecting
        do {
            let (opened, loaded) = try await open(refreshing: false)
            install(opened, loaded)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    private func open(refreshing: Bool) async throws -> (any DatabaseSource, SchemaSnapshot) {
        let target = try await targetProvider(refreshing)
        switch target {
        case .saved(let saved, _): database = saved.database
        case .discovered(let found): database = found.database
        }
        let opened = try await connector.connect(target)
        do {
            return (opened, try await opened.snapshot())
        } catch {
            opened.close()
            throw error
        }
    }

    private func install(_ opened: any DatabaseSource, _ loaded: SchemaSnapshot) {
        dropGrids()
        source?.close()
        source = opened
        snapshot = loaded
        state = .ready
    }

    // MARK: Reading

    // MARK: Grids

    /// The grid source for a relation: a connection of its own, so cancelling a grid's query never cancels the
    /// schema refresh. Nil when the session is not ready, the relation is unknown, or the source cannot page.
    public func gridSource(for id: RelationID) -> (any GridSource)? {
        guard let source, state == .ready, let relation = snapshot?.relation(id) else { return nil }
        return source.gridSource(for: relation)
    }

    /// The paged model of a relation, made at the first ask and kept.
    public func grid(for id: RelationID) -> GridModel? {
        if let existing = grids[id] { return existing.model }
        guard let relation = snapshot?.relation(id), let gridSource = gridSource(for: id) else { return nil }
        let model = GridModel(source: gridSource, clock: clock)
        if let current = source {
            model.onConnectionLost = { [weak self] error in _ = self?.noticeLoss(error, of: current) }
        }
        grids[id] = (model, relation)
        return model
    }

    private func dropGrids() {
        for (_, grid) in grids { grid.model.close() }
        grids = [:]
    }

    /// Loads the first rows of a relation. A relation already loaded is left alone unless `force`.
    public func loadRows(_ id: RelationID, force: Bool = false) async {
        guard let source, state == .ready else { return }
        if !force, rows[id] != nil { return }
        rows[id] = .loading
        do {
            rows[id] = .loaded(try await source.firstRows(of: id, limit: Self.previewRowLimit))
        } catch {
            if !noticeLoss(error, of: source) { rows[id] = .failed(Self.describe(error)) }
        }
    }

    /// Reads the schema again, and the previews that are showing: a table was added, or rows changed.
    public func refreshSchema() async {
        guard let source, state == .ready else { return }
        do {
            snapshot = try await source.snapshot()
        } catch {
            _ = noticeLoss(error, of: source)
            return
        }
        // A relation whose structure changed starts its grid again; the others keep theirs.
        for (id, grid) in grids where snapshot?.relation(id) != grid.relation {
            grid.model.close()
            grids[id] = nil
        }
        for id in rows.keys.sorted() { await loadRows(id, force: true) }
    }

    /// Counts a relation's rows exactly, in a read-only transaction. `cancelCount()` stops it.
    public func countExactly(_ id: RelationID) async {
        guard let source, state == .ready else { return }
        exactCounts[id] = .loading
        do {
            exactCounts[id] = .loaded(try await source.exactRowCount(of: id))
        } catch let error as SourceError where error.kind == .cancelled {
            exactCounts[id] = nil
        } catch {
            exactCounts[id] = nil
            if !noticeLoss(error, of: source) { exactCounts[id] = .failed(Self.describe(error)) }
        }
    }

    /// Asks the server to stop the count in flight.
    public func cancelCount() { source?.cancelCurrent() }

    // MARK: Losing the connection and getting it back

    /// Starts reconnecting if `error` says the connection is gone. Returns whether it did.
    private func noticeLoss(_ error: any Error, of failed: any DatabaseSource) -> Bool {
        let lost = (error as? SourceError)?.kind == .connectionLost || failed.isBroken
        guard lost, source === failed, state == .ready else { return lost }
        dropGrids()
        failed.close()
        source = nil
        state = .lost(Self.describe(error))
        startReconnecting(immediately: false)
        return true
    }

    private func startReconnecting(immediately: Bool) {
        generation += 1
        let mine = generation
        reconnectTask = Task { [weak self] in await self?.reconnectLoop(generation: mine, immediately: immediately) }
    }

    private func reconnectLoop(generation mine: Int, immediately: Bool) async {
        var skipSleep = immediately
        while generation == mine, !Task.isCancelled {
            if !skipSleep {
                do { try await clock.sleep(seconds: Self.backoff(attempt: attempts)) } catch { return }
            }
            skipSleep = false
            guard generation == mine, !Task.isCancelled else { return }
            if await attemptReconnect(generation: mine) { return }
        }
    }

    /// One reconnect attempt. Returns true when the loop is over: the session is back, or refused.
    private func attemptReconnect(generation mine: Int) async -> Bool {
        attempts += 1
        state = .reconnecting(attempt: attempts)
        do {
            let (opened, loaded) = try await open(refreshing: true)
            guard generation == mine, !Task.isCancelled else {
                opened.close()
                return true
            }
            install(opened, loaded)
            reconnectTask = nil
            await reloadRows()
            return true
        } catch {
            guard generation == mine, !Task.isCancelled else { return true }
            if (error as? SourceError)?.kind == .readOnlyNotEnforced {
                state = .failed(Self.describe(error))
                reconnectTask = nil
                return true
            }
            state = .lost(Self.describe(error))
            return false
        }
    }

    /// After a reconnect the previews that were showing are read again; the old rows may be stale.
    private func reloadRows() async {
        let shown = rows.keys.sorted()
        exactCounts = [:]
        for id in shown { await loadRows(id, force: true) }
    }

    /// Tries once now, instead of waiting for the next back-off step; the loop goes on if it fails.
    public func reconnectNow() async {
        guard case .lost = state else { return }
        reconnectTask?.cancel()
        generation += 1
        let mine = generation
        if await attemptReconnect(generation: mine) { return }
        reconnectTask = Task { [weak self] in await self?.reconnectLoop(generation: mine, immediately: false) }
    }

    /// Gives up reconnecting. The session stays in the sidebar, stopped.
    public func stopTrying() {
        switch state {
        case .lost, .reconnecting:
            generation += 1
            reconnectTask?.cancel()
            reconnectTask = nil
            state = .stopped
        default:
            break
        }
    }

    /// Closes the source and ends any retrying: the connection was removed or the app is quitting.
    public func close() {
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        dropGrids()
        source?.close()
        source = nil
        state = .stopped
    }

    // MARK: Messages

    /// What the user reads. Never contains a password: `SourceError` messages are built without one.
    nonisolated static func describe(_ error: any Error) -> String {
        if let error = error as? SourceError {
            switch error.kind {
            case .readOnlyNotEnforced:
                return "Sift refused this session: the server did not enforce a read-only session."
            default:
                return error.message
            }
        }
        return String(describing: error)
    }
}
