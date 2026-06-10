import AppKit
import AVFoundation
import Combine

/// Owns the long-lived pieces (hotkey, orb window, realtime client, wake word)
/// and routes user intent (hotkey press, wake word, dismissal) between them.
@MainActor
final class AppCoordinator: ObservableObject {
    let settings: SettingsStore
    let orbState = OrbState()
    // Lazy — creating its NSHostingView during SwiftUI scene-graph construction
    // crashes AttributeGraph with WindowToolbarStyleEnvironment.
    lazy var cursorHalo: CursorHalo = CursorHalo()

    private let hotkey = GlobalHotkey()
    private let wakeWord = WakeWordDetector()
    private var orbController: OrbWindowController?
    private var realtime: RealtimeClient?
    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func start() {
        orbController = OrbWindowController(state: orbState, requestDismiss: { [weak self] in
            self?.deactivate()
        })

        // Press behavior depends on the interaction mode (read live each time):
        //  • toggle      → press opens/closes the orb; release ignored
        //  • pushToTalk  → press opens & listens; release dismisses (hold to talk)
        hotkey.onPress = { [weak self] in
            guard let self else { return }
            if self.settings.interactionMode == "pushToTalk" { self.activate() } else { self.toggle() }
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return }
            if self.settings.interactionMode == "pushToTalk" { self.deactivate() }
        }
        applyHotkey()

        settings.$hotkey
            .dropFirst()
            .sink { [weak self] _ in self?.applyHotkey() }
            .store(in: &cancellables)

        settings.$wakeWordEnabled
            .sink { [weak self] enabled in self?.applyWakeWord(enabled: enabled) }
            .store(in: &cancellables)

