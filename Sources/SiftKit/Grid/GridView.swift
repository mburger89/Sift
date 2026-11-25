import Foundation
import MetalUI
import SiftCore

/// What a relation's "Rows" tab shows: the toolbar (filters and search), the table, the value inspector and the
/// status bar, over one `GridModel` the session keeps per relation.
struct GridView: Component {
    let session: DatabaseSession
    let relation: RelationInfo
    /// The zone times are shown in: the cells' timestamps and the "Changes since" time.
    var timeZone: TimeZone = .current

    var content: some ElementGroup {
        if let grid = session.grid(for: relation.id) {
            GridContent(grid: grid, timeZone: timeZone).equatable()
        } else {
            Text(Self.unavailable(session.state)).foregroundColor(.secondary)
                .padding(Edges(all: Pixels(16)))
                .accessibilityIdentifier("grid.unavailable")
        }
    }

    static func unavailable(_ state: DatabaseSession.State) -> String {
        state == .ready ? "This source cannot show rows." : "Rows are shown when the connection is back."
    }
}

/// The parts of the grid, each its own component so a page arriving rebuilds the table and nothing around it.
struct GridContent: Component, Equatable {
    let grid: GridModel
    var timeZone: TimeZone = .current
    nonisolated static func == (l: Self, r: Self) -> Bool { l.grid === r.grid && l.timeZone == r.timeZone }

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: 0) {
            GridToolbar(grid: grid).equatable()
            Divider()
            HStack(spacing: 0) {
                GridTable(grid: grid, timeZone: timeZone).equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ValueInspector(grid: grid).equatable()
                    .frame(width: Pixels(300))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            GridStatusBar(grid: grid, timeZone: timeZone).equatable()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("grid")
    }
}

/// The comparator a sortable column's header carries. The server sorts: `compare` is never asked.
struct GridColumnSort: SortComparator, Hashable {
    typealias Compared = GridRowRef
    var column: Int
    var order: SortOrder = .forward

    func compare(_ lhs: GridRowRef, _ rhs: GridRowRef) -> ComparisonResult { .orderedSame }
}

/// Which reveal of which grid the table last saw.
struct RevealToken: Hashable {
    let grid: ObjectIdentifier
    let count: Int
    /// Whether the requested row exists yet. MetalUI drops a `scrollTo` past the row count, so a reveal into a count
    /// that is still the placeholder must run again when the real one lands.
    let reachable: Bool
}

/// The table: a frozen row-number column, then one column per source column, over `GridModel.rows`.
///
/// The first declared column is "#", so a data column's cell-mode coordinate is its index plus one.
struct GridTable: Component, Equatable {
    /// How many times `content` has run, for the cost pins (debug builds only).
    @MainActor static var bodyCount = 0

    let grid: GridModel
    var timeZone: TimeZone = .current

    nonisolated static func == (l: Self, r: Self) -> Bool { l.grid === r.grid && l.timeZone == r.timeZone }

    var content: some ElementGroup {
        // The cells read pages through `value(row:column:)`; this read is what redraws them when a page lands.
        // swiftlint:disable:next redundant_discardable_let - result builder: `_ = x` is not valid
        let _ = Self.countBody()
        // swiftlint:disable:next redundant_discardable_let - result builder: `_ = x` is not valid
        let _ = grid.pagesVersion
        let grid = grid
        let columns = grid.columns
        let timeZone = timeZone
        let linkColumns = Self.linkColumns(grid)
        ScrollViewReader { proxy in
        Table(grid.rows, selection: Self.selection(grid), sortOrder: Self.sortOrder(grid)) {
            TableColumn("#") { (row: GridRowRef) in
                Text(verbatim: "\(row.ordinal + 1)").font(size: 12).foregroundColor(.secondary)
                    .accessibilityIdentifier("grid.row.\(row.ordinal)")
            }
            .width(Pixels(64))
            .alignment(.trailing)
            TableColumnForEach(0..<columns.count) { c in
                if columns[c].isSortable {
                    TableColumn(columns[c].name, sortUsing: GridColumnSort(column: c)) { (row: GridRowRef) in
                        Self.cell(grid, columns, row, c, timeZone, linkColumns)
                    }
                    .width(min: Pixels(60), ideal: Pixels(160), max: Pixels(600))
                    .alignment(CellFormat.alignment(for: columns[c]) == .trailing ? .trailing : .leading)
                } else {
                    TableColumn(columns[c].name) { (row: GridRowRef) in
                        Self.cell(grid, columns, row, c, timeZone, linkColumns)
                    }
                    .width(min: Pixels(60), ideal: Pixels(160), max: Pixels(600))
                    .alignment(CellFormat.alignment(for: columns[c]) == .trailing ? .trailing : .leading)
                }
            }
        }
        .tableRowHeight(Pixels(24))
        .tableFrozenColumns(1)
        .tableRowIndex { $0 }
        .tableActiveCell(Self.activeCell(grid))
        .tableCellBackground { cell in Self.fill(grid, cell) }
        .copyable(Self.copied(grid))
        .accessibilityIdentifier("grid.table")
        .contextMenu(
            forSelectionType: Int.self,
            menu: { (rows: Set<Int>) in
                for link in Self.menuLinks(grid, rows) {
                    Button(link.title) { if let follow = link.follow { grid.onFollow?(follow) } }
                        .disabled(link.follow == nil)
                        .accessibilityIdentifier("grid.menu.link.\(link.outgoing ? "out" : "in").\(link.foreignKey.id)")
                }
            },
            primaryAction: { _ in Self.followActiveCell(grid) }
        )
        // The grid asks to show a cell (a follow, Back): the proxy is only reachable here.
        // The token names the grid as well as the count: this table sits in one place for every relation, and a
        // count alone is equal across two grids. `initial` covers a table that was just mounted (Structure and back).
        .onChange(of: RevealToken(
            grid: ObjectIdentifier(grid), count: grid.revealCount,
            reachable: grid.revealRequest.map { $0.row < grid.count.value } ?? false), initial: true) {
            guard let p = grid.revealRequest, grid.activePosition == p else { return }
            proxy.scrollTo(TableCell(row: p.row, column: p.column + 1), anchor: .center)
        }
        }
    }

