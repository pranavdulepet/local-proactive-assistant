import AssistantCore
import Foundation
import LocalInference

/// Host-owned dispatch: the model can request reads, but cannot supply executable code or recipients.
public struct IndexedContextSource: ReadContextSource {
    private let store: ObservationStore
    private let mail: (any MailSource)?
    private let additional: (any ReadContextSource)?

    public init(store: ObservationStore, mail: (any MailSource)? = nil,
                additional: (any ReadContextSource)? = nil) {
        self.store = store
        self.mail = mail
        self.additional = additional
    }

    public func execute(_ call: ContextToolCall) async throws -> ContextToolResult {
        try call.validate()
        switch call.tool {
        case .searchIndex:
            guard let query = call.query, !query.isEmpty else {
                throw LocalModelFailure("An indexed search needs a question or search terms.")
            }
            if ConversationContextRouter.requestsMail(query), let mail {
                do { try await MailIngestor(source: mail, store: store).run() }
                catch {
                    try? await store.markSourceUnavailable(.mail)
                    throw error
                }
            }
            let request = try await EvidenceRetriever(store: store).request(question: query)
            return ContextToolResult(records: request.records, coverage: request.coverage)
        case .mailInbox:
            guard let mail else { throw MailSourceFailure("Apple Mail is not enabled on this host.") }
            do { try await MailIngestor(source: mail, store: store).run() }
            catch {
                try? await store.markSourceUnavailable(.mail)
                throw error
            }
            // A tool request has already selected Mail; do not classify its search terms again.
            let query = "email inbox " + (call.query ?? "recent")
            let request = try await EvidenceRetriever(store: store).request(question: query)
            return ContextToolResult(records: request.records,
                coverage: request.coverage.filter { $0.hasPrefix("mail:") })
        default:
            guard let additional else {
                throw LocalModelFailure("This read source is not enabled on this host.")
            }
            return try await additional.execute(call)
        }
    }
}
