import Darwin
import Foundation

public struct ProcessFailure: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum BoundedProcessRunner {
    public static func run(
        executable: String,
        arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval = 60
    ) async throws -> Data {
        let child = BoundedProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Blocking Foundation APIs must not occupy Swift's cooperative executor.
                DispatchQueue(label: "assistant.helper.request").async {
                    continuation.resume(with: Result {
                        try capture(
                            child: child, executable: executable, arguments: arguments,
                            standardInput: standardInput, timeout: timeout
                        )
                    })
                }
            }
        } onCancel: {
            child.stop()
        }
    }

    private static func capture(
        child: BoundedProcess,
        executable: String,
        arguments: [String],
        standardInput: Data?,
        timeout: TimeInterval
    ) throws -> Data {
        let process = child.process
        let stdout = Pipe()
        let stderr = Pipe()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = standardInput.map { _ in Pipe() }
        process.standardInput = stdin
        try child.start()
        let deadline = DispatchWorkItem { child.stop(timedOut: true) }
        DispatchQueue(label: "assistant.helper.deadline").asyncAfter(
            deadline: .now() + timeout, execute: deadline
        )
        defer {
            deadline.cancel()
            child.stop()
        }
        let outputReader = ProcessOutput(stdout)
        let errorReader = ProcessOutput(stderr)
        if let standardInput, let stdin {
            try stdin.fileHandleForWriting.write(contentsOf: standardInput)
            try stdin.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        let output = outputReader.value()
        let errorOutput = errorReader.value()
        if child.timedOut {
            throw ProcessFailure("Helper request exceeded its \(Int(timeout))s deadline; result may be unknown")
        }
        if child.cancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProcessFailure(
                detail?.isEmpty == false ? detail! : "Helper exited with status \(process.terminationStatus)"
            )
        }
        return output
    }
}

private final class ProcessOutput: @unchecked Sendable {
    private let group = DispatchGroup()
    private var data = Data()

    init(_ pipe: Pipe) {
        group.enter()
        DispatchQueue(label: "assistant.helper.pipe").async { [self] in
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
    }

    func value() -> Data {
        group.wait()
        return data
    }
}

/// Launch/cancel races are serialized; escalation only targets this still-running child.
private final class BoundedProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var interrupted = false
    private var deadlineExpired = false

    var cancelled: Bool { lock.withLock { interrupted } }
    var timedOut: Bool { lock.withLock { deadlineExpired } }

    func start() throws {
        try lock.withLock {
            if interrupted { throw CancellationError() }
            try process.run()
        }
    }

    func stop(timedOut: Bool = false) {
        lock.withLock {
            interrupted = true
            guard process.isRunning else { return }
            deadlineExpired = deadlineExpired || timedOut
            process.terminate()
        }
        DispatchQueue(label: "assistant.helper.terminate").asyncAfter(deadline: .now() + 2) { [self] in
            lock.withLock {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

