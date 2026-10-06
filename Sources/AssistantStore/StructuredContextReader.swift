import AssistantCore
import Foundation
import LocalInference

/// The planner selects a source and supplies literal fields. The host does not
/// reclassify natural language into a different source, person or date window.
struct StructuredContextReader: Sendable {
    let store: ObservationStore
    var calendar: Calendar = .autoupdatingCurrent

    func execute(_ call: ContextToolCall) async throws -> ContextToolResult {
        try call.validate()
        switch call.tool {
        case .messages: return try await messages(call)
        case .calendar: return try await events(call)
        case .contacts: return try await contacts(call)
        default: throw LocalModelFailure("This structured index reader does not provide that source.")
        }
    }

    private func messages(_ call: ContextToolCall) async throws -> ContextToolResult {
        var handles = Set<String>()
        var identity: String?
        var coverage: [String] = []
        if let person = call.person {
            if let handle = Self.literalHandle(person) {
                handles = Self.handleVariants(handle)
                identity = handle
                coverage.append("messages: Scoped to the explicitly requested handle \(EvidenceText.bounded(handle, bytes: 180)).")
            } else {
                let resolution = try await resolvePerson(person)
                guard resolution.complete, resolution.people.count == 1, let match = resolution.people.first else {
                    let reason = !resolution.complete
                        ? "The bounded identity search has more candidates; ask for a fuller name or exact phone/email handle."
                        : resolution.people.isEmpty ? "No indexed contact name or nickname matched all supplied name tokens."
                        : "Multiple contacts match this person; ask the owner which contact or phone/email handle they mean."
                    return ContextToolResult(records: Self.records(Array(resolution.people.prefix(8))), coverage: [
                        "messages: \(reason) No unscoped message search was performed.",
                        try await sourceCoverage(.contacts), try await sourceCoverage(.messages)
                    ])
                }
                handles = Set(match.handles.flatMap { Self.handleVariants($0) })
                identity = Self.displayName(match)
                guard !handles.isEmpty else {
                    return ContextToolResult(records: Self.records([match]), coverage: [
                        "messages: The selected contact has no indexed phone/email handles. No unscoped message search was performed.",
                        try await sourceCoverage(.contacts), try await sourceCoverage(.messages)
                    ])
                }
                coverage.append("messages: Resolved the literal name to \(EvidenceText.bounded(identity!, bytes: 160)) (\(EvidenceText.bounded(match.locator, bytes: 180))). All supplied name tokens matched a name or nickname.")
                coverage.append(try await sourceCoverage(.contacts))
            }
        }
        let start = try call.from.map(parseDate)
        let end = try call.to.map(parseDate)
        if let start, let end, start >= end { throw LocalModelFailure("Message dates require from before the exclusive to boundary.") }
        let direction = call.direction ?? "any"
        let limit = call.limit ?? 8
        let offset = call.offset ?? 0
        let observations = try await store.recallMessages(matchingAnyHandle: handles,
            direction: direction, topicQuery: Self.checkedFTS(call.query), from: start, to: end,
            limit: limit, offset: offset)
        let formatter = ISO8601DateFormatter()
        let range = "\(start.map(formatter.string(from:)) ?? "earliest indexed") through \(end.map(formatter.string(from:)) ?? "latest indexed") (to is exclusive)"
        coverage.append("messages: \(observations.count) \(direction) messages returned newest first, offset \(offset), limit \(limit), \(range). Person, direction, topic and date filters ran before the limit. Empty results mean no matching indexed rows, not no messages on the devices.\(observations.count == limit ? " More matches may be available at offset \(offset + observations.count)." : "")")
        coverage.append(try await sourceCoverage(.messages))
        let records = observations.enumerated().map { index, item in
            let direction: String
            switch item.trust {
            case .ownerAuthored: direction = "outbound (owner sent)"
            case .knownExternal, .unknownExternal: direction = "inbound (participant sent)"
            case .structuredSource: direction = "unavailable"
            }
            let participant = identity ?? item.handles.joined(separator: ", ")
            let metadata = "Direction: \(direction)\nParticipant: \(EvidenceText.bounded(participant, bytes: 160))\nSent: \(item.sourceTimestamp.map(formatter.string(from:)) ?? "unknown")\nMessage: "
            return EvidenceRecord(id: "e\(index + 1)", source: "messages", timestamp: item.sourceTimestamp,
                text: EvidenceText.bounded(metadata + item.text, bytes: 768), locator: EvidenceText.bounded(item.locator, bytes: 256), trust: item.trust.rawValue)
        }
        return ContextToolResult(records: records, coverage: coverage.map { EvidenceText.bounded($0, bytes: 512) })
    }

