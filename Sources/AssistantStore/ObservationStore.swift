import CSQLite
import Foundation

public struct ObservationStoreFailure: Error, CustomStringConvertible, Sendable {
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}

public actor ObservationStore {
    private let database: OpaquePointer

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

        self.database = database

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
    }

    deinit {
        sqlite3_close(database)
    }

    @discardableResult
    public func record(_ observation: Observation) throws -> Bool {
        try execute("BEGIN IMMEDIATE")
        do {
            let inserted = try insert(observation)
            let storedID = try observationID(
                source: observation.source,
                externalID: observation.externalID,
                versionHash: observation.versionHash
            )

            if inserted && !observation.tombstone {
                try insertSearchText(id: storedID, text: observation.text)
            }
            try updateHead(
                source: observation.source,
                externalID: observation.externalID,
                observationID: storedID,
                sourceRevision: observation.sourceRevision
            )
            try execute("COMMIT")
            return inserted
        } catch {
            try? execute("ROLLBACK")
            throw error
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
            WHERE excluded.source_revision > observation_heads.source_revision
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(source.rawValue, at: 1, to: statement)
        try bind(externalID, at: 2, to: statement)
        try bind(observationID, at: 3, to: statement)
        try bind(sourceRevision, at: 4, to: statement)
        try step(statement, operation: "update observation head")
    }

    private func decodeObservation(_ statement: OpaquePointer) throws -> Observation {
        guard let id = UUID(uuidString: try text(at: 0, from: statement)),
              let source = ObservationSource(rawValue: try text(at: 1, from: statement)),
              let trust = ObservationTrust(rawValue: try text(at: 7, from: statement)) else {
            throw ObservationStoreFailure("Stored observation contains an unknown value")
        }

        let sourceTimestamp = sqlite3_column_type(statement, 6) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        return Observation(
            id: id,
            source: source,
            externalID: try text(at: 2, from: statement),
            versionHash: try text(at: 3, from: statement),
            sourceRevision: sqlite3_column_int64(statement, 4),
            observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            sourceTimestamp: sourceTimestamp,
            trust: trust,
            text: try text(at: 8, from: statement),
            locator: try text(at: 9, from: statement),
            tombstone: sqlite3_column_int(statement, 10) != 0
        )
    }

    private func execute(_ sql: String) throws {
        try Self.execute(sql, on: database)
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map(String.init(cString:)) ?? "unknown SQLite error"
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

    private func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        try check(sqlite3_bind_double(statement, index, value), operation: "bind number")
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

    CREATE VIRTUAL TABLE IF NOT EXISTS observation_fts USING fts5(
        observation_id UNINDEXED,
        text,
        tokenize = 'unicode61'
    );

    CREATE INDEX IF NOT EXISTS observations_source_time
    ON observations(source, source_timestamp);
    """
}
