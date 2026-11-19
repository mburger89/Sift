import MetalUI

/// The sidebar: an outline `List` of saved connections, discovered containers and, under a connected one,
/// its schemas and tables. The two roots are outline nodes, not `Section`s (gap G3); the expansion is the
/// outline's own (gap G4), so selecting a table from elsewhere does not reveal its row.
struct SidebarView: Component {
    let model: AppModel

    var content: some ElementGroup {
        VStack(spacing: 0) {
            ScrollView {
                List(model.sidebarTree, children: \.children, selection: model.binding(\.selection)) { node in
                    SidebarRow(node: node).equatable()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Pixels(260))
        .frame(maxHeight: .infinity)
        .background(.sidebarFill)
        .accessibilityIdentifier("sidebar")
    }
}
