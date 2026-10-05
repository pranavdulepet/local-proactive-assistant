import AssistantCore
import CryptoKit
import Foundation

public struct MailIngestor: Sendable {
    private let source: any MailSource
    private let store: ObservationStore

    public init(source: any MailSource, store: ObservationStore) {
        self.source = source
        self.store = store
    }

    @discardableResult
    public func run(now: Date = Date()) async throws -> Int {
        try await refresh(now: now).messages.count
    }

    /// Return the current page as well as indexing it. Callers answer from this page, not an older cached search.
    @discardableResult
    public func refresh(query: String? = nil, offset: Int = 0, now: Date = Date()) async throws -> MailSnapshot {
        let snapshot = try await source.searchSnapshot(query: query, offset: offset)
        let savedCursor = try await store.sourceCursor(for: .mail)
        let previous = savedCursor.flatMap(Int64.init) ?? 0
        let revision = max(previous + 1, Int64(now.timeIntervalSince1970 * 1_000))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let observations = try snapshot.messages.map { record in
            let digest = SHA256.hash(data: try encoder.encode(record))
            return Observation(
                source: .mail, externalID: record.externalID,
                versionHash: digest.map { String(format: "%02x", $0) }.joined(),
                sourceRevision: revision, observedAt: now, sourceTimestamp: record.receivedAt,
                trust: .unknownExternal, text: Self.text(for: record), locator: Self.locator(for: record)
            )
        }
        // Searches and pages overlap. Absence from one result cannot retire an email returned by another.
        try await store.record(observations, advancing: .mail, cursor: String(revision))
        try await store.refreshCoverage(for: .mail, status: .partial,
                                       limitations: snapshot.coverageLimitations, at: now)
        return snapshot
    }

    public static func locator(for record: MailMessageRecord) -> String {
        "apple-mail:message-id:\(record.externalID)"
    }

    public static func text(for record: MailMessageRecord) -> String {
        let mailbox = record.mailbox.map { "\nMailbox: \(singleLine($0))" } ?? ""
        let body = record.bodyAvailable ? record.body : "[Message body unavailable; metadata only.]"
        return "From: \(singleLine(record.sender))\nSubject: \(singleLine(record.subject))\nUnread: \(record.unread ? "yes" : "no")\(mailbox)\nBody excerpt: \(body)"
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
