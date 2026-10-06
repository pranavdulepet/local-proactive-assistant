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

    @Test func inboxReadUsesLazyBulkMetadataAfterSuccessfulProbe() async throws {
        var options = try MailStoreSource.SearchOptions(query: nil, offset: 0, limit: 8)
        options.probe = true
        #expect(try await runFixture(options: options).searchedMailboxes == 1)
        options.probe = false
        let snapshot = try await runFixture(options: options)
        #expect(snapshot.messages.count == 8)
        #expect(snapshot.messages[0].subject == "Ordinary news")
        #expect(snapshot.messages[0].body.hasPrefix("Inbox body"))
        #expect(snapshot.nextOffset == 8)
        #expect(snapshot.searchComplete)
    }

    @Test func missingReceivedDateDoesNotAbortAnOtherwiseReadableEmail() async throws {
        let snapshot = try await runFixture(query: "unread emails",
            suffix: "fixtureInbox[119].dateReceived = function() { return null; };")
        #expect(snapshot.messages.map(\.externalID) == ["inbox-119"])
        #expect(snapshot.messages[0].receivedAt == nil)
        #expect(snapshot.messages[0].body.hasPrefix("Inbox body"))
        #expect(snapshot.readIssues.contains { $0.stage == .messageDates })
        #expect(!snapshot.searchComplete)
    }

    @Test func realAppleEventDescriptorValuesDecodeDatesHeadersAndMissingValues() async throws {
        let suffix = #"""
        var scriptError = Ref();
        // Keep the script self-contained: current date is a Standard Additions command,
        // not required to test Foundation's native Apple Event descriptors.
        var reply = $.NSAppleScript.alloc.initWithSource('return {119, "Maya", "Project review", false, "Read the review before Friday", missing value}').executeAndReturnError(scriptError);
        if (!reply || reply.isNil()) {
            var info = scriptError[0];
            var code = info ? Number(ObjC.unwrap(info.objectForKey('NSAppleScriptErrorNumber'))) : 'unknown';
            throw new Error('Native descriptor fixture script failed: ' + code);
        }
        if (Number(reply.numberOfItems) !== 6) throw new Error('Native descriptor fixture expected six script values; received ' + Number(reply.numberOfItems));
        var nativeDate = $.NSDate.dateWithTimeIntervalSince1970(1791140400);
        reply.insertDescriptorAtIndex($.NSAppleEventDescriptor.descriptorWithDate(nativeDate), 7);
        if (Number(reply.numberOfItems) !== 7) throw new Error('Native descriptor fixture could not insert its date');
        var m = fixtureInbox[119];
        m.id = function() { return reply.descriptorAtIndex(1).int32Value; };
        m.sender = function() { return reply.descriptorAtIndex(2).stringValue; };
        m.subject = function() { return reply.descriptorAtIndex(3).stringValue; };
        m.dateReceived = function() { return reply.descriptorAtIndex(7).dateValue; };
        m.readStatus = function() { return reply.descriptorAtIndex(4).booleanValue; };
        m.content = function() { return reply.descriptorAtIndex(5).stringValue; };
        """#
        let snapshot = try await runFixture(query: "unread emails", suffix: suffix)
        #expect(snapshot.messages.map(\.externalID) == ["119"])
        #expect(snapshot.messages[0].receivedAt == Date(timeIntervalSince1970: 1_791_140_400))
        #expect(snapshot.messages[0].sender == "Maya")
        #expect(snapshot.messages[0].subject == "Project review")
        #expect(snapshot.messages[0].body == "Read the review before Friday")
        let missing = try await runFixture(query: "unread emails", suffix: suffix +
            "\nm.dateReceived = function() { return reply.descriptorAtIndex(6).dateValue; };")
        #expect(missing.messages[0].receivedAt == nil)
        #expect(missing.messages[0].body == "Read the review before Friday")
    }

    @Test func failedQueryReportsItsStageWithoutExposingMailContents() async throws {
        do {
            _ = try await runFixture(query: nil,
                suffix: "fixtureInboxBox.messages.id = function() { throw {number: -2700, message: 'private@example.test Secret subject'}; };")
            Issue.record("Expected the metadata read to fail")
        } catch let failure as MailSourceFailure {
            #expect(failure.code == .scriptFailure)
            #expect(failure.appleEventCode == -2700)
            #expect(failure.stage == .messageIdentifiers)
            #expect(failure.description.contains("message identifiers"))
            #expect(!failure.description.contains("private@example.test"))
            #expect(!failure.description.contains("Secret subject"))
        }
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
                                 ("timedOut", .timedOut), ("unsupportedSearch", .unsupportedSearch), ("scriptFailure", .scriptFailure)] {
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
        #expect(MailStoreSource.processFailure("JavaScript exception private deadline subject (-2700)").code == .scriptFailure)
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
    function collection(items) {
        // A Mail result is an object specifier, not an eager array of stable Message objects.
        var messages = function() { throw {number: -2700, message: 'Cannot eagerly resolve Mail references'}; };
        ['id', 'dateReceived', 'sender', 'subject', 'readStatus'].forEach(function(key) {
            messages[key] = function() { return items.map(function(item) { return item[key](); }); };
        });
        messages.whose = function(condition) { return collection(items.filter(function(item) { return matches(item, condition); })); };
        messages.byId = function(id) {
            var value = items.filter(function(item) { return String(plainMailValue(item.id())) === String(id); })[0];
            if (!value) throw {number: -1728, message: 'Missing message'};
            return value;
        };
        return messages;
    }
    function box(name, items, children) {
        return {name: function() { return name; }, messages: collection(items), mailboxes: function() { return children || []; }};
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