    private func events(_ call: ContextToolCall) async throws -> ContextToolResult {
        guard let from = call.from, let to = call.to else { throw LocalModelFailure("Calendar reads require explicit from/to dates.") }
        let start = try parseDate(from), end = try parseDate(to)
        guard start < end else { throw LocalModelFailure("Calendar dates require from before the exclusive to boundary.") }
        let limit = call.limit ?? 8, offset = call.offset ?? 0
        var handles = Set<String>()
        var identityCoverage: [String] = []
        if let person = call.person {
            if let handle = Self.literalHandle(person) {
                handles = Self.handleVariants(handle)
            } else {
                let resolution = try await resolvePerson(person)
                guard resolution.complete, resolution.people.count == 1, let match = resolution.people.first, !match.handles.isEmpty else {
                    return ContextToolResult(records: Self.records(Array(resolution.people.prefix(8))), coverage: [
                        "calendar: The participant name did not resolve to one contact with phone/email handles. Ask for an exact contact or handle; no unscoped Calendar search was performed.",
                        try await sourceCoverage(.contacts), try await sourceCoverage(.calendar)
                    ])
                }
                handles = Set(match.handles.flatMap { Self.handleVariants($0) })
                identityCoverage.append(try await sourceCoverage(.contacts))
            }
            identityCoverage.append("calendar: Participant filter matches the resolved phone/email handles in indexed organizer/attendee metadata, not a guessed name in event text.")
        }
        let events = try await store.calendarObservations(from: start, to: end,
            matchingAnyHandle: handles, topicQuery: Self.checkedFTS(call.query), limit: limit, offset: offset)
        let formatter = ISO8601DateFormatter()
        let scope = "calendar: \(events.count) indexed events overlapping [\(formatter.string(from: start)), \(formatter.string(from: end))) in \(calendar.timeZone.identifier); offset \(offset), limit \(limit). Includes overnight/all-day overlaps with stored end dates; canceled events are excluded. Missing legacy end dates are treated as start-only events.\(events.count == limit ? " More matches may be available at offset \(offset + events.count)." : "")"
        let records = events.enumerated().map { index, item in
            // Preserve interval facts even when a long external event title consumes
            // most of the excerpt budget. Missing ends must remain explicitly unknown.
            let interval = "Start: \(item.sourceTimestamp.map(formatter.string(from:)) ?? "unknown")\nEnd: \(item.sourceEndTimestamp.map(formatter.string(from:)) ?? "unknown")\nEvent: "
            return EvidenceRecord(id: "e\(index + 1)", source: "calendar", timestamp: item.sourceTimestamp,
                text: EvidenceText.bounded(interval + item.text, bytes: 768),
                locator: EvidenceText.bounded(item.locator, bytes: 256), trust: item.trust.rawValue)
        }
        return ContextToolResult(records: records, coverage: [
            EvidenceText.bounded(scope, bytes: 512), try await sourceCoverage(.calendar)
        ] + identityCoverage)
    }

    private func contacts(_ call: ContextToolCall) async throws -> ContextToolResult {
        guard let query = call.person ?? call.query else { throw LocalModelFailure("Contacts reads require a literal name, handle or search term.") }
        let limit = call.limit ?? 8, offset = call.offset ?? 0
        let candidates: [Observation]
        if let handle = Self.literalHandle(query) {
            candidates = try await store.currentObservations(source: .contacts,
                matchingAnyHandle: Self.handleVariants(handle), limit: offset + limit + 1)
        } else if call.person != nil {
            candidates = try await resolvePerson(query).people
        } else if let fts = Self.fts(query) {
            candidates = try await store.search(fts, sources: [.contacts], limit: offset + limit + 1).map(\.observation)
        } else { throw LocalModelFailure("Contacts searches need literal text or a phone/email handle.") }
        let filtered: [Observation]
        if call.person != nil, let topic = call.query {
            let terms = Self.tokens(topic)
            guard !terms.isEmpty else { throw LocalModelFailure("Contact filters require literal text.") }
            filtered = candidates.filter { item in terms.allSatisfy { Self.tokens(item.text).contains($0) } }
        } else { filtered = candidates }
        let selected = Array(filtered.dropFirst(offset).prefix(limit))
        let scope = "contacts: \(selected.count) matching indexed contact records, offset \(offset), limit \(limit). Search terms are literal, not FTS operators. Name identity candidates are bounded to 100 and may be incomplete for broad names. Multiple records may identify different people; resolve ambiguity before using a contact's handles.\(filtered.count > offset + limit ? " More matches are available at offset \(offset + limit)." : "")"
        return ContextToolResult(records: Self.records(selected), coverage: [scope, try await sourceCoverage(.contacts)])
    }

