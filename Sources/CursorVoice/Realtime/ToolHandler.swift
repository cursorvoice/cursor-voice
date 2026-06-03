import Foundation
import CoreGraphics
import AppKit
import AVFoundation
import Speech
import ApplicationServices

/// Output of a tool call. `outputJSON` is the string the model receives as
/// the function call result. `attachedImageBase64`, if set, is a JPEG that
/// the realtime client should inject as a user input_image conversation
/// item BEFORE delivering the function output (so the next response can
/// reference the screenshot).
struct ToolDispatchResult {
    let outputJSON: String
    let attachedImageBase64: String?
}

/// Dispatches Realtime API function calls to the matching Swift capability.
actor ToolHandler {
    static let toolDefinitions: [[String: Any]] = [
        [
            "type": "function",
            "name": "list_ui_elements",
            "description": "Return a list of clickable UI elements in the currently focused window of the frontmost app, using the macOS Accessibility tree. Each entry has role, title, and frame (in screen points). This is FAR more reliable than pixel-clicking — prefer it whenever you can. Call this BEFORE click_element. Requires Accessibility permission.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ]
        ],
        [
            "type": "function",
            "name": "click_element",
            "description": "Click a UI element by its title text (and optional role). FIRST tries to fire the element's AXPress action directly — no mouse simulation, immune to scaling/scroll/animation. Falls back to clicking the element's frame center if AXPress isn't supported. This is the MOST RELIABLE way to click — prefer it over mouse_click for anything with a visible label.",
            "parameters": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Title/label of the element. Case-insensitive substring match."],
                    "role": ["type": "string", "description": "Optional AX role filter (AXButton, AXLink, AXTextField, AXMenuItem, AXCheckBox, ...)"],
                    "count": ["type": "integer", "default": 1, "description": "1 for single, 2 for double-click (fallback path only)"]
                ],
                "required": ["name"]
            ]
        ],
        [
            "type": "function",
            "name": "mark_screen",
            "description": "LAST-RESORT targeting for clicks. Takes a screenshot and overlays NUMBERED badges on every candidate clickable region (from the accessibility tree + OCR). Use this only when click_element and click_text both fail — e.g. unlabeled icons, toolbars, canvas/painted UI. Look at the returned numbered image, then call click_mark with the number on your target.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ]
        ],
        [
            "type": "function",
            "name": "click_mark",
            "description": "Click the center of a numbered mark from the most recent mark_screen call.",
            "parameters": [
                "type": "object",
                "properties": [
                    "mark": ["type": "integer", "description": "The badge number to click."]
                ],
                "required": ["mark"]
            ]
        ],
        [
            "type": "function",
            "name": "find_text",
            "description": "Take a screenshot and OCR it with the macOS Vision framework. Returns text matches with their pixel bounding boxes. Use this when the target is visible text that's NOT exposed via the Accessibility tree (web content in Safari, Electron apps, Canvas, dynamically-painted UI). Provide a query to filter results.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Optional substring to filter recognised text."]
                ],
                "required": [] as [String]
            ]
        ],
        [
            "type": "function",
            "name": "click_text",
            "description": "Find visible text on screen via OCR, then click the center of the matched box. Use this when click_element fails and there's visible text to target — works on web pages, images, anything Vision can read. Returns success + the matched text.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "The visible text to find and click. Case-insensitive substring."],
                    "match_index": ["type": "integer", "default": 0, "description": "If multiple matches, which one to click (0 = first)."]
                ],
                "required": ["query"]
            ]
        ],
        [
            "type": "function",
            "name": "hotkey",
            "description": "Press a key combo expressed as a list, e.g. [\"cmd\",\"shift\",\"t\"]. Modifiers can be anywhere in the list; the last non-modifier is the actual key. Use this for chord shortcuts.",
            "parameters": [
                "type": "object",
                "properties": [
                    "keys": ["type": "array", "items": ["type": "string"]]
                ],
                "required": ["keys"]
            ]
        ],
        [
            "type": "function",
            "name": "permissions_diagnostics",
            "description": "Report current macOS permission state for Microphone, Speech Recognition, Screen Recording, and Accessibility. Call this when a tool fails so you can tell the user concretely what they need to enable.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ]
        ],
        [
            "type": "function",
            "name": "batch_actions",
            "description": "Run a sequence of actions in ONE tool call (without taking a screenshot between each step). Use this for any multi-step automation to massively cut round-trip latency. One screenshot is auto-attached after the whole batch finishes. Supported action types: click_element, mouse_click, mouse_move, type_text, press_key, hotkey, scroll, sleep, run_shell, run_applescript, open_url. Each step dict needs a 'type' field plus that action's normal arguments (e.g. {\"type\":\"run_shell\",\"command\":\"...\"}).",
            "parameters": [
                "type": "object",
                "properties": [
                    "actions": [
                        "type": "array",
                        "description": "Ordered list of action dicts. Each must have a 'type' field plus that type's normal arguments.",
                        "items": ["type": "object"]
                    ],
                    "stop_on_error": ["type": "boolean", "default": true]
                ],
                "required": ["actions"]
            ]
        ],
        [
            "type": "function",
            "name": "remember",
            "description": "Save a fact about the user or this Mac to long-term memory (persists across sessions). Use sparingly — only durable preferences, names, IDs, common tasks, system shortcuts the user uses, etc. Don't store ephemeral state.",
            "parameters": [
                "type": "object",
                "properties": [
                    "content": ["type": "string", "description": "A short fact in the third person, e.g. 'User's preferred browser is Arc' or 'User's GitHub username is foo'"]
                ],
                "required": ["content"]
            ]
        ],
        [
            "type": "function",
            "name": "recall",
            "description": "Look up memories. Returns memories matching the optional query, or all memories if no query. Use this when the user references something you might already know.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Optional substring to filter by."]
                ],
                "required": [] as [String]
            ]
        ],
        [
            "type": "function",
            "name": "web_search",
            "description": "Search the web for live, up-to-date information. Returns the top results (title, URL, snippet). Use this for ANY question about current events, prices, scores, releases, news — anything time-sensitive. After web_search you may fetch_url to read a specific page.",
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Plain natural-language query."]
                ],
                "required": ["query"]
            ]
        ],
        [
            "type": "function",
            "name": "fetch_url",
            "description": "Fetch a URL and return its stripped text (≤4000 chars). Use after web_search to read a specific article or page. Does NOT open a browser window.",
            "parameters": [
                "type": "object",
                "properties": [
                    "url": ["type": "string"]
                ],
                "required": ["url"]
            ]
        ],
        [
            "type": "function",
            "name": "browser_click_text",
            "description": "Click a link/button/control in the FRONTMOST browser tab (Safari, Chrome, Brave, Edge, Arc) by its visible text. Runs in the page DOM — pixel-perfect, immune to scroll/layout. Prefer this over mouse_click for ANY web page element. Falls through if JavaScript-from-Apple-Events isn't enabled.",
            "parameters": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "Visible text/label of the element to click."]
                ],
                "required": ["text"]
            ]
        ],
        [
            "type": "function",
            "name": "browser_snapshot",
            "description": "List the interactive elements (links, buttons, inputs) on the current browser page with their text — so you can target them with browser_click_text without a screenshot. Use on web pages before clicking.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ]
        ],
        [
            "type": "function",
            "name": "browser_run_js",
            "description": "Run arbitrary JavaScript in the frontmost browser tab and return the result as text. Powerful escape hatch for reading or manipulating web pages (fill fields, extract data, navigate). Use for web tasks that browser_click_text can't express.",
            "parameters": [
                "type": "object",
                "properties": [
                    "js": ["type": "string", "description": "JavaScript expression/IIFE; its return value is stringified."]
                ],
                "required": ["js"]
            ]
        ],
        [
            "type": "function",
            "name": "open_url",
            "description": "Open a URL in the user's default browser (no clicking). Use this for ALL web navigation and searches — much more reliable than trying to click through Safari. For Google: https://google.com/search?q=ENCODED_QUERY. For sites: https://example.com. URL-encode spaces as + or %20.",
            "parameters": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "A fully-qualified URL beginning with https://"]
                ],
                "required": ["url"]
            ]
        ],
        [
            "type": "function",
            "name": "see_screen",
            "description": "Take a screenshot of the user's screen and attach it as an image. The image is the screen at NATIVE pixel resolution — image_size_px in the metadata is also the click coordinate space. ALWAYS call this before any mouse_* tool unless you've just seen the relevant area, and call it again after if you need to verify.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ]
        ],
        [
            "type": "function",
            "name": "mouse_move",
            "description": "Move the mouse cursor. x, y are IMAGE PIXEL coordinates from the most recent screenshot — origin TOP-LEFT, same scale as the image (no math needed). (0,0) is the top-left corner of the screenshot.",
            "parameters": [
                "type": "object",
                "properties": [
                    "x": ["type": "number", "description": "image pixel x, top-left origin"],
                    "y": ["type": "number", "description": "image pixel y, top-left origin"]
                ],
                "required": ["x", "y"]
            ]
        ],
        [
            "type": "function",
            "name": "mouse_click",
            "description": "Click at (x, y). Coordinates are IMAGE PIXELS from the most recent screenshot (top-left origin, exact scale). For best accuracy aim at the CENTER of the target element. count=2 for double-click.",
            "parameters": [
                "type": "object",
                "properties": [
                    "x": ["type": "number"],
                    "y": ["type": "number"],
                    "button": ["type": "string", "enum": ["left", "right"], "default": "left"],
                    "count": ["type": "integer", "default": 1, "minimum": 1, "maximum": 3]
                ],
                "required": ["x", "y"]
            ]
        ],
        [
            "type": "function",
            "name": "mouse_drag",
            "description": "Press at (from_x, from_y), drag to (to_x, to_y), release. All coords are IMAGE PIXELS from the most recent screenshot.",
            "parameters": [
                "type": "object",
                "properties": [
                    "from_x": ["type": "number"], "from_y": ["type": "number"],
                    "to_x": ["type": "number"], "to_y": ["type": "number"],
                    "duration_ms": ["type": "integer", "default": 350]
                ],
                "required": ["from_x", "from_y", "to_x", "to_y"]
            ]
        ],
        [
            "type": "function",
            "name": "scroll",
            "description": "Scroll the mouse wheel by (delta_x, delta_y) pixels. Positive y scrolls up.",
            "parameters": [
                "type": "object",
                "properties": [
                    "delta_x": ["type": "integer", "default": 0],
                    "delta_y": ["type": "integer", "default": 0]
                ],
                "required": [] as [String]
            ]
        ],
        [
            "type": "function",
            "name": "type_text",
            "description": "Type a literal string into whatever's currently focused.",
            "parameters": [
                "type": "object",
                "properties": [
                    "text": ["type": "string"]
                ],
                "required": ["text"]
            ]
        ],
        [
            "type": "function",
            "name": "press_key",
            "description": "Press a named key with optional modifiers. key examples: return, tab, space, escape, up/down/left/right, a–z, 0–9, f1–f12. modifiers is an array containing any of: cmd, shift, option, control.",
            "parameters": [
                "type": "object",
                "properties": [
                    "key": ["type": "string"],
                    "modifiers": ["type": "array", "items": ["type": "string"]]
                ],
                "required": ["key"]
            ]
        ],
        [
            "type": "function",
            "name": "calendar_add_event",
            "description": "Add an event to the user's Calendar. start is 'YYYY-MM-DD HH:MM' (24-hour, local time).",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "start": ["type": "string", "description": "YYYY-MM-DD HH:MM (24h)"],
                    "duration_minutes": ["type": "integer", "default": 60],
                    "notes": ["type": "string"],
                    "calendar": ["type": "string", "description": "Optional calendar name; default = first writable."]
                ],
                "required": ["title", "start"]
            ]
        ],
        [
            "type": "function",
            "name": "calendar_today",
            "description": "List the user's events for today.",
            "parameters": ["type": "object", "properties": [:] as [String: Any], "required": [] as [String]]
        ],
        [
            "type": "function",
            "name": "reminders_add",
            "description": "Add a reminder. due is optional 'YYYY-MM-DD HH:MM'.",
            "parameters": [
                "type": "object",
                "properties": [
                    "text": ["type": "string"],
                    "due": ["type": "string", "description": "Optional YYYY-MM-DD HH:MM"],
                    "list": ["type": "string", "description": "Optional list name; default list otherwise."]
                ],
                "required": ["text"]
            ]
        ],
        [
            "type": "function",
            "name": "notes_create",
            "description": "Create a note in Apple Notes (iCloud account).",
            "parameters": [
                "type": "object",
                "properties": ["title": ["type": "string"], "body": ["type": "string"]],
                "required": ["title", "body"]
            ]
        ],
        [
            "type": "function",
            "name": "mail_compose",
            "description": "Open a pre-filled email DRAFT in Mail (shown to the user, NEVER auto-sent).",
            "parameters": [
                "type": "object",
                "properties": [
                    "to": ["type": "string"], "subject": ["type": "string"], "body": ["type": "string"]
                ],
                "required": ["to", "subject", "body"]
            ]
        ],
        [
            "type": "function",
            "name": "run_applescript",
            "description": "Run an AppleScript. Returns stdout or an error.",
            "parameters": [
                "type": "object",
                "properties": [
                    "script": ["type": "string"]
                ],
                "required": ["script"]
            ]
        ],
        [
            "type": "function",
            "name": "run_shell",
            "description": "Run a zsh shell command. Returns combined stdout/stderr (≤4000 chars).",
            "parameters": [
                "type": "object",
                "properties": [
                    "command": ["type": "string"]
                ],
                "required": ["command"]
            ]
        ],
        [
            "type": "function",
            "name": "open_app",
            "description": "Open (launch) an application by display name (e.g. \"Safari\", \"Visual Studio Code\") or bundle id. Launches it if it isn't already running. Prefer this over AppleScript for opening apps.",
            "parameters": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "App display name or bundle id"]
                ],
                "required": ["name"]
            ]
        ],
        [
            "type": "function",
            "name": "activate_app",
            "description": "Bring an already-running application to the front by display name or bundle id.",
            "parameters": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "App display name or bundle id"]
                ],
                "required": ["name"]
            ]
        ],
        [
            "type": "function",
            "name": "list_apps",
            "description": "List the currently running, visible applications (name, bundle id, whether active).",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ]
        ],
        [
            "type": "function",
            "name": "list_windows",
            "description": "List on-screen windows with their owning app, title, and bounds (x/y/width/height in screen points). Use before set_window_bounds.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ]
        ],
        [
            "type": "function",
            "name": "set_window_bounds",
            "description": "Move and resize an app's frontmost window. Coordinates are global screen points, top-left origin.",
            "parameters": [
                "type": "object",
                "properties": [
                    "app": ["type": "string", "description": "App display name or bundle id"],
                    "x": ["type": "number"],
                    "y": ["type": "number"],
                    "width": ["type": "number"],
                    "height": ["type": "number"]
                ],
                "required": ["app", "x", "y", "width", "height"]
            ]
        ],
        [
            "type": "function",
            "name": "frontmost_app",
            "description": "Return the frontmost (active) application's name, bundle id, and pid.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ]
        ]
    ]

    /// Marks from the most recent mark_screen call, for click_mark to resolve.
    private var lastMarks: [MarkOverlay.Mark] = []

    /// Set by the realtime client to surface "AI controlling input" state to the UI.
    var inputActivity: ((Bool) -> Void)?
    /// Fires with a short human-readable label when a tool starts running.
    var onToolStart: ((String) -> Void)?
    /// Fires when a tool finishes (success or failure).
    var onToolEnd: (() -> Void)?

    func setInputActivityCallback(_ cb: @escaping (Bool) -> Void) {
        self.inputActivity = cb
    }
    func setToolCallbacks(start: @escaping (String) -> Void, end: @escaping () -> Void) {
        self.onToolStart = start
        self.onToolEnd = end
    }

    private func friendlyLabel(for tool: String) -> String {
        switch tool {
        case "see_screen":               return "looking at screen"
        case "list_ui_elements":         return "reading UI tree"
        case "click_element":            return "clicking"
        case "find_text":                return "reading text on screen"
        case "click_text":               return "clicking on text"
        case "mark_screen":              return "mapping the screen"
        case "click_mark":               return "clicking"
        case "remember":                 return "remembering"
        case "recall":                   return "recalling"
        case "web_search":               return "searching the web"
        case "fetch_url":                return "reading a page"
        case "open_url":                 return "opening a link"
        case "browser_click_text":       return "clicking in browser"
        case "browser_snapshot":         return "reading the page"
        case "browser_run_js":           return "running browser script"
        case "mouse_move":               return "moving cursor"
        case "mouse_click":              return "clicking"
        case "mouse_drag":               return "dragging"
        case "scroll":                   return "scrolling"
        case "type_text":                return "typing"
        case "press_key":                return "pressing key"
        case "hotkey":                   return "pressing keys"
        case "permissions_diagnostics":  return "checking permissions"
        case "batch_actions":            return "running steps"
        case "calendar_add_event":       return "adding to calendar"
        case "calendar_today":           return "checking your calendar"
        case "reminders_add":            return "adding a reminder"
        case "notes_create":             return "creating a note"
        case "mail_compose":             return "drafting an email"
        case "run_applescript":          return "running script"
        case "run_shell":                return "running command"
        case "open_app":                 return "opening app"
        case "activate_app":             return "switching apps"
        case "list_apps":                return "listing apps"
        case "list_windows":             return "listing windows"
        case "set_window_bounds":        return "moving window"
        case "frontmost_app":            return "checking active app"
        default:                         return tool
        }
    }

    /// Tools that change the Mac / the outside world — gated by dry-run mode.
    /// Read-only tools (see_screen, list_*, find_text, web_search, recall, …)
    /// always run so the model can still observe and plan.
    private static let mutatingTools: Set<String> = [
        "click_element", "click_text", "click_mark",
        "mouse_click", "mouse_move", "mouse_drag",
        "type_text", "press_key", "hotkey", "scroll", "batch_actions",
        "run_shell", "run_applescript", "open_url",
        "open_app", "activate_app", "set_window_bounds",
        "calendar_add_event", "reminders_add", "notes_create", "mail_compose",
        "browser_click_text", "browser_run_js"
    ]

    func dispatch(name: String, argsJSON: String) async -> ToolDispatchResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any]) ?? [:]
        let label = friendlyLabel(for: name)
        onToolStart?(label)
        defer { onToolEnd?() }

        // Dry-run mode (Settings → Behavior): describe mutating actions instead
        // of performing them. Read-only tools still run so the model can plan.
        if UserDefaults.standard.bool(forKey: "dryRun"), Self.mutatingTools.contains(name) {
            NSLog("Tool: [dry-run] would \(name)")
            return ToolDispatchResult(outputJSON: encode([
                "dry_run": true,
                "skipped_action": name,
                "would": label,
                "args": args,
                "note": "Dry-run mode is ON — this action was NOT performed. Tell the user what you would have done."
            ]), attachedImageBase64: nil)
        }

        switch name {
        case "list_ui_elements":
            let elements = AXTree.enumerateFrontmost()
            let payload: [[String: Any]] = elements.map { e in
                [
                    "role": e.role,
                    "title": e.title,
                    "frame": [
                        "x": Int(e.frame.origin.x),
                        "y": Int(e.frame.origin.y),
                        "w": Int(e.frame.size.width),
                        "h": Int(e.frame.size.height)
                    ]
                ]
            }
            return ToolDispatchResult(
                outputJSON: encode([
                    "frontmost": NSWorkspace.shared.frontmostApplication?.localizedName ?? "?",
                    "count": elements.count,
                    "elements": payload
                ]),
                attachedImageBase64: nil
            )

        case "click_element":
            let nameArg = (args["name"] as? String) ?? ""
            let roleArg = args["role"] as? String
            let count = (args["count"] as? Int) ?? 1
            NSLog("Tool: click_element name=\"\(nameArg)\" role=\(roleArg ?? "—")")
            let elements = AXTree.enumerateFrontmost()
            guard let match = AXTree.bestMatch(in: elements, name: nameArg, role: roleArg) else {
                return ToolDispatchResult(
                    outputJSON: encode([
                        "error": "no element matching \"\(nameArg)\"",
                        "hint": "call list_ui_elements to see what's available"
                    ]),
                    attachedImageBase64: nil
                )
            }
            self.inputActivity?(true)
            // Try AXPress first — no mouse simulation, no coordinate math.
            // Only do the AXPress path for single clicks; double-click needs a real click.
            let pressed = (count == 1) && AXTree.tryPress(match.element)
            if !pressed {
                let center = CGPoint(x: match.frame.midX, y: match.frame.midY)
                InputSynth.clickPoint(center, count: count)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.inputActivity?(false)
            return await confirmWithScreenshot([
                "ok": true,
                "action": "click_element",
                "via": pressed ? "AXPress" : "coordinate",
                "clicked": ["role": match.role, "title": match.title]
            ])

        case "mark_screen":
            NSLog("Tool: mark_screen")
            let shot = await ScreenCapture.shared.capture()
            guard let cg = shot.cgImage else {
                return ToolDispatchResult(outputJSON: encode(["error": "screen capture failed"]),
                                          attachedImageBase64: nil)
            }
            let ax = AXTree.enumerateFrontmost()
            let ocr = await OCR.recognize(in: cg)
            let (marks, annotated) = MarkOverlay.build(baseImage: cg, axElements: ax, ocr: ocr)
            self.lastMarks = marks
            let listing = marks.map { m -> [String: Any] in
                ["mark": m.index, "label": m.label]
            }
            return ToolDispatchResult(
                outputJSON: encode([
                    "count": marks.count,
                    "marks": listing,
                    "note": "Numbered badges are drawn on the attached image. Call click_mark with the number on your target."
                ]),
                attachedImageBase64: annotated ?? shot.imageBase64
            )

        case "click_mark":
            let n = (args["mark"] as? Int) ?? number(args["mark"]).map { Int($0) } ?? -1
            NSLog("Tool: click_mark \(n)")
            guard let m = lastMarks.first(where: { $0.index == n }) else {
                return ToolDispatchResult(outputJSON: encode([
                    "error": "no mark numbered \(n)",
                    "hint": "call mark_screen first"
                ]), attachedImageBase64: nil)
            }
            // bbox is image pixels → click via the image-pixel path (handles scale + display origin).
            let center = CGPoint(x: m.bbox.midX, y: m.bbox.midY)
            self.inputActivity?(true)
            InputSynth.click(imagePx: center, button: .left, count: 1)
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.inputActivity?(false)
            return await confirmWithScreenshot(["ok": true, "action": "click_mark",
                                                "mark": n, "label": m.label])

        case "find_text":
            let q = args["query"] as? String
            NSLog("Tool: find_text query=\(q ?? "—")")
            let shot = await ScreenCapture.shared.capture()
            guard let cg = shot.cgImage else {
                return ToolDispatchResult(outputJSON: encode(["error": "screen capture failed"]),
                                          attachedImageBase64: nil)
            }
            let matches = OCR.filter(await OCR.recognize(in: cg), query: q)
            let payload = matches.prefix(40).map { m in
                [
                    "text": m.text,
                    "bbox": [
                        "x": Int(m.bbox.origin.x),
                        "y": Int(m.bbox.origin.y),
                        "w": Int(m.bbox.size.width),
                        "h": Int(m.bbox.size.height)
                    ],
                    "confidence": Double(m.confidence)
                ] as [String: Any]
            }
            return ToolDispatchResult(
                outputJSON: encode(["count": matches.count, "matches": payload]),
                attachedImageBase64: shot.imageBase64
            )

        case "click_text":
            let q = (args["query"] as? String) ?? ""
            let idx = (args["match_index"] as? Int) ?? 0
            NSLog("Tool: click_text query=\"\(q)\" idx=\(idx)")
            let shot = await ScreenCapture.shared.capture()
            guard let cg = shot.cgImage else {
                return ToolDispatchResult(outputJSON: encode(["error": "screen capture failed"]),
                                          attachedImageBase64: nil)
            }
            let matches = OCR.filter(await OCR.recognize(in: cg), query: q)
            guard !matches.isEmpty, idx >= 0, idx < matches.count else {
                return ToolDispatchResult(
                    outputJSON: encode([
                        "error": "no text matching \"\(q)\"",
                        "ocr_count": matches.count
                    ]),
                    attachedImageBase64: shot.imageBase64
                )
            }
            let m = matches[idx]
            let center = CGPoint(x: m.bbox.midX, y: m.bbox.midY)
            self.inputActivity?(true)
            InputSynth.click(imagePx: center, button: .left, count: 1)
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.inputActivity?(false)
            return await confirmWithScreenshot([
                "ok": true,
                "action": "click_text",
                "matched_text": m.text
            ])

        case "hotkey":
            let keys = (args["keys"] as? [String]) ?? []
            NSLog("Tool: hotkey \(keys.joined(separator: "+"))")
            let modSet: Set<String> = ["cmd","command","shift","option","alt","control","ctrl"]
            let mods = keys.filter { modSet.contains($0.lowercased()) }
            let mainKey = keys.last { !modSet.contains($0.lowercased()) } ?? ""
            guard !mainKey.isEmpty else {
                return ToolDispatchResult(outputJSON: encode(["error": "no main key in \(keys)"]),
                                          attachedImageBase64: nil)
            }
            InputSynth.pressKey(mainKey, modifiers: mods)
            return await confirmWithScreenshot(["ok": true, "action": "hotkey", "keys": keys])

        case "permissions_diagnostics":
            return ToolDispatchResult(
                outputJSON: encode([
                    "microphone":          Self.authStatusString(AVCaptureDevice.authorizationStatus(for: .audio).rawValue),
                    "speech_recognition":  Self.authStatusString(Int(SFSpeechRecognizer.authorizationStatus().rawValue)),
                    "screen_recording":    CGPreflightScreenCaptureAccess() ? "authorized" : "not_authorized",
                    "accessibility":       AXIsProcessTrusted() ? "authorized" : "not_authorized"
                ]),
                attachedImageBase64: nil
            )

        case "batch_actions":
            let steps = (args["actions"] as? [[String: Any]]) ?? []
            let stopOnError = (args["stop_on_error"] as? Bool) ?? true
            NSLog("Tool: batch_actions ×\(steps.count) stopOnError=\(stopOnError)")
            self.inputActivity?(true)
            var done: [[String: Any]] = []
            var errored = false
            for step in steps {
                let stepType = (step["type"] as? String) ?? ""
                let stepResult = await runBatchStep(type: stepType, args: step)
                done.append(["type": stepType, "result": stepResult])
                if let r = stepResult as? [String: Any], r["error"] != nil {
                    errored = true
                    if stopOnError { break }
                }
            }
            self.inputActivity?(false)
            return await confirmWithScreenshot([
                "ok": !errored,
                "action": "batch_actions",
                "steps_run": done.count,
                "results": done
            ])

        case "remember":
            let content = (args["content"] as? String) ?? ""
            MemoryStore.shared.remember(content)
            NSLog("Tool: remember \"\(content.prefix(80))\"")
            return ToolDispatchResult(outputJSON: encode(["ok": true, "stored": content]),
                                      attachedImageBase64: nil)

        case "recall":
            let q = args["query"] as? String
            let items = MemoryStore.shared.recall(matching: q)
            let payload = items.suffix(40).map { ["content": $0.content] }
            return ToolDispatchResult(outputJSON: encode(["count": items.count, "memories": payload]),
                                      attachedImageBase64: nil)

        case "web_search":
            let q = (args["query"] as? String) ?? ""
            NSLog("Tool: web_search \"\(q)\"")
            let result = await WebSearch.search(q)
            return ToolDispatchResult(outputJSON: encode(result), attachedImageBase64: nil)

        case "fetch_url":
            let urlString = (args["url"] as? String) ?? ""
            NSLog("Tool: fetch_url \(urlString)")
            let result = await WebSearch.fetch(urlString)
            return ToolDispatchResult(outputJSON: encode(result), attachedImageBase64: nil)

        case "browser_click_text":
            let text = (args["text"] as? String) ?? ""
            NSLog("Tool: browser_click_text \"\(text)\"")
            let res = BrowserBridge.clickText(text)
            // Verify with a screenshot since a DOM click may change the page.
            return await confirmWithScreenshot(res)

        case "browser_snapshot":
            NSLog("Tool: browser_snapshot")
            return ToolDispatchResult(outputJSON: encode(BrowserBridge.snapshot()), attachedImageBase64: nil)

        case "browser_run_js":
            let js = (args["js"] as? String) ?? ""
            NSLog("Tool: browser_run_js \(js.prefix(80))")
            return ToolDispatchResult(outputJSON: encode(BrowserBridge.runJS(js)), attachedImageBase64: nil)

        case "open_url":
            let urlString = (args["url"] as? String) ?? ""
            NSLog("Tool: open_url \(urlString)")
            guard let url = URL(string: urlString), url.scheme != nil else {
                return ToolDispatchResult(outputJSON: encode(["error": "invalid URL"]),
                                          attachedImageBase64: nil)
            }
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            // Give the browser a moment to render, then attach the screen.
            try? await Task.sleep(nanoseconds: 800_000_000)
            return await confirmWithScreenshot(["ok": true, "action": "open_url", "url": urlString])

        case "see_screen":
            let result = await ScreenCapture.shared.capture()
            return ToolDispatchResult(
                outputJSON: encode(result.metadata),
                attachedImageBase64: result.imageBase64
            )

        case "mouse_move":
            let x = number(args["x"]) ?? 0
            let y = number(args["y"]) ?? 0
            NSLog("Tool: mouse_move (img px \(x),\(y))")
            self.inputActivity?(true)
            InputSynth.moveCursor(imagePx: CGPoint(x: x, y: y))
            self.inputActivity?(false)
            return await confirmWithScreenshot(["ok": true, "action": "mouse_move"])

        case "mouse_click":
            let x = number(args["x"]) ?? 0
            let y = number(args["y"]) ?? 0
            let buttonStr = (args["button"] as? String) ?? "left"
            let button: CGMouseButton = (buttonStr == "right") ? .right : .left
            let count = (args["count"] as? Int) ?? 1
            NSLog("Tool: mouse_click \(buttonStr) ×\(count) (img px \(x),\(y))")
            self.inputActivity?(true)
            InputSynth.click(imagePx: CGPoint(x: x, y: y), button: button, count: count)
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.inputActivity?(false)
            return await confirmWithScreenshot(["ok": true, "action": "mouse_click"])

        case "mouse_drag":
            let fx = number(args["from_x"]) ?? 0
            let fy = number(args["from_y"]) ?? 0
            let tx = number(args["to_x"])   ?? 0
            let ty = number(args["to_y"])   ?? 0
            let dur = (args["duration_ms"] as? Int) ?? 350
            NSLog("Tool: mouse_drag (img px \(fx),\(fy))→(\(tx),\(ty)) in \(dur)ms")
            self.inputActivity?(true)
            InputSynth.drag(fromPx: CGPoint(x: fx, y: fy),
                            toPx: CGPoint(x: tx, y: ty),
                            durationMs: dur)
            self.inputActivity?(false)
            return await confirmWithScreenshot(["ok": true, "action": "mouse_drag"])

        case "scroll":
            let dx = Int32((args["delta_x"] as? Int) ?? 0)
            let dy = Int32((args["delta_y"] as? Int) ?? 0)
            NSLog("Tool: scroll (\(dx),\(dy))")
            InputSynth.scroll(deltaX: dx, deltaY: dy)
            return await confirmWithScreenshot(["ok": true, "action": "scroll"])

        case "type_text":
            let text = (args["text"] as? String) ?? ""
            NSLog("Tool: type_text \(text.count) chars")
            self.inputActivity?(true)
            // Long strings: paste via clipboard (~50ms instead of ~5s of CGEvent loop).
            // Short strings: per-character — more compatible with paste-filtering fields.
            if text.count > 30 {
                await pasteText(text)
            } else {
                InputSynth.type(text)
            }
            self.inputActivity?(false)
            return await confirmWithScreenshot(["ok": true, "action": "type_text"])

        case "press_key":
            let key = (args["key"] as? String) ?? ""
            let mods = (args["modifiers"] as? [String]) ?? []
            NSLog("Tool: press_key \(mods.joined(separator: "+"))+\(key)")
            InputSynth.pressKey(key, modifiers: mods)
            return await confirmWithScreenshot(["ok": true, "action": "press_key"])

        case "calendar_add_event":
            NSLog("Tool: calendar_add_event")
            let out = NativeConnectors.calendarAddEvent(
                title: (args["title"] as? String) ?? "",
                start: (args["start"] as? String) ?? "",
                durationMinutes: (args["duration_minutes"] as? Int) ?? 60,
                notes: (args["notes"] as? String) ?? "",
                calendar: (args["calendar"] as? String) ?? "")
            return ToolDispatchResult(outputJSON: encode(out), attachedImageBase64: nil)

        case "calendar_today":
            NSLog("Tool: calendar_today")
            return ToolDispatchResult(outputJSON: encode(NativeConnectors.calendarToday()), attachedImageBase64: nil)

        case "reminders_add":
            NSLog("Tool: reminders_add")
            let out = NativeConnectors.remindersAdd(
                text: (args["text"] as? String) ?? "",
                due: (args["due"] as? String) ?? "",
                list: (args["list"] as? String) ?? "")
            return ToolDispatchResult(outputJSON: encode(out), attachedImageBase64: nil)

        case "notes_create":
            NSLog("Tool: notes_create")
            let out = NativeConnectors.notesCreate(
                title: (args["title"] as? String) ?? "",
                body: (args["body"] as? String) ?? "")
            return ToolDispatchResult(outputJSON: encode(out), attachedImageBase64: nil)

        case "mail_compose":
            NSLog("Tool: mail_compose")
            let out = NativeConnectors.mailCompose(
                to: (args["to"] as? String) ?? "",
                subject: (args["subject"] as? String) ?? "",
                body: (args["body"] as? String) ?? "")
            return ToolDispatchResult(outputJSON: encode(out), attachedImageBase64: nil)

        case "run_applescript":
            let script = (args["script"] as? String) ?? ""
            NSLog("Tool: run_applescript: \(script.prefix(120))")
            return ToolDispatchResult(outputJSON: encode(AppleScriptRunner.run(script)),
                                      attachedImageBase64: nil)

        case "run_shell":
            let cmd = (args["command"] as? String) ?? ""
            NSLog("Tool: run_shell: \(cmd.prefix(120))")
            let out = await ShellRunner.run(cmd)
            return ToolDispatchResult(outputJSON: encode(out), attachedImageBase64: nil)

        case "open_app":
            let name = (args["name"] as? String) ?? ""
            NSLog("Tool: open_app \(name)")
            let out = await MainActor.run { WindowManager.openApp(name: name) }
            return ToolDispatchResult(outputJSON: encode(out), attachedImageBase64: nil)

        case "activate_app":
            let name = (args["name"] as? String) ?? ""
            NSLog("Tool: activate_app \(name)")
            let out = await MainActor.run { WindowManager.activateApp(query: name) }
            return ToolDispatchResult(outputJSON: encode(out), attachedImageBase64: nil)

        case "list_apps":
            let apps = await MainActor.run { WindowManager.listApps() }
            return ToolDispatchResult(outputJSON: encode(["apps": apps]), attachedImageBase64: nil)

        case "list_windows":
            let windows = WindowManager.listWindows()
            return ToolDispatchResult(outputJSON: encode(["windows": windows]), attachedImageBase64: nil)

        case "set_window_bounds":
            let app = (args["app"] as? String) ?? ""
            let x = number(args["x"]) ?? 0
            let y = number(args["y"]) ?? 0
            let w = number(args["width"]) ?? 0
            let h = number(args["height"]) ?? 0
            NSLog("Tool: set_window_bounds \(app) \(x),\(y) \(w)x\(h)")
            let out = await MainActor.run { WindowManager.setWindowBounds(appQuery: app, x: x, y: y, width: w, height: h) }
            return await confirmWithScreenshot(out)

        case "frontmost_app":
            let out = await MainActor.run { WindowManager.frontmostApp() }
            return ToolDispatchResult(outputJSON: encode(out), attachedImageBase64: nil)

        default:
            return ToolDispatchResult(outputJSON: encode(["error": "unknown tool \(name)"]),
                                      attachedImageBase64: nil)
        }
    }

    /// Wait briefly for the UI to settle, then capture the screen. Returns
    /// the original tool output dict plus an attached screenshot so the model
    /// can visually verify what its action did.
    private func confirmWithScreenshot(_ output: [String: Any]) async -> ToolDispatchResult {
        try? await Task.sleep(nanoseconds: 120_000_000)  // let UI redraw
        let shot = await ScreenCapture.shared.capture()
        var merged = output
        merged["screenshot"] = shot.metadata
        return ToolDispatchResult(outputJSON: encode(merged),
                                  attachedImageBase64: shot.imageBase64)
    }

    /// JSON numbers may arrive as Int or Double; normalize to Double.
    private func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int    { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String, let d = Double(s) { return d }
        return nil
    }


    private func encode(_ obj: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: data, encoding: .utf8) { return s }
        return "{}"
    }

    /// Run one step of a batch_actions call. Returns a plain dict that gets
    /// folded into the batch result. Does NOT take a screenshot per step.
    private func runBatchStep(type: String, args: [String: Any]) async -> Any {
        switch type {
        case "click_element":
            let nameArg = (args["name"] as? String) ?? ""
            let roleArg = args["role"] as? String
            let elements = AXTree.enumerateFrontmost()
            guard let match = AXTree.bestMatch(in: elements, name: nameArg, role: roleArg) else {
                return ["error": "no element matching \"\(nameArg)\""]
            }
            let pressed = AXTree.tryPress(match.element)
            if !pressed {
                InputSynth.clickPoint(CGPoint(x: match.frame.midX, y: match.frame.midY))
            }
            return ["ok": true, "via": pressed ? "AXPress" : "coordinate",
                    "clicked": match.title]
        case "mouse_click":
            let x = number(args["x"]) ?? 0
            let y = number(args["y"]) ?? 0
            let buttonStr = (args["button"] as? String) ?? "left"
            let button: CGMouseButton = (buttonStr == "right") ? .right : .left
            let count = (args["count"] as? Int) ?? 1
            InputSynth.click(imagePx: CGPoint(x: x, y: y), button: button, count: count)
            return ["ok": true]
        case "mouse_move":
            let x = number(args["x"]) ?? 0
            let y = number(args["y"]) ?? 0
            InputSynth.moveCursor(imagePx: CGPoint(x: x, y: y))
            return ["ok": true]
        case "type_text":
            let text = (args["text"] as? String) ?? ""
            if text.count > 30 { await pasteText(text) } else { InputSynth.type(text) }
            return ["ok": true]
        case "press_key":
            let key = (args["key"] as? String) ?? ""
            let mods = (args["modifiers"] as? [String]) ?? []
            InputSynth.pressKey(key, modifiers: mods)
            return ["ok": true]
        case "hotkey":
            let keys = (args["keys"] as? [String]) ?? []
            let modSet: Set<String> = ["cmd","command","shift","option","alt","control","ctrl"]
            let mods = keys.filter { modSet.contains($0.lowercased()) }
            let mainKey = keys.last { !modSet.contains($0.lowercased()) } ?? ""
            if mainKey.isEmpty { return ["error": "no main key"] }
            InputSynth.pressKey(mainKey, modifiers: mods)
            return ["ok": true]
        case "scroll":
            let dx = Int32((args["delta_x"] as? Int) ?? 0)
            let dy = Int32((args["delta_y"] as? Int) ?? 0)
            InputSynth.scroll(deltaX: dx, deltaY: dy)
            return ["ok": true]
        case "sleep":
            let seconds = number(args["seconds"]) ?? 0
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return ["ok": true]
        case "run_shell":
            let cmd = (args["command"] as? String) ?? ""
            NSLog("Batch: run_shell: \(cmd.prefix(120))")
            return await ShellRunner.run(cmd)
        case "run_applescript":
            let script = (args["script"] as? String) ?? ""
            NSLog("Batch: run_applescript: \(script.prefix(120))")
            return AppleScriptRunner.run(script)
        case "open_url":
            let urlString = (args["url"] as? String) ?? ""
            guard let url = URL(string: urlString), url.scheme != nil else {
                return ["error": "invalid URL"]
            }
            NSLog("Batch: open_url: \(urlString)")
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return ["ok": true, "url": urlString]
        default:
            return ["error": "unsupported batch action \"\(type)\""]
        }
    }

    /// Clipboard-based paste for fast bulk text entry. Stashes the existing
    /// pasteboard, writes the text, sends Cmd+V, then restores.
    private func pasteText(_ text: String) async {
        let pb = NSPasteboard.general
        let saved = await MainActor.run { pb.string(forType: .string) }
        await MainActor.run {
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
        InputSynth.pressKey("v", modifiers: ["cmd"])
        try? await Task.sleep(nanoseconds: 250_000_000)
        await MainActor.run {
            pb.clearContents()
            if let s = saved { pb.setString(s, forType: .string) }
        }
    }

    private static func authStatusString(_ raw: Int) -> String {
        switch raw {
        case 0: return "not_determined"
        case 1: return "restricted"
        case 2: return "denied"
        case 3: return "authorized"
        default: return "unknown(\(raw))"
        }
    }
}
