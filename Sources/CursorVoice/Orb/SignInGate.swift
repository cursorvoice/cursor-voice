import AppKit
import SwiftUI
import Combine

/// Full-screen welcome / sign-in gate. Shown on launch when the user isn't
/// signed in — aurora ribbons, the orb, the wordmark, and a Sign in with
/// Google button. Auto-dismisses (with a fade) once sign-in completes.
@MainActor
enum SignInGate {
    private static var window: NSWindow?
    private static var bag = Set<AnyCancellable>()

    static func presentIfNeeded() {
        guard window == nil else { return }
        guard GoogleAuth.shared.identity == nil else { return }   // already signed in
        guard let screen = NSScreen.main else { return }

        let w = KeyableWindow(contentRect: screen.frame,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        w.level = .modalPanel
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.setFrame(screen.frame, display: true)
        w.contentView = NSHostingView(rootView: SignInView())
        window = w

        show()

        // Dismiss for good once an identity appears.
        GoogleAuth.shared.$identity
            .receive(on: RunLoop.main)
            .sink { if $0 != nil { dismiss() } }
            .store(in: &bag)

        // While sign-in is in progress, get OUT of the way so the browser's
        // Google account picker is usable. Come back if it fails / is cancelled.
        GoogleAuth.shared.$inProgress
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { busy in
                if busy { hideForBrowser() }
                else if GoogleAuth.shared.identity == nil { show() }
            }
            .store(in: &bag)
    }

    private static func show() {
        guard let w = window else { return }
        w.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    /// Slide the gate out of the way so the browser is fully interactive.
    private static func hideForBrowser() {
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            w.animator().alphaValue = 0
        } completionHandler: {
            w.orderOut(nil)
        }
    }

    static func dismiss() {
        guard let w = window else { return }
        bag.removeAll()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.6
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().alphaValue = 0
        }, completionHandler: {
            w.orderOut(nil)
            window = nil
        })
    }
}

/// Borderless window that can still become key so its controls are clickable.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct SignInView: View {
    @ObservedObject private var google = GoogleAuth.shared
    @State private var appear = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            AuroraRibbons(reduceMotion: false, colors: [
                Color(red: 0.55, green: 0.30, blue: 0.95),
                Color(red: 0.97, green: 0.45, blue: 0.78),
                Color(red: 0.40, green: 0.78, blue: 1.00),
                Color(red: 0.42, green: 0.97, blue: 0.90)
            ])
            .opacity(0.6)
            .ignoresSafeArea()

            VStack(spacing: 22) {
                AuroraOrb(size: 120)
                    .scaleEffect(appear ? 1 : 0.7)
                    .opacity(appear ? 1 : 0)

                VStack(spacing: 8) {
                    Text("Cursor Voice")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .tracking(0.5)
                    Text("Talk to your Mac. It sees your screen and does the thing.")
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 12)

                Button(action: { google.signIn() }) {
                    HStack(spacing: 10) {
                        if google.inProgress {
                            ProgressView().controlSize(.small).tint(.black)
                        } else {
                            Image(systemName: "g.circle.fill").font(.system(size: 17))
                        }
                        Text(google.inProgress ? "Signing in…" : "Sign in with Google")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 26).padding(.vertical, 13)
                    .background(Capsule().fill(.white))
                    .shadow(color: .white.opacity(0.25), radius: 20)
                }
                .buttonStyle(.plain)
                .disabled(google.inProgress)
                .opacity(appear ? 1 : 0)
                .padding(.top, 8)

                if !google.isConfigured {
                    Text("Add your Google OAuth Client ID in Settings first.")
                        .font(.caption).foregroundStyle(.orange.opacity(0.9))
                } else if let err = google.lastError {
                    Text(err).font(.caption).foregroundStyle(.orange.opacity(0.9))
                        .multilineTextAlignment(.center).frame(maxWidth: 360).lineLimit(3)
                }
            }
            .padding(40)
        }
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.7).delay(0.15)) { appear = true } }
    }
}
