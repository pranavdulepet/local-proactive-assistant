import Foundation

public struct HistoricalMessage: Equatable, Sendable {
    public let cursor: TransportCursor
    public let guid: String
    public let chatID: TransportChatID
    public let text: String
    public let isFromMe: Bool
    public let isGroup: Bool
    public let senderName: String?
    public let createdAt: Date

    public init(
        cursor: TransportCursor,
        guid: String,
        chatID: TransportChatID,
        text: String,
        isFromMe: Bool,
        isGroup: Bool,
        senderName: String?,
        createdAt: Date
    ) {
        self.cursor = cursor
        self.guid = guid
        self.chatID = chatID
        self.text = text
        self.isFromMe = isFromMe
        self.isGroup = isGroup
        self.senderName = senderName
        self.createdAt = createdAt
    }
}

public struct MessageHistoryPage: Equatable, Sendable {
    public let messages: [HistoricalMessage]
    public let nextCursor: TransportCursor
    public let hasMore: Bool

    public init(
        messages: [HistoricalMessage],
        nextCursor: TransportCursor,
        hasMore: Bool
    ) {
        self.messages = messages
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public protocol MessageHistorySource: Sendable {
    func chats() async throws -> [TransportChat]
    func messages(
        after cursor: TransportCursor,
        limit: Int
    ) async throws -> MessageHistoryPage
}
