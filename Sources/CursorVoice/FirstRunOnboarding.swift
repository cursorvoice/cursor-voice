import AppKit
import SwiftUI
import AVFoundation
import CoreGraphics
import ApplicationServices

/// Interactive first-run walkthrough, shown once after sign-in: a short guided
/// tour that (1) welcomes, (2) walks the user through the macOS permissions with
/// live status + deep links into System Settings, (3) explains the hotkey, and
/// (4) hands off with a "try this command" prompt. Permission prompts are a
/// known drop-off cliff — this makes the grants explicit and recoverable.
@MainActor
enum FirstRunOnboarding {
    private static var window: NSWindow?
    private static let completedKey = "didCompleteFirstRunV1"

    static var hasCompleted: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    /// Present only if it hasn't run before and the user is signed in.
    static func presentIfNeeded(settings: SettingsStore) {
        guard !hasCompleted else { return }
        guard GoogleAuth.shared.identity != nil else { return }
        present(settings: settings)
    }

    /// Force-present (used by the "Replay setup guide" button in Settings).
    static func present(settings: SettingsStore) {
        guard window == nil, let screen = NSScreen.main else { return }

        let w = KeyableWindow(contentRect: screen.frame,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        w.level = .modalPanel
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.setFrame(screen.frame, display: true)
        w.contentView = NSHostingView(rootView: FirstRunView(settings: settings) { finish() })
        window = w

        w.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    private static func finish() {
        UserDefaults.standard.set(true, forKey: completedKey)
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.5
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().alphaValue = 0
        }, completionHandler: {
            w.orderOut(nil)
            window = nil
        })
    }
}

private struct FirstRunView: View {
    @ObservedObject var settings: SettingsStore
    let onDone: () -> Void

    @State private var step = 0
    @State private var appear = false
    private let lastStep = 3

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            AuroraRibbons(reduceMotion: false, colors: [
                Color(red: 0.55, green: 0.30, blue: 0.95),
                Color(red: 0.97, green: 0.45, blue: 0.78),
                Color(red: 0.40, green: 0.78, blue: 1.00),
                Color(red: 0.42, green: 0.97, blue: 0.90)
            ])
            .opacity(0.45)
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button("Skip") { onDone() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(24)
                }
                Spacer()
            }

            VStack(spacing: 26) {
                content
                    .frame(maxWidth: 460)
                    .padding(36)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(.white.opacity(0.06))
                            .background(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(.white.opacity(0.12), lineWidth: 1)
                            )
                    )

                HStack(spacing: 8) {
                    ForEach(0...lastStep, id: \.self) { i in
                        Circle()
                            .fill(.white.opacity(i == step ? 0.9 : 0.25))
                            .frame(width: 7, height: 7)
                    }
                }
            }
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 14)
        }
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.8).delay(0.1)) { appear = true } }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcome
        case 1: permissions
        case 2: hotkeyStep
        default: tryIt
        }
    }

    // MARK: Step 0 — welcome
    private var welcome: some View {
        VStack(spacing: 18) {
            AuroraOrb(size: 96)
            Text("Welcome to Cursor Voice")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Talk to your Mac and it does the thing — opens apps, clicks, types, reads your screen, searches the web. Let's get you set up in about 30 seconds.")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
            primaryButton("Get started") { next() }
        }
    }

    // MARK: Step 1 — permissions
    private var permissions: some View {
        VStack(spacing: 16) {
            stepTitle("Grant a few permissions", "Cursor Voice runs entirely on your Mac. These let it hear you, see the screen, and act for you.")
            VStack(spacing: 10) {
                PermissionRow(title: "Microphone", subtitle: "Hear your voice commands",
                              status: PermissionProbe.mic, settingsURL: PermissionProbe.micURL)
                PermissionRow(title: "Screen Recording", subtitle: "See what's on your screen",
                              status: PermissionProbe.screen, settingsURL: PermissionProbe.screenURL)
                PermissionRow(title: "Accessibility", subtitle: "Click and type for you",
                              status: PermissionProbe.accessibility, settingsURL: PermissionProbe.accessibilityURL)
            }
            Text("Screen Recording and Accessibility may need you to quit and reopen Cursor Voice once granted.")
                .font(.caption).foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
            primaryButton("Continue") { next() }
        }
    }

    // MARK: Step 2 — hotkey
    private var hotkeyStep: some View {
        VStack(spacing: 18) {
            Image(systemName: "command")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            stepTitle("Summon it anywhere", "Press your hotkey from any app to pop the orb at your cursor and start talking.")
            Text(settings.hotkey.displayString)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.1)))
            Text(settings.interactionMode == "pushToTalk"
                 ? "You're in push-to-talk: hold the hotkey while you speak, release when done."
                 : "Tap once to open, tap again to close. You can switch to push-to-talk in Settings.")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
            Text("You can also enable a spoken wake word in Settings → General.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
            primaryButton("Continue") { next() }
        }
    }

    // MARK: Step 3 — try it
    private var tryIt: some View {
        VStack(spacing: 18) {
            AuroraOrb(size: 84)
            Text("You're all set")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            VStack(spacing: 8) {
                Text("Press \(Text(settings.hotkey.displayString).fontWeight(.semibold)) and try saying:")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                ForEach(["“What's on my screen?”", "“Open Calculator”", "“Search the web for the weather”"], id: \.self) { ex in
                    Text(ex)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            Text("More examples live in Settings → Commands.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
            primaryButton("Done") { onDone() }
        }
    }

    // MARK: helpers
    private func stepTitle(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(sub)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
    }

    private func primaryButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 30).padding(.vertical, 12)
                .background(Capsule().fill(.white))
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func next() { withAnimation(.easeInOut(duration: 0.25)) { step = min(step + 1, lastStep) } }
}

/// One permission row with a live status dot and an "Open Settings" deep link.
private struct PermissionRow: View {
    let title: String
    let subtitle: String
    let status: () -> Bool
    let settingsURL: String

    @State private var granted = false
    private let tick = Timer.publish(every: 1.2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(granted ? .green : .white.opacity(0.4))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(subtitle).font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            if granted {
                Text("Granted").font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.green.opacity(0.9))
            } else {
                Button("Open Settings") { openSettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.16)))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
        .onAppear { granted = status() }
        .onReceive(tick) { _ in granted = status() }
    }

    private func openSettings() {
        if let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
    }
}

/// Live permission probes + System Settings deep links.
private enum PermissionProbe {
    static let mic: () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static let screen: () -> Bool = { CGPreflightScreenCaptureAccess() }
    static let accessibility: () -> Bool = { AXIsProcessTrusted() }

    static let micURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    static let screenURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    static let accessibilityURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
}
