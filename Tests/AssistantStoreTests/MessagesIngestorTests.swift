import AssistantCore
import Foundation
import Testing
@testable import AssistantStore

struct MessagesIngestorTests {
    @Test
    func indexesOnlyDirectIMessagesAndAdvancesTheAuthoritativeCursor() async throws {
        let chats = [
            chat(id: 1, service: "iMessage"),
            chat(id: 2, service: "SMS"),
            chat(id: 3, service: "iMessage", isGroup: true),
            chat(id: 4, service: "iMessage"),
        ]
        let source = FakeMessageHistorySource(
            chats: chats,
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

        let summary = try await ingestor.run(pageSize: 100)

        #expect(summary == MessageIngestionSummary(
            pages: 2,
            scanned: 6,
            indexed: 2,
            cursor: TransportCursor(rawValue: 90)
        ))
        #expect(await source.requests() == [
            Request(cursor: 0, limit: 100),
            Request(cursor: 50, limit: 100),
        ])
        #expect(try await store.sourceCursor(for: .messages) == "90")
        #expect(try await store.current(source: .messages, externalID: "sms") == nil)
        #expect(try await store.current(source: .messages, externalID: "group") == nil)
        #expect(try await store.current(source: .messages, externalID: "control") == nil)
        #expect(try await store.current(source: .messages, externalID: "blank") == nil)
        #expect(
            try await store.current(source: .messages, externalID: "owner")?.trust == .ownerAuthored
        )
        #expect(
            try await store.current(source: .messages, externalID: "unknown")?.trust == .unknownExternal
        )
    }

    @Test
    func resumesFromTheStoredCursorAndPersistsEmptyPages() async throws {
        let source = FakeMessageHistorySource(
            chats: [chat(id: 1, service: "iMessage")],
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

    private func chat(id: Int64, service: String, isGroup: Bool = false) -> TransportChat {
        TransportChat(
            id: TransportChatID(rawValue: id),
            identifier: "chat-\(id)",
            guid: "guid-\(id)",
            displayName: "Chat \(id)",
            service: service,
            participants: ["person@example.com"],
            isGroup: isGroup
        )
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
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(id))
        )
    }
}

private struct Request: Equatable, Sendable {
    let cursor: Int64
    let limit: Int
}

private actor FakeMessageHistorySource: MessageHistorySource {
    private let availableChats: [TransportChat]
    private var remainingPages: [MessageHistoryPage]
    private var receivedRequests: [Request] = []

    init(chats: [TransportChat], pages: [MessageHistoryPage]) {
        availableChats = chats
        remainingPages = pages
    }

    func chats() async throws -> [TransportChat] {
        availableChats
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
