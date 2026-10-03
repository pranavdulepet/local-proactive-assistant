import AssistantCore
import Darwin
import Foundation

func transportDebugLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["ASSISTANT_DEBUG"] == "1" else { return }
    try? FileHandle.standardError.write(contentsOf: Data("[transport] \(message)\n".utf8))
}

enum ProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval = 60
    ) async throws -> Data {
        let child = BoundedProcess()
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            // Foundation's blocking pipe/wait APIs must not occupy Swift's cooperative executor.
            DispatchQueue(label: "imsg.request").async {
              do {
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
            DispatchQueue(label: "imsg.deadline").asyncAfter(deadline: .now() + timeout, execute: deadline)
            defer { deadline.cancel(); child.stop() }

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
                throw TransportFailure("imsg request exceeded its \(Int(timeout))s deadline; result may be unknown")
            }
            if child.cancelled { throw CancellationError() }

            guard process.terminationStatus == 0 else {
                let detail = String(data: errorOutput, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw TransportFailure(
                    detail?.isEmpty == false ? detail! : "imsg exited with status \(process.terminationStatus)"
                )
            }

            continuation.resume(returning: output)
              } catch {
                continuation.resume(throwing: error)
              }
            }
          }
        } onCancel: {
            child.stop()
        }
    }
}

private final class ProcessOutput: @unchecked Sendable {
    private let group = DispatchGroup()
    private var data = Data()

    init(_ pipe: Pipe) {
        group.enter()
        DispatchQueue(label: "imsg.pipe").async { [self] in
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
        DispatchQueue(label: "imsg.terminate").asyncAfter(deadline: .now() + 2) { [self] in
            lock.withLock {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

final class StreamingProcess: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var buffer = Data()

    func lines(
        executable: String,
        arguments: [String],
        initialStandardInput: Data? = nil
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            if executable.contains("/") {
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [executable] + arguments
            }

            process.standardOutput = stdout
            process.standardError = stderr

            let stdin = initialStandardInput.map { _ in Pipe() }
            process.standardInput = stdin

            do {
                try process.run()
                transportDebugLog("started \(executable) \(arguments.joined(separator: " "))")
                if let initialStandardInput, let stdin {
                    try stdin.fileHandleForWriting.write(contentsOf: initialStandardInput)
                }
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let reader = Task.detached { [self] in
                do {
                    while !Task.isCancelled {
                        var bytes = [UInt8](repeating: 0, count: 4_096)
                        let count = bytes.withUnsafeMutableBytes { buffer in
                            Darwin.read(
                                self.stdout.fileHandleForReading.fileDescriptor,
                                buffer.baseAddress,
                                buffer.count
                            )
                        }
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        guard count > 0 else { break }

                        let chunk = Data(bytes.prefix(count))
                        transportDebugLog("received \(count) stdout bytes")

                        self.lock.withLock {
                            self.buffer.append(chunk)
                            while let newline = self.buffer.firstIndex(of: 0x0A) {
                                let line = self.buffer[..<newline]
                                self.buffer.removeSubrange(...newline)
                                if !line.isEmpty {
                                    continuation.yield(Data(line))
                                }
                            }
                        }
                    }

                    self.process.waitUntilExit()
                    guard self.process.terminationStatus != 0,
                          self.process.terminationReason != .uncaughtSignal else {
                        continuation.finish()
                        return
                    }

                    let errorData = self.stderr.fileHandleForReading.readDataToEndOfFile()
                    let detail = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.finish(
                        throwing: TransportFailure(
                            detail?.isEmpty == false
                                ? detail!
                                : "imsg rpc exited with status \(self.process.terminationStatus)",
                            retrySafe: true
                        )
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { [weak self] _ in
                reader.cancel()
                try? stdin?.fileHandleForWriting.close()
                guard let self, self.process.isRunning else { return }
                self.process.terminate()
            }
        }
    }
}
