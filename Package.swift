// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesEdge",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        // An xtool project must contain exactly one library product representing the main app
        .library(
            name: "HermesEdgeApp",
            targets: ["HermesEdgeApp"]
        ),
        .library(
            name: "HermesEdgeCore",
            targets: ["HermesEdgeCore"]
        )
    ],
    targets: [
        .target(
            name: "HermesEdgeCore",
            dependencies: [],
            path: "Sources/HermesEdgeCore"
        ),
        .target(
            name: "HermesEdgeApp",
            dependencies: ["HermesEdgeCore"],
            path: "Sources/HermesEdgeApp"
        )
    ]
)
