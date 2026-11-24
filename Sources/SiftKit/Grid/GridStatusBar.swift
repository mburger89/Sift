import Foundation
import MetalUI
import SiftCore

/// The row count (exact or "≈"), what is running, the last error, and the order note.
struct GridStatusBar: Component, Equatable {
    /// How many times `content` has run, for the cost pins (debug builds only).
    @MainActor static var bodyCount = 0

    let grid: GridModel
    var timeZone: TimeZone = .current
    nonisolated static func == (l: Self, r: Self) -> Bool { l.grid === r.grid && l.timeZone == r.timeZone }

    var content: some ElementGroup {
        let _ = Self.countBody()
        let grid = grid
        HStack(spacing: Pixels(12)) {
            Text(Self.countText(grid.count)).font(size: 12)
                .accessibilityLabel(Self.countText(grid.count))
                .accessibilityIdentifier("grid.status.count")
            if !grid.count.isExact {
                if grid.isCountingExactly {
                    Text("counting\u{2026}").font(size: 12).foregroundColor(.secondary)
                        .accessibilityIdentifier("grid.status.counting")
                    Button("Cancel") { grid.cancelExactCount() }
                        .accessibilityIdentifier("grid.status.cancelCount")
                } else {
                    Button("Count exactly") { grid.countExactly() }
                        .accessibilityIdentifier("grid.status.countExactly")
                }
            }
            ChangesBar(grid: grid, timeZone: timeZone).equatable()
            if grid.isLoading {
                Text("loading\u{2026}").font(size: 12).foregroundColor(.secondary)
                    .accessibilityIdentifier("grid.status.loading")
            }
            if Self.isFullScan(grid) {
                Text("full scan").font(size: 12).foregroundColor(.secondary)
                    .accessibilityIdentifier("grid.status.fullScan")
            }
            if let note = grid.orderNote {
                Text(note).font(size: 12).foregroundColor(.secondary)
                    .accessibilityLabel(note)
                    .accessibilityIdentifier("grid.status.note")
            }
            Spacer()
            if let error = grid.error {
                Text(error).font(size: 12).foregroundColor(.red).lineLimit(1)
                    .accessibilityLabel(error)
                    .accessibilityIdentifier("grid.status.error")
                Button("Retry") { grid.retry() }
                    .accessibilityIdentifier("grid.status.retry")
            }
        }
        .padding(inset(12, 6))
        // Fixed, as the toolbar's is: a message or a button appearing must not resize the table above.
        .frame(maxWidth: .infinity, minHeight: Pixels(28), maxHeight: Pixels(28))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("grid.status")
    }

    static func countText(_ count: RowCount) -> String {
        switch count {
        case .exact(let n): return "\(RowEstimate.grouped(Int64(n))) \(n == 1 ? "row" : "rows")"
        case .estimated(let n): return "\u{2248} \(RowEstimate.grouped(Int64(n))) rows"
        }
    }

    /// A search over a relation of more than a million rows reads every one of them.
    static func isFullScan(_ grid: GridModel) -> Bool {
        let narrowed = !(grid.query.search ?? "").isEmpty || grid.query.changes?.only == true
        return narrowed && grid.count.value > PGScan.fullScanRows
    }
}

enum PGScan {
    static let fullScanRows = 1_000_000
}

extension GridStatusBar {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}
