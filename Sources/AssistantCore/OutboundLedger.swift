import CryptoKit
import Foundation

public struct OutboundLedgerEntry: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let chatID: TransportChatID
    public let normalizedContentHash: String
    public let exactContentHash: String?
    public var transportMessageGUID: String?
    public var transportRowID: Int64?
    public var needsRecovery: Bool
    public let sentAt: Date
    public let expiresAt: Date

    public init(
        requestID: UUID,
        chatID: TransportChatID,
        normalizedContentHash: String,
        transportMessageGUID: String?,
        sentAt: Date,
        expiresAt: Date,
        exactContentHash: String? = nil,
        transportRowID: Int64? = nil
    ) {
        self.requestID = requestID
        self.chatID = chatID
        self.normalizedContentHash = normalizedContentHash
        self.exactContentHash = exactContentHash
        self.transportMessageGUID = transportMessageGUID
        self.transportRowID = transportRowID
        self.needsRecovery = transportMessageGUID == nil
        self.sentAt = sentAt
        self.expiresAt = expiresAt
    }
    private enum CodingKeys: String, CodingKey {
        case requestID, chatID, normalizedContentHash, transportMessageGUID
        case needsRecovery, sentAt, expiresAt, exactContentHash, transportRowID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        chatID = try container.decode(TransportChatID.self, forKey: .chatID)
        normalizedContentHash = try container.decode(String.self, forKey: .normalizedContentHash)
        exactContentHash = try container.decodeIfPresent(String.self, forKey: .exactContentHash)
        transportMessageGUID = try container.decodeIfPresent(String.self, forKey: .transportMessageGUID)
        transportRowID = try container.decodeIfPresent(Int64.self, forKey: .transportRowID)
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
        let previous = entries
        prune(at: sentAt)

        let entry = OutboundLedgerEntry(
            requestID: requestID,
            chatID: chatID,
            normalizedContentHash: Self.contentHash(text),
            transportMessageGUID: nil,
            sentAt: sentAt,
            expiresAt: sentAt.addingTimeInterval(ttl),
            exactContentHash: Self.exactContentHash(text)
        )
        entries.append(entry)
        prune(at: sentAt)
        do { try persist() } catch { entries = previous; throw error }
        return entry
    }

    public func confirm(requestID: UUID, messageGUID: String?, rowID: Int64? = nil) throws {
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }) else {
            return
        }

        let previous = entries[index]
        if let messageGUID, !messageGUID.isEmpty {
            entries[index].transportMessageGUID = messageGUID
        }
        if let rowID { entries[index].transportRowID = rowID }
        entries[index].needsRecovery = false
        do { try persist() } catch { entries[index] = previous; throw error }
    }

    public func entry(requestID: UUID) -> OutboundLedgerEntry? {
        entries.first { $0.requestID == requestID }
    }

    public func confirmedReceipt(requestID: UUID) -> SendReceipt? {
        guard let entry = entries.first(where: { $0.requestID == requestID }),
              let guid = entry.transportMessageGUID, !guid.isEmpty else { return nil }
        return SendReceipt(requestID: requestID, messageGUID: guid,
            rowID: entry.transportRowID, transport: "applescript-observed")
    }

    /// Associate an outgoing catchup row with exactly one recorded send attempt.
    /// Unconfirmed text matches are deliberately limited to the send's time window.
    public func reconcileSubmission(
        _ message: InboundTransportMessage,
        in verifiedChatIDs: Set<TransportChatID>
    ) throws -> SendReceipt? {
        guard message.isFromMe, !message.guid.isEmpty,
              verifiedChatIDs.contains(message.chatID) else { return nil }
        let matching = entries.filter {
            Self.matchesSubmission(message, for: $0, in: verifiedChatIDs)
        }
        guard matching.count == 1, let entry = matching.first,
              !entries.contains(where: {
                  $0.requestID != entry.requestID && $0.transportMessageGUID == message.guid
              }) else { return nil }
        let receipt = SendReceipt(requestID: entry.requestID, messageGUID: message.guid,
            rowID: message.cursor.rawValue, transport: "applescript-observed")
        try confirm(requestID: receipt.requestID, messageGUID: receipt.messageGUID, rowID: receipt.rowID)
        return receipt
    }

    /// Shared matching policy for transport history and live alias catchup.
    public static func submissionReceipt(
        for entry: OutboundLedgerEntry,
        messages: [InboundTransportMessage],
        in verifiedChatIDs: Set<TransportChatID>
    ) -> SendReceipt? {
        let candidates = messages.filter { matchesSubmission($0, for: entry, in: verifiedChatIDs) }
        // The same physical GUID may be joined to both self-chat aliases.
        guard Set(candidates.map(\.guid)).count == 1,
              let message = candidates.max(by: { $0.cursor < $1.cursor }) else { return nil }
        return SendReceipt(requestID: entry.requestID, messageGUID: message.guid,
            rowID: message.cursor.rawValue, transport: "applescript-observed")
    }

    private static func matchesSubmission(
        _ message: InboundTransportMessage,
        for entry: OutboundLedgerEntry,
        in verifiedChatIDs: Set<TransportChatID>
    ) -> Bool {
        guard verifiedChatIDs.contains(entry.chatID), verifiedChatIDs.contains(message.chatID),
              message.isFromMe, message.cursor.rawValue > 0, !message.guid.isEmpty else { return false }
        if let guid = entry.transportMessageGUID, !guid.isEmpty { return message.guid == guid }
        let age = message.createdAt.timeIntervalSince(entry.sentAt)
        guard age >= 0, age <= 120 else { return false }
        if let hash = entry.exactContentHash { return exactContentHash(message.text) == hash }
        // Older ledgers stored only the normalized hash. They retain the same
        // outgoing/alias/time/uniqueness checks, without fabricating a send GUID.
        return contentHash(message.text) == entry.normalizedContentHash
    }

    public func pendingRecoveryChatIDs() -> Set<TransportChatID> {
        Set(entries.filter(\.needsRecovery).map(\.chatID))
    }

    public func markRecovered(requestID: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.requestID == requestID }) else { return }
        let previous = entries[index]
        entries[index].needsRecovery = false
        do { try persist() } catch { entries[index] = previous; throw error }
    }

    public func markRecovered(chatID: TransportChatID) throws {
        let previous = entries
        for index in entries.indices where entries[index].chatID == chatID {
            entries[index].needsRecovery = false
        }
        do { try persist() } catch { entries = previous; throw error }
    }

    public func cancel(requestID: UUID) throws {
        let previous = entries
        entries.removeAll { $0.requestID == requestID }
        do { try persist() } catch { entries = previous; throw error }
    }

    public func contains(
        messageGUID: String,
        chatID: TransportChatID,
        aliases: Set<TransportChatID> = [],
        at date: Date = Date()
    ) throws -> Bool {
        guard !messageGUID.isEmpty else { return false }
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

    public static func exactContentHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
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
