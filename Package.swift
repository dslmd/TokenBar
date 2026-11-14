// swift-tools-version:5.9
import PackageDescription

// TokenBarCore is Foundation-only and builds on Linux and macOS.
// The SwiftUI executable target is only declared when the package is
// resolved on macOS, so `swift build` / `swift test` keep working on Linux.
var products: [Product] = [
    .library(name: "TokenBarCore", targets: ["TokenBarCore"]),
]

var targets: [Target] = [
    .target(name: "TokenBarCore"),
    .testTarget(
        name: "TokenBarCoreTests",
        dependencies: ["TokenBarCore"],
        resources: [.copy("Fixtures")]
    ),
]

#if os(macOS)
products.append(.executable(name: "TokenBar", targets: ["TokenBar"]))
targets.append(.executableTarget(name: "TokenBar", dependencies: ["TokenBarCore"]))
#endif

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
