// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Portlight",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Portlight", targets: ["Portlight"])],
    targets: [
        .target(name: "ProcessBridge", publicHeadersPath: "include"),
        .target(name: "PortlightCore", dependencies: ["ProcessBridge"]),
        .executableTarget(name: "Portlight", dependencies: ["PortlightCore"]),
        .executableTarget(name: "PortlightChecks", dependencies: ["PortlightCore"], path: "Tests/PortlightCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
