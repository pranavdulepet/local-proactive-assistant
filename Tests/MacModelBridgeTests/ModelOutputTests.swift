import Testing
@testable import MacModelBridge

struct ModelOutputTests {
    @Test func removesObservedDuplicateWithoutLosingTheReplyOrCitation() {
        #expect(ModelOutput.reply("No open reminders showing right now.\n</think>\n\nNo open reminders showing right now.")
            == "No open reminders showing right now.")
        #expect(ModelOutput.reply("5 PM [e1].\r\n</think>\r\n\r\n5 PM [e1].") == "5 PM [e1].")
    }

    @Test func separatesAnalysisFromTheFinalAnswerAndWithholdsAnUnclosedBlock() {
        #expect(ModelOutput.reply("<think>Internal reasoning.</think>\nFriday at 5 PM [e1].")
            == "Friday at 5 PM [e1].")
        #expect(ModelOutput.reply("<think>Unfinished internal reasoning.").isEmpty)
    }

    @Test func preservesQuotedMarkupAndNormalReplies() {
        for text in ["The closing tag is </think>.", "Example:\n```\n</think>\n```", "Friday at 5 PM [e1]."] {
            #expect(ModelOutput.reply(text) == text)
        }
    }
}
