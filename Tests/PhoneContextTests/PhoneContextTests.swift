import Foundation
import LocalInference
import PhoneContext
import Testing

struct PhoneContextTests {
    @Test func mergesOverlapsClipsTheWindowAndDoesNotCountGaps() {
        func date(_ hours: Double) -> Date { Date(timeIntervalSince1970: hours * 3_600) }
        let intervals = [DateInterval(start: date(-1), end: date(2)), DateInterval(start: date(1), end: date(3)), DateInterval(start: date(4), end: date(6)), DateInterval(start: date(9), end: date(10))]
        #expect(SleepSummary.hours(intervals: intervals, window: DateInterval(start: date(0), end: date(5))) == 4)
        #expect(SleepSummary.hours(intervals: [], window: DateInterval(start: date(0), end: date(5))) == 0)
    }

    @Test func noSourcesEnabledDoesNotReadPrivateData() async throws {
        let request = try await PhoneContextSource().request(question: "What is on my calendar?", includeCalendar: false, includeContacts: false, includeSleep: false)
        #expect(request.records.isEmpty)
        #expect(request.coverage.count == 1)
    }

    @Test func portableContextRoundTripsAndRejectsOversizedOrInvalidImports() throws {
        let demo = ContextDocument.demo(now: Date(timeIntervalSince1970: 2_000_000_000))
        #expect(try ContextDocument.decode(ContextDocument.encode(demo)) == demo)
        #expect(throws: (any Error).self) { try ContextDocument.decode(Data(repeating: 32, count: ContextDocument.maximumBytes + 1)) }
        let invalid = Data("{\"schemaVersion\":\"unknown\"}".utf8)
        #expect(throws: (any Error).self) { try ContextDocument.decode(invalid) }
    }
}
