import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var coordinator: AppCoordinator
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        VStack(spacing: 0) {
            UpdateBanner(checker: updates)

            TabView {
                GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
                PermissionsView().tabItem { Label("Permissions", systemImage: "lock.shield") }
                CommandsTab().tabItem { Label("Commands", systemImage: "text.bubble") }
                UsageTab().tabItem { Label("Usage", systemImage: "dollarsign.circle") }
                AdvancedTab().tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            }
        }
        .frame(width: 500, height: 460)
        .onAppear {
            // Accessory (menu-bar) apps open windows behind whatever's frontmost.
            // Force the app + its settings window to the front.
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                for w in NSApp.windows where w.title.contains("Settings") || w.styleMask.contains(.titled) {
                    w.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}

private struct GeneralTab: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var google = GoogleAuth.shared
    @State private var apiKeyField: String = ""
    @State private var recording = false
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var googleID: String = ""
    @State private var googleSecret: String = ""
    @State private var showGoogleSetup = false

    var body: some View {
        Form {
            Section {
                if let id = google.identity {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 26)).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(id.name).fontWeight(.medium)
                            Text(id.email).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sign out") { google.signOut() }.buttonStyle(.bordered)
                    }
                } else {
                    Button {
                        if google.isConfigured { google.signIn() } else { showGoogleSetup = true }
                    } label: {
                        HStack(spacing: 8) {
                            if google.inProgress { ProgressView().controlSize(.small) }
                            Image(systemName: "g.circle.fill")
                            Text(google.inProgress ? "Signing in…" : "Sign in with Google")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(google.inProgress)

                    Button("OAuth setup…") { showGoogleSetup = true }
                        .buttonStyle(.borderless).font(.caption)

                    if let err = google.lastError {
                        Text(err).font(.caption).foregroundStyle(.orange).lineLimit(3)
                    }
                }

                if showGoogleSetup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Paste your Google OAuth client (Desktop app) credentials:")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Client ID (…apps.googleusercontent.com)", text: $googleID)
                            .textFieldStyle(.roundedBorder)
                        TextField("Client secret", text: $googleSecret)
                            .textFieldStyle(.roundedBorder)
                        Button("Save credentials") {
                            google.setCredentials(clientID: googleID, clientSecret: googleSecret)
                            showGoogleSetup = false
                        }
                        .disabled(googleID.isEmpty)
                    }
                }
            } header: { Text("Account") } footer: {
                Text("Sign in with Google to identify yourself. Only your name and email are read — no access to Gmail, Calendar, or Drive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                SecureField("sk-...", text: $apiKeyField, onCommit: commitKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text(settings.apiKey == nil ? "Not set" : "Stored in Keychain")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Spacer()
                    Button("Save") { commitKey() }
                        .disabled(apiKeyField.isEmpty)
                }
            } header: { Text("OpenAI API key") }

            Section {
                Picker("Microphone", selection: Binding(
                    get: { settings.inputDeviceUID ?? "" },
                    set: { settings.setInputDeviceUID($0.isEmpty ? nil : $0) })) {
                    Text("System Default").tag("")
                    ForEach(inputDevices) { d in
                        Text(d.name).tag(d.uid)
                    }
                }
                Text("Which microphone the assistant listens through. Applies on the next time you summon the orb.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Microphone input") }

            Section {
                HStack {
                    Text(settings.hotkey.displayString)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.secondary.opacity(0.12)))
                    Spacer()
                    HotkeyRecorderButton(recording: $recording) { spec in
                        settings.setHotkey(spec)
                        recording = false
                    }
                }
                Text("Press the hotkey anywhere to summon the orb at your cursor.")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Behavior", selection: Binding(
                    get: { settings.interactionMode },
                    set: { settings.setInteractionMode($0) })) {
                    Text("Toggle — press to open / close").tag("toggle")
                    Text("Push-to-talk — hold to talk").tag("pushToTalk")
                }
                Text("Push-to-talk: hold the hotkey while you speak, release to dismiss.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Hotkey") }

            Section {
                Toggle("Listen for wake word", isOn: Binding(
                    get: { settings.wakeWordEnabled },
                    set: { settings.setWakeWordEnabled($0) }))
                TextField("Wake phrase", text: Binding(
                    get: { settings.wakeWordPhrase },
                    set: { settings.setWakeWordPhrase($0) }))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.wakeWordEnabled)
                Text("Uses on-device speech recognition. Audio stays local until the phrase fires.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Wake word") }
        }
        .formStyle(.grouped)
        .onAppear {
            apiKeyField = settings.apiKey ?? ""
            inputDevices = AudioDevices.inputDevices()
            googleID = google.savedClientID
            googleSecret = google.savedClientSecret
        }
    }

    private func commitKey() { settings.setAPIKey(apiKeyField) }
}

