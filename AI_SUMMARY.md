# Cursor Voice — Project Briefing (for another AI)

This document is a self-contained handover. Read it end-to-end and you can pick up the project cold.

---

## 1. What it is, in one paragraph

**Cursor Voice** is a native macOS menu-bar app written in Swift (no Xcode required to build). The user presses a global hotkey, a small aurora-gradient orb materializes at the cursor with a spring + shockwave reveal animation, and the user has an open voice channel to the OpenAI Realtime API. While the orb is open, the model can: take screenshots of the screen, enumerate UI elements via the macOS Accessibility tree, click elements by name, synthesize raw mouse and keyboard input via `CGEvent`, run AppleScript and shell commands, fetch URLs and scrape DuckDuckGo for live web information, open URLs, and persist long-term memory in a local JSON file. The user can interrupt the model mid-sentence and the model stops cleanly. The whole loop — voice in, see + act, voice out — runs over a single `URLSessionWebSocketTask` to `wss://api.openai.com/v1/realtime`.

---

## 2. Distribution

- **Repo**: https://github.com/tottenabderrahmane1-create/cursor-voice (public, MIT)
- **Homebrew tap**: https://github.com/tottenabderrahmane1-create/homebrew-cursor-voice
- **Latest release**: v0.2.0 (DMG 2.3 MB, ad-hoc signed + hardened runtime)
- Three install paths, all live:
  - `curl -fsSL https://raw.githubusercontent.com/tottenabderrahmane1-create/cursor-voice/main/install.sh | bash`
  - `brew tap tottenabderrahmane1-create/cursor-voice && brew install --cask cursor-voice`
  - Drag-from-DMG manual install
- **No paid Apple Developer ID.** Code is ad-hoc signed (`codesign --sign -`). Curl installer and Homebrew cask both run `xattr -dr com.apple.quarantine` post-install to bypass Gatekeeper.

---

## 3. Build system

No Xcode project file. Plain Swift sources compiled directly with `swiftc` from Command Line Tools.

- `scripts/build.sh`
  - Builds in `/tmp/cursorvoice-build/` (iCloud Drive on the source tree adds xattrs that break hardened-runtime signing; building in `/tmp` avoids it).
  - Compiles every `.swift` under `Sources/CursorVoice/` with `swiftc -O -target arm64-apple-macos14.0`.
  - Generates `.icns` via `iconutil` from the PNGs in `Sources/CursorVoice/Assets.xcassets/AppIcon.appiconset/`.
  - Writes `Info.plist` (LSUIElement=true, all usage descriptions).
  - `xattr -cr` then `codesign --force --deep --sign - --options runtime --entitlements entitlements.plist --timestamp=none`.
  - Mirrors the built bundle into `$ROOT/build/` for convenience.
- `scripts/dmg.sh` — `hdiutil` + ditto to a drag-to-Applications DMG. Prints SHA256 for the cask.
- `install.sh` — end-user curl installer.
- `entitlements.plist` — `app-sandbox=false`, `device.audio-input`, `automation.apple-events`, `network.client`, `cs.allow-jit`, `cs.allow-unsigned-executable-memory`, `cs.disable-library-validation`.

Architecture: arm64-only. Deployment target: macOS 14 (Sonoma).

---

## 4. Source layout (≈3,400 LOC Swift)

