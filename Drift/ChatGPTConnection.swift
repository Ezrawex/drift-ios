import SwiftUI
import AuthenticationServices

@MainActor @Observable final class ChatGPTConnection: NSObject, ASWebAuthenticationPresentationContextProviding, PlanAccessProvider {
    static let shared = ChatGPTConnection()
    private(set) var book = ChatGPTCredentialBook()
    private(set) var status = "Not connected"
    private(set) var busy = false
    private(set) var models: [PlanModel] = []
    var modelSlug = ""
    private(set) var testResult: String?
    var showPlanWelcome = false
    private var usableStorage = false
    private let keychain: any ChatGPTCredentialStorage
    private let http: any ChatGPTAuthHTTP
    private var listener: ChatGPTLoopback?
    private var webSession: ASWebAuthenticationSession?
    private var operation: Task<Void, Never>?
    private var refreshTasks: [String: Task<ChatGPTRegistration, Error>] = [:]
    private var generation = UUID()

    var selected: ChatGPTRegistration? { book.registrations.first { $0.id == book.selectedID } }
    var canSignIn: Bool {
        if #available(iOS 17.4, *) { return usableStorage && !busy }
        return false
    }
    var planGranted: Bool { selected?.tokens?.scopes.isSuperset(of: ["resource.invoke", "chatgpt.tokens.use.direct"]) == true }

    init(keychain: any ChatGPTCredentialStorage = ChatGPTKeychain(), http: any ChatGPTAuthHTTP = NativeChatGPTAuthHTTP()) {
        self.keychain = keychain; self.http = http
        super.init()
        do {
            book = try keychain.load(); try keychain.save(book); usableStorage = true
            if selected?.tokens != nil { status = "Saved sign-in · Cloud request not tested this session" }
        } catch { status = ChatGPTAuthError.storage.localizedDescription }
    }

