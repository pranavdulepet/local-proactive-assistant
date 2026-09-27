import AssistantCore
import Foundation
import Testing
@testable import AssistantStore

struct MessagesIngestorTests {
    @Test
    func indexesOnlyDirectMessagesAndAdvancesTheAuthoritativeCursor() async throws {
        let source = FakeMessageHistorySource(
            pages: [
                MessageHistoryPage(
                    messages: [
                        message(id: 10, guid: "owner", chatID: 1, text: "Send the deck", isFromMe: true),
                        message(id: 11, guid: "sms", chatID: 2, text: "SMS"),
                        message(id: 12, guid: "group", chatID: 3, text: "Group", isGroup: true),
                        message(id: 13, guid: "control", chatID: 4, text: "Control"),
                        message(id: 14, guid: "blank", chatID: 1, text: "  \n"),
                    ],
                    nextCursor: TransportCursor(rawValue: 50),
                    hasMore: true
                ),
                MessageHistoryPage(
                    messages: [
                        message(id: 70, guid: "unknown", chatID: 1, text: "Meet at Misi")
                    ],
                    nextCursor: TransportCursor(rawValue: 90),
                    hasMore: false
                ),
            ]
        )
        let store = try ObservationStore()
        let ingestor = MessagesIngestor(
            source: source,
            store: store,
            excludedChatIDs: [TransportChatID(rawValue: 4)]
        )
        let progress = ProgressRecorder()

        let summary = try await ingestor.run(pageSize: 100) { progress.append($0) }

        #expect(summary == MessageIngestionSummary(
            pages: 2,
            scanned: 6,
            indexed: 3,
            cursor: TransportCursor(rawValue: 90)
        ))
        #expect(await source.requests() == [
            Request(cursor: 0, limit: 100),
            Request(cursor: 50, limit: 100),
        ])
        #expect(progress.values().map(\.cursor.rawValue) == [50, 90])
        #expect(try await store.sourceCursor(for: .messages) == "90")
        #expect(try await store.current(source: .messages, externalID: "sms")?.text == "SMS")
        #expect(try await store.current(source: .messages, externalID: "group") == nil)
        #expect(try await store.current(source: .messages, externalID: "control") == nil)
        #expect(try await store.current(source: .messages, externalID: "blank") == nil)
        #expect(
            try await store.current(source: .messages, externalID: "owner")?.trust == .ownerAuthored
        )
        #expect(
            try await store.current(source: .messages, externalID: "unknown")?.trust == .unknownExternal
        )
        #expect(
            try await store.current(source: .messages, externalID: "unknown")?.handles
                == ["+14155550123"]
        )
        #expect(try await store.sourceCoverage(for: .messages)?.status == .partial)
    }

    @Test
    func resumesFromTheStoredCursorAndPersistsEmptyPages() async throws {
        let source = FakeMessageHistorySource(
            pages: [
                MessageHistoryPage(
                    messages: [],
                    nextCursor: TransportCursor(rawValue: 75),
                    hasMore: false
                )
            ]
        )
        let store = try ObservationStore()
        try await store.record([], advancing: .messages, cursor: "42")

        let summary = try await MessagesIngestor(source: source, store: store).run()

        #expect(await source.requests() == [Request(cursor: 42, limit: 500)])
        #expect(summary.cursor.rawValue == 75)
        #expect(summary.indexed == 0)
        #expect(try await store.sourceCursor(for: .messages) == "75")
    }

    private func message(
        id: Int64,
        guid: String,
        chatID: Int64,
        text: String,
        isFromMe: Bool = false,
        isGroup: Bool = false
    ) -> HistoricalMessage {
        HistoricalMessage(
            cursor: TransportCursor(rawValue: id),
            guid: guid,
            chatID: TransportChatID(rawValue: chatID),
            text: text,
            isFromMe: isFromMe,
            isGroup: isGroup,
            senderName: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(id)),
            participantHandle: "+1 (415) 555-0123"
        )
    }
}

private struct Request: Equatable, Sendable {
    let cursor: Int64
    let limit: Int
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var summaries: [MessageIngestionSummary] = []

    func append(_ summary: MessageIngestionSummary) {
        lock.lock()
        summaries.append(summary)
        lock.unlock()
    }

    func values() -> [MessageIngestionSummary] {
        lock.lock()
        defer { lock.unlock() }
        return summaries
    }
}

private actor FakeMessageHistorySource: MessageHistorySource {
    private var remainingPages: [MessageHistoryPage]
    private var receivedRequests: [Request] = []

    init(pages: [MessageHistoryPage]) {
        remainingPages = pages
    }

    func messages(
        after cursor: TransportCursor,
        limit: Int
    ) async throws -> MessageHistoryPage {
        receivedRequests.append(Request(cursor: cursor.rawValue, limit: limit))
        guard !remainingPages.isEmpty else {
            throw ObservationStoreFailure("No fake history page remains")
        }
        return remainingPages.removeFirst()
    }

    func requests() -> [Request] {
        receivedRequests
    }
}
