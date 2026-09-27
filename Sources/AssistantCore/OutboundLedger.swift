import CryptoKit
import Foundation

public struct OutboundLedgerEntry: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let chatID: TransportChatID
    public let normalizedContentHash: String
    public var transportMessageGUID: String?
    public let sentAt: Date
    public let expiresAt: Date

    public init(
        requestID: UUID,
        chatID: TransportChatID,
        normalizedContentHash: String,
        transportMessageGUID: String?,
        sentAt: Date,
        expiresAt: Date
    ) {
        self.requestID = requestID
        self.chatID = chatID
        self.normalizedContentHash = normalizedContentHash
        self.transportMessageGUID = transportMessageGUID
        self.sentAt = sentAt
        self.expiresAt = expiresAt
    }
}

public actor OutboundLedger {
    private let fileURL: URL?
    private var entries: [OutboundLedgerEntry]

    public init(fileURL: URL? = nil) throws {
        self.fileURL = fileURL

        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = []
            return
        }

        let data = try Data(contentsOf: fileURL)
        entries = try JSONDecoder().decode([OutboundLedgerEntry].self, from: data)
    }

    @discardableResult
    public func begin(
        requestID: UUID,
        chatID: TransportChatID,
        text: String,
        sentAt: Date = Date(),
        ttl: TimeInterval = 120
    ) throws -> OutboundLedgerEntry {
        prune(at: sentAt)

        let entry = OutboundLedgerEntry(
            requestID: requestID,
            chatID: chatID,
            normalizedContentHash: Self.contentHash(text),
            transportMessageGUID: nil,
            sentAt: sentAt,
            expiresAt: sentAt.addingTimeInterval(ttl)
        )
        entries.append(entry)
        try persist()
        return entry
    }

    public func confirm(requestID: UUID, messageGUID: String?) throws {
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }) else {
            return
        }

        entries[index].transportMessageGUID = messageGUID
        try persist()
    }

    public func cancel(requestID: UUID) throws {
        entries.removeAll { $0.requestID == requestID }
        try persist()
    }

    public func contains(
        messageGUID: String,
        chatID: TransportChatID,
        at date: Date = Date()
    ) throws -> Bool {
        prune(at: date)
        return entries.contains {
            $0.chatID == chatID && $0.transportMessageGUID == messageGUID
        }
    }

    public func contains(
        text: String,
        chatID: TransportChatID,
        messageDate: Date,
        tolerance: TimeInterval = 30,
        at date: Date = Date()
    ) throws -> Bool {
        prune(at: date)
        let hash = Self.contentHash(text)

        return entries.contains {
            $0.chatID == chatID
                && $0.normalizedContentHash == hash
                && abs($0.sentAt.timeIntervalSince(messageDate)) <= tolerance
        }
    }

    public static func contentHash(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func prune(at date: Date) {
        entries.removeAll { $0.expiresAt < date }
    }

    private func persist() throws {
        guard let fileURL else { return }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
