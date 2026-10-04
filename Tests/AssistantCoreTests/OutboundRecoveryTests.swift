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
        #expect(await ledger.pendingRecoveryChatIDs() == [chat])
        try await ledger.markRecovered(chatID: chat)
        #expect(await ledger.pendingRecoveryChatIDs().isEmpty)
        #expect(try await ledger.contains(
            text: "reply", chatID: chat, messageDate: Date()
        ))
    }
}
