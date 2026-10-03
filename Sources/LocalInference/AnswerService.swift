import Foundation

public struct AnswerResult: Sendable {
    public enum Mode: String, Codable, Sendable { case model, evidence, insufficient }
    public let mode: Mode
    public let text: String
    public let modelID: String?
}

public struct AnswerService: Sendable {
    private let provider: any LocalModelProvider
    public init(provider: any LocalModelProvider) { self.provider = provider }

    public func answer(_ request: EvidenceRequest) async throws -> AnswerResult {
        try request.validate()
        guard !request.records.isEmpty else {
            return AnswerResult(mode: .insufficient, text: "No matching indexed evidence.\n" + footer(request), modelID: nil)
        }
        let availability = await provider.availability()
        guard availability.ready else {
            return fallback(request, reason: availability.detail)
        }
        do {
            let answer = try await provider.answer(request)
            try answer.validate(for: request)
            if answer.insufficientEvidence {
                return AnswerResult(mode: .insufficient, text: "The retrieved evidence is insufficient to answer this question.\n" + footer(request), modelID: provider.modelID)
            }
            let usedIDs = Set(answer.claims.flatMap(\.evidenceIDs))
            let claims = answer.claims.map { "\($0.text) [\($0.evidenceIDs.joined(separator: ", "))]" }
            let sources = request.records.filter { usedIDs.contains($0.id) }.map {
                "[\($0.id)] \($0.source) — \($0.locator)"
            }
            return AnswerResult(mode: .model, text: (claims + sources + [footer(request)]).joined(separator: "\n"), modelID: provider.modelID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return fallback(request, reason: "Local generation failed or its citations were invalid.")
        }
    }

    private func fallback(_ request: EvidenceRequest, reason: String) -> AnswerResult {
        let excerpts = request.records.map { "[\($0.id)] \($0.text)\nSource: \($0.locator)" }
        return AnswerResult(mode: .evidence, text: (["Evidence only: \(reason)"] + excerpts + [footer(request)]).joined(separator: "\n"), modelID: nil)
    }

    private func footer(_ request: EvidenceRequest) -> String {
        let timestamp = ISO8601DateFormatter().string(from: request.createdAt)
        return (["Evidence assembled: \(timestamp).", "Coverage is bounded; citations identify supplied sources, not proof that every model claim is correct."] + request.coverage).joined(separator: "\n")
    }
}
