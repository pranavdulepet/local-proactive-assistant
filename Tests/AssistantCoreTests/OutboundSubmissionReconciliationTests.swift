import Foundation
import Testing
@testable import AssistantCore

struct OutboundSubmissionReconciliationTests {
    private let phone = TransportChatID(rawValue: 954)
    private let email = TransportChatID(rawValue: 955)
    private let started = Date(timeIntervalSince1970: 1_790_000_000)
    private let text = "Assistant: Your calendar review is tomorrow at 10."

    @Test func otherVerifiedAliasConfirmsAnOutgoingRowAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ledger.json")
        let ledger = try OutboundLedger(fileURL: file)
        let request = UUID()
        _ = try await ledger.begin(requestID: request, chatID: email, text: text, sentAt: started)
        try await ledger.markRecovered(requestID: request)
        let restarted = try OutboundLedger(fileURL: file)
        let row = message(guid: "actual-guid", chat: phone)
        let receipt = try #require(try await restarted.reconcileSubmission(row, in: [phone, email]))
        #expect(receipt.requestID == request)
        #expect(receipt.messageGUID == "actual-guid")
        #expect(receipt.rowID == 200)
        #expect(try await restarted.contains(messageGUID: "actual-guid", chatID: email,
            at: started.addingTimeInterval(5)))
        let confirmed = try OutboundLedger(fileURL: file)
        #expect(await confirmed.confirmedReceipt(requestID: request)?.messageGUID == "actual-guid")
    }

    @Test func incomingOldForeignOrDifferentTextCannotConfirmSubmission() async throws {
        let ledger = try OutboundLedger()
        _ = try await ledger.begin(requestID: UUID(), chatID: email, text: text, sentAt: started)
        let invalid = [
            message(guid: "incoming", chat: phone, fromMe: false),
            message(guid: "foreign", chat: .init(rawValue: 3)),
            message(guid: "old", chat: phone, offset: -1),
            message(guid: "late", chat: phone, offset: 121),
            message(guid: "", chat: phone),
            message(guid: "different", chat: phone, content: text + " "),
        ]
        for row in invalid {
            #expect(try await ledger.reconcileSubmission(row, in: [phone, email]) == nil)
        }
    }

    @Test func multipleRowsOrMultipleSendIntentsRemainUncertain() async throws {
        let ledger = try OutboundLedger()
        let first = try await ledger.begin(requestID: UUID(), chatID: email, text: text, sentAt: started)
        let row = message(guid: "first", chat: phone)
        let duplicate = message(guid: "second", chat: phone)
        #expect(OutboundLedger.submissionReceipt(for: first, messages: [row, duplicate], in: [phone, email]) == nil)
        _ = try await ledger.begin(requestID: UUID(), chatID: phone, text: text, sentAt: started)
        #expect(try await ledger.reconcileSubmission(row, in: [phone, email]) == nil)
    }

    @Test func onePhysicalGUIDJoinedToBothAliasesIsOneSubmission() async throws {
        let ledger = try OutboundLedger()
        let entry = try await ledger.begin(requestID: UUID(), chatID: email, text: text, sentAt: started)
        let rows = [message(guid: "same-physical-guid", chat: phone),
                    message(guid: "same-physical-guid", chat: email)]
        let receipt = OutboundLedger.submissionReceipt(for: entry, messages: rows, in: [phone, email])
        #expect(receipt?.requestID == entry.requestID)
        #expect(receipt?.messageGUID == "same-physical-guid")
    }

    private func message(guid: String, chat: TransportChatID, fromMe: Bool = true,
                         offset: TimeInterval = 1, content: String? = nil) -> InboundTransportMessage {
        InboundTransportMessage(cursor: .init(rawValue: 200), guid: guid, chatID: chat,
            text: content ?? text, isFromMe: fromMe, createdAt: started.addingTimeInterval(offset))
    }
}

struct EchoSubmissionReconciliationTests {
    @Test func foreignWatchRowCannotMoveThisAliasesCursorEvenWhenItsContentMatches() async throws {
        let email = TransportChatID(rawValue: 955), phone = TransportChatID(rawValue: 954)
        let started = Date()
        let ledger = try OutboundLedger()
        _ = try await ledger.begin(requestID: UUID(), chatID: email, text: "Assistant: Ready.", sentAt: started)
        let outgoing = InboundTransportMessage(cursor: .init(rawValue: 200), guid: "other-alias-guid",
            chatID: phone, text: "Assistant: Ready.", isFromMe: true, createdAt: started.addingTimeInterval(1))
        let transport = ReconciliationTransport(input: outgoing, outgoingChat: phone, observesSubmission: false)
        let cursors = CursorStore()
        let service = EchoService(transport: transport, ledger: ledger, cursorStore: cursors,
            echoChatIDs: [email, phone])
        var events: [EchoEvent] = []
        for try await event in service.events(chatID: email) { events.append(event) }
        #expect(events.first?.decision == .reject(.wrongChat))
        #expect(await cursors.cursor(for: email) == nil)
        #expect(await transport.sendCount() == 0)
    }

