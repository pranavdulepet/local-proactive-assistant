import Darwin
import Foundation

/// Runs fixed host helpers without a shell. Both output streams and execution time are bounded.
enum ContextProcess {
    struct Output: Sendable {
        let data: Data
        let truncated: Bool
    }

    static func run(executable: String, arguments: [String], input: Data? = nil,
                    timeout: TimeInterval = 12, limit: Int = 524_288) async throws -> Output {
        let child = ContextChild()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue(label: "assistant.context.helper").async {
                    continuation.resume(with: Result {
                        try capture(child, executable: executable, arguments: arguments,
                                    input: input, timeout: timeout, limit: limit)
                    })
                }
            }
        } onCancel: {
            child.stop(.cancelled)
        }
    }

    private static func capture(_ child: ContextChild, executable: String, arguments: [String],
                                input: Data?, timeout: TimeInterval, limit: Int) throws -> Output {
        let process = child.process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        let stdin = input.map { _ in Pipe() }
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        try child.start()
        let deadline = DispatchWorkItem { child.stop(.timeout) }
        DispatchQueue(label: "assistant.context.deadline").asyncAfter(
            deadline: .now() + timeout, execute: deadline
        )
        defer { deadline.cancel(); child.stop(.finished) }
        let output = ContextOutput(stdout, limit: limit, child: child)
        let errors = ContextOutput(stderr, limit: 16_384, child: child)
        if let input, let stdin {
            // A converter that does not consume input must still obey its process deadline.
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        let data = output.value()
        _ = errors.value()
        switch child.reason {
        case .some(.cancelled): throw CancellationError()
        case .some(.timeout): throw MacContextFailure("The local read exceeded its time limit.")
        case .some(.outputLimit): return Output(data: data, truncated: true)
        case .some(.finished), .none:
            guard process.terminationStatus == 0 else {
                // Helper errors can contain private item text. Do not expose stderr.
                throw MacContextFailure("The local application or file helper could not be read.")
            }
            return Output(data: data, truncated: false)
        }
    }
}

private final class ContextOutput: @unchecked Sendable {
    private let group = DispatchGroup()
    private var data = Data()

    init(_ pipe: Pipe, limit: Int, child: ContextChild) {
        group.enter()
        DispatchQueue(label: "assistant.context.output").async { [self] in
            defer { group.leave() }
            while true {
                let block = pipe.fileHandleForReading.readData(ofLength: 8_192)
                guard !block.isEmpty else { return }
                let remaining = max(0, limit - data.count)
                data.append(block.prefix(remaining))
                if block.count > remaining {
                    child.stop(.outputLimit)
                    // Drain after termination so the helper cannot wait on a full pipe.
                }
            }
        }
    }

    func value() -> Data { group.wait(); return data }
}

private final class ContextChild: @unchecked Sendable {
    enum StopReason { case cancelled, timeout, outputLimit, finished }
    let process = Process()
    private let lock = NSLock()
    private var stopReason: StopReason?
    var reason: StopReason? { lock.withLock { stopReason } }

    func start() throws {
        try lock.withLock {
            if stopReason != nil { throw CancellationError() }
            try process.run()
        }
    }

    func stop(_ reason: StopReason) {
        lock.withLock {
            if stopReason == nil { stopReason = reason }
            guard process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue(label: "assistant.context.kill").asyncAfter(deadline: .now() + 1) { [self] in
            lock.withLock {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

struct ContextCommandRunner: Sendable {
    let run: @Sendable (String, [String], Data?, TimeInterval, Int) async throws -> ContextProcess.Output
    static let system = Self { executable, arguments, input, timeout, limit in
        try await ContextProcess.run(executable: executable, arguments: arguments, input: input,
                                     timeout: timeout, limit: limit)
    }
}

public struct MacContextFailure: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}
