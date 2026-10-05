import AssistantCore
import Foundation
import LocalInference

/// Host-owned dispatch: the model can request reads, but cannot supply executable code or recipients.
public struct IndexedContextSource: ReadContextSource {
    private let store: ObservationStore
    private let mail: (any MailSource)?
    private let additional: (any ReadContextSource)?
    private let access: SourceAccessRegistry?

    public init(store: ObservationStore, mail: (any MailSource)? = nil,
                additional: (any ReadContextSource)? = nil, access: SourceAccessRegistry? = nil) {
        self.store = store
        self.mail = mail
        self.additional = additional
        self.access = access
    }

    public func execute(_ call: ContextToolCall) async throws -> ContextToolResult {
        try call.validate()
        let accessTool: ContextTool = call.tool == .searchIndex && ConversationContextRouter.requestsMail(call.query ?? "")
            ? .mailInbox : call.tool
        do {
            let result = try await read(call)
            try result.validate()
            // Access status is advisory. A metadata write failure must not discard
            // successfully read evidence or become a source-access diagnosis.
            try? await access?.record(tool: accessTool, ready: true, detail: result.coverage.joined(separator: " "))
            return result
        } catch is CancellationError { throw CancellationError() }
        catch {
            try? await access?.record(tool: accessTool, ready: false, detail: String(describing: error))
            throw error
        }
    }

    private func read(_ call: ContextToolCall) async throws -> ContextToolResult {
        switch call.tool {
        case .searchIndex:
            guard let query = call.query, !query.isEmpty else {
                throw LocalModelFailure("An indexed search needs a question or search terms.")
            }
            if ConversationContextRouter.requestsMail(query), let mail {
                do { return try await mailResult(query: query, source: mail) }
                catch {
                    try? await store.markSourceUnavailable(.mail)
                    throw error
                }
            }
            let request = try await EvidenceRetriever(store: store).request(question: query)
            return ContextToolResult(records: request.records, coverage: request.coverage)
        case .mailInbox:
            guard let mail else { throw MailSourceFailure("Apple Mail is not enabled on this host.") }
            do { return try await mailResult(query: call.query, source: mail) }
            catch {
                try? await store.markSourceUnavailable(.mail)
                throw error
            }
        default:
            guard let additional else {
                throw LocalModelFailure("This read source is not enabled on this host.")
            }
            return try await additional.execute(call)
        }
    }

    private func mailResult(query: String?, source: any MailSource) async throws -> ContextToolResult {
        let snapshot = try await MailIngestor(source: source, store: store).refresh(query: query)
        let records = snapshot.messages.prefix(8).enumerated().map { index, record in
            EvidenceRecord(id: "e\(index + 1)", source: "mail", timestamp: record.receivedAt,
                text: EvidenceText.bounded(MailIngestor.text(for: record), bytes: 768),
                locator: EvidenceText.bounded(MailIngestor.locator(for: record), bytes: 256), trust: "unknownExternal")
        }
        let coverage = snapshot.coverageLimitations.map { EvidenceText.bounded("mail: " + $0, bytes: 512) }
            + ["mail: This turn supplies at most eight message excerpts from the current search page. It does not summarize every matching email."]
        return ContextToolResult(records: Array(records), coverage: coverage)
    }
}
