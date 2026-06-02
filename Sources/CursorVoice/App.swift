import SwiftUI
import AppKit

@main
struct CursorVoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(coordinator: appDelegate.coordinator)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.settings)
                .environmentObject(appDelegate.coordinator)
        }
    }
}

/// Menu-bar dropdown. `SettingsLink` reliably opens/focuses the Settings
/// scene; a simultaneous tap gesture also activates the app and pulls the
/// window to the front (accessory apps otherwise open it behind others, and
/// it must re-front when already open).
private struct MenuContent: View {
    let coordinator: AppCoordinator

    var body: some View {
        Button("Summon Orb") { coordinator.toggle() }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
            .simultaneousGesture(TapGesture().onEnded { Self.frontSettings() })
        SettingsLink { Text("Check for Updates…") }
            .simultaneousGesture(TapGesture().onEnded {
                Task { await UpdateChecker.shared.check() }
                Self.frontSettings()
            })
        Divider()
        Button("Quit Cursor Voice") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    static func frontSettings() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            for w in NSApp.windows where w.styleMask.contains(.titled) && !w.isMiniaturized {
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let settings = SettingsStore()
    lazy var coordinator: AppCoordinator = AppCoordinator(settings: settings)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
        // Trigger system permission prompts up front so they never appear
        // mid-conversation. Non-blocking — features degrade if declined.
        Task { @MainActor in await PermissionsOnboarding.requestAll() }
        // Check for updates on launch and periodically thereafter.
        UpdateChecker.shared.startPeriodicCheck()
        // Not signed in → full-screen welcome / sign-in gate.
        // Signed in → the brand intro (first launch only).
        if GoogleAuth.shared.identity == nil {
            SignInGate.presentIfNeeded()
        } else {
            LaunchOverlay.play()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}
