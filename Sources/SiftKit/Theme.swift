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

extension Color {
    static let sidebarFill = Color(SidebarFill.self)
}

extension AppModel {
    /// A `Binding` to one of the model's properties, so a control can write it (a write runs from input).
    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>) -> Binding<Value> {
        nonisolated(unsafe) let keyPath = keyPath
        return Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}
