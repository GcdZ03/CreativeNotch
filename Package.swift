// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CreativeNotch",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "CreativeNotchCore"),
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
