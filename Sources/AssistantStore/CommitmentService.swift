import Foundation

public struct CommitmentExtractionSummary: Equatable, Sendable {
    public let scanned: Int
    public let extracted: Int
    public let inserted: Int
    public let since: Date

    public init(scanned: Int, extracted: Int, inserted: Int, since: Date) {
        self.scanned = scanned
        self.extracted = extracted
        self.inserted = inserted
        self.since = since
    }
}

public struct CommitmentService: Sendable {
    private let store: ObservationStore
    private let extractor: DeterministicCommitmentExtractor
    private let clock: @Sendable () -> Date

    public init(
        store: ObservationStore,
        extractor: DeterministicCommitmentExtractor = .init(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.extractor = extractor
        self.clock = clock
    }

    public func extractRecent(days: Int = 30) async throws -> CommitmentExtractionSummary {
        let boundedDays = min(max(days, 1), 365)
        let since = clock().addingTimeInterval(-Double(boundedDays) * 24 * 60 * 60)
        let observations = try await store.currentObservations(
            source: .messages,
            trust: .ownerAuthored,
            from: since,
            limit: 100_000
        )
        let assertions = observations.flatMap(extractor.extract(from:))
        let inserted = try await store.recordCommitments(assertions)
        return CommitmentExtractionSummary(
            scanned: observations.count,
            extracted: assertions.count,
            inserted: inserted,
            since: since
        )
    }
}
