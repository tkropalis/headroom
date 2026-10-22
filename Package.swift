// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "HeadroomCore", targets: ["HeadroomCore"]),
        .executable(name: "headroom", targets: ["headroom"]),
        // Not "Headroom": APFS is usually case-insensitive, so it would overwrite the headroom command.
        .executable(name: "HeadroomApp", targets: ["HeadroomApp"]),
    ],
    targets: [
        .target(name: "HeadroomCore"),
        .executableTarget(name: "headroom", dependencies: ["HeadroomCore"]),
        .executableTarget(name: "HeadroomApp", dependencies: ["HeadroomCore"]),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore"]),
    ],
    swiftLanguageModes: [.v5]
)
