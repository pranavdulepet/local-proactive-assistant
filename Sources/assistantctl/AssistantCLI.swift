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
import MacContextAdapter
import MailAdapter
import PhoneSync

@main
struct AssistantCLI {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let quiet = takeFlag("--quiet", from: &arguments)
        let verbose = takeFlag("--verbose", from: &arguments)
            || ProcessInfo.processInfo.environment["ASSISTANT_DEBUG"] == "1"
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
            let model = takeOption("--model", from: &arguments) ?? "apple"
            let localURL = takeOption("--model-url", from: &arguments)
            let localName = takeOption("--model-name", from: &arguments)
            let provider = try selectedModel(model, url: localURL, name: localName)
            let state = await provider.availability()
            if !quiet || !state.ready {
                print("\(provider.modelID): \(state.ready ? "ready" : "unavailable")")
                print(state.detail)
            }
            if !state.ready { exit(1) }

        case "prepare-access":
            if !quiet { print("Allow access to the local apps you want to use when macOS asks.") }
            let store = try ObservationStore(fileURL: try stateURL("assistant.sqlite"))
            let access = try SourceAccessRegistry(fileURL: try stateURL("source-access.json"))
            let source = IndexedContextSource(store: store, mail: MailStoreSource(),
                additional: MacContextSource(requestPermissions: true), access: access)
            var unavailable = 0
            for tool in [ContextTool.mailInbox, .notes, .reminders, .photos] {
                do {
                    if tool == .mailInbox {
                        _ = try await source.execute(ContextToolCall(tool: .mailInbox, limit: 1))
                    } else {
                        _ = try await source.execute(ContextToolCall(tool: tool))
                    }
                    if !quiet { print("\(SourceAccessRegistry.name(tool)): readable. Search coverage is reported with each answer.") }
                } catch {
                    unavailable += 1
                    try? await access.record(tool: tool, ready: false, detail: String(describing: error))
                    print("\(error)")
                }
            }
            if unavailable > 0 {
                if !quiet { print("Chat can use the readable sources. Run prepare-access again to retry unavailable apps.") }
                exit(1)
            }

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
            if !quiet || !health.ready {
                print("Messages: \(health.ready ? "ready" : "unavailable")")
                if let version = health.version, verbose { print("imsg \(version)") }
                print(health.detail)
            }
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
            let lease = try HostLease(fileURL: stateURL("host.lock"))
            defer { withExtendedLifetime(lease) {} }
            let model = takeOption("--model", from: &arguments)
            let localURL = takeOption("--model-url", from: &arguments)
            let localName = takeOption("--model-name", from: &arguments)
            let provider = try model.map { try selectedModel($0, url: localURL, name: localName) }
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
                if verbose { print("Contacts Me card unavailable; using verified self routes.") }
            }
            let selfChats = SelfChatRoutes.resolve(
                primary: selectedChat, available: availableChats, ownerHandles: ownerHandles
            )
            let replyRoute = SelfChatRoutes.replyRoute(primary: selectedChat, verified: selfChats)
            if verbose {
                print("Owner routes: " + selfChats.map { String($0.id.rawValue) }.joined(separator: ", "))
                print("All replies use chat \(replyRoute.id.rawValue).")
            }
            let ledger = try OutboundLedger(fileURL: try stateURL("outbound-ledger.json"))
            let cursorStore = try CursorStore(fileURL: try stateURL("cursors.json"))
            let pendingChats = await ledger.pendingRecoveryChatIDs()
            for route in selfChats where pendingChats.contains(route.id) {
                // An uncertain outgoing send may have produced an echo. Keep the
                // ledger hash for suppression, but never skip unseen incoming rows.
                try await ledger.markRecovered(chatID: route.id)
                if verbose { print("Chat \(route.id.rawValue): catching up without resending uncertain replies.") }
            }
            let databaseURL = try stateURL("assistant.sqlite")
            let store = try ObservationStore(fileURL: databaseURL)
            try await store.recoverInterruptedReminders()
            // Commands and model retrieval use separate WAL readers. Neither
            // waits in the indexing actor's queue, and a long retrieval cannot
            // delay /status or /pause.
            let commandStore = try ObservationStore(fileURL: databaseURL)
            let answerStore = try ObservationStore(fileURL: databaseURL)
            let chatHistory = try ConversationHistory(fileURL: try stateURL("conversation-history.json"))
            let phoneSync: PhoneSyncServer?
            if let identity = try MacPhoneIdentity.load() {
                phoneSync = try PhoneSyncServer(identity: identity, store: store)
                phoneSync?.start()
                if verbose { print("Phone sync: local HTTPS port \(identity.pairing.server.port ?? 8765).") }
            } else { phoneSync = nil }
            defer { phoneSync?.stop() }
            let ownerRouteIDs = Set(selfChats.map(\.id))
            let controlTransport = PollingIMsgTransport(base: transport,
                replyChatID: replyRoute.id, ownerChatIDs: ownerRouteIDs)
            let inbox = try ConversationInbox(fileURL: try stateURL("conversation-inbox.json"))
            var readRoots: [URL] = []
            while let root = takeOption("--read-root", from: &arguments) {
                readRoots.append(URL(fileURLWithPath: root, isDirectory: true))
            }
            let localReads = MacContextSource(allowedRoots: readRoots.isEmpty ? nil : MacContextSource.defaultRoots + readRoots)
            let access = try SourceAccessRegistry(fileURL: try stateURL("source-access.json"))
            let contextSource = IndexedContextSource(
                store: answerStore, mail: MailStoreSource(), additional: localReads, access: access
            )
            let conversation = provider.map { selected in ModelConversationService(
                store: answerStore, provider: selected, transport: controlTransport,
                ledger: ledger, chatID: chat, history: chatHistory, inbox: inbox,
                mail: MailStoreSource(), contextSource: contextSource,
                contextTools: ContextTool.allCases, verbose: verbose, replyPrefix: "Assistant: ",
                ownerChatIDs: ownerRouteIDs
            ) }
            let sessions: [ControlSession] = selfChats.map { route in
                let service = EchoService(
                    transport: controlTransport,
                    ledger: ledger,
                    cursorStore: cursorStore,
                    replyMessage: { message in
                        let answerQuestion: (@Sendable (String) async throws -> String?)?
                        if let conversation {
                            let key = message.guid.isEmpty
                                ? "\(route.id.rawValue):row:\(message.cursor.rawValue)" : "guid:\(message.guid)"
                            answerQuestion = { question in
                                try await conversation.begin(question: question, to: route.id, sourceID: key)
                            }
                        } else { answerQuestion = nil }
                        let handler = ControlCommandHandler(store: commandStore, inbox: inbox,
                            access: access, answerQuestion: answerQuestion)
                        return try await handler.response(to: message.text).map { "Assistant: " + $0 }
                    },
                    checkpointAfterReply: true,
                    onReconnect: { attempt, delay, detail in
                        print("chat \(route.id.rawValue) catchup interrupted: \(detail); "
                            + "retrying in \(Int(delay))s (attempt \(attempt))")
                    },
                    onProgress: { cursor, detail in
                        guard verbose else { return }
                        print("chat \(route.id.rawValue) row \(cursor.rawValue): \(detail)")
                    },
                    echoChatIDs: ownerRouteIDs,
                    onSubmissionReconciled: { receipt in
                        try? await inbox.reconcile(requestID: receipt.requestID)
                    }
                )
                return ControlSession(chatID: route.id, service: service, conversation: conversation)
            }
            print("Ready. Text your Messages self-chat from your iPhone.")
            print("/status shows source access. Control-C stops the assistant.")
            if ProcessInfo.processInfo.environment["ASSISTANT_NATIVE_HOST"] == "1" {
                print("The menu bar app keeps the host running. This Mac must stay awake and online.")
            } else {
                print("Keep this window open and your Mac awake and online. Closing the lid can stop replies.")
            }
            if verbose { print("Refresh: Messages every minute; Calendar and Contacts every 15 minutes.") }
            if model != nil {
                let work = await inbox.counts()
                if verbose { print("Replies: \(work.queued) pending, \(work.uncertain) uncertain, \(work.failed) failed.") }
                await conversation?.resumePending()
                Task { await conversation?.reconcilePendingSubmissions() }
            }
            if selfChats.count == 1 && verbose {
                print("Only one route found. If your self-chat also uses another phone or email, "
                    + "add it with assistantctl add-self-handle --address <your address>.")
            }
            let refresh = HostRefreshService(
                messages: transport, calendar: EventKitCalendarSource(),
                contacts: ContactsStoreSource(), store: store,
                controlChatIDs: Set(selfChats.map(\.id))
            )
            let stopSignals = HostStopSignals()
            let reminders = ProactiveReminderService(store: store, transport: controlTransport,
                ledger: ledger, replyPrefix: "Assistant: ")
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await _ in stopSignals.events { return }
                    }
                    for session in sessions {
                        let resumeCursor = await cursorStore.cursor(for: session.chatID)
                        if let resumeCursor, verbose {
                            print("Chat \(session.chatID.rawValue) resumes after row \(resumeCursor.rawValue).")
                        }
                        group.addTask {
                            for try await event in session.service.events(
                                chatID: session.chatID, after: resumeCursor
                            ) {
                                if !verbose && (event.sendOutcome == .notAttempted || event.sendOutcome == .confirmed) { continue }
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
                                        print("chat \(session.chatID.rawValue) accepted row "
                                            + "\(event.inbound.cursor.rawValue); no immediate reply")
                                    }
                                case .reject(let reason):
                                    print("chat \(session.chatID.rawValue) ignored row "
                                        + "\(event.inbound.cursor.rawValue): \(reason.rawValue)")
                                }
                            }
                        }
                    }
                    group.addTask {
                        var unavailableSources = Set<ObservationSource>()
                        while !Task.isCancelled {
                            let report = try await refresh.refresh()
                            let failed = Set(report.failures)
                            for source in failed.subtracting(unavailableSources) {
                                print("\(source.rawValue) refresh unavailable; check permission/access. Commands remain available.")
                            }
                            // Calendar/Contacts are checked less often than Messages.
                            // Avoid repeating warnings during the same outage.
                            unavailableSources.formUnion(failed)
                            if report.messagesReady { unavailableSources.remove(.messages) }
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
                            await conversation?.reconcilePendingSubmissions()
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

        case "index-mail":
            let store = try ObservationStore(fileURL: try stateURL("assistant.sqlite"))
            let query = takeOption("--query", from: &arguments)
            let rawOffset = takeOption("--offset", from: &arguments) ?? "0"
            guard let offset = Int(rawOffset), (0...100_000).contains(offset) else {
                throw CLIError("Mail page offset must be between 0 and 100000.")
            }
            let snapshot = try await MailIngestor(source: MailStoreSource(), store: store)
                .refresh(query: query, offset: offset)
            for limitation in snapshot.coverageLimitations { print(limitation) }

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

    private static func selectedModel(_ model: String, url: String?, name: String?) throws -> any LocalModelProvider {
        switch model {
        case "apple": return MacModelProvider()
        case "ollama":
            guard let url, let parsed = URL(string: url), let name else {
                throw CLIError("Ollama needs --model-url http://127.0.0.1:11435 and --model-name <installed-model>.")
            }
            return try OllamaModelProvider(baseURL: parsed, modelName: name)
        case "local":
            guard let url, let parsed = URL(string: url), let name else {
                throw CLIError("Local model needs --model-url http://127.0.0.1:<port>/v1 and --model-name <installed-model>.")
            }
            return try LoopbackModelProvider(
                baseURL: parsed, modelName: name,
                reasoningEffort: ProcessInfo.processInfo.environment["ASSISTANT_LOCAL_REASONING_EFFORT"]
            )
        default:
            throw CLIError("Use --model apple, --model ollama or --model local.")
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

    private static func takeFlag(_ name: String, from arguments: inout [String]) -> Bool {
        guard let index = arguments.firstIndex(of: name) else { return false }
        arguments.remove(at: index)
        return true
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
          Add --quiet to setup checks or --verbose for diagnostic output.
          assistantctl doctor [--imsg <path>]
          assistantctl chats [--imsg <path>]
          assistantctl pair-chat [--imsg <path>]
          assistantctl add-self-handle --address <your phone or email>
          assistantctl echo --chat-id <id> [--after <rowid>] [--imsg <path>]
          assistantctl serve [--control-chat-id <id>] [--model apple|ollama|local] [--model-url <loopback-url> --model-name <model>] [--read-root <folder>] [--imsg <path>]
          assistantctl pair-phone [--host <local-hostname-or-LAN-IP>]
          assistantctl unpair-phone
          assistantctl model-status
          assistantctl prepare-access
          assistantctl model-eval
          assistantctl ask --question <question> [--person <exact person>]
          assistantctl export-context --question <question> [--person <exact person>] --output <file.lpa-context>
          assistantctl proactive-status
          assistantctl pause
          assistantctl resume
          assistantctl index-messages --control-chat-id <id> [--imsg <path>]
          assistantctl index-calendar
          assistantctl index-contacts
          assistantctl index-mail [--query <sender/topic/folder/date>] [--offset <page offset>]
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

/// Native and Terminal hosts use the same orderly shutdown path.
private final class HostStopSignals: @unchecked Sendable {
    let events: AsyncStream<Void>
    private let sources: [DispatchSourceSignal]
    init() {
        let pair = AsyncStream<Void>.makeStream()
        events = pair.stream
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { pair.continuation.yield(()); pair.continuation.finish() }
            source.resume()
            return source
        }
    }
    deinit { for source in sources { source.cancel() } }
}

/// One Mac host owns the paired inbox across all local model profiles.
private final class HostLease {
    private let descriptor: Int32
    init(fileURL: URL) throws {
        descriptor = open(fileURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CLIError("The host lock could not be opened.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CLIError("Another assistant is already running. Stop the Terminal or Mac app host before starting this one.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
