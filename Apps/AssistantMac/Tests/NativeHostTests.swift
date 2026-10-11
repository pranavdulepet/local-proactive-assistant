import Darwin
import Foundation

@main
struct NativeHostTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-host-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try testProfiles(root)
        try testRestartBudget()
        try await testRunningHostStopsItsProcess(root)
        try await testStopCancelsStartupCheck(root)
        try await testPhonePairingBlocksStartAndCancelsItsProcess(root)
        try await testExitBeforeReadyIsNotRetried(root)
        try await testAccessDenialNamesTheNativeApp(root)
        print("Native host profile and process lifecycle tests passed.")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw HostFailure(message) }
    }

    private static func testProfiles(_ root: URL) throws {
        let profile = root.appendingPathComponent("profile.txt")
        for text in ["1\napple\n\n\n", "1\nollama\nqwen3.5:4b\n\n", "1\nlocal\nmy-model\nhttp://127.0.0.1:8080/v1\n", "1\nlocal\nmy-model\nhttp://[::1]:8080/v1\n"] {
            try Data(text.utf8).write(to: profile)
            _ = try HostProfile.load(from: profile)
        }
        for text in ["1\nlocal\nmy-model\nhttps://example.com/v1\n", "1\nlocal\nmy-model\nhttp://localhost:8080/v1\n", "1\nlocal\nmy-model\nhttp://user:pass@127.0.0.1:8080/v1\n", "1\nlocal\nmy-model\nhttp://127.0.0.1:8080/v1?token=x\n", "1\nollama\nqwen:CLOUD\n\n", "1\nollama\n$(touch pwned)\n\n", "1\napple\nextra\n\n", "1\napple\n\n\nextra\n"] {
            try Data(text.utf8).write(to: profile)
            do { _ = try HostProfile.load(from: profile); throw HostFailure("Accepted invalid saved model settings: \(text)") }
            catch let failure as HostFailure { if failure.description.hasPrefix("Accepted invalid") { throw failure } }
        }
        try Data("1\napple\n\n\n".utf8).write(to: profile)
        let link = root.appendingPathComponent("linked-profile.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: profile)
        do { _ = try HostProfile.load(from: link); throw HostFailure("Accepted a symlink model profile.") }
        catch let failure as HostFailure { if failure.description == "Accepted a symlink model profile." { throw failure } }
        let ollama = HostProfile(provider: "ollama", model: "qwen3.5:4b", endpoint: "")
        try require(ollama.arguments == ["--model", "ollama", "--model-url", "http://127.0.0.1:11435", "--model-name", "qwen3.5:4b"], "Native Ollama arguments changed.")
    }

    private static func testRestartBudget() throws {
        var budget = RestartBudget()
        try require(budget.nextDelay(wasReady: false, exitStatus: 1, intentional: false) == nil, "Retried startup failure.")
        try require(budget.nextDelay(wasReady: true, exitStatus: 0, intentional: false) == nil, "Retried clean exit.")
        try require(budget.nextDelay(wasReady: true, exitStatus: 1, intentional: true) == nil, "Retried intentional stop.")
        for delay in [2.0, 5.0, 15.0] {
            try require(budget.nextDelay(wasReady: true, exitStatus: 1, intentional: false) == delay, "Wrong restart delay.")
        }
        try require(budget.nextDelay(wasReady: true, exitStatus: 1, intentional: false) == nil, "Unbounded restart loop.")
        budget.reset()
        try require(budget.attempts == 0, "Restart budget did not reset.")
    }

    @MainActor private static func fixture(_ root: URL, name: String, behavior: String) throws -> (HostController, URL) {
        let home = root.appendingPathComponent(name)
        let payload = home.appendingPathComponent("Runtime")
        let support = home.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: payload.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let pid = home.appendingPathComponent("child.pid")
        let path = pid.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/bash
        case "$1" in
          doctor) \(behavior == "denied-doctor" ? "echo 'Messages: unavailable'; exit 1" : behavior == "blocked-check" ? "echo $$ > '\(path)'; exec /bin/sleep 60" : "exit 0") ;;
          model-status) exit 0 ;;
          serve) echo $$ > '\(path)'; \(behavior == "exit-before-ready" ? "exit 7" : "echo 'Ready. Fixture host'; exec /bin/sleep 60") ;;
          pair-phone) echo $$ > '\(path)'; exec /bin/sleep 60 ;;
          *) exit 0 ;;
        esac
        """
        let cli = payload.appendingPathComponent("bin/assistantctl")
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        try Data("1\nlocal\nfixture-model\nhttp://127.0.0.1:8080/v1\n".utf8).write(to: support.appendingPathComponent("model-profile.txt"))
        try Data("1\n".utf8).write(to: support.appendingPathComponent("control-chat-id.txt"))
        return (HostController(payload: payload, support: support), pid)
    }

    @MainActor private static func waitUntil(_ message: String, timeout: TimeInterval = 8, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { throw HostFailure(message) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor private static func testRunningHostStopsItsProcess(_ root: URL) async throws {
        let (host, pidFile) = try fixture(root, name: "running", behavior: "run")
        host.launch()
        try await waitUntil("Host did not consume real readiness output: \(host.notice)") { host.phase == .running }
        let pid = try Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        try require(Darwin.kill(pid, 0) == 0, "Fixture child never ran.")
        host.stop()
        try await waitUntil("Host did not stop its child.") { host.phase == .stopped }
        try require(Darwin.kill(pid, 0) != 0, "Owned host process survived Stop.")
    }

    @MainActor private static func testStopCancelsStartupCheck(_ root: URL) async throws {
        let (host, pidFile) = try fixture(root, name: "startup", behavior: "blocked-check")
        host.launch()
        try await waitUntil("Startup check did not start.") {
            guard let value = try? String(contentsOf: pidFile, encoding: .utf8) else { return false }
            return Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }
        let pid = try Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        host.stop()
        try await waitUntil("Startup cancellation did not finish.") { host.phase == .stopped }
        try require(Darwin.kill(pid, 0) != 0, "Startup probe survived Stop.")
    }

    @MainActor private static func testExitBeforeReadyIsNotRetried(_ root: URL) async throws {
        let (host, _) = try fixture(root, name: "early-exit", behavior: "exit-before-ready")
        host.launch()
        try await waitUntil("Early exit was not reported.") { host.phase == .attention }
        try require(host.notice.contains("7"), "Exit status was hidden.")
        try await Task.sleep(for: .milliseconds(2200))
        try require(host.phase == .attention, "Failed startup was automatically retried.")
    }

    @MainActor private static func testAccessDenialNamesTheNativeApp(_ root: URL) async throws {
        let (host, _) = try fixture(root, name: "access-denial", behavior: "denied-doctor")
        host.launch()
        try await waitUntil("Messages denial did not stop startup.") { host.phase == .attention }
        try require(host.notice.contains("Local Assistant Full Disk Access"), "Native access recovery did not name the responsible app.")
        try require(host.notice.contains("quit and reopen"), "Native access recovery did not explain the required relaunch.")
    }

    @MainActor private static func testPhonePairingBlocksStartAndCancelsItsProcess(_ root: URL) async throws {
        let (host, pidFile) = try fixture(root, name: "phone-pairing", behavior: "run")
        host.pairPhone()
        try await waitUntil("Phone pairing command did not start.") {
            guard let value = try? String(contentsOf: pidFile, encoding: .utf8) else { return false }
            return Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        }
        let pid = try Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        try require(host.pairingPhone && !host.canStart, "Start was enabled during phone pairing.")
        host.launch()
        try require(host.phase == .stopped, "The host started while pairing was in progress.")
        host.stop()
        try await waitUntil("Phone pairing cancellation did not finish.") { host.phase == .stopped && !host.pairingPhone }
        try require(Darwin.kill(pid, 0) != 0, "Phone pairing process survived Stop.")
        try require(host.phonePairingResult.isEmpty, "Cancelled pairing displayed a verification result.")
    }
}
