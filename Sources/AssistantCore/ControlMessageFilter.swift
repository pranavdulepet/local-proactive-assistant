import Foundation

public enum RejectionReason: String, Equatable, Sendable {
    case outboundEcho
    case empty
    case replayed
    case wrongChat
}

public enum InboundDecision: Equatable, Sendable {
    case accept
    case reject(RejectionReason)
}

public struct ControlMessageFilter: Sendable {
    private let controlChatID: TransportChatID
    private let ledger: OutboundLedger

    public init(controlChatID: TransportChatID, ledger: OutboundLedger) {
        self.controlChatID = controlChatID
        self.ledger = ledger
    }

    public func evaluate(
        _ message: InboundTransportMessage,
        after cursor: TransportCursor?,
        now: Date = Date()
    ) async throws -> InboundDecision {
        if try await ledger.contains(
            messageGUID: message.guid,
            chatID: message.chatID,
            at: now
        ) {
            return .reject(.outboundEcho)
        }

        if try await ledger.contains(
            text: message.text,
            chatID: message.chatID,
            messageDate: message.createdAt,
            at: now
        ) {
            return .reject(.outboundEcho)
        }

        if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .reject(.empty)
        }

        if let cursor, message.cursor <= cursor {
            return .reject(.replayed)
        }

        guard message.chatID == controlChatID else {
            return .reject(.wrongChat)
        }

        return .accept
    }
}
