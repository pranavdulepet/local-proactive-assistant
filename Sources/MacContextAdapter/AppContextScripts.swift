import CryptoKit
import Foundation
import LocalInference

struct AppContextSnapshot: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let id: String
        let title: String
        let body: String
        let detail: String
        let timestamp: Date?
    }
    let items: [Item]
    let total: Int
    let scanned: Int
    let skipped: Int

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 262_144 else { throw MacContextFailure("The application read exceeded its output limit.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Self.self, from: data)
        guard snapshot.total >= snapshot.scanned, (0...200).contains(snapshot.scanned),
              (0...snapshot.scanned).contains(snapshot.skipped), snapshot.items.count <= 8,
              snapshot.items.count <= snapshot.scanned - snapshot.skipped,
              Set(snapshot.items.map(\.id)).count == snapshot.items.count,
              snapshot.items.allSatisfy({
                  !$0.id.isEmpty && $0.id.utf8.count <= 220 && $0.title.utf8.count <= 1_024 &&
                  $0.body.utf8.count <= 16_384 && $0.detail.utf8.count <= 2_048
              }) else { throw MacContextFailure("The application returned an invalid bounded read.") }
        return snapshot
    }

    func result(source: String) -> ContextToolResult {
        let records = items.map { item in
            let digest = SHA256.hash(data: Data((source + ":" + item.id).utf8))
                .map { String(format: "%02x", $0) }.joined()
            return EvidenceRecord(id: source + ":" + digest, source: source,
                timestamp: item.timestamp,
                text: EvidenceText.bounded("Title: \(EvidenceText.bounded(item.title, bytes: 180))\n\(EvidenceText.bounded(item.detail, bytes: 180))\n\(item.body)", bytes: 768),
                locator: source + ":" + item.id, trust: "unknownExternal")
        }
        let scope = source == "notes"
            ? "Titles and text from the first 32 KiB of each sampled note body are searched. Locked notes, handwriting and attachments are not read."
            : "Sampled reminder titles, notes, completion state and due dates are read. The result is not a complete account export."
        return ContextToolResult(records: records, coverage: [EvidenceText.bounded(
            "\(source): \(items.count) matching excerpts from \(scanned) scanned of \(total) app-supplied items; \(skipped) could not be read. At most 200 items are scanned and 8 excerpts returned. App order and sync determine coverage. \(scope)", bytes: 512)])
    }
}

