import AppleModelAdapter
import Foundation
import LocalInference
import Testing

struct AppleSystemModelProviderTests {
    @Test
    func alwaysReportsAnActionableAvailabilityState() async {
        let provider = AppleSystemModelProvider()
        let state = await provider.availability()
        #expect(!state.detail.isEmpty)
        #expect(provider.modelID == "apple-system")
    }

    @Test
    func rejectsOversizedRequestsBeforeAnyModelWork() async {
        let provider = AppleSystemModelProvider()
        let request = EvidenceRequest(question: String(repeating: "x", count: 513), records: [], coverage: [])
        await #expect(throws: LocalModelFailure.self) { try await provider.answer(request) }
    }
}
