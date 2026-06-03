import Foundation
import AppKit
import CryptoKit
import Network

/// "Sign in with Google" for identity (OpenID Connect) using the installed-app
/// loopback + PKCE flow. Scopes are just `openid email profile` — no access to
/// the user's Gmail/Calendar/Drive, so no sensitive-scope verification needed.
///
/// Flow: open Google's consent page in the browser with a redirect to a local
/// loopback server → receive the auth code → exchange for tokens (PKCE) →
/// decode the id_token for the user's email/name. Refresh token kept in Keychain.
@MainActor
final class GoogleAuth: ObservableObject {
    static let shared = GoogleAuth()

    struct Identity: Codable, Equatable {
        let email: String
        let name: String
        let picture: String?
        let sub: String
    }

    @Published private(set) var identity: Identity?
    @Published private(set) var inProgress = false
    @Published private(set) var lastError: String?

    private let defaults = UserDefaults.standard
    private let refreshKeychain = KeychainStore(service: "com.cursorvoice.app", account: "google-refresh-token")
    private var server: LoopbackServer?

    // Baked-in OAuth client for the shipped app. For an "installed app" Google
    // does not treat these as confidential (PKCE provides the security), so
    // shipping them lets every user sign in with the app's own client.
    // The secret is XOR-obfuscated only to keep a plaintext token out of the
    // public repo (it ends up in the binary regardless); not a security measure.
    // A per-machine override via UserDefaults still takes precedence.
    private static let bakedClientID = "946007924079-c3nmabuvesemdkktjn4oegg9f43ajem5.apps.googleusercontent.com"
    private static let bakedSecretXOR: [UInt8] = [29, 21, 25, 9, 10, 2, 119, 43, 23, 5, 43, 56, 25, 10, 17, 44, 35, 62, 10, 23, 56, 23, 41, 13, 105, 12, 25, 99, 0, 20, 13, 15, 56, 108, 16]
    private static var bakedClientSecret: String {
        String(bytes: bakedSecretXOR.map { $0 ^ 0x5A }, encoding: .utf8) ?? ""
    }

    /// Per-device cap: at most this many distinct Google accounts may ever sign
    /// in on a single device. A new account beyond the cap is refused.
    static let maxAccountsPerDevice = 4

    /// Stable keys (Google `sub`) of accounts that have signed in on this device.
    private var seenAccounts: [String] {
        get { defaults.stringArray(forKey: "deviceAccounts") ?? [] }
        set { defaults.set(newValue, forKey: "deviceAccounts") }
    }

    /// Decide whether `id` may sign in under the per-device account cap, and
    /// record it if so. Returns false (with a reason) when the cap is exceeded.
    private func admit(_ id: Identity) -> Bool {
        let key = id.sub.isEmpty ? id.email.lowercased() : id.sub
        var seen = seenAccounts
        if seen.contains(key) { return true }            // returning account — fine
        if seen.count >= Self.maxAccountsPerDevice {
            return false                                  // new account over the cap
        }
        seen.append(key)
        seenAccounts = seen
        return true
    }

    private var clientID: String {
        let v = defaults.string(forKey: "googleClientID") ?? ""
        return v.isEmpty ? Self.bakedClientID : v
    }
    private var clientSecret: String {
        let v = defaults.string(forKey: "googleClientSecret") ?? ""
        return v.isEmpty ? Self.bakedClientSecret : v
    }
    var isConfigured: Bool { !clientID.isEmpty }

    private init() {
        if let data = defaults.data(forKey: "googleIdentity"),
           let id = try? JSONDecoder().decode(Identity.self, from: data) {
            identity = id
        }
    }

    func setCredentials(clientID: String, clientSecret: String) {
        defaults.set(clientID.trimmingCharacters(in: .whitespaces), forKey: "googleClientID")
        defaults.set(clientSecret.trimmingCharacters(in: .whitespaces), forKey: "googleClientSecret")
    }
    var savedClientID: String { clientID }
    var savedClientSecret: String { clientSecret }

    // MARK: - Sign in

    func signIn() {
        guard !inProgress else { return }
        guard isConfigured else { lastError = "Add your Google OAuth Client ID first."; return }
        inProgress = true
        lastError = nil

        let verifier = Self.codeVerifier()
        let challenge = Self.codeChallenge(verifier)

        let server = LoopbackServer()
        self.server = server
        Task { @MainActor in
            do {
                let port = try await server.start { [weak self] code in
                    Task { @MainActor in await self?.handleRedirect(code: code, verifier: verifier) }
                }
                let redirect = "http://127.0.0.1:\(port)"
                var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
                comps.queryItems = [
                    .init(name: "client_id", value: clientID),
                    .init(name: "redirect_uri", value: redirect),
                    .init(name: "response_type", value: "code"),
                    .init(name: "scope", value: "openid email profile"),
                    .init(name: "code_challenge", value: challenge),
                    .init(name: "code_challenge_method", value: "S256"),
                    .init(name: "access_type", value: "offline"),
                    .init(name: "prompt", value: "consent")
                ]
                self.pendingRedirect = redirect
                NSWorkspace.shared.open(comps.url!)
            } catch {
                self.inProgress = false
                self.lastError = "couldn't start local server: \(error.localizedDescription)"
            }
        }
    }

