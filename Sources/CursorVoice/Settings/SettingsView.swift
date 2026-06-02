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
                Text("Capabilities: see screen, run AppleScript, run shell. The model will ask for confirmation before executing AppleScript or shell.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Capabilities") }

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
