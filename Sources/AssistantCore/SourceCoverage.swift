import Foundation

public enum CoverageStatus: String, Codable, Sendable {
    case ready
    case partial
    case unavailable
}

public struct SourceCoverage: Codable, Equatable, Sendable {
    public let source: ObservationSource
    public let status: CoverageStatus
    public let earliestAvailable: Date?
    public let latestObserved: Date?
    public let lastSuccessfulSync: Date
    public let cursor: String?
    public let limitations: [String]

    public init(
        source: ObservationSource,
        status: CoverageStatus,
        earliestAvailable: Date?,
        latestObserved: Date?,
        lastSuccessfulSync: Date,
        cursor: String?,
        limitations: [String]
    ) {
        self.source = source
        self.status = status
        self.earliestAvailable = earliestAvailable
        self.latestObserved = latestObserved
        self.lastSuccessfulSync = lastSuccessfulSync
        self.cursor = cursor
        self.limitations = limitations
    }
}
