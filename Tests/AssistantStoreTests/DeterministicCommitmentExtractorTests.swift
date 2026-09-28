import AssistantCore
import Foundation
import Testing
@testable import AssistantStore

struct DeterministicCommitmentExtractorTests {
    @Test
    func extractsOnlyOwnerAuthoredStatementsWithSupportedTimeCues() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let sourceDate = try #require(
            ISO8601DateFormatter().date(from: "2026-09-27T14:00:00Z")
        )
        let observation = message(
            text: "I’ll send the deck tomorrow. I will not call today. I will review this afternoon?",
            trust: .ownerAuthored,
            date: sourceDate
        )
        let extractor = DeterministicCommitmentExtractor(calendar: calendar)

        let commitments = extractor.extract(from: observation)

        #expect(commitments.count == 1)
        #expect(commitments[0].summary == "I’ll send the deck tomorrow.")
        #expect(commitments[0].dueText == "tomorrow")
        #expect(
            commitments[0].dueAt
                == ISO8601DateFormatter().date(from: "2026-09-28T23:59:59Z")
        )
        #expect(commitments[0].evidenceObservationID == observation.id)
        #expect(extractor.extract(from: observation) == commitments)
    }

    @Test
    func rejectsExternalAndUntimedStatements() {
        let extractor = DeterministicCommitmentExtractor()
        #expect(
            extractor.extract(
                from: message(text: "I’ll send it tomorrow", trust: .knownExternal)
            ).isEmpty
        )
        #expect(
            extractor.extract(
                from: message(text: "I’ll send it soon", trust: .ownerAuthored)
            ).isEmpty
        )
    }

    @Test
    func rejectsObservedAvailabilityAndHedgedIntentFalsePositives() {
        let extractor = DeterministicCommitmentExtractor()
        let falsePositives = [
            "I’ll have time tmr I’m just tired today bc of red eye",
            "I will try to leave by 8 smth today",
        ]

        for text in falsePositives {
            #expect(
                extractor.extract(
                    from: message(text: text, trust: .ownerAuthored)
                ).isEmpty
            )
        }
    }

    @Test
    func keepsStrongCommitmentsAndIgnoresTimeCuesInExplanations() {
        let extractor = DeterministicCommitmentExtractor()

        #expect(
            extractor.extract(
                from: message(
                    text: "I will finish re-writing the confusing parts of the paper manually by tonight and will do another pass tomorrow morning",
                    trust: .ownerAuthored
                )
            ).count == 1
        )
        #expect(
            extractor.extract(
                from: message(
                    text: "I’ll send it soon because I’m busy today",
                    trust: .ownerAuthored
                )
            ).isEmpty
        )
    }

    private func message(
        text: String,
        trust: ObservationTrust,
        date: Date = Date(timeIntervalSince1970: 2_000_000_000)
    ) -> Observation {
        Observation(
            source: .messages,
            externalID: UUID().uuidString,
            versionHash: "v1",
            sourceRevision: 1,
            observedAt: date,
            sourceTimestamp: date,
            trust: trust,
            text: text,
            locator: "imsg:test"
        )
    }
}
