import CSQLite
import AssistantCore
import Foundation

public struct ObservationStoreFailure: Error, CustomStringConvertible, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

public actor ObservationStore {
    private let connection: SQLiteConnection
    private var database: OpaquePointer { connection.handle }

    public init(fileURL: URL? = nil) throws {
        if let fileURL {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        var database: OpaquePointer?
        let path = fileURL?.path ?? ":memory:"
        let result = sqlite3_open_v2(
            path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown SQLite error"
            sqlite3_close(database)
            throw ObservationStoreFailure("Could not open observation store: \(detail)")
        }

        do {
            try Self.execute(Self.schema, on: database)
            if let fileURL {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: fileURL.path
                )
            }
        } catch {
            sqlite3_close(database)
            throw error
        }

        connection = SQLiteConnection(handle: database)
    }

    @discardableResult
    public func record(_ observation: Observation) throws -> Bool {
        try execute("BEGIN IMMEDIATE")
        do {
            let inserted = try recordInsideTransaction(observation)
            try execute("COMMIT")
            return inserted
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    public func record(
        _ observations: [Observation],
        advancing source: ObservationSource,
        cursor: String
    ) throws -> Int {
        try execute("BEGIN IMMEDIATE")
        do {
            var inserted = 0
            for observation in observations {
                guard observation.source == source else {
                    throw ObservationStoreFailure(
                        "Cannot advance \(source.rawValue) with a \(observation.source.rawValue) observation"
                    )
                }
                if try recordInsideTransaction(observation) {
                    inserted += 1
                }
            }
            try saveCursor(cursor, for: source)
            try execute("COMMIT")
            return inserted
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func sourceCursor(for source: ObservationSource) throws -> String? {
        let statement = try prepare(
            "SELECT cursor FROM source_cursors WHERE source = ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(source.rawValue, at: 1, to: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try text(at: 0, from: statement)
        case SQLITE_DONE:
            return nil
        default:
            throw failure("Could not read source cursor")
        }
    }

    public func current(
        source: ObservationSource,
        externalID: String
    ) throws -> Observation? {
        let sql = """
        SELECT o.id, o.source, o.external_id, o.version_hash, o.source_revision,
               o.observed_at, o.source_timestamp, o.trust, o.text, o.locator,
               o.tombstone
        FROM observation_heads h
        JOIN observations o ON o.id = h.observation_id
        WHERE h.source = ? AND h.external_id = ?
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(source.rawValue, at: 1, to: statement)
        try bind(externalID, at: 2, to: statement)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeObservation(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw failure("Could not read current observation")
        }
    }

    public func currentExternalIDs(source: ObservationSource) throws -> Set<String> {
        let statement = try prepare(
            """
            SELECT o.external_id
            FROM observation_heads h
            JOIN observations o ON o.id = h.observation_id
            WHERE h.source = ? AND o.tombstone = 0
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(source.rawValue, at: 1, to: statement)

        var identifiers: Set<String> = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                identifiers.insert(try text(at: 0, from: statement))
            case SQLITE_DONE:
                return identifiers
            default:
                throw failure("Could not read current observation identifiers")
            }
        }
    }

    public func currentObservations(
        source: ObservationSource,
        matchingAnyHandle handles: Set<String>,
        from startDate: Date? = nil,
        to endDate: Date? = nil,
        limit: Int = 100
    ) throws -> [Observation] {
        guard !handles.isEmpty, limit > 0 else { return [] }
        let sortedHandles = handles.sorted()
        let placeholders = Array(repeating: "?", count: sortedHandles.count)
            .joined(separator: ", ")
        let sql = """
        SELECT DISTINCT o.id, o.source, o.external_id, o.version_hash, o.source_revision,
               o.observed_at, o.source_timestamp, o.trust, o.text, o.locator,
               o.tombstone
        FROM observation_handles oh
        JOIN observation_heads h ON h.observation_id = oh.observation_id
        JOIN observations o ON o.id = h.observation_id
        WHERE o.source = ?
          AND o.tombstone = 0
          AND oh.handle IN (\(placeholders))
          AND (? IS NULL OR o.source_timestamp >= ?)
          AND (? IS NULL OR o.source_timestamp <= ?)
        ORDER BY o.source_timestamp, o.external_id
        LIMIT ?
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bind(source.rawValue, at: 1, to: statement)
        var index = Int32(2)
        for handle in sortedHandles {
            try bind(handle, at: index, to: statement)
            index += 1
        }
        try bind(startDate?.timeIntervalSince1970, at: index, to: statement)
        try bind(startDate?.timeIntervalSince1970, at: index + 1, to: statement)
        try bind(endDate?.timeIntervalSince1970, at: index + 2, to: statement)
        try bind(endDate?.timeIntervalSince1970, at: index + 3, to: statement)
        try bind(Int64(limit), at: index + 4, to: statement)

        var observations: [Observation] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                observations.append(try decodeObservation(statement))
            case SQLITE_DONE:
                return observations
            default:
                throw failure("Could not read observations by handle")
            }
        }
    }

    public func currentObservations(
        source: ObservationSource,
        trust: ObservationTrust,
        from startDate: Date? = nil,
        to endDate: Date? = nil,
        limit: Int = 100
    ) throws -> [Observation] {
        guard limit > 0 else { return [] }
        let statement = try prepare(
            """
            SELECT o.id, o.source, o.external_id, o.version_hash, o.source_revision,
                   o.observed_at, o.source_timestamp, o.trust, o.text, o.locator,
                   o.tombstone
            FROM observation_heads h
            JOIN observations o ON o.id = h.observation_id
            WHERE o.source = ?
              AND o.trust = ?
              AND o.tombstone = 0
              AND (? IS NULL OR o.source_timestamp >= ?)
              AND (? IS NULL OR o.source_timestamp <= ?)
            ORDER BY o.source_timestamp, o.external_id
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(source.rawValue, at: 1, to: statement)
        try bind(trust.rawValue, at: 2, to: statement)
        try bind(startDate?.timeIntervalSince1970, at: 3, to: statement)
        try bind(startDate?.timeIntervalSince1970, at: 4, to: statement)
        try bind(endDate?.timeIntervalSince1970, at: 5, to: statement)
        try bind(endDate?.timeIntervalSince1970, at: 6, to: statement)
        try bind(Int64(limit), at: 7, to: statement)

        var observations: [Observation] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                observations.append(try decodeObservation(statement))
            case SQLITE_DONE:
                return observations
            default:
                throw failure("Could not read observations by trust")
            }
        }
    }

    @discardableResult
    public func recordCommitments(_ commitments: [CommitmentAssertion]) throws -> Int {
        try execute("BEGIN IMMEDIATE")
        do {
            var inserted = 0
            for commitment in commitments {
                if try insertCommitment(commitment) {
                    inserted += 1
                }
                try insertCommitmentEvidence(commitment)
            }
            try execute("COMMIT")
            return inserted
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    public func replaceCommitments(
        _ commitments: [CommitmentAssertion],
        extractorID: String,
        since: Date
    ) throws -> CommitmentReconciliation {
        guard commitments.allSatisfy({ $0.extractorID == extractorID }) else {
            throw ObservationStoreFailure("Cannot reconcile commitments from another extractor")
        }

        try execute("BEGIN IMMEDIATE")
        do {
            var inserted = 0
            for commitment in commitments {
                if try insertCommitment(commitment) {
                    inserted += 1
                }
                try insertCommitmentEvidence(commitment)
            }

            let currentIDs = Set(commitments.map(\.id))
            let staleIDs = try activeCommitmentIDs(
                extractorID: extractorID,
                since: since
            ).filter { !currentIDs.contains($0) }
            for id in staleIDs {
                try supersedeCommitment(id: id)
            }
            try execute("COMMIT")
            return CommitmentReconciliation(
                inserted: inserted,
                superseded: staleIDs.count
            )
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func openCommitments(limit: Int = 20) throws -> [CommitmentAssertion] {
        guard limit > 0 else { return [] }
        let statement = try prepare(
            """
            SELECT id, predicate, status, summary, due_at, due_text, confidence,
                   evidence_observation_id, extractor_id, schema_version, created_at
            FROM open_commitments
            ORDER BY due_at, created_at
            LIMIT ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(Int64(limit), at: 1, to: statement)
        var commitments: [CommitmentAssertion] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                commitments.append(try decodeCommitment(statement))
            case SQLITE_DONE:
                return commitments
            default:
                throw failure("Could not read open commitments")
            }
        }
    }

    public func commitmentEvidence(id: String) throws -> CommitmentEvidence? {
        let statement = try prepare(
            """
            SELECT a.id, a.predicate, a.status, a.summary, a.due_at, a.due_text,
                   a.confidence, a.evidence_observation_id, a.extractor_id,
                   a.schema_version, a.created_at,
                   o.id, o.source, o.external_id, o.version_hash, o.source_revision,
                   o.observed_at, o.source_timestamp, o.trust, o.text, o.locator,
                   o.tombstone
            FROM derived_assertions a
            JOIN assertion_evidence e ON e.assertion_id = a.id
            JOIN observations o ON o.id = e.observation_id
            WHERE a.id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return CommitmentEvidence(
                commitment: try decodeCommitment(statement),
                observation: try decodeObservation(statement, offset: 11)
            )
        case SQLITE_DONE:
            return nil
        default:
            throw failure("Could not read commitment evidence")
        }
    }

    @discardableResult
    public func completeCommitment(id: String) throws -> Bool {
        let statement = try prepare(
            """
            UPDATE derived_assertions
            SET status = ?
            WHERE id = ? AND predicate = ? AND status = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(AssertionStatus.completed.rawValue, at: 1, to: statement)
        try bind(id, at: 2, to: statement)
        try bind(AssertionPredicate.commitmentCreated.rawValue, at: 3, to: statement)
        try bind(AssertionStatus.active.rawValue, at: 4, to: statement)
        try step(statement, operation: "complete commitment")
        return sqlite3_changes(database) == 1
    }

    public func setProactivityPaused(_ paused: Bool) throws {
        try execute("UPDATE proactivity_settings SET paused = \(paused ? 1 : 0) WHERE id = 1")
    }

    /// Called by the single host after acquiring its lock, never by diagnostic readers.
    public func recoverInterruptedReminders() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("UPDATE proactivity_settings SET paused = 1 WHERE EXISTS (SELECT 1 FROM proactive_deliveries WHERE outcome = 'reserved')")
            try execute("UPDATE proactive_deliveries SET outcome = 'unknown' WHERE outcome = 'reserved'")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// A failed attempt must not change the last successful sync timestamp.
    public func markSourceUnavailable(_ source: ObservationSource) throws {
        let statement = try prepare("UPDATE source_coverage SET status = 'unavailable' WHERE source = ?")
        defer { sqlite3_finalize(statement) }
        try bind(source.rawValue, at: 1, to: statement)
        try step(statement, operation: "mark unavailable source")
    }

    public func proactivityStatus() throws -> ProactivityStatus {
        let statement = try prepare("SELECT paused, last_gate, checked_at FROM proactivity_settings WHERE id = 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure("Could not read proactivity settings") }
        let delivery = try prepare("SELECT id || ': ' || outcome FROM proactive_deliveries ORDER BY reserved_at DESC LIMIT 1")
        defer { sqlite3_finalize(delivery) }
        let lastDelivery = sqlite3_step(delivery) == SQLITE_ROW ? try text(at: 0, from: delivery) : nil
        return ProactivityStatus(
            paused: sqlite3_column_int(statement, 0) == 1,
            lastGate: try text(at: 1, from: statement),
            checkedAt: optionalDate(at: 2, from: statement),
            lastDelivery: lastDelivery
        )
    }

    /// The budget, evidence check, audit decision and reservation share one SQLite transaction.
    public func reserveDueReminder(now: Date, calendar: Calendar) throws -> ReminderReservation? {
        try execute("BEGIN IMMEDIATE")
        do {
            let reservation = try reserveDueReminderInsideTransaction(now: now, calendar: calendar)
            try execute("COMMIT")
            return reservation
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func reserveDueReminderInsideTransaction(now: Date, calendar: Calendar) throws -> ReminderReservation? {
        if try proactivityStatus().paused {
            try saveProactiveGate("paused", at: now)
            return nil
        }
        let components = calendar.dateComponents([.era, .year, .month, .day], from: now)
        let day = "\(components.era ?? 1)-\(components.year!)-\(components.month!)-\(components.day!)"
        let budget = try prepare("SELECT 1 FROM proactive_deliveries WHERE local_day = ? OR reserved_at > ? LIMIT 1")
        defer { sqlite3_finalize(budget) }
        try bind(day, at: 1, to: budget)
        try bind(now.addingTimeInterval(-86_400).timeIntervalSince1970, at: 2, to: budget)
        if sqlite3_step(budget) == SQLITE_ROW {
            try saveProactiveGate("dailyBudget", at: now)
            return nil
        }
        let candidates = try prepare("SELECT id FROM open_commitments WHERE due_at >= ? AND due_at <= ? ORDER BY due_at, id")
        defer { sqlite3_finalize(candidates) }
        try bind(now.timeIntervalSince1970, at: 1, to: candidates)
        try bind(now.addingTimeInterval(10_800).timeIntervalSince1970, at: 2, to: candidates)
        let coverage = try sourceCoverage(for: .messages)
        var lastGate = "noDueCommitment"
        while sqlite3_step(candidates) == SQLITE_ROW {
            let id = try text(at: 0, from: candidates)
            guard let evidence = try commitmentEvidence(id: id) else { continue }
            let currentID = try current(source: .messages, externalID: evidence.observation.externalID)?.id
            if let gate = DueCommitmentRule.gate(evidence: evidence, coverage: coverage, currentObservationID: currentID, now: now, calendar: calendar) {
                lastGate = gate
                continue
            }
            let repeated = try prepare("SELECT 1 FROM proactive_deliveries WHERE evidence_key = ? LIMIT 1")
            defer { sqlite3_finalize(repeated) }
            try bind(evidence.observation.externalID, at: 1, to: repeated)
            if sqlite3_step(repeated) == SQLITE_ROW {
                lastGate = "duplicateEvidence"
                continue
            }
            let reservation = ReminderReservation(id: UUID(), commitmentID: id)
            let insert = try prepare("INSERT INTO proactive_deliveries (id, commitment_id, evidence_key, local_day, reserved_at, outcome) VALUES (?, ?, ?, ?, ?, 'reserved')")
            defer { sqlite3_finalize(insert) }
            try bind(reservation.id.uuidString, at: 1, to: insert)
            try bind(id, at: 2, to: insert)
            try bind(evidence.observation.externalID, at: 3, to: insert)
            try bind(day, at: 4, to: insert)
            try bind(now.timeIntervalSince1970, at: 5, to: insert)
            try step(insert, operation: "reserve proactive reminder")
            try saveProactiveGate("reserved:\(id)", at: now)
            return reservation
        }
        try saveProactiveGate(lastGate, at: now)
        return nil
    }

    public func finishReminder(id: UUID, outcome: String, messageGUID: String?) throws {
        let statement = try prepare("UPDATE proactive_deliveries SET outcome = ?, message_guid = ? WHERE id = ? AND outcome = 'reserved'")
        defer { sqlite3_finalize(statement) }
        try bind(outcome, at: 1, to: statement)
        try bind(messageGUID, at: 2, to: statement)
        try bind(id.uuidString, at: 3, to: statement)
        try step(statement, operation: "record proactive submission")
    }

    private func saveProactiveGate(_ gate: String, at now: Date) throws {
        let statement = try prepare("UPDATE proactivity_settings SET last_gate = ?, checked_at = ? WHERE id = 1")
        defer { sqlite3_finalize(statement) }
        try bind(gate, at: 1, to: statement)
        try bind(now.timeIntervalSince1970, at: 2, to: statement)
        try step(statement, operation: "audit proactive gate")
    }

    @discardableResult
    public func refreshCoverage(
        for source: ObservationSource,
        status: CoverageStatus,
        limitations: [String],
        at syncDate: Date = Date()
    ) throws -> SourceCoverage {
        let (earliest, latest) = try currentTimestampBounds(for: source)
        let cursor = try sourceCursor(for: source)
        let limitationsData = try JSONEncoder().encode(limitations)
        guard let limitationsJSON = String(data: limitationsData, encoding: .utf8) else {
            throw ObservationStoreFailure("Could not encode source coverage limitations")
        }

        let statement = try prepare(
            """
            INSERT INTO source_coverage (
                source, status, earliest_available, latest_observed,
                last_successful_sync, cursor, limitations
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source) DO UPDATE SET
                status = excluded.status,
                earliest_available = excluded.earliest_available,
                latest_observed = excluded.latest_observed,
                last_successful_sync = excluded.last_successful_sync,
                cursor = excluded.cursor,
                limitations = excluded.limitations
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(source.rawValue, at: 1, to: statement)
        try bind(status.rawValue, at: 2, to: statement)
        try bind(earliest?.timeIntervalSince1970, at: 3, to: statement)
        try bind(latest?.timeIntervalSince1970, at: 4, to: statement)
        try bind(syncDate.timeIntervalSince1970, at: 5, to: statement)
        try bind(cursor, at: 6, to: statement)
        try bind(limitationsJSON, at: 7, to: statement)
        try step(statement, operation: "save source coverage")

        return SourceCoverage(
            source: source,
            status: status,
            earliestAvailable: earliest,
            latestObserved: latest,
            lastSuccessfulSync: syncDate,
            cursor: cursor,
            limitations: limitations
        )
    }

    private func currentTimestampBounds(
        for source: ObservationSource
    ) throws -> (Date?, Date?) {
        let statement = try prepare(
            """
            SELECT MIN(o.source_timestamp), MAX(o.source_timestamp)
            FROM observation_heads h
            JOIN observations o ON o.id = h.observation_id
            WHERE h.source = ? AND o.tombstone = 0
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(source.rawValue, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw failure("Could not calculate source coverage")
        }
        return (
            optionalDate(at: 0, from: statement),
            optionalDate(at: 1, from: statement)
        )
    }

    public func sourceCoverage(for source: ObservationSource) throws -> SourceCoverage? {
        let statement = try prepare(
            """
            SELECT source, status, earliest_available, latest_observed,
                   last_successful_sync, cursor, limitations
            FROM source_coverage WHERE source = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(source.rawValue, at: 1, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeCoverage(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw failure("Could not read source coverage")
        }
    }

    public func sourceCoverages() throws -> [SourceCoverage] {
        try ObservationSource.allCases.compactMap { try sourceCoverage(for: $0) }
    }

    public func search(
        _ query: String,
        sources: Set<ObservationSource> = Set(ObservationSource.allCases),
        limit: Int = 20
    ) throws -> [ObservationSearchHit] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sources.isEmpty,
              limit > 0 else {
            return []
        }

        let placeholders = Array(repeating: "?", count: sources.count).joined(separator: ", ")
        let sql = """
        SELECT o.id, o.source, o.external_id, o.version_hash, o.source_revision,
               o.observed_at, o.source_timestamp, o.trust, o.text, o.locator,
               o.tombstone, bm25(observation_fts) AS rank
        FROM observation_fts
        JOIN observation_heads h ON h.observation_id = observation_fts.observation_id
        JOIN observations o ON o.id = h.observation_id
        WHERE observation_fts MATCH ?
          AND o.tombstone = 0
          AND o.source IN (\(placeholders))
        ORDER BY rank
        LIMIT ?
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bind(query, at: 1, to: statement)
        for (offset, source) in sources.sorted(by: { $0.rawValue < $1.rawValue }).enumerated() {
            try bind(source.rawValue, at: Int32(offset + 2), to: statement)
        }
        try bind(Int64(limit), at: Int32(sources.count + 2), to: statement)

        var hits: [ObservationSearchHit] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                hits.append(
                    ObservationSearchHit(
                        observation: try decodeObservation(statement),
                        rank: sqlite3_column_double(statement, 11)
                    )
                )
            case SQLITE_DONE:
                return hits
            default:
                throw failure("Could not search observations")
            }
        }
    }

    private func recordInsideTransaction(_ observation: Observation) throws -> Bool {
        let inserted = try insert(observation)
        let storedID = try observationID(
            source: observation.source,
            externalID: observation.externalID,
            versionHash: observation.versionHash
        )

        if inserted && !observation.tombstone {
            try insertSearchText(id: storedID, text: observation.text)
        }
        try insertHandles(observation.handles, observationID: storedID)
        try updateHead(
            source: observation.source,
            externalID: observation.externalID,
            observationID: storedID,
            sourceRevision: observation.sourceRevision
        )
        return inserted
    }

    private func insertCommitment(_ commitment: CommitmentAssertion) throws -> Bool {
        let statement = try prepare(
            """
            INSERT OR IGNORE INTO derived_assertions (
                id, predicate, status, summary, due_at, due_text, confidence,
                evidence_observation_id, extractor_id, schema_version, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(commitment.id, at: 1, to: statement)
        try bind(commitment.predicate.rawValue, at: 2, to: statement)
        try bind(commitment.status.rawValue, at: 3, to: statement)
        try bind(commitment.summary, at: 4, to: statement)
        try bind(commitment.dueAt.timeIntervalSince1970, at: 5, to: statement)
        try bind(commitment.dueText, at: 6, to: statement)
        try bind(commitment.confidence, at: 7, to: statement)
        try bind(commitment.evidenceObservationID.uuidString, at: 8, to: statement)
        try bind(commitment.extractorID, at: 9, to: statement)
        try bind(commitment.schemaVersion, at: 10, to: statement)
        try bind(commitment.createdAt.timeIntervalSince1970, at: 11, to: statement)
        try step(statement, operation: "insert commitment")
        return sqlite3_changes(database) == 1
    }

    private func insertCommitmentEvidence(_ commitment: CommitmentAssertion) throws {
        let statement = try prepare(
            """
            INSERT OR IGNORE INTO assertion_evidence (assertion_id, observation_id)
            VALUES (?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(commitment.id, at: 1, to: statement)
        try bind(commitment.evidenceObservationID.uuidString, at: 2, to: statement)
        try step(statement, operation: "link commitment evidence")
    }

    private func activeCommitmentIDs(
        extractorID: String,
        since: Date
    ) throws -> [String] {
        let statement = try prepare(
            """
            SELECT id
            FROM derived_assertions
            WHERE predicate = ? AND status = ? AND extractor_id = ? AND created_at >= ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(AssertionPredicate.commitmentCreated.rawValue, at: 1, to: statement)
        try bind(AssertionStatus.active.rawValue, at: 2, to: statement)
        try bind(extractorID, at: 3, to: statement)
        try bind(since.timeIntervalSince1970, at: 4, to: statement)

        var ids: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                ids.append(try text(at: 0, from: statement))
            case SQLITE_DONE:
                return ids
            default:
                throw failure("Could not read active commitments")
            }
        }
    }

    private func supersedeCommitment(id: String) throws {
        let statement = try prepare(
            """
            UPDATE derived_assertions
            SET status = ?
            WHERE id = ? AND status = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(AssertionStatus.superseded.rawValue, at: 1, to: statement)
        try bind(id, at: 2, to: statement)
        try bind(AssertionStatus.active.rawValue, at: 3, to: statement)
        try step(statement, operation: "supersede commitment")
    }

    private func saveCursor(_ cursor: String, for source: ObservationSource) throws {
        let statement = try prepare(
            """
            INSERT INTO source_cursors (source, cursor, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(source)
            DO UPDATE SET cursor = excluded.cursor, updated_at = excluded.updated_at
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(source.rawValue, at: 1, to: statement)
        try bind(cursor, at: 2, to: statement)
        try bind(Date().timeIntervalSince1970, at: 3, to: statement)
        try step(statement, operation: "save source cursor")
    }

    private func insert(_ observation: Observation) throws -> Bool {
        let sql = """
        INSERT OR IGNORE INTO observations (
            id, source, external_id, version_hash, source_revision, observed_at,
            source_timestamp, trust, text, locator, tombstone
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bind(observation.id.uuidString, at: 1, to: statement)
        try bind(observation.source.rawValue, at: 2, to: statement)
        try bind(observation.externalID, at: 3, to: statement)
        try bind(observation.versionHash, at: 4, to: statement)
        try bind(observation.sourceRevision, at: 5, to: statement)
        try bind(observation.observedAt.timeIntervalSince1970, at: 6, to: statement)
        if let sourceTimestamp = observation.sourceTimestamp {
            try bind(sourceTimestamp.timeIntervalSince1970, at: 7, to: statement)
        } else {
            try check(sqlite3_bind_null(statement, 7), operation: "bind source timestamp")
        }
        try bind(observation.trust.rawValue, at: 8, to: statement)
        try bind(observation.text, at: 9, to: statement)
        try bind(observation.locator, at: 10, to: statement)
        try bind(observation.tombstone ? 1 : 0, at: 11, to: statement)
        try step(statement, operation: "insert observation")
        return sqlite3_changes(database) == 1
    }

    private func observationID(
        source: ObservationSource,
        externalID: String,
        versionHash: String
    ) throws -> String {
        let statement = try prepare(
            """
            SELECT id FROM observations
            WHERE source = ? AND external_id = ? AND version_hash = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(source.rawValue, at: 1, to: statement)
        try bind(externalID, at: 2, to: statement)
        try bind(versionHash, at: 3, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw failure("Could not resolve stored observation")
        }
        return try text(at: 0, from: statement)
    }

    private func insertSearchText(id: String, text: String) throws {
        let statement = try prepare(
            "INSERT INTO observation_fts (observation_id, text) VALUES (?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        try bind(id, at: 1, to: statement)
        try bind(text, at: 2, to: statement)
        try step(statement, operation: "index observation")
    }

    private func insertHandles(_ handles: [String], observationID: String) throws {
        for handle in Set(handles) {
            let statement = try prepare(
                "INSERT OR IGNORE INTO observation_handles (observation_id, handle) VALUES (?, ?)"
            )
            defer { sqlite3_finalize(statement) }
            try bind(observationID, at: 1, to: statement)
            try bind(handle, at: 2, to: statement)
            try step(statement, operation: "index observation handle")
        }
    }

    private func updateHead(
        source: ObservationSource,
        externalID: String,
        observationID: String,
        sourceRevision: Int64
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO observation_heads (
                source, external_id, observation_id, source_revision
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(source, external_id)
            DO UPDATE SET
                observation_id = excluded.observation_id,
                source_revision = excluded.source_revision
            WHERE excluded.source_revision >= observation_heads.source_revision
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(source.rawValue, at: 1, to: statement)
        try bind(externalID, at: 2, to: statement)
        try bind(observationID, at: 3, to: statement)
        try bind(sourceRevision, at: 4, to: statement)
        try step(statement, operation: "update observation head")
    }

    private func decodeObservation(
        _ statement: OpaquePointer,
        offset: Int32 = 0
    ) throws -> Observation {
        guard let id = UUID(uuidString: try text(at: offset, from: statement)),
              let source = ObservationSource(rawValue: try text(at: offset + 1, from: statement)),
              let trust = ObservationTrust(rawValue: try text(at: offset + 7, from: statement)) else {
            throw ObservationStoreFailure("Stored observation contains an unknown value")
        }

        let sourceTimestamp = sqlite3_column_type(statement, offset + 6) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 6))
        return Observation(
            id: id,
            source: source,
            externalID: try text(at: offset + 2, from: statement),
            versionHash: try text(at: offset + 3, from: statement),
            sourceRevision: sqlite3_column_int64(statement, offset + 4),
            observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 5)),
            sourceTimestamp: sourceTimestamp,
            trust: trust,
            handles: try handles(for: id.uuidString),
            text: try text(at: offset + 8, from: statement),
            locator: try text(at: offset + 9, from: statement),
            tombstone: sqlite3_column_int(statement, offset + 10) != 0
        )
    }

    private func decodeCommitment(_ statement: OpaquePointer) throws -> CommitmentAssertion {
        guard let predicate = AssertionPredicate(rawValue: try text(at: 1, from: statement)),
              let status = AssertionStatus(rawValue: try text(at: 2, from: statement)),
              let evidenceID = UUID(uuidString: try text(at: 7, from: statement)) else {
            throw ObservationStoreFailure("Stored commitment contains an unknown value")
        }
        return CommitmentAssertion(
            id: try text(at: 0, from: statement),
            predicate: predicate,
            status: status,
            summary: try text(at: 3, from: statement),
            dueAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            dueText: try text(at: 5, from: statement),
            confidence: sqlite3_column_double(statement, 6),
            evidenceObservationID: evidenceID,
            extractorID: try text(at: 8, from: statement),
            schemaVersion: try text(at: 9, from: statement),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10))
        )
    }

    private func handles(for observationID: String) throws -> [String] {
        let statement = try prepare(
            "SELECT handle FROM observation_handles WHERE observation_id = ? ORDER BY handle"
        )
        defer { sqlite3_finalize(statement) }
        try bind(observationID, at: 1, to: statement)
        var handles: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                handles.append(try text(at: 0, from: statement))
            case SQLITE_DONE:
                return handles
            default:
                throw failure("Could not read observation handles")
            }
        }
    }

    private func decodeCoverage(_ statement: OpaquePointer) throws -> SourceCoverage {
        guard let source = ObservationSource(rawValue: try text(at: 0, from: statement)),
              let status = CoverageStatus(rawValue: try text(at: 1, from: statement)) else {
            throw ObservationStoreFailure("Stored source coverage contains an unknown value")
        }
        let data = Data(try text(at: 6, from: statement).utf8)
        return SourceCoverage(
            source: source,
            status: status,
            earliestAvailable: optionalDate(at: 2, from: statement),
            latestObserved: optionalDate(at: 3, from: statement),
            lastSuccessfulSync: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            cursor: optionalText(at: 5, from: statement),
            limitations: try JSONDecoder().decode([String].self, from: data)
        )
    }

    private func optionalDate(at index: Int32, from statement: OpaquePointer) -> Date? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func optionalText(at index: Int32, from statement: OpaquePointer) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func execute(_ sql: String) throws {
        try Self.execute(sql, on: database)
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            throw ObservationStoreFailure(detail)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(
            sqlite3_prepare_v2(database, sql, -1, &statement, nil),
            operation: "prepare statement"
        )
        guard let statement else {
            throw ObservationStoreFailure("SQLite returned no prepared statement")
        }
        return statement
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, Self.transient)
        }
        try check(result, operation: "bind text")
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        if let value {
            try bind(value, at: index, to: statement)
        } else {
            try check(sqlite3_bind_null(statement, index), operation: "bind null text")
        }
    }

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        try check(sqlite3_bind_double(statement, index, value), operation: "bind number")
    }

    private func bind(_ value: Double?, at index: Int32, to statement: OpaquePointer) throws {
        if let value {
            try bind(value, at: index, to: statement)
        } else {
            try check(sqlite3_bind_null(statement, index), operation: "bind null number")
        }
    }

    private func bind(_ value: Int, at index: Int32, to statement: OpaquePointer) throws {
        try bind(Int64(value), at: index, to: statement)
    }

    private func bind(_ value: Int64, at index: Int32, to statement: OpaquePointer) throws {
        try check(sqlite3_bind_int64(statement, index, value), operation: "bind integer")
    }

    private func step(_ statement: OpaquePointer, operation: String) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw failure("Could not \(operation)")
        }
    }

    private func text(at index: Int32, from statement: OpaquePointer) throws -> String {
        guard let value = sqlite3_column_text(statement, index) else {
            throw ObservationStoreFailure("Stored observation is missing required text")
        }
        return String(cString: value)
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result == SQLITE_OK else {
            throw failure("Could not \(operation)")
        }
    }

    private func failure(_ prefix: String) -> ObservationStoreFailure {
        ObservationStoreFailure("\(prefix): \(String(cString: sqlite3_errmsg(database)))")
    }

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static let schema = """
    PRAGMA journal_mode = WAL;
    PRAGMA foreign_keys = ON;
    PRAGMA busy_timeout = 5000;

    CREATE TABLE IF NOT EXISTS proactivity_settings (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        paused INTEGER NOT NULL CHECK (paused IN (0, 1)),
        last_gate TEXT NOT NULL,
        checked_at REAL
    );
    INSERT OR IGNORE INTO proactivity_settings (id, paused, last_gate) VALUES (1, 1, 'notEvaluated');

    CREATE TABLE IF NOT EXISTS proactive_deliveries (
        id TEXT PRIMARY KEY,
        commitment_id TEXT NOT NULL,
        evidence_key TEXT NOT NULL UNIQUE,
        local_day TEXT NOT NULL UNIQUE,
        reserved_at REAL NOT NULL,
        outcome TEXT NOT NULL CHECK (outcome IN ('reserved', 'submitted', 'unknown')),
        message_guid TEXT
    );

    CREATE TABLE IF NOT EXISTS observations (
        id TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        external_id TEXT NOT NULL,
        version_hash TEXT NOT NULL,
        source_revision INTEGER NOT NULL,
        observed_at REAL NOT NULL,
        source_timestamp REAL,
        trust TEXT NOT NULL,
        text TEXT NOT NULL,
        locator TEXT NOT NULL,
        tombstone INTEGER NOT NULL CHECK (tombstone IN (0, 1)),
        UNIQUE (source, external_id, version_hash)
    );

    CREATE TABLE IF NOT EXISTS observation_heads (
        source TEXT NOT NULL,
        external_id TEXT NOT NULL,
        observation_id TEXT NOT NULL REFERENCES observations(id),
        source_revision INTEGER NOT NULL,
        PRIMARY KEY (source, external_id)
    );

    CREATE TABLE IF NOT EXISTS source_cursors (
        source TEXT PRIMARY KEY,
        cursor TEXT NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS observation_handles (
        observation_id TEXT NOT NULL REFERENCES observations(id),
        handle TEXT NOT NULL,
        PRIMARY KEY (observation_id, handle)
    );

    CREATE TABLE IF NOT EXISTS source_coverage (
        source TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        earliest_available REAL,
        latest_observed REAL,
        last_successful_sync REAL NOT NULL,
        cursor TEXT,
        limitations TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS derived_assertions (
        id TEXT PRIMARY KEY,
        predicate TEXT NOT NULL,
        status TEXT NOT NULL,
        summary TEXT NOT NULL,
        due_at REAL NOT NULL,
        due_text TEXT NOT NULL,
        confidence REAL NOT NULL,
        evidence_observation_id TEXT NOT NULL REFERENCES observations(id),
        extractor_id TEXT NOT NULL,
        schema_version TEXT NOT NULL,
        created_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS assertion_evidence (
        assertion_id TEXT NOT NULL REFERENCES derived_assertions(id),
        observation_id TEXT NOT NULL REFERENCES observations(id),
        PRIMARY KEY (assertion_id, observation_id)
    );

    CREATE VIEW IF NOT EXISTS open_commitments AS
    SELECT * FROM derived_assertions
    WHERE predicate = 'commitmentCreated' AND status = 'active';

    CREATE VIRTUAL TABLE IF NOT EXISTS observation_fts USING fts5(
        observation_id UNINDEXED,
        text,
        tokenize = 'unicode61'
    );

    CREATE INDEX IF NOT EXISTS observations_source_time
    ON observations(source, source_timestamp);

    CREATE INDEX IF NOT EXISTS observation_handles_handle
    ON observation_handles(handle);

    CREATE INDEX IF NOT EXISTS derived_assertions_status_due
    ON derived_assertions(predicate, status, due_at);
    """
}

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close(handle)
    }
}
