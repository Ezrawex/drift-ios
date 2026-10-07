import Foundation
import CryptoKit
import Security

// Request preparation only. No provider call or eligibility assumption is made here.
struct ChatGPTSignInRequest: Sendable {
    let state: String
    let nonce: String
    let verifier: String
    let redirectURI: URL
    let authorizationURL: URL

    enum PreparationFailure: Error { case randomUnavailable, invalidRegistration }

    init(port: UInt16, hostID: UUID, appName: String = "Drift", issuedClientID: String? = nil) throws {
        guard port != 0, !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              issuedClientID == nil || (issuedClientID != "dynamic_agent_client"
                && issuedClientID?.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                && !(issuedClientID?.isEmpty ?? true)) else {
            throw PreparationFailure.invalidRegistration
        }
        state = try Self.randomValue()
        nonce = try Self.randomValue()
        verifier = try Self.randomValue()
        redirectURI = URL(string: "http://127.0.0.1:\(port)/auth/callback")!
        var url = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        var items = [
            URLQueryItem(name: "client_id", value: issuedClientID ?? "dynamic_agent_client"),
            URLQueryItem(name: "ext_agent_host_id", value: "urn:uuid:\(hostID.uuidString.lowercased())"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
            URLQueryItem(name: "resource", value: "https://api.openai.com/v1"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(verifier))
        ]
        if issuedClientID == nil { items.append(URLQueryItem(name: "agent_name_hint", value: appName)) }
        url.queryItems = items
        // OAuth servers commonly parse query values as forms, where a literal + is a space.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        authorizationURL = url.url!
    }

    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PreparationFailure.randomUnavailable
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
