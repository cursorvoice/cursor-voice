import Foundation
import AppKit
import Combine

struct HotkeySpec: Codable, Equatable {
    var keyCode: UInt32       // Carbon virtual key code
    var carbonModifiers: UInt32 // Carbon modifier bitmask

    // Default: ⌃⌥/ (control+option+slash) — rarely used by anything else.
    static let defaultSpec = HotkeySpec(keyCode: 44,  // /
                                        carbonModifiers: 4096 | 2048) // controlKey | optionKey

    var displayString: String {
        var parts: [String] = []
        if carbonModifiers & 256 != 0 { parts.append("⌘") }   // cmdKey
        if carbonModifiers & 2048 != 0 { parts.append("⌥") }  // optionKey
        if carbonModifiers & 4096 != 0 { parts.append("⌃") }  // controlKey
        if carbonModifiers & 512 != 0 { parts.append("⇧") }   // shiftKey
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    static func keyName(for code: UInt32) -> String {
        switch code {
        case 49: return "Space"
        case 36: return "Return"
        case 53: return "Esc"
        case 51: return "⌫"
        case 48: return "⇥"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 44: return "/"
        case 27: return "-"
        case 24: return "="
        case 43: return ","
        case 47: return "."
        case 39: return "'"
        case 41: return ";"
        case 33: return "["
        case 30: return "]"
        case 42: return "\\"
        case 50: return "`"
        default: break
        }
        let map: [UInt32: String] = [
            0:"A",11:"B",8:"C",2:"D",14:"E",3:"F",5:"G",4:"H",34:"I",38:"J",
            40:"K",37:"L",46:"M",45:"N",31:"O",35:"P",12:"Q",15:"R",1:"S",17:"T",
            32:"U",9:"V",13:"W",7:"X",16:"Y",6:"Z",
            18:"1",19:"2",20:"3",21:"4",23:"5",22:"6",26:"7",28:"8",25:"9",29:"0"
        ]
        return map[code] ?? "Key\(code)"
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var apiKey: String?
    @Published var model: String
    @Published var voice: String
    @Published var hotkey: HotkeySpec
    @Published var wakeWordEnabled: Bool
    @Published var wakeWordPhrase: String
    /// Core Audio UID of the chosen mic, or nil for the system default input.
    @Published var inputDeviceUID: String?
    /// Opt-in: let the assistant run shell commands flagged as risky. Off by default.
    @Published var allowRiskyShellCommands: Bool
    /// Dry run: the assistant describes the actions it WOULD take instead of performing them.
    @Published var dryRun: Bool
    /// Spoken-response verbosity: "concise" · "normal" · "detailed".
    @Published var verbosity: String
    /// Tell the model the user's frontmost app at session start (app name only).
    @Published var ambientContext: Bool

    private let keychain = KeychainStore(service: "com.cursorvoice.app", account: "openai-api-key")
    private let defaults = UserDefaults.standard

    init() {
        self.apiKey = nil
        self.model = defaults.string(forKey: "model") ?? "gpt-realtime-2"
        self.voice = defaults.string(forKey: "voice") ?? "marin"
        self.wakeWordEnabled = defaults.bool(forKey: "wakeWordEnabled")
        self.wakeWordPhrase = defaults.string(forKey: "wakeWordPhrase") ?? "hey cursor"
        self.inputDeviceUID = defaults.string(forKey: "inputDeviceUID")
        self.allowRiskyShellCommands = defaults.bool(forKey: ShellRunner.allowRiskyKey)
        self.dryRun = defaults.bool(forKey: "dryRun")
        self.verbosity = defaults.string(forKey: "verbosity") ?? "normal"
        self.ambientContext = defaults.object(forKey: "ambientContext") as? Bool ?? true

        if let data = defaults.data(forKey: "hotkey"),
           let spec = try? JSONDecoder().decode(HotkeySpec.self, from: data) {
            self.hotkey = spec
        } else {
            self.hotkey = .defaultSpec
        }

        self.apiKey = try? keychain.read()
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = trimmed.isEmpty ? nil : trimmed
        try? keychain.write(trimmed)
    }

    func setHotkey(_ spec: HotkeySpec) {
        hotkey = spec
        if let data = try? JSONEncoder().encode(spec) {
            defaults.set(data, forKey: "hotkey")
        }
    }

    func setModel(_ value: String) { model = value; defaults.set(value, forKey: "model") }
    func setVoice(_ value: String) { voice = value; defaults.set(value, forKey: "voice") }
    func setInputDeviceUID(_ uid: String?) {
        inputDeviceUID = uid
        if let uid = uid { defaults.set(uid, forKey: "inputDeviceUID") }
        else { defaults.removeObject(forKey: "inputDeviceUID") }
    }
    func setWakeWordEnabled(_ v: Bool) { wakeWordEnabled = v; defaults.set(v, forKey: "wakeWordEnabled") }
    func setWakeWordPhrase(_ v: String) { wakeWordPhrase = v; defaults.set(v, forKey: "wakeWordPhrase") }
    func setAllowRiskyShellCommands(_ v: Bool) { allowRiskyShellCommands = v; defaults.set(v, forKey: ShellRunner.allowRiskyKey) }
    func setDryRun(_ v: Bool) { dryRun = v; defaults.set(v, forKey: "dryRun") }
    func setVerbosity(_ v: String) { verbosity = v; defaults.set(v, forKey: "verbosity") }
    func setAmbientContext(_ v: Bool) { ambientContext = v; defaults.set(v, forKey: "ambientContext") }

    /// Wipe persisted UserDefaults + Keychain and reset published state to defaults.
    /// The app keeps running; user can re-enter the API key afterwards.
    func resetAll() {
        for key in ["hotkey", "model", "voice", "wakeWordEnabled", "wakeWordPhrase", "inputDeviceUID", ShellRunner.allowRiskyKey, "dryRun", "verbosity", "ambientContext"] {
            defaults.removeObject(forKey: key)
        }
        try? keychain.write("")
        apiKey = nil
        model = "gpt-realtime-2"
        voice = "marin"
        hotkey = .defaultSpec
        wakeWordEnabled = false
        wakeWordPhrase = "hey cursor"
        inputDeviceUID = nil
        allowRiskyShellCommands = false
        dryRun = false
        verbosity = "normal"
        ambientContext = true
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
