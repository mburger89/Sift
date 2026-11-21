import MetalUI
import SiftCore

/// One row above the grid: the filter chips and the form that adds one, and the search field.
///
/// A chip is (column, operator, value). Chips are ANDed. The search runs on Return, never per keystroke, and ⌘F
/// (`Modifiers.primary` + F) focuses its field.
struct GridToolbar: Component, Equatable {
    /// How many times `content` has run, for the cost pins (debug builds only).
    @MainActor static var bodyCount = 0

    let grid: GridModel
    nonisolated static func == (l: Self, r: Self) -> Bool { l.grid === r.grid }
    @FocusState private var searchFocused: Bool

    var content: some ElementGroup {
        let _ = Self.countBody()
        let grid = grid
        HStack(spacing: Pixels(8)) {
            ForEach(Array(grid.query.filters.enumerated()), id: \.offset) { index, filter in
                HStack(spacing: Pixels(4)) {
                    Text(grid.chipTitle(filter)).font(size: 12)
                        .accessibilityLabel(grid.chipTitle(filter))
                        .accessibilityIdentifier("grid.chip.\(index)")
                    Button("\u{00D7}") { grid.removeFilter(at: index) }
                        .accessibilityLabel("Remove filter")
                        .accessibilityIdentifier("grid.chip.\(index).remove")
                }
                .padding(inset(8, 3))
                .background(.surfaceSecondary)
                .cornerRadius(Pixels(10))
            }
            ForEach(Array(grid.rejectedFilters.enumerated()), id: \.offset) { index, filter in
                HStack(spacing: Pixels(4)) {
                    Text(grid.chipTitle(filter)).font(size: 12).foregroundColor(.red)
                        .accessibilityLabel(grid.chipTitle(filter))
                        .accessibilityValue(grid.error ?? "")
                        .accessibilityIdentifier("grid.chip.rejected.\(index)")
                    Button("\u{00D7}") { grid.dismissRejectedFilters() }
                        .accessibilityLabel("Dismiss")
                        .accessibilityIdentifier("grid.chip.rejected.\(index).remove")
                }
                .padding(inset(8, 3))
                .roundedBorder(.red, radius: Pixels(10), width: Pixels(1))
            }
            Picker("Column", selection: Binding(get: { grid.draftColumn }, set: { grid.draftColumn = $0 })) {
                ForEach(0..<grid.columns.count, id: \.self) { c in
                    Text(verbatim: grid.columns[c].name).tag(c)
                }
            }
            .accessibilityIdentifier("grid.filter.column")
            Picker("Operator", selection: Binding(get: { grid.draftOp }, set: { grid.draftOp = $0 })) {
                ForEach(FilterOp.allCases, id: \.self) { op in
                    Text(verbatim: op.title).tag(op)
                }
            }
            .accessibilityIdentifier("grid.filter.op")
            if grid.draftOp.takesValue {
                TextField("Value", text: Binding(get: { grid.draftValue }, set: { grid.draftValue = $0 }))
                    .onSubmit { grid.addDraftFilter() }
                    .frame(width: Pixels(140))
                    .accessibilityIdentifier("grid.filter.value")
            }
            Button("Add filter") { grid.addDraftFilter() }
                .accessibilityIdentifier("grid.filter.add")
            Spacer()
            TextField("Search", text: Binding(get: { grid.searchText }, set: { grid.searchText = $0 }))
                .focused($searchFocused)
                .onSubmit { grid.submitSearch() }
                .frame(width: Pixels(200))
                .accessibilityIdentifier("grid.search")
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f")
                .accessibilityIdentifier("grid.find")
        }
        .padding(inset(12, 6))
        // A fixed height: the table under it must not change size when a field's text (the font's line height) changes.
        .frame(maxWidth: .infinity, minHeight: Pixels(40), maxHeight: Pixels(40))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("grid.toolbar")
    }
}

extension GridToolbar {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}
