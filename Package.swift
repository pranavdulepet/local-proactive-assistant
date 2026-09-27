// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalProactiveAssistant",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
        .library(name: "AssistantStore", targets: ["AssistantStore"]),
        .library(name: "EventKitAdapter", targets: ["EventKitAdapter"]),
        .library(name: "IMsgTransport", targets: ["IMsgTransport"]),
        .executable(name: "assistantctl", targets: ["assistantctl"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "AssistantCore"),
        .target(
            name: "AssistantStore",
            dependencies: ["AssistantCore", "CSQLite"]
        ),
        .target(
            name: "IMsgTransport",
            dependencies: ["AssistantCore"]
        ),
        .target(
            name: "EventKitAdapter",
            dependencies: ["AssistantCore"]
        ),
        .executableTarget(
            name: "assistantctl",
            dependencies: [
                "AssistantCore",
                "AssistantStore",
                "EventKitAdapter",
                "IMsgTransport",
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/assistantctl/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "AssistantCoreTests",
            dependencies: ["AssistantCore"]
        ),
        .testTarget(
            name: "AssistantStoreTests",
            dependencies: ["AssistantCore", "AssistantStore"]
        ),
        .testTarget(
            name: "IMsgTransportTests",
            dependencies: ["AssistantCore", "IMsgTransport"]
        ),
        .testTarget(
            name: "EventKitAdapterTests",
            dependencies: ["EventKitAdapter"]
        ),
    ]
)
