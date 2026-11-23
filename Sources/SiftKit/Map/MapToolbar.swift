import MetalUI
import SiftCore

/// The strip above the map: Table or Map, search, fit and zoom, the schema filter, views and Reset layout.
struct MapToolbar: Component {
    let model: AppModel
    let map: MapModel
    var focus: FocusState<Bool>.Binding

    var content: some ElementGroup {
        let map = map
        let model = model
        HStack(spacing: Pixels(8)) {
            Picker("View", selection: Binding(get: { model.detailMode }, set: { model.setDetailMode($0) })) {
                Text("Table").tag(DetailMode.table)
                Text("Map").tag(DetailMode.map)
                Text("Query").tag(DetailMode.query)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("map.mode")
            TextField("Find a table", text: Binding(get: { map.search }, set: { map.search = $0 }))
                .focused(focus)
                .onSubmit { map.flyToBestMatch() }
                .frame(width: Pixels(200))
                .accessibilityIdentifier("map.search")
            Button("Find") { focus.wrappedValue = true }
                .keyboardShortcut("f")
                .accessibilityIdentifier("map.find")
            Spacer()
            Button("Fit") { map.fit() }
                .keyboardShortcut("0")
                .accessibilityIdentifier("map.fit")
            Button("\u{2212}") { map.zoomOut() }
                .accessibilityLabel("Zoom out")
                .accessibilityIdentifier("map.zoomOut")
            Text(verbatim: "\(Int((map.geometry.zoom * 100).rounded()))%").font(size: 12).foregroundColor(.secondary)
                .frame(width: Pixels(40), alignment: .trailing)
                .accessibilityIdentifier("map.zoom")
            Button("+") { map.zoomIn() }
                .accessibilityLabel("Zoom in")
                .accessibilityIdentifier("map.zoomIn")
            SchemaFilterMenu(map: map, schemas: map.snapshot?.schemas ?? [])
            Toggle("Views", isOn: Binding(
                get: { map.filter.showViews },
                set: { value in
                    var filter = map.filter
                    filter.showViews = value
                    Task { @MainActor in await map.setFilter(filter) }
                }))
                .accessibilityIdentifier("map.views")
            Button("Reset layout") { Task { @MainActor in await map.resetLayout() } }
                .accessibilityIdentifier("map.reset")
        }
        .padding(inset(12, 0))
        // A fixed height: the map under it must not change size when a label (the zoom, a button) changes width or
        // wraps on a font with wider letters, because a resize pans the map.
        .frame(maxWidth: .infinity, minHeight: Pixels(48), maxHeight: Pixels(48))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("map.toolbar")
    }
}

/// A menu of the schemas, each a toggle. Unchecking one hides its tables and the links that reach them.
struct SchemaFilterMenu: Component {
    let map: MapModel
    let schemas: [String]

    var content: some ElementGroup {
        let map = map
        let schemas = schemas
        Menu {
            for schema in schemas {
                Toggle(schema, isOn: Binding(
                    get: { map.filter.schemas?.contains(schema) ?? true },
                    set: { on in
                        var shown = map.filter.schemas ?? Set(schemas)
                        if on { shown.insert(schema) } else { shown.remove(schema) }
                        var filter = map.filter
                        filter.schemas = shown.count == schemas.count ? nil : shown
                        Task { @MainActor in await map.setFilter(filter) }
                    }))
            }
        } label: {
            Text("Schemas")
        }
        .accessibilityIdentifier("map.schemas")
    }
}

/// The matches for what is typed in the search field, under the toolbar. A click flies to one.
struct MapSearchResults: Component {
    let map: MapModel

    var content: some ElementGroup {
        let matches = map.layout.map { MapSearch.matches(map.search, in: $0.graph.ids) } ?? []
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(matches, id: \.self) { id in
                    Button(id.qualifiedName) { map.flyTo(id) }
                        .accessibilityIdentifier("map.result.\(id.schema).\(id.name)")
                }
            }
            .padding(Edges(all: Pixels(6)))
            .background(.mapCardFill)
            .roundedBorder(.mapCardBorder, radius: Pixels(6), width: Pixels(1))
            .padding(Edges(all: Pixels(8)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("map.results")
        }
    }
}