private struct AdvancedTab: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var showResetConfirm = false

    private let models: [(id: String, label: String)] = [
        ("gpt-realtime",           "gpt-realtime  ·  default GA model"),
        ("gpt-realtime-2",         "gpt-realtime-2  ·  reasoning, slowest, most capable"),
        ("gpt-realtime-1.5",       "gpt-realtime-1.5  ·  best voice quality"),
        ("gpt-realtime-mini",      "gpt-realtime-mini  ·  cheap & fast"),
        ("gpt-realtime-translate", "gpt-realtime-translate  ·  speech→speech translation")
    ]
    private let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: Binding(
                    get: { settings.model },
                    set: { settings.setModel($0) })) {
                    ForEach(models, id: \.id) { m in
                        Text(m.label).tag(m.id)
                    }
                }
                Picker("Voice", selection: Binding(
                    get: { settings.voice },
                    set: { settings.setVoice($0) })) {
                    ForEach(voices, id: \.self) { Text($0.capitalized).tag($0) }
                }
            } header: { Text("Realtime") }

            Section {
                Toggle("Dry run — describe actions, don't perform them", isOn: Binding(
                    get: { settings.dryRun },
                    set: { settings.setDryRun($0) }))
                Text(settings.dryRun
                     ? "Dry run is ON — the assistant says what it WOULD do (click, type, run, move windows) but doesn't actually do it. Reading the screen still works. A safe way to try it out."
                     : "When on, the assistant narrates the actions it would take instead of performing them — a safe way to see what it'll do before letting it act.")
                    .font(.caption).foregroundStyle(settings.dryRun ? .orange : .secondary)

                Picker("Spoken detail", selection: Binding(
                    get: { settings.verbosity },
                    set: { settings.setVerbosity($0) })) {
                    Text("Concise").tag("concise")
                    Text("Normal").tag("normal")
                    Text("Detailed").tag("detailed")
                }
                Text("How much the assistant says back. Applies the next time you summon the orb.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Ambient context — share your active app", isOn: Binding(
                    get: { settings.ambientContext },
                    set: { settings.setAmbientContext($0) }))
                Text("Tells the assistant which app is in front so you don't have to say it. App name only — your clipboard is never sent automatically (it's read only when you ask).")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Behavior") }

            Section {
                Toggle("Vision-assist — describe the screen aloud", isOn: Binding(
                    get: { settings.visionAssist },
                    set: { settings.setVisionAssist($0) }))
                Text("For low-vision use: the assistant proactively reads and describes what's on screen and narrates what it's doing.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Hands-free — voice-only navigation", isOn: Binding(
                    get: { settings.handsFree },
                    set: { settings.setHandsFree($0) }))
                Text("For mouse/keyboard-free use: it announces each action, prefers Accessibility/keyboard over coordinate clicks, and lists choices so you can pick by voice.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Accessibility") }

            Section {
                Toggle("Allow risky shell commands", isOn: Binding(
                    get: { settings.allowRiskyShellCommands },
                    set: { settings.setAllowRiskyShellCommands($0) }))
                Text(settings.allowRiskyShellCommands
                     ? "⚠️ Risky commands are ALLOWED. The assistant can run destructive shell commands (recursive deletes, disk formatting, running as root, piping a download into a shell). The model can be steered by on-screen or web content — leave this off unless you understand the risk."
                     : "Commands that look destructive (recursive deletes, disk formatting, running as root, piping a download into a shell) are blocked by default. Turn this on to let the assistant run them anyway — at your own risk.")
                    .font(.caption)
                    .foregroundStyle(settings.allowRiskyShellCommands ? .orange : .secondary)
            } header: { Text("Shell commands") }

            Section {
                Button("Reset all settings…", role: .destructive) {
                    showResetConfirm = true
                }
                Text("Wipes API key, hotkey, voice, model, and wake word preferences.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Danger zone") }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset everything?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) { settings.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears the API key from your Keychain and resets the hotkey, voice, model, and wake-word settings.")
        }
    }
}

