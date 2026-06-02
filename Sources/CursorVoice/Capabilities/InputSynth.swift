import AppKit
import CoreGraphics
import ApplicationServices

/// Synthesizes mouse and keyboard events for the AI to physically drive the
/// Mac. All public functions take Cocoa-style screen coordinates
/// (origin = bottom-left of primary display) and convert internally.
/// Requires Accessibility permission; CGEvent.post otherwise silently fails.
enum InputSynth {
    /// Marker stamped into every CGEvent we post so the orb's global
    /// click-away monitor can recognise "this click came from us, don't dismiss".
    static let eventUserDataMarker: Int64 = 0x4356_4F52_4250_5453 // "CVORBPTS"

    // MARK: - Accessibility

    /// True if we currently have Accessibility permission.
    static var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Prompts the user to grant Accessibility, opening the System Settings pane
    /// if not yet granted. Idempotent.
    @discardableResult
    static func requestAccessibility(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Mouse
    //
    // Public API uses *image-pixel coordinates*: top-left origin, same scale
    // as the screenshot the model just received (native display pixels).
    // We convert to CG points (top-left origin, logical points) before posting,
    // dividing by the backing scale factor on Retina.

    static func moveCursor(imagePx: CGPoint) {
        post(.mouseMoved, at: imagePx, button: .left)
    }

    static func click(imagePx: CGPoint, button: CGMouseButton = .left, count: Int = 1) {
        let (down, up): (CGEventType, CGEventType) = {
            switch button {
            case .left:  return (.leftMouseDown,  .leftMouseUp)
            case .right: return (.rightMouseDown, .rightMouseUp)
            default:     return (.otherMouseDown, .otherMouseUp)
            }
        }()
        for i in 1...max(1, count) {
            postClick(down, at: imagePx, button: button, clickState: i)
            postClick(up,   at: imagePx, button: button, clickState: i)
        }
    }

    static func drag(fromPx from: CGPoint, toPx to: CGPoint, durationMs: Int = 350) {
        postClick(.leftMouseDown, at: from, button: .left, clickState: 1)
        let steps = max(8, durationMs / 16)
        let interval = TimeInterval(durationMs) / TimeInterval(steps) / 1000.0
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: from.x + (to.x - from.x) * t,
                            y: from.y + (to.y - from.y) * t)
            post(.leftMouseDragged, at: p, button: .left)
            Thread.sleep(forTimeInterval: interval)
        }
        postClick(.leftMouseUp, at: to, button: .left, clickState: 1)
    }

    static func scroll(deltaX: Int32, deltaY: Int32) {
        let e = CGEvent(scrollWheelEvent2Source: source,
                        units: .pixel,
                        wheelCount: 2,
                        wheel1: deltaY,
                        wheel2: deltaX,
                        wheel3: 0)
        e?.setIntegerValueField(.eventSourceUserData, value: eventUserDataMarker)
        e?.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    /// Type a literal string. Uses Unicode keystrokes so it handles any character.
    static func type(_ text: String) {
        for scalar in text.unicodeScalars {
            var u = UniChar(scalar.value)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            down?.setIntegerValueField(.eventSourceUserData, value: eventUserDataMarker)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            up?.setIntegerValueField(.eventSourceUserData, value: eventUserDataMarker)
            up?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.008)
        }
    }

    /// Press a named key with optional modifiers. `key` is one of: return, enter,
    /// tab, space, delete/backspace, escape, up, down, left, right, home, end,
    /// pageup, pagedown, or a single letter / digit.
    /// `modifiers` is an array containing any of: cmd, shift, option, control.
    static func pressKey(_ key: String, modifiers: [String] = []) {
        guard let code = keyCode(for: key) else { return }
        var flags: CGEventFlags = []
        for m in modifiers.map({ $0.lowercased() }) {
            switch m {
            case "cmd", "command":   flags.insert(.maskCommand)
            case "shift":            flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control":  flags.insert(.maskControl)
            default: break
            }
        }
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true)
        down?.flags = flags
        down?.setIntegerValueField(.eventSourceUserData, value: eventUserDataMarker)
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)
        up?.flags = flags
        up?.setIntegerValueField(.eventSourceUserData, value: eventUserDataMarker)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Plumbing

    /// Use a dedicated source so we can later distinguish AI events from user input.
    private static let source: CGEventSource? = CGEventSource(stateID: .privateState)

    private static func post(_ type: CGEventType, at imagePx: CGPoint, button: CGMouseButton) {
        let p = imagePxToPoint(imagePx)
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.setIntegerValueField(.eventSourceUserData, value: eventUserDataMarker)
        e?.post(tap: .cghidEventTap)
    }

    private static func postClick(_ type: CGEventType, at imagePx: CGPoint,
                                  button: CGMouseButton, clickState: Int) {
        let p = imagePxToPoint(imagePx)
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        e?.setIntegerValueField(.eventSourceUserData, value: eventUserDataMarker)
        e?.post(tap: .cghidEventTap)
    }

    /// Convert image-pixel coords (top-left origin, in the captured-screenshot
    /// scale, relative to the captured display) to GLOBAL CoreGraphics points.
    /// Scales by the ratio and offsets by the captured display's global origin,
    /// so clicks land on the correct monitor in multi-display setups.
    private static func imagePxToPoint(_ imagePx: CGPoint) -> CGPoint {
        let r = ScreenCapture.pointsPerImagePixel
        let o = ScreenCapture.capturedDisplayOrigin
        return CGPoint(x: o.x + imagePx.x * r, y: o.y + imagePx.y * r)
    }

    /// Click at a GLOBAL screen point (logical points, top-left origin) — e.g.
    /// an Accessibility element's frame center, which AX already reports in
    /// global top-left coordinates. Posts directly, bypassing the image-pixel
    /// translation so there's no origin/scale round-trip error.
    static func clickPoint(_ point: CGPoint, count: Int = 1) {
        NSLog("InputSynth.clickPoint: global (\(Int(point.x)),\(Int(point.y)))")
        let (down, up): (CGEventType, CGEventType) = (.leftMouseDown, .leftMouseUp)
        for i in 1...max(1, count) {
            for type in [down, up] {
                let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                e?.setIntegerValueField(.eventSourceUserData, value: eventUserDataMarker)
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    private static func keyCode(for name: String) -> Int? {
        switch name.lowercased() {
        case "return", "enter": return 36
        case "tab":             return 48
        case "space":           return 49
        case "delete", "backspace": return 51
        case "forwarddelete":   return 117
        case "escape", "esc":   return 53
        case "up":              return 126
        case "down":            return 125
        case "left":            return 123
        case "right":           return 124
        case "home":            return 115
        case "end":             return 119
        case "pageup":          return 116
        case "pagedown":        return 121
        case "f1":  return 122; case "f2":  return 120; case "f3":  return 99
        case "f4":  return 118; case "f5":  return 96;  case "f6":  return 97
        case "f7":  return 98;  case "f8":  return 100; case "f9":  return 101
        case "f10": return 109; case "f11": return 103; case "f12": return 111
        default: break
        }
        let map: [String: Int] = [
            "a":0,"b":11,"c":8,"d":2,"e":14,"f":3,"g":5,"h":4,"i":34,"j":38,
            "k":40,"l":37,"m":46,"n":45,"o":31,"p":35,"q":12,"r":15,"s":1,"t":17,
            "u":32,"v":9,"w":13,"x":7,"y":16,"z":6,
            "0":29,"1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25
        ]
        return map[name.lowercased()]
    }
}
