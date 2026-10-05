import AssistantCore
import Foundation
import ProcessSupport
import Testing
@testable import MailAdapter

struct MailStoreSourceTests {
    @Test func unreadFilteringFindsOlderInboxMessagesBeforeApplyingPageLimit() async throws {
        let snapshot = try await runFixture(query: "unread emails")
        #expect(snapshot.scope == .inbox)
        #expect(snapshot.matched == 1)
        #expect(snapshot.messages.map(\.externalID) == ["inbox-119"])
        #expect(snapshot.messages[0].unread)
        #expect(snapshot.searchComplete)
    }

    @Test func importantUnreadTriageDoesNotRequireImportanceWordsInTheEmail() async throws {
        let snapshot = try await runFixture(query: "important urgent unread emails")
        #expect(snapshot.scope == .inbox)
        #expect(snapshot.messages.map(\.externalID) == ["inbox-119"])
        #expect(!snapshot.messages[0].subject.lowercased().contains("important"))
        let explicit = try await runFixture(query: "subject:urgent", suffix: "fixtureInbox[119].subject = function() { return 'Urgent review'; };")
        #expect(explicit.messages.map(\.externalID) == ["inbox-119"])
    }

    @Test func explicitArchiveRequestFiltersFoldersBeforeApplyingTheMessageLimit() async throws {
        let snapshot = try await runFixture(query: "archive emails")
        #expect(snapshot.scope == .allMailboxes)
        #expect(snapshot.matched == 220)
        #expect(snapshot.searchedMailboxes == 1)
        #expect(snapshot.messages.allSatisfy { $0.mailbox?.contains("Archive") == true })
    }

    @Test func localMailRemainsReadableWithoutAnActiveAccount() async throws {
        let snapshot = try await runFixture(query: "archive emails", suffix: """
            var baseFixtureMail = fixtureMail;
            fixtureMail = function() {
                var mail = baseFixtureMail();
                mail.accounts = function() { return []; };
                mail.mailboxes = function() { return [fixtureArchiveBox]; };
                return mail;
            };
            """)
        #expect(snapshot.scope == .allMailboxes)
        #expect(snapshot.matched == 220)
        #expect(snapshot.searchComplete)
    }

    @Test func connectionProbeUsesMetadataWithoutFetchingBodies() async throws {
        var options = try MailStoreSource.SearchOptions(query: nil, offset: 0)
        options.probe = true
        let result = try await runFixture(options: options,
            suffix: "fixtureInbox.forEach(function(m) { m.content = function() { throw new Error('Body must not be read during connection'); }; });")
        #expect(result.messages.isEmpty)
        #expect(result.searchedMailboxes == 1)
        #expect(result.searchComplete)
    }

    @Test func keywordSearchFindsArchiveBodyBeyondTheOldInboxSample() async throws {
        let snapshot = try await runFixture(query: "Find email from Maya about project")
        #expect(snapshot.scope == .allMailboxes)
        #expect(snapshot.searchComplete)
        #expect(snapshot.searchedMailboxes == 3)
        #expect(snapshot.messages.map(\.externalID) == ["archive-219"])
        #expect(snapshot.messages[0].mailbox?.contains("Archive") == true)
        #expect(snapshot.messages[0].body.contains("project"))
        #expect(snapshot.messages[0].body.count <= 2000)
    }

    @Test func pagesAreSortedAndTellTheCallerWhenMatchesRemain() async throws {
        let first = try await runFixture(query: nil)
        let second = try await runFixture(query: nil, offset: 100)
        #expect(first.messages.count == 100)
        #expect(first.matched == 120)
        #expect(first.nextOffset == 100)
        #expect(first.messages[0].externalID == "inbox-0")
        #expect(second.messages.count == 20)
        #expect(second.nextOffset == nil)
        #expect(Set(first.messages.map(\.externalID)).isDisjoint(with: Set(second.messages.map(\.externalID))))
        #expect(first.coverageLimitations.contains { $0.contains("does not cover every matching email") })
    }

    @Test func unavailableBodiesKeepUsefulMetadataWithAnExplicitGap() async throws {
        let snapshot = try await runFixture(query: "unread emails", suffix: "fixtureInbox[119].content = function() { throw {number: -10000, message: 'private message'}; };")
        #expect(snapshot.messages.count == 1)
        #expect(!snapshot.messages[0].bodyAvailable)
        #expect(snapshot.messages[0].body.isEmpty)
        #expect(!snapshot.searchComplete)
        #expect(snapshot.coverageLimitations.contains { $0.contains("metadata only") })
    }

    @Test func queryTextTravelsAsDataAndCannotInvokeMailActions() async throws {
        let snapshot = try await runFixture(query: "Maya \"; mail.delete(); // project")
        #expect(snapshot.messages.isEmpty)
        #expect(snapshot.searchComplete)
    }

