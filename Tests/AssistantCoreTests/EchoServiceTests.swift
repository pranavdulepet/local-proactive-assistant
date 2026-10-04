import Foundation
import Testing
@testable import AssistantCore

struct EchoServiceTests {
    private let chatID = TransportChatID(rawValue: 42)

    @Test
    func reconnectsAfterRetrySafeWatchFailure() async throws {
        let cursorStore = CursorStore()
        try await cursorStore.advance(
            chatID: chatID,
            to: TransportCursor(rawValue: 100)
        )
        let transport = ScriptedTransport(
            steps: [
                .failure(TransportFailure("watch stopped", retrySafe: true)),
                .messages([message(cursor: 101, text: "hello")]),
            ]
        )
        let service = EchoService(
            transport: transport,
            ledger: try OutboundLedger(),
            cursorStore: cursorStore,
            reconnectDelay: { _ in 0 }
        )

        var received: EchoEvent?
        for try await event in service.events(
            chatID: chatID,
            after: TransportCursor(rawValue: 90)
        ) {
            received = event
            break
        }

        let cursor = await cursorStore.cursor(for: chatID)
        #expect(received?.decision == .accept)
        #expect(cursor == TransportCursor(rawValue: 101))
        #expect(
            transport.requestedCursors == [
                TransportCursor(rawValue: 100),
                TransportCursor(rawValue: 100),
            ]
        )
    }

    @Test
    func checkpointsIgnoredOutboundEchoes() async throws {
        let ledger = try OutboundLedger()
        let requestID = UUID()
        try await ledger.begin(
            requestID: requestID,
            chatID: chatID,
            text: "echo: hello"
        )
        try await ledger.confirm(
            requestID: requestID,
            messageGUID: "outbound-guid"
        )

        let cursorStore = CursorStore()
        let transport = ScriptedTransport(
            steps: [
                .messages([
                    message(
                        cursor: 102,
                        text: "echo: hello",
                        guid: "outbound-guid"
                    ),
                ]),
            ]
        )
        let service = EchoService(
            transport: transport,
            ledger: ledger,
            cursorStore: cursorStore
        )

        var received: EchoEvent?
        for try await event in service.events(chatID: chatID) {
            received = event
            break
        }

        let cursor = await cursorStore.cursor(for: chatID)
        #expect(received?.decision == .reject(.outboundEcho))
        #expect(cursor == TransportCursor(rawValue: 102))
    }

    @Test
    func checkpointsAcceptedMessagesWhenTheHandlerDoesNotReply() async throws {
        let cursorStore = CursorStore()
        let transport = ScriptedTransport(
            steps: [.messages([message(cursor: 103, text: "note to self")])]
        )
        let service = EchoService(
            transport: transport,
            ledger: try OutboundLedger(),
            cursorStore: cursorStore,
            reply: { _ in nil }
        )

        var received: EchoEvent?
        for try await event in service.events(chatID: chatID) {
            received = event
            break
        }

        let cursor = await cursorStore.cursor(for: chatID)
        #expect(received?.decision == .accept)
        #expect(received?.receipt == nil)
        #expect(transport.sentMessages.isEmpty)
        #expect(cursor == TransportCursor(rawValue: 103))
    }

    @Test
    func uncertainSendKeepsHostAliveAndDoesNotReplayCommand() async throws {
        let cursorStore = CursorStore()
        let transport = ScriptedTransport(
            steps: [.messages([
                message(cursor: 201, text: "/status"),
                message(cursor: 202, text: "/help"),
            ])],
            uncertainFirstSend: true
        )
        let service = EchoService(
            transport: transport,
            ledger: try OutboundLedger(),
            cursorStore: cursorStore
        )
        var outcomes: [EchoSendOutcome] = []
        for try await event in service.events(chatID: chatID) {
            outcomes.append(event.sendOutcome)
        }

        #expect(outcomes == [.uncertain, .confirmed])
        #expect(await cursorStore.cursor(for: chatID) == TransportCursor(rawValue: 202))
        #expect(transport.sentMessages.count == 2)

        let restarted = EchoService(
            transport: ScriptedTransport(steps: [.messages([message(cursor: 201, text: "/status")])]),
            ledger: try OutboundLedger(),
            cursorStore: cursorStore
        )
        for try await event in restarted.events(chatID: chatID) {
            #expect(event.decision == .reject(.replayed))
        }
    }

    private func message(
        cursor: Int64,
        text: String,
        guid: String = UUID().uuidString
    ) -> InboundTransportMessage {
        InboundTransportMessage(
            cursor: TransportCursor(rawValue: cursor),
            guid: guid,
            chatID: chatID,
            text: text,
            isFromMe: true,
            createdAt: Date()
        )
    }
}

private final class ScriptedTransport: MessageTransport, @unchecked Sendable {
    enum Step: Sendable {
        case failure(TransportFailure)
        case messages([InboundTransportMessage])
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var cursors: [TransportCursor?] = []
    private var messages: [OutboundTransportMessage] = []
    private let uncertainFirstSend: Bool

    init(steps: [Step], uncertainFirstSend: Bool = false) {
        self.steps = steps
        self.uncertainFirstSend = uncertainFirstSend
    }

    var requestedCursors: [TransportCursor?] {
        lock.withLock { cursors }
    }

    var sentMessages: [OutboundTransportMessage] {
        lock.withLock { messages }
    }

    func probe() async -> TransportHealth {
        TransportHealth(ready: true, detail: "ready")
    }

    func chats() async throws -> [TransportChat] {
        []
    }

    func subscribe(
        chatID: TransportChatID,
        after cursor: TransportCursor?
    ) -> AsyncThrowingStream<InboundTransportMessage, Error> {
        let step = lock.withLock {
            cursors.append(cursor)
            return steps.isEmpty ? nil : steps.removeFirst()
        }

        return AsyncThrowingStream { continuation in
            switch step {
            case .failure(let error):
                continuation.finish(throwing: error)
            case .messages(let messages):
                for message in messages {
                    continuation.yield(message)
                }
                continuation.finish()
            case nil:
                continuation.finish()
            }
        }
    }

    func send(
        _ message: OutboundTransportMessage,
        to chatID: TransportChatID
    ) async throws -> SendReceipt {
        let sendNumber = lock.withLock { () -> Int in
            messages.append(message)
            return messages.count
        }
        if uncertainFirstSend && sendNumber == 1 {
            throw TransportFailure("Delivery outcome unknown", retrySafe: false)
        }
        return SendReceipt(
            requestID: message.requestID,
            messageGUID: UUID().uuidString,
            rowID: nil,
            transport: "test"
        )
    }
}
