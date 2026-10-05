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
        let snapshot = try await source.inboxSnapshot()
        // A partial per-message failure must not retire evidence as if the scan succeeded.
        guard snapshot.skipped == 0 else {
            throw MailSourceFailure("Some inbox messages could not be read. Open Apple Mail, let it sync, and try again.")
        }
        let savedCursor = try await store.sourceCursor(for: .mail)
        let previous = savedCursor.flatMap(Int64.init) ?? 0
        let revision = max(previous + 1, Int64(now.timeIntervalSince1970 * 1_000))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var observations = try snapshot.messages.map { record in
            let digest = SHA256.hash(data: try encoder.encode(record))
            return Observation(
                source: .mail, externalID: record.externalID,
                versionHash: digest.map { String(format: "%02x", $0) }.joined(),
                sourceRevision: revision, observedAt: now, sourceTimestamp: record.receivedAt,
                trust: .unknownExternal,
                text: "From: \(Self.singleLine(record.sender))\nSubject: \(Self.singleLine(record.subject))\nUnread: \(record.unread ? "yes" : "no")\nBody snippet: \(record.body)",
                locator: "apple-mail:inbox:message-id:\(record.externalID)"
            )
        }
        let oldIDs = try await store.currentExternalIDs(source: .mail)
        let sampledIDs = Set(snapshot.messages.map(\.externalID))
        for id in oldIDs.subtracting(sampledIDs) {
            observations.append(Observation(
                source: .mail, externalID: id, versionHash: "out-of-sample-\(revision)",
                sourceRevision: revision, observedAt: now, trust: .unknownExternal,
                text: "", locator: "apple-mail:inbox:message-id:\(id)", tombstone: true
            ))
        }
        try await store.record(observations, advancing: .mail, cursor: String(revision))
        try await store.refreshCoverage(for: .mail, status: .partial, limitations: [
            "Apple Mail Inbox sample: \(snapshot.messages.count) messages from \(snapshot.totalInbox) Inbox items, refreshed on email requests. Mail supplies sample order; this is not a complete account search.",
            "Bodies are snippets of at most 2000 characters. Attachments, Sent, Archive and other folders are not read. Missing from this sample does not prove an email was deleted."
        ], at: now)
        return snapshot.messages.count
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
