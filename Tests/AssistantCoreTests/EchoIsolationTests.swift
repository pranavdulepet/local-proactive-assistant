import Foundation
import Testing
@testable import AssistantCore

struct EchoIsolationTests {
    @Test func foreignChatRowsCannotSkipTheOwnersUnseenMessages() async throws {
        let owner = TransportChatID(rawValue: 42)
        let cursors = try CursorStore()
        let service = EchoService(transport: ForeignRowTransport(), ledger: try OutboundLedger(), cursorStore: cursors)
        var accepted = 0
        for try await event in service.events(chatID: owner, after: TransportCursor(rawValue: 10)) {
            if event.decision == .accept { accepted += 1 }
        }
        #expect(accepted == 1)
        #expect(await cursors.cursor(for: owner)?.rawValue == 11)
    }
}

private struct ForeignRowTransport: MessageTransport {
    func probe() async -> TransportHealth { TransportHealth(ready: true, detail: "fixture") }
    func chats() async throws -> [TransportChat] { [] }
    func subscribe(chatID: TransportChatID, after cursor: TransportCursor?) -> AsyncThrowingStream<InboundTransportMessage, Error> {
        AsyncThrowingStream { continuation in
            for (chat, row) in [(99, 999), (42, 11)] {
                continuation.yield(InboundTransportMessage(cursor: TransportCursor(rawValue: Int64(row)),
                    guid: "guid-\(row)", chatID: TransportChatID(rawValue: Int64(chat)),
                    text: "question", isFromMe: true, createdAt: Date()))
            }
            continuation.finish()
        }
    }
    func send(_ message: OutboundTransportMessage, to chatID: TransportChatID) async throws -> SendReceipt {
        SendReceipt(requestID: message.requestID, messageGUID: "reply-guid", rowID: 12, transport: "fixture")
    }
}
