import Foundation
import Testing
@testable import AssistantCore

struct ControlMessageFilterTests {
    private let chatID = TransportChatID(rawValue: 42)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func acceptsANewControlMessage() async throws {
        let ledger = try OutboundLedger()
        let filter = ControlMessageFilter(controlChatID: chatID, ledger: ledger)

        let decision = try await filter.evaluate(
            message(text: "hello", cursor: 11),
            after: TransportCursor(rawValue: 10),
            now: now
        )

        #expect(decision == .accept)
    }

    @Test
    func rejectsAnEchoByGUID() async throws {
        let ledger = try OutboundLedger()
        let requestID = UUID()
        try await ledger.begin(
            requestID: requestID,
            chatID: chatID,
            text: "echo: hello",
            sentAt: now
        )
        try await ledger.confirm(requestID: requestID, messageGUID: "outbound-guid")

        let filter = ControlMessageFilter(controlChatID: chatID, ledger: ledger)
        let decision = try await filter.evaluate(
            message(text: "different rendering", cursor: 12, guid: "outbound-guid"),
            after: nil,
            now: now
        )

        #expect(decision == .reject(.outboundEcho))
    }

    @Test
    func rejectsAnEchoByContentAndTimeWhenGUIDIsUnavailable() async throws {
        let ledger = try OutboundLedger()
        try await ledger.begin(
            requestID: UUID(),
            chatID: chatID,
            text: "echo: hello",
            sentAt: now
        )

        let filter = ControlMessageFilter(controlChatID: chatID, ledger: ledger)
        let decision = try await filter.evaluate(
            message(text: "echo: hello", cursor: 12, createdAt: now.addingTimeInterval(2)),
            after: nil,
            now: now
        )

        #expect(decision == .reject(.outboundEcho))
    }

    @Test
    func doesNotSuppressAnOldIdenticalOwnerMessage() async throws {
        let ledger = try OutboundLedger()
        try await ledger.begin(
            requestID: UUID(),
            chatID: chatID,
            text: "same words",
            sentAt: now
        )

        let filter = ControlMessageFilter(controlChatID: chatID, ledger: ledger)
        let decision = try await filter.evaluate(
            message(text: "same words", cursor: 12, createdAt: now.addingTimeInterval(31)),
            after: nil,
            now: now
        )

        #expect(decision == .accept)
    }

    @Test
    func rejectsEmptyEvents() async throws {
        let ledger = try OutboundLedger()
        let filter = ControlMessageFilter(controlChatID: chatID, ledger: ledger)

        let decision = try await filter.evaluate(
            message(text: "   ", cursor: 11),
            after: TransportCursor(rawValue: 10),
            now: now
        )

        #expect(decision == .reject(.empty))
    }

    @Test
    func rejectsReplayedRows() async throws {
        let ledger = try OutboundLedger()
        let filter = ControlMessageFilter(controlChatID: chatID, ledger: ledger)

        let decision = try await filter.evaluate(
            message(text: "hello", cursor: 10),
            after: TransportCursor(rawValue: 10),
            now: now
        )

        #expect(decision == .reject(.replayed))
    }

    @Test
    func rejectsMessagesFromAnotherChat() async throws {
        let ledger = try OutboundLedger()
        let filter = ControlMessageFilter(controlChatID: chatID, ledger: ledger)
        let otherChatMessage = InboundTransportMessage(
            cursor: TransportCursor(rawValue: 11),
            guid: UUID().uuidString,
            chatID: TransportChatID(rawValue: 84),
            text: "hello",
            isFromMe: true,
            createdAt: now
        )

        let decision = try await filter.evaluate(
            otherChatMessage,
            after: TransportCursor(rawValue: 10),
            now: now
        )

        #expect(decision == .reject(.wrongChat))
    }

    private func message(
        text: String,
        cursor: Int64,
        guid: String = UUID().uuidString,
        createdAt: Date? = nil
    ) -> InboundTransportMessage {
        InboundTransportMessage(
            cursor: TransportCursor(rawValue: cursor),
            guid: guid,
            chatID: chatID,
            text: text,
            isFromMe: true,
            createdAt: createdAt ?? now
        )
    }
}
