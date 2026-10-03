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

        case "serve":
            guard let rawChatID = takeOption("--control-chat-id", from: &arguments),
                  let chatID = Int64(rawChatID), chatID > 0 else {
                throw CLIError("serve requires --control-chat-id <positive integer>")
            }
            let hostLock = try HostLock(fileURL: try stateURL("host.lock"))
            defer { withExtendedLifetime(hostLock) {} }
            let chat = TransportChatID(rawValue: chatID)
            guard let selectedChat = try await transport.chats().first(where: { $0.id == chat }),
                  !selectedChat.isGroup, selectedChat.service == "iMessage" else {
                throw CLIError("Control chat must appear in the recent chats and be a direct iMessage conversation. Send it a message, then retry.")
            }
            let ledger = try OutboundLedger(fileURL: try stateURL("outbound-ledger.json"))
            let cursorStore = try CursorStore(fileURL: try stateURL("cursors.json"))
            let store = try ObservationStore(fileURL: try stateURL("assistant.sqlite"))
            try await store.recoverInterruptedReminders()
            let handler = ControlCommandHandler(store: store)
            let service = EchoService(
                transport: transport,
                ledger: ledger,
                cursorStore: cursorStore,
                reply: { text in try await handler.response(to: text) },
                onReconnect: { attempt, delay, detail in
                    print(
                        "watch interrupted: \(detail) "
                            + "reconnecting in \(Int(delay))s (attempt \(attempt))"
                    )
                }
            )

            let resumeCursor = await cursorStore.cursor(for: chat)
            print("Serving owner commands in chat \(chatID). Press Control-C to stop.")
            print("Automatic refresh: Messages every 60s; Calendar/Contacts every 15m. Send /status, /pause or /resume.")
            if let resumeCursor {
                print("Resuming after row \(resumeCursor.rawValue).")
            }
            let refresh = HostRefreshService(
                messages: transport, calendar: EventKitCalendarSource(),
                contacts: ContactsStoreSource(), store: store, controlChatID: chat
            )
            let reminders = ProactiveReminderService(store: store, transport: transport, ledger: ledger)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await event in service.events(chatID: chat, after: resumeCursor) {
                        switch event.decision {
                        case .accept where event.receipt != nil:
                            let guid = event.receipt?.messageGUID ?? "unverified"
                            print("handled row \(event.inbound.cursor.rawValue); submitted \(guid)")
                        case .accept:
                            print("ignored row \(event.inbound.cursor.rawValue): not a command")
                        case .reject(let reason):
                            print("ignored row \(event.inbound.cursor.rawValue): \(reason.rawValue)")
                        }
                    }
                }
                group.addTask {
                    while !Task.isCancelled {
                        let report = try await refresh.refresh()
                        for source in report.failures {
                            print("\(source.rawValue) refresh unavailable; check permission/access. Commands remain available.")
                        }
                        if report.messagesReady {
                            do {
                                if try await reminders.tick(chatID: chat) {
                                    print("proactive reminder submitted (not a delivery confirmation)")
                                }
                            } catch {
                                try Task.checkCancellation()
                                try await store.setProactivityPaused(true)
                                print("proactive submission uncertain; reminders paused. Check /status before /resume.")
                            }
                        }
                        try await Task.sleep(for: .seconds(60))
                    }
                }
                defer { group.cancelAll() }
                try await group.next()
            }

        case "proactive-status", "pause", "resume":
            let store = try ObservationStore(fileURL: try stateURL("assistant.sqlite"))
            let text = command == "proactive-status" ? "/status" : "/\(command)"
            if let response = try await ControlCommandHandler(store: store).response(to: text) {
                print(response)
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

        case "source-status":
            let store = try ObservationStore(fileURL: try stateURL("assistant.sqlite"))
            let formatter = ISO8601DateFormatter()
            for source in ObservationSource.allCases {
                guard let coverage = try await store.sourceCoverage(for: source) else {
                    print("\(source.rawValue): never synced")
                    continue
                }
                print("\(source.rawValue): \(coverage.status.rawValue)")
                print("  last sync: \(formatter.string(from: coverage.lastSuccessfulSync))")
                if let earliest = coverage.earliestAvailable,
                   let latest = coverage.latestObserved {
                    print(
                        "  observed: \(formatter.string(from: earliest)) "
                            + "through \(formatter.string(from: latest))"
                    )
                }
                if let cursor = coverage.cursor { print("  cursor: \(cursor)") }
                for limitation in coverage.limitations {
                    print("  limitation: \(limitation)")
                }
            }

        case "meeting-context":
            guard let person = takeOption("--person", from: &arguments) else {
                throw CLIError(
                    "meeting-context requires --person <exact name, nickname, phone, or email>"
                )
            }
            let store = try ObservationStore(fileURL: try stateURL("assistant.sqlite"))
            let evidence = try await MeetingContextService(store: store).evidence(for: person)
            let formatter = ISO8601DateFormatter()
            print("Person")
            print(indentedSummary(evidence.person.text))
            print("\nUpcoming meeting")
            print(indentedSummary(evidence.meeting.text))
            print("\nRecent direct messages (up to 10)")
            if evidence.recentMessages.isEmpty {
                print("  none in the indexed 90-day lookback")
            } else {
                for message in evidence.recentMessages {
                    let timestamp = message.sourceTimestamp.map(formatter.string(from:)) ?? "unknown"
                    let text = message.text.replacingOccurrences(of: "\n", with: " ")
                    print("  \(timestamp)  \(text)")
                }
            }
            print("\nCoverage used")
            for coverage in evidence.coverage {
                print("  \(coverage.source.rawValue): \(coverage.status.rawValue)")
            }

        case "index-commitments":
            let rawDays = takeOption("--days", from: &arguments) ?? "30"
            guard let days = Int(rawDays), (1...365).contains(days) else {
                throw CLIError("index-commitments requires --days between 1 and 365")
            }
            let store = try ObservationStore(fileURL: try stateURL("assistant.sqlite"))
            let summary = try await CommitmentService(store: store).extractRecent(days: days)
            let formatter = ISO8601DateFormatter()
            print(
                "Scanned \(summary.scanned) owner-authored messages since "
                    + "\(formatter.string(from: summary.since)); "
                    + "matched \(summary.extracted); inserted \(summary.inserted); "
                    + "superseded \(summary.superseded)."
            )

        case "forgetting":
            let store = try ObservationStore(fileURL: try stateURL("assistant.sqlite"))
            let commitments = try await store.openCommitments(limit: 50)
            let formatter = ISO8601DateFormatter()
            if commitments.isEmpty {
                print("No open commitments matched the deterministic rule.")
            } else {
                print("Open commitments")
                for commitment in commitments {
                    let timing = commitment.dueAt < Date() ? "overdue" : "upcoming"
                    print("  [\(commitment.id)] \(timing) \(formatter.string(from: commitment.dueAt))")
                    print("    \(commitment.summary)")
                }
            }
            print(
                "\nRule coverage: owner-authored direct messages containing "
                    + "an actionable I’ll/I will statement plus today, tonight, tomorrow, "
                    + "or this morning/afternoon/evening. Availability and hedged intent are excluded."
            )
            print("Completion is explicit; use complete-commitment after verifying an item is done.")
            if let coverage = try await store.sourceCoverage(for: .messages) {
                print(
                    "Messages coverage: \(coverage.status.rawValue), synced through "
                        + "\(formatter.string(from: coverage.lastSuccessfulSync))."
                )
            }

        case "why":
            guard let id = takeOption("--commitment", from: &arguments) else {
                throw CLIError("why requires --commitment <id>")
            }
            let store = try ObservationStore(fileURL: try stateURL("assistant.sqlite"))
            guard let evidence = try await store.commitmentEvidence(id: id) else {
                throw CLIError("commitment not found: \(id)")
            }
            let formatter = ISO8601DateFormatter()
            print("Commitment [\(evidence.commitment.id)]")
            print("  status: \(evidence.commitment.status.rawValue)")
            print("  due: \(formatter.string(from: evidence.commitment.dueAt))")
            print("  matched cue: \(evidence.commitment.dueText)")
            print("  extractor: \(evidence.commitment.extractorID)")
            print("\nSource evidence")
            if let timestamp = evidence.observation.sourceTimestamp {
                print("  sent: \(formatter.string(from: timestamp))")
            }
            print("  text: \(evidence.observation.text)")
            print("  locator: \(evidence.observation.locator)")

        case "complete-commitment":
            guard let id = takeOption("--commitment", from: &arguments) else {
                throw CLIError("complete-commitment requires --commitment <id>")
            }
            let store = try ObservationStore(fileURL: try stateURL("assistant.sqlite"))
            guard try await store.completeCommitment(id: id) else {
                throw CLIError("active commitment not found: \(id)")
            }
            print("Completed commitment \(id).")

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

    private static func indentedSummary(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }

    private static func printUsage() {
        print("""
        Usage:
          assistantctl doctor [--imsg <path>]
          assistantctl chats [--imsg <path>]
          assistantctl echo --chat-id <id> [--after <rowid>] [--imsg <path>]
          assistantctl serve --control-chat-id <id> [--imsg <path>]
          assistantctl proactive-status
          assistantctl pause
          assistantctl resume
          assistantctl index-messages --control-chat-id <id> [--imsg <path>]
          assistantctl index-calendar
          assistantctl index-contacts
          assistantctl source-status
          assistantctl meeting-context --person <exact name, nickname, phone, or email>
          assistantctl index-commitments [--days <1...365>]
          assistantctl forgetting
          assistantctl why --commitment <id>
          assistantctl complete-commitment --commitment <id>
        """)
    }
}

private struct CLIError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
