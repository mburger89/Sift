import Foundation
import MetalUI
import SiftCore

/// The map's surface: the canvas under one transform, and the gestures that change it.
///
/// Pan with the wheel or a drag on empty canvas; zoom with ⌘-wheel (Ctrl elsewhere) or a pinch.
struct SchemaMapView: Component {
    let model: AppModel
    let map: MapModel
    let key: ConnectionKey
    @Environment(\.displayScale) private var displayScale

    var content: some ElementGroup {
        let scale = Float(displayScale)
        let map = map
        // The canvas is the surface and the world is laid over it: what is drawn never sizes the surface.
        Color.mapCanvas
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) { MapContentLayer(map: map) }
            }
            .overlay(alignment: .topTrailing) {
                ZStack(alignment: .topTrailing) { MapSearchResults(map: map) }
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack(alignment: .bottomTrailing) { MapMinimap(map: map) }.padding(Edges(all: Pixels(12)))
            }
            .overlay(alignment: .bottomLeading) {
                ZStack(alignment: .bottomLeading) { MapEdgeInfoStrip(map: map) }
            }
            .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("map")
        .onGeometryChange(for: Size<Pixels>.self, of: { $0.size }, action: { map.setViewSize($0, scale: scale) })
        .onScrollWheel { Self.scroll($0, map, scale: scale) }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): map.hover(at: point)
            case .ended: map.clearHover()
            }
        }
        .gesture(SpatialTapGesture().onEnded { (tap: SpatialTapGesture.Value) in
            Self.tap(tap, map)
        })
        .gesture(DragGesture(minimumDistance: Pixels(3))
            .onChanged { (value: DragGesture.Value) in
                map.dragChanged(start: value.startLocation, translation: value.translation, scale: scale)
            }
            .onEnded { _ in map.dragEnded() }
            .onCancelled { map.dragEnded() })
        .focusable(true, interactions: .edit)
        .hoverKeyRegion()
        .onKeyPress(.return) {
            guard let selected = map.selected else { return .ignored }
            map.open(selected)
            return .handled
        }
    }

    /// A click selects the table (or the foreign key) under it; a double click opens the table.
    @MainActor
    static func tap(_ tap: SpatialTapGesture.Value, _ map: MapModel) {
        if let table = map.table(at: tap.location) {
            map.selectedEdge = nil
            map.selected = table
            if tap.clickCount >= 2 { map.open(table) }
        } else if let edge = map.edge(at: tap.location) {
            map.selectedEdge = edge
        } else {
            map.selectedEdge = nil
            map.selected = nil
        }
    }

    /// ⌘ or Ctrl zooms by `2^(Δy/100)` about the pointer; anything else pans.
    @MainActor
    static func scroll(_ event: ScrollEvent, _ map: MapModel, scale: Float) -> Bool {
        if event.modifiers.contains(.command) || event.modifiers.contains(.control) {
            map.zoom(by: pow(2, Double(event.delta.y.value) / 100), about: event.location, scale: scale)
        } else {
            map.panBy(event.delta.x.value, event.delta.y.value, scale: scale)
        }
        return true
    }
}