```
Sources/CursorVoice/
├── App.swift                       # @main + AppDelegate; MenuBarExtra; Settings scene
├── AppCoordinator.swift            # Owns lifecycle: hotkey + orb + realtime + halo + wake word
├── PermissionsOnboarding.swift     # Requests Mic/Speech/Screen/AX prompts at first launch
├── MenuBarIcon.swift               # Loads colored aurora orb glyph for the menu bar
├── UpdateChecker.swift             # GitHub releases polling + in-place auto-update
│
├── Orb/
│   ├── OrbPanel.swift              # NSPanel: borderless, non-activating, popUpMenu level
│   ├── OrbWindowController.swift   # Position panel near cursor, install dismiss monitors
│   ├── OrbView.swift               # SwiftUI: aurora orb, reveal anim, status pill, transcript
│   ├── OrbState.swift              # ObservableObject for orb UI state
│   ├── CursorTracker.swift         # 60Hz timer polling NSEvent.mouseLocation
│   └── CursorHalo.swift            # Second NSPanel pinned to cursor; gradient aura, breathes
│
├── Hotkey/
│   └── GlobalHotkey.swift          # Carbon RegisterEventHotKey wrapper
│
├── Realtime/
│   ├── RealtimeClient.swift        # WebSocket + barge-in + tool dispatch glue
│   ├── AudioEngine.swift           # AVAudioEngine: 24kHz PCM16 capture + playback w/ fade
│   └── ToolHandler.swift           # Actor dispatching every tool the model can call
│
├── WakeWord/
│   └── WakeWordDetector.swift      # SFSpeechRecognizer continuous recognition
│
├── Capabilities/
│   ├── ScreenCapture.swift         # ScreenCaptureKit: native-res JPEG, ratio tracking
│   ├── InputSynth.swift            # CGEvent mouse/keyboard, event tagging
│   ├── AXTree.swift                # Accessibility tree walk + bestMatch
│   ├── AppleScriptRunner.swift     # NSAppleScript
│   ├── ShellRunner.swift           # Process (zsh) with destructive-cmd blocklist
│   ├── WebSearch.swift             # DDG HTML scrape + URL fetch + HTML strip
│   └── MemoryStore.swift           # JSON file in ~/Library/Application Support
│
└── Settings/
    ├── SettingsView.swift          # TabView: General / Permissions / Advanced
    ├── SettingsStore.swift         # @Published settings; UserDefaults + Keychain
    ├── KeychainStore.swift         # Generic password item for API key
    ├── HotkeyRecorderButton.swift  # Capture a global hotkey from key events
    ├── PermissionsView.swift       # Live status + deep-link buttons
    └── UpdateBanner.swift          # Banner shown when update is available

entitlements.plist
scripts/build.sh
scripts/dmg.sh
install.sh
Casks/cursor-voice.rb
README.md
LICENSE                             # MIT
```

---

## 5. Runtime architecture

```
       AppDelegate
            │
            │ creates
            ▼
       AppCoordinator (@MainActor)
   ┌────────┼────────┬───────────────┬─────────────────┐
   │        │        │               │                 │
GlobalHotkey  WakeWordDetector  OrbWindowController  CursorHalo (lazy)
   │                                  │                 │
   │ on press                         │ contains
   │                                  ▼
   └────────────► toggle()         OrbPanel (NSPanel borderless)
                     │                 │ hosts
                     │                 ▼
                     │             NSHostingView<OrbView>
                     │
                     ▼
                  activate() ──► startRealtime(apiKey)
                                       │ creates
                                       ▼
                                 RealtimeClient (URLSessionWebSocketTask)
                                 │   ├── AudioEngine (AVAudioEngine 24kHz PCM16)
                                 │   └── ToolHandler (actor)
                                 │           │ dispatches to
                                 │           ▼
                                 │       Capabilities/* (Screen, InputSynth,
                                 │       AXTree, WebSearch, Memory, AppleScript, Shell)
                                 │
                                 └── onStateChange / onAudioLevel / onTranscript
                                       /onToolStart/End/onInputActivity
                                       └─► OrbState (@MainActor ObservableObject)
                                                 │
                                                 ▼
                                             OrbView re-renders
```

---

## 6. Realtime API integration (CRITICAL details — easy to get wrong)

- **Endpoint**: `wss://api.openai.com/v1/realtime?model={model}` (GA endpoint, NOT the beta one).
- **Headers**: `Authorization: Bearer <key>`. **Do NOT send `OpenAI-Beta: realtime=v1`** — it forces the beta API shape and the server rejects with code 4000.
- **`session.update` shape (GA)**:
  ```json
  {
    "type": "session.update",
    "session": {
      "type": "realtime",
      "model": "gpt-realtime",
      "output_modalities": ["audio"],
      "instructions": "...",
      "audio": {
        "input": {
          "format": { "type": "audio/pcm", "rate": 24000 },
          "turn_detection": {
            "type": "server_vad",
            "threshold": 0.5,
            "prefix_padding_ms": 200,
            "silence_duration_ms": 400
          },
          "transcription": { "model": "whisper-1" }
        },
        "output": {
          "format": { "type": "audio/pcm", "rate": 24000 },
          "voice": "marin"
        }
      },
      "tools": [...],
      "tool_choice": "auto"
    }
  }
  ```
