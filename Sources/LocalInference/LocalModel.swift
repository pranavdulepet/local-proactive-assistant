import Foundation

public struct ModelAvailability: Codable, Equatable, Sendable {
    public let ready: Bool
    public let detail: String

    public init(ready: Bool, detail: String) {
        self.ready = ready
        self.detail = detail
    }
}

/// Providers receive bounded evidence and may propose host-validated read requests.
public protocol LocalModelProvider: Sendable {
    var modelID: String { get }
    func availability() async -> ModelAvailability
    func answer(_ request: EvidenceRequest) async throws -> GroundedAnswer
    func chat(_ request: ChatRequest) async throws -> ChatReply
    func planContext(_ request: ContextPlanRequest) async throws -> ContextPlan
}

public extension LocalModelProvider {
    func planContext(_ request: ContextPlanRequest) async throws -> ContextPlan {
        throw ContextPlanningUnavailable()
    }
    func chat(_ request: ChatRequest) async throws -> ChatReply {
        throw LocalModelFailure("This local model does not support conversation.")
    }
}

public struct LocalModelFailure: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct EvidenceRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let source: String
    public let timestamp: Date?
    public let text: String
    public let locator: String
    public let trust: String

    public init(id: String, source: String, timestamp: Date?, text: String, locator: String, trust: String) {
        self.id = id
        self.source = source
        self.timestamp = timestamp
        self.text = text
        self.locator = locator
        self.trust = trust
    }
}

/// Also the explicit, portable context document imported by the phone app.
public struct EvidenceRequest: Codable, Equatable, Sendable {
    public static let schema = "local-assistant.evidence.v1"
    public let schemaVersion: String
    public let question: String
    public let createdAt: Date
    public let records: [EvidenceRecord]
    public let coverage: [String]

    public init(question: String, createdAt: Date = Date(), records: [EvidenceRecord], coverage: [String]) {
        schemaVersion = Self.schema
        self.question = question
        self.createdAt = createdAt
        self.records = records
        self.coverage = coverage
    }

    public func validate() throws {
        guard schemaVersion == Self.schema else { throw LocalModelFailure("Unsupported evidence document version.") }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.utf8.count <= 512 else { throw LocalModelFailure("Question must contain 1–512 UTF-8 bytes.") }
        guard records.count <= 8, Set(records.map(\.id)).count == records.count,
              coverage.count <= 8, coverage.allSatisfy({ $0.utf8.count <= 512 }) else {
            throw LocalModelFailure("Evidence document exceeds its record or coverage limits.")
        }
        for record in records {
            guard !record.id.isEmpty, record.id.utf8.count <= 80,
                  record.source.utf8.count <= 40, record.trust.utf8.count <= 40,
                  record.text.utf8.count <= 768, record.locator.utf8.count <= 256 else {
                throw LocalModelFailure("Evidence record exceeds its field limits.")
            }
        }
    }
}

public struct GroundedClaim: Codable, Equatable, Sendable {
    public let evidenceIDs: [String]
    public let text: String
    public init(evidenceIDs: [String], text: String) {
        self.evidenceIDs = evidenceIDs
        self.text = text
    }
}

public struct GroundedAnswer: Codable, Equatable, Sendable {
    public let insufficientEvidence: Bool
    public let claims: [GroundedClaim]
    public init(insufficientEvidence: Bool, claims: [GroundedClaim]) {
        self.insufficientEvidence = insufficientEvidence
        self.claims = claims
    }

    public func validate(for request: EvidenceRequest) throws {
        try request.validate()
        let knownIDs = Set(request.records.map(\.id))
        guard claims.count <= 5, insufficientEvidence == claims.isEmpty else {
            throw LocalModelFailure("Model returned an inconsistent answer.")
        }
        for claim in claims {
            guard !claim.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  claim.text.utf8.count <= 512,
                  !claim.evidenceIDs.isEmpty, claim.evidenceIDs.count <= 8,
                  Set(claim.evidenceIDs).isSubset(of: knownIDs) else {
                throw LocalModelFailure("Model returned missing, unknown or oversized citations.")
            }
        }
    }
}