    @Test func uncertainCommandSendUsesAliasReceiptWithoutSendingAgain() async throws {
        let email = TransportChatID(rawValue: 955), phone = TransportChatID(rawValue: 954)
        let input = InboundTransportMessage(cursor: .init(rawValue: 100), guid: "owner-command",
            chatID: email, text: "/status", isFromMe: true, createdAt: Date())
        let transport = ReconciliationTransport(input: input, outgoingChat: phone, observesSubmission: true)
        let ledger = try OutboundLedger()
        let service = EchoService(transport: transport, ledger: ledger,
            reply: { _ in "Assistant: Ready." }, echoChatIDs: [email, phone])
        var events: [EchoEvent] = []
        for try await event in service.events(chatID: email) { events.append(event) }
        #expect(events.count == 1)
        #expect(events.first?.sendOutcome == .confirmed)
        #expect(events.first?.receipt?.messageGUID == "actual-outgoing-guid")
        #expect(await transport.sendCount() == 1)
    }

    @Test func unobservedCommandSendStaysUncertainAndIsNotRetried() async throws {
        let email = TransportChatID(rawValue: 955), phone = TransportChatID(rawValue: 954)
        let input = InboundTransportMessage(cursor: .init(rawValue: 100), guid: "owner-command",
            chatID: email, text: "/status", isFromMe: true, createdAt: Date())
        let transport = ReconciliationTransport(input: input, outgoingChat: phone, observesSubmission: false)
        let service = EchoService(transport: transport, ledger: try OutboundLedger(),
            reply: { _ in "Assistant: Ready." }, echoChatIDs: [email, phone])
        var events: [EchoEvent] = []
        for try await event in service.events(chatID: email) { events.append(event) }
        #expect(events.first?.sendOutcome == .uncertain)
        #expect(events.first?.receipt == nil)
        #expect(await transport.sendCount() == 1)
    }

    @Test func lateAliasCatchupSavesActualGUIDAndNotifiesHostWithoutAReply() async throws {
        let email = TransportChatID(rawValue: 955), phone = TransportChatID(rawValue: 954)
        let started = Date()
        let ledger = try OutboundLedger()
        let request = UUID()
        let text = "Assistant: Ready."
        _ = try await ledger.begin(requestID: request, chatID: email, text: text, sentAt: started)
        try await ledger.markRecovered(requestID: request)
        let outgoing = InboundTransportMessage(cursor: .init(rawValue: 200), guid: "late-outgoing-guid",
            chatID: phone, text: text, isFromMe: true, createdAt: started.addingTimeInterval(1))
        let transport = ReconciliationTransport(input: outgoing, outgoingChat: phone, observesSubmission: false)
        let notifications = ReconciledReceiptBox()
        let service = EchoService(transport: transport, ledger: ledger, echoChatIDs: [email, phone],
            onSubmissionReconciled: { await notifications.append($0) })
        var events: [EchoEvent] = []
        for try await event in service.events(chatID: phone) { events.append(event) }
        #expect(events.first?.decision == .reject(.outboundEcho))
        #expect(await notifications.receipts().map(\.requestID) == [request])
        #expect(await ledger.confirmedReceipt(requestID: request)?.messageGUID == "late-outgoing-guid")
        #expect(await transport.sendCount() == 0)
    }
}

private actor ReconciledReceiptBox {
    private var values: [SendReceipt] = []
    func append(_ receipt: SendReceipt) { values.append(receipt) }
    func receipts() -> [SendReceipt] { values }
}

private actor ReconciliationTransport: MessageTransport {
    private let input: InboundTransportMessage
    private let outgoingChat: TransportChatID
    private let observesSubmission: Bool
    private var count = 0
    private var sentText = ""
    init(input: InboundTransportMessage, outgoingChat: TransportChatID, observesSubmission: Bool) {
        self.input = input; self.outgoingChat = outgoingChat; self.observesSubmission = observesSubmission
    }
    func probe() -> TransportHealth { .init(ready: true, detail: "fixture") }
    func chats() -> [TransportChat] { [] }
    nonisolated func subscribe(chatID: TransportChatID, after cursor: TransportCursor?) -> AsyncThrowingStream<InboundTransportMessage, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(input)
            continuation.finish()
        }
    }
    func send(_ message: OutboundTransportMessage, to chatID: TransportChatID) throws -> SendReceipt {
        count += 1; sentText = message.text
        throw TransportFailure("Delivery outcome unknown")
    }
    func reconcileSubmission(for entry: OutboundLedgerEntry, in verifiedChatIDs: Set<TransportChatID>) -> SendReceipt? {
        guard observesSubmission else { return nil }
        let outgoing = InboundTransportMessage(cursor: .init(rawValue: 200), guid: "actual-outgoing-guid",
            chatID: outgoingChat, text: sentText, isFromMe: true, createdAt: entry.sentAt.addingTimeInterval(1))
        return OutboundLedger.submissionReceipt(for: entry, messages: [outgoing], in: verifiedChatIDs)
    }
    func sendCount() -> Int { count }
}
