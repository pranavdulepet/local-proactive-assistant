import CryptoKit
import Foundation

public struct OutboundLedgerEntry: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let chatID: TransportChatID
    public let normalizedContentHash: String
    public var transportMessageGUID: String?
    public var needsRecovery: Bool
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
        self.needsRecovery = transportMessageGUID == nil
        self.sentAt = sentAt
        self.expiresAt = expiresAt
    }
    private enum CodingKeys: String, CodingKey {
        case requestID, chatID, normalizedContentHash, transportMessageGUID
        case needsRecovery, sentAt, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        chatID = try container.decode(TransportChatID.self, forKey: .chatID)
        normalizedContentHash = try container.decode(String.self, forKey: .normalizedContentHash)
        transportMessageGUID = try container.decodeIfPresent(String.self, forKey: .transportMessageGUID)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        // Older ledger files had no recovery bit. An entry without a send GUID
        // may have been delivered, so recover it conservatively once.
        needsRecovery = try container.decodeIfPresent(Bool.self, forKey: .needsRecovery)
            ?? (transportMessageGUID == nil)
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
        ttl: TimeInterval = 600
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
        prune(at: sentAt)
        try persist()
        return entry
    }

    public func confirm(requestID: UUID, messageGUID: String?) throws {
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }) else {
            return
        }

        entries[index].transportMessageGUID = messageGUID
        entries[index].needsRecovery = false
        try persist()
    }

    public func pendingRecoveryChatIDs() -> Set<TransportChatID> {
        Set(entries.filter(\.needsRecovery).map(\.chatID))
    }

    public func markRecovered(requestID: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }) else { return }
        entries[index].needsRecovery = false
        try persist()
    }

    public func markRecovered(chatID: TransportChatID) throws {
        for index in entries.indices where entries[index].chatID == chatID {
            entries[index].needsRecovery = false
        }
        try persist()
    }

    public func cancel(requestID: UUID) throws {
        entries.removeAll { $0.requestID == requestID }
        try persist()
    }

    public func contains(
        messageGUID: String,
        chatID: TransportChatID,
        aliases: Set<TransportChatID> = [],
        at date: Date = Date()
    ) throws -> Bool {
        prune(at: date)
        return entries.contains {
            ($0.chatID == chatID || aliases.contains($0.chatID))
                && $0.transportMessageGUID == messageGUID
        }
    }

    public func contains(
        text: String,
        chatID: TransportChatID,
        aliases: Set<TransportChatID> = [],
        messageDate: Date,
        tolerance: TimeInterval = 180,
        at date: Date = Date()
    ) throws -> Bool {
        prune(at: date)
        let hash = Self.contentHash(text)

        return entries.contains {
            ($0.chatID == chatID || aliases.contains($0.chatID))
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
        // Saved cursors can replay an outgoing echo long after a restart. Keep
        // its identity/hash for catchup; text matching still uses message time.
        entries.removeAll { max($0.expiresAt, $0.sentAt.addingTimeInterval(30 * 86_400)) < date }
        if entries.count > 4_096 { entries = Array(entries.suffix(4_096)) }
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