    private struct PersonResolution {
        let people: [Observation]
        let complete: Bool
    }

    private func resolvePerson(_ name: String) async throws -> PersonResolution {
        guard let query = Self.fts(name) else { return PersonResolution(people: [], complete: true) }
        // This candidate bound is explicit. Exhausting it never produces a guessed identity.
        let hits = try await store.search(query, sources: [.contacts], limit: 101).map(\.observation)
        let tokens = Self.tokens(name)
        let names = hits.prefix(100).filter { contact in
            Self.names(contact).contains { field in tokens.allSatisfy { Self.tokens(field).contains($0) } }
        }
        let exact = names.filter { contact in Self.names(contact).contains { Self.tokens($0) == tokens } }
        return PersonResolution(people: exact.isEmpty ? names : exact, complete: hits.count <= 100)
    }

    private static func names(_ contact: Observation) -> [String] {
        let lines = contact.text.split(separator: "\n")
        return [lines.first.map(String.init) ?? ""] + lines.filter { $0.hasPrefix("Nickname: ") }.map { String($0.dropFirst(10)) }
    }
    private static func displayName(_ contact: Observation) -> String {
        contact.text.split(separator: "\n").first.map(String.init) ?? "Unnamed contact"
    }
    private static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
    private static func fts(_ text: String?) -> String? {
        guard let text else { return nil }
        let terms = tokens(text)
        guard !terms.isEmpty else { return nil }
        return terms.map { "\"\($0)\"" }.joined(separator: " AND ")
    }
    private static func checkedFTS(_ text: String?) throws -> String? {
        let query = fts(text)
        if text != nil, query == nil { throw LocalModelFailure("Topic searches require literal letters or numbers; omit query for an unfiltered read.") }
        return query
    }
    private static func literalHandle(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("@"), !value.contains(where: \.isWhitespace) { return PersonHandle.normalize(value) }
        let phoneCharacters = CharacterSet(charactersIn: "+0123456789 ()-.\u{00A0}")
        if value.unicodeScalars.allSatisfy(phoneCharacters.contains), value.filter(\.isNumber).count >= 7 {
            return PersonHandle.normalize(value)
        }
        if value.lowercased().hasPrefix("tel:") { return literalHandle(String(value.dropFirst(4))) }
        return nil
    }
    private static func handleVariants(_ handle: String) -> Set<String> {
        guard let value = PersonHandle.normalize(handle) else { return [] }
        // A written country code may omit '+'. Do not guess a country from local
        // digits or join unrelated contacts using suffix-only phone matches.
        if value.hasPrefix("+"), value.dropFirst().allSatisfy(\.isNumber) {
            return [value, String(value.dropFirst())]
        }
        return [value]
    }

    private func parseDate(_ value: String) throws -> Date {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: value) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian)
        day.timeZone = calendar.timeZone
        day.dateFormat = "yyyy-MM-dd"
        day.isLenient = false
        guard value.count == 10, let result = day.date(from: value), day.string(from: result) == value else {
            throw LocalModelFailure("Context dates must be ISO calendar dates or timestamps with a timezone.")
        }
        return result
    }

    private func sourceCoverage(_ source: ObservationSource) async throws -> String {
        guard let state = try await store.sourceCoverage(for: source) else { return "\(source.rawValue): never synced; results cover indexed rows only." }
        let timestamp = ISO8601DateFormatter().string(from: state.lastSuccessfulSync)
        return EvidenceText.bounded("\(source.rawValue): \(state.status.rawValue), synced \(timestamp). \(state.limitations.joined(separator: " ")) Indexed evidence may be older than the device's current data.", bytes: 512)
    }
    private static func records(_ observations: [Observation]) -> [EvidenceRecord] {
        observations.prefix(8).enumerated().map { index, item in
            EvidenceRecord(id: "e\(index + 1)", source: item.source.rawValue, timestamp: item.sourceTimestamp,
                text: EvidenceText.bounded(item.text, bytes: 768), locator: EvidenceText.bounded(item.locator, bytes: 256), trust: item.trust.rawValue)
        }
    }
}