enum AppContextScripts {
    // Pure readNotes/readReminders functions allow fixtures without launching an app.
    // Query text is passed in argv as data, and is never concatenated into this script.
    static let notes = #"""
    function bounded(value, count) { return Array.from(String(value || '')).slice(0, count).join(''); }
    function dateString(value) {
        try { return value.toISOString().replace(/\.\d{3}Z$/, 'Z'); } catch (_) { return null; }
    }
    function plainNote(value) {
        return String(value || '').slice(0, 32768)
            .replace(/<br\s*\/?\s*>/gi, '\n').replace(/<\/(div|p|h[1-6]|li)>/gi, '\n')
            .replace(/<[^>]*>/g, '').replace(/&nbsp;/g, ' ').replace(/&lt;/g, '<')
            .replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&');
    }
    function queryTerms(query) {
        return String(query || '').toLowerCase().split(/\s+/).filter(function(x) { return x.length > 0; }).slice(0, 6);
    }
    function matchingText(text, terms) {
        var lower = text.toLowerCase(), first = -1;
        terms.forEach(function(term) { var index = lower.indexOf(term); if (index >= 0 && (first < 0 || index < first)) first = index; });
        return text.slice(Math.max(0, first - 80));
    }
    function readNotes(notesApp, query) {
        var notes = notesApp.notes();
        var maximum = Math.min(notes.length, 200), scanned = 0, items = [], skipped = 0;
        var terms = queryTerms(query);
        var deadline = Date.now() + 10000;
        for (var i = 0; i < maximum; i++) {
            if (Date.now() > deadline || (terms.length === 0 && items.length === 8)) break;
            scanned++;
            try {
                var note = notes[i];
                var title = bounded(note.name(), 256);
                var text = plainNote(note.body());
                var searchable = (title + '\n' + text).toLowerCase();
                if (terms.every(function(term) { return searchable.indexOf(term) >= 0; }) && items.length < 8) {
                    var changed = null;
                    try { changed = dateString(note.modificationDate()); } catch (_) {}
                    items.push({id: String(note.id()), title: title, body: bounded(matchingText(text, terms), 4096),
                                detail: 'Apple Notes text excerpt', timestamp: changed});
                }
            } catch (_) { skipped++; }
        }
        return {items: items, total: notes.length, scanned: scanned, skipped: skipped};
    }
    function run(argv) { return JSON.stringify(readNotes(Application('Notes'), argv[0] || '')); }
    """#

    static let reminders = #"""
    function bounded(value, count) { return Array.from(String(value || '')).slice(0, count).join(''); }
    function dateString(value) {
        try { return value.toISOString().replace(/\.\d{3}Z$/, 'Z'); } catch (_) { return null; }
    }
    function readReminders(remindersApp, query) {
        var reminders = remindersApp.reminders();
        var maximum = Math.min(reminders.length, 200), scanned = 0, matches = [], skipped = 0;
        var terms = String(query || '').toLowerCase().split(/\s+/).filter(function(x) { return x.length > 0; }).slice(0, 6);
        var includeCompleted = terms.some(function(term) { return /^(complete|completed|done)$/.test(term); });
        var dueFilter = terms.indexOf('today') >= 0 ? 'today' : terms.indexOf('tomorrow') >= 0 ? 'tomorrow' : terms.indexOf('overdue') >= 0 ? 'overdue' : null;
        var contentTerms = terms.filter(function(term) { return !/^(reminder|reminders|task|tasks|due|today|tomorrow|overdue|complete|completed|done|incomplete|open|unfinished)$/.test(term); });
        var now = new Date(), today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        var tomorrow = new Date(today.getFullYear(), today.getMonth(), today.getDate() + 1);
        var nextDay = new Date(today.getFullYear(), today.getMonth(), today.getDate() + 2);
        var deadline = Date.now() + 10000;
        for (var i = 0; i < maximum; i++) {
            if (Date.now() > deadline) break;
            scanned++;
            try {
                var reminder = reminders[i], completed = reminder.completed();
                if (!includeCompleted && completed) continue;
                var title = bounded(reminder.name(), 256), body = bounded(reminder.body(), 4096);
                var searchable = (title + '\n' + body).toLowerCase();
                if (!contentTerms.every(function(term) { return searchable.indexOf(term) >= 0; })) continue;
                var due = null;
                try { due = reminder.dueDate(); } catch (_) {}
                var dueISO = dateString(due);
                if (dueFilter && !dueISO) continue;
                if (dueFilter === 'today' && !(due >= today && due < tomorrow)) continue;
                if (dueFilter === 'tomorrow' && !(due >= tomorrow && due < nextDay)) continue;
                if (dueFilter === 'overdue' && !(due < now)) continue;
                var changed = null;
                try { changed = dateString(reminder.modificationDate()); } catch (_) {}
                matches.push({id: String(reminder.id()), title: title, body: body,
                    detail: 'Completed: ' + (completed ? 'yes' : 'no') + '\nDue: ' + (dueISO || 'none'),
                    timestamp: changed, due: dueISO});
            } catch (_) { skipped++; }
        }
        matches.sort(function(a, b) { return String(a.due || '9999').localeCompare(String(b.due || '9999')); });
        var items = matches.slice(0, 8).map(function(item) {
            return {id: item.id, title: item.title, body: item.body, detail: item.detail, timestamp: item.timestamp};
        });
        return {items: items, total: reminders.length, scanned: scanned, skipped: skipped};
    }
    function run(argv) { return JSON.stringify(readReminders(Application('Reminders'), argv[0] || '')); }
    """#
}
