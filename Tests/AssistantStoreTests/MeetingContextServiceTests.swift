import AssistantCore
import Foundation
import Testing
@testable import AssistantStore

struct MeetingContextServiceTests {
    @Test
    func joinsAnExactContactToAnUpcomingMeetingAndRecentMessages() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = try ObservationStore()
        let contact = observation(
            source: .contacts,
            externalID: "contact-alex",
            timestamp: nil,
            handles: ["alex@example.com", "+14155550123"],
            text: "Alex Rivera\nNickname: Lex\nEmails: alex@example.com"
        )
        let meeting = observation(
            source: .calendar,
            externalID: "event-1",
            timestamp: now.addingTimeInterval(86_400),
            handles: ["alex@example.com"],
            text: "Project Cedar review\nStatus: confirmed\nAttendees: alex@example.com"
        )
        let relevantMessage = observation(
            source: .messages,
            externalID: "message-1",
            timestamp: now.addingTimeInterval(-3_600),
            handles: ["+14155550123"],
            text: "Bring the launch checklist"
        )
        let unrelatedMessage = observation(
            source: .messages,
            externalID: "message-2",
            timestamp: now.addingTimeInterval(-1_800),
            handles: ["other@example.com"],
            text: "Unrelated"
        )
        for item in [contact, meeting, relevantMessage, unrelatedMessage] {
            try await store.record(item)
        }
        try await store.refreshCoverage(
            for: .calendar,
            status: .partial,
            limitations: [],
            at: now
        )

        let evidence = try await MeetingContextService(
            store: store,
            clock: { now }
        ).evidence(for: "Lex")

        #expect(evidence.person == contact)
        #expect(evidence.meeting == meeting)
        #expect(evidence.recentMessages == [relevantMessage])
        #expect(evidence.coverage.map(\.source) == [.calendar])
    }

    @Test
    func reportsAmbiguousExactNamesInsteadOfGuessing() async throws {
        let store = try ObservationStore()
        for identifier in ["contact-1", "contact-2"] {
            try await store.record(
                observation(
                    source: .contacts,
                    externalID: identifier,
                    timestamp: nil,
                    handles: ["\(identifier)@example.com"],
                    text: "Alex Rivera"
                )
            )
        }

        do {
            _ = try await MeetingContextService(store: store).evidence(for: "Alex Rivera")
            Issue.record("Expected an ambiguous contact match")
        } catch let error as MeetingContextFailure {
            guard case .personAmbiguous(let query, let candidates) = error else {
                Issue.record("Expected personAmbiguous, got \(error)")
                return
            }
            #expect(query == "Alex Rivera")
            #expect(candidates.count == 2)
        }
    }

    private func observation(
        source: ObservationSource,
        externalID: String,
        timestamp: Date?,
        handles: [String],
        text: String
    ) -> Observation {
        Observation(
            source: source,
            externalID: externalID,
            versionHash: "v1",
            sourceRevision: 1,
            observedAt: Date(timeIntervalSince1970: 2_000_000_000),
            sourceTimestamp: timestamp,
            trust: source == .messages ? .knownExternal : .structuredSource,
            handles: handles,
            text: text,
            locator: "\(source.rawValue):\(externalID)"
        )
    }
}
