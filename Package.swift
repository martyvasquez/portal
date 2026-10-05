// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Portal",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Portal",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Portal",
            // build.sh puts Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "PortalTests", dependencies: ["Portal"], path: "Tests/PortalTests"),
    ]
)
