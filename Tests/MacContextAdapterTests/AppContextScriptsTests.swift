import Foundation
import LocalInference
import Testing
@testable import MacContextAdapter

struct AppContextScriptsTests {
    @Test func notesFixtureReadsPlainTextAndBoundsWithoutApplicationLaunch() async throws {
        let fixture = #"""
        function fakeNotes() {
            var items = [];
            for (var i = 0; i < 220; i++) {
                items.push({index: i,
                    id: function() { return 'note-' + this.index; },
                    name: function() { return 'Maya project ' + this.index; },
                    body: function() { return '<h1>Review</h1><div>Costs &amp; dates<br>Ready</div>' + 'x'.repeat(5000); },
                    modificationDate: function() { return new Date('2026-10-04T18:00:00Z'); }
                });
            }
            return {notes: function() { return items; }};
        }
        function run() { return JSON.stringify(readNotes(fakeNotes(), 'maya')); }
        """#
        let output = try await ContextProcess.run(executable: "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", "-e", AppContextScripts.notes + fixture], timeout: 12)
        let snapshot = try AppContextSnapshot.decode(output.data)
        #expect(snapshot.total == 220)
        #expect(snapshot.scanned == 200)
        #expect(snapshot.items.count == 8)
        #expect(snapshot.items[0].body.contains("Costs & dates\nReady"))
        #expect(!snapshot.items[0].body.contains("<div>"))
        #expect(snapshot.items.allSatisfy { $0.body.count <= 4096 })
        let result = snapshot.result(source: "notes")
        #expect(result.records.allSatisfy { $0.trust == "unknownExternal" })
        try result.validate()
    }

    @Test func remindersFixtureFiltersCompletionAndSortsByDueDate() async throws {
        let fixture = #"""
        function fakeReminders() {
            function item(id, done, date) {
                return {id: function() { return id; }, name: function() { return 'Maya review'; },
                    body: function() { return 'Confirm the cost'; }, completed: function() { return done; },
                    dueDate: function() { return date ? new Date(date) : null; },
                    modificationDate: function() { return new Date('2026-10-04T18:00:00Z'); }};
            }
            return {reminders: function() { return [item('later', false, '2020-02-01T12:00:00Z'),
                item('completed', true, '2020-01-01T12:00:00Z'), item('earlier', false, '2020-01-02T12:00:00Z')]; }};
        }
        function run() { return JSON.stringify(readReminders(fakeReminders(), 'maya overdue')); }
        """#
        let output = try await ContextProcess.run(executable: "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", "-e", AppContextScripts.reminders + fixture], timeout: 12)
        let snapshot = try AppContextSnapshot.decode(output.data)
        #expect(snapshot.scanned == 3)
        #expect(snapshot.items.map(\.id) == ["earlier", "later"])
        #expect(snapshot.items[0].detail.contains("Completed: no"))
        try snapshot.result(source: "reminders").validate()
    }

    @Test func malformedApplicationResponsesRejectDuplicatesAndOversizedItems() throws {
        let item = #"{"id":"n1","title":"Review","body":"body","detail":"text","timestamp":null}"#
        let repeated = "{\"total\":2,\"scanned\":2,\"skipped\":0,\"items\":[" + item + "," + item + "]}"
        #expect(throws: Error.self) { try AppContextSnapshot.decode(Data(repeated.utf8)) }
        #expect(throws: Error.self) { try AppContextSnapshot.decode(Data(repeating: 0, count: 262_145)) }
    }

    @Test func helperOutputLimitAndDeadlineAreEnforced() async throws {
        let output = try await ContextProcess.run(executable: "/usr/bin/printf",
            arguments: ["%s", String(repeating: "x", count: 50_000)], timeout: 3, limit: 8_192)
        #expect(output.truncated)
        #expect(output.data.count == 8_192)
        await #expect(throws: MacContextFailure.self) {
            try await ContextProcess.run(executable: "/bin/sleep", arguments: ["3"], timeout: 0.1)
        }
    }
}