        // Reconnect the realtime session whenever model or voice changes,
        // so picker selections take effect immediately on the open orb.
        settings.$model
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.reconnectIfActive() }
            .store(in: &cancellables)

        settings.$voice
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.reconnectIfActive() }
            .store(in: &cancellables)

        settings.$inputDeviceUID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.reconnectIfActive() }
            .store(in: &cancellables)

        wakeWord.onDetect = { [weak self] in
            Task { @MainActor in self?.activate() }
        }

        // When the Mac sleeps, the audio device/route gets torn out from under a
        // live session, which made it spin (the model repeating "ok…"). Close the
        // session cleanly on sleep; the user re-summons on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.orbState.isVisible {
                    NSLog("Coordinator: system sleeping — closing active session")
                    self.deactivate()
                }
            }
        }

        // NOTE: MCP connections are deferred for now (code retained in
        // MCPClient/MCPManager for a later release). Not connected at startup.
    }

    func stop() {
        deactivate()
        hotkey.unregister()
        wakeWord.stop()
    }

    // MARK: - Activation

    func toggle() {
        if orbState.isVisible { deactivate() } else { activate() }
    }

    func activate() {
        NSLog("Coordinator: activate()")
        guard !orbState.isVisible else { return }
        // Gate all usage behind sign-in — surface the welcome instead of the orb.
        guard GoogleAuth.shared.identity != nil else {
            NSLog("Coordinator: not signed in; showing sign-in gate")
            SignInGate.presentIfNeeded()
            return
        }
        guard let key = settings.apiKey, !key.isEmpty else {
            NSLog("Coordinator: no API key set; beeping and opening settings")
            NSSound.beep()
            settings.openSettings()
            return
        }
        // Wake-word and the realtime audio engine both want the input node,
        // so park the detector while the orb is up.
        wakeWord.stop()

        // Mic was requested at startup via PermissionsOnboarding.
        // If the user denied, the audio engine will report the failure;
        // we don't gate activation on a redundant request here.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            orbState.connection = .error("microphone denied — enable in System Settings → Privacy")
        }
        orbController?.present()
        cursorHalo.start()                 // halo follows cursor the whole session
        cursorHalo.active = false          // dimmed at rest, intense during input synth
        CostMeter.shared.startSession()    // fresh cost meter per session (not per reconnect)
        orbState.sessionCost = 0
        startRealtime(apiKey: key)
    }

    func deactivate() {
        guard orbState.isVisible || realtime != nil else { return }  // already torn down
        orbController?.dismiss()
        cursorHalo.stop()
        realtime?.disconnect()
        realtime = nil
        if settings.wakeWordEnabled {
            wakeWord.start(phrase: settings.wakeWordPhrase)
        }
    }

    /// Tear down and rebuild the realtime client with current settings,
    /// only if a session is currently active. Called when the user changes
    /// model or voice in the picker so the new selection takes effect now.
    private func reconnectIfActive() {
        guard orbState.isVisible, let key = settings.apiKey else { return }
        NSLog("Coordinator: reconnecting realtime (model=\(settings.model) voice=\(settings.voice))")
        realtime?.disconnect()
        realtime = nil
        orbState.connection = .connecting
        startRealtime(apiKey: key)
    }

    // MARK: - Realtime wiring

    private func startRealtime(apiKey: String) {
        let client = RealtimeClient(apiKey: apiKey,
                                    model: settings.model,
                                    voice: settings.voice,
                                    instructions: Self.buildInstructions(),
                                    inputDeviceUID: settings.inputDeviceUID)
        client.onStateChange = { [weak self] state in
            Task { @MainActor in self?.orbState.connection = state }
        }
        client.onAudioLevel = { [weak self] level in
            Task { @MainActor in self?.orbState.audioLevel = level }
        }
        client.onOutputLevel = { [weak self] level in
            Task { @MainActor in self?.orbState.outputLevel = level }
        }
        client.onTranscript = { [weak self] text in
            Task { @MainActor in self?.orbState.lastTranscript = text }
        }
        client.onInputActivity = { [weak self] active in
            Task { @MainActor in
                self?.orbState.aiControlling = active
                // Halo stays visible the whole session; intensity flips with activity.
                self?.cursorHalo.active = active
            }
        }
        client.onToolStart = { [weak self] label in
            Task { @MainActor in self?.orbState.activeTool = label }
        }
        client.onToolEnd = { [weak self] in
            Task { @MainActor in self?.orbState.activeTool = nil }
        }
        client.onUsage = { [weak self] usage, model in
            Task { @MainActor in
                CostMeter.shared.record(usage: usage, model: model)
                self?.orbState.sessionCost = CostMeter.shared.sessionCost
            }
        }
        client.connect()
        realtime = client
    }

    // MARK: - Hotkey / wake word config

    private func applyHotkey() {
        hotkey.register(keyCode: settings.hotkey.keyCode,
                        modifiers: settings.hotkey.carbonModifiers)
    }

    private func applyWakeWord(enabled: Bool) {
        if enabled { wakeWord.start(phrase: settings.wakeWordPhrase) }
        else { wakeWord.stop() }
    }

    /// Build the system instructions for this session, appending any
    /// long-term memories so the model starts with that context.
    private static func buildInstructions() -> String {
        var s = baseSystemInstructions
        // Verbosity preference (Settings → Behavior).
        switch UserDefaults.standard.string(forKey: "verbosity") {
        case "concise":
            s += "\n\nVERBOSITY: Be extra terse — a word or two at most, and only when you truly must speak. Strongly prefer silence."
        case "detailed":
            s += "\n\nVERBOSITY: The user wants more detail — after acting, briefly explain what you did (a sentence or two) and describe what you see when it's relevant."
        default:
            break // "normal" — use the base instructions as-is
        }
        // Ambient context (Settings → Behavior): tell the model the frontmost
        // app so the user doesn't have to say it. App NAME only — never the
        // clipboard (the model reads that on demand via read_clipboard).
        if (UserDefaults.standard.object(forKey: "ambientContext") as? Bool ?? true),
           let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName {
            s += "\n\nRIGHT NOW: the user's frontmost app is \(frontApp). (Ambient context — use silently, don't recite.)"
        }
        // Accessibility modes (Settings → Accessibility).
        let d = UserDefaults.standard
        if d.bool(forKey: "visionAssist") {
            s += "\n\nVISION-ASSIST MODE: The user may have low vision. Proactively describe what's on screen in clear spoken language; read out important text, labels, and changes; and narrate what you see and do. Be descriptive rather than terse — this overrides the default 'be terse' guidance."
        }
        if d.bool(forKey: "handsFree") {
            s += "\n\nHANDS-FREE MODE: The user navigates entirely by voice (no mouse/keyboard). Announce each action as you take it, strongly prefer Accessibility/keyboard actions over coordinate clicks, and when the user must choose, list the options clearly so they can pick by voice."
        }
        let memories = MemoryStore.shared.all()
        if !memories.isEmpty {
            s += "\n\nWHAT YOU REMEMBER ABOUT THIS USER (from past sessions):\n"
            for m in memories.suffix(50) {
                s += "• \(m.content)\n"
            }
            s += "\nDon't recite this list. Apply it silently when relevant."
        }
        return s
    }

    private static let baseSystemInstructions = """
    You are Cursor Voice — a desktop voice assistant living next to the user's cursor.

    SPEAKING (be terse):
    • Execute silently. Never say "let me", "I'll", "first I'll", "now I'm going to".
    • Only speak when (a) the task is finished — one short sentence, (b) you need clarification,
      or (c) something failed.
    • For COMPLEX or LONG tasks (more than ~3 tool calls), say a short status hint BEFORE you start
      ("checking that for you", "searching now") — then go silent until done.
    • For simple/atomic tasks, no preamble at all. Just do it.

    CANCEL / NEVERMIND:
    • If the user says "nevermind", "stop", "cancel", "wait", "actually", "forget it", or otherwise
      retracts the request — halt immediately. Do NOT run any pending tool. Just say "ok" or
      stay silent. The user's word overrides any plan you had.

    GROUND TRUTH = THE SCREEN:
    • Before any action that depends on what's currently on screen — clicking, typing into a field,
      reading state, replying about a UI — call see_screen FIRST. Don't guess from memory.
    • Your own windows (orb + halo) are excluded from screenshots, so you see the real UI.
    • Re-call see_screen between steps if the UI may have changed.

    LATEST INFORMATION:
    • Your training data is stale. For ANY question about current events, prices, scores, releases,
      versions, or anything time-sensitive, use web_search(query) to get live results, then optionally
      fetch_url(url) to read a specific page. Don't pretend to know — look it up.

    TOOL CHOICE — pick the most direct path (in this priority order):
    1. Live info / news / current facts → web_search, then fetch_url for full page.
    2. Web navigation → open_url (NEVER click through Safari to navigate).
    3. macOS app control (Music, Mail, Calendar, Finder, Messages, Notes, etc.) → run_applescript.
    4. Acting on a WEB PAGE (anything in Safari/Chrome/Brave/Edge/Arc) → browser_click_text
       to click by visible text, browser_snapshot to see what's on the page, browser_run_js
       for anything else. This runs in the real DOM and is the most reliable web path —
       prefer it over screenshots/clicking for web content.
    5. Clicking a labeled native UI element (button, link, menu item, text field) →
       list_ui_elements then click_element. INTERNALLY tries AXPress (fires the action with
       no mouse simulation) and falls back to coord-click. The most reliable native path.
    6. Clicking VISIBLE TEXT not in the AX tree → find_text / click_text (Vision OCR + click).
    7. App actions — calendar_add_event, calendar_today, reminders_add, notes_create,
       mail_compose — use these for those apps instead of clicking.
    8. Address bar in any browser → hotkey ["cmd","l"].
    9. Multi-step automation → batch_actions. Big latency win vs. one call per step.
    10. Shell / system → run_shell.
    11. If a native target has NO label and NO readable text (icons, toolbars, canvas) →
        mark_screen to get numbered candidates, then click_mark with the number.
    12. mouse_click / mouse_drag are the ABSOLUTE LAST RESORT — only when everything above
        fails. see_screen first; coordinates are image pixels, top-left origin, exact scale;
        aim CENTER of the target.

    DIAGNOSIS:
    • If a tool fails or you suspect it might (no permission, blocked, etc.), call
      permissions_diagnostics to check exactly what's enabled and tell the user
      specifically which switch to flip in System Settings → Privacy & Security.

    VERIFICATION (this is how you stop missing things):
    • After EVERY action, a fresh screenshot is auto-attached. COMPARE it to the previous one.
    • Did the expected change happen? If yes → continue. If no → look again, identify why,
      adjust. Don't blindly keep clicking the same coords.
    • For text fields: after typing, verify your text appears in the field on the screenshot.
    • If an action didn't take effect after TWO tries, STOP repeating it — switch method
      (AX → text → marks → coords) or tell the user what's blocking you.
    • If something needs time to appear (a dialog, a page load, a result), use
      wait_for_text("…") or wait(seconds) and then act once it's there — don't guess timing.

    CODING TASKS:
    • If the user asks you to write, refactor, explain, or run code and the `codex` plugin
      is installed (tool name plugin_codex), prefer it — it uses their Codex subscription,
      not the API key. If it isn't installed, suggest installing it from the marketplace.

    HELP / "WHAT CAN YOU DO":
    • If the user asks what you can do (or seems unsure / hesitant), give a SHORT spoken
      overview in plain language with 2–3 concrete examples tied to their current app —
      e.g. "I can run your Mac by voice: open apps, click and type for you, read what's on
      screen, search the web, manage files, and remember things. Want me to try one?"
      Keep it brief and inviting — not a feature dump.

    MACROS (teach a skill):
    • "record a macro called X" → macro_record_start(X). Then PERFORM the steps the user
      asks for normally — they're captured automatically. "stop recording" → macro_record_stop.
    • "run my X macro" / "do my X routine" → macro_run(X). "what macros do I have" → macro_list.
    • While recording, work step-by-step and confirm each step briefly so the user can steer.

    MEMORY:
    • You have persistent long-term memory across sessions via `remember` and `recall`.
    • Use remember for stable, useful facts: preferred apps, names, project paths, common
      shortcuts the user uses, recurring tasks. Not for ephemeral state.
    • If the user mentions something they've told you before, recall(query) first.

    SAFETY: never rm -rf, never sudo.
    """
}
