import AssistantCore
import AssistantStore
import ContactsAdapter
import Darwin
import EventKitAdapter
import Foundation
import IMsgTransport

@main
struct AssistantCLI {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let executable = takeOption("--imsg", from: &arguments) ?? "imsg"
        let transport = IMsgTransport(executable: executable)

        guard let command = arguments.first else {
            printUsage()
            return
        }
        arguments.removeFirst()

        switch command {
        case "doctor":
            let health = await transport.probe()
            print("imsg: \(health.ready ? "ready" : "unavailable")")
            if let version = health.version { print("version: \(version)") }
            print(health.detail)
            if !health.ready { exit(1) }

        case "chats":
            for chat in try await transport.chats() {
                let kind = chat.isGroup ? "group" : "direct"
                print("\(chat.id.rawValue)\t\(kind)\t\(chat.service)\t\(chat.displayName)")
            }

        case "echo":
            guard let rawChatID = takeOption("--chat-id", from: &arguments),
                  let chatID = Int64(rawChatID) else {
                throw CLIError("echo requires --chat-id <positive integer>")
            }
            let after = takeOption("--after", from: &arguments).flatMap(Int64.init)
            let ledger = try OutboundLedger(fileURL: try stateURL("outbound-ledger.json"))
            let cursorStore = try CursorStore(fileURL: try stateURL("cursors.json"))
            let service = EchoService(
                transport: transport,
                ledger: ledger,
                cursorStore: cursorStore,
                onReconnect: { attempt, delay, detail in
                    print(
                        "watch interrupted: \(detail) "
                            + "reconnecting in \(Int(delay))s (attempt \(attempt))"
                    )
                }
            )

            let chat = TransportChatID(rawValue: chatID)
            let storedCursor = await cursorStore.cursor(for: chat)
            let resumeCursor = [after.map(TransportCursor.init(rawValue:)), storedCursor]
                .compactMap { $0 }
                .max()

            print("Watching chat \(chatID). Press Control-C to stop.")
            if let resumeCursor {
                print("Resuming after row \(resumeCursor.rawValue).")
            }
            for try await event in service.events(
                chatID: chat,
                after: resumeCursor
            ) {
                switch event.decision {
                case .accept:
                    let guid = event.receipt?.messageGUID ?? "unverified"
                    print("accepted row \(event.inbound.cursor.rawValue); sent \(guid)")
                case .reject(let reason):
                    print("ignored row \(event.inbound.cursor.rawValue): \(reason.rawValue)")
                }
            }

        case "index-messages":
            guard let rawChatID = takeOption("--control-chat-id", from: &arguments),
                  let chatID = Int64(rawChatID), chatID > 0 else {
                throw CLIError("index-messages requires --control-chat-id <positive integer>")
            }
            let store = try ObservationStore(fileURL: try stateURL("assistant.sqlite"))
            let ingestor = MessagesIngestor(
                source: transport,
                store: store,
                excludedChatIDs: [TransportChatID(rawValue: chatID)]
            )
            let summary = try await ingestor.run { progress in
                print(
                    "Scanned \(progress.scanned) messages; "
                        + "indexed \(progress.indexed); cursor \(progress.cursor.rawValue)."
                )
            }
            print(
                "Indexed \(summary.indexed) of \(summary.scanned) messages "
                    + "across \(summary.pages) page(s); cursor \(summary.cursor.rawValue)."
            )

        case "index-calendar":
            let now = Date()
            let calendar = Calendar.current
            guard let startDate = calendar.date(byAdding: .day, value: -90, to: now),
                  let endDate = calendar.date(byAdding: .day, value: 365, to: now) else {
                throw CLIError("could not calculate the Calendar scan window")
            }
            let store = try ObservationStore(fileURL: try stateURL("assistant.sqlite"))
            let ingestor = CalendarIngestor(
                source: EventKitCalendarSource(),
                store: store
            )
            let summary = try await ingestor.run(from: startDate, to: endDate)
            let formatter = ISO8601DateFormatter()
            print(
                "Indexed \(summary.indexed) of \(summary.scanned) Calendar events; "
                    + "window \(formatter.string(from: summary.startDate)) "
                    + "through \(formatter.string(from: summary.endDate)); "
                    + "cursor \(summary.cursor)."
            )

        case "index-contacts":
            let store = try ObservationStore(fileURL: try stateURL("assistant.sqlite"))
            let summary = try await ContactsIngestor(
                source: ContactsStoreSource(),
                store: store
            ).run()
            print(
                "Indexed \(summary.indexed) of \(summary.scanned) contacts; "
                    + "tombstoned \(summary.tombstoned); "
                    + "access \(summary.authorization.rawValue); "
                    + "cursor \(summary.cursor)."
            )

        default:
            throw CLIError("unknown command: \(command)")
        }
    }

    private static func takeOption(_ name: String, from arguments: inout [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            return nil
        }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return value
    }

    private static func stateURL(_ filename: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root
            .appendingPathComponent("LocalProactiveAssistant", isDirectory: true)
            .appendingPathComponent(filename)
    }

    private static func printUsage() {
        print("""
        Usage:
          assistantctl doctor [--imsg <path>]
          assistantctl chats [--imsg <path>]
          assistantctl echo --chat-id <id> [--after <rowid>] [--imsg <path>]
          assistantctl index-messages --control-chat-id <id> [--imsg <path>]
          assistantctl index-calendar
          assistantctl index-contacts
        """)
    }
}

private struct CLIError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
