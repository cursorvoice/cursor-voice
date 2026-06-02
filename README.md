# Cursor Voice

**→ [cursorvoice.app](https://cursorvoice.app)**

A native macOS voice assistant that lives next to your cursor. Press a hotkey, talk to it, and it sees your screen, drives your Mac, and answers back — powered by the OpenAI Realtime API.

```
              cursor
                 ┃
                 ▼   ←  ⌃⌥/  summon
                 ◯   listening…
                 ◯   "search youtube for lo-fi beats"
                 ◯   opening a link…
```

## What it does

- **Voice-in / voice-out** via `gpt-realtime` (configurable per-session)
- **Sees your screen** — captures the display via ScreenCaptureKit so it can answer about what's in front of you
- **Drives the Mac** — synthesizes mouse and keyboard input via CGEvent; clicks UI elements by name via the Accessibility tree; runs AppleScript and shell commands
- **Web access** — `web_search` (no API key) + `fetch_url` for live information
- **Persistent memory** — remembers facts across sessions
- **Wake word** — opt-in, on-device, listens for "Hey Cursor" via SFSpeechRecognizer

## Install

### One-line installer (curl)

```bash
curl -fsSL https://raw.githubusercontent.com/cursorvoice/cursor-voice/main/install.sh | bash
```

Downloads the latest release, copies the app into `/Applications`, strips the quarantine attribute, and launches it. Done.

### Homebrew

```bash
brew tap cursorvoice/cursor-voice
brew install --cask cursor-voice
```

The cask's `postflight` strips quarantine automatically — no right-click-Open dance.

### Manual

1. Download the DMG from the [latest release](https://github.com/cursorvoice/cursor-voice/releases/latest).
2. Open it, drag **Cursor Voice** into Applications.
3. **First launch**: macOS Gatekeeper will refuse to open it (it's ad-hoc signed, no paid Developer ID). Fix with one of:
   - **Right-click the app → Open** → confirm in the dialog.
   - Or: `xattr -dr com.apple.quarantine /Applications/CursorVoice.app && open /Applications/CursorVoice.app`

You'll see a small aurora orb appear in the menu bar.

## Setup

1. Click the menu bar orb → **Settings…**
2. Paste your **OpenAI API key** (stored in your Keychain).
3. Pick a **hotkey** (default `⌃⌥/`) and optionally enable the wake word.
4. Macros will prompt for **Microphone**, **Speech Recognition**, **Screen Recording**, and **Accessibility** permissions the first time you press the hotkey. Grant all four — each one unlocks one capability.

> **Important**: macOS only honors Screen Recording and Accessibility on a fresh process launch, so quit and reopen the app after granting them.

## Use

- **Press the hotkey** anywhere — the orb materializes at your cursor.
- **Speak** — it streams audio to the realtime model and speaks back.
- **Interrupt** by talking over it; it stops mid-sentence cleanly.
- **Click outside the orb / press Esc** to dismiss.
- **Wake word** (opt-in): say *"Hey Cursor"* anywhere.

Example commands:

- "What's on my screen?"
- "Search YouTube for lo-fi beats"
- "Open the Downloads folder"
- "Play Bohemian Rhapsody in Apple Music"
- "Click the Save button"
- "Remember that my main project lives in `~/Code/foo`"

## Models

Pick a Realtime model in **Settings → Advanced**:

| Model                    | Notes                                   |
| ------------------------ | --------------------------------------- |
| `gpt-realtime`           | Default GA model                        |
| `gpt-realtime-2`         | Reasoning, slower, most capable         |
| `gpt-realtime-1.5`       | Best voice quality                      |
| `gpt-realtime-mini`      | Cheap & fast                            |
| `gpt-realtime-translate` | Real-time speech-to-speech translation  |

Changes apply to the open session immediately (it reconnects).

## Permissions

Cursor Voice asks for, in order:

1. **Microphone** — to capture your voice
2. **Speech Recognition** — only if wake word is enabled (on-device)
3. **Screen Recording** — for `see_screen` and the auto-attached screenshots after each action
4. **Accessibility** — for `click_element` (AX-tree clicking) and mouse/keyboard synthesis

You can see live status in **Settings → Permissions** with deep-link buttons to the relevant System Settings pane.

## Privacy

- API key lives only in your local Keychain.
- Audio is streamed to OpenAI's Realtime API while the orb is active. No audio leaves your Mac when the orb is dismissed.
- Wake word listening is **on-device** — audio is not transmitted unless the phrase matches.
- Memory is stored locally at `~/Library/Application Support/CursorVoice/memory.json`.

## Build from source

Requirements: macOS 14+, Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/cursorvoice/cursor-voice.git
cd cursor-voice
./scripts/build.sh
./scripts/dmg.sh
open ./build/CursorVoice.app
```

`build.sh` compiles with `swiftc`, assembles the bundle, generates the `.icns`, writes `Info.plist`, and ad-hoc-signs with the hardened runtime. `dmg.sh` packs the bundle into a drag-to-Applications DMG.

There's no Xcode project required — the codebase is plain Swift sources organised under `Sources/CursorVoice/`.

## Architecture

- `App.swift` / `AppCoordinator.swift` — entry point, lifecycle, orchestrates everything
- `MenuBarExtra` — SwiftUI menu bar item with `SettingsLink`
- `Orb/` — borderless `NSPanel` floating at the cursor; the aurora SwiftUI view with reveal/breath/audio-reactive animations; cursor halo overlay
- `Realtime/RealtimeClient.swift` — `URLSessionWebSocketTask` against `wss://api.openai.com/v1/realtime`; barge-in interruption with `response.cancel` + `conversation.item.truncate`
- `Realtime/AudioEngine.swift` — `AVAudioEngine` capture at 24kHz PCM16, playback via `AVAudioPlayerNode`
- `Realtime/ToolHandler.swift` — dispatch for the tool calls
- `Capabilities/` — `ScreenCapture` (ScreenCaptureKit), `InputSynth` (CGEvent mouse/keyboard), `AXTree` (Accessibility tree introspection), `WebSearch`, `AppleScriptRunner`, `ShellRunner`, `MemoryStore`
- `Hotkey/` — Carbon `RegisterEventHotKey`
- `WakeWord/` — `SFSpeechRecognizer` continuous recognition
- `Settings/` — SwiftUI Settings scene + Keychain

## Caveats

- **App Sandbox is off.** The shell + AppleScript tools and CGEvent posting need this. If you re-enable the sandbox, drop those capabilities.
- **Ad-hoc signature.** No paid Developer ID, so no notarization. Gatekeeper will block on first launch — see install instructions above.
- **Apple Silicon only.** Built for `arm64-apple-macos14.0`.

## Support

Cursor Voice is free and open source. Keeping the project online (domain, etc.) costs a little each year — if the app is useful to you, a small tip covers it and is genuinely appreciated. There's a **Sponsor** button at the top of this repo.

**Questions or bug reports:** open a [GitHub issue](https://github.com/cursorvoice/cursor-voice/issues) or email **support@cursorvoice.app**.

Thank you 💜

## License

MIT.
