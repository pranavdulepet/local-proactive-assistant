import AssistantCore
import Foundation
import LocalInference

/// Decide when the owner's current turn needs indexed personal evidence.
/// The model still handles ordinary dialogue using the recent transcript.
struct ConversationContextRouter {
    static func retrievalQuery(for message: String, previous: String?) -> String? {
        let words = tokens(message)
        guard !words.isEmpty else { return nil }
        if asksAboutRecentTranscript(words) { return nil }

        if needsEvidence(words, isQuestion: message.contains("?")) {
            return message
        }
        guard let previous, isFollowUp(message),
              needsEvidence(tokens(previous), isQuestion: previous.contains("?")) else {
            return nil
        }
        return EvidenceText.bounded(previous + " " + message, bytes: 512)
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func needsEvidence(_ words: Set<String>, isQuestion: Bool) -> Bool {
        let sources: Set<String> = [
            "calendar", "schedule", "agenda", "appointment", "appointments", "meeting",
            "meetings", "event", "events", "availability", "plans",
            "message", "messages", "imessage", "sms", "text", "texts", "texted",
            "contact", "contacts", "phone", "number", "email", "address",
            "sleep", "slept", "health", "steps",
            "commitment", "commitments", "promise", "promised", "deadline", "forgetting"
        ]
        if !words.isDisjoint(with: sources) { return true }

        let pastActions: Set<String> = [
            "said", "say", "sent", "send", "told", "replied", "discussed",
            "decided", "agreed", "asked", "wrote", "written"
        ]
        let person: Set<String> = ["i", "me", "we", "us", "my", "mine", "our", "ours"]
        if !words.isDisjoint(with: pastActions) &&
            (!words.isDisjoint(with: person) || words.contains("who")) {
            return true
        }
        if words.contains("tell") && words.contains("did") &&
            !words.isDisjoint(with: person) {
            return true
        }

        let asks: Set<String> = ["what", "when", "where", "who", "which", "how", "did", "do", "does", "is", "are"]
        let possessive: Set<String> = ["my", "mine", "our", "ours"]
        return !words.isDisjoint(with: possessive) && (isQuestion || !words.isDisjoint(with: asks))
    }

    private static func asksAboutRecentTranscript(_ words: Set<String>) -> Bool {
        let near: Set<String> = ["just", "previous", "last", "earlier", "moment"]
        let speech: Set<String> = ["said", "say", "asked", "answered", "answer", "wrote", "replied"]
        let speaker: Set<String> = ["i", "you", "my", "your"]
        let external: Set<String> = ["text", "texts", "message", "messages", "to", "with", "about", "yesterday", "week", "month"]
        return !words.isDisjoint(with: near) && !words.isDisjoint(with: speech) &&
            !words.isDisjoint(with: speaker) && words.isDisjoint(with: external)
    }

    private static func isFollowUp(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["and ", "also ", "what about", "how about", "tell me more",
                "when is it", "who is that", "then ", "what else"].contains {
            lower.hasPrefix($0)
        }
    }
}