- **Threshold value must be IEEE-754 exact**. `0.42` serializes to 17 decimal places via `JSONSerialization` and the server rejects with `"max decimal places exceeded"`. Use clean fractions: 0.5, 0.25, 0.75 are safe.
- **Server-side VAD** is more responsive for barge-in than semantic_vad.
- **Output event names** (GA): `response.output_audio.delta`, `response.output_audio.done`, `response.output_audio_transcript.delta` (the code also accepts legacy `response.audio.*` for compatibility).
- **Barge-in flow** (`RealtimeClient.barge`):
  1. `audio.cancelPlayback()` — sets mixer volume to 0, stops + flushes `AVAudioPlayerNode`, restores volume after 40ms.
  2. Send `response.cancel`.
  3. Send `conversation.item.truncate` with `audio_end_ms = (emittedOutputBytes / 2) * 1000 / 24000` so server context matches what user actually heard.
  4. Set `activeResponseId = nil`. Every audio/transcript delta handler guards `guard activeResponseId != nil` — stragglers in flight from the server post-cancel are dropped, otherwise the model would keep talking after interruption.
- **Image input** (after `see_screen`): inject `conversation.item.create` with `{ "type":"message", "role":"user", "content":[{ "type":"input_image", "image_url":"data:image/jpeg;base64,..." }] }` BEFORE the `function_call_output`, then `response.create`. The model then references the screenshot in its next response.
- **Available voices**: `marin`, `cedar`, `alloy`, `ash`, `ballad`, `coral`, `echo`, `sage`, `shimmer`, `verse`. Pickable in Settings → Advanced; changes trigger a graceful reconnect mid-session.
- **Available models in UI**: `gpt-realtime` (default GA), `gpt-realtime-2` (reasoning), `gpt-realtime-1.5` (best voice), `gpt-realtime-mini` (cheap), `gpt-realtime-translate`.

---

## 7. Tools exposed to the model

All functions return JSON strings that the model receives as `function_call_output`. After every action that changes UI state, a fresh screenshot is auto-attached as the next `input_image` (the model is instructed to check it).

| Tool | Args | Behavior |
| ---- | ---- | -------- |
| `see_screen` | – | ScreenCaptureKit at NATIVE pixel res, JPEG q=0.72; excludes our own windows from capture; sets `ScreenCapture.pointsPerImagePixel` for later input synth. |
| `list_ui_elements` | – | Walks AX tree of frontmost app's focused window; returns flat list of `{role, title, frame{x,y,w,h}}` for buttons/links/textfields/menu items/etc. Frames are in screen points, top-left origin. |
| `click_element` | `name`, `role?`, `count?` | `AXTree.bestMatch` (exact > prefix > contains > value match) → `InputSynth.clickPoint(midX, midY)`. **THIS IS THE RELIABLE PATH** — pixel-perfect, label-based. |
| `mouse_move` / `mouse_click` / `mouse_drag` | x,y in image pixels | CGEvent posts via dedicated `CGEventSource(stateID: .privateState)`, with `eventSourceUserData=0x4356_4F52_4250_5453` so our own global click-monitor can identify and ignore them. Coords are converted via the `pointsPerImagePixel` ratio recorded by the most recent screenshot. |
| `scroll` / `type_text` / `press_key` | – | CGEvent. `press_key` accepts `"return", "tab", "space", "escape", "up/down/left/right", "a-z", "0-9", "f1-f12"` with modifier array `["cmd","shift","option","control"]`. |
| `open_url` | `url` | `NSWorkspace.shared.open` — preferred over clicking through Safari. |
| `web_search` | `query` | Fetches `https://html.duckduckgo.com/html/?q=...`, regex-parses results, unwraps DDG redirect URLs (`uddg=...`), returns top 6 `{title, url, snippet}`. No API key. |
| `fetch_url` | `url` | URLSession download, HTML strip (drops `<script>`, `<style>`, `<noscript>`, all tags; decodes common entities; collapses whitespace), trims to 4000 chars. |
| `run_applescript` | `script` | `NSAppleScript.executeAndReturnError`. |
| `run_shell` | `command` | `/bin/zsh -l -c`; blocks `rm -rf`, `sudo`, `mkfs`, `dd if=`, `shutdown`, `halt`, `diskutil erase`. Captures stdout+stderr, trimmed to 4000 chars. |
| `remember` | `content` | Appends to JSON memory store. Deduped case-insensitive (re-add bumps timestamp). Capped at 200. |
| `recall` | `query?` | Returns matching memories. |

