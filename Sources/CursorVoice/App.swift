import SwiftUI
import AppKit
import Combine

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
    private var bag = Set<AnyCancellable>()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register for cursorvoice:// URLs (marketplace "Install in app" deep link).
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// Also handles URLs delivered via the modern AppKit path.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { PluginInstaller.handle($0) }
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let str = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: str) else { return }
        PluginInstaller.handle(url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
        // Trigger system permission prompts up front so they never appear
        // mid-conversation. Non-blocking — features degrade if declined.
        Task { @MainActor in await PermissionsOnboarding.requestAll() }
        // Check for updates on launch and periodically thereafter (every 6h).
        UpdateChecker.shared.startPeriodicCheck()
        // Also re-check whenever the app is brought to the front (throttled to
        // once an hour) so it stays current without waiting on the timer.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in await UpdateChecker.shared.checkThrottled() } }
        // Not signed in → full-screen welcome / sign-in gate.
        // Signed in → the brand intro (first launch only).
        if GoogleAuth.shared.identity == nil {
            SignInGate.presentIfNeeded()
        } else {
            LaunchOverlay.play()
            // Let the brand intro finish, then run the guided first-run tour.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { [settings] in
                FirstRunOnboarding.presentIfNeeded(settings: settings)
            }
        }

        // First sign-in on a fresh install → kick off the guided tour once the
        // sign-in gate has dismissed.
        GoogleAuth.shared.$identity
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [settings] id in
                guard id != nil, !FirstRunOnboarding.hasCompleted else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    FirstRunOnboarding.presentIfNeeded(settings: settings)
                }
            }
            .store(in: &bag)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}
