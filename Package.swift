// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalProactiveAssistant",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
        .library(name: "AssistantStore", targets: ["AssistantStore"]),
        .library(name: "IMsgTransport", targets: ["IMsgTransport"]),
        .executable(name: "assistantctl", targets: ["assistantctl"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .brew(["sqlite3"]),
                .apt(["libsqlite3-dev"]),
            ]
        ),
        .target(name: "AssistantCore"),
        .target(
            name: "AssistantStore",
            dependencies: ["CSQLite"]
        ),
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
            name: "AssistantStoreTests",
            dependencies: ["AssistantStore"]
        ),
        .testTarget(
            name: "IMsgTransportTests",
            dependencies: ["AssistantCore", "IMsgTransport"]
        ),
    ]
)
