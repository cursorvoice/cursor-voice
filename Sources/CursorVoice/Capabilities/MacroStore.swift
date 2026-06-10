import Foundation

/// Macros — "teach it a skill". A macro is a named sequence of tool calls the
/// user performed once while recording; replaying runs the same steps again.
/// Stored as JSON files in ~/Library/Application Support/CursorVoice/macros/.
///
/// Recording is voice-driven: "record a macro called deploy" → do the steps by
/// voice → "stop recording". Replay: "run my deploy macro".
enum MacroStore {

    struct Step: Codable {
        let tool: String
        let argsJSON: String
    }

    struct Macro: Codable {
        var name: String          // display name, lowercase
        var steps: [Step]
        var createdAt: Date
    }

    static func dir() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = support.appendingPathComponent("CursorVoice/macros", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func slug(_ name: String) -> String {
        let s = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return s.isEmpty ? "macro" : s
    }

    private static func url(for name: String) -> URL {
        dir().appendingPathComponent("\(slug(name)).json")
    }

    static func save(_ macro: Macro) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(macro) {
            try? data.write(to: url(for: macro.name))
        }
    }

    static func load(_ name: String) -> Macro? {
        // Exact slug first, then fuzzy contains-match so "run deploy" finds "deploy-site".
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url(for: name)),
           let m = try? dec.decode(Macro.self, from: data) { return m }
        let want = slug(name)
        for m in list() where slug(m.name).contains(want) || want.contains(slug(m.name)) {
            return m
        }
        return nil
    }

    static func list() -> [Macro] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: dir(), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(Macro.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name < $1.name }
    }

    @discardableResult
    static func delete(_ name: String) -> Bool {
        guard let m = load(name) else { return false }
        try? FileManager.default.removeItem(at: url(for: m.name))
        return true
    }
}
