import MetalUI

/// One sidebar row: the title, and a quiet subtitle at the right.
///
/// **`.equatable()`** (where the row is placed): MetalUI skips this `content` getter while `==` holds, so
/// selecting another table rebuilds the row it left and the row it entered, not every row. `==` is the
/// decision: it compares everything the body reads, which is the node alone (the selection highlight is the
/// list's, not the row's). `bodyCount` is what a cost pin reads.
struct SidebarRow: Component, Equatable {
    let node: SidebarNode

    /// How many times a row's `content` has run, for the pin that selecting rebuilds at most two rows.
    @MainActor static var bodyCount = 0

    nonisolated static func == (lhs: SidebarRow, rhs: SidebarRow) -> Bool { lhs.node == rhs.node }

    var content: some ElementGroup {
        let _ = Self.countBody()
        HStack(spacing: Pixels(6)) {
            Text(node.title)
                .font(size: node.kind == .root ? 12 : 13)
                .foregroundColor(node.kind == .root || node.kind == .problem ? .secondary : .primary)
                .accessibilityIdentifier("sidebar.\(node.id.token)")
            Spacer()
            if let subtitle = node.subtitle {
                Text(subtitle).font(size: 11).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SidebarRow {
    @MainActor static func countBody() {
        #if DEBUG
        bodyCount += 1
        #endif
    }
}
