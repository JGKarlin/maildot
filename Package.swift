// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MailDot",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BridgeCore", targets: ["BridgeCore"]), .library(name: "BridgeAutomation", targets: ["BridgeAutomation"])],
    targets: [
        .target(name: "PinnedHTTP", linkerSettings:[.linkedLibrary("curl")]),
        // Mail Dot's search index is encrypted with SQLCipher, Zetetic's encrypted SQLite (owner's approval, 15 November
        // 2026), in place of the system SQLite. The checksum is the one Zetetic publishes for this release.
        .binaryTarget(name: "SQLCipher", url: "https://github.com/sqlcipher/SQLCipher.swift/releases/download/4.20.0/SQLCipher.xcframework.zip",
                      checksum: "1505174fe7f8a0fe81d6ebf87a64b17701b500c12a445ef6b68b9159f012d747"),
        .target(name: "BridgeCore", dependencies:["PinnedHTTP", "SQLCipher"], cSettings:[.define("SQLITE_HAS_CODEC")]),
        .target(name: "BridgeAutomation", dependencies: ["BridgeCore"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
        .testTarget(name: "BridgeAutomationTests", dependencies: ["BridgeAutomation"])
    ]
)
