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
        function run(argv) { return JSON.stringify(readNotes(fakeNotes(), argv[0] || '')); }
        """#
        let output = try await ContextProcess.run(executable: "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", "-e", AppContextScripts.notes + fixture, "--", "maya"], timeout: 12)
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

    @Test func malformedApplicationResponsesRejectDuplicatesAndOversizedItems() throws {
        let item = #"{"id":"n1","title":"Review","body":"body","detail":"text","timestamp":null}"#
        let repeated = "{\"total\":2,\"scanned\":2,\"skipped\":0,\"items\":[" + item + "," + item + "]}"
        #expect(throws: Error.self) { try AppContextSnapshot.decode(Data(repeated.utf8)) }
        #expect(throws: Error.self) { try AppContextSnapshot.decode(Data(repeating: 0, count: 262_145)) }
    }

    @Test func notesNativeFilterFindsCandidateAfterOldSampleCap() async throws {
        let fixture = #"""
        function fakeNotes() {
            var items = [];
            for (var i = 0; i < 250; i++) {
                items.push({index: i, id: function() { return 'note-' + this.index; },
                    name: function() { return this.index === 249 ? 'Maya launch plan' : 'Other note'; },
                    body: function() { return '<div>launch dates and cost</div>'; },
                    modificationDate: function() { return new Date('2026-10-04T18:00:00Z'); }});
            }
            function notes() { return items; }
            notes.whose = function(predicate) {
                var clauses = predicate._and || [predicate];
                return function() { return items.filter(function(item) {
                    return clauses.every(function(clause) {
                        var term = clause._or[0].name._contains;
                        return (item.name() + '\n' + item.body()).toLowerCase().indexOf(term) >= 0;
                    });
                }); };
            };
            return {notes: notes, accounts: function() { return [{}]; }};
        }
        function run() { return JSON.stringify(readNotes(fakeNotes(), 'maya launch')); }
        """#
        let output = try await ContextProcess.run(executable: "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", "-e", AppContextScripts.notes + fixture], timeout: 12)
        let snapshot = try AppContextSnapshot.decode(output.data)
        #expect(snapshot.total == 250)
        #expect(snapshot.scanned == 1)
        #expect(snapshot.filterApplied == true)
        #expect(snapshot.items[0].id == "note-249")
        #expect(snapshot.result(source: "notes").coverage[0].contains("filtered candidates"))
    }

    @Test func noteBytePrefixIsUnicodeSafeAndCoverageDoesNotClaimComplete() async throws {
        let fixture = #"""
        function run() {
            var note = {id: function() { return 'unicode'; }, name: function() { return 'Emoji'; },
                body: function() { return '😀'.repeat(20000); }, modificationDate: function() { return new Date(); }};
            var output = readNotes({notes: function() { return [note]; }}, '');
            output.inspectedUTF8Bytes = plainNote(note.body()).length * 2;
            return JSON.stringify(output);
        }
        """#
        let output = try await ContextProcess.run(executable: "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", "-e", AppContextScripts.notes + fixture], timeout: 12)
        let snapshot = try AppContextSnapshot.decode(output.data)
        #expect(snapshot.items[0].body.utf8.count <= 16_384)
        let json = try #require(JSONSerialization.jsonObject(with: output.data) as? [String: Any])
        #expect(json["inspectedUTF8Bytes"] as? Int == 32_768)
        #expect(snapshot.result(source: "notes").coverage[0].contains("not a search of every note"))
    }

    @Test func errorEnvelopesDistinguishDenialTimeoutAndScriptingFailures() throws {
        for (code, expected) in [(-1743, MacContextFailureKind.permissionDenied), (-1712, .timedOut), (-1700, .scriptingFailed)] {
            do {
                _ = try AppContextSnapshot.decode(Data("{\"failure\":{\"code\":\(code)}}".utf8))
                Issue.record("Expected classified application failure")
            } catch let failure as MacContextFailure {
                #expect(failure.kind == expected)
                #expect(failure.systemCode == code)
            }
        }
        let allSkipped = #"{"items":[],"total":2,"scanned":2,"skipped":2}"#
        do {
            _ = try AppContextSnapshot.decode(Data(allSkipped.utf8))
            Issue.record("All unreadable items must not be connected as an empty source")
        } catch let failure as MacContextFailure { #expect(failure.kind == .readFailed) }
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
