import AppKit

/// Read/write the system clipboard so the assistant can "summarize what I
/// copied", "paste that as plain text", etc. (Reading returns the text;
/// pasting-as-plain-text = set the clipboard to plain text, then ⌘V.)
enum ClipboardManager {

    static func read() -> [String: Any] {
        let pb = NSPasteboard.general
        // readObjects coerces RTF/HTML/legacy text reps to a String, unlike
        // string(forType: .string) which needs the exact plain-text type present
        // (browsers/rich-text apps often don't put public.utf8-plain-text).
        if let arr = pb.readObjects(forClasses: [NSString.self], options: nil) as? [String],
           let s = arr.first(where: { !$0.isEmpty }) {
            return ["text": clip(s), "length": s.count]
        }
        if let s = pb.string(forType: .string), !s.isEmpty {
            return ["text": clip(s), "length": s.count]
        }
        // Nothing readable — surface the available types to aid debugging.
        let types = (pb.types ?? []).map { $0.rawValue }
        return ["text": "", "note": "no readable text on the clipboard", "available_types": types]
    }

    private static func clip(_ s: String) -> String {
        s.count > 4000 ? String(s.prefix(4000)) + "\n…(truncated)" : s
    }

    @discardableResult
    static func set(_ text: String) -> [String: Any] {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return ["ok": true, "set_length": text.count]
    }
}
