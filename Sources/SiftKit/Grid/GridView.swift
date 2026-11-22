import Foundation
import MetalUI
import SiftCore

/// What a relation's "Rows" tab shows: the toolbar (filters and search), the table, the value inspector and the
/// status bar, over one `GridModel` the session keeps per relation.
struct GridView: Component {
    let session: DatabaseSession
    let relation: RelationInfo

    var content: some ElementGroup {
        if let grid = session.grid(for: relation.id) {
            GridContent(grid: grid).equatable()
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
    nonisolated static func == (l: Self, r: Self) -> Bool { l.grid === r.grid }

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: 0) {
            GridToolbar(grid: grid).equatable()
            Divider()
            HStack(spacing: 0) {
                GridTable(grid: grid).equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ValueInspector(grid: grid).equatable()
                    .frame(width: Pixels(300))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            GridStatusBar(grid: grid).equatable()
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
        let _ = Self.countBody()
        let _ = grid.pagesVersion
        let grid = grid
        let columns = grid.columns
        let timeZone = timeZone
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
                        Self.cell(grid, columns, row, c, timeZone)
                    }
                    .width(min: Pixels(60), ideal: Pixels(160), max: Pixels(600))
                    .alignment(CellFormat.alignment(for: columns[c]) == .trailing ? .trailing : .leading)
                } else {
                    TableColumn(columns[c].name) { (row: GridRowRef) in
                        Self.cell(grid, columns, row, c, timeZone)
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
        .copyable(Self.copied(grid))
        .accessibilityIdentifier("grid.table")
    }

    @MainActor
    static func cell(_ grid: GridModel, _ columns: [ResultColumn], _ row: GridRowRef, _ c: Int, _ timeZone: TimeZone) -> GridCell {
        let id = "grid.cell.\(row.ordinal).\(c)"
        guard let value = grid.value(row: row.ordinal, column: c) else { return GridCell(text: nil, id: id) }
        return GridCell(text: CellFormat.format(value, column: columns[c], timeZone: timeZone), id: id)
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
