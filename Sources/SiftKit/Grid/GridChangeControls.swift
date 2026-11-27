import Foundation
import MetalUI
import SiftCore

/// The "Newest first" toggle and, when more than one column could say what is newest, the picker of that column.
/// Nothing at all for a relation with no such column. A component of its own, as the toolbar's builder is deep already.
struct NewestControl: Component, Equatable {
    let grid: GridModel
    nonisolated static func == (l: Self, r: Self) -> Bool { l.grid === r.grid }

    var content: some ElementGroup {
        let grid = grid
        if !grid.recencySorts.isEmpty {
            HStack(spacing: Pixels(6)) {
                Toggle("Newest first", isOn: Binding(get: { grid.isNewestFirst }, set: { grid.setNewestFirst($0) }))
                    .toggleStyle(.button)
                    .accessibilityValue(grid.isNewestFirst ? "on" : "off")
                    .accessibilityIdentifier("grid.newest")
                if grid.recencyColumns.count > 1 {
                    NewestColumnPicker(grid: grid).equatable()
                }
            }
        }
    }
}

/// The column "Newest first" sorts by, when there is more than one candidate. A component of its own, as
/// `DetailModePicker` is: an inline Picker among siblings overflows Windows' 1 MB test stack (G17).
struct NewestColumnPicker: Component, Equatable {
    let grid: GridModel
    nonisolated static func == (l: Self, r: Self) -> Bool { l.grid === r.grid }

    var content: some ElementGroup {
        let grid = grid
        if let current = grid.newestColumn ?? grid.recencyColumns.first {
            Picker("Newest by", selection: Binding(get: { grid.newestColumn ?? current }, set: { grid.setNewestColumn($0) })) {
                ForEach(grid.recencyColumns, id: \.self) { c in
                    Text(verbatim: grid.columns[c].name).tag(c)
                }
            }
            .accessibilityIdentifier("grid.newest.column")
        }
    }
}

/// Looks again at the relation (⌘R does the same).
struct RefreshButton: Component, Equatable {
    let grid: GridModel
    nonisolated static func == (l: Self, r: Self) -> Bool { l.grid === r.grid }

    var content: some ElementGroup {
        let grid = grid
        // Only a relation's rows can be read again: a query result is captured, and its Refresh would do nothing.
        if grid.links != nil {
            Button("Refresh") { grid.refresh() }
                .accessibilityIdentifier("grid.refresh")
        }
    }
}

/// The status bar's part about a highlight: when the look was taken, the Only changes toggle and Clear. Nothing without
/// a highlight.
struct ChangesBar: Component, Equatable {
    /// How many times `content` has run, for the cost pins (debug builds only).
    @MainActor static var bodyCount = 0

    let grid: GridModel
    var timeZone: TimeZone = .current
    nonisolated static func == (l: Self, r: Self) -> Bool { l.grid === r.grid && l.timeZone == r.timeZone }

    var content: some ElementGroup {
        let _ = Self.countBody()
        let grid = grid
        if let since = grid.changesSince {
            let text = Self.sinceText(since, in: timeZone)
            HStack(spacing: Pixels(12)) {
                Text(text).font(size: 12)
                    .accessibilityLabel(text)
                    .accessibilityIdentifier("grid.changes.since")
                Toggle(
                    "Only changes",
                    isOn: Binding(get: { grid.query.changes?.only == true }, set: { grid.setOnlyChanges($0) })
                )
                .accessibilityIdentifier("grid.changes.only")
                Button("Clear") { grid.clearChanges() }
                    .accessibilityIdentifier("grid.changes.clear")
            }
        }
    }

    /// "Changes since 10:42:13", in `zone`.
    static func sinceText(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm:ss"
        return "Changes since \(formatter.string(from: date))"
    }
}

extension ChangesBar {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}
