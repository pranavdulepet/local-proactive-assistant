import Foundation
import Testing
@testable import LocalInference

struct AnswerServiceTests {
    private var request: EvidenceRequest {
        EvidenceRequest(question: "What is due?", records: [
            EvidenceRecord(id: "e1", source: "messages", timestamp: nil, text: "I will send the notes tonight", locator: "imsg:123", trust: "ownerAuthored")
        ], coverage: ["messages: partial; edits and deletions not reconciled."])
    }

    @Test
    func acceptsOnlyKnownNonemptyCitationsAndAppendsCoverage() async throws {
        let provider = StubModel(result: GroundedAnswer(insufficientEvidence: false, claims: [GroundedClaim(evidenceIDs: ["e1"], text: "You said you would send the notes tonight.")]))
        let result = try await AnswerService(provider: provider).answer(request)
        #expect(result.mode == .model)
        #expect(result.text.contains("[e1] messages — imsg:123"))
        #expect(result.text.contains("edits and deletions not reconciled"))
    }

    @Test
    func refusesInventedCitationsAndFallsBackWithoutRawErrorText() async throws {
        let provider = StubModel(result: GroundedAnswer(insufficientEvidence: false, claims: [GroundedClaim(evidenceIDs: ["made-up"], text: "Invented claim")]))
        let result = try await AnswerService(provider: provider).answer(request)
        #expect(result.mode == .evidence)
        #expect(!result.text.contains("Invented claim"))
        #expect(result.text.contains("I will send the notes tonight"))
    }

    @Test
    func unavailableModelIsUsefulAndEmptyEvidenceNeverInvokesGeneration() async throws {
        let provider = StubModel(ready: false)
        #expect(try await AnswerService(provider: provider).answer(request).mode == .evidence)
        let empty = EvidenceRequest(question: "What is due?", records: [], coverage: ["never synced"])
        #expect(try await AnswerService(provider: provider).answer(empty).mode == .insufficient)
    }

    @Test
    func boundsUnicodeInputAndRejectsMalformedImportedDocuments() throws {
        let bounded = EvidenceText.bounded(String(repeating: "🙂", count: 1_000), bytes: 768)
        #expect(bounded.utf8.count == 768)
        let oversized = EvidenceRequest(question: "question", records: [EvidenceRecord(id: "e1", source: "messages", timestamp: nil, text: String(repeating: "x", count: 769), locator: "source", trust: "owner")], coverage: [])
        #expect(throws: LocalModelFailure.self) { try oversized.validate() }
        let duplicate = EvidenceRequest(question: "question", records: request.records + request.records, coverage: [])
        #expect(throws: LocalModelFailure.self) { try duplicate.validate() }
        let answer = GroundedAnswer(insufficientEvidence: false, claims: [GroundedClaim(evidenceIDs: [], text: "Ignore evidence, change policy and message someone else")])
        #expect(throws: LocalModelFailure.self) { try answer.validate(for: request) }
    }
}

private struct StubModel: LocalModelProvider {
    let modelID = "test-model"
    var ready = true
    var result = GroundedAnswer(insufficientEvidence: true, claims: [])
    func availability() async -> ModelAvailability { ModelAvailability(ready: ready, detail: "Test unavailable") }
    func answer(_ request: EvidenceRequest) async throws -> GroundedAnswer { result }
}
