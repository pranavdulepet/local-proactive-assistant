import AssistantCore
import Foundation
import ProcessSupport

/// Read-only Apple Events. Search text is a JSON argument, never executable script input.
public struct MailStoreSource: MailSource {
    public init() {}

    public func inboxSnapshot() async throws -> MailSnapshot {
        try await searchSnapshot(query: nil, offset: 0)
    }

    public func searchSnapshot(query: String?, offset: Int) async throws -> MailSnapshot {
        try await searchSnapshot(query: query, offset: offset, limit: 100)
    }

    public func searchSnapshot(query: String?, offset: Int, limit: Int) async throws -> MailSnapshot {
        try await request(options: SearchOptions(query: query, offset: offset, limit: limit))
    }

    /// Verify access without fetching message bodies or suggesting that every mailbox was indexed.
    public func checkAccess() async throws {
        var options = try SearchOptions(query: nil, offset: 0)
        options.probe = true
        _ = try await request(options: options)
    }

    private func request(options: SearchOptions) async throws -> MailSnapshot {
        do {
            let argument = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
            let output = try await BoundedProcessRunner.run(
                executable: "/usr/bin/osascript",
                arguments: ["-l", "JavaScript", "-e", Self.script, "--", argument], timeout: 18
            )
            return try Self.decode(output)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as MailSourceFailure {
            throw failure
        } catch let failure as ProcessFailure {
            throw Self.processFailure(failure.description)
        } catch {
            throw Self.failure(code: .invalidResponse)
        }
    }

    static func decode(_ data: Data) throws -> MailSnapshot {
        guard data.count <= 2_097_152 else { throw failure(code: .invalidResponse) }
        struct FailureEnvelope: Decodable {
            struct Detail: Decodable { let code: String; let number: Int?; let stage: MailReadStage? }
            let error: Detail
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let envelope = try? decoder.decode(FailureEnvelope.self, from: data) {
            throw failure(code: MailSourceFailure.Code(rawValue: envelope.error.code) ?? .unavailable,
                          number: envelope.error.number, stage: envelope.error.stage)
        }
        let snapshot: MailSnapshot
        do { snapshot = try decoder.decode(MailSnapshot.self, from: data) }
        catch { throw failure(code: .invalidResponse) }
        guard snapshot.messages.count <= 100,
              snapshot.scanned >= snapshot.messages.count, snapshot.scanned <= 100,
              snapshot.skipped == snapshot.scanned - snapshot.messages.count,
              snapshot.totalInbox >= 0, snapshot.matched >= snapshot.scanned,
              snapshot.matched <= 5_000, snapshot.offset >= 0, snapshot.offset <= 100_000,
              snapshot.searchedMailboxes >= 0, snapshot.searchedMailboxes <= 256,
              snapshot.unavailableMailboxes >= 0, snapshot.unavailableMailboxes <= 256,
              snapshot.readIssues.count <= 10, snapshot.readIssues.allSatisfy({ (1...5_000).contains($0.count) }),
              snapshot.nextOffset.map({ $0 > snapshot.offset && $0 <= snapshot.matched }) ?? true,
              Set(snapshot.messages.map(\.externalID)).count == snapshot.messages.count,
              snapshot.messages.allSatisfy({
                  !$0.externalID.isEmpty && $0.externalID.utf8.count <= 128 &&
                  $0.sender.utf8.count <= 1_024 && $0.subject.utf8.count <= 1_024 &&
                  $0.body.utf8.count <= 8_192 && ($0.mailbox?.utf8.count ?? 0) <= 1_024
              }) else { throw failure(code: .invalidResponse) }
        return snapshot
    }

    /// Keep only a numeric Apple Events code; stderr can contain private Mail content.
    static func processFailure(_ detail: String) -> MailSourceFailure {
        if detail.hasPrefix("Helper request exceeded its ") && detail.contains("s deadline") {
            return failure(code: .timedOut, stage: .scriptExecution)
        }
        let expression = try? NSRegularExpression(pattern: #"\((-\d{3,5})\)"#)
        let range = NSRange(detail.startIndex..<detail.endIndex, in: detail)
        let match = expression?.matches(in: detail, range: range).last
        let number = match.flatMap { Range($0.range(at: 1), in: detail) }.flatMap { Int(detail[$0]) }
        return failure(code: code(for: number), number: number, stage: .scriptExecution)
    }

    private static func code(for number: Int?) -> MailSourceFailure.Code {
        switch number {
        case -1743, -10004, -10005: .permissionDenied
        case -1712: .timedOut
        case -600: .mailNotRunning
        case -1700, -1708, -1723, -1728: .unsupportedSearch
        case -2700: .scriptFailure
        default: .unavailable
        }
    }

    private static func failure(code: MailSourceFailure.Code, number: Int? = nil, stage: MailReadStage? = nil) -> MailSourceFailure {
        let detail: String
        switch code {
        case .permissionDenied:
            detail = "Mail access was denied. Enable your terminal in System Settings > Privacy & Security > Automation > Mail, then retry."
        case .mailboxUnavailable:
            detail = "The requested Mail folder is not exposed under that name. Check its name in Mail, or search by sender, date, or topic instead."
        case .noAccounts:
            detail = "Mail has no configured account or local mailbox. Open Apple Mail and add or enable an account before connecting it."
        case .mailNotRunning:
            detail = "Apple Mail is closed. Open it and retry the connection."
        case .timedOut:
            detail = "Apple Mail reached the timeout for this request. Open Mail, let it finish loading, and retry a narrower search."
        case .unsupportedSearch:
            detail = "Apple Mail rejected the requested read or search operation. Open Mail and retry."
        case .invalidResponse:
            detail = "Apple Mail returned an invalid or oversized response. Retry a narrower search."
        case .scriptFailure:
            detail = "Mail returned an unknown scripting error. The read stage identifies the failing operation."
        case .unavailable:
            detail = "Apple Mail could not complete the requested read. Open Mail and retry."
        }
        let location = stage.map { " Read stage: \($0.label)." } ?? ""
        let suffix = number.map { " Apple Events code: \($0)." } ?? ""
        return MailSourceFailure(code, detail + location + suffix, appleEventCode: number, stage: stage)
    }

    struct SearchOptions: Codable, Equatable {
        let scope: MailSearchScope
        let terms: [String]
        let unreadOnly: Bool
        let subjectOnly: Bool
        let mailboxName: String?
        let after: String?
        let before: String?
        let offset: Int
        let limit: Int
        var probe = false

        init(query: String?, offset: Int, limit: Int = 100) throws {
            guard offset >= 0, offset <= 100_000, (1...100).contains(limit),
                  (query?.utf8.count ?? 0) <= 256, query?.contains("\0") != true else {
                throw MailSourceFailure(.invalidResponse, "Mail search text or page offset is invalid.")
            }
            self.offset = offset
            self.limit = limit
            let text = query ?? ""
            let normalized = text.lowercased()
            let onlySubject = normalized.contains("subject:")
            subjectOnly = onlySubject
            if normalized.contains("archive") { mailboxName = "archive" }
            else if normalized.hasPrefix("sent") || normalized.contains("sent folder") || normalized.contains("sent mail") || normalized.contains("sent emails") || normalized.contains("my sent") {
                mailboxName = "sent"
            } else { mailboxName = nil }
            let stop: Set<String> = ["mail", "mails", "email", "emails", "inbox", "archive", "archived", "sent", "folder", "mailbox", "subject", "find", "search", "check", "show",
                "read", "unread", "recent", "latest", "all", "from", "about", "for", "with", "my", "me", "the",
                "a", "an", "on", "in", "at", "of", "to", "and", "that", "is", "are", "was", "were", "can",
                "you", "look", "get", "has", "have", "had", "just", "tell", "which", "any", "anything", "please",
                "what", "whats", "do", "did", "i", "need", "respond", "response", "reply", "replies", "today", "yesterday", "tomorrow"]
            let dayFormatter = DateFormatter()
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            dayFormatter.calendar = Calendar(identifier: .gregorian)
            dayFormatter.timeZone = .autoupdatingCurrent
            dayFormatter.dateFormat = "yyyy-MM-dd"
            dayFormatter.isLenient = false
            let datedTokens = text.split(whereSeparator: { $0.isWhitespace }).compactMap { token -> (String, Date)? in
                guard token.count == 10 else { return nil }
                let value = String(token)
                guard let date = dayFormatter.date(from: value), dayFormatter.string(from: date) == value else { return nil }
                return (value, date)
            }
            let dates = datedTokens.map { $0.1 }.sorted()
            let dateTerms = Set(datedTokens.map { $0.0 })
            let formatter = ISO8601DateFormatter()
            after = dates.first.map { formatter.string(from: $0) }
            before = dates.last.flatMap { Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: $0) }.map { formatter.string(from: $0) }
            let tokens = normalized.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@._-")).inverted)
            unreadOnly = tokens.contains("unread")
            var seen = Set<String>()
            terms = tokens.filter { token in
                token.count >= 2 && !stop.contains(token) && (onlySubject || !["important", "urgent", "priority", "priorities"].contains(token)) && !dateTerms.contains(token) && seen.insert(token).inserted
            }.prefix(6).map { $0 }
            let searchesAccounts = !terms.isEmpty || !dates.isEmpty || mailboxName != nil
            scope = searchesAccounts ? .allMailboxes : .inbox
        }
    }

    static let script = #"""
    function mailError(number) {
        if (number === -1743 || number === -10004 || number === -10005) return 'permissionDenied';
        if (number === -1712) return 'timedOut';
        if (number === -600) return 'mailNotRunning';
        if (number === -1700 || number === -1708 || number === -1723 || number === -1728) return 'unsupportedSearch';
        if (number === -2700) return 'scriptFailure';
        return 'unavailable';
    }
    function errorNumber(error) {
        var value = Number(error && (error.errorNumber || error.number));
        if (value && isFinite(value)) return value;
        var match = String(error && error.message || '').match(/\((-\d{3,5})\)/);
        return match ? Number(match[1]) : null;
    }
    function plainMailValue(value) {
        if (value === null || value === undefined || value instanceof Date) return value;
        if (typeof ObjC !== 'undefined') {
            try { return ObjC.unwrap(value); } catch (_) {}
        }
        return value;
    }
    function mailDateMilliseconds(value) {
        value = plainMailValue(value);
        if (value instanceof Date) return isFinite(value.getTime()) ? value.getTime() : null;
        if (typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(value)) {
            var parsed = Date.parse(value);
            return isFinite(parsed) ? parsed : null;
        }
        // NSDate from the Objective-C bridge is not automatically a JavaScript Date.
        if (value && typeof ObjC !== 'undefined') {
            try {
                if (value.isKindOfClass($.NSDate)) {
                    var seconds = Number(value.timeIntervalSince1970);
                    return isFinite(seconds) && Math.abs(seconds * 1000) <= 8640000000000000 ? seconds * 1000 : null;
                }
            } catch (_) {}
        }
        return null;
    }
    function readMail(mail, options) {
        function bounded(value, count) {
            var result = String(plainMailValue(value) || '').slice(0, count);
            if (/^[\uDC00-\uDFFF]/.test(result)) result = result.slice(1);
            if (/[\uD800-\uDBFF]$/.test(result)) result = result.slice(0, -1);
            return result;
        }
        function arrayValues(value) {
            var result = [];
            function append(item) {
                item = plainMailValue(item);
                if (Array.isArray(item)) item.forEach(append);
                else result.push(item);
            }
            append(value);
            return result;
        }
        var started = Date.now(), stage = 'accountAccess', lastStage = null, lastNumber = null;
        var complete = true, unavailable = 0, searched = 0, matched = [], seen = {}, visited = {}, visitedCount = 0;
        var totalInbox = 0, issues = {};
        function expired() { return Date.now() - started >= 12000; }
        function note(readStage, number) {
            complete = false;
            lastStage = readStage; lastNumber = number;
            var key = readStage + ':' + number;
            if (!issues[key]) issues[key] = {stage: readStage, appleEventCode: number, count: 0};
            issues[key].count = Math.min(5000, issues[key].count + 1);
        }
        function deny(error) { if (mailError(errorNumber(error)) === 'permissionDenied') throw error; }
        function column(collection, key, readStage, count) {
            stage = readStage;
            try {
                var values = arrayValues(collection[key]({timeout: 6}));
                if (count !== undefined && values.length !== count) throw new Error('Invalid Mail metadata column');
                return values;
            } catch (error) {
                deny(error);
                if (key === 'id') throw error;
                note(readStage, errorNumber(error));
                var missing = [];
                for (var n = 0; n < count; n++) missing.push(null);
                return missing;
            }
        }
        function collect(box, label) {
            var folder = label.split('/').pop().toLowerCase().replace(/\s+/g, '');
            if (options.mailboxName === 'archive' && folder.indexOf('archive') < 0 && folder !== 'allmail') return;
            if (options.mailboxName === 'sent' && folder.indexOf('sent') < 0) return;
            if (expired() || searched >= 256 || matched.length >= 5000) { complete = false; return; }
            try {
                stage = 'mailboxAccess';
                if (options.probe) { box.name({timeout: 6}); searched++; return; }
                var conditions = [];
                if (options.unreadOnly) conditions.push({readStatus: false});
                if (options.after) conditions.push({dateReceived: {'>=': new Date(options.after)}});
                if (options.before) conditions.push({dateReceived: {'<': new Date(options.before)}});
                options.terms.forEach(function(term) {
                    conditions.push(options.subjectOnly ? {subject: {_contains: term}} : {_or: [{sender: {_contains: term}}, {subject: {_contains: term}}, {content: {_contains: term}}]});
                });
                stage = 'messageSearch';
                var predicate = conditions.length === 1 ? conditions[0] : {_and: conditions};
            var collection = conditions.length ? box.messages.whose(predicate, {ignoring: 'case'}) : box.messages;
                // Keep the object specifier. Calling messages() first needlessly resolves every message reference.
                var ids = column(collection, 'id', conditions.length ? 'messageSearch' : 'messageIdentifiers');
                var dates = column(collection, 'dateReceived', 'messageDates', ids.length);
                var senders = column(collection, 'sender', 'messageHeaders', ids.length);
                var subjects = column(collection, 'subject', 'messageHeaders', ids.length);
                var read = column(collection, 'readStatus', 'messageReadStatus', ids.length);
                searched++;
                if (options.scope === 'inbox') totalInbox = ids.length;
                for (var i = 0; i < ids.length; i++) {
                    if (expired() || matched.length >= 5000) { complete = false; break; }
                    var nativeID = plainMailValue(ids[i]), id = String(nativeID);
                    if ((typeof nativeID !== 'string' && typeof nativeID !== 'number') || !id || id.length > 128 || (typeof nativeID === 'number' && !isFinite(nativeID))) {
                        note('messageIdentifiers', null); continue;
                    }
                    if (seen[id]) continue;
                    if (typeof read[i] !== 'boolean') { note('messageReadStatus', null); continue; }
                    seen[id] = true;
                    var time = mailDateMilliseconds(dates[i]);
                    if (time === null) note('messageDates', null);
                    matched.push({id: id, nativeID: nativeID, box: box, time: time,
                        sender: bounded(senders[i], 256), subject: bounded(subjects[i], 256),
                        unread: !read[i], mailbox: bounded(label, 256)});
                }
            } catch (error) {
                deny(error); unavailable++;
                note(stage, errorNumber(error));
            }
        }
        function walk(container, owner, prefix, depth) {
            if (expired() || visitedCount >= 256 || depth > 8 || matched.length >= 5000) { complete = false; return; }
            var boxes;
            stage = 'mailboxAccess';
            try { boxes = container.mailboxes({timeout: 6}); }
            catch (error) { deny(error); unavailable++; note(stage, errorNumber(error)); return; }
            for (var i = 0; i < boxes.length; i++) {
                if (expired() || visitedCount >= 256 || matched.length >= 5000) { complete = false; break; }
                var box = boxes[i], name;
                stage = 'mailboxAccess';
                try { name = String(box.name({timeout: 6})); }
                catch (error) { deny(error); unavailable++; note(stage, errorNumber(error)); continue; }
                var path = prefix + '/' + name, key = owner + ':' + path;
                if (visited[key]) continue;
                visited[key] = true; visitedCount++;
                collect(box, owner + path);
                walk(box, owner, path, depth + 1);
            }
        }
        try {
            stage = 'accountAccess';
            var accounts = mail.accounts({timeout: 6});
            if (options.probe && !accounts.length) {
                var waiting = Date.now();
                while (!accounts.length && Date.now() - waiting < 3000 && !expired()) {
                    delay(0.2); accounts = mail.accounts({timeout: 6});
                }
            }
            if (!accounts.length) {
                stage = 'mailboxAccess';
                var local = mail.mailboxes({timeout: 6});
                if (!local.length) return JSON.stringify({error: {code: 'noAccounts', number: null, stage: stage}});
                if (options.probe) collect(local[0], 'Local Mail');
                else options.scope = 'allMailboxes';
            }
            if (!(options.probe && searched)) {
                if (options.scope === 'inbox' || options.probe) collect(mail.inbox, 'Inbox');
                else {
                    for (var a = 0; a < accounts.length; a++) {
                        if (expired()) { complete = false; break; }
                        var account = accounts[a], owner = 'Account ' + (a + 1);
                        try { owner = bounded(account.name({timeout: 6}), 128); } catch (_) {}
                        walk(account, owner, '', 0);
                    }
                    walk(mail, 'Local Mail', '', 0);
                    totalInbox = matched.length;
                }
            }
            if (!searched && unavailable) return JSON.stringify({error: {code: mailError(lastNumber), number: lastNumber, stage: lastStage}});
            if (!searched && options.mailboxName) return JSON.stringify({error: {code: 'mailboxUnavailable', number: lastNumber, stage: 'mailboxAccess'}});
            matched.sort(function(a, b) {
                if (a.time === null && b.time !== null) return 1;
                if (b.time === null && a.time !== null) return -1;
                return (b.time || 0) - (a.time || 0) || a.id.localeCompare(b.id);
            });
            var records = [], scanned = 0, skipped = 0;
            var end = Math.min(matched.length, options.offset + (options.limit || 100));
            for (var n = options.offset; n < end; n++) {
                if (expired()) { complete = false; break; }
                scanned++;
                var item = matched[n], body = '', bodyAvailable = true;
                stage = 'messageBody';
                try {
                    var m = item.box.messages.byId(item.nativeID);
                    body = String(plainMailValue(m.content({timeout: 6})) || '');
                    var start = 0, lower = body.toLowerCase();
                    for (var t = 0; t < options.terms.length; t++) {
                        var location = lower.indexOf(options.terms[t]);
                        if (location >= 0) { start = Math.max(0, location - 300); break; }
                    }
                    body = bounded(body.slice(start), 2000);
                } catch (error) { deny(error); bodyAvailable = false; note(stage, errorNumber(error)); }
                records.push({externalID: item.id, sender: item.sender, subject: item.subject,
                    receivedAt: item.time === null ? null : new Date(item.time).toISOString().replace(/\.\d{3}Z$/, 'Z'),
                    unread: item.unread, body: body, mailbox: item.mailbox, bodyAvailable: bodyAvailable});
            }
            stage = 'serialization';
            var next = options.offset + scanned;
            return JSON.stringify({messages: records, totalInbox: totalInbox, scanned: scanned, skipped: skipped,
                scope: options.scope, matched: matched.length, searchedMailboxes: searched, unavailableMailboxes: Math.min(unavailable, 256),
                searchComplete: complete, offset: options.offset, nextOffset: scanned > 0 && next < matched.length ? next : null,
                readIssues: Object.keys(issues).slice(0, 10).map(function(key) { return issues[key]; })});
        } catch (error) {
            var number = errorNumber(error);
            return JSON.stringify({error: {code: mailError(number), number: number, stage: stage}});
        }
    }
    function readMailInbox(mail) {
        return readMail(mail, {scope: 'inbox', terms: [], unreadOnly: false, offset: 0, limit: 100});
    }
    function run(argv) {
        var mail = Application('com.apple.mail'), options = JSON.parse(argv[0]);
        if (!mail.running()) {
            if (!options.probe) return JSON.stringify({error: {code: 'mailNotRunning', number: -600, stage: 'accountAccess'}});
            mail.launch();
            var started = Date.now();
            while (!mail.running()) {
                if (Date.now() - started >= 12000) return JSON.stringify({error: {code: 'timedOut', number: null, stage: 'accountAccess'}});
                delay(0.2);
            }
        }
        return readMail(mail, options);
    }
    """#
}
