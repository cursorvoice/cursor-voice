import AppKit

/// Read/write the system clipboard so the assistant can "summarize what I
/// copied", "paste that as plain text", etc. (Reading returns the text;
/// pasting-as-plain-text = set the clipboard to plain text, then ⌘V.)
enum ClipboardManager {

    static func read() -> [String: Any] {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string), !s.isEmpty {
            let clipped = s.count > 4000 ? String(s.prefix(4000)) + "\n…(truncated)" : s
            return ["text": clipped, "length": s.count]
        }
        return ["text": "", "note": "clipboard has no text content"]
    }

    @discardableResult
    static func set(_ text: String) -> [String: Any] {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return ["ok": true, "set_length": text.count]
    }
}
