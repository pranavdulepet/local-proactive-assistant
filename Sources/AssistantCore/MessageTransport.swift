import Foundation

public struct TransportChatID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }
}

public struct TransportCursor: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct TransportChat: Codable, Equatable, Sendable {
    public let id: TransportChatID
    public let identifier: String
    public let guid: String
    public let displayName: String
    public let service: String
    public let participants: [String]
    public let isGroup: Bool

    public init(
        id: TransportChatID,
        identifier: String,
        guid: String,
        displayName: String,
        service: String,
        participants: [String],
        isGroup: Bool
    ) {
        self.id = id
        self.identifier = identifier
        self.guid = guid
        self.displayName = displayName
        self.service = service
        self.participants = participants
        self.isGroup = isGroup
    }
}

public struct InboundTransportMessage: Codable, Equatable, Sendable {
    public let cursor: TransportCursor
    public let guid: String
    public let chatID: TransportChatID
    public let text: String
    public let isFromMe: Bool
    public let createdAt: Date

    public init(
        cursor: TransportCursor,
        guid: String,
        chatID: TransportChatID,
        text: String,
        isFromMe: Bool,
        createdAt: Date
    ) {
        self.cursor = cursor
        self.guid = guid
        self.chatID = chatID
        self.text = text
        self.isFromMe = isFromMe
        self.createdAt = createdAt
    }
}

public struct OutboundTransportMessage: Equatable, Sendable {
    public let requestID: UUID
    public let text: String
    public let isProgress: Bool

    public init(requestID: UUID = UUID(), text: String, isProgress: Bool = false) {
        self.requestID = requestID
        self.text = text
        self.isProgress = isProgress
    }
}

public struct SendReceipt: Equatable, Sendable {
    public let requestID: UUID
    public let messageGUID: String?
    public let rowID: Int64?
    public let transport: String?

    public init(
        requestID: UUID,
        messageGUID: String?,
        rowID: Int64?,
        transport: String?
    ) {
        self.requestID = requestID
        self.messageGUID = messageGUID
        self.rowID = rowID
        self.transport = transport
    }
}

public struct TransportHealth: Equatable, Sendable {
    public let ready: Bool
    public let version: String?
    public let detail: String

    public init(ready: Bool, version: String? = nil, detail: String) {
        self.ready = ready
        self.version = version
        self.detail = detail
    }
}

public struct TransportFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public let retrySafe: Bool

    public init(_ message: String, retrySafe: Bool = false) {
        self.message = message
        self.retrySafe = retrySafe
    }

    public var description: String { message }
}

public protocol MessageTransport: Sendable {
    func probe() async -> TransportHealth
    func chats() async throws -> [TransportChat]
    func subscribe(
        chatID: TransportChatID,
        after cursor: TransportCursor?
    ) -> AsyncThrowingStream<InboundTransportMessage, Error>
    func send(
        _ message: OutboundTransportMessage,
        to chatID: TransportChatID
    ) async throws -> SendReceipt
    /// Best effort; true means requested, not proof that the recipient rendered it.
    func setTyping(_ typing: Bool, to chatID: TransportChatID) async -> Bool
}

public extension MessageTransport {
    func setTyping(_ typing: Bool, to chatID: TransportChatID) async -> Bool { false }
}
