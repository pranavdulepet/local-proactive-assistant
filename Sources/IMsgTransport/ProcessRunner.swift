import AssistantCore
import Foundation

enum ProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        standardInput: Data? = nil
    ) async throws -> Data {
        try await Task.detached {
            let process = Process()
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

            if let standardInput {
                let stdin = Pipe()
                process.standardInput = stdin
                try process.run()
                try stdin.fileHandleForWriting.write(contentsOf: standardInput)
                try stdin.fileHandleForWriting.close()
            } else {
                try process.run()
            }

            process.waitUntilExit()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()

            guard process.terminationStatus == 0 else {
                let detail = String(data: errorOutput, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw TransportFailure(
                    detail?.isEmpty == false ? detail! : "imsg exited with status \(process.terminationStatus)"
                )
            }

            return output
        }.value
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
        arguments: [String]
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

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }

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

            process.terminationHandler = { [weak self] process in
                guard let self else { return }
                self.stdout.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus == 0 || process.terminationReason == .uncaughtSignal {
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
                            : "imsg watch exited with status \(process.terminationStatus)"
                    )
                )
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
            }

            continuation.onTermination = { [weak self] _ in
                guard let self, self.process.isRunning else { return }
                self.process.terminate()
            }
        }
    }
}
