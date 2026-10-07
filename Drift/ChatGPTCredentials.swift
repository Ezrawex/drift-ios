import Foundation
import Security
import CryptoKit

struct ChatGPTRegistration: Codable, Sendable, Identifiable {
    let clientID: String
    let identity: ChatGPTIdentity
    var tokens: ChatGPTTokens?
    var id: String { clientID + ":" + identity.subject }
    var label: String { (identity.email ?? "ChatGPT account") + " · " + String(clientID.suffix(6)) }
    var accountKey: String { SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() }
}

struct ChatGPTTokens: Codable, Sendable {
    let access: String
    let refresh: String
    let idToken: String
    let scopes: Set<String>
    let expiresAt: Date
    let earliestRefreshAt: Date?

    static func parse(_ data: Data, now: Date = Date(), previous: ChatGPTTokens? = nil) throws -> Self {
        guard data.count <= 131_072,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["token_type"] as? String == "Bearer",
              let access = object["access_token"] as? String, valid(access),
              let refresh = object["refresh_token"] as? String, valid(refresh),
              let idToken = object["id_token"] as? String ?? previous?.idToken, valid(idToken),
              let expires = object["expires_in"] as? Int, (61...86_400).contains(expires) else { throw ChatGPTAuthError.invalidTokens }
        let scopes: Set<String>
        if let value = object["scope"] as? String { scopes = Set(value.split(separator: " ").map(String.init)) }
        else if let previous { scopes = previous.scopes }
        else { throw ChatGPTAuthError.invalidTokens }
        guard scopes.contains("openid") else { throw ChatGPTAuthError.invalidTokens }
        let earliest = (object["earliest_refresh_at"] as? Double).map(Date.init(timeIntervalSince1970:))
        if let earliest, !earliest.timeIntervalSince1970.isFinite { throw ChatGPTAuthError.invalidTokens }
        return Self(access: access, refresh: refresh, idToken: idToken, scopes: scopes,
                    expiresAt: now.addingTimeInterval(Double(expires)), earliestRefreshAt: earliest)
    }
    private static func valid(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 32_768 && token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }
}

struct ChatGPTCredentialBook: Codable {
    var hostID = UUID()
    var registrations: [ChatGPTRegistration] = []
    var selectedID: String?
    var welcomedIDs: Set<String>?
    var uncertainRenewals: Set<String>?
}

protocol ChatGPTCredentialStorage: Sendable {
    func load() throws -> ChatGPTCredentialBook
    func save(_ book: ChatGPTCredentialBook) throws
}

// One atomic record preserves rotating credentials and host identity together.
// Tokens never enter UserDefaults, cloud sync, app files, logs or analytics.
struct ChatGPTKeychain: ChatGPTCredentialStorage {
    var service = "com.ezra.drift.chatgpt"
    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: "credential-book", kSecAttrSynchronizable: false]
    }
    func load() throws -> ChatGPTCredentialBook {
        var search = query
        search[kSecReturnData] = true; search[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return ChatGPTCredentialBook() }
        guard status == errSecSuccess, let data = result as? Data,
              let book = try? JSONDecoder().decode(ChatGPTCredentialBook.self, from: data) else { throw ChatGPTAuthError.storage }
        return book
    }
    func save(_ book: ChatGPTCredentialBook) throws {
        let data = try JSONEncoder().encode(book)
        let values: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            values.forEach { insertion[$0.key] = $0.value }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw ChatGPTAuthError.storage }
        } else if status != errSecSuccess { throw ChatGPTAuthError.storage }
    }
}

protocol ChatGPTAuthHTTP: Sendable {
    func fetch(path: String, form: [String: String]?) async throws -> Data
}

final class NativeChatGPTAuthHTTP: NSObject, ChatGPTAuthHTTP, URLSessionTaskDelegate, @unchecked Sendable {
    func fetch(path: String, form: [String: String]? = nil) async throws -> Data {
        guard ["/.well-known/jwks.json", "/api/accounts/oauth/token", "/api/accounts/oauth/revoke"].contains(path) else {
            throw ChatGPTAuthError.invalidTokens
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://auth.openai.com" + path)!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(form)
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url == request.url else { throw ChatGPTAuthError.invalidTokens }
        guard response.statusCode == 200 else { throw ChatGPTAuthError.provider(response.statusCode) }
        var data = Data()
        let limit = path == "/.well-known/jwks.json" ? 1_000_000 : 131_072
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw ChatGPTAuthError.invalidTokens }
            data.append(byte)
        }
        return data
    }
    static func form(_ fields: [String: String]) -> Data {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: safe)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: safe)!
        }.joined(separator: "&").utf8)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct ChatGPTCodeExchange: Sendable {
    let http: any ChatGPTAuthHTTP
    func exchange(_ grant: ChatGPTGrant, request: ChatGPTSignInRequest, previous: ChatGPTRegistration?) async throws -> ChatGPTRegistration {
        let data = try await http.fetch(path: "/api/accounts/oauth/token", form: [
            "grant_type": "authorization_code", "client_id": grant.clientID, "code": grant.code,
            "code_verifier": request.verifier, "redirect_uri": request.redirectURI.absoluteString, "resource": "https://api.openai.com/v1"
        ])
        let tokens = try ChatGPTTokens.parse(data)
        let jwks = try await http.fetch(path: "/.well-known/jwks.json", form: nil)
        let identity = try ChatGPTIdentityVerifier.verify(tokens.idToken, jwks: jwks, clientID: grant.clientID, nonce: request.nonce)
        if let previous {
            guard previous.clientID == grant.clientID, previous.identity.subject == identity.subject else { throw ChatGPTAuthError.invalidIdentity }
        }
        try Task.checkCancellation()
        return ChatGPTRegistration(clientID: grant.clientID, identity: identity, tokens: tokens)
    }
}
