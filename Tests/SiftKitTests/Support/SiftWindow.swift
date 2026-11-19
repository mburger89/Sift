import Foundation
import MetalUI
import MetalUITesting
import SiftKit
#if os(Linux) || os(Windows)
import MetalUIPortableText
import MetalUISystemFonts
#endif

/// The app's real root element in a headless window, settled so lists have built their rows.
///
/// Text goes through CoreText on macOS. On Linux and Windows it is the portable text system over
/// the fonts in MetalUI's own `Tests/Fonts` (the CI container has none installed), read by
/// `#filePath` as MetalUI's tests read them, falling back to the installed fonts.
@MainActor
func siftWindow(model: AppModel, size: Size<Pixels> = siftWindowSize, recordsLayout: Bool = true,
                options: HeadlessPlatformWindow.Options = .init()) throws -> TestWindow {
    #if os(Linux) || os(Windows)
    let resolver = try testFontResolver()
    let window = try TestWindow(size: size, options: options, recordsLayout: recordsLayout,
                                textSystem: { PortableTextSystem(resolver: resolver) }) { siftRootView(model: model) }
    #else
    let window = try TestWindow(size: size, options: options, recordsLayout: recordsLayout) { siftRootView(model: model) }
    #endif
    // A `List` measures its own origin in its first frame and builds its rows in the next.
    window.tick()
    window.tick()
    return window
}

/// Any element tree in a headless window with the same text setup as `siftWindow`.
@MainActor
func siftTestWindow<Content: Element>(size: Size<Pixels> = Size(width: Pixels(400), height: Pixels(300)),
                                      recordsLayout: Bool = true, @ElementBuilder content: @escaping @MainActor () -> Content) throws -> TestWindow {
    #if os(Linux) || os(Windows)
    let resolver = try testFontResolver()
    let window = try TestWindow(size: size, recordsLayout: recordsLayout, textSystem: { PortableTextSystem(resolver: resolver) }, content: content)
    #else
    let window = try TestWindow(size: size, recordsLayout: recordsLayout, content: content)
    #endif
    window.tick()
    window.tick()
    return window
}

#if os(Linux) || os(Windows)
private func testFontResolver() throws -> PortableFontResolver {
    let here = URL(fileURLWithPath: #filePath)
    // Tests/SiftKitTests/Support/SiftWindow.swift -> the package root's sibling MetalUI checkout.
    let fonts = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("MetalUI/Tests/Fonts").path
    if FileManager.default.fileExists(atPath: fonts), let resolver = try? SystemFonts.resolver(directories: [fonts]) {
        return resolver
    }
    return try SystemFonts.resolver()
}
#endif
