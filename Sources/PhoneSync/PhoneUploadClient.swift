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
    private var pairingChanging = false
    private var pairingGeneration: UInt64 = 0
    private var queueMutations = 0
    private var queueDrainWaiters: [CheckedContinuation<Void, Never>] = []

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
        guard !pairingChanging else { throw PhoneSyncFailure("A pairing change is already in progress.") }
        pairingChanging = true
        pairingGeneration &+= 1
        pairing = nil
        defer { pairingChanging = false }
        for task in await tasks() { task.cancel() }
        await drainQueueMutations()
        try await queue?.reset()
        try PairingKeychain.write(value, account: "phone")
        pairing = value; lastSynced = nil; pendingCount = 0
        UserDefaults.standard.removeObject(forKey: "phone.lastSynced")
        status = "Paired with \(value.name)."
    }

    public func disconnect() async throws {
        guard !pairingChanging else { throw PhoneSyncFailure("A pairing change is already in progress.") }
        pairingChanging = true
        pairingGeneration &+= 1
        pairing = nil
        defer { pairingChanging = false }
        for task in await tasks() { task.cancel() }
        await drainQueueMutations()
        try PairingKeychain.remove(account: "phone")
        try await queue?.reset()
        pairing = nil; lastSynced = nil; pendingCount = 0
        UserDefaults.standard.removeObject(forKey: "phone.lastSynced")
        status = "Phone disconnected."
    }

    public func enqueue(sleepEnabled: Bool, sleep: [PhoneSleepDigest],
                        activityEnabled: Bool? = nil, activity: PhoneActivityDigest? = nil,
                        locationEnabled: Bool? = nil, location: PhoneLocationDigest? = nil) async throws {
        guard !pairingChanging, let pairing, let queue else { throw PhoneSyncFailure("Pair with your Mac first.") }
        let generation = pairingGeneration
        queueMutations += 1
        do {
            _ = try await queue.enqueue(pairing: pairing, sleepEnabled: sleepEnabled, sleep: sleep,
                activityEnabled: activityEnabled, activity: activity, locationEnabled: locationEnabled, location: location)
        } catch {
            finishQueueMutation()
            throw error
        }
        finishQueueMutation()
        guard generation == pairingGeneration, self.pairing == pairing, !pairingChanging else { return }
        await uploadNext()
    }

    public func retry() async { await uploadNext() }

    private func tasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    private func uploadNext() async {
        guard !pairingChanging, let pairing, let queue, !startingUpload else { return }
        let generation = pairingGeneration
        startingUpload = true
        defer {
            startingUpload = false
            if generation != pairingGeneration, self.pairing != nil, !pairingChanging {
                Task { [weak self] in await self?.uploadNext() }
            }
        }
        do {
            let files = try await queue.pending()
            guard generation == pairingGeneration, self.pairing == pairing, !pairingChanging else { return }
            pendingCount = files.count
            guard !files.isEmpty else { return }
            let existingTasks = await tasks()
            guard generation == pairingGeneration, self.pairing == pairing, !pairingChanging else { return }
            guard existingTasks.isEmpty else { status = "Syncing phone context…"; return }
            var request = URLRequest(url: pairing.server.appendingPathComponent("phone-context"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + pairing.token, forHTTPHeaderField: "Authorization")
            let attributes = try FileManager.default.attributesOfItem(atPath: files[0].path)
            request.setValue(String((attributes[.size] as? NSNumber)?.intValue ?? 0), forHTTPHeaderField: "Content-Length")
            let task = session.uploadTask(with: request, fromFile: files[0])
            let sequence = (files[0].lastPathComponent as NSString).deletingPathExtension
            task.taskDescription = Self.identity(of: pairing) + ":" + sequence
            status = "Syncing phone context…"
            task.resume()
        } catch {
            if generation == pairingGeneration, self.pairing == pairing {
                status = "Could not queue phone context. Open the companion again to retry."
            }
        }
    }

    nonisolated private static func identity(of pairing: PhonePairing) -> String {
        let identity = [pairing.deviceID.uuidString, pairing.server.absoluteString,
            pairing.certificateSHA256, pairing.token].joined(separator: "\n")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func drainQueueMutations() async {
        guard queueMutations > 0 else { return }
        await withCheckedContinuation { queueDrainWaiters.append($0) }
    }

    private func finishQueueMutation() {
        queueMutations -= 1
        guard queueMutations == 0 else { return }
        let waiters = queueDrainWaiters
        queueDrainWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func acknowledge(_ sequence: Int64, identity: String, generation: UInt64) async throws -> Bool {
        guard !pairingChanging, generation == pairingGeneration,
              let pairing, Self.identity(of: pairing) == identity, let queue else { return false }
        queueMutations += 1
        defer { finishQueueMutation() }
        try await queue.acknowledge(sequence)
        return !pairingChanging && generation == pairingGeneration
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
        let description = task.taskDescription?.split(separator: ":", maxSplits: 1)
        let identity = description?.count == 2 ? description.map { String($0[0]) } : nil
        let sequence = description?.count == 2 ? description.flatMap { Int64($0[1]) } : nil
        let acknowledged = response?.value(forHTTPHeaderField: "X-Acknowledged-Sequence").flatMap(Int64.init)
        let success = error == nil && response?.statusCode == 200
        Task { @MainActor [self] in
            guard !pairingChanging, let pairing, let queue else { return }
            let generation = pairingGeneration
            guard let identity, identity == Self.identity(of: pairing) else {
                // An old pairing or pre-upgrade task cannot acknowledge this
                // queue. Preserve its files and retry against the current Mac.
                await uploadNext()
                return
            }
            if success, let sequence, let acknowledged, acknowledged >= sequence {
                do {
                    guard try await acknowledge(acknowledged, identity: identity, generation: generation) else { return }
                    let count = try await queue.pending().count
                    guard generation == pairingGeneration, self.pairing == pairing, !pairingChanging else { return }
                    lastSynced = Date()
                    UserDefaults.standard.set(lastSynced, forKey: "phone.lastSynced")
                    pendingCount = count
                    status = "Phone context received by your Mac. Ask about it in Messages."
                    await uploadNext()
                } catch {
                    if generation == pairingGeneration, self.pairing == pairing {
                        status = "The Mac received context, but the local queue could not be updated."
                    }
                }
            } else if response?.statusCode == 401 {
                status = "Pairing was revoked. Pair with your Mac again."
            } else {
                let count = try? await queue.pending().count
                guard generation == pairingGeneration, self.pairing == pairing, !pairingChanging else { return }
                pendingCount = count ?? pendingCount
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
