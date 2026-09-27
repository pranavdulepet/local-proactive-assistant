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
                if let initialStandardInput, let stdin {
                    try stdin.fileHandleForWriting.write(contentsOf: initialStandardInput)
                }
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let reader = Task.detached { [weak self] in
                guard let self else { return }

                do {
                    while !Task.isCancelled {
                        let chunk = try self.stdout.fileHandleForReading.read(upToCount: 4_096)
                            ?? Data()
                        guard !chunk.isEmpty else { break }

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
                                : "imsg rpc exited with status \(self.process.terminationStatus)"
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
