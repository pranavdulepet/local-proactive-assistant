import AssistantCore
import Foundation

/// Exact day-agenda questions are answered from indexed Calendar events.
public struct CalendarAgendaService: Sendable {
    private let store: ObservationStore
    private let clock: @Sendable () -> Date

    public init(store: ObservationStore, clock: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.clock = clock
    }

    public func response(to question: String) async throws -> String? {
        let text = question.lowercased()
        guard text.contains("calendar") || text.contains("schedule") else { return nil }
        let dayOffset: Int
        let dayName: String
        let words = Set(text.split(whereSeparator: { !$0.isLetter }).map(String.init))
        if text.contains("tomorrow") || words.contains("tmr") {
            dayOffset = 1
            dayName = "tomorrow"
        } else if text.contains("today") {
            dayOffset = 0
            dayName = "today"
        } else {
            return nil
        }

        guard let coverage = try await store.sourceCoverage(for: .calendar) else {
            return "Calendar has never synced on this Mac. Check Calendar access and send /status."
        }
        let calendar = Calendar.autoupdatingCurrent
        guard let start = calendar.date(
            byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: clock())
        ), let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return "Could not determine the requested Calendar day."
        }

        let events = try await store.currentObservations(
            source: .calendar, trust: .structuredSource,
            from: start, to: end.addingTimeInterval(-0.001), limit: 50
        ).filter { !$0.text.contains("Status: canceled") }

        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        var lines = [events.isEmpty
            ? "No indexed Calendar events start \(dayName)."
            : "Indexed Calendar events starting \(dayName):"]
        for (index, event) in events.prefix(12).enumerated() {
            let title = event.text.split(separator: "\n").first.map(String.init) ?? "Untitled event"
            let time = event.text.contains("All day: yes")
                ? "All day"
                : event.sourceTimestamp.map(formatter.string(from:)) ?? "Time unavailable"
            lines.append("\(index + 1). \(time) — \(title) [\(index + 1)]")
        }
        if events.count > 12 {
            lines.append("Showing 12 of \(events.count) indexed events.")
        }
        for (index, event) in events.prefix(12).enumerated() {
            lines.append("[\(index + 1)] \(event.locator)")
        }
        let syncTime = ISO8601DateFormatter().string(from: coverage.lastSuccessfulSync)
        lines.append("Calendar \(coverage.status.rawValue), synced \(syncTime). Times in \(calendar.timeZone.identifier).")
        lines.append(contentsOf: coverage.limitations.map { "Coverage: \($0)" })
        return lines.joined(separator: "\n")
    }
}
