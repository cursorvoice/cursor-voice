import Foundation
import AppKit
import ApplicationServices

/// Walks the macOS Accessibility tree of the frontmost app and exposes
/// it as a flat list of clickable / focusable elements. This is *the*
/// reliable path for the model to act on UI — no pixel hunting needed.
enum AXTree {

    struct Element {
        let role: String
        let title: String
        let value: String
        let frame: CGRect        // screen points, top-left origin
        let identifier: String   // synthetic id stable for a single tree walk
        let element: AXUIElement // live handle for AXPress / other actions
    }

    /// Try to fire the element's AXPress action. Returns true on success.
    /// AXPress invokes the action without simulating a click — no coordinate
    /// math, no cursor movement. Works on every standard AXButton /
    /// AXMenuItem / AXCheckBox / AXLink etc. The single biggest accuracy win
    /// available — coordinate clicks should be a fallback only.
    static func tryPress(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private static let interestingRoles: Set<String> = [
        "AXButton",
        "AXLink",
        "AXTextField",
        "AXTextArea",
        "AXSearchField",
        "AXMenuItem",
        "AXMenuButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXTabGroup",
        "AXTab",
        "AXComboBox",
        "AXOutline",
        "AXRow",
        "AXCell",
        "AXImage"
    ]

    /// Returns a flat list of interesting elements from the frontmost app's focused window.
    static func enumerateFrontmost(maxDepth: Int = 14, maxElements: Int = 120) -> [Element] {
        guard AXIsProcessTrusted() else { return [] }
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Prefer focused window; fall back to all top-level windows.
        var startElements: [AXUIElement] = []
        if let focused = copyAttribute(axApp, kAXFocusedWindowAttribute) as! AXUIElement? {
            startElements = [focused]
        } else if let windows = copyAttribute(axApp, kAXWindowsAttribute) as? [AXUIElement] {
            startElements = windows
        }
        if startElements.isEmpty { startElements = [axApp] }

        var results: [Element] = []
        var counter = 0
        for root in startElements {
            walk(root, depth: 0, maxDepth: maxDepth, results: &results, counter: &counter, limit: maxElements)
            if results.count >= maxElements { break }
        }
        return results
    }

    /// Find the best match by case-insensitive title contains; optional role filter.
    static func bestMatch(in elements: [Element], name: String, role: String? = nil) -> Element? {
        let q = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let pool = role.map { r in elements.filter { $0.role == r } } ?? elements

        // Score: exact title > prefix > contains > value match
        func score(_ e: Element) -> Int {
            let t = e.title.lowercased()
            let v = e.value.lowercased()
            if t == q { return 1000 }
            if t.hasPrefix(q) { return 800 }
            if t.contains(q) { return 600 - abs(t.count - q.count) }
            if v.contains(q) { return 400 }
            return 0
        }
        let ranked = pool.map { (e: $0, s: score($0)) }.filter { $0.s > 0 }
            .sorted { $0.s > $1.s }
        return ranked.first?.e
    }

    // MARK: - Private

    private static func walk(_ element: AXUIElement,
                             depth: Int,
                             maxDepth: Int,
                             results: inout [Element],
                             counter: inout Int,
                             limit: Int) {
        if depth > maxDepth || results.count >= limit { return }

        let role  = (copyAttribute(element, kAXRoleAttribute) as? String) ?? ""
        let title = (copyAttribute(element, kAXTitleAttribute) as? String) ?? ""
        let value = stringFrom(copyAttribute(element, kAXValueAttribute))
        let help  = (copyAttribute(element, kAXHelpAttribute) as? String) ?? ""
        let desc  = (copyAttribute(element, kAXDescriptionAttribute) as? String) ?? ""

        let displayTitle = !title.isEmpty ? title
                         : !help.isEmpty ? help
                         : !desc.isEmpty ? desc
                         : value

        if interestingRoles.contains(role), !displayTitle.isEmpty {
            let frame = frameOf(element)
            if frame.width > 0 && frame.height > 0 {
                counter += 1
                results.append(Element(
                    role: role,
                    title: displayTitle,
                    value: value,
                    frame: frame,
                    identifier: "el\(counter)",
                    element: element
                ))
            }
        }

        if let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for c in children {
                walk(c, depth: depth + 1, maxDepth: maxDepth,
                     results: &results, counter: &counter, limit: limit)
                if results.count >= limit { return }
            }
        }
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> Any? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value
    }

    private static func frameOf(_ element: AXUIElement) -> CGRect {
        var pos = CGPoint.zero, sz = CGSize.zero
        if let p = copyAttribute(element, kAXPositionAttribute) {
            AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        }
        if let s = copyAttribute(element, kAXSizeAttribute) {
            AXValueGetValue(s as! AXValue, .cgSize, &sz)
        }
        return CGRect(origin: pos, size: sz)
    }

    private static func stringFrom(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        if let v = any { return "\(v)" }
        return ""
    }
}
