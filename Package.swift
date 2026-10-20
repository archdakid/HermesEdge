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
    dependencies: [
        .package(url: "https://github.com/mattt/llama.swift", exact: "2.10549.0")
    ],
    targets: [
        .target(
            name: "HermesEdge",
            dependencies: [
                .product(name: "LlamaSwift", package: "llama.swift", condition: .when(platforms: [.iOS, .macOS]))
            ],
            path: "Sources",
            resources: [
                .process("HermesEdgeCore/Memory/SOUL.md"),
                .process("HermesEdgeCore/Memory/USER.md"),
                .process("HermesEdgeCore/Memory/AGENTS.md")
            ]
        )
    ]
)