/// Live spend estimate from the Realtime API's usage reports.
private struct UsageTab: View {
    @ObservedObject private var meter = CostMeter.shared
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Estimated cost") {
                    Text(CostMeter.short(meter.sessionCost)).fontWeight(.semibold).monospacedDigit()
                }
                LabeledContent("Requests") { Text("\(meter.sessionRequests)").monospacedDigit() }
                LabeledContent("Input tokens") {
                    Text(CostMeter.grouped(meter.sessionInputTokens)).monospacedDigit()
                }
                LabeledContent("Output tokens") {
                    Text(CostMeter.grouped(meter.sessionOutputTokens)).monospacedDigit()
                }
            } header: { Text("This session") } footer: {
                Text("Resets each time you summon the orb. A running estimate also appears under the orb while you talk.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Estimated cost") {
                    Text(CostMeter.short(meter.lifetimeCost)).fontWeight(.semibold).monospacedDigit()
                }
                LabeledContent("Input tokens") {
                    Text(CostMeter.grouped(meter.lifetimeInputTokens)).monospacedDigit()
                }
                LabeledContent("Output tokens") {
                    Text(CostMeter.grouped(meter.lifetimeOutputTokens)).monospacedDigit()
                }
                Button("Reset totals…", role: .destructive) { showResetConfirm = true }
            } header: { Text("All time") }

            Section {
                Text("Estimate only. Costs are computed locally from the token counts OpenAI reports, using published per-model prices — they may differ from your actual bill. Your OpenAI dashboard is authoritative. Cursor Voice never sees your spend; nothing leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset usage totals?", isPresented: $showResetConfirm) {
            Button("Reset", role: .destructive) { meter.resetLifetime() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears the all-time cost and token counters. This doesn't affect your OpenAI account.")
        }
    }
}

/// A discoverable list of example commands — so people know what they can say.
private struct CommandsTab: View {
    @EnvironmentObject var settings: SettingsStore
    private let groups: [(title: String, examples: [String])] = [
        ("Apps & windows", [
            "Open Calculator",
            "Bring Safari to the front",
            "What windows are open?",
            "Move this window to the top-left, 900 by 700"
        ]),
        ("Click, type & scroll", [
            "Click the Save button",
            "Type my email address",
            "Scroll down",
            "Press Command-S"
        ]),
        ("Files & documents", [
            "Find files named invoice in my Downloads",
            "Rename this file to notes.txt",
            "Read this PDF and summarize it"
        ]),
        ("Clipboard", [
            "What's on my clipboard?",
            "Summarize what I copied",
            "Put my address on the clipboard"
        ]),
        ("Web & search", [
            "Search YouTube for lo-fi beats",
            "What's the weather in Tokyo?",
            "Open github.com"
        ]),
        ("Memory", [
            "Remember my project is at ~/Code/foo",
            "What's my deploy command?",
            "Forget what I told you about the API key"
        ]),
        ("System & screen", [
            "What's on my screen?",
            "What's my battery level?",
            "What time is it in London?"
        ])
    ]

    var body: some View {
        Form {
            Section {
                Text("Press your hotkey and just say it. A few things to try:")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(groups.indices, id: \.self) { i in
                Section {
                    ForEach(groups[i].examples, id: \.self) { ex in
                        Text("“\(ex)”").font(.callout)
                    }
                } header: { Text(groups[i].title) }
            }
            Section {
                Button("Replay setup guide…") {
                    FirstRunOnboarding.present(settings: settings)
                }
            } footer: {
                Text("Re-run the guided first-launch walkthrough (permissions, hotkey, example commands).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
