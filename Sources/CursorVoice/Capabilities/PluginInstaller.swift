import Foundation
import AppKit

/// Handles `cursorvoice://install?url=<rawManifestUrl>` deep links from the
/// community marketplace. Fetches the manifest, shows a confirmation (plugins
/// run with the user's permissions, so installs are never silent), and writes it
/// into the plugins folder PluginManager already watches.
@MainActor
enum PluginInstaller {

    /// Entry point for any `cursorvoice://` URL the app is opened with.
    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "cursorvoice" else { return }
        // host OR first path component = action (cursorvoice://install?... )
        let action = (url.host ?? url.pathComponents.dropFirst().first ?? "").lowercased()
        guard action == "install" else {
            NSLog("PluginInstaller: ignoring unknown action '\(action)'")
            return
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let raw = items.first(where: { $0.name == "url" })?.value,
              let src = URL(string: raw),
              src.scheme == "https" else {
            present(alert: "Couldn’t install", info: "That install link was malformed or not secure (https required).")
            return
        }
        Task { await fetchAndConfirm(src) }
    }

    private static func fetchAndConfirm(_ src: URL) async {
        do {
            var req = URLRequest(url: src)
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                present(alert: "Couldn’t download", info: "The plugin manifest couldn’t be fetched from \(src.host ?? "the source").")
                return
            }
            guard data.count < 64_000,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = obj["name"] as? String, !name.isEmpty,
                  let desc = obj["description"] as? String,
                  let run = obj["run"] as? [String: Any],
                  let type = run["type"] as? String,
                  ["shell", "applescript", "open_url"].contains(type),
                  let template = run["template"] as? String, !template.isEmpty else {
                present(alert: "Not a valid plugin", info: "This file isn’t a well-formed Cursor Voice plugin manifest.")
                return
            }
            confirmInstall(name: name, desc: desc, type: type, template: template, source: src, data: data)
        } catch {
            present(alert: "Couldn’t download", info: error.localizedDescription)
        }
    }

    private static func confirmInstall(name: String, desc: String, type: String,
                                       template: String, source: URL, data: Data) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Install “\(name)”?"
        let action: String = {
            switch type {
            case "open_url":    return "Opens a URL"
            case "shell":       return "Runs a shell command"
            case "applescript": return "Runs AppleScript"
            default:            return type
            }
        }()
        a.informativeText = """
        \(desc)

        Action: \(action)
        \(template)

        Source: \(source.host ?? source.absoluteString)

        Plugins run with your permissions. Only install plugins you trust.
        """
        a.alertStyle = .warning
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        write(name: name, data: data)
    }

    private static func write(name: String, data: Data) {
        let slug = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let file = PluginManager.pluginsDir().appendingPathComponent("\(slug.isEmpty ? "plugin" : slug).json")
        do {
            try data.write(to: file)
            NSLog("PluginInstaller: installed \(file.lastPathComponent)")
            present(alert: "Installed “\(name)”",
                    info: "It’s ready. Summon the orb and try it — the assistant can use it now.",
                    style: .informational)
        } catch {
            present(alert: "Couldn’t save", info: error.localizedDescription)
        }
    }

    private static func present(alert: String, info: String, style: NSAlert.Style = .warning) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = alert
        a.informativeText = info
        a.alertStyle = style
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
