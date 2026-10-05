import Foundation

public struct MailMessageRecord: Codable, Equatable, Sendable {
    public let externalID: String
    public let sender: String
    public let subject: String
    public let receivedAt: Date
    public let unread: Bool
    public let body: String
    public let mailbox: String?
    public let bodyAvailable: Bool

    public init(externalID: String, sender: String, subject: String, receivedAt: Date, unread: Bool,
                body: String, mailbox: String? = nil, bodyAvailable: Bool = true) {
        self.externalID = externalID
        self.sender = sender
        self.subject = subject
        self.receivedAt = receivedAt
        self.unread = unread
        self.body = body
        self.mailbox = mailbox
        self.bodyAvailable = bodyAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case externalID, sender, subject, receivedAt, unread, body, mailbox, bodyAvailable
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        externalID = try values.decode(String.self, forKey: .externalID)
        sender = try values.decode(String.self, forKey: .sender)
        subject = try values.decode(String.self, forKey: .subject)
        receivedAt = try values.decode(Date.self, forKey: .receivedAt)
        unread = try values.decode(Bool.self, forKey: .unread)
        body = try values.decode(String.self, forKey: .body)
        mailbox = try values.decodeIfPresent(String.self, forKey: .mailbox)
        bodyAvailable = try values.decodeIfPresent(Bool.self, forKey: .bodyAvailable) ?? true
    }
}

public enum MailSearchScope: String, Codable, Sendable {
    case inbox
    case allMailboxes
}

/// A page of a local Mail search. Search coverage and returned evidence are separate limits.
public struct MailSnapshot: Codable, Equatable, Sendable {
    public let messages: [MailMessageRecord]
    /// Retained for existing clients; for all-mailbox searches this is the number of identified matches.
    public let totalInbox: Int
    public let scanned: Int
    public let skipped: Int
    public let scope: MailSearchScope
    public let matched: Int
    public let searchedMailboxes: Int
    public let unavailableMailboxes: Int
    public let searchComplete: Bool
    public let offset: Int
    public let nextOffset: Int?

    public init(messages: [MailMessageRecord], totalInbox: Int, scanned: Int, skipped: Int = 0,
                scope: MailSearchScope = .inbox, matched: Int? = nil, searchedMailboxes: Int = 1,
                unavailableMailboxes: Int = 0, searchComplete: Bool = false,
                offset: Int = 0, nextOffset: Int? = nil) {
        self.messages = messages
        self.totalInbox = totalInbox
        self.scanned = scanned
        self.skipped = skipped
        self.scope = scope
        self.matched = matched ?? totalInbox
        self.searchedMailboxes = searchedMailboxes
        self.unavailableMailboxes = unavailableMailboxes
        self.searchComplete = searchComplete
        self.offset = offset
        self.nextOffset = nextOffset
    }

    public var coverageLimitations: [String] {
        let area = scope == .inbox ? "Inbox" : "account and local mailboxes, including Archive and Sent where Mail exposes them"
        let search = searchComplete ? "Finished searching the requested scope" : "Search coverage is incomplete"
        var notes = [
            "Apple Mail: \(search) across \(searchedMailboxes) \(area); \(matched) matching messages identified, \(messages.count) returned at offset \(offset).",
            "Message bodies are excerpts of at most 2000 characters. Attachments and messages unavailable to Apple Mail are excluded; this is not a complete account export."
        ]
        if let nextOffset {
            notes.append("More matching messages remain after this page; next offset \(nextOffset). A summary of this page does not cover every matching email.")
        }
        if unavailableMailboxes > 0 || skipped > 0 || messages.contains(where: { !$0.bodyAvailable }) {
            notes.append("\(unavailableMailboxes) mailboxes and \(skipped) messages were unavailable; \(messages.filter { !$0.bodyAvailable }.count) returned messages have metadata only.")
        }
        if !searchComplete {
            notes.append("The search reached a time or enumeration limit, or a mailbox could not be read. No result is not proof that no matching email exists.")
        }
        return notes
    }

    private enum CodingKeys: String, CodingKey {
        case messages, totalInbox, scanned, skipped, scope, matched, searchedMailboxes
        case unavailableMailboxes, searchComplete, offset, nextOffset
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        messages = try values.decode([MailMessageRecord].self, forKey: .messages)
        totalInbox = try values.decode(Int.self, forKey: .totalInbox)
        scanned = try values.decode(Int.self, forKey: .scanned)
        skipped = try values.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        scope = try values.decodeIfPresent(MailSearchScope.self, forKey: .scope) ?? .inbox
        matched = try values.decodeIfPresent(Int.self, forKey: .matched) ?? totalInbox
        searchedMailboxes = try values.decodeIfPresent(Int.self, forKey: .searchedMailboxes) ?? 1
        unavailableMailboxes = try values.decodeIfPresent(Int.self, forKey: .unavailableMailboxes) ?? 0
        searchComplete = try values.decodeIfPresent(Bool.self, forKey: .searchComplete) ?? false
        offset = try values.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        nextOffset = try values.decodeIfPresent(Int.self, forKey: .nextOffset)
    }
}

public protocol MailSource: Sendable {
    func inboxSnapshot() async throws -> MailSnapshot
    func searchSnapshot(query: String?, offset: Int) async throws -> MailSnapshot
}

public extension MailSource {
    func searchSnapshot(query: String?, offset: Int) async throws -> MailSnapshot {
        guard offset == 0 else { throw MailSourceFailure(.unavailable, "This Mail source does not support search pagination.") }
        return try await inboxSnapshot()
    }

    func searchSnapshot(query: String?) async throws -> MailSnapshot {
        try await searchSnapshot(query: query, offset: 0)
    }
}

public struct MailSourceFailure: Error, CustomStringConvertible, Sendable {
    public enum Code: String, Sendable {
        case permissionDenied, mailboxUnavailable, noAccounts, mailNotRunning, timedOut, unsupportedSearch, invalidResponse, unavailable
    }
    public let code: Code
    public let appleEventCode: Int?
    public let description: String

    public init(_ description: String) {
        self.init(.unavailable, description)
    }

    public init(_ code: Code, _ description: String, appleEventCode: Int? = nil) {
        self.code = code
        self.appleEventCode = appleEventCode
        self.description = description
    }
}
