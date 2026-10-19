// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesEdge",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "HermesEdge",
            targets: ["HermesEdge"]
        )
    ],
    targets: [
        .target(
            name: "HermesEdge",
            dependencies: [],
            path: "Sources"
        )
    ]
)
