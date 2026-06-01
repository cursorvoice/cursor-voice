# Research: Computer Control Plus → ideas for Cursor Voice

**Source examined:** `~/plugins/computer-control-plus` (v0.6.0) — a local Codex MCP plugin you wrote, 947 LOC Swift + 1,569 LOC Python. Architecture: a persistent Swift native helper subprocess for input/AX/OCR, wrapped by a Python MCP server that the Codex CLI calls into.

This doc maps what CCP does, finds the *seven* things that would meaningfully improve Cursor Voice's reliability — particularly the "clicks miss too often" problem — and ranks them by impact.

---

## Side-by-side capability matrix

| Capability | Computer Control Plus | Cursor Voice (now) |
| ---------- | --------------------- | ------------------ |
| Screenshot | Native Quartz (`CGDisplayCreateImage`), `screencapture` CLI fallback for cursor | ScreenCaptureKit native-pixel |
| Mouse / keyboard | Persistent native helper, CGEvent | One-shot CGEvent per call, `InputSynth` |
| AX tree walk | Yes — `accessibility_snapshot` (depth/node-limited) | Yes — `AXTree.enumerateFrontmost` |
| Find element by name | `find_ui_elements(query, role)` | `AXTree.bestMatch` |
| Click element | **AXPress first, coordinate-click fallback** | Coordinate-click only |
| **OCR** | **`ocr_screen` + `click_text` via Vision framework** | ❌ none |
| Image template match | OpenCV `find_image`, `wait_for_image` | ❌ none |
| **Batched actions** | `batch_actions([…])` — one MCP call runs N steps | ❌ single tool per call |
| Hotkey (multi-key) | `hotkey([k1, k2, …])` | `press_key(key, modifiers)` (only one main key) |
| **Clipboard-paste typing** | `type_text(text, restore_clipboard=True)` | per-char CGEvent only |
| Permission diagnostics | `permission_diagnostics`, `open_permission_settings` | Settings UI only, not a tool |
| Window mgmt | `list_windows`, `set_window_bounds`, `activate_app` | AppleScript only |
| Warm-up of native frameworks | `warm_up(...)` | n/a (always-running process) |
| Visible cursor indicator | Separate Python NSWindow that flashes at click point | `CursorHalo` panel follows cursor continuously |
| Voice in/out | ❌ | ✅ realtime |
| Wake word | ❌ | ✅ SFSpeechRecognizer |
| App distribution | n/a (local plugin) | Universal macOS app, DMG, brew tap, auto-update |
| Web search | ❌ | DDG scrape + fetch_url |
| Persistent memory | ❌ | JSON memory store |

---

## Things to port — ranked by impact on the "clicks miss too much" problem

### 1. ★★★ Try AXPress before coordinate-clicking

CCP's `click_ui_element` calls `AXUIElementPerformAction(element, kAXPressAction)` first. If the element supports `AXPress`, the action fires *without any mouse simulation at all* — no coordinate math, no scaling, no cursor movement, no event-loop race. Coordinate-center-click is the fallback.

This is the single biggest accuracy win available. The current `click_element` tool in Cursor Voice computes the AX frame's center and synthesizes a CGEvent click — that still has Retina, multi-display, and pixel-rounding failure modes. AXPress sidesteps all of them.

```swift
// New shape for click_element internals:
let actionResult = AXUIElementPerformAction(element, kAXPressAction as CFString)
if actionResult == .success {
    return // done — no click synthesized
}
// fallback to coordinate click at frame center
InputSynth.clickPoint(CGPoint(x: frame.midX, y: frame.midY))
```

`AXPressAction` works on every standard `AXButton`, `AXMenuItem`, `AXCheckBox`, `AXRadioButton`, `AXPopUpButton`, and many `AXLink` elements. **Estimated effect**: lifts native-UI click accuracy from ~70% to ~95%+.

Where to put it: `Capabilities/AXTree.swift` (add `performPress(_ element:)`) + `Realtime/ToolHandler.swift` (modify the `click_element` case).

### 2. ★★★ OCR-based text targeting (`ocr_screen` + `click_text`)

When AX is empty — web content in Safari, Electron apps, Canvas/WebGL UIs, dynamically painted content — the only path Cursor Voice has today is the model squinting at pixels. CCP uses macOS's built-in **Vision framework** (`VNRecognizeTextRequest`) to OCR the screen, returns word boxes, and exposes `click_text(query)` that clicks the center of the matched box.

```swift
import Vision

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate    // or .fast for speed
let handler = VNImageRequestHandler(cgImage: screenshotCG)
try handler.perform([request])
let results = (request.results ?? []).compactMap { obs in
    obs.topCandidates(1).first.map { ($0.string, obs.boundingBox) }
}
```

Vision returns `boundingBox` in normalized image coords (origin bottom-left). Convert to screen points and we have a click target.

New tools to add: `find_text(query)` (returns matches with boxes) and `click_text(query)`. Combined with `click_element` (AX path) the model would have *four* targeting strategies: open_url → AppleScript → click_element (AX/AXPress) → click_text (OCR/Vision) → mouse_click (last-resort pixel pick). That covers every kind of UI.

**Estimated effect**: removes the "miss" tail for anything visible-but-unlabeled. No extra dependencies — Vision is in macOS.

Where to put it: new `Capabilities/OCR.swift`, plus tool entries in `ToolHandler`.

### 3. ★★★ `batch_actions` — run a sequence in one tool call

Right now the model emits one tool call per click/type/key, and each round-trip costs:
- the model's response.create cycle on the server
- function_call_arguments streaming
- our local dispatch + screenshot wait
- response audio

