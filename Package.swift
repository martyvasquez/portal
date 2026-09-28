// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Portal",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "Portal", path: "Sources/Portal"),
        .testTarget(name: "PortalTests", dependencies: ["Portal"], path: "Tests/PortalTests"),
    ]
)
