import Foundation
import PDFKit

/// Read documents so the assistant can answer questions about a file the user
/// points at — extends the on-screen OCR to actual files. PDFs via PDFKit,
/// plain-text/code via UTF-8. Read-only.
enum DocReader {

    private static let maxChars = 12_000

    /// Extract text from a PDF. Returns page count + text (truncated if long).
    static func readPDF(path: String) -> [String: Any] {
        let p = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: p) else { return ["error": "file not found: \(p)"] }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: p)) else {
            return ["error": "couldn't open as PDF (corrupt or not a PDF): \(p)"]
        }
        let text = doc.string ?? ""
        if text.isEmpty {
            return ["ok": true, "path": p, "pages": doc.pageCount, "chars": 0,
                    "text": "(no extractable text — likely a scanned/image-only PDF; open it on screen and use see_screen/find_text instead)"]
        }
        return ["ok": true, "path": p, "pages": doc.pageCount, "chars": text.count, "text": clip(text)]
    }

    /// Read a text/code file as UTF-8 (falls back to Latin-1). Refuses
    /// directories, binaries, and files over ~5MB.
    static func readFile(path: String) -> [String: Any] {
        let p = (path as NSString).expandingTildeInPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: p, isDirectory: &isDir) else { return ["error": "file not found: \(p)"] }
        if isDir.boolValue { return ["error": "that's a directory, not a file: \(p)"] }
        if let attrs = try? fm.attributesOfItem(atPath: p),
           let size = attrs[.size] as? Int, size > 5_000_000 {
            return ["error": "file too large (\(size) bytes) — only text files under ~5MB are read"]
        }
        guard let data = fm.contents(atPath: p) else { return ["error": "couldn't read file"] }
        if data.prefix(1024).contains(0) {
            return ["error": "looks like a binary file, not text: \(p)"]
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        return ["ok": true, "path": p, "chars": text.count, "text": clip(text)]
    }

    private static func clip(_ text: String) -> String {
        text.count > maxChars
            ? String(text.prefix(maxChars)) + "\n…(truncated, \(text.count) chars total)"
            : text
    }
}
