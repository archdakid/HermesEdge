// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HermesEdge",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .executable(
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
        .executableTarget(
            name: "HermesEdgeApp",
            dependencies: ["HermesEdgeCore"],
            path: "Sources/HermesEdgeApp"
        ),
        .testTarget(
            name: "HermesEdgeTests",
            dependencies: ["HermesEdgeCore"],
            path: "Tests/HermesEdgeTests"
        )
    ]
)
