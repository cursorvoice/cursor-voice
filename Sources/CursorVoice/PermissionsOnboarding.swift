import Foundation
import AVFoundation
import Speech
import CoreGraphics

/// Sequentially triggers macOS permission prompts at first launch.
/// Each request is fire-and-forget (we don't gate the app on the result —
/// features simply degrade if the user declines).
@MainActor
enum PermissionsOnboarding {
    static func requestAll() async {
        await requestMic()
        await requestSpeech()
        requestScreenRecording()
        requestAccessibility()
        requestFileAccess()
        NSLog("Onboarding: permission requests issued")
    }

    /// Touch the protected user folders so macOS shows its "would like to access
    /// files in your Downloads/Desktop/Documents folder" prompts. (There's no
    /// programmatic prompt for full disk access — that's granted manually in
    /// System Settings — but these per-folder prompts cover everyday files.)
    private static func requestFileAccess() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        for folder in ["Downloads", "Desktop", "Documents"] {
            let url = home.appendingPathComponent(folder)
            // Listing the directory triggers the TCC prompt on first access.
            _ = try? fm.contentsOfDirectory(atPath: url.path)
        }
    }

    private static func requestAccessibility() {
        if AXIsProcessTrusted() { return }
        _ = InputSynth.requestAccessibility()
    }

    private static func requestMic() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .notDetermined else {
            NSLog("Onboarding: mic already \(status.rawValue)")
            return
        }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    private static func requestSpeech() async {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else {
            NSLog("Onboarding: speech already \(status.rawValue)")
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in cont.resume() }
        }
    }

    private static func requestScreenRecording() {
        if CGPreflightScreenCaptureAccess() {
            NSLog("Onboarding: screen recording already granted")
            return
        }
        // Triggers the system prompt + adds the app to Privacy → Screen Recording.
        // Note: macOS often requires an app relaunch to actually USE the grant.
        _ = CGRequestScreenCaptureAccess()
    }
}
