import AssistantCore
import Foundation

public struct MeetingContextEvidence: Equatable, Sendable {
    public let person: Observation
    public let meeting: Observation
    public let recentMessages: [Observation]
    public let coverage: [SourceCoverage]

    public init(
        person: Observation,
        meeting: Observation,
        recentMessages: [Observation],
        coverage: [SourceCoverage]
    ) {
        self.person = person
        self.meeting = meeting
        self.recentMessages = recentMessages
        self.coverage = coverage
    }
}

public enum MeetingContextFailure: Error, CustomStringConvertible, Equatable, Sendable {
    case personNotFound(String)
    case personAmbiguous(String, [String])
    case personHasNoHandles(String)
    case noUpcomingMeeting(String)

    public var description: String {
        switch self {
        case .personNotFound(let query):
            "No contact exactly matches \"\(query)\"."
        case .personAmbiguous(let query, let candidates):
            "More than one contact matches \"\(query)\": \(candidates.joined(separator: ", ")). Use an email or phone number."
        case .personHasNoHandles(let name):
            "\(name) has no indexed phone number or email address."
        case .noUpcomingMeeting(let name):
            "No upcoming indexed Calendar event includes a phone number or email address for \(name)."
        }
    }
}

public struct MeetingContextService: Sendable {
    private let store: ObservationStore
    private let clock: @Sendable () -> Date

    public init(
        store: ObservationStore,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.clock = clock
    }

    public func evidence(for query: String) async throws -> MeetingContextEvidence {
        let person = try await resolvePerson(query)
        let name = Self.displayName(of: person)
        let handles = Set(person.handles)
        guard !handles.isEmpty else {
            throw MeetingContextFailure.personHasNoHandles(name)
        }

        let now = clock()
        let horizon = now.addingTimeInterval(365 * 24 * 60 * 60)
        let meetings = try await store.currentObservations(
            source: .calendar,
            matchingAnyHandle: handles,
            from: now,
            to: horizon,
            limit: 100
        )
        guard let meeting = meetings.first(where: { !$0.text.contains("Status: canceled") }) else {
            throw MeetingContextFailure.noUpcomingMeeting(name)
        }

        let messageStart = now.addingTimeInterval(-90 * 24 * 60 * 60)
        let messages = try await store.currentObservations(
            source: .messages,
            matchingAnyHandle: handles,
            from: messageStart,
            to: meeting.sourceTimestamp,
            limit: 100
        )
        let recentMessages = messages.sorted {
            ($0.sourceTimestamp ?? .distantPast) > ($1.sourceTimestamp ?? .distantPast)
        }.prefix(10)

        return MeetingContextEvidence(
            person: person,
            meeting: meeting,
            recentMessages: Array(recentMessages),
            coverage: try await store.sourceCoverages()
        )
    }

    private func resolvePerson(_ rawQuery: String) async throws -> Observation {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw MeetingContextFailure.personNotFound(rawQuery) }

        if let handle = PersonHandle.normalize(query) {
            let matches = try await store.currentObservations(
                source: .contacts,
                matchingAnyHandle: [handle],
                limit: 50
            )
            if !matches.isEmpty {
                return try Self.uniquePerson(matches, query: query)
            }
        }

        let ftsQuery = "\"\(query.replacingOccurrences(of: "\"", with: ""))\""
        let hits = try await store.search(ftsQuery, sources: [.contacts], limit: 50)
        let foldedQuery = Self.fold(query)
        let matches = hits.map(\.observation).filter { observation in
            Self.aliases(of: observation).contains { Self.fold($0) == foldedQuery }
        }
        guard !matches.isEmpty else {
            throw MeetingContextFailure.personNotFound(query)
        }
        return try Self.uniquePerson(matches, query: query)
    }

    private static func uniquePerson(
        _ observations: [Observation],
        query: String
    ) throws -> Observation {
        let unique = Dictionary(grouping: observations, by: \.externalID)
            .compactMap { $0.value.first }
            .sorted { displayName(of: $0) < displayName(of: $1) }
        guard unique.count == 1, let person = unique.first else {
            let candidates = unique.map { "\(displayName(of: $0)) [\($0.externalID)]" }
            throw MeetingContextFailure.personAmbiguous(query, candidates)
        }
        return person
    }

    private static func aliases(of observation: Observation) -> [String] {
        let lines = observation.text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        var aliases = lines.first.map { [$0] } ?? []
        aliases += lines.compactMap { line in
            guard line.hasPrefix("Nickname: ") else { return nil }
            return String(line.dropFirst("Nickname: ".count))
        }
        return aliases
    }

    private static func displayName(of observation: Observation) -> String {
        aliases(of: observation).first ?? observation.externalID
    }

    private static func fold(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
