import AssistantCore
import Foundation
import LocalInference
import Testing
@testable import AssistantStore

struct SourceAccessRegistryTests {
    @Test func nativeSetupAndRunningReaderPreserveEachOthersLatestObservations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("access.json")
        let runningReader = try SourceAccessRegistry(fileURL: file)
        let nativeSetup = try SourceAccessRegistry(fileURL: file)
        let now = Date()
        try await runningReader.record(tool: .notes, ready: true, detail: "Queried Notes", at: now)
        try await nativeSetup.record(tool: .mailInbox, ready: false, detail: "Mail script failure", at: now)
        try await nativeSetup.record(tool: .notes, ready: false, detail: "Older check", at: now.addingTimeInterval(-60))
        let status = await runningReader.snapshot()
        #expect(status.count == 2)
        #expect(status.first { $0.tool == .notes }?.ready == true)
        #expect(status.first { $0.tool == .mailInbox }?.detail == "Mail script failure")
    }

    @Test func failedFirstReadIsVisibleInStatusWithoutInventingPermissions() async throws {
        let registry = try SourceAccessRegistry()
        let store = try ObservationStore()
        let source = IndexedContextSource(store: store, additional: UnavailableNotes(), access: registry)
        await #expect(throws: Error.self) { _ = try await source.execute(ContextToolCall(tool: .notes)) }
        let status = try await ControlCommandHandler(store: store, access: registry).response(to: "/status")!
        #expect(status.contains("Notes: unavailable"))
        #expect(status.contains("Notes script error -1708"))
        #expect(!status.contains("Automation"))
    }

    @Test func readableEmptyAppReplacesOldFailureAndPersists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("access.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = try SourceAccessRegistry(fileURL: file)
        try await registry.record(tool: .notes, ready: false, detail: "unavailable")
        try await registry.record(tool: .notes, ready: true, detail: "No matching notes; queried title and body.")
        let restored = try SourceAccessRegistry(fileURL: file)
        let entries = await restored.snapshot()
        #expect(entries.count == 1)
        #expect(entries[0].ready)
        #expect(entries[0].detail.contains("No matching"))
    }
}

private struct UnavailableNotes: ReadContextSource {
    func execute(_ call: ContextToolCall) throws -> ContextToolResult {
        throw LocalModelFailure("Notes script error -1708; access denial was not reported.")
    }
}
