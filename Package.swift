// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SiftCore", targets: ["SiftCore"]),
        .library(name: "SiftPG", targets: ["SiftPG"]),
        .library(name: "SiftLayout", targets: ["SiftLayout"]),
        .executable(name: "siftpg-probe", targets: ["siftpg-probe"]),
    ],
    targets: [
        .systemLibrary(
            name: "CLibPQ",
            pkgConfig: "libpq",
            providers: [.brew(["libpq"]), .apt(["libpq-dev"])]
        ),
        .target(name: "SiftCore"),
        .target(name: "SiftPG", dependencies: ["CLibPQ", "SiftCore"]),
        .target(name: "SiftLayout"),
        .executableTarget(name: "siftpg-probe", dependencies: ["SiftPG", "SiftCore"]),
        .testTarget(name: "SiftPGTests", dependencies: ["SiftPG", "SiftCore"]),
        .testTarget(name: "SiftLayoutTests", dependencies: ["SiftLayout"]),
    ],
    swiftLanguageModes: [.v6]
)