public enum EvidenceText {
    public static func bounded(_ text: String, bytes: Int) -> String {
        var result = ""
        var count = 0
        for character in text {
            let next = String(character).utf8.count
            if count + next > bytes { break }
            result.append(character)
            count += next
        }
        return result
    }
}


public struct ChatTurn: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public let role: Role
    public let text: String
    public init(role: Role, text: String) { self.role = role; self.text = text }
}

/// A bounded, tool-free local conversation. Source records remain quoted data.
public struct ChatRequest: Codable, Equatable, Sendable {
    public let message: String
    public let history: [ChatTurn]
    public let records: [EvidenceRecord]
    public let coverage: [String]
    public let contextReads: [ContextReadStatus]?

    public init(message: String, history: [ChatTurn], records: [EvidenceRecord] = [], coverage: [String] = [],
                contextReads: [ContextReadStatus]? = nil) {
        self.message = message
        self.history = history
        self.records = records
        self.coverage = coverage
        self.contextReads = contextReads
    }

    public func validate() throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.utf8.count <= 4_096,
              history.count <= 8,
              history.allSatisfy({ !$0.text.isEmpty && $0.text.utf8.count <= 2_048 }),
              records.count <= 8,
              Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 80 &&
                  $0.source.utf8.count <= 40 && $0.trust.utf8.count <= 40 &&
                  $0.text.utf8.count <= 768 && $0.locator.utf8.count <= 256 }),
              coverage.count <= 8,
              coverage.allSatisfy({ $0.utf8.count <= 512 }) else {
            throw LocalModelFailure("Conversation exceeds local context limits.")
        }
        if let contextReads {
            guard contextReads.count <= 3 else { throw LocalModelFailure("Conversation exceeds its read receipt limit.") }
            for read in contextReads { try read.validate() }
        }
    }
}

public struct ContextReadStatus: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case read, empty, failed }
    public let tool: ContextTool
    public let outcome: Outcome
    public let recordCount: Int
    public init(tool: ContextTool, outcome: Outcome, recordCount: Int) {
        self.tool = tool; self.outcome = outcome; self.recordCount = recordCount
    }
    public func validate() throws {
        guard (0...8).contains(recordCount), (outcome == .read ? recordCount > 0 : recordCount == 0) else {
            throw LocalModelFailure("Invalid host context read receipt.")
        }
    }
}

public struct ChatReply: Codable, Equatable, Sendable {
    public let text: String
    public init(text: String) { self.text = text }
    public func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 2_048 else { throw LocalModelFailure("Invalid local conversation reply.") }
    }

    public func validate(for request: ChatRequest) throws {
        do { try validate() }
        catch { throw ChatReplyFailure("The local conversation reply was empty or oversized.") }
        try request.validate()
        let knownIDs = Set(request.records.map(\.id))
        let citations = try NSRegularExpression(pattern: #"\[(e[0-9]+)\]"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in citations.matches(in: text, range: range) {
            guard let idRange = Range(match.range(at: 1), in: text), knownIDs.contains(String(text[idRange])) else {
                throw ChatReplyFailure("The reply cites evidence that was not supplied.")
            }
        }
        // The harness has no write tools. Reject direct claims of completed actions.
        let writeClaim = #"(?i)(?<!["“'])\bI(?:['’]ve| have)?\s+(?:just\s+)?(?:(?:sent|booked|purchased|deleted|scheduled|installed)\b|(?:updated|changed|created)\s+(?:(?:a|an|the|your|that|this)\s+)*(?:setting|event|file|reminder|appointment|reservation|account|calendar)\b)"#
        if text.range(of: writeClaim, options: .regularExpression) != nil {
            throw ChatReplyFailure("The local reply claimed an unsupported action.")
        }
        let hasRead = !request.records.isEmpty || request.contextReads?.contains { $0.outcome != .failed } == true
        let readClaim = #"(?i)(?<!["“'])\bI(?:['’]ve| have)?\s+(?:just\s+)?(?:checked|read(?!\s+(?:your (?:message|text)|what you (?:wrote|said)))|searched|verified|opened|looked through)\b"#
        if !hasRead, text.range(of: readClaim, options: .regularExpression) != nil {
            throw ChatReplyFailure("The local reply claimed a read that did not happen.")
        }
    }
}

public struct ChatReplyFailure: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}
