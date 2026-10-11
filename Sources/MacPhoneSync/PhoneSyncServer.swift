#if os(macOS)
import AssistantStore
import Foundation
import Network
import PhoneSync
import Security

/// Receives only typed phone summaries. No model, message, or action endpoint is exposed.
public final class PhoneSyncServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "assistant.phone.listener")
    private let store: ObservationStore
    private var connections: [UUID: UploadConnection] = [:] // listener queue only

    public init(identity: MacPhoneIdentity, store: ObservationStore) throws {
        self.store = store
        let tls = NWProtocolTLS.Options()
        guard let secured = sec_identity_create(try identity.securityIdentity()) else { throw PhoneSyncFailure("Could not configure phone TLS.") }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secured)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let port = NWEndpoint.Port(rawValue: UInt16(identity.pairing.server.port ?? 8765))!
        listener = try NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()), on: port)
        listener.service = NWListener.Service(name: identity.pairing.name, type: "_lpa-sync._tcp")
    }

    public func start() {
        listener.stateUpdateHandler = { state in
            if case .failed = state { print("Phone sync unavailable; check the local network or port. Messages remain available.") }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.connections.count < 16 else { connection.cancel(); return }
            let id = UUID()
            let upload = UploadConnection(connection: connection, queue: self.queue, store: self.store) { [weak self] in
                self?.connections.removeValue(forKey: id)
            }
            self.connections[id] = upload
            upload.start()
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
        queue.async { [self] in
            for connection in Array(connections.values) { connection.close() }
        }
    }
}

/// Mutable parser state is confined to its serial listener queue.
private final class UploadConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let store: ObservationStore
    private let onClose: @Sendable () -> Void
    private var data = Data()
    private var closed = false
    private var timeout: DispatchWorkItem?

    init(connection: NWConnection, queue: DispatchQueue, store: ObservationStore, onClose: @escaping @Sendable () -> Void) {
        self.connection = connection; self.queue = queue; self.store = store; self.onClose = onClose
    }

    func start() {
        let deadline = DispatchWorkItem { [weak self] in self?.close() }
        timeout = deadline
        queue.asyncAfter(deadline: .now() + 20, execute: deadline)
        connection.start(queue: queue)
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true; timeout?.cancel(); connection.cancel(); onClose()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] content, _, complete, error in
            guard !closed else { return }
            if let content { data.append(content) }
            guard data.count <= PhoneSyncEnvelope.maximumBytes + 4096 else { respond(413); return }
            if let separator = data.range(of: Data("\r\n\r\n".utf8)) {
                guard separator.lowerBound <= 4096, let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else { respond(400); return }
                let lines = header.components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let pair = line.split(separator: ":", maxSplits: 1)
                    guard pair.count == 2 else { respond(400); return }
                    let name = pair[0].lowercased()
                    guard headers[name] == nil else { respond(400); return }
                    headers[name] = pair[1].trimmingCharacters(in: .whitespaces)
                }
                guard lines.first == "POST /phone-context HTTP/1.1", headers["transfer-encoding"] == nil,
                      let rawLength = headers["content-length"], let length = Int(rawLength), length > 0,
                      length <= PhoneSyncEnvelope.maximumBytes else { respond(400); return }
                let expected = separator.upperBound + length
                if data.count == expected {
                    accept(Data(data[separator.upperBound..<expected]), authorization: headers["authorization"])
                    return
                }
                if data.count > expected { respond(400); return }
            }
            if complete || error != nil { close() } else { receive() }
        }
    }

    private func accept(_ body: Data, authorization: String?) {
        do {
            guard let identity = try MacPhoneIdentity.load(),
                  let authorization, constantTimeEqual(authorization, "Bearer " + identity.pairing.token) else { respond(401); return }
            let envelope = try PhoneSyncEnvelope.decode(body)
            guard envelope.deviceID == identity.pairing.deviceID else { respond(401); return }
            Task { [self] in
                do {
                    let acknowledged = try await store.acceptPhoneContext(envelope)
                    queue.async { [self] in respond(200, sequence: acknowledged) }
                } catch { queue.async { [self] in respond(500) } }
            }
        } catch { respond(400) }
    }

    private func respond(_ status: Int, sequence: Int64? = nil) {
        guard !closed else { return }
        let acknowledgment = sequence.map { "X-Acknowledged-Sequence: \($0)\r\n" } ?? ""
        let response = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n\(acknowledgment)Content-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [self] _ in close() })
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
#endif