Tool calls drive a "current action" label in the orb status pill ("looking at screen…", "clicking…", "searching the web…", etc.).

---

## 8. System prompt (current)

The model is told, in priority order:

1. **Speaking**: silent execution; speak only on completion (one short sentence), clarification need, or error. For complex tasks (>3 tool calls): one brief status sentence before starting, then silent.
2. **Cancel intents**: "nevermind", "stop", "cancel", "wait", "actually", "forget it" → halt immediately, no pending tools.
3. **Ground truth = screen**: `see_screen` before any action that depends on UI state. Re-call between steps.
4. **Latest info**: `web_search` then optionally `fetch_url`. Don't fake answers for time-sensitive questions.
5. **Tool priority**: `web_search`/`fetch_url` → `open_url` → `run_applescript` → `list_ui_elements`+`click_element` → `press_key`/keyboard shortcuts → `run_shell` → `mouse_click` (LAST resort, for canvases / custom-painted UI without AX).
6. **Verification loop**: after every action, the auto-attached screenshot is the source of truth. Compare to previous. If the expected change didn't happen, look again, adjust — don't blindly re-click.
7. **Memory**: at session start the model receives "WHAT YOU REMEMBER ABOUT THIS USER" — all memories appended to instructions. Use `remember` for durable user facts.
8. **Safety**: never `rm -rf`, never `sudo`.

Coordinates: image pixels, top-left origin, exact scale of the screenshot — no math.

---

## 9. UI specifics

- **Orb panel**: 300×280 pt, borderless `NSPanel`, level `.popUpMenu` (101) — sits above the menu bar. `nonactivatingPanel`, `canBecomeKey=false`, `canBecomeMain=false`. `wantsLayer=true` with `masksToBounds=false` on both the hosting view and the panel's content view (so glow/blurs aren't clipped).
- **Orb visual** (`OrbView`): 42pt diameter sphere, three layered radial blooms inside a clipped circle, glass rim + specular highlight, audio-reactive bright core (scales with mic input level), shockwave ring on reveal, optional `TraceArc` while in `.thinking` state. Reveal: spring scale 0.25→1.0 (response 0.38, damping 0.66), opacity 0→1, blur 14→0, shockwave 0→1.4× radius over 0.8s. Dismiss: ease-in 0.22s.
- **Status pill** + **transcript bubble**: stacked text shadows for legibility, no background rectangle.
- **Cursor halo**: 120×120 pt panel at `.screenSaver` level, follows cursor at 60Hz, two radial blooms (pink/violet, sky-blue), breathes at 1.7Hz, intensifies during AI input synthesis (`OrbState.aiControlling`).
- **Reveal positioning**: orb is offset ~18pt diagonally from the cursor, flips sides at screen edges, clamped to `screen.frame` (NOT `visibleFrame`, so it can roam the menu bar area).
- **Click-away dismiss**: global `NSEvent.addGlobalMonitorForEvents` for `leftMouseDown/rightMouseDown`. Inspects `cgEvent.getIntegerValueField(.eventSourceUserData)`; ignores events tagged with `InputSynth.eventUserDataMarker` so the model's own clicks don't dismiss the orb. Global Esc also dismisses.
- **Single dismiss path**: all routes (click-away, Esc, orb tap) call `coordinator.deactivate()` which tears down panel + realtime + halo + restarts wake word. Prevents "multiple orbs" / zombie sessions.
- **Menu bar icon**: colored mini orb PNG (22@1x / 44@2x), non-template.

---

## 10. Permissions

Requested on first launch by `PermissionsOnboarding`:

1. **Microphone** (`AVCaptureDevice.requestAccess(for: .audio)`)
2. **Speech Recognition** (`SFSpeechRecognizer.requestAuthorization`) — only used if wake word enabled
3. **Screen Recording** (`CGRequestScreenCaptureAccess()`) — requires app relaunch to take effect
4. **Accessibility** (`AXIsProcessTrustedWithOptions` with prompt) — requires app relaunch

