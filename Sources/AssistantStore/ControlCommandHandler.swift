import AssistantCore
import Foundation

public struct ControlCommandHandler: Sendable {
    private let store: ObservationStore
    private let clock: @Sendable () -> Date
    private let answerQuestion: (@Sendable (String) async -> String)?

    public init(
        store: ObservationStore,
        clock: @escaping @Sendable () -> Date = Date.init,
        answerQuestion: (@Sendable (String) async -> String)? = nil
    ) {
        self.store = store
        self.clock = clock
        self.answerQuestion = answerQuestion
    }

    public func response(to text: String) async throws -> String? {
        guard let command = Command(text) else {
            let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard question.hasSuffix("?"), let answerQuestion else { return nil }
            return await answerQuestion(question)
        }

        switch command {
        case .ask(let question):
            guard let answerQuestion else { return "Local answers are disabled. Start serve with --model apple after running scripts/setup-local-model.sh." }
            return await answerQuestion(question)
        case .forgetting:
            return try await forgettingResponse()
        case .why(let id):
            return try await whyResponse(id: id)
        case .done(let id):
            guard try await store.completeCommitment(id: id) else {
                return "No active commitment found for [\(id)]."
            }
            return "Completed commitment [\(id)]."
        case .pause:
            try await store.setProactivityPaused(true)
            return "Proactive reminders paused. Owner commands still work."
        case .resume:
            try await store.setProactivityPaused(false)
            return "Proactive reminders enabled: at most one per day, quiet hours 10 PM–8 AM, no repeats."
        case .status:
            let status = try await store.proactivityStatus()
            var lines = ["Proactive reminders: \(status.paused ? "paused" : "enabled").", "Last gate: \(status.lastGate)."]
            if let delivery = status.lastDelivery { lines.append("Last submission: \(delivery) (not a delivery confirmation).") }
            if let checked = status.checkedAt { lines.append("Policy checked: \(Self.timestamp(checked)).") }
            for source in ObservationSource.allCases {
                guard let coverage = try await store.sourceCoverage(for: source) else {
                    lines.append("\(source.rawValue): never synced.")
                    continue
                }
                lines.append("\(coverage.source.rawValue): \(coverage.status.rawValue), synced \(Self.timestamp(coverage.lastSuccessfulSync)).")
            }
            return lines.joined(separator: "\n")
        case .meeting(let person):
            do {
                let evidence = try await MeetingContextService(store: store, clock: clock).evidence(for: person)
                var lines = ["Upcoming meeting:", evidence.meeting.text, "Source: \(evidence.meeting.locator)", "Recent direct messages:"]
                lines += evidence.recentMessages.map { "\(Self.timestamp($0.sourceTimestamp ?? $0.observedAt)): \(Self.excerpt($0.text)) [\($0.locator)]" }
                lines += evidence.coverage.map { "\($0.source.rawValue): \($0.status.rawValue), synced \(Self.timestamp($0.lastSuccessfulSync))" }
                return lines.joined(separator: "\n")
            } catch let failure as MeetingContextFailure {
                return failure.description
            }
        case .help:
            return Self.help
        case .invalid(let usage):
            return usage
        }
    }

    private func forgettingResponse() async throws -> String {
        let commitments = try await store.openCommitments(limit: 20)
        var lines: [String]
        if commitments.isEmpty {
            lines = ["No open commitments matched the deterministic rule."]
        } else {
            lines = ["Open commitments:"]
            for commitment in commitments {
                let timing = commitment.dueAt < clock() ? "overdue" : "upcoming"
                lines.append(
                    "[\(commitment.id)] \(timing) \(Self.timestamp(commitment.dueAt))"
                )
                lines.append(commitment.summary)
            }
            lines.append("Reply /why <id> for evidence or /done <id> to complete it.")
        }
        lines.append(contentsOf: try await coverageLines())
        return lines.joined(separator: "\n")
    }

    private func whyResponse(id: String) async throws -> String {
        guard let evidence = try await store.commitmentEvidence(id: id) else {
            return "Commitment not found: [\(id)]."
        }

        let commitment = evidence.commitment
        let observation = evidence.observation
        var lines = [
            "Why [\(commitment.id)]",
            "Claim: \(commitment.summary)",
            "Status: \(commitment.status.rawValue)",
            "Due: \(Self.timestamp(commitment.dueAt)) (matched “\(commitment.dueText)”)"
        ]
        if let sourceTimestamp = observation.sourceTimestamp {
            lines.append("Evidence sent: \(Self.timestamp(sourceTimestamp))")
        }
        if !observation.handles.isEmpty {
            lines.append("Conversation: \(observation.handles.joined(separator: ", "))")
        }
        lines.append("Excerpt: “\(Self.excerpt(observation.text))”")
        lines.append("Source: \(observation.locator)")
        let decisions = try await store.proactiveDecisions(commitmentID: id)
        lines += decisions.map { "Proactive gate: \($0)" }
        lines.append(contentsOf: try await coverageLines())
        return lines.joined(separator: "\n")
    }

    private func coverageLines() async throws -> [String] {
        guard let coverage = try await store.sourceCoverage(for: .messages) else {
            return ["Messages coverage: unavailable."]
        }
        var lines = [
            "Messages coverage: \(coverage.status.rawValue) through "
                + "\(Self.timestamp(coverage.lastSuccessfulSync))."
        ]
        lines.append(contentsOf: coverage.limitations.map { "Coverage limitation: \($0)" })
        return lines
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func excerpt(_ text: String) -> String {
        let singleLine = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard singleLine.count > 280 else { return singleLine }
        return String(singleLine.prefix(279)) + "…"
    }

    private static let help = """
    Commands:
    /forgetting — list open commitments
    /why <id> — show the stored evidence for a commitment
    /done <id> — mark a commitment complete
    /meeting <exact person> — meeting context from indexed evidence
    /ask <question> — answer from bounded indexed evidence when the local model is enabled
    /pause — stop unsolicited reminders
    /resume — enable the one-per-day due-commitment rule
    /status — show proactive policy and Messages coverage
    /help — show these commands
    """
}

private enum Command: Equatable {
    case ask(String)
    case forgetting
    case why(String)
    case done(String)
    case meeting(String)
    case pause
    case resume
    case status
    case help
    case invalid(String)

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        if normalized == "what am i forgetting?" || normalized == "what am i forgetting" {
            self = .forgetting
            return
        }
        guard trimmed.hasPrefix("/") else { return nil }

        let parts = trimmed.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace }
        )
        let name = parts[0].lowercased()
        let argument = parts.count == 2
            ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        switch name {
        case "/ask":
            self = argument.map(Self.ask) ?? .invalid("Usage: /ask <question>")
        case "/forgetting":
            self = .forgetting
        case "/why":
            self = argument.map(Self.why)
                ?? .invalid("Usage: /why <commitment-id>")
        case "/done":
            self = argument.map(Self.done)
                ?? .invalid("Usage: /done <commitment-id>")
        case "/help":
            self = .help
        case "/pause": self = .pause
        case "/resume": self = .resume
        case "/status": self = .status
        case "/meeting":
            self = argument.map(Self.meeting) ?? .invalid("Usage: /meeting <exact person>")
        default:
            self = .invalid("Unknown command. Send /help for available commands.")
        }
    }
}
