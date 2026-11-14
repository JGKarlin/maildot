// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MailDot",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BridgeCore", targets: ["BridgeCore"]), .library(name: "BridgeAutomation", targets: ["BridgeAutomation"])],
    targets: [
        .target(name: "PinnedHTTP", linkerSettings:[.linkedLibrary("curl")]),
        .target(name: "BridgeCore", dependencies:["PinnedHTTP"]),
        .target(name: "BridgeAutomation", dependencies: ["BridgeCore"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
        .testTarget(name: "BridgeAutomationTests", dependencies: ["BridgeAutomation"])
    ]
)
