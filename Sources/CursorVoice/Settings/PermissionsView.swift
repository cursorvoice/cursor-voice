import SwiftUI
import AVFoundation
import Speech
import CoreGraphics
import ApplicationServices

struct PermissionsView: View {
    @State private var micGranted = false
    @State private var speechGranted = false
    @State private var screenGranted = false
    @State private var accessibilityGranted = false
    @State private var fullDiskGranted = false

    private let refreshTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                row(name: "Microphone",
                    granted: micGranted,
                    hint: "Required for voice input.",
                    anchor: "Privacy_Microphone") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                        refresh()
                    }
                }
                row(name: "Speech Recognition",
                    granted: speechGranted,
                    hint: "Required for the \"Hey Cursor\" wake word.",
                    anchor: "Privacy_SpeechRecognition") {
                    SFSpeechRecognizer.requestAuthorization { _ in
                        DispatchQueue.main.async { refresh() }
                    }
                }
                row(name: "Screen Recording",
                    granted: screenGranted,
                    hint: "Lets the assistant see your screen. Needs an app relaunch after granting.",
                    anchor: "Privacy_ScreenCapture") {
                    _ = CGRequestScreenCaptureAccess()
                    refresh()
                }
                row(name: "Accessibility",
                    granted: accessibilityGranted,
                    hint: "Required for the assistant to move the mouse, click, and type.",
                    anchor: "Privacy_Accessibility") {
                    _ = InputSynth.requestAccessibility()
                    refresh()
                }
                row(name: "Full Disk Access",
                    granted: fullDiskGranted,
                    hint: "Lets the assistant read & work with ALL your files (Downloads, Desktop, Documents…). Without it, those folders are off-limits. Needs an app relaunch after granting.",
                    anchor: "Privacy_AllFiles") {
                    openSystemSettings(anchor: "Privacy_AllFiles")
                }
            } header: { Text("Permissions") }

            Section {
                Button("Refresh status") { refresh() }
            } footer: {
                Text("Some permissions only take effect after relaunching the app. If a switch is on in System Settings but the status here is still off, quit and reopen Cursor Voice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .onReceive(refreshTimer) { _ in refresh() }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(name: String,
                     granted: Bool,
                     hint: String,
                     anchor: String,
                     onGrant: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Button("Open Settings") { openSystemSettings(anchor: anchor) }
                    .buttonStyle(.bordered)
            } else {
                Button("Grant") { onGrant() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 2)
    }

    private func openSystemSettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refresh() {
        micGranted           = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted        = SFSpeechRecognizer.authorizationStatus() == .authorized
        screenGranted        = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
        fullDiskGranted      = Self.hasFullDiskAccess()
    }

    /// Heuristic FDA check: a protected, FDA-gated path is only readable when
    /// Full Disk Access is granted. (No public API exists for this.)
    private static func hasFullDiskAccess() -> Bool {
        let probes = [
            ("\(NSHomeDirectory())/Library/Safari/Bookmarks.plist"),
            ("/Library/Application Support/com.apple.TCC/TCC.db")
        ]
        for p in probes where FileManager.default.fileExists(atPath: p) {
            if FileManager.default.isReadableFile(atPath: p),
               (try? FileHandle(forReadingFrom: URL(fileURLWithPath: p)))?.closeFile() != nil {
                return true
            }
        }
        return false
    }
}
