import Foundation

public enum AssertionPredicate: String, Codable, Sendable {
    case commitmentCreated
}

public enum AssertionStatus: String, Codable, Sendable {
    case active
    case completed
}

public struct CommitmentAssertion: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let predicate: AssertionPredicate
    public let status: AssertionStatus
    public let summary: String
    public let dueAt: Date
    public let dueText: String
    public let confidence: Double
    public let evidenceObservationID: UUID
    public let extractorID: String
    public let schemaVersion: String
    public let createdAt: Date

    public init(
        id: String,
        predicate: AssertionPredicate = .commitmentCreated,
        status: AssertionStatus = .active,
        summary: String,
        dueAt: Date,
        dueText: String,
        confidence: Double,
        evidenceObservationID: UUID,
        extractorID: String,
        schemaVersion: String,
        createdAt: Date
    ) {
        self.id = id
        self.predicate = predicate
        self.status = status
        self.summary = summary
        self.dueAt = dueAt
        self.dueText = dueText
        self.confidence = confidence
        self.evidenceObservationID = evidenceObservationID
        self.extractorID = extractorID
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
    }
}

public struct CommitmentEvidence: Equatable, Sendable {
    public let commitment: CommitmentAssertion
    public let observation: Observation

    public init(commitment: CommitmentAssertion, observation: Observation) {
        self.commitment = commitment
        self.observation = observation
    }
}
