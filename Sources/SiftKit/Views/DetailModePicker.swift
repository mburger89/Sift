import MetalUI

/// The Table | Map | Query switch of a connection's detail area, shared by the map's and the editor's toolbars.
///
/// A component of its own so the toolbar that holds it keeps a shallow builder: on Windows the test process runs on a
/// 1 MB main-thread stack, and the map toolbar's builder, with a third segment in it, no longer fit.
struct DetailModePicker: Component, Equatable {
    let model: AppModel
    var identifier: String
    nonisolated static func == (l: Self, r: Self) -> Bool { l.model === r.model && l.identifier == r.identifier }

    var content: some ElementGroup {
        let model = model
        Picker("View", selection: Binding(get: { model.detailMode }, set: { model.setDetailMode($0) })) {
            Text("Table").tag(DetailMode.table)
            Text("Map").tag(DetailMode.map)
            Text("Query").tag(DetailMode.query)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(identifier)
    }
}
