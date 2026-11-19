import MetalUI

/// The menu bar's items, each with a shortcut on `EventModifiers.primary` (⌘ on macOS, Ctrl elsewhere).
/// On macOS they join AppKit's main menu; on SDL, where there is no native bar, every window draws it.
@MainActor
public func installSiftCommands(on app: App, model: AppModel) {
    app.commands {
        CommandGroup(after: .newItem) {
            Button("New Connection") { model.beginNewConnection() }
                .keyboardShortcut("n")
            Button("Refresh") { Task { @MainActor in await model.refresh() } }
                .keyboardShortcut("r")
        }
    }
}
