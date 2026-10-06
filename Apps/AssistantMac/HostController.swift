import AppKit
import Combine
import Darwin
import Foundation
import ServiceManagement

@MainActor
final class HostController: ObservableObject {
    static let shared = HostController()
    enum Phase: String { case stopped = "Stopped", starting = "Starting", running = "Running", stopping = "Stopping", attention = "Needs attention", restarting = "Restarting" }
    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var modelLabel = "No model selected"
    @Published private(set) var notice = ""
    @Published private(set) var sources: [SourceObservation] = []
    @Published private(set) var coverage = "No indexed source status checked yet."
    @Published private(set) var recentLines: [String] = []
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginDetail = ""
    @Published private(set) var checkingSources = false
    @Published private(set) var readRoots: [String] = []
    let support: URL
    let payload: URL
    private var backend: Process?
    private var modelServer: Process?
    private var awake: Process?
    private var output: Pipe?
    private var pendingOutput = Data()
    private var startup: Task<Void, Never>?
    private var restart: Task<Void, Never>?
    private var readinessTimeout: Task<Void, Never>?
    private var sourceCheck: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var generation = UUID()
    private var shouldRun = false
    private var budget = RestartBudget()
    private var readyAt: Date?
    private var log: FileHandle?

    var isActive: Bool { [.starting, .running, .stopping, .restarting].contains(phase) }
    var canStart: Bool { !isActive }
    var hasSetup: Bool {
        FileManager.default.fileExists(atPath: support.appendingPathComponent("model-profile.txt").path)
            && FileManager.default.fileExists(atPath: support.appendingPathComponent("control-chat-id.txt").path)
    }
    var cli: URL { payload.appendingPathComponent("bin/assistantctl") }

    init(payload: URL? = nil, support: URL? = nil) {
        self.payload = payload ?? Bundle.main.resourceURL!.appendingPathComponent("Runtime")
        self.support = support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalProactiveAssistant")
        refreshSavedState()
        loadReadRoots()
        refreshLoginStatus()
    }

    func launch() {
        guard hasSetup else {
            notice = "Choose a model and pair your Messages self-chat with the guided starter first."
            phase = .attention
            return
        }
        start()
    }

