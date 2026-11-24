import MetalUI

/// Padding of `horizontal` points left and right and `vertical` top and bottom
/// (`Edges` has an all-sides initialiser and a per-side one, not this).
func inset(_ horizontal: Float, _ vertical: Float) -> Edges<Pixels> {
    Edges(top: Pixels(vertical), right: Pixels(horizontal), bottom: Pixels(vertical), left: Pixels(horizontal))
}

/// The sidebar's fill: one value for both schemes through `Color(light:dark:)`.
struct SidebarFill: ThemeColorKey {
    static let defaultValue = Color(light: Color(red: 0.94, green: 0.94, blue: 0.96),
                                    dark: Color(red: 0.12, green: 0.12, blue: 0.14))
}

/// The strip a connection problem is shown on.
struct BannerFill: ThemeColorKey {
    static let defaultValue = Color(light: Color(red: 1, green: 0.93, blue: 0.78),
                                    dark: Color(red: 0.32, green: 0.25, blue: 0.1))
}

/// The map's colours: one value for both schemes through `Color(light:dark:)`.
struct MapCanvasFill: ThemeColorKey {
    static let defaultValue = Color(light: Color(red: 0.97, green: 0.97, blue: 0.985),
                                    dark: Color(red: 0.085, green: 0.085, blue: 0.1))
}

struct MapCardFill: ThemeColorKey {
    static let defaultValue = Color(light: Color(red: 1, green: 1, blue: 1),
                                    dark: Color(red: 0.16, green: 0.16, blue: 0.19))
}

struct MapCardBorder: ThemeColorKey {
    static let defaultValue = Color(light: Color(red: 0.8, green: 0.8, blue: 0.84),
                                    dark: Color(red: 0.32, green: 0.32, blue: 0.38))
}

/// The colour of a link: a foreign key's cells in the grid, and the map's accents.
struct LinkAccent: ThemeColorKey {
    static let defaultValue = Color(light: Color(red: 0.0, green: 0.38, blue: 0.9),
                                    dark: Color(red: 0.35, green: 0.62, blue: 1))
}

/// The tint of a changed row (every cell, "#" too) after a Refresh.
struct ChangeRowFill: ThemeColorKey {
    static let defaultValue = Color(light: Color(red: 0.86, green: 0.93, blue: 1.0),
                                    dark: Color(red: 0.13, green: 0.22, blue: 0.36))
}

/// The stronger tint of a cell that changed inside a changed row.
struct ChangeCellFill: ThemeColorKey {
    static let defaultValue = Color(light: Color(red: 1.0, green: 0.87, blue: 0.55),
                                    dark: Color(red: 0.45, green: 0.33, blue: 0.08))
}

struct MapEdgeColor: ThemeColorKey {
    static let defaultValue = Color(light: Color(red: 0.55, green: 0.58, blue: 0.66),
                                    dark: Color(red: 0.5, green: 0.53, blue: 0.62))
}

struct MapScrim: ThemeColorKey {
    static let defaultValue = Color(light: Color(red: 0.97, green: 0.97, blue: 0.985, opacity: 0.78),
                                    dark: Color(red: 0.085, green: 0.085, blue: 0.1, opacity: 0.78))
}

extension Color {
    static let sidebarFill = Color(SidebarFill.self)
    static let bannerFill = Color(BannerFill.self)
    static let mapCanvas = Color(MapCanvasFill.self)
    static let mapCardFill = Color(MapCardFill.self)
    static let mapCardBorder = Color(MapCardBorder.self)
    static let linkAccent = Color(LinkAccent.self)
    static let mapAccent = Color(LinkAccent.self)
    static let mapEdge = Color(MapEdgeColor.self)
    static let mapScrim = Color(MapScrim.self)
}

extension ProposalElementGroup {
    /// Rounds this view's corners and strokes the same shape inside its edge. `.border` after `.cornerRadius` stays square.
    func roundedBorder(_ color: Color, radius: Pixels, width: Pixels = 1) -> some ProposalElementGroup {
        cornerRadius(radius).overlay {
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(color, lineWidth: width)
                .allowsHitTesting(false)
        }
    }
}

extension AppModel {
    /// A `Binding` to one of the model's properties, so a control can write it (a write runs from input).
    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>) -> Binding<Value> {
        nonisolated(unsafe) let keyPath = keyPath
        return Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}
