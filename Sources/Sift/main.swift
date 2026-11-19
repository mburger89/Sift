import MetalUI
import SiftKit
#if canImport(MetalUISDL)
import MetalUIPortableText
import MetalUISDL
import MetalUISystemFonts
#endif

/// AppKit and Metal on macOS; SDL3 with MetalUI's portable text, over the platform's
/// installed fonts, on Linux and Windows.
@MainActor
func makeApp() throws -> App {
    #if canImport(MetalUISDL)
    let resolver = try SystemFonts.resolver()
    return App(platform: try SDLPlatform(options: .headlessIfRequested()), textSystem: { PortableTextSystem(resolver: resolver) })
    #else
    return try App()
    #endif
}

let model = AppModel()
let app = try makeApp()
try app.openWindow(title: "Sift", size: siftWindowSize, minSize: siftMinimumSize) { siftRootView(model: model) }
app.run()