    func signOut() {
        identity = nil
        defaults.removeObject(forKey: "googleIdentity")
        try? refreshKeychain.write("")
    }

    private var pendingRedirect: String = ""

    private func handleRedirect(code: String?, verifier: String) async {
        server?.stop(); server = nil
        guard let code = code else {
            inProgress = false
            lastError = "sign-in was cancelled"
            return
        }
        await exchange(code: code, verifier: verifier)
        inProgress = false
    }

    // MARK: - Token exchange

    private func exchange(code: String, verifier: String) async {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var params = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": pendingRedirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier
        ]
        if !clientSecret.isEmpty { params["client_secret"] = clientSecret }
        req.httpBody = params.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let body = String(data: data, encoding: .utf8) ?? ""
                lastError = "token exchange failed: \(body.prefix(160))"
                NSLog("GoogleAuth: token exchange failed: \(body)")
                return
            }
            if let idToken = obj["id_token"] as? String, let id = Self.decodeIdentity(idToken) {
                guard admit(id) else {
                    lastError = "This device has reached its limit of \(Self.maxAccountsPerDevice) accounts."
                    NSLog("GoogleAuth: device account cap reached — rejected \(id.email)")
                    try? refreshKeychain.write("")
                    return
                }
                if let refresh = obj["refresh_token"] as? String { try? refreshKeychain.write(refresh) }
                identity = id
                if let d = try? JSONEncoder().encode(id) { defaults.set(d, forKey: "googleIdentity") }
                NSLog("GoogleAuth: signed in as \(id.email)")
                // Register this account with the community backend so the website
                // recognizes it as connected (lets it publish plugins). Best-effort.
                BackendRegister.register(idToken: idToken)
            } else {
                lastError = "no id_token in response"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private static func decodeIdentity(_ jwt: String) -> Identity? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Identity(
            email: (obj["email"] as? String) ?? "",
            name: (obj["name"] as? String) ?? (obj["email"] as? String) ?? "Google user",
            picture: obj["picture"] as? String,
            sub: (obj["sub"] as? String) ?? ""
        )
    }

    private static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }
    private static func codeChallenge(_ verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(hash))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static func formEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

/// Minimal one-shot loopback HTTP server: accepts a single GET request on an
/// ephemeral localhost port, extracts ?code= (or ?error=), responds with a
/// "you can close this tab" page, then reports the code.
final class LoopbackServer {
    private var listener: NWListener?
    private var onCode: ((String?) -> Void)?

    /// Start listening on an ephemeral localhost port; resolves with the real
    /// bound port once the listener is ready. `completion` fires once with the
    /// auth code captured from the redirect.
    func start(completion: @escaping (String?) -> Void) async throws -> UInt16 {
        self.onCode = completion
        let listener = try NWListener(using: .tcp)   // OS picks an ephemeral port
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let code = Self.parseCode(request)
                let html = "<html><body style=\"font-family:-apple-system;background:#0c0c14;color:#eee;text-align:center;padding-top:18%\"><h2>Cursor Voice</h2><p>You're signed in. You can close this tab.</p></body></html>"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
                conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                self?.fire(code)
            }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    if let p = listener.port?.rawValue, p != 0, self.claimResume() {
                        cont.resume(returning: p)
                    }
                case .failed(let err):
                    if self.claimResume() { cont.resume(throwing: err) }
                default: break
                }
            }
            listener.start(queue: .main)
        }
    }

    private let resumeLock = NSLock()
    private var didResume = false
    /// Returns true exactly once (first caller wins) — guards the continuation.
    private func claimResume() -> Bool {
        resumeLock.lock(); defer { resumeLock.unlock() }
        if didResume { return false }
        didResume = true
        return true
    }

    private var fired = false
    private func fire(_ code: String?) {
        guard !fired else { return }
        fired = true
        DispatchQueue.main.async { self.onCode?(code) }
    }

    func stop() { listener?.cancel(); listener = nil }

    private static func parseCode(_ request: String) -> String? {
        guard let line = request.split(separator: "\r\n").first,
              let pathPart = line.split(separator: " ").dropFirst().first,
              let comps = URLComponents(string: "http://x\(pathPart)") else { return nil }
        if comps.queryItems?.first(where: { $0.name == "error" }) != nil { return nil }
        return comps.queryItems?.first(where: { $0.name == "code" })?.value
    }
}
