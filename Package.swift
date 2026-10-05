// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocalProactiveAssistant",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
        .library(name: "AssistantStore", targets: ["AssistantStore"]),
        .library(name: "LocalInference", targets: ["LocalInference"]),
        .library(name: "AppleModelAdapter", targets: ["AppleModelAdapter"]),
        .library(name: "PhoneSync", targets: ["PhoneSync"]),
        .library(name: "PhoneContext", targets: ["PhoneContext"]),
        .library(name: "ContactsAdapter", targets: ["ContactsAdapter"]),
        .library(name: "EventKitAdapter", targets: ["EventKitAdapter"]),
        .library(name: "IMsgTransport", targets: ["IMsgTransport"]),
        .library(name: "MailAdapter", targets: ["MailAdapter"]),
        .library(name: "MacContextAdapter", targets: ["MacContextAdapter"]),
        .executable(name: "assistantctl", targets: ["assistantctl"]),
        .executable(name: "assistant-model-worker", targets: ["assistant-model-worker"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "AssistantCore"),
        .target(name: "LocalInference"),
        .target(name: "ProcessSupport"),
        .target(name: "MailAdapter", dependencies: ["AssistantCore", "ProcessSupport"]),
        .target(name: "MacContextAdapter", dependencies: ["LocalInference", "ProcessSupport"]),
        .target(name: "MacModelBridge", dependencies: ["LocalInference", "ProcessSupport"]),
        .target(name: "AppleModelAdapter", dependencies: ["LocalInference"]),
        .target(name: "PhoneSync"),
        .target(name: "MacPhoneSync", dependencies: ["PhoneSync", "AssistantStore", "ProcessSupport"]),
        .target(name: "PhoneContext", dependencies: ["AssistantCore", "LocalInference", "AppleModelAdapter", "ContactsAdapter", "EventKitAdapter", "PhoneSync"]),
        .executableTarget(name: "assistant-model-worker", dependencies: ["AppleModelAdapter", "LocalInference"]),
        .target(
            name: "AssistantStore",
            dependencies: ["AssistantCore", "CSQLite", "LocalInference", "PhoneSync"]
        ),
        .target(
            name: "IMsgTransport",
            dependencies: ["AssistantCore", "ProcessSupport"]
        ),
        .target(
            name: "EventKitAdapter",
            dependencies: ["AssistantCore"]
        ),
        .target(
            name: "ContactsAdapter",
            dependencies: ["AssistantCore"]
        ),
        .executableTarget(
            name: "assistantctl",
            dependencies: [
                "AssistantCore",
                "AssistantStore",
                "ContactsAdapter",
                "EventKitAdapter",
                "IMsgTransport",
                "LocalInference",
                "MacModelBridge",
                "MacPhoneSync",
                "MacContextAdapter",
                "MailAdapter",
                "PhoneSync",
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
            name: "MacContextAdapterTests",
            dependencies: ["MacContextAdapter", "LocalInference", "ProcessSupport"]
        ),
        .testTarget(
            name: "MailAdapterTests",
            dependencies: ["MailAdapter", "AssistantCore", "ProcessSupport"]
        ),
        .testTarget(
            name: "PhoneContextTests",
            dependencies: ["PhoneContext", "LocalInference"]
        ),
        .testTarget(
            name: "AppleModelAdapterTests",
            dependencies: ["AppleModelAdapter", "LocalInference"]
        ),
        .testTarget(
            name: "MacModelBridgeTests",
            dependencies: ["MacModelBridge", "LocalInference"]
        ),
        .testTarget(
            name: "LocalInferenceTests",
            dependencies: ["LocalInference"]
        ),
        .testTarget(
            name: "AssistantCoreTests",
            dependencies: ["AssistantCore"]
        ),
        .testTarget(
            name: "AssistantStoreTests",
            dependencies: ["AssistantCore", "AssistantStore", "LocalInference", "PhoneSync"]
        ),
        .testTarget(
            name: "IMsgTransportTests",
            dependencies: ["AssistantCore", "IMsgTransport"]
        ),
        .testTarget(
            name: "EventKitAdapterTests",
            dependencies: ["EventKitAdapter"]
        ),
        .testTarget(
            name: "ContactsAdapterTests",
            dependencies: ["ContactsAdapter"]
        ),
    ]
)
