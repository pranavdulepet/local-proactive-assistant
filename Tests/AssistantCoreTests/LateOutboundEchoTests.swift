import Foundation
import Testing
@testable import AssistantCore

struct LateOutboundEchoTests {
    @Test func savedAliasEchoStaysSuppressedAfterRestartBeyondTheShortSendWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("ledger.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sent = Date()
        let phone = TransportChatID(rawValue: 954), email = TransportChatID(rawValue: 955)
        let ledger = try OutboundLedger(fileURL: file)
        let request = UUID()
        try await ledger.begin(requestID: request, chatID: phone, text: "Your meeting is at noon.", sentAt: sent)
        try await ledger.confirm(requestID: request, messageGUID: "outbound-guid")
        let restored = try OutboundLedger(fileURL: file)
        let filter = ControlMessageFilter(controlChatID: email, ledger: restored, echoChatIDs: [phone, email])
        let echo = InboundTransportMessage(cursor: TransportCursor(rawValue: 20), guid: "received-alias-guid",
            chatID: email, text: "Your meeting is at noon.", isFromMe: false, createdAt: sent.addingTimeInterval(2))
        #expect(try await filter.evaluate(echo, after: nil, now: sent.addingTimeInterval(3_600)) == .reject(.outboundEcho))
        let owner = InboundTransportMessage(cursor: TransportCursor(rawValue: 21), guid: "owner-guid",
            chatID: email, text: echo.text, isFromMe: true, createdAt: sent.addingTimeInterval(3_600))
        #expect(try await filter.evaluate(owner, after: nil, now: sent.addingTimeInterval(3_600)) == .accept)
    }
}
