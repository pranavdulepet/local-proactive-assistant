import AssistantCore
import CryptoKit
import Foundation

public struct MessageIngestionSummary: Equatable, Sendable {
    public let pages: Int
    public let scanned: Int
    public let indexed: Int
    public let cursor: TransportCursor

    public init(pages: Int, scanned: Int, indexed: Int, cursor: TransportCursor) {
        self.pages = pages
        self.scanned = scanned
        self.indexed = indexed
        self.cursor = cursor
    }
}

public struct MessagesIngestor: Sendable {
    private let source: any MessageHistorySource
    private let store: ObservationStore
    private let excludedChatIDs: Set<TransportChatID>

    public init(
        source: any MessageHistorySource,
        store: ObservationStore,
        excludedChatIDs: Set<TransportChatID> = []
    ) {
        self.source = source
        self.store = store
        self.excludedChatIDs = excludedChatIDs
    }

    public func run(
        pageSize: Int = 500,
        onProgress: (@Sendable (MessageIngestionSummary) -> Void)? = nil
    ) async throws -> MessageIngestionSummary {
        let savedCursor = try await store.sourceCursor(for: .messages)
        if let savedCursor, Int64(savedCursor) == nil {
            throw ObservationStoreFailure("Stored Messages cursor is not an integer")
        }

        var cursor = TransportCursor(rawValue: savedCursor.flatMap(Int64.init) ?? 0)
        var pages = 0
        var scanned = 0
        var indexed = 0
        let limit = min(max(pageSize, 1), 500)

        while true {
            try Task.checkCancellation()
            let page = try await source.messages(after: cursor, limit: limit)
            guard page.nextCursor >= cursor else {
                throw ObservationStoreFailure("Messages history cursor moved backwards")
            }
            if page.hasMore && page.nextCursor == cursor {
                throw ObservationStoreFailure("Messages history did not advance its cursor")
            }

            let observations = page.messages.compactMap { message -> Observation? in
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !excludedChatIDs.contains(message.chatID),
                      !message.isGroup,
                      !text.isEmpty else {
                    return nil
                }
                return Self.observation(for: message)
            }

            indexed += try await store.record(
                observations,
                advancing: .messages,
                cursor: String(page.nextCursor.rawValue)
            )
            pages += 1
            scanned += page.messages.count
            cursor = page.nextCursor
            let summary = MessageIngestionSummary(
                pages: pages,
                scanned: scanned,
                indexed: indexed,
                cursor: cursor
            )
            onProgress?(summary)

            if !page.hasMore {
                try await store.refreshCoverage(
                    for: .messages,
                    status: .partial,
                    limitations: [
                        "One-to-one text messages only; groups, attachments, edits, and deletions are not yet reconciled."
                    ]
                )
                return summary
            }
        }
    }

    private static func observation(for message: HistoricalMessage) -> Observation {
        let handles = PersonHandle.normalize([message.participantHandle].compactMap { $0 })
        let versionInput = [
            message.guid,
            String(message.chatID.rawValue),
            message.text,
            String(message.isFromMe),
            ISO8601DateFormatter().string(from: message.createdAt),
            handles.joined(separator: ","),
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(versionInput.utf8))
        let versionHash = digest.map { String(format: "%02x", $0) }.joined()
        let trust: ObservationTrust
        if message.isFromMe {
            trust = .ownerAuthored
        } else if message.senderName?.isEmpty == false {
            trust = .knownExternal
        } else {
            trust = .unknownExternal
        }

        return Observation(
            source: .messages,
            externalID: message.guid,
            versionHash: versionHash,
            sourceRevision: message.cursor.rawValue,
            sourceTimestamp: message.createdAt,
            trust: trust,
            handles: handles,
            text: message.text,
            locator: "imsg:chat:\(message.chatID.rawValue):message:\(message.guid)"
        )
    }
}
