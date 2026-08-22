// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CreativeNotch",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "CreativeNotchCore"),
        .executableTarget(
            name: "CreativeNotch",
            dependencies: ["CreativeNotchCore"]
        ),
        .testTarget(
            name: "CreativeNotchCoreTests",
            dependencies: ["CreativeNotchCore"]
        ),
    ]
)
