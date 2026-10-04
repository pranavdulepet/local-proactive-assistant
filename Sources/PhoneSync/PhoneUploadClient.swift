#if os(iOS)
import Combine
import CryptoKit
import Foundation
import Security
import UIKit

@MainActor
public final class PhoneUploadClient: NSObject, ObservableObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static let shared = PhoneUploadClient()
    @Published public private(set) var pairing: PhonePairing?
    @Published public private(set) var status = "Pair with your Mac to share phone context."
    @Published public private(set) var lastSynced: Date?
    @Published public private(set) var pendingCount = 0
    public var backgroundCompletion: (() -> Void)?
    private let queue: PhoneUploadQueue?
    private var session: URLSession!
    private var startingUpload = false

    private override init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhoneSync", isDirectory: true)
        queue = try? PhoneUploadQueue(directory: root)
        super.init()
        pairing = try? PairingKeychain.read(PhonePairing.self, account: "phone")
        lastSynced = UserDefaults.standard.object(forKey: "phone.lastSynced") as? Date
        let config = URLSessionConfiguration.background(withIdentifier: "org.localproactiveassistant.phone.upload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        if pairing != nil { status = "Paired. Phone context syncs when your Mac is reachable." }
    }

    public func pair(_ value: PhonePairing) async throws {
        try value.validate()
        for task in await tasks() { task.cancel() }
        try await queue?.reset()
        try PairingKeychain.write(value, account: "phone")
        pairing = value; lastSynced = nil; pendingCount = 0
        UserDefaults.standard.removeObject(forKey: "phone.lastSynced")
        status = "Paired with \(value.name)."
    }

    public func disconnect() async throws {
        for task in await tasks() { task.cancel() }
        try PairingKeychain.remove(account: "phone")
        try await queue?.reset()
        pairing = nil; lastSynced = nil; pendingCount = 0
        UserDefaults.standard.removeObject(forKey: "phone.lastSynced")
        status = "Phone disconnected."
    }

    public func enqueue(sleepEnabled: Bool, sleep: [PhoneSleepDigest]) async throws {
        guard let pairing, let queue else { throw PhoneSyncFailure("Pair with your Mac first.") }
        _ = try await queue.enqueue(pairing: pairing, sleepEnabled: sleepEnabled, sleep: sleep)
        await uploadNext()
    }

    public func retry() async { await uploadNext() }

    private func tasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    private func uploadNext() async {
        guard let pairing, let queue, !startingUpload else { return }
        startingUpload = true
        defer { startingUpload = false }
        do {
            let files = try await queue.pending()
            pendingCount = files.count
            guard !files.isEmpty else { return }
            guard await tasks().isEmpty else { status = "Syncing phone context…"; return }
            var request = URLRequest(url: pairing.server.appendingPathComponent("phone-context"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + pairing.token, forHTTPHeaderField: "Authorization")
            let attributes = try FileManager.default.attributesOfItem(atPath: files[0].path)
            request.setValue(String((attributes[.size] as? NSNumber)?.intValue ?? 0), forHTTPHeaderField: "Content-Length")
            let task = session.uploadTask(with: request, fromFile: files[0])
            task.taskDescription = files[0].lastPathComponent
            status = "Syncing phone context…"
            task.resume()
        } catch { status = "Could not queue phone context. Open the companion again to retry." }
    }

    nonisolated public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0),
              let pairing = try? PairingKeychain.read(PhonePairing.self, account: "phone"),
              challenge.protectionSpace.host == pairing.server.host else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard fingerprint == pairing.certificateSHA256 else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let response = task.response as? HTTPURLResponse
        let sequence = task.taskDescription.flatMap { Int64(($0 as NSString).deletingPathExtension) }
        let acknowledged = response?.value(forHTTPHeaderField: "X-Acknowledged-Sequence").flatMap(Int64.init)
        let success = error == nil && response?.statusCode == 200
        Task { @MainActor [self] in
            guard pairing != nil, let queue else { return }
            if success, let sequence, let acknowledged, acknowledged >= sequence {
                do {
                    try await queue.acknowledge(acknowledged)
                    lastSynced = Date()
                    UserDefaults.standard.set(lastSynced, forKey: "phone.lastSynced")
                    pendingCount = try await queue.pending().count
                    status = "Phone context received by your Mac. Ask about it in Messages."
                    await uploadNext()
                } catch { status = "The Mac received context, but the local queue could not be updated." }
            } else if response?.statusCode == 401 {
                status = "Pairing was revoked. Pair with your Mac again."
            } else {
                pendingCount = (try? await queue.pending().count) ?? pendingCount
                status = "Waiting for your Mac. Updates stay queued on this phone."
            }
        }
    }

    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [self] in
            backgroundCompletion?(); backgroundCompletion = nil
        }
    }
}
#endif
