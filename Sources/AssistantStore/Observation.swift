import Foundation

public enum ObservationSource: String, Codable, CaseIterable, Hashable, Sendable {
    case messages
    case calendar
    case contacts
}

public enum ObservationTrust: String, Codable, Sendable {
    case ownerAuthored
    case structuredSource
    case knownExternal
    case unknownExternal
}

public struct Observation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let source: ObservationSource
    public let externalID: String
    public let versionHash: String
    public let sourceRevision: Int64
    public let observedAt: Date
    public let sourceTimestamp: Date?
    public let trust: ObservationTrust
    public let text: String
    public let locator: String
    public let tombstone: Bool

    public init(
        id: UUID = UUID(),
        source: ObservationSource,
        externalID: String,
        versionHash: String,
        sourceRevision: Int64,
        observedAt: Date = Date(),
        sourceTimestamp: Date? = nil,
        trust: ObservationTrust,
        text: String,
        locator: String,
        tombstone: Bool = false
    ) {
        self.id = id
        self.source = source
        self.externalID = externalID
        self.versionHash = versionHash
        self.sourceRevision = sourceRevision
        self.observedAt = observedAt
        self.sourceTimestamp = sourceTimestamp
        self.trust = trust
        self.text = text
        self.locator = locator
        self.tombstone = tombstone
    }
}

public struct ObservationSearchHit: Equatable, Sendable {
    public let observation: Observation
    public let rank: Double

    public init(observation: Observation, rank: Double) {
        self.observation = observation
        self.rank = rank
    }
}
