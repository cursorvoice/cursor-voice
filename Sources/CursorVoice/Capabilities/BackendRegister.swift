import Foundation

/// Tells the community backend "this Google account uses the app", so the
/// website (community.cursorvoice.app) recognizes it as a connected account and
/// lets it publish plugins. Best-effort and privacy-light: it sends only the
/// Google ID token (which the backend verifies) — nothing else. Silent on
/// failure; the app works fine whether or not the backend exists.
enum BackendRegister {
    /// Stable Worker URL (Cloudflare custom domain). Until the Worker is deployed
    /// there, this call simply no-ops on the network error.
    static let base = "https://api.cursorvoice.app"

    static func register(idToken: String) {
        guard !idToken.isEmpty, let url = URL(string: base + "/register") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["idToken": idToken])
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err = err { NSLog("BackendRegister: \(err.localizedDescription)") }
            else if let h = resp as? HTTPURLResponse { NSLog("BackendRegister: \(h.statusCode)") }
        }.resume()
    }
}
