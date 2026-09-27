import CryptoKit
import Foundation

public struct DeterministicCommitmentExtractor: Sendable {
    public static let extractorID = "owner-future-time-cue"
    public static let schemaVersion = "commitment.v1"
    private static let expression = try! NSRegularExpression(
        pattern: #"\b(?:I['’]ll|I will)\s+([^.!?\n]+)([.!?]|$)"#,
        options: [.caseInsensitive]
    )

    private let calendar: Calendar

    public init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    public func extract(from observation: Observation) -> [CommitmentAssertion] {
        guard observation.source == .messages,
              observation.trust == .ownerAuthored,
              let sourceTimestamp = observation.sourceTimestamp else {
            return []
        }

        let text = observation.text as NSString
        let matches = Self.expression.matches(
            in: observation.text,
            range: NSRange(location: 0, length: text.length)
        )
        return matches.compactMap { match in
            guard match.numberOfRanges == 3,
                  text.substring(with: match.range(at: 2)) != "?" else { return nil }
            let action = text.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !action.lowercased().hasPrefix("not "),
                  let due = dueWindow(in: action, relativeTo: sourceTimestamp) else {
                return nil
            }
            let summary = text.substring(with: match.range(at: 0))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CommitmentAssertion(
                id: assertionID(
                    observationID: observation.id,
                    matchLocation: match.range.location,
                    summary: summary
                ),
                summary: summary,
                dueAt: due.date,
                dueText: due.text,
                confidence: 1,
                evidenceObservationID: observation.id,
                extractorID: Self.extractorID,
                schemaVersion: Self.schemaVersion,
                createdAt: sourceTimestamp
            )
        }
    }

    private func dueWindow(
        in action: String,
        relativeTo sourceTimestamp: Date
    ) -> (date: Date, text: String)? {
        let lowercased = action.lowercased()
        let cues = [
            "this afternoon",
            "this evening",
            "this morning",
            "tomorrow",
            "tonight",
            "today",
        ]
        guard let cue = cues.first(where: {
            lowercased.range(
                of: #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#,
                options: .regularExpression
            ) != nil
        }) else { return nil }

        let dayStart = calendar.startOfDay(for: sourceTimestamp)
        let date: Date?
        switch cue {
        case "this morning":
            date = calendar.date(byAdding: .hour, value: 12, to: dayStart)
        case "this afternoon":
            date = calendar.date(byAdding: .hour, value: 17, to: dayStart)
        case "this evening", "tonight", "today":
            date = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: dayStart)
        case "tomorrow":
            date = calendar.date(byAdding: DateComponents(day: 2, second: -1), to: dayStart)
        default:
            date = nil
        }
        return date.map { ($0, cue) }
    }

    private func assertionID(
        observationID: UUID,
        matchLocation: Int,
        summary: String
    ) -> String {
        let input = [
            Self.extractorID,
            Self.schemaVersion,
            observationID.uuidString,
            String(matchLocation),
            summary,
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(input.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
