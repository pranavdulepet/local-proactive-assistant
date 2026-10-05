import Foundation
import LocalInference

public struct PersonalContextTrace: Equatable, Sendable {
    public let stage: String
    public let tool: ContextTool?
    public let elapsedMilliseconds: Int
    public let outcome: String
}

public struct PersonalContextAnswer: Sendable {
    public let reply: ChatReply
    public let trace: [PersonalContextTrace]
}

public struct PersonalContextReadTimeout: Error, CustomStringConvertible, Sendable {
    public var description: String { "The context read timed out; no complete result was available." }
    public init() {}
}

/// A read-only model loop. The host owns permissions, call budgets and the eventual recipient.
public struct PersonalContextAgent: Sendable {
    private let provider: any LocalModelProvider
    private let source: any ReadContextSource
    private let availableTools: [ContextTool]
    private let initialCoverage: [String]
    private let readTimeout: Duration
    private let clock: @Sendable () -> Date

    public init(provider: any LocalModelProvider, source: any ReadContextSource,
                availableTools: [ContextTool], coverage: [String] = [],
                readTimeout: Duration = .seconds(20),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.source = source
        self.availableTools = Array(Set(availableTools)).sorted { $0.rawValue < $1.rawValue }
        self.initialCoverage = coverage
        self.readTimeout = readTimeout
        self.clock = clock
    }

    public func reply(message: String, history: [ChatTurn]) async throws -> PersonalContextAnswer {
        var records: [EvidenceRecord] = []
        var coverage = initialCoverage
        var executed: [ContextToolCall] = []
        var trace: [PersonalContextTrace] = []

        for pass in 0..<2 {
            try Task.checkCancellation()
            // Reserve one read for refinement rather than spending the whole budget immediately.
            let remaining = pass == 0 ? 2 : 3 - executed.count
            guard remaining > 0 else { break }
            let request = ContextPlanRequest(
                message: message, history: history, records: records,
                coverage: boundedCoverage(coverage), availableTools: availableTools,
                executedCalls: executed, remainingCalls: remaining, createdAt: clock()
            )
            try request.validate()
            let started = clock()
            let plan = try await provider.planContext(request)
            try plan.validate(for: request)
            trace.append(PersonalContextTrace(stage: "planning", tool: nil,
                elapsedMilliseconds: milliseconds(since: started), outcome: "pass \(pass + 1); \(plan.calls.count) reads"))
            if plan.calls.isEmpty { break }

            var shouldRefine = false
            for call in plan.calls {
                try Task.checkCancellation()
                // Attempted reads count even if they fail; the model cannot retry indefinitely.
                executed.append(call)
                let started = clock()
                do {
                    let result = try await read(call)
                    try result.validate()
                    records = merging(records, with: result.records)
                    coverage.append(contentsOf: result.coverage)
                    trace.append(PersonalContextTrace(stage: "read", tool: call.tool,
                        elapsedMilliseconds: milliseconds(since: started), outcome: "\(result.records.count) records"))
                    // File discovery returns candidate paths, so a second pass may read a candidate.
                    if result.records.isEmpty || call.tool == .searchFiles { shouldRefine = true }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    shouldRefine = true
                    coverage.append(EvidenceText.bounded("\(call.tool.rawValue): read failed. \(error)", bytes: 512))
                    trace.append(PersonalContextTrace(stage: "read", tool: call.tool,
                        elapsedMilliseconds: milliseconds(since: started), outcome: "unavailable"))
                }
            }
            if !shouldRefine { break }
        }

        try Task.checkCancellation()
        let request = ChatRequest(message: message, history: history,
            records: records, coverage: boundedCoverage(coverage))
        try request.validate()
        let started = clock()
        let reply = try await provider.chat(request)
        try reply.validate()
        trace.append(PersonalContextTrace(stage: "reply", tool: nil,
            elapsedMilliseconds: milliseconds(since: started), outcome: "generated"))
        return PersonalContextAnswer(reply: reply, trace: trace)
    }

    private func read(_ call: ContextToolCall) async throws -> ContextToolResult {
        try call.validate()
        let source = self.source
        let timeout = readTimeout
        return try await withThrowingTaskGroup(of: ContextToolResult.self) { group in
            group.addTask { try await source.execute(call) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PersonalContextReadTimeout()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    private func boundedCoverage(_ coverage: [String]) -> [String] {
        var seen = Set<String>()
        let statuses = coverage.reversed().filter { seen.insert($0).inserted }.prefix(7).reversed()
        let capability = "Available host read tools: " + availableTools.map(\.rawValue).joined(separator: ", ")
            + ". Reads are bounded to permitted sources; this answer contains at most eight sampled records across sources. Missing records are not proof that no data exists."
        return [EvidenceText.bounded(capability, bytes: 512)]
            + statuses.map { EvidenceText.bounded($0, bytes: 512) }
    }

    private func merging(_ existing: [EvidenceRecord], with added: [EvidenceRecord]) -> [EvidenceRecord] {
        var seen = Set<String>()
        let latest = (existing + added).reversed().filter {
            seen.insert($0.source + "\0" + $0.locator + "\0" + $0.text).inserted
        }
        // Keep evidence from each source: a full Mail sample must not erase Calendar,
        // and a document read must not erase the context that motivated it.
        var sourceOrder: [String] = []
        var groups: [String: [EvidenceRecord]] = [:]
        for record in latest {
            if groups[record.source] == nil { sourceOrder.append(record.source) }
            groups[record.source, default: []].append(record)
        }
        var selected: [EvidenceRecord] = []
        var offset = 0
        while selected.count < 8 {
            var found = false
            for source in sourceOrder where selected.count < 8 {
                if let group = groups[source], offset < group.count {
                    selected.append(group[offset])
                    found = true
                }
            }
            if !found { break }
            offset += 1
        }
        return selected.enumerated().map { index, record in
            EvidenceRecord(id: "e\(index + 1)", source: record.source, timestamp: record.timestamp,
                text: record.text, locator: record.locator, trust: record.trust)
        }
    }

    private func milliseconds(since started: Date) -> Int {
        max(0, Int(clock().timeIntervalSince(started) * 1_000))
    }
}
