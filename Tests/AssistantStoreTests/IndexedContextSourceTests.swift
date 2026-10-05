import AssistantCore
import Foundation
import LocalInference
import Testing
@testable import AssistantStore

struct IndexedContextSourceTests {
    @Test func calendarReadsUsePlannerISODateRatherThanToday() async throws {
        let store = try ObservationStore()
        let calendar = Calendar.autoupdatingCurrent
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12))!
        for (id, date) in [("target", day), ("other", day.addingTimeInterval(-86_400))] {
            try await store.record(Observation(
                source: .calendar, externalID: id, versionHash: "v1", sourceRevision: 1,
                observedAt: Date(), sourceTimestamp: date, trust: .structuredSource,
                text: "Event \(id)", locator: "calendar:\(id)"
            ))
        }
        let result = try await IndexedContextSource(store: store).execute(
            ContextToolCall(tool: .searchIndex, query: "calendar 2026-10-08")
        )
        #expect(result.records.map(\.locator) == ["calendar:target"])
    }
    @Test func modelChosenMailReadWorksWithoutNaturalLanguageClassifier() async throws {
        let store = try ObservationStore()
        let source = CountingContextMail()
        let reader = IndexedContextSource(store: store, mail: source)
        let result = try await reader.execute(ContextToolCall(tool: .mailInbox, query: "Maya project"))
        #expect(await source.count() == 1)
        #expect(result.records.count == 1)
        #expect(result.records[0].source == "mail")
        #expect(result.records[0].text.contains("Review the project"))
        #expect(result.coverage.allSatisfy { $0.hasPrefix("mail:") })
        try result.validate()
    }

    @Test func indexedEmailRequestsRefreshAndFailedReadsDoNotReturnStaleMail() async throws {
        let store = try ObservationStore()
        let source = CountingContextMail()
        let reader = IndexedContextSource(store: store, mail: source)
        _ = try await reader.execute(ContextToolCall(tool: .searchIndex, query: "unread emails"))
        #expect(await source.count() == 1)
        let failing = IndexedContextSource(store: store, mail: DeniedContextMail())
        await #expect(throws: MailSourceFailure.self) {
            _ = try await failing.execute(ContextToolCall(tool: .mailInbox))
        }
    }

    @Test func fileReadsDelegateOnlyAfterHostValidation() async throws {
        let source = ContextReadSpy()
        let reader = IndexedContextSource(store: try ObservationStore(), additional: source)
        let call = ContextToolCall(tool: .readFile, path: "/Users/test/Documents/plan.txt")
        _ = try await reader.execute(call)
        #expect(await source.calls() == [call])
        await #expect(throws: Error.self) {
            _ = try await reader.execute(ContextToolCall(tool: .readFile, path: "/Users/test/../secrets"))
        }
        #expect(await source.calls().count == 1)
    }
}

private actor CountingContextMail: MailSource {
    private var reads = 0
    func count() -> Int { reads }
    func inboxSnapshot() -> MailSnapshot {
        reads += 1
        return MailSnapshot(messages: [MailMessageRecord(
            externalID: "review", sender: "Maya", subject: "Project",
            receivedAt: Date(), unread: true, body: "Review the project on Tuesday."
        )], totalInbox: 1, scanned: 1)
    }
}

private struct DeniedContextMail: MailSource {
    func inboxSnapshot() throws -> MailSnapshot { throw MailSourceFailure("Allow Automation > Mail.") }
}

private actor ContextReadSpy: ReadContextSource {
    private var captured: [ContextToolCall] = []
    func calls() -> [ContextToolCall] { captured }
    func execute(_ call: ContextToolCall) -> ContextToolResult {
        captured.append(call)
        return ContextToolResult(records: [], coverage: ["Documents: empty fixture."])
    }
}
