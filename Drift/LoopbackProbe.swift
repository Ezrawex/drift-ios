#if DEBUG
import Foundation
import Network

// Local platform diagnostic only. This does not contact or authenticate with OpenAI.
enum ProbeCallback: Equatable, Sendable {
    case code
    case denied
}

enum ProbeFailure: Error, Equatable {
    case invalidRequest, wrongState, incompleteRegistration, cancelled, timeout
}

struct ProbeRequest {
    static func validate(_ header: String, port: UInt16, state: String) throws -> ProbeCallback {
        let lines = header.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1",
              parts[1].hasPrefix("/auth/callback?"),
              let url = URLComponents(string: "http://127.0.0.1:\(port)\(parts[1])"),
              url.path == "/auth/callback", url.fragment == nil else { throw ProbeFailure.invalidRequest }
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard hosts.count == 1,
              hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(port)" else {
            throw ProbeFailure.invalidRequest
        }
        let items = url.queryItems ?? []
        for key in ["state", "code", "client_id", "error"] {
            guard items.filter({ $0.name == key }).count <= 1 else { throw ProbeFailure.invalidRequest }
        }
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        guard value("state") == state else { throw ProbeFailure.wrongState }
        if let error = value("error") {
            guard error == "access_denied", value("code") == nil else { throw ProbeFailure.invalidRequest }
            return .denied
        }
        guard let code = value("code"), !code.isEmpty, code.count <= 4096,
              let client = value("client_id"), !client.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              client.count <= 1024, client != "dynamic_agent_client" else {
            throw ProbeFailure.incompleteRegistration
        }
        return .code
    }
}

// All mutable state below is confined to queue, including cancellation and callbacks.
final class LoopbackProbeServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.example.drift.loopback-probe")
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var result: (@Sendable (Result<ProbeCallback, Error>) -> Void)?
    private var state = ""
    private var port: UInt16 = 0
    private var finished = false

    func start(state: String, timeout: TimeInterval = 60,
               result: @escaping @Sendable (Result<ProbeCallback, Error>) -> Void) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.listener == nil, !self.finished else {
                    continuation.resume(throwing: ProbeFailure.cancelled); return
                }
                self.ready = continuation
                self.state = state
                self.result = result
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self, weak listener] status in
                        guard let self, let listener else { return }
                        switch status {
                        case .ready:
                            guard let port = listener.port?.rawValue else { self.finish(.failure(ProbeFailure.invalidRequest)); return }
                            self.port = port
                            self.ready?.resume(returning: port); self.ready = nil
                        case .failed(let error): self.finish(.failure(error))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(.failure(ProbeFailure.timeout))
                    }
                } catch { self.finish(.failure(error)) }
            }
        }
    }

    func stop() { queue.async { self.finish(.failure(ProbeFailure.cancelled)) } }

    private func accept(_ connection: NWConnection) {
        guard !finished, connections.count < 4 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receive(connection, id: id, buffer: Data())
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.connections.removeValue(forKey: id)?.cancel()
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil, !self.finished else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 8192, error == nil else { self.connections.removeValue(forKey: id)?.cancel(); return }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: buffer[..<range.lowerBound], encoding: .utf8) {
                do {
                    let callback = try ProbeRequest.validate(header, port: self.port, state: self.state)
                    self.reply(connection, id: id, accepted: true, callback: callback)
                } catch { self.reply(connection, id: id, accepted: false, callback: nil) }
            } else if complete { self.connections.removeValue(forKey: id)?.cancel() }
            else { self.receive(connection, id: id, buffer: buffer) }
        }
    }

    private func reply(_ connection: NWConnection, id: UUID, accepted: Bool, callback: ProbeCallback?) {
        let body = accepted
            ? "Drift local callback received. Return to Drift. No OpenAI account was connected."
            : "Invalid local test callback. Return to Drift and start a new test."
        let response = "HTTP/1.1 \(accepted ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.connections.removeValue(forKey: id)?.cancel()
            if let callback { self.finish(.success(callback)) }
        })
    }

    private func finish(_ value: Result<ProbeCallback, Error>) {
        guard !finished else { return }
        finished = true
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        ready?.resume(throwing: value.failure ?? ProbeFailure.cancelled); ready = nil
        let completion = result; result = nil
        completion?(value)
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let value) = self { value } else { nil } }
}
#endif
