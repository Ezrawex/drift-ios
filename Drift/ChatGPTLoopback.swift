import Foundation
import Network

// Listener lives in the iPhone app. It never binds to the LAN or accepts tokens
// from another host. The code is consumed once, only after state validation.
final class ChatGPTLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ezra.drift.chatgpt-callback")
    private var listener: NWListener?
    private var ready: CheckedContinuation<ChatGPTSignInRequest, Error>?
    private var request: ChatGPTSignInRequest?
    private var issuedID: String?
    private var connections: [UUID: NWConnection] = [:]
    private var completion: (@Sendable (Result<ChatGPTGrant, Error>) -> Void)?
    private var finished = false
    private var consuming = false

    func start(hostID: UUID, issuedID: String?, timeout: TimeInterval = 600,
               completion: @escaping @Sendable (Result<ChatGPTGrant, Error>) -> Void) async throws -> ChatGPTSignInRequest {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.listener == nil, !self.finished else { continuation.resume(throwing: ChatGPTAuthError.cancelled); return }
                self.ready = continuation; self.issuedID = issuedID; self.completion = completion
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters); self.listener = listener
                    listener.stateUpdateHandler = { [weak self, weak listener] status in
                        guard let self, let listener else { return }
                        switch status {
                        case .ready:
                            do {
                                guard let port = listener.port?.rawValue else { throw ChatGPTAuthError.invalidCallback }
                                let request = try ChatGPTSignInRequest(port: port, hostID: hostID, issuedClientID: issuedID)
                                self.request = request; self.ready?.resume(returning: request); self.ready = nil
                            } catch { self.finish(.failure(error)) }
                        case .failed(let error): self.finish(.failure(error))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(ChatGPTAuthError.timeout)) }
                } catch { self.finish(.failure(error)) }
            }
        }
    }
    func stop() { queue.async { self.finish(.failure(ChatGPTAuthError.cancelled)) } }

    private func accept(_ connection: NWConnection) {
        guard !finished, !consuming, connections.count < 4 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue); receive(connection, id: id, buffer: Data())
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.connections.removeValue(forKey: id)?.cancel() }
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, !self.finished, !self.consuming, self.connections[id] != nil else { return }
            var buffer = buffer; if let data { buffer.append(data) }
            guard buffer.count <= 16_384, error == nil else { self.connections.removeValue(forKey: id)?.cancel(); return }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)), let request = self.request,
               let header = String(data: buffer[..<end.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n"), parts = (header.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
                let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
                guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1", parts[1].hasPrefix("/auth/callback?"),
                      hosts.count == 1, hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(request.redirectURI.port!)",
                      let url = URL(string: "http://127.0.0.1:\(request.redirectURI.port!)\(parts[1])") else {
                    self.reply(connection, id: id, result: nil); return
                }
                do { self.reply(connection, id: id, result: .success(try ChatGPTGrant.parse(url, request: request, issuedClientID: self.issuedID))) }
                catch ChatGPTAuthError.denied { self.reply(connection, id: id, result: .failure(ChatGPTAuthError.denied)) }
                catch ChatGPTAuthError.incompleteRegistration { self.reply(connection, id: id, result: .failure(ChatGPTAuthError.incompleteRegistration)) }
                catch { self.reply(connection, id: id, result: nil) }
            } else if complete { self.connections.removeValue(forKey: id)?.cancel() }
            else { self.receive(connection, id: id, buffer: buffer) }
        }
    }
    private func reply(_ connection: NWConnection, id: UUID, result: Result<ChatGPTGrant, Error>?) {
        if result != nil { consuming = true; listener?.cancel() }
        let body = result == nil ? "Invalid sign-in return. Return to Drift and try again." : "Sign-in return received. Return to Drift to finish verifying the connection."
        let response = "HTTP/1.1 \(result == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.connections.removeValue(forKey: id)?.cancel()
            if let result { self.finish(result) }
        })
    }
    private func finish(_ result: Result<ChatGPTGrant, Error>) {
        guard !finished else { return }; finished = true
        listener?.cancel(); listener = nil; request = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        ready?.resume(throwing: ChatGPTAuthError.cancelled); ready = nil
        let callback = completion; completion = nil; callback?(result)
    }
}
