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
    let candidateCount: Int?
    let filterApplied: Bool?
    let filterFallback: Bool?
    let accounts: Int?
    let truncated: Bool?

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 262_144 else { throw MacContextFailure("The application read exceeded its output limit.", kind: .invalidResponse) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct FailureEnvelope: Decodable { struct Failure: Decodable { let code: Int? }; let failure: Failure }
        if let envelope = try? decoder.decode(FailureEnvelope.self, from: data) {
            throw MacContextFailure.helperFailure(code: envelope.failure.code)
        }
        let snapshot: Self
        do { snapshot = try decoder.decode(Self.self, from: data) }
        catch { throw MacContextFailure("The fixed application script returned an invalid response.", kind: .invalidResponse) }
        guard snapshot.total >= snapshot.scanned, (0...200).contains(snapshot.scanned),
              (0...snapshot.scanned).contains(snapshot.skipped), snapshot.items.count <= 8,
              snapshot.candidateCount.map({ $0 >= snapshot.scanned && $0 <= snapshot.total }) ?? true,
              snapshot.items.count <= snapshot.scanned - snapshot.skipped,
              Set(snapshot.items.map(\.id)).count == snapshot.items.count,
              snapshot.items.allSatisfy({
                  !$0.id.isEmpty && $0.id.utf8.count <= 220 && $0.title.utf8.count <= 1_024 &&
                  $0.body.utf8.count <= 16_384 && $0.detail.utf8.count <= 2_048
              }) else { throw MacContextFailure("The application returned an invalid bounded read.", kind: .invalidResponse) }
        if snapshot.scanned > 0 && snapshot.skipped == snapshot.scanned {
            throw MacContextFailure("The application exposed items, but none of the sampled items could be read. Its scripting API or locked items may be the cause; permission denial was not reported.", kind: .readFailed)
        }
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
        if total == 0 {
            let detail = accounts == 0
                ? "The application exposes no Notes accounts or items for this Mac login. Add or sync an account in Notes."
                : "The application exposes no local Notes items for this Mac login. This does not prove that remote accounts or unsynced devices are empty."
            return ContextToolResult(records: [], coverage: ["Notes read succeeded. " + detail])
        }
        let filter = filterApplied == true ? "The app filtered candidates by literal title/body text before sampling."
            : filterFallback == true ? "The app rejected native filtering; a limited app-order sample was searched instead."
            : "This is an app-order preview, not a search of every note."
        let scope = "Up to 200 candidate notes and the first 32 KiB of each body are inspected; 8 excerpts returned. Locked notes, attachments, handwriting, later body text and unsynced items are outside coverage."
        return ContextToolResult(records: records, coverage: [EvidenceText.bounded(
            "Notes: \(items.count) excerpts; \(scanned) of \(candidateCount ?? total) candidates inspected from \(total) app-exposed notes; \(skipped) unreadable\(truncated == true ? "; read deadline/sample limit reached" : ""). \(filter) \(scope)", bytes: 512)])
    }
}

enum AppContextScripts {
    // The pure readNotes function allows fixtures without launching an app.
    // Query text is passed in argv as data, and is never concatenated into this script.
    static let notes = #"""
    function bounded(value, count) { return Array.from(String(value || '')).slice(0, count).join(''); }
    function dateString(value) {
        try { return value.toISOString().replace(/\.\d{3}Z$/, 'Z'); } catch (_) { return null; }
    }
    function bytePrefix(value, limit) {
        var output = [], count = 0;
        for (var character of String(value || '')) {
            var scalar = character.codePointAt(0);
            var bytes = scalar <= 0x7f ? 1 : scalar <= 0x7ff ? 2 : scalar <= 0xffff ? 3 : 4;
            if (count + bytes > limit) break;
            output.push(character); count += bytes;
        }
        return output.join('');
    }
    function plainNote(value) {
        return bytePrefix(value, 32768)
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
    function errorCode(error) {
        var number = error.errorNumber !== undefined ? error.errorNumber : error.number;
        if (number !== undefined && isFinite(Number(number))) return Number(number);
        var match = String(error).match(/(?:Error\s+|error number\s+|\()(-\d{3,5})(?:[:\s\)]|$)/);
        return match ? Number(match[1]) : null;
    }
    function readNotes(notesApp, query) {
        var all = notesApp.notes(), notes = all, accounts = null;
        try { accounts = notesApp.accounts().length; } catch (_) {}
        var terms = queryTerms(query), filterApplied = false, filterFallback = false;
        if (terms.length > 0) {
            try {
                // Fixed Apple Events predicate; query values remain literal data.
                var clauses = terms.map(function(term) {
                    return {_or: [{name: {_contains: term}}, {body: {_contains: term}}]};
                });
                notes = notesApp.notes.whose(clauses.length === 1 ? clauses[0] : {_and: clauses})();
                filterApplied = true;
            } catch (error) {
                var code = errorCode(error);
                if (code === -1743 || code === -1744 || code === -1712) throw error;
                filterFallback = true;
            }
        }
        var maximum = Math.min(notes.length, 200), scanned = 0, items = [], skipped = 0;
        var truncated = false;
        var deadline = Date.now() + 10000;
        for (var i = 0; i < maximum; i++) {
            if (Date.now() > deadline) { truncated = true; break; }
            if (terms.length === 0 && items.length === 8) break;
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
            } catch (error) {
                var code = errorCode(error);
                if (code === -1743 || code === -1744 || code === -1712) throw error;
                skipped++;
            }
        }
        if (notes.length > 200) truncated = true;
        return {items: items, total: all.length, scanned: scanned, skipped: skipped,
            candidateCount: notes.length, filterApplied: filterApplied, filterFallback: filterFallback,
            accounts: accounts, truncated: truncated};
    }
    function run(argv) {
        try { return JSON.stringify(readNotes(Application('Notes'), argv[0] || '')); }
        catch (error) { return JSON.stringify({failure: {code: errorCode(error)}}); }
    }
    """#

}
