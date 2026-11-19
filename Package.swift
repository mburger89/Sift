// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SiftCore", targets: ["SiftCore"]),
        .library(name: "SiftPG", targets: ["SiftPG"]),
        .executable(name: "siftpg-probe", targets: ["siftpg-probe"]),
    ],
    targets: [
        .systemLibrary(
            name: "CLibPQ",
            pkgConfig: "libpq",
            providers: [.brew(["libpq"]), .apt(["libpq-dev"])]
        ),
        .target(name: "SiftCore"),
        .target(name: "SiftTestSupport", dependencies: ["SiftCore"]),
        .target(name: "SiftPG", dependencies: ["CLibPQ", "SiftCore"]),
        .executableTarget(name: "siftpg-probe", dependencies: ["SiftPG", "SiftCore"]),
        .testTarget(name: "SiftCoreTests", dependencies: ["SiftCore", "SiftTestSupport"]),
        .testTarget(name: "SiftPGTests", dependencies: ["SiftPG", "SiftCore"]),
    ],
    swiftLanguageModes: [.v6]
)
