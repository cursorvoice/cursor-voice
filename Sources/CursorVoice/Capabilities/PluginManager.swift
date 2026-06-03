import Foundation
import AppKit

/// Community plugin SDK. Users drop JSON manifests in
/// ~/Library/Application Support/CursorVoice/plugins/*.json; each defines a
/// tool the model can call. The action is a shell command, AppleScript, or URL
/// template with {{arg}} substitution. Tool names are prefixed `plugin_` so
/// they never collide with built-ins.
///
/// Manifest:
/// {
///   "name": "open ticket",
///   "description": "Open a Jira ticket by key in the browser",
///   "parameters": { "type": "object",
///                   "properties": { "key": { "type": "string" } },
///                   "required": ["key"] },
///   "run": { "type": "open_url", "template": "https://co.atlassian.net/browse/{{key}}" }
/// }
enum PluginManager {

    struct Tool {
        let name: String          // already `plugin_`-prefixed + sanitized
        let description: String
        let parameters: [String: Any]
        let runType: String       // "shell" | "applescript" | "open_url"
        let template: String
        var file: URL? = nil      // source manifest (for the Settings → Plugins UI)
    }

    static func pluginsDir() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = support.appendingPathComponent("CursorVoice/plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func isPlugin(_ name: String) -> Bool { name.hasPrefix("plugin_") }

    /// Load + validate all manifests in the plugins directory.
    static func load() -> [Tool] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: pluginsDir(), includingPropertiesForKeys: nil) else { return [] }
        var tools: [Tool] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawName = obj["name"] as? String,
                  let desc = obj["description"] as? String,
                  let run = obj["run"] as? [String: Any],
                  let runType = run["type"] as? String,
                  ["shell", "applescript", "open_url"].contains(runType),
                  let template = run["template"] as? String else { continue }
            let sanitized = rawName.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .filter { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !sanitized.isEmpty else { continue }
            let params = (obj["parameters"] as? [String: Any])
                ?? ["type": "object", "properties": [:] as [String: Any]]
            tools.append(Tool(name: "plugin_\(sanitized)", description: desc,
                              parameters: params, runType: runType, template: template, file: f))
        }
        return tools
    }

    /// Tool schemas to advertise to the model alongside the built-ins.
    static func toolSchemas() -> [[String: Any]] {
        load().map {
            ["type": "function", "name": $0.name, "description": $0.description, "parameters": $0.parameters]
        }
    }

    /// Execute a plugin tool by name with the model's args.
    static func run(name: String, args: [String: Any]) async -> [String: Any] {
        guard let t = load().first(where: { $0.name == name }) else {
            return ["error": "unknown plugin tool \(name)"]
        }
        let cmd = substitute(t.template, args: args, runType: t.runType)
        switch t.runType {
        case "open_url":
            guard let url = URL(string: cmd), url.scheme != nil else { return ["error": "invalid URL: \(cmd)"] }
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return ["ok": true, "opened": cmd]
        case "applescript":
            return AppleScriptRunner.run(cmd).mapValues { $0 as Any }
        case "shell":
            return await ShellRunner.run(cmd).mapValues { $0 as Any }
        default:
            return ["error": "unsupported run type \(t.runType)"]
        }
    }

    /// Substitute {{arg}} placeholders, escaping per target so a plugin can't be
    /// trivially broken (or injected) by arg values.
    private static func substitute(_ template: String, args: [String: Any], runType: String) -> String {
        var s = template
        for (k, v) in args {
            let raw = "\(v)"
            let safe: String
            switch runType {
            case "shell":       safe = "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
            case "open_url":    safe = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
            case "applescript": safe = raw.replacingOccurrences(of: "\\", with: "\\\\")
                                          .replacingOccurrences(of: "\"", with: "\\\"")
            default:            safe = raw
            }
            s = s.replacingOccurrences(of: "{{\(k)}}", with: safe)
        }
        return s
    }
}