    func signIn(newAccount: Bool = false) {
        guard canSignIn else { return }
        cancel(); busy = true; status = "Opening secure sign-in…"
        let id = generation
        let previous = newAccount ? nil : selected
        let server = ChatGPTLoopback(); listener = server
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let request = try await server.start(hostID: book.hostID, issuedID: previous?.clientID) { [weak self] result in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.received(result, previous: previous, id: id)
                    }
                }
                guard generation == id, !Task.isCancelled else { server.stop(); return }
                pendingRequest = request
                if #available(iOS 17.4, *) {
                    // The documented HTTP return goes to our loopback listener.
                    // Keep the app foregrounded through a system authentication sheet.
                    let session = ASWebAuthenticationSession(url: request.authorizationURL, callback: .customScheme("drift-auth-unused")) { [weak self] _, _ in
                        Task { @MainActor in
                            guard let self, self.generation == id, self.listener != nil else { return }
                            self.cancel(); self.status = "Sign-in was closed. You can try again."
                        }
                    }
                    session.presentationContextProvider = self
                    session.prefersEphemeralWebBrowserSession = true
                    webSession = session
                    guard session.start() else { throw ChatGPTAuthError.cancelled }
                    status = "Finish sign-in in the secure browser"
                } else { throw ChatGPTAuthError.cancelled }
            } catch {
                guard generation == id else { return }
                cancel(); status = error is CancellationError ? "Sign-in was cancelled." : error.localizedDescription
            }
        }
    }
    private var pendingRequest: ChatGPTSignInRequest?

    private func received(_ result: Result<ChatGPTGrant, Error>, previous: ChatGPTRegistration?, id: UUID) {
        listener = nil; webSession?.cancel(); webSession = nil
        guard let request = pendingRequest else { cancel(); return }
        pendingRequest = nil
        operation = Task {
            do {
                let grant = try result.get()
                status = "Verifying ChatGPT identity…"
                let registration = try await ChatGPTCodeExchange(http: http).exchange(grant, request: request, previous: previous)
                // A cancelled request may still be completing a rotating refresh.
                // Finish that atomic update before replacing this registration.
                if let pending = refreshTasks[registration.id] { _ = try? await pending.value }
                guard generation == id, !Task.isCancelled else { return }
                var next = book
                next.registrations.removeAll { $0.id == registration.id }; next.registrations.append(registration)
                next.selectedID = registration.id
                next.uncertainRenewals?.remove(registration.id)
                try commit(next)
                models = []; modelSlug = ""; testResult = nil
                status = planGranted ? "Signed in · Plan permission granted" : "Signed in · ChatGPT plan permission was not granted"
                showPlanWelcome = planGranted && !(book.welcomedIDs ?? []).contains(registration.id)
                busy = false; operation = nil
            } catch {
                guard generation == id else { return }
                busy = false; operation = nil; status = error.localizedDescription
            }
        }
    }

    func cancel() {
        generation = UUID(); operation?.cancel(); operation = nil
        // Do not cancel token renewal: the server may already have invalidated
        // the old refresh token. Its replacement must reach protected storage.
        listener?.stop(); listener = nil; pendingRequest = nil
        webSession?.cancel(); webSession = nil; busy = false
    }
    func choose(_ id: String) {
        guard !busy, book.registrations.contains(where: { $0.id == id }) else { return }
        cancel()
        var next = book; next.selectedID = id
        do { try commit(next); models = []; modelSlug = ""; testResult = nil; status = selected?.tokens == nil ? "Sign in again to continue" : "Saved sign-in · Load models to verify access" }
        catch { status = error.localizedDescription }
    }

    func access() async throws -> PlanAccess {
        let id = generation
        guard usableStorage, let selected, let tokens = selected.tokens,
              tokens.scopes.isSuperset(of: ["resource.invoke", "chatgpt.tokens.use.direct"]) else { throw PlanTransportError.signInRequired }
        if tokens.expiresAt.timeIntervalSinceNow > 120 { return try planAccess(selected) }
        guard !(book.uncertainRenewals ?? []).contains(selected.id) || refreshTasks[selected.id] != nil else {
            throw PlanTransportError.signInRequired
        }
        let task: Task<ChatGPTRegistration, Error>
        if let pending = refreshTasks[selected.id] { task = pending }
        else {
            let http = self.http
            task = Task {
                defer { refreshTasks[selected.id] = nil }
                if let earliest = tokens.earliestRefreshAt, earliest > Date() { throw PlanTransportError.signInRequired }
                // A durable intent marks a crash/timeout after possible rotation.
                // Reauthorization is safer than replaying an uncertain old token.
                var intent = book
                intent.uncertainRenewals = (intent.uncertainRenewals ?? []).union([selected.id])
                try commit(intent)
                let data = try await http.fetch(path: "/api/accounts/oauth/token", form: [
                    "grant_type": "refresh_token", "client_id": selected.clientID, "refresh_token": tokens.refresh,
                    "resource": "https://api.openai.com/v1"
                ])
                let renewed = try ChatGPTTokens.parse(data, previous: tokens)
                if renewed.idToken != tokens.idToken {
                    let jwks = try await http.fetch(path: "/.well-known/jwks.json", form: nil)
                    let identity = try ChatGPTIdentityVerifier.verify(renewed.idToken, jwks: jwks, clientID: selected.clientID, nonce: nil)
                    guard identity.subject == selected.identity.subject else { throw ChatGPTAuthError.invalidIdentity }
                }
                let registration = ChatGPTRegistration(clientID: selected.clientID, identity: selected.identity, tokens: renewed)
                var next = book
                guard let index = next.registrations.firstIndex(where: { $0.id == selected.id }) else { throw PlanTransportError.accountChanged }
                next.registrations[index] = registration
                next.uncertainRenewals?.remove(selected.id)
                do { try commit(next) }
                catch { usableStorage = false; throw error }
                return registration
            }
            refreshTasks[selected.id] = task
        }
        let renewed = try await task.value
        try Task.checkCancellation()
        guard generation == id, book.selectedID == selected.id else { throw PlanTransportError.accountChanged }
        return try planAccess(renewed)
    }
    private func planAccess(_ registration: ChatGPTRegistration) throws -> PlanAccess {
        guard let tokens = registration.tokens else { throw PlanTransportError.signInRequired }
        let result = PlanAccess(accountKey: registration.accountKey, token: tokens.access, scopes: tokens.scopes, expiresAt: tokens.expiresAt)
        _ = try result.authorizedToken(); return result
    }
    private func commit(_ next: ChatGPTCredentialBook) throws { try keychain.save(next); book = next }

    func acknowledgePlan() {
        guard let selected else { showPlanWelcome = false; return }
        var next = book
        next.welcomedIDs = (next.welcomedIDs ?? []).union([selected.id])
        do { try commit(next); showPlanWelcome = false }
        catch { status = error.localizedDescription }
    }

    func loadModels() {
        guard !busy, planGranted else { return }; busy = true
        let id = generation; status = "Checking models available to your account…"
        operation = Task {
            do {
                let result = try await ChatGPTPlanModelCatalog(accessProvider: self, http: URLSessionPlanHTTPTransport()).load()
                guard generation == id, !Task.isCancelled else { return }
                models = result; modelSlug = result.first?.slug ?? ""
                status = "Model access verified · A cloud response is still needed"
            } catch { if generation == id { status = error.localizedDescription } }
            if generation == id { busy = false; operation = nil }
        }
    }
    func testCloud() {
        guard !busy, let model = models.first(where: { $0.slug == modelSlug }) else { return }
        busy = true; testResult = nil; let id = generation; status = "Waiting for a real cloud response…"
        operation = Task {
            do {
                let text = try await ChatGPTPlanProbe.run(model: model, accessProvider: self, http: URLSessionPlanHTTPTransport())
                guard generation == id, !Task.isCancelled else { return }
                testResult = text; status = "Real cloud response received · Mix generation remains demo"
            } catch { if generation == id { status = error.localizedDescription } }
            if generation == id { busy = false; operation = nil }
        }
    }
    func signOut() {
        guard !busy, let selected else { return }
        cancel(); busy = true; let id = generation
        operation = Task {
            // Revoke the latest rotating token, never an invalidated predecessor.
            if let pending = refreshTasks[selected.id] { _ = try? await pending.value }
            guard generation == id else { return }
            let latest = book.registrations.first { $0.id == selected.id }
            let uncertain = (book.uncertainRenewals ?? []).contains(selected.id)
            var revoked = latest?.tokens == nil
            if let tokens = latest?.tokens {
                do {
                    _ = try await http.fetch(path: "/api/accounts/oauth/revoke", form: [
                        "token": tokens.refresh, "token_type_hint": "refresh_token", "client_id": selected.clientID
                    ])
                    revoked = !uncertain
                } catch { /* Clear locally even if the remote service is unavailable. */ }
            }
            guard generation == id else { return }
            do {
                var next = book
                if let index = next.registrations.firstIndex(where: { $0.id == selected.id }) { next.registrations[index].tokens = nil }
                next.uncertainRenewals?.remove(selected.id)
                try commit(next); models = []; modelSlug = ""; testResult = nil
                status = revoked ? "Signed out" : "Signed out locally. Remote revocation was not confirmed; disconnect Drift in ChatGPT Settings."
            } catch { status = error.localizedDescription }
            busy = false; operation = nil
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.windows.first { $0.isKeyWindow } ?? UIWindow()
    }
}

