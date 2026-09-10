// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Minted",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Minted", targets: ["Minted"]),
    ],
    targets: [
        .target(name: "Minted", resources: [.process("Resources")]),
        .testTarget(name: "MintedTests", dependencies: ["Minted"]),
    ]
)
