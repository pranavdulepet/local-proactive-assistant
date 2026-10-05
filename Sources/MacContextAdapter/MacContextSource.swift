import Foundation
import LocalInference

/// A host-owned read boundary. Model requests cannot change the permitted roots or run code.
public struct MacContextSource: ReadContextSource {
    private let files: FileContextReader
    private let runner: ContextCommandRunner

    /// Additional roots must be chosen by the owner locally, never by a model tool call.
    /// A nil list uses the usual document folders and the locally available iCloud Drive.
    public init(allowedRoots: [URL]? = nil) {
        self.init(allowedRoots: allowedRoots ?? Self.defaultRoots, runner: .system)
    }

    init(allowedRoots: [URL], runner: ContextCommandRunner) {
        self.runner = runner
        files = FileContextReader(roots: allowedRoots, runner: runner)
    }

    public static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Documents", "Desktop", "Downloads", "Library/Mobile Documents/com~apple~CloudDocs"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
    }

    public func execute(_ call: ContextToolCall) async throws -> ContextToolResult {
        try Task.checkCancellation()
        try call.validate()
        let result: ContextToolResult
        do {
            switch call.tool {
            case .searchFiles:
                result = try await Self.offload { try await files.search(call.query!) }
            case .readFile:
                result = try await Self.offload { try await files.read(call.path!) }
            case .notes, .reminders:
                let script = call.tool == .notes ? AppContextScripts.notes : AppContextScripts.reminders
                let query = call.query.map { FileContextReader.searchTerms($0).joined(separator: " ") } ?? ""
                let output = try await runner.run("/usr/bin/osascript",
                    ["-l", "JavaScript", "-e", script, "--", query], nil, 15, 262_144)
                guard !output.truncated else { throw MacContextFailure("The application response exceeded its bounded output limit.") }
                result = try AppContextSnapshot.decode(output.data).result(source: call.tool.rawValue)
            case .deviceInfo:
                result = await deviceInfo()
            case .searchIndex, .mailInbox:
                result = ContextToolResult(records: [], coverage: ["This local Mac reader does not provide \(call.tool.rawValue); the host's Messages/Calendar/Contacts index and Mail adapter provide those reads."])
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let detail: String
            if call.tool == .notes || call.tool == .reminders {
                let app = call.tool == .notes ? "Notes" : "Reminders"
                detail = "\(app) could not be read. Open \(app) with synced local items and allow the host terminal under macOS Privacy & Security > Automation > \(app). Locked or unavailable items may remain unreadable. Each read stops after 15 seconds."
            } else if let failure = error as? MacContextFailure {
                detail = failure.description
            } else {
                detail = "This local read could not complete. Check folder access and that the document is downloaded locally."
            }
            throw MacContextFailure(EvidenceText.bounded("\(call.tool.rawValue): \(detail)", bytes: 512))
        }
        try result.validate()
        return result
    }

    private static func offload<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let worker = Task.detached(operation: operation)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func deviceInfo() async -> ContextToolResult {
        let process = ProcessInfo.processInfo
        var model = "unavailable"
        if let output = try? await runner.run("/usr/sbin/sysctl", ["-n", "hw.model"], nil, 3, 1_024),
           !output.truncated, let text = String(data: output.data, encoding: .utf8) {
            model = EvidenceText.bounded(text.trimmingCharacters(in: .whitespacesAndNewlines), bytes: 128)
        }
        let text = "Mac hardware identifier: \(model)\nSystem: \(process.operatingSystemVersionString)\nPhysical memory: \(process.physicalMemory) bytes\nLogical processors: \(process.processorCount)"
        return ContextToolResult(records: [EvidenceRecord(id: "device:hardware", source: "device",
            timestamp: Date(), text: EvidenceText.bounded(text, bytes: 768), locator: "mac:hardware",
            trust: "hostMetadata")], coverage: ["Device information is basic local OS/hardware metadata. It does not include passwords, accounts, running-app contents, screen text or phone hardware."])
    }
}
