import Foundation

/// Voice-driven file operations: find files by name, and move/rename them.
/// Paths accept `~`. Move/rename are mutating (gated by dry-run). Destructive
/// deletes are intentionally NOT offered — use the Trash via Finder instead.
enum FileOps {

    /// Search file/folder names containing `query` under `dir` (default: home).
    static func find(query: String, in dir: String?) -> [String: Any] {
        let fm = FileManager.default
        let base = expand(dir ?? "~")
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ["error": "empty query"] }
        guard fm.fileExists(atPath: base) else { return ["error": "directory not found: \(base)"] }

        var matches: [String] = []
        var scanned = 0
        if let en = fm.enumerator(at: URL(fileURLWithPath: base),
                                  includingPropertiesForKeys: nil,
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in en {
                scanned += 1
                if scanned > 30_000 { break }              // bound the walk
                if url.lastPathComponent.lowercased().contains(q) {
                    matches.append(url.path)
                    if matches.count >= 50 { break }
                }
            }
        }
        return ["query": query, "base": base, "count": matches.count, "matches": matches]
    }

    /// Move or rename a file/folder. If `to` is an existing directory, the item
    /// is moved into it keeping its name.
    static func move(from: String, to: String) -> [String: Any] {
        let fm = FileManager.default
        let src = expand(from)
        var dst = expand(to)
        guard fm.fileExists(atPath: src) else { return ["error": "source not found: \(src)"] }

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dst, isDirectory: &isDir), isDir.boolValue {
            dst = (dst as NSString).appendingPathComponent((src as NSString).lastPathComponent)
        }
        if fm.fileExists(atPath: dst) {
            return ["error": "destination already exists: \(dst)"]
        }
        do {
            try fm.moveItem(atPath: src, toPath: dst)
            return ["ok": true, "from": src, "to": dst]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private static func expand(_ p: String) -> String {
        (p as NSString).expandingTildeInPath
    }
}
