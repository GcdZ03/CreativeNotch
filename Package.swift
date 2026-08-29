// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CreativeNotch",
    platforms: [.macOS("26.0")],
    products: [
        // Loaded at runtime by the perl helper; nothing links it. It is a
        // product only so SwiftPM emits a dylib for bundle.sh to ship.
        .library(name: "CreativeNotchMediaBridge", type: .dynamic,
                 targets: ["CreativeNotchMediaBridge"]),
    ],
    targets: [
        .target(name: "CreativeNotchCore"),
        // The only non-Swift target in the repo. Deliberately a dependency
        // of nothing: the perl helper dlopens it, no Swift target links it.
        .target(
            name: "CreativeNotchMediaBridge",
            linkerSettings: [.linkedFramework("Foundation")]
        ),
        .target(
            name: "CreativeNotchUI",
            dependencies: ["CreativeNotchCore"]
        ),
        .executableTarget(
            name: "CreativeNotch",
            dependencies: ["CreativeNotchCore", "CreativeNotchUI"]
        ),
        .testTarget(
            name: "CreativeNotchCoreTests",
            dependencies: ["CreativeNotchCore"]
        ),
        .testTarget(
            name: "CreativeNotchUITests",
            dependencies: ["CreativeNotchUI"]
        ),
    ]
)