Live status with Grant + "Open Settings" deep-links in Settings → Permissions. TCC service names:
- `kTCCServiceMicrophone`
- `kTCCServiceSpeechRecognition`
- `kTCCServiceScreenCapture`
- (Accessibility is not a TCC.db entry; it's the AX process-trust system.)

Apple Events / Automation is per-target, prompts on first AppleScript call to each app.

**Ad-hoc signing implication**: each rebuild changes the cdhash, so TCC may re-prompt. For end users from a release DMG this isn't a problem; for developers rebuilding locally, expect to re-grant.

---

## 11. Wake word

`SFSpeechRecognizer` continuous, on-device (audio stays local until phrase matches). Loose tokenization: every token of the phrase must appear in order somewhere in the partial transcript (so "hey, cursor", "hey cursor", "hey there cursor" all match). Auto-restarts every 55s because `SFSpeechRecognitionTask` has a ~1min ceiling. While the orb is active, wake word is stopped (they share the input node); restarts on deactivate if still enabled. Toggle + phrase configurable in Settings.

---

## 12. Hotkey

Carbon `RegisterEventHotKey` on `GetApplicationEventTarget()`. Default: ⌃⌥/ (kVK 44, mods controlKey|optionKey = 6144). Recorder in Settings requires at least one modifier (rejects bare keys with `NSSound.beep()`), shows live-held modifiers as user holds them, captures on first non-modifier keyDown.

---

## 13. Auto-update (v0.2.0)

`UpdateChecker`:
1. On launch + every 6h, polls `https://api.github.com/repos/.../releases/latest`.
2. Parses tag, compares to `CFBundleShortVersionString` via dotted-version comparison.
3. If newer, locates the DMG asset, sets `availableUpdate`.
4. `SettingsView` shows banner with "Release notes" + "Install & relaunch".
5. On install: downloads DMG to `/tmp`, writes a detached bash updater script that:
   - waits for the running app's PID to exit (polls `kill -0`),
   - mounts the DMG via `hdiutil`,
   - replaces `Bundle.main.bundlePath` (likely `/Applications/CursorVoice.app`) with the new bundle via `cp -R`,
   - `xattr -dr com.apple.quarantine`,
   - `open` the new app,
   - self-cleans the DMG and the script.
6. App calls `NSApp.terminate(nil)`; script takes over.

No Sparkle, no XPC helpers, no embedded auto-updater framework.

---

## 14. Settings persistence

- `SettingsStore` (`@MainActor ObservableObject`) with `@Published` for each field.
- API key → `KeychainStore` (`kSecClassGenericPassword`, service `com.cursorvoice.app`, account `openai-api-key`).
- Everything else → `UserDefaults`.
- "Reset all settings" wipes both.
- Model / voice changes while orb is open trigger a graceful realtime reconnect via Combine sinks in `AppCoordinator`.

---

## 15. Known limits / non-goals

- **Apple Silicon only**, macOS 14+ only.
- **No iOS/iPad/visionOS** counterpart.
- **No notarization** → first-launch Gatekeeper warning unless installer strips quarantine.
- **No Sandbox** — shell, AppleScript, and CGEvent posting need it off. Re-enabling sandbox would require dropping those tools or moving them to an XPC helper.
- **Web search is HTML-scraped** — fragile if DDG changes their HTML.
- **AX click only works on apps with proper accessibility labels.** Web pages (Safari) have decent AX but partial. Electron apps are hit-or-miss. Games and Canvas-based UIs have no AX.
- **Memory has no semantic search** — just substring matching on `recall`.
- **Wake word locale is en-US hardcoded.**
- **No telemetry**, no crash reporting.

---

## 16. Recent decisions worth knowing

- **Coordinate system unification** (v0.1.x). Model clicks were 7/10 misses because of a Retina pixel-vs-point mismatch. Fix: `ScreenCapture` records `pointsPerImagePixel = screen.frame.width / capturedImageWidth` on every capture; `InputSynth` reads that ratio for all coordinate translations. On default Retina displays where SCDisplay reports scaled-pixel-equals-points, ratio = 1.0 and no math is needed.
- **Synthetic event identification**. Every CGEvent posted by InputSynth stamps `eventSourceUserData = 0x4356_4F52_4250_5453` ("CVORBPTS"). The orb's global click-away monitor inspects this on incoming events to skip dismissing during AI input.
- **Lazy CursorHalo**. Eagerly creating its `NSHostingView` inside `AppCoordinator.init` crashed SwiftUI's AttributeGraph with `WindowToolbarStyleEnvironment` — apparently you can't create an NSHostingView during the App scene-graph construction. Making `cursorHalo` `lazy var` fixed it.
- **Build in /tmp**. iCloud Drive on the source tree adds xattrs that break hardened-runtime codesign. Build script ditto's the bundle out to `/tmp/cursorvoice-build/` first.

---

## 17. File-by-file responsibility cheat sheet

| File | What it owns |
| ---- | ------------ |
| `App.swift` | `@main`, `MenuBarExtra`, `Settings` scene, `AppDelegate` lifecycle. |
| `AppCoordinator.swift` | Single source of truth for "is the orb active". Wires hotkey/wake-word/orb/realtime/halo together. System instructions built here. |
| `UpdateChecker.swift` | GitHub releases polling + in-place install. |
| `Orb/OrbPanel.swift` | NSPanel subclass; never becomes key/main. |
| `Orb/OrbWindowController.swift` | Position panel, install global click/Esc monitors that route to coordinator. |
| `Orb/OrbView.swift` | All the SwiftUI for the orb (aurora, reveal, audio reactivity, status pill, transcript bubble). |
| `Orb/CursorHalo.swift` | Independent panel that follows cursor; intensity flips with `aiControlling`. |
| `Realtime/RealtimeClient.swift` | WS handshake, session.update, audio chunk routing, tool-call dispatch, barge-in. |
| `Realtime/AudioEngine.swift` | AVAudioEngine input tap + format-converted PCM16 24kHz, output via player node. Cancel = volume-zero + stop + flush. |
| `Realtime/ToolHandler.swift` | Actor; `dispatch(name, argsJSON)` switch; tool-start/end callbacks for the status pill. |
| `Capabilities/ScreenCapture.swift` | SCScreenshotManager native-res capture; records `pointsPerImagePixel`. Excludes own bundle ID windows. |
| `Capabilities/InputSynth.swift` | CGEvent mouse/keyboard; tagged user-data marker; image-px↔point conversion via ScreenCapture's ratio. |
| `Capabilities/AXTree.swift` | Walk frontmost app's AX tree; flat list; scored `bestMatch`. |
| `Capabilities/WebSearch.swift` | DDG HTML scrape + URL fetch + HTML strip. |
| `Capabilities/MemoryStore.swift` | JSON file persistence at `~/Library/Application Support/CursorVoice/memory.json`. |
| `Settings/SettingsStore.swift` | All persistent settings; model/voice change publishers wired to coordinator. |
| `Settings/SettingsView.swift` | TabView; injects UpdateBanner at top. |

---

## 18. How to extend it

- **New tool**: add definition to `ToolHandler.toolDefinitions`, add case in `dispatch(name:argsJSON:)`, register friendly label in `friendlyLabel(for:)`.
- **New permission**: extend `PermissionsOnboarding.requestAll`, add a row in `PermissionsView` with status + Grant + deep-link.
- **New voice/model**: edit the picker arrays in `Settings/SettingsView.swift`.
- **New visual state**: extend `OrbState.connection` or add a `@Published` field; render in `OrbView.statusText`.

---

## 19. Things that would meaningfully improve the project

(For another AI to consider as a next iteration.)

- **Vision-driven element picking when AX is empty.** If `list_ui_elements` returns nothing (Electron/Canvas/games), fall back to a Set-of-Marks (SoM) style overlay: number every visible clickable region in the screenshot and let the model pick by index. Possible via OCR + edge detection, or via a vision-driven cropped second-pass screenshot.
- **OCR layer on screenshots** (Vision framework's `VNRecognizeTextRequest`) — returns word-level boxes the model can click without doing pixel hunting.
- **MCP-style tool router** so users can plug in their own tools without rebuilding.
- **Browser-DOM bridge** for Safari/Chrome — far more reliable than even AX for web UIs (via AppleScript JS execution or WebExtension).
- **Cross-display correctness**. Single-display assumption in several places (`NSScreen.main`).
- **A real updater diff/delta** — currently the whole DMG is downloaded. Sparkle's binary patches would save bandwidth.
- **Crash reporting** + opt-in telemetry on tool usage to know which tools the model actually picks.
- **Faster wake word** via Porcupine or a small on-device wake word model — current SFSpeechRecognizer-based approach is battery-hungry.
- **More expressive memory** — embeddings + semantic recall vs substring grep.
- **Notarization path.** Requires $99/yr Apple Developer ID; would unlock submission to the official `homebrew-cask` repo and remove the Gatekeeper friction.