    @Test func decoderRejectsDuplicateIDsOversizedBodiesAndInvalidPagination() throws {
        let record = MailMessageRecord(externalID: "1", sender: "Maya", subject: "Review", receivedAt: Date(), unread: true, body: "body")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        #expect(throws: Error.self) {
            try MailStoreSource.decode(encoder.encode(MailSnapshot(messages: [record, record], totalInbox: 2, scanned: 2)))
        }
        let big = MailMessageRecord(externalID: "2", sender: "Maya", subject: "Review", receivedAt: Date(), unread: true, body: String(repeating: "x", count: 9000))
        #expect(throws: Error.self) {
            try MailStoreSource.decode(encoder.encode(MailSnapshot(messages: [big], totalInbox: 1, scanned: 1)))
        }
        #expect(throws: Error.self) {
            try MailStoreSource.decode(encoder.encode(MailSnapshot(messages: [record], totalInbox: 1, scanned: 1, nextOffset: 5)))
        }
    }

    @Test func diagnosticsDistinguishPermissionsAccountsTimeoutAndScriptingWithoutLeakingData() throws {
        for (code, expected) in [("permissionDenied", MailSourceFailure.Code.permissionDenied),
                                 ("noAccounts", .noAccounts), ("mailboxUnavailable", .mailboxUnavailable), ("mailNotRunning", .mailNotRunning),
                                 ("timedOut", .timedOut), ("unsupportedSearch", .unsupportedSearch)] {
            do {
                _ = try MailStoreSource.decode(Data("{\"error\":{\"code\":\"\(code)\",\"number\":null}}".utf8))
                Issue.record("Expected a classified Mail failure")
            } catch let failure as MailSourceFailure {
                #expect(failure.code == expected)
            }
        }
        let denied = MailStoreSource.processFailure("execution error: private@example.test secret subject (-1743)")
        #expect(denied.code == .permissionDenied)
        #expect(denied.appleEventCode == -1743)
        #expect(!denied.description.contains("private@example.test"))
        #expect(!denied.description.contains("secret subject"))
        #expect(MailStoreSource.processFailure("Helper request exceeded its 18s deadline").code == .timedOut)
        #expect(MailStoreSource.processFailure("unrecognized private content (-1708)").code == .unsupportedSearch)
    }

    @Test func searchDatesUseWholeDaysAndRejectOversizedRequests() throws {
        let options = try MailStoreSource.SearchOptions(query: "emails Maya 2026-10-04 2026-10-05", offset: 100)
        #expect(options.terms == ["maya"])
        #expect(options.after != nil && options.before != nil)
        #expect(options.offset == 100)
        #expect(throws: Error.self) { try MailStoreSource.SearchOptions(query: String(repeating: "x", count: 257), offset: 0) }
        #expect(throws: Error.self) { try MailStoreSource.SearchOptions(query: nil, offset: -1) }
    }

    private func runFixture(query: String?, offset: Int = 0, suffix: String = "") async throws -> MailSnapshot {
        try await runFixture(options: MailStoreSource.SearchOptions(query: query, offset: offset), suffix: suffix)
    }

    private func runFixture(options: MailStoreSource.SearchOptions, suffix: String = "") async throws -> MailSnapshot {
        let argument = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        let output = try await BoundedProcessRunner.run(
            executable: "/usr/bin/osascript", arguments: ["-l", "JavaScript", "-e",
                MailStoreSource.script + Self.fixture + suffix + "\nfunction run(argv) { return readMail(fixtureMail(), JSON.parse(argv[0])); }", "--", argument], timeout: 10
        )
        return try MailStoreSource.decode(output)
    }

    static let fixture = #"""
    function message(id, index, subject, body, unread) {
        return {id: function() { return id; }, sender: function() { return 'Maya <maya@example.test>'; },
            subject: function() { return subject; }, dateReceived: function() { return new Date(1791140400000 - index * 60000); },
            readStatus: function() { return !unread; }, content: function() { return body; }};
    }
    function matches(item, condition) {
        if (condition._and) return condition._and.every(function(c) { return matches(item, c); });
        if (condition._or) return condition._or.some(function(c) { return matches(item, c); });
        return Object.keys(condition).every(function(key) {
            var value = item[key](), expected = condition[key];
            if (typeof expected !== 'object') return value === expected;
            if (expected._contains !== undefined) return String(value).toLowerCase().indexOf(String(expected._contains).toLowerCase()) >= 0;
            if (expected['>='] !== undefined) return value >= expected['>='];
            if (expected['<'] !== undefined) return value < expected['<'];
            return false;
        });
    }
    function box(name, items, children) {
        var messages = function() { return items; };
        messages.whose = function(condition) { return function() { return items.filter(function(item) { return matches(item, condition); }); }; };
        return {name: function() { return name; }, messages: messages, mailboxes: function() { return children || []; }};
    }
    var fixtureInbox = [], fixtureArchive = [];
    for (var i = 0; i < 120; i++) fixtureInbox.push(message('inbox-' + i, i, 'Ordinary news', 'Inbox body ' + 'x'.repeat(3000), i === 119));
    for (var j = 0; j < 220; j++) fixtureArchive.push(message('archive-' + j, j + 1000, 'Stored message',
        j === 219 ? 'x'.repeat(3500) + ' project decision: ship Friday' : 'Archived unrelated notes', false));
    var fixtureInboxBox = box('Inbox', fixtureInbox), fixtureArchiveBox = box('Archive', fixtureArchive);
    function fixtureMail() {
        return {accounts: function() { return [{name: function() { return 'Local account'; }, mailboxes: function() {
            return [fixtureInboxBox, fixtureArchiveBox]; }}]; }, inbox: fixtureInboxBox,
            mailboxes: function() { return [box('On My Mac', [])]; },
            delete: function() { throw new Error('A write was attempted'); }};
    }
    """#
}
