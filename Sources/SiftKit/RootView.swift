import MetalUI

/// The window the app opens at, and the smallest it may be resized to.
public let siftWindowSize = Size(width: Pixels(1200), height: Pixels(780))
public let siftMinimumSize = Size(width: Pixels(760), height: Pixels(480))

/// The window's one root element: sidebar | divider | detail.
@MainActor
public func siftRootView(model: AppModel) -> some Element {
    VStack(spacing: 0) {
        SiftScreen(model: model)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.surface)
}

/// Sidebar | divider | detail, each its own `Component` so no one builder holds the whole tree.
struct SiftScreen: Component {
    let model: AppModel

    var content: some ElementGroup {
        HStack(spacing: 0) {
            SidebarView(model: model)
            Divider()
            DetailArea(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
