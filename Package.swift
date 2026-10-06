// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Portal",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
        // GitHub-flavored Markdown, for pasting transformer results as rich text.
        .package(url: "https://github.com/swiftlang/swift-cmark", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "Portal",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
            path: "Sources/Portal",
            // build.sh puts Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "PortalTests", dependencies: ["Portal"], path: "Tests/PortalTests"),
    ]
)
