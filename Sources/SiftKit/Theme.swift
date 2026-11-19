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

extension Color {
    static let sidebarFill = Color(SidebarFill.self)
    static let bannerFill = Color(BannerFill.self)
}

extension AppModel {
    /// A `Binding` to one of the model's properties, so a control can write it (a write runs from input).
    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>) -> Binding<Value> {
        nonisolated(unsafe) let keyPath = keyPath
        return Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}
