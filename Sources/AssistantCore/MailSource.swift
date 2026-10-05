import Foundation

public struct MailMessageRecord: Codable, Equatable, Sendable {
    public let externalID: String
    public let sender: String
    public let subject: String
    public let receivedAt: Date
    public let unread: Bool
    public let body: String

    public init(externalID: String, sender: String, subject: String, receivedAt: Date, unread: Bool, body: String) {
        self.externalID = externalID
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
        self.unread = unread
        self.body = body
    }
}

/// A bounded view of Mail's Inbox, not a complete account export.
public struct MailSnapshot: Codable, Equatable, Sendable {
    public let messages: [MailMessageRecord]
    public let totalInbox: Int
    public let scanned: Int
    public let skipped: Int

    public init(messages: [MailMessageRecord], totalInbox: Int, scanned: Int, skipped: Int = 0) {
        self.messages = messages
        self.totalInbox = totalInbox
        self.scanned = scanned
        self.skipped = skipped
    }
}

public protocol MailSource: Sendable {
    func inboxSnapshot() async throws -> MailSnapshot
}

public struct MailSourceFailure: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}
