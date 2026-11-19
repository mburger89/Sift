// swift-tools-version: 6.1
import PackageDescription

// MetalUI's SDL backend (`MetalUISDL`) is compiled only when its `SDL` trait is on: on Linux
// and Windows. `AccessKit` is its screen-reader bridge. macOS uses AppKit and needs neither.
#if os(Linux) || os(Windows)
let metalUITraits: Set<Package.Dependency.Trait> = ["SDL", "AccessKit"]
#else
let metalUITraits: Set<Package.Dependency.Trait> = [.defaults]
#endif

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sift", targets: ["Sift"]),
        .library(name: "SiftKit", targets: ["SiftKit"]),
        .library(name: "SiftCore", targets: ["SiftCore"]),
        .library(name: "SiftPG", targets: ["SiftPG"]),
        .library(name: "SiftDocker", targets: ["SiftDocker"]),
        .library(name: "SiftLayout", targets: ["SiftLayout"]),
        .executable(name: "siftpg-probe", targets: ["siftpg-probe"]),
    ],
    dependencies: [
        .package(name: "MetalUI", path: "../MetalUI", traits: metalUITraits)
    ],
    targets: [
        .systemLibrary(
            name: "CLibPQ",
            pkgConfig: "libpq",
            providers: [.brew(["libpq"]), .apt(["libpq-dev"])]
        ),
        .target(name: "SiftCore"),
        .target(name: "SiftDocker", dependencies: ["SiftCore"]),
        .target(name: "SiftTestSupport", dependencies: ["SiftCore", "SiftPG", "SiftDocker"]),
        .target(name: "SiftPG", dependencies: ["CLibPQ", "SiftCore"]),
        .target(name: "SiftLayout"),
        .target(
            name: "SiftKit",
            dependencies: [
                "SiftCore", "SiftPG", "SiftDocker", "SiftLayout",
                .product(name: "MetalUI", package: "MetalUI"),
            ]
        ),
        .executableTarget(
            name: "Sift",
            dependencies: [
                "SiftKit", "SiftCore",
                .product(name: "MetalUI", package: "MetalUI"),
                .product(name: "MetalUISDL", package: "MetalUI", condition: .when(platforms: [.linux, .windows])),
                // On every platform (SG-D): with a platform condition SwiftPM drops their C modules on macOS.
                .product(name: "MetalUIPortableText", package: "MetalUI"),
                .product(name: "MetalUISystemFonts", package: "MetalUI"),
            ]
        ),
        .executableTarget(name: "siftpg-probe", dependencies: ["SiftPG", "SiftCore"]),
        .testTarget(name: "SiftCoreTests", dependencies: ["SiftCore", "SiftTestSupport"]),
        .testTarget(
            name: "SiftDockerTests",
            dependencies: ["SiftDocker", "SiftCore", "SiftTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "SiftPGTests", dependencies: ["SiftPG", "SiftCore", "SiftTestSupport"]),
        .testTarget(
            name: "SiftKitTests",
            dependencies: [
                "SiftKit", "SiftCore", "SiftDocker", "SiftTestSupport",
                .product(name: "MetalUI", package: "MetalUI"),
                .product(name: "MetalUITesting", package: "MetalUI"),
                .product(name: "MetalUIPortableText", package: "MetalUI"),
                .product(name: "MetalUISystemFonts", package: "MetalUI"),
            ]
        ),
        .testTarget(name: "SiftLayoutTests", dependencies: ["SiftLayout"]),
    ],
    swiftLanguageModes: [.v6]
)