struct ChatGPTConnectionView: View {
    @State private var connection = ChatGPTConnection.shared
    var body: some View {
        List {
            Section {
                Text("Connect your ChatGPT plan").font(.title2.weight(.semibold))
                Text("Drift is open source. This connection uses the official ChatGPT sign-in preview. Compatibility on an iPhone is still being verified.")
                Text("Your mix flow stays in Demo until real music selection is connected.").foregroundStyle(Palette.secondary)
            }
            Section("Connection") {
                Text(connection.status).accessibilityIdentifier("chatGPTStatus")
                if connection.busy {
                    ProgressView().accessibilityLabel("Connecting")
                    Button("Cancel") { connection.cancel() }
                } else {
                    if !connection.book.registrations.isEmpty {
                        Picker("Account", selection: Binding(get: { connection.book.selectedID ?? "" }, set: { connection.choose($0) })) {
                            ForEach(connection.book.registrations) { Text($0.label).tag($0.id) }
                        }
                    }
                    Button { connection.signIn() } label: {
                        Text("Continue with ChatGPT").fontWeight(.semibold).frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).tint(.white).foregroundStyle(.black)
                        .disabled(!connection.canSignIn).accessibilityIdentifier("chatGPTContinue")
                    if #unavailable(iOS 17.4) { Text("This sign-in preview requires iOS 17.4 or later.").font(.footnote) }
                    if !connection.book.registrations.isEmpty {
                        Button("Use a different ChatGPT account") { connection.signIn(newAccount: true) }
                        if connection.selected?.tokens != nil { Button("Sign out", role: .destructive) { connection.signOut() } }
                    }
                }
            }
            if connection.planGranted {
                Section("Verify cloud access") {
                    Label("Using ChatGPT plan", systemImage: "checkmark.shield").font(.subheadline)
                    Button("Load available models") { connection.loadModels() }.disabled(connection.busy)
                    if !connection.models.isEmpty {
                        Picker("Model", selection: $connection.modelSlug) {
                            ForEach(connection.models, id: \.slug) { Text($0.displayName).tag($0.slug) }
                        }.disabled(connection.busy)
                        Button("Test cloud connection") { connection.testCloud() }.disabled(connection.busy)
                    }
                    if let result = connection.testResult { Text(result).textSelection(.enabled) }
                    Text("The test sends a short greeting request, without your playlist. It uses your plan allowance. It does not enable a paid API or purchase credits.").font(.footnote).foregroundStyle(Palette.secondary)
                }
            }
            Section("Privacy and usage") {
                Text("Sign in directly with OpenAI in the system browser. Drift keeps its own credentials in this device’s Keychain. No password is collected by Drift.")
                Text("Connecting grants only the permissions you approve. It does not give Drift access to your ChatGPT conversations.")
                Link("ChatGPT usage and app access", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                Link("Drift source code", destination: URL(string: "https://github.com/Ezrawex/drift-ios")!)
            }
        }.scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle("ChatGPT").navigationBarTitleDisplayMode(.inline)
            .alert("You’re using your ChatGPT plan", isPresented: $connection.showPlanWelcome) {
                Button("Got it") { connection.acknowledgePlan() }
            } message: {
                Text("Eligible cloud requests use your ChatGPT plan. Manage Drift’s access and usage limits in ChatGPT Settings. The mix flow remains demo until real music selection is connected.")
            }
    }
}
