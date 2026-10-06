import Foundation
import LocalInference

/// A small private transcript shared by the Mac's verified self-chat routes.
public actor ConversationHistory {
    private struct Exchange: Codable {
        let messages: [AgentMessage]
        let records: [EvidenceRecord]
    }
    private struct Snapshot: Codable {
        let schemaVersion: Int
        let turns: [ChatTurn]
        let sourceIDs: [String]
        let exchanges: [Exchange]?
    }

    private let fileURL: URL?
    private var turns: [ChatTurn]
    private var sourceIDs: [String]
    private var exchanges: [Exchange] = []

    public init() {
        fileURL = nil
        turns = []
        sourceIDs = []
    }

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            if let legacy = try? decoder.decode([ChatTurn].self, from: data) {
                turns = legacy
                sourceIDs = []
            } else {
                let snapshot = try decoder.decode(Snapshot.self, from: data)
                guard snapshot.schemaVersion == 1 else {
                    throw LocalModelFailure("Unsupported conversation history version.")
                }
                turns = snapshot.turns
                sourceIDs = Array(snapshot.sourceIDs.suffix(4_096))
                exchanges = snapshot.exchanges ?? []
            }
        } else {
            turns = []
            sourceIDs = []
        }
        turns = Array(turns.suffix(8))
    }

    public func recent() -> [ChatTurn] { turns }
    public func agentTranscript() -> [AgentMessage] { exchanges.flatMap(\.messages) }
    public func agentRecords() -> [EvidenceRecord] { exchanges.flatMap(\.records) }

    public func lastUserMessage() -> String? {
        turns.last(where: { $0.role == .user })?.text
    }

    public func append(user: String, assistant: String, sourceID: String? = nil,
                       agentMessages: [AgentMessage] = [], records: [EvidenceRecord] = []) throws {
        if let sourceID, sourceIDs.contains(sourceID) { return }
        let previousTurns = turns
        let previousIDs = sourceIDs
        let previousExchanges = exchanges
        turns.append(ChatTurn(role: .user, text: EvidenceText.bounded(user, bytes: 2_048)))
        turns.append(ChatTurn(role: .assistant, text: EvidenceText.bounded(assistant, bytes: 2_048)))
        turns = Array(turns.suffix(8))
        if agentMessages.isEmpty {
            // Legacy model turns still belong in the native conversation after a model switch.
            exchanges.append(Exchange(messages: [
                AgentMessage(role: .user, content: EvidenceText.bounded(user, bytes: 2_048)),
                AgentMessage(role: .assistant, content: EvidenceText.bounded(assistant, bytes: 8_192))
            ], records: []))
        } else {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // Retain the decisions and useful excerpts, not every byte of a previous lookup.
            let compact = agentMessages.map { message -> AgentMessage in
                guard message.role == .tool,
                      let result = try? decoder.decode(ContextToolResult.self, from: Data(message.content.utf8)) else { return message }
                let excerpts = result.records.map {
                    EvidenceRecord(id: $0.id, source: $0.source, timestamp: $0.timestamp,
                        text: EvidenceText.bounded($0.text, bytes: 256), locator: $0.locator, trust: $0.trust)
                }
                let summary = ContextToolResult(records: excerpts, coverage: result.coverage)
                guard let data = try? encoder.encode(summary) else { return message }
                return AgentMessage(role: .tool, content: String(decoding: data, as: UTF8.self), toolCallID: message.toolCallID)
            }
            let retainedRecords = compact.filter { $0.role == .tool }.flatMap {
                (try? decoder.decode(ContextToolResult.self, from: Data($0.content.utf8)))?.records ?? []
            }
            exchanges.append(Exchange(messages: compact, records: retainedRecords))
        }
        exchanges = Array(exchanges.suffix(2))
        while exchanges.count > 1 && (exchanges.flatMap(\.messages).count > 24
            || exchanges.flatMap(\.messages).reduce(0, { $0 + $1.content.utf8.count }) > 24_000) {
            exchanges.removeFirst()
        }
        if let sourceID { sourceIDs = Array((sourceIDs + [sourceID]).suffix(4_096)) }
        do { try persist() } catch {
            turns = previousTurns
            sourceIDs = previousIDs
            exchanges = previousExchanges
            throw error
        }
    }

    private func persist() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let snapshot = Snapshot(schemaVersion: 1, turns: turns, sourceIDs: sourceIDs, exchanges: exchanges)
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func clear() throws {
        let previousTurns = turns
        let previousIDs = sourceIDs
        let previousExchanges = exchanges
        turns = []
        exchanges = []
        sourceIDs = []
        do { try persist() } catch {
            turns = previousTurns
            sourceIDs = previousIDs
            exchanges = previousExchanges
            throw error
        }
    }
}