    func start(resetBudget: Bool = true) {
        guard !isActive else { return }
        if resetBudget { budget.reset() }
        generation = UUID()
        let token = generation
        shouldRun = true
        readyAt = nil
        notice = ""
        phase = .starting
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                let profile = try HostProfile.load(from: support.appendingPathComponent("model-profile.txt"))
                modelLabel = profile.label
                try prepareLog()
                if profile.provider == "ollama" { try await startOllama(token: token) }
                let doctor = try await command(cli, ["doctor", "--quiet"], timeout: 20)
                guard doctor.status == 0 else { throw HostFailure(doctor.text.isEmpty ? "Allow Local Assistant Full Disk Access in Privacy & Security, then Start again." : doctor.text) }
                let check = try await command(cli, ["model-status"] + profile.arguments + ["--quiet"], timeout: 25)
                guard check.status == 0 else { throw HostFailure(check.text.isEmpty ? "The selected local model is unavailable." : check.text) }
                try Task.checkCancellation()
                guard generation == token, shouldRun else { throw CancellationError() }
                try startBackend(profile: profile, token: token)
            } catch is CancellationError {
                // The explicit Stop task owns cleanup and state.
            } catch {
                guard generation == token else { return }
                shouldRun = false
                generation = UUID()
                let failureToken = generation
                append("Startup stopped: \(error)")
                await stopOwnedProcesses()
                guard generation == failureToken else { return }
                phase = .attention
                notice = String(describing: error)
            }
        }
    }

    func stop(completion: (@MainActor () -> Void)? = nil) {
        if let stopping {
            Task { await stopping.value; completion?() }
            return
        }
        shouldRun = false
        readyAt = nil
        generation = UUID()
        let token = generation
        startup?.cancel()
        restart?.cancel()
        readinessTimeout?.cancel()
        sourceCheck?.cancel()
        phase = .stopping
        stopping = Task { [weak self] in
            guard let self else { completion?(); return }
            defer { stopping = nil }
            await startup?.value
            await sourceCheck?.value
            await stopOwnedProcesses()
            guard generation == token else { completion?(); return }
            phase = .stopped
            notice = "The assistant is stopped. Start to answer texts again."
            completion?()
        }
    }

    private func startBackend(profile: HostProfile, token: UUID) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = cli
        process.arguments = ["serve"] + profile.arguments + ["--quiet"]
        if let root = ProcessInfo.processInfo.environment["ASSISTANT_READ_ROOT"], !root.isEmpty {
            process.arguments! += ["--read-root", root]
        }
        for root in readRoots { process.arguments! += ["--read-root", root] }
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] exited in
            let code = exited.terminationStatus
            Task { @MainActor [weak self] in await self?.backendExited(code: code, token: token) }
        }
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(data, token: token) }
        }
        backend = process
        output = pipe
        pendingOutput = Data()
        try process.run()
        let power = Process()
        power.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        power.arguments = ["-i", "-w", String(process.processIdentifier)]
        power.standardOutput = FileHandle.nullDevice
        power.standardError = FileHandle.nullDevice
        try power.run()
        awake = power
        readinessTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, generation == token, phase == .starting else { return }
            shouldRun = false
            generation = UUID()
            let timeoutToken = generation
            await stopOwnedProcesses()
            guard generation == timeoutToken else { return }
            phase = .attention
            notice = "The host did not finish starting. Check access permissions and recent activity, then Start again."
        }
    }

    private func consume(_ data: Data, token: UUID) {
        guard generation == token else { return }
        pendingOutput.append(data)
        while let end = pendingOutput.firstIndex(of: 10) {
            let line = String(decoding: pendingOutput[..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            pendingOutput.removeSubrange(...end)
            if line.hasPrefix("Ready."), backend?.isRunning == true, shouldRun {
                readinessTimeout?.cancel()
                phase = .running
                readyAt = Date()
                refreshSavedState()
                notice = "Text your paired self-chat from your phone. Keep this Mac online; closing the lid can stop replies."
            }
            if !line.isEmpty { append(line) }
        }
        if pendingOutput.count > 16_384 {
            append(String(decoding: pendingOutput.prefix(16_384), as: UTF8.self))
            pendingOutput.removeAll(keepingCapacity: true)
        }
    }

    private func backendExited(code: Int32, token: UUID) async {
        guard generation == token else { return }
        let wasReady = readyAt != nil
        if let readyAt, Date().timeIntervalSince(readyAt) >= 600 { budget.reset() }
        readyAt = nil
        if !pendingOutput.isEmpty { append(String(decoding: pendingOutput, as: UTF8.self)); pendingOutput.removeAll() }
        append("Host exited with status \(code).")
        phase = .stopping
        await stopOwnedProcesses()
        guard generation == token else { return }
        guard shouldRun, let delay = budget.nextDelay(wasReady: wasReady, exitStatus: code, intentional: !shouldRun) else {
            shouldRun = false
            phase = code == 0 ? .stopped : .attention
            notice = code == 0 ? "The assistant stopped. Start to resume." : "The host exited with status \(code). Check recent activity, then Start again."
            return
        }
        phase = .restarting
        notice = "The host exited. Restarting in \(Int(delay)) seconds (\(budget.attempts) of 3)."
        restart = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, generation == token, shouldRun else { return }
            phase = .stopped
            start(resetBudget: false)
        }
    }

    private func startOllama(token: UUID) async throws {
        let port = try await command(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-nP", "-iTCP:11435", "-sTCP:LISTEN", "-t"], timeout: 5)
        guard port.status != 0 else { throw HostFailure("The model port is already in use. Stop the Terminal assistant or other host before starting this app.") }
        let candidates = [
            support.appendingPathComponent("Runtime/Ollama.app/Contents/Resources/ollama"),
            URL(fileURLWithPath: "/opt/homebrew/opt/ollama/bin/ollama"),
            URL(fileURLWithPath: "/usr/local/opt/ollama/bin/ollama"),
            URL(fileURLWithPath: "/Applications/Ollama.app/Contents/Resources/ollama"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ollama"), URL(fileURLWithPath: "/usr/local/bin/ollama")
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw HostFailure("Ollama is not installed. Run the guided starter once to install the selected local model.")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve"]
        var env = environment()
        env["OLLAMA_HOST"] = "127.0.0.1:11435"
        env["OLLAMA_NO_CLOUD"] = "1"
        env["NO_PROXY"] = "localhost,127.0.0.1,::1"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] exited in
            let code = exited.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, generation == token, shouldRun, phase == .running else { return }
                append("The owned Ollama server exited with status \(code).")
                backend?.terminate()
            }
        }
        modelServer = process
        try process.run()
        for _ in 0..<40 {
            try Task.checkCancellation()
            guard generation == token, process.isRunning else { throw HostFailure("Ollama exited before its local server started. Open the app log for details.") }
            let owner = try await command(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-nP", "-a", "-p", String(process.processIdentifier), "-iTCP:11435", "-sTCP:LISTEN", "-t"], timeout: 3)
            if owner.status == 0 { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw HostFailure("Ollama did not open its local model port. Open the app log for details.")
    }

    private func stopOwnedProcesses() async {
        readinessTimeout?.cancel()
        output?.fileHandleForReading.readabilityHandler = nil
        let ownedBackend = backend
        let ownedAwake = awake
        let ownedModel = modelServer
        let ownedLog = log
        backend = nil
        awake = nil
        modelServer = nil
        output = nil
        log = nil
        await terminate(ownedBackend)
        await terminate(ownedAwake)
        await terminate(ownedModel)
        try? ownedLog?.close()
    }

    private func terminate(_ process: Process?) async {
        guard let process, process.isRunning else { return }
        process.terminate()
        // Detached cleanup preserves a grace period even when the startup task was cancelled.
        await Task.detached {
            for _ in 0..<50 {
                if !process.isRunning { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                for _ in 0..<10 {
                    if !process.isRunning { return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }.value
    }

    private struct Result { let status: Int32; let text: String }
    private func command(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> Result {
        let logs = support.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = logs.appendingPathComponent("native-check-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw HostFailure("The app could not create a private check log.") }
        let file = try FileHandle(forWritingTo: temp)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = file
        process.standardError = file
        defer { try? file.close(); try? FileManager.default.removeItem(at: temp) }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw HostFailure("The \(executable.lastPathComponent) check timed out.") }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            await terminate(process)
            throw error
        }
        let read = try FileHandle(forReadingFrom: temp)
        defer { try? read.close() }
        let data = try read.read(upToCount: 65_536) ?? Data()
        return Result(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = payload.appendingPathComponent("bin").path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["ASSISTANT_NATIVE_HOST"] = "1"
        return env
    }

    private func prepareLog() throws {
        let folder = support.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("native-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw HostFailure("The app could not create its private log.") }
        log = try FileHandle(forWritingTo: url)
    }

    private func append(_ line: String) {
        let bounded = String(line.prefix(2048))
        recentLines.append(bounded)
        if recentLines.count > 80 { recentLines.removeFirst(recentLines.count - 80) }
        try? log?.write(contentsOf: Data((bounded + "\n").utf8))
    }

    func refreshSavedState() {
        if !isActive, let profile = try? HostProfile.load(from: support.appendingPathComponent("model-profile.txt")) { modelLabel = profile.label }
        let url = support.appendingPathComponent("source-access.json")
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? 65_537) <= 65_536,
           let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([SourceObservation].self, from: data) {
            sources = Array(decoded.sorted { $0.name < $1.name }.prefix(12))
        }
    }

    func refreshSources(connect: Bool = false) {
        guard !checkingSources else { return }
        checkingSources = true
        sourceCheck = Task { [weak self] in
            guard let self else { return }
            defer { checkingSources = false; refreshSavedState() }
            do {
                if connect {
                    let check = try await command(cli, ["prepare-access", "--quiet"], timeout: 180)
                    notice = check.status == 0 ? "The requested source checks completed. Coverage still depends on each question." : check.text
                }
                let status = try await command(cli, ["source-status"], timeout: 10)
                coverage = status.text.isEmpty ? "No indexed source status is available yet." : status.text
            } catch is CancellationError {
            } catch { notice = String(describing: error) }
        }
    }

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
        switch status {
        case .enabled: loginDetail = "Starts at your next login."
        case .requiresApproval: loginDetail = "Approve Local Assistant in Login Items."
        case .notRegistered: loginDetail = "Off"
        case .notFound: loginDetail = "Install the app before enabling login startup."
        @unknown default: loginDetail = "Login status unavailable."
        }
    }

    private func loadReadRoots() {
        let url = support.appendingPathComponent("native-read-roots.json")
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
           values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 16_385) <= 16_384,
           let data = try? Data(contentsOf: url), let roots = try? JSONDecoder().decode([String].self, from: data),
           roots.count <= 16, roots.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 1024 && !$0.contains("\0") }) {
            readRoots = roots
        }
    }

    func chooseReadFolder() {
        guard !isActive else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a folder the assistant may read"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let path = panel.url?.path, !readRoots.contains(path) else { return }
        saveReadRoots(Array((readRoots + [path]).prefix(16)))
    }

    func removeReadFolder(_ path: String) { guard !isActive else { return }; saveReadRoots(readRoots.filter { $0 != path }) }

    private func saveReadRoots(_ roots: [String]) {
        do {
            let target = support.appendingPathComponent("native-read-roots.json")
            if FileManager.default.fileExists(atPath: target.path) {
                let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw HostFailure("The folder settings path is not a regular file.") }
            }
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(roots).write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            readRoots = roots
        } catch { notice = "The permitted folders could not be saved: \(error)" }
    }

    func setLoginEnabled(_ enabled: Bool) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch { notice = "Login startup could not be changed: \(error.localizedDescription)" }
            refreshLoginStatus()
        }
    }

    func openLogs() { NSWorkspace.shared.open(support.appendingPathComponent("Logs")) }
    func openAccessSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
    func openSetupGuide() { NSWorkspace.shared.open(URL(string: "https://github.com/pranavdulepet/local-proactive-assistant/blob/main/docs/install.md")!) }
}
