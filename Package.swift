// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalProactiveAssistant",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
        .library(name: "IMsgTransport", targets: ["IMsgTransport"]),
        .executable(name: "assistantctl", targets: ["assistantctl"]),
    ],
    targets: [
        .target(name: "AssistantCore"),
        .target(
            name: "IMsgTransport",
            dependencies: ["AssistantCore"]
        ),
        .executableTarget(
            name: "assistantctl",
            dependencies: ["AssistantCore", "IMsgTransport"]
        ),
        .testTarget(
            name: "AssistantCoreTests",
            dependencies: ["AssistantCore"]
        ),
        .testTarget(
            name: "IMsgTransportTests",
            dependencies: ["AssistantCore", "IMsgTransport"]
        ),
    ]
)
