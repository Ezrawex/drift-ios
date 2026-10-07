import Foundation
import Security

enum ChatGPTAuthError: LocalizedError, Equatable {
    case invalidCallback, denied, incompleteRegistration, invalidIdentity, invalidTokens, storage, timeout, cancelled
    case provider(Int)
    var errorDescription: String? {
        switch self {
        case .invalidCallback: "The sign-in return could not be verified. Please start again."
        case .denied: "ChatGPT sign-in was declined. Nothing was connected."
        case .incompleteRegistration: "ChatGPT did not return a complete app registration. Please start again."
        case .invalidIdentity: "The ChatGPT account identity could not be verified. Nothing was connected."
        case .invalidTokens: "ChatGPT returned incomplete credentials. Please sign in again."
        case .storage: "Drift could not safely save the connection in Keychain. Please try again."
        case .timeout: "Sign-in timed out. Please start again."
        case .cancelled: "Sign-in was cancelled."
        case .provider(let status): "ChatGPT connection failed (HTTP \(status)). Please try again."
        }
    }
}

struct ChatGPTGrant: Sendable {
    let code: String
    let clientID: String

    static func parse(_ url: URL, request: ChatGPTSignInRequest, issuedClientID: String?) throws -> Self {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http", components.host == "127.0.0.1",
              components.port == request.redirectURI.port, components.path == "/auth/callback",
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw ChatGPTAuthError.invalidCallback
        }
        let items = components.queryItems ?? []
        for key in ["state", "code", "client_id", "error", "scope"] {
            guard items.filter({ $0.name == key }).count <= 1 else { throw ChatGPTAuthError.invalidCallback }
        }
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        guard value("state") == request.state else { throw ChatGPTAuthError.invalidCallback }
        if let error = value("error") {
            guard value("code") == nil else { throw ChatGPTAuthError.invalidCallback }
            if error == "access_denied" { throw ChatGPTAuthError.denied }
            throw ChatGPTAuthError.incompleteRegistration
        }
        guard let code = value("code"), !code.isEmpty, code.utf8.count <= 4096 else { throw ChatGPTAuthError.invalidCallback }
        let client = value("client_id") ?? issuedClientID
        guard let client, !client.isEmpty, client != "dynamic_agent_client", client.utf8.count <= 1024,
              client.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              issuedClientID == nil || issuedClientID == client else { throw ChatGPTAuthError.incompleteRegistration }
        return Self(code: code, clientID: client)
    }
}

struct ChatGPTIdentity: Codable, Equatable, Sendable {
    let subject: String
    let email: String?
}

// Native Security verifies RS256, the algorithm advertised by OpenAI's current
// discovery document. No unsigned claim or token-provided key URL is trusted.
enum ChatGPTIdentityVerifier {
    static func verify(_ token: String, jwks: Data, clientID: String, nonce: String?, now: Date = Date()) throws -> ChatGPTIdentity {
        guard token.utf8.count <= 32_768, jwks.count <= 1_000_000 else { throw ChatGPTAuthError.invalidIdentity }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = decode(String(parts[0])), let claimsData = decode(String(parts[1])),
              let signature = decode(String(parts[2])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String, !kid.isEmpty,
              header["crit"] == nil, header["jku"] == nil, header["jwk"] == nil,
              let document = try? JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let keys = document["keys"] as? [[String: Any]] else { throw ChatGPTAuthError.invalidIdentity }
        let matching = keys.filter { $0["kid"] as? String == kid }
        guard matching.count == 1, let key = matching.first,
              key["kty"] as? String == "RSA", key["alg"] as? String == "RS256",
              key["use"] as? String == "sig", let n = key["n"] as? String, let e = key["e"] as? String,
              let modulus = decode(n), let exponent = decode(e),
              (256...1024).contains(modulus.count), !exponent.isEmpty, exponent.count <= 8 else { throw ChatGPTAuthError.invalidIdentity }
        let der = tagged(0x30, integer(modulus) + integer(exponent))
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                  Data("\(parts[0]).\(parts[1])".utf8) as CFData, signature as CFData, nil),
              let claims = try? JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              claims["iss"] as? String == "https://auth.openai.com",
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let expiry = number(claims["exp"]), expiry > now.timeIntervalSince1970 - 5,
              let issued = number(claims["iat"]), issued <= now.timeIntervalSince1970 + 5, issued < expiry else {
            throw ChatGPTAuthError.invalidIdentity
        }
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audience.contains(clientID), !clientID.isEmpty,
              audience.count <= 1 || claims["azp"] as? String == clientID,
              claims["azp"] == nil || claims["azp"] as? String == clientID else { throw ChatGPTAuthError.invalidIdentity }
        if let nonce { guard claims["nonce"] as? String == nonce else { throw ChatGPTAuthError.invalidIdentity } }
        if claims["nbf"] != nil {
            guard let notBefore = number(claims["nbf"]), notBefore <= now.timeIntervalSince1970 + 5 else { throw ChatGPTAuthError.invalidIdentity }
        }
        return ChatGPTIdentity(subject: subject, email: claims["email"] as? String)
    }

    static func decode(_ text: String) -> Data? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: padded)
    }
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    private static func integer(_ data: Data) -> Data {
        var bytes = Data(data.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes[bytes.startIndex] & 0x80 != 0 { bytes.insert(0, at: bytes.startIndex) }
        return tagged(0x02, bytes)
    }
    private static func tagged(_ tag: UInt8, _ value: Data) -> Data {
        var length: [UInt8] = []
        if value.count < 128 { length = [UInt8(value.count)] }
        else {
            var n = value.count
            while n > 0 { length.insert(UInt8(n & 255), at: 0); n >>= 8 }
            length.insert(0x80 | UInt8(length.count), at: 0)
        }
        return Data([tag] + length) + value
    }
}
