import AssistantCore
import AssistantStore
import ContactsAdapter
import Darwin
import EventKitAdapter
import Foundation
import IMsgTransport
import LocalInference
import MacModelBridge
import MacPhoneSync
import PhoneSync

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
        case "pair-phone":
            let host = takeOption("--host", from: &arguments) ?? ProcessInfo.processInfo.hostName
            let localHost = host.contains(".") ? host : host + ".local"
            let identity = try await MacPhoneIdentity.create(host: localHost)
            let path = try stateURL("phone-pairing.png")
            try await identity.showQR(at: path)
            print("Scan the QR code with your iPhone Camera to pair with \(identity.pairing.name).")
            print("Verify code \(identity.pairing.verificationCode) on the phone. Keep the code private.")
            print("Then start serve as usual. Phone summaries sync over your local network; no AI server is involved.")

        case "unpair-phone":
            try PairingKeychain.remove(account: "mac")
            try? FileManager.default.removeItem(at: try stateURL("phone-pairing.png"))
            print("Phone pairing revoked. Existing indexed evidence remains until removed; no further uploads are accepted.")

        case "model-status":
            let provider = MacModelProvider()
            let state = await provider.availability()
            print("\(provider.modelID): \(state.ready ? "ready" : "unavailable")")
            print(state.detail)
            if !state.ready { exit(1) }

        case "ask", "export-context":
            guard let question = takeOption("--question", from: &arguments) else {
                throw CLIError("\(command) requires --question <question>")
            }
            let person = takeOption("--person", from: &arguments)
            let store = try ObservationStore(fileURL: try stateURL("assistant.sqlite"))
            let request = try await EvidenceRetriever(store: store).request(question: question, meetingPerson: person)
            if command == "ask" {
                let result = try await AnswerService(provider: MacModelProvider()).answer(request)
                print(result.text)
            } else {
                guard let path = takeOption("--output", from: &arguments) else {
                    throw CLIError("export-context requires --output <file.lpa-context>")
                }
                let url = URL(fileURLWithPath: path)
                try ContextDocument.encode(request).write(to: url, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                print("Exported \(request.records.count) bounded records to \(url.path). This is a snapshot, not live sync.")
            }

        case "model-eval":
            let provider = MacModelProvider()
            let state = await provider.availability()
            guard state.ready else { throw CLIError(state.detail) }
            let request = EvidenceRequest(question: "What is the demo project deadline?", createdAt: Date(), records: [
                EvidenceRecord(id: "demo1", source: "demo", timestamp: nil, text: "The demo project deadline is Friday at 5 PM.", locator: "public demo fixture", trust: "ownerAuthored")
            ], coverage: ["Synthetic public fixture only; no personal data."])
            let start = Date()
            let answer = try await provider.answer(request)
            try answer.validate(for: request)
            guard !answer.insufficientEvidence else { throw CLIError("Model abstained on the supported demo fixture.") }
            print("Bounded output and citation checks passed in \(String(format: "%.1f", Date().timeIntervalSince(start)))s.")
            for claim in answer.claims { print("\(claim.text) [\(claim.evidenceIDs.joined(separator: ", "))]") }
            print("Review whether the claim accurately preserves Friday at 5 PM. Citation validation alone does not prove factual support.")

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

        case "pair-chat":
            let health = await transport.probe()
            guard health.ready else { throw CLIError("Messages is unavailable: \(health.detail)") }
            let code = "LOCAL-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
            print("On your iPhone, send \(code) to your private iMessage self-chat.")
            print("Waiting up to two minutes for that exact message...")
            var matchedChat: TransportChat?
            var matchedCursor: TransportCursor?
            for _ in 0..<60 {
                let matches = try await transport.matchingMessages(code)
                if let match = matches.first(where: { $0.isFromMe }) {
                    matchedCursor = match.cursor
                    matchedChat = try await transport.chats().first {
                        $0.id == match.chatID && !$0.isGroup && $0.service == "iMessage"
                    }
                    if matchedChat == nil {
                        throw CLIError("The code appeared outside a recent direct iMessage chat. Retry in your self-chat.")
                    }
                    break
                }
                try await Task.sleep(for: .seconds(2))
            }
            guard let matchedChat, let matchedCursor else {
                throw CLIError("No matching self-chat message arrived. Check Messages sync and retry.")
            }
            print("Found direct chat: \(matchedChat.displayName) [\(matchedChat.identifier)]")
            print("Is this your private self-chat? Type yes to use it: ", terminator: "")
            guard readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes" else {
                throw CLIError("Pairing cancelled; no chat was saved.")
            }
            let configURL = try stateURL("control-chat-id.txt")
            try FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let cursorStore = try CursorStore(fileURL: try stateURL("cursors.json"))
            try await cursorStore.advance(chatID: matchedChat.id, to: matchedCursor)
            try String(matchedChat.id.rawValue).write(to: configURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            print("Self-chat paired. Start with bash scripts/start.sh.")

        case "add-self-handle":
            guard let address = takeOption("--address", from: &arguments),
                  let normalized = SelfChatRoutes.canonical(address),
                  normalized.contains("@") || normalized.first?.isNumber == true
                    || normalized.hasPrefix("+") else {
                throw CLIError("Provide your own iMessage phone number or email with --address.")
            }
            let matches = try await transport.chats().filter {
                !$0.isGroup && $0.service == "iMessage"
                    && SelfChatRoutes.canonical($0.identifier) == normalized
            }
            guard !matches.isEmpty else {
                throw CLIError("No recent direct iMessage chat uses this address. Text it first, then retry.")
            }
            print("Add \(normalized) as one of your own self-chat addresses? Type yes: ", terminator: "")
            guard readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "yes" else {
                throw CLIError("No address was saved.")
            }
            let url = try stateURL("self-handles.json")
            var handles = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: url))) ?? []
            handles.append(normalized)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(Array(Set(handles)).sorted()).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            print("Saved your self-chat address. Restart bash scripts/start.sh to include its route.")

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
                    switch event.sendOutcome {
                    case .confirmed:
                        let guid = event.receipt?.messageGUID ?? "unverified"
                        print("accepted row \(event.inbound.cursor.rawValue); sent \(guid)")
                    case .notStarted:
                        print("row \(event.inbound.cursor.rawValue): send did not start; text again if needed")
                    case .uncertain:
                        print("row \(event.inbound.cursor.rawValue): delivery outcome unknown; not retried")
                    case .notAttempted:
                        print("row \(event.inbound.cursor.rawValue): no reply")
                    }
                case .reject(let reason):
                    print("ignored row \(event.inbound.cursor.rawValue): \(reason.rawValue)")
                }
            }

        case "serve":
            let model = takeOption("--model", from: &arguments)
            guard model == nil || model == "apple" else { throw CLIError("The supported local model is --model apple.") }
            let configuredChatID = try? String(contentsOf: stateURL("control-chat-id.txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawChatID = takeOption("--control-chat-id", from: &arguments) ?? configuredChatID,
                  let chatID = Int64(rawChatID), chatID > 0 else {
                throw CLIError("No self-chat paired. Run bash scripts/start.sh or pass --control-chat-id <id>.")
            }
            let hostLock = try HostLock(fileURL: try stateURL("host.lock"))
            defer { withExtendedLifetime(hostLock) {} }
            let chat = TransportChatID(rawValue: chatID)
            let availableChats = try await transport.chats()
            guard let selectedChat = availableChats.first(where: { $0.id == chat }),
                  !selectedChat.isGroup, selectedChat.service == "iMessage" else {
                throw CLIError("Control chat must appear in the recent chats and be a direct iMessage conversation. Send it a message, then retry.")
            }
            let savedHandles = (try? JSONDecoder().decode(
                [String].self, from: Data(contentsOf: stateURL("self-handles.json"))
            )) ?? []
            var ownerHandles = Set(savedHandles)
            do {
                ownerHandles.formUnion(try await ContactsStoreSource().selfHandles())
            } catch {
                print("Contacts Me card unavailable; using paired and manually verified self routes.")
            }
            let selfChats = SelfChatRoutes.resolve(
                primary: selectedChat, available: availableChats, ownerHandles: ownerHandles
            )
            print("Owner routes: " + selfChats.map { String($0.id.rawValue) }.joined(separator: ", "))
            let ledger = try OutboundLedger(fileURL: try stateURL("outbound-ledger.json"))
            let cursorStore = try CursorStore(fileURL: try stateURL("cursors.json"))
            let pendingChats = await ledger.pendingRecoveryChatIDs()
            for route in selfChats where pendingChats.contains(route.id) {
                let saved = await cursorStore.cursor(for: route.id) ?? TransportCursor(rawValue: 0)
                let latest = try await transport.latestChatCursor(in: route.id, after: saved)
                try await cursorStore.advance(chatID: route.id, to: latest)
                try await ledger.markRecovered(chatID: route.id)
                print("Chat \(route.id.rawValue): recovered an earlier unconfirmed send; "
                    + "skipped through row \(latest.rawValue) without resending. Text again if needed.")
            }
            let store = try ObservationStore(fileURL: try stateURL("assistant.sqlite"))
            try await store.recoverInterruptedReminders()
            let phoneSync: PhoneSyncServer?
            if let identity = try MacPhoneIdentity.load() {
                phoneSync = try PhoneSyncServer(identity: identity, store: store)
                phoneSync?.start()
                print("Paired phone sync listening on local HTTPS port \(identity.pairing.server.port ?? 8765).")
            } else { phoneSync = nil }
            defer { phoneSync?.stop() }
            let controlTransport = PollingIMsgTransport(base: transport)
            let ownerRouteIDs = Set(selfChats.map(\.id))
            let sessions: [ControlSession] = selfChats.map { route in
                let conversation = model == "apple" ? ModelConversationService(
                    store: store, provider: MacModelProvider(), transport: controlTransport,
                    ledger: ledger, chatID: route.id
                ) : nil
                let answerQuestion: (@Sendable (String) async -> String)?
                if let conversation {
                    answerQuestion = { question in await conversation.begin(question: question) }
                } else { answerQuestion = nil }
                let handler = ControlCommandHandler(store: store, answerQuestion: answerQuestion)
                let service = EchoService(
                    transport: controlTransport,
                    ledger: ledger,
                    cursorStore: cursorStore,
                    reply: { text in try await handler.response(to: text) },
                    onReconnect: { attempt, delay, detail in
                        print("chat \(route.id.rawValue) catchup interrupted: \(detail); "
                            + "retrying in \(Int(delay))s (attempt \(attempt))")
                    },
                    onProgress: { cursor, detail in
                        guard ProcessInfo.processInfo.environment["ASSISTANT_DEBUG"] == "1" else { return }
                        print("chat \(route.id.rawValue) row \(cursor.rawValue): \(detail)")
                    },
                    echoChatIDs: ownerRouteIDs
                )
                return ControlSession(chatID: route.id, service: service, conversation: conversation)
            }
            print("Serving owner commands. Press Control-C to stop.")
            print("Automatic refresh: Messages every 60s; Calendar/Contacts every 15m. Send /status, /pause or /resume.")
            if model != nil { print("Ready: text a question ending in ? in your Messages self-chat.") }
            if selfChats.count == 1 {
                print("Only one route found. If your self-chat also uses another phone or email, "
                    + "add it with assistantctl add-self-handle --address <your address>.")
            }
            let refresh = HostRefreshService(
                messages: transport, calendar: EventKitCalendarSource(),
                contacts: ContactsStoreSource(), store: store,
                controlChatIDs: Set(selfChats.map(\.id))
            )
            let reminders = ProactiveReminderService(store: store, transport: controlTransport, ledger: ledger)
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for session in sessions {
                        let resumeCursor = await cursorStore.cursor(for: session.chatID)
                        if let resumeCursor {
                            print("Chat \(session.chatID.rawValue) resumes after row \(resumeCursor.rawValue).")
                        }
                        group.addTask {
                            for try await event in session.service.events(
                                chatID: session.chatID, after: resumeCursor
                            ) {
                                switch event.decision {
                                case .accept:
                                    switch event.sendOutcome {
                                    case .confirmed:
                                        let guid = event.receipt?.messageGUID ?? "unverified"
                                        print("chat \(session.chatID.rawValue) handled row "
                                            + "\(event.inbound.cursor.rawValue); submitted \(guid)")
                                    case .notStarted:
                                        print("chat \(session.chatID.rawValue) row "
                                            + "\(event.inbound.cursor.rawValue): send did not start; text again if needed")
                                    case .uncertain:
                                        print("chat \(session.chatID.rawValue) row "
                                            + "\(event.inbound.cursor.rawValue): delivery outcome unknown; not retried")
                                    case .notAttempted:
                                        print("chat \(session.chatID.rawValue) ignored row "
                                            + "\(event.inbound.cursor.rawValue): not a command")
                                    }
                                case .reject(let reason):
                                    print("chat \(session.chatID.rawValue) ignored row "
                                        + "\(event.inbound.cursor.rawValue): \(reason.rawValue)")
                                }
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
            } catch {
                for session in sessions { await session.conversation?.cancel() }
                throw error
            }
            for session in sessions { await session.conversation?.cancel() }

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
          assistantctl pair-chat [--imsg <path>]
          assistantctl add-self-handle --address <your phone or email>
          assistantctl echo --chat-id <id> [--after <rowid>] [--imsg <path>]
          assistantctl serve [--control-chat-id <id>] [--model apple] [--imsg <path>]
          assistantctl pair-phone [--host <local-hostname-or-LAN-IP>]
          assistantctl unpair-phone
          assistantctl model-status
          assistantctl model-eval
          assistantctl ask --question <question> [--person <exact person>]
          assistantctl export-context --question <question> [--person <exact person>] --output <file.lpa-context>
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

private struct ControlSession: Sendable {
    let chatID: TransportChatID
    let service: EchoService
    let conversation: ModelConversationService?
}

private struct CLIError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
