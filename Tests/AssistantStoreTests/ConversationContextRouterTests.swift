import Testing
@testable import AssistantStore

struct ConversationContextRouterTests {
    @Test func ordinaryConversationKeepsRecentChatWithoutScanningSources() {
        for prompt in [
            "Hello!", "How are you doing?", "Tell me a joke.", "Can you tell me a joke?",
            "What did I just say?", "Repeat your last answer.",
            "Can you help me think through an idea?"
        ] {
            #expect(ConversationContextRouter.retrievalQuery(for: prompt, previous: nil) == nil)
        }
    }

    @Test func naturalPersonalQuestionsFindLocalContext() {
        for prompt in [
            "Do I have any meetings tomorrow?",
            "What's on my calendar this week?",
            "What did Maya text me?",
            "What's Maya's phone number?",
            "How much did I sleep?",
            "Did we agree on a deadline?",
            "What's my favorite restaurant?"
        ] {
            #expect(ConversationContextRouter.retrievalQuery(for: prompt, previous: nil) == prompt)
        }
    }

    @Test func followUpsCarryPersonalTopicAcrossTurns() {
        #expect(ConversationContextRouter.retrievalQuery(
            for: "And tomorrow?", previous: "What's on my schedule today?"
        ) == "What's on my schedule today? And tomorrow?")
        #expect(ConversationContextRouter.retrievalQuery(
            for: "What about Maya?", previous: "Did I get any texts from Noah?"
        ) == "Did I get any texts from Noah? What about Maya?")
        #expect(ConversationContextRouter.retrievalQuery(
            for: "And tomorrow?", previous: "Tell me a joke."
        ) == nil)
    }
}