For a 5-step UI flow that's ~5× the latency. CCP's `batch_actions` takes a list of action dicts and runs them sequentially (with sleeps between), returning a single combined result. The model picks "open Safari and search for X" → one tool call with `[activate_app, hotkey(cmd+l), type_text(...), press_key(enter)]`.

Schema (from CCP):
```json
{
  "actions": [
    {"action": "press_key", "key": "l", "modifiers": ["cmd"]},
    {"action": "type_text", "text": "youtube.com"},
    {"action": "press_key", "key": "return"},
    {"action": "sleep",     "seconds": 0.6}
  ],
  "stop_on_error": true
}
```

**Estimated effect**: 3–5× faster multi-step automation, fewer chances for the model to drift between steps.

Where to put it: new case in `ToolHandler.dispatch`. After the batch finishes, attach a single after-screenshot rather than one per step.

### 4. ★★ Clipboard-paste fast text entry

CCP's `type_text` has `restore_clipboard=True` mode: it stashes the current clipboard, writes the text to the pasteboard, sends `Cmd+V`, restores the clipboard. For anything longer than ~10 characters this is dramatically faster than the current per-character `keyboardSetUnicodeString` loop in `InputSynth.type`.

For short strings the per-char path is fine (more compatible with input fields that filter keystrokes). Use clipboard mode automatically when `text.count > 30` or expose as an option.

```swift
let pb = NSPasteboard.general
let saved = pb.string(forType: .string)
pb.clearContents()
pb.setString(text, forType: .string)
InputSynth.pressKey("v", modifiers: ["cmd"])
// after a beat:
pb.clearContents(); if let s = saved { pb.setString(s, forType: .string) }
```

**Estimated effect**: typing a paragraph drops from ~5s of CGEvent loop to ~50ms.

### 5. ★★ `hotkey([list])` — proper multi-key combos

CCP's `hotkey` takes a list like `["cmd", "shift", "t"]` and presses them in order (modifiers held, main key tapped, modifiers released). Cursor Voice's `press_key(key, modifiers)` is the same shape conceptually but limited to one main key — it can't express things like `Cmd+K Cmd+S` (chord) cleanly.

Add a `hotkey(keys)` tool alongside `press_key`. Internally express as press-down sequence then release sequence so modifiers properly stack.

### 6. ★★ Permission diagnostics as a tool

CCP exposes `permission_diagnostics` and `open_permission_settings` as tools the model can call. When something fails ("I tried to screenshot but got an error"), the model can self-explain: call `permission_diagnostics`, see that Screen Recording isn't granted, and tell the user concretely *"Screen Recording isn't enabled — open System Settings → Privacy → Screen Recording and enable Cursor Voice, then quit and reopen me."*

```swift
case "permissions_diagnostics":
    return [
        "microphone":           AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
        "speech_recognition":   SFSpeechRecognizer.authorizationStatus().rawValue,
        "screen_recording":     CGPreflightScreenCaptureAccess(),
        "accessibility":        AXIsProcessTrusted()
    ]
```

**Estimated effect**: removes a class of "it just doesn't work" frustration. Users get a clear diagnosis instead of silence.

### 7. ★ First-class app + window management

CCP has `open_application`, `activate_app`, `list_apps`, `frontmost_app`, `list_windows`, `set_window_bounds` as discrete tools. Cursor Voice forces the model to do all of this through `run_applescript`, which works but is verbose and forces the model to write AppleScript syntax every time.

Lifting these to first-class tools makes the model's job easier and reduces script-generation errors:

```swift
case "activate_app":  // by name → NSRunningApplication.activate
case "open_app":      // by name or .app path → NSWorkspace.open
case "list_windows":  // CGWindowListCopyWindowInfo + AX frames
case "set_window_bounds": // AX position/size on the matched window
case "frontmost_app": // NSWorkspace.frontmostApplication
```

---

## Things to skip / not worth porting

- **The persistent native helper subprocess pattern.** CCP needs it because Python can't post CGEvents quickly. Cursor Voice is already native Swift end-to-end — keeping CGEvent calls inline in the same process is fine and faster.
- **`warm_up`.** CV runs continuously while the orb is up. AppKit/Quartz are already loaded by then.
- **Visible cursor indicator (Python NSWindow).** We already have `CursorHalo`, arguably nicer (continuous follow + intensity-modulated aurora vs. discrete flash).
- **OpenCV image template matching.** Niche enough that I'd defer until OCR-clicking proves insufficient. Vision OCR covers most "find this on screen" needs without the OpenCV dependency.

---

## Suggested implementation order

If I had a day, here's what I'd do in this order:

1. **AXPress in `click_element`** — half an hour. Biggest accuracy lift.
2. **Permissions diagnostics tool** — fifteen minutes. Pure UX, lets the model self-explain failures.
3. **`hotkey([list])`** + **clipboard-paste `type_text`** — an hour. Small, useful, low risk.
4. **OCR — `find_text` + `click_text`** — two hours. Solves the "labelled-but-not-AX" failure mode.
5. **`batch_actions`** — two hours. Big latency reduction.
6. **First-class app/window tools** — an hour. Quality of life.

Total: a solid afternoon for a major usability + reliability lift. Each item is independent; you can stop at any point.

---

## Open question

Worth doing all of it, or are there specific failure modes you care most about right now? My read is that #1 (AXPress) and #4 (OCR) together would fix the bulk of the "clicks miss too much" issue — they cost ~2.5 hours and would push the accuracy from "useful but flaky" to "reliable enough to trust on real tasks."
