import AppKit
import SwiftUI

/// A clean, full-screen brand intro played ONCE (first launch only): flowing
/// aurora ribbons sweep the screen, the orb blooms in, the wordmark fades up,
/// a soft chime plays, then it all fades out. Non-interactive; auto-dismisses.
@MainActor
enum LaunchOverlay {
    private static var window: NSWindow?
    private static let playedKey = "didPlayIntro"

    /// Force the intro to play regardless of the first-launch flag (for testing).
    static func play(force: Bool = false) {
        if !force && UserDefaults.standard.bool(forKey: playedKey) { return }
        guard window == nil, let screen = NSScreen.main else { return }
        UserDefaults.standard.set(true, forKey: playedKey)

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let w = NSWindow(contentRect: screen.frame,
                         styleMask: [.borderless],
                         backing: .buffered,
                         defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.setFrame(screen.frame, display: true)

        let host = NSHostingView(rootView: LaunchView(reduceMotion: reduce))
        host.frame = CGRect(origin: .zero, size: screen.frame.size)
        host.autoresizingMask = [.width, .height]
        w.contentView = host
        w.alphaValue = 1
        w.orderFrontRegardless()
        window = w

        if !reduce { LaunchSound.play(duration: 3.0) }

        // Hold longer, then fade out.
        let hold: TimeInterval = reduce ? 1.0 : 3.4
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.7
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                w.animator().alphaValue = 0
            }, completionHandler: {
                w.orderOut(nil)
                window = nil
            })
        }
    }
}

private struct LaunchView: View {
    let reduceMotion: Bool

    @State private var orbScale: CGFloat = 0.25
    @State private var orbOpacity: CGFloat = 0
    @State private var orbBlur: CGFloat = 30
    @State private var shock: CGFloat = 0
    @State private var shockOpacity: CGFloat = 0
    @State private var wordOpacity: CGFloat = 0
    @State private var wordOffset: CGFloat = 16
    @State private var backdrop: CGFloat = 0
    @State private var ribbonsOpacity: CGFloat = 0

    private let orbSize: CGFloat = 140
    private let v = Color(red: 0.55, green: 0.30, blue: 0.95)
    private let p = Color(red: 0.97, green: 0.45, blue: 0.78)
    private let s = Color(red: 0.40, green: 0.78, blue: 1.00)
    private let m = Color(red: 0.42, green: 0.97, blue: 0.90)

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black).opacity(0.85 * backdrop).ignoresSafeArea()

            AuroraRibbons(reduceMotion: reduceMotion, colors: [v, p, s, m])
                .opacity(ribbonsOpacity)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                orb
                    .frame(width: orbSize, height: orbSize)
                    .scaleEffect(orbScale)
                    .opacity(orbOpacity)
                    .blur(radius: orbBlur)

                Text("Cursor Voice")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                    .tracking(0.5)
                    .opacity(wordOpacity)
                    .offset(y: wordOffset)
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
            }
        }
        .onAppear(perform: animateIn)
    }

    private var orb: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(shockOpacity), lineWidth: 1.5)
                    .frame(width: orbSize * (1 + 1.6 * shock), height: orbSize * (1 + 1.6 * shock))
                Circle()
                    .fill(aurora(t))
                    .frame(width: orbSize * 1.8, height: orbSize * 1.8)
                    .blur(radius: 48).opacity(0.65)
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.95), .white.opacity(0.5), .white.opacity(0.08)],
                                         center: .center, startRadius: 0, endRadius: orbSize / 2))
                    .frame(width: orbSize * 0.8, height: orbSize * 0.8)
                Circle()
                    .fill(aurora(t * 1.1)).frame(width: orbSize * 0.8, height: orbSize * 0.8)
                    .blur(radius: 13).opacity(0.7).blendMode(.screen)
                Ellipse()
                    .fill(.white.opacity(0.7)).frame(width: orbSize * 0.3, height: orbSize * 0.16)
                    .offset(x: -orbSize * 0.16, y: -orbSize * 0.22).blur(radius: 6)
                Circle()
                    .strokeBorder(.white.opacity(0.5), lineWidth: 0.8)
                    .frame(width: orbSize * 0.8, height: orbSize * 0.8)
            }
            .shadow(color: v.opacity(0.6), radius: 44)
        }
    }

    private func animateIn() {
        if reduceMotion {
            backdrop = 1; ribbonsOpacity = 0.7; orbScale = 1; orbOpacity = 1
            orbBlur = 0; wordOpacity = 1; wordOffset = 0
            return
        }
        withAnimation(.easeOut(duration: 0.6)) { backdrop = 1; ribbonsOpacity = 0.7 }
        withAnimation(.spring(response: 0.8, dampingFraction: 0.62)) {
            orbScale = 1; orbOpacity = 1; orbBlur = 0
        }
        shockOpacity = 0.6
        withAnimation(.easeOut(duration: 1.1)) { shock = 1; shockOpacity = 0 }
        withAnimation(.easeOut(duration: 0.6).delay(0.6)) { wordOpacity = 1; wordOffset = 0 }
    }

    private func aurora(_ t: TimeInterval) -> AngularGradient {
        AngularGradient(colors: [v, p, s, m, v], center: .center,
                        angle: .degrees(reduceMotion ? 220 : t.truncatingRemainder(dividingBy: 8) * 45))
    }
}

/// Flowing northern-lights bands rendered with a Canvas of sine-displaced
/// thick strokes, heavily blurred so they read as soft aurora curtains.
private struct AuroraRibbons: View {
    let reduceMotion: Bool
    let colors: [Color]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { ctx in
            let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                for i in 0..<colors.count {
                    var path = Path()
                    let yBase = size.height * (0.34 + 0.11 * Double(i))
                    let amp = 70.0 + 20.0 * Double(i)
                    let speed = 0.35 + 0.12 * Double(i)
                    var x = 0.0
                    path.move(to: CGPoint(x: 0, y: yBase))
                    while x <= size.width {
                        let phase = (x / size.width) * .pi * 3 + t * speed + Double(i)
                        let y = yBase + sin(phase) * amp
                        path.addLine(to: CGPoint(x: x, y: y))
                        x += 10
                    }
                    gc.stroke(path, with: .color(colors[i].opacity(0.5)),
                              style: StrokeStyle(lineWidth: 110, lineCap: .round))
                }
            }
            .blur(radius: 70)
            .blendMode(.screen)
        }
    }
}