    @MainActor
    // swiftlint:disable:next function_parameter_count - positional per-cell inputs, built once per cell
    static func cell(
        _ grid: GridModel, _ columns: [ResultColumn], _ row: GridRowRef, _ c: Int, _ timeZone: TimeZone, _ linkColumns: Set<Int>
    ) -> GridCell {
        let id = "grid.cell.\(row.ordinal).\(c)"
        let mark = Self.cellMark(grid.mark(row: row.ordinal), column: c)
        guard let value = grid.value(row: row.ordinal, column: c) else { return GridCell(text: nil, id: id, mark: mark) }
        return GridCell(
            text: CellFormat.format(value, column: columns[c], timeZone: timeZone), id: id, mark: mark, isLink: linkColumns.contains(c))
    }

    /// The columns that draw in the link colour: those of an outgoing foreign key.
    @MainActor
    static func linkColumns(_ grid: GridModel) -> Set<Int> { grid.links?.outgoingColumns ?? [] }

    /// The links of the row a context menu opened on: one row only. Several rows, or none, offer no items.
    @MainActor
    static func menuLinks(_ grid: GridModel, _ rows: Set<Int>) -> [ReferenceLink] {
        guard rows.count == 1, let row = rows.first, let links = grid.links else { return [] }
        return links.links(row: row) { grid.value(row: row, column: $0) }
    }

    /// Return, or a double click, on a key cell: follows the active cell's key. Anything else does nothing.
    @MainActor
    static func followActiveCell(_ grid: GridModel) {
        guard let active = grid.activePosition, active.column >= 0, let links = grid.links else { return }
        let row = active.row
        guard let follow = links.primaryFollow(row: row, column: active.column, value: { grid.value(row: row, column: $0) })
        else { return }
        grid.onFollow?(follow)
    }

    /// The accessibility mark of data column `c` under its row's mark.
    static func cellMark(_ mark: RowMark?, column c: Int) -> CellMark? {
        switch mark {
        case nil: nil
        case .newOrChanged?: .newRow
        case .changed(let cells)?: cells.contains(c) ? .cell : .row
        }
    }

    /// The tint of a table cell (`tableCellBackground`). `cell.column` counts the frozen "#" column, so data column `c`
    /// is `cell.column - 1`. It reads only `GridModel.mark(row:)`, never observed state, and draws no animation: a
    /// fade would redraw every realised cell every frame.
    @MainActor
    static func fill(_ grid: GridModel, _ cell: TableCell<Int>) -> Color? {
        grid.noteFillRead()
        guard let mark = grid.mark(row: cell.row) else { return nil }
        if case .changed(let cells) = mark, cells.contains(cell.column - 1) { return Color(ChangeCellFill.self) }
        return Color(ChangeRowFill.self)
    }

    @MainActor
    static func selection(_ grid: GridModel) -> Binding<Int?> {
        Binding(get: { grid.selectedRow }, set: { grid.selectedRow = $0 })
    }

    @MainActor
    static func sortOrder(_ grid: GridModel) -> Binding<[GridColumnSort]> {
        Binding(
            get: {
                grid.query.sort.map { [GridColumnSort(column: $0.column, order: $0.ascending ? .forward : .reverse)] } ?? []
            },
            set: { order in
                var next = grid.query
                next.sort = order.first.map { GridSort(column: $0.column, ascending: $0.order == .forward) }
                grid.apply(next)
            })
    }

    @MainActor
    static func activeCell(_ grid: GridModel) -> Binding<TableCell<Int>?> {
        Binding(
            get: { grid.activePosition.map { TableCell(row: $0.row, column: $0.column + 1) } },
            set: { cell in grid.activePosition = cell.map { GridPosition(row: $0.row, column: $0.column - 1) } })
    }

    /// What ⌘C copies: the active cell's raw text, nothing cut. Nothing when there is no active cell.
    @MainActor
    static func copied(_ grid: GridModel) -> [String] {
        guard let position = grid.activePosition else { return [] }
        if position.column < 0 { return [String(position.row + 1)] }
        return [grid.value(row: position.row, column: position.column).map(CellFormat.rawText) ?? ""]
    }
}

extension GridTable {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}
