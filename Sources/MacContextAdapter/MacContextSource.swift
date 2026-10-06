import Foundation
import LocalInference

/// A host-owned read boundary. Model requests cannot change the permitted roots or run code.
public struct MacContextSource: ReadContextSource {
    private let files: FileContextReader
    private let runner: ContextCommandRunner
    private let reminders: RemindersContextReader
    private let photos: PhotosContextReader

    /// Additional roots must be chosen by the owner locally, never by a model tool call.
    /// A nil list uses the usual document folders and the locally available iCloud Drive.
    public init(allowedRoots: [URL]? = nil, requestPermissions: Bool = false) {
        self.init(allowedRoots: allowedRoots ?? Self.defaultRoots, runner: .system,
                  reminderStore: EventKitReminderStore(), requestPermissions: requestPermissions)
    }

    init(allowedRoots: [URL], runner: ContextCommandRunner,
         reminderStore: any ReminderStore = EventKitReminderStore(),
         photoStore: any PhotoStore = NativePhotoStore(), requestPermissions: Bool = false) {
        self.runner = runner
        files = FileContextReader(roots: allowedRoots, runner: runner)
        reminders = RemindersContextReader(store: reminderStore, requestPermissions: requestPermissions)
        photos = PhotosContextReader(store: photoStore, requestPermissions: requestPermissions)
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
            case .notes:
                let script = AppContextScripts.notes
                let query = call.query.map { FileContextReader.searchTerms($0).filter {
                    !["note", "notes", "check", "show", "list", "summarize"].contains($0)
                }.joined(separator: " ") } ?? ""
                let output = try await runner.run("/usr/bin/osascript",
                    ["-l", "JavaScript", "-e", script, "--", query], nil, 15, 262_144)
                guard !output.truncated else { throw MacContextFailure("The application response exceeded its bounded output limit.", kind: .invalidResponse) }
                result = try AppContextSnapshot.decode(output.data).result(source: call.tool.rawValue)
            case .reminders:
                result = try await reminders.read(query: call.query)
            case .photos:
                result = try await photos.read(call)
            case .deviceInfo:
                result = await deviceInfo()
            case .searchIndex, .mailInbox, .messages, .calendar, .contacts:
                result = ContextToolResult(records: [], coverage: ["This local Mac reader does not provide \(call.tool.rawValue); the host's Messages/Calendar/Contacts index and Mail adapter provide those reads."])
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = error as? MacContextFailure
                ?? MacContextFailure("This local read failed without a classified access error.")
            let detail = call.tool == .notes ? Self.notesFailure(failure) : failure.description
            throw MacContextFailure(EvidenceText.bounded("\(call.tool.rawValue): \(detail)", bytes: 512),
                                    kind: failure.kind, systemCode: failure.systemCode)
        }
        try result.validate()
        return result
    }

    private static func notesFailure(_ failure: MacContextFailure) -> String {
        switch failure.kind {
        case .permissionDenied:
            return "Notes Apple Events access was denied (\(failure.systemCode ?? -1743)). Allow the host terminal under macOS Privacy & Security > Automation > Notes if you want it connected."
        case .permissionRequired:
            return "Notes Apple Events access has not been granted. Run source setup on the Mac to choose access."
        case .timedOut:
            return "Notes did not finish its read before the deadline. No permission denial was reported. Open Notes and check whether it is responding, then retry."
        case .scriptingFailed:
            return "The fixed Notes scripting API failed\(failure.systemCode.map { " (Apple Event code \($0))" } ?? ""). This does not establish denied permission; update the host and check Notes is responding."
        case .applicationUnavailable:
            return "Notes could not be reached through Apple Events. Open Notes on this Mac and retry."
        case .invalidResponse:
            return "Notes returned invalid or oversized data from the fixed script. The source was not marked connected."
        case .permissionRestricted:
            return "Notes access is restricted by macOS or device management."
        default:
            return "Notes exposed items, but the bounded read could not complete. Locked items or its scripting API may be the cause; permission denial was not reported."
        }
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
