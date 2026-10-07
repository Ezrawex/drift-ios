#if DEBUG
import SwiftUI
import AuthenticationServices

@MainActor @Observable final class CallbackProbeModel: NSObject, ASWebAuthenticationPresentationContextProviding {
    var status = "Ready for a local test"
    var callbackURL: URL?
    var backgroundCount = 0
    private var server: LoopbackProbeServer?
    private var webSession: ASWebAuthenticationSession?
    private var attempt = UUID()

    func prepare() async {
        cancel()
        let id = UUID(); attempt = id
        let state = UUID().uuidString + UUID().uuidString
        let server = LoopbackProbeServer(); self.server = server
        status = "Starting listener…"
        do {
            let port = try await server.start(state: state) { [weak self] result in
                Task { @MainActor in
                    guard let self, self.attempt == id else { return }
                    self.callbackURL = nil; self.server = nil
                    self.webSession?.cancel(); self.webSession = nil
                    switch result {
                    case .success(.code): self.status = "Local callback received"
                    case .success(.denied): self.status = "Local denial received"
                    case .failure(ProbeFailure.timeout): self.status = "Test timed out. Start again."
                    case .failure: self.status = "Local test stopped. Start again."
                    }
                }
            }
            guard attempt == id else { server.stop(); return }
            var url = URLComponents(string: "http://127.0.0.1:\(port)/auth/callback")!
            url.queryItems = [URLQueryItem(name: "code", value: "local-test-only"),
                              URLQueryItem(name: "state", value: state),
                              URLQueryItem(name: "client_id", value: "local-test-client")]
            callbackURL = url.url
            status = "Listener ready on 127.0.0.1"
        } catch { if attempt == id { status = "Listener could not start." } }
    }

    func cancel() {
        attempt = UUID(); server?.stop(); server = nil; callbackURL = nil
        webSession?.cancel(); webSession = nil
        status = "Ready for a local test"
    }

    func openSystemBrowser() {
        guard webSession == nil, let url = callbackURL, #available(iOS 17.4, *) else { return }
        let id = attempt
        // The documented HTTP redirect is received by our listener, not this custom-scheme callback.
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("drift-local-probe")) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.attempt == id, self.server != nil else { return }
                self.cancel(); self.status = "System browser closed. Start again."
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        webSession = session
        if !session.start() { cancel(); status = "System browser could not start." }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.windows.first { $0.isKeyWindow } ?? UIWindow()
    }
}

struct CallbackProbeView: View {
    @State private var model = CallbackProbeModel()
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Local callback test").font(.title2.bold())
                    Text("This tests whether the iPhone browser can return a callback to Drift. It uses a fake local code and makes no request to OpenAI.")
                }
                Section("Current result") {
                    Text(model.status).accessibilityIdentifier("probeStatus")
                    Text("Background transitions: \(model.backgroundCount)").font(.caption)
                    Button("Start local test") { Task { await model.prepare() } }
                        .accessibilityIdentifier("probeStart")
                    if let url = model.callbackURL {
                        if #available(iOS 17.4, *) {
                            Button("Open local callback in system browser") { model.openSystemBrowser() }
                                .accessibilityIdentifier("probeSystemBrowser")
                        }
                        Button("Open local callback in Safari") { openURL(url) }
                            .accessibilityIdentifier("probeBrowser")
                        Button("Cancel test") { model.cancel() }.accessibilityIdentifier("probeCancel")
                    }
                }
                Section("What this does not prove") {
                    Text("ChatGPT-plan eligibility, actual sign-in, inference, token renewal, or callback reliability on a physical iPhone remain unverified.")
                    Text("The system browser returns to Drift after the local callback. With Safari, return manually. The listener expires after 60 seconds.")
                }
            }.scrollContentBackground(.hidden).background(Palette.background)
                .navigationTitle("Connection diagnostic").navigationBarTitleDisplayMode(.inline)
        }.tint(Palette.accent).foregroundStyle(Palette.ink)
            .onChange(of: phase) { _, value in if value == .background { model.backgroundCount += 1 } }
            .onDisappear { model.cancel() }
    }
}
#endif
