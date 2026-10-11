import Foundation
import Testing
@testable import AssistantCore

struct OutboundRecoveryTests {
    @Test
    func decodesLegacyUnconfirmedEntryAndSettlesWithoutRemovingEchoSuppression() async throws {
        let chat = TransportChatID(rawValue: 42)
        let requestID = UUID()
        let entry = OutboundLedgerEntry(
            requestID: requestID, chatID: chat,
            normalizedContentHash: OutboundLedger.contentHash("reply"),
            transportMessageGUID: nil, sentAt: Date(),
            expiresAt: Date().addingTimeInterval(120)
        )
        var legacy = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]
        )
        legacy.removeValue(forKey: "needsRecovery")
        let decoded = try JSONDecoder().decode(
            OutboundLedgerEntry.self, from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decoded.needsRecovery)

        let ledger = try OutboundLedger()
        try await ledger.begin(requestID: requestID, chatID: chat, text: "reply")
        #expect(await ledger.pendingRecoveryChatIDs() == Set([chat]))
        try await ledger.markRecovered(chatID: chat)
        #expect(await ledger.pendingRecoveryChatIDs().isEmpty)
        #expect(try await ledger.contains(
            text: "reply", chatID: chat, messageDate: Date()
        ))
        let filter = ControlMessageFilter(controlChatID: chat, ledger: ledger)
        let cursor = TransportCursor(rawValue: 100)
        let echo = InboundTransportMessage(
            cursor: .init(rawValue: 101), guid: "outbound", chatID: chat,
            text: "reply", isFromMe: true, createdAt: Date()
        )
        let nextQuestion = InboundTransportMessage(
            cursor: .init(rawValue: 102), guid: "new-question", chatID: chat,
            text: "What next?", isFromMe: true, createdAt: Date()
        )
        #expect(try await filter.evaluate(echo, after: cursor) == .reject(.outboundEcho))
        #expect(try await filter.evaluate(nextQuestion, after: cursor) == .accept)
    }
}
