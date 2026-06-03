import SwiftUI

/// Small, premium glass orb — aurora swirl *inside* the sphere, soft outer glow.
/// Inspired by ChatGPT voice mode + Apple Intelligence aesthetic. Compact, calm.
struct OrbView: View {
    @ObservedObject var state: OrbState
    var onDismiss: () -> Void

    @State private var phase: Phase = .hidden
    enum Phase { case hidden, appearing, settled, dismissing }

    // Sizing
    private let orbSize: CGFloat = 42
    private let panelSize: CGFloat = 280

    // Animation state
    @State private var scale: CGFloat = 0.2
    @State private var opacity: CGFloat = 0
    @State private var blurAmount: CGFloat = 14
    @State private var shockProgress: CGFloat = 0
    @State private var shockOpacity: CGFloat = 0

    var body: some View {
        ZStack {
            // Click-outside-to-dismiss capture
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 8) {
                orbVisual
                    .frame(width: orbSize, height: orbSize)
                    .scaleEffect(scale)
                    .opacity(opacity)
                    .blur(radius: blurAmount)
                    .compositingGroup()
                    .onTapGesture { /* eat */ }

                statusPill
                    .opacity(phase == .settled ? 0.95 : 0)
                    .offset(y: phase == .settled ? 0 : 4)
                    .animation(.easeOut(duration: 0.25).delay(0.12), value: phase)

                if state.sessionCost > 0 && phase == .settled {
                    costPill
                        .transition(.opacity)
                }

                if !trimmedTranscript.isEmpty {
                    transcriptBubble
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .onTapGesture { /* eat */ }
                }
            }
            .animation(.easeOut(duration: 0.22), value: trimmedTranscript)
        }
        .frame(width: panelSize, height: panelSize)
        .onAppear { runReveal() }
        .onChange(of: state.isVisible) { _, visible in
            if visible { runReveal() } else { runDismiss() }
        }
    }

    // MARK: - Orb composition

    private var orbVisual: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let lvl = CGFloat(max(state.audioLevel, state.outputLevel))

            ZStack {
                // Shockwave (reveal)
                Circle()
                    .strokeBorder(.white.opacity(shockOpacity), lineWidth: 1.5 * (1 - shockProgress))
                    .frame(width: orbSize * (1 + 1.4 * shockProgress),
                           height: orbSize * (1 + 1.4 * shockProgress))

                // Outer glow — soft, audio-reactive
                Circle()
                    .fill(auroraGradient(time: t))
                    .frame(width: orbSize * 2.0, height: orbSize * 2.0)
                    .blur(radius: orbSize * 0.55)
                    .opacity(0.35 + 0.18 * breathing(t) + 0.25 * Double(lvl))

                // Glass sphere with aurora swirling inside
                ZStack {
                    // Aurora interior (clipped to circle)
                    Circle()
                        .fill(auroraGradient(time: t * 1.1))
                        .blur(radius: orbSize * 0.18)
                        .scaleEffect(1.25)
                        .offset(x: sin(t * 0.6) * orbSize * 0.06,
                                y: cos(t * 0.5) * orbSize * 0.06)

                    // Subtle white veil to give it "glass" softness
                    Circle()
                        .fill(.white.opacity(0.08))

                    // Bright center pulse on audio
                    Circle()
                        .fill(RadialGradient(
                            colors: [.white.opacity(0.9), .white.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: orbSize * 0.5
                        ))
                        .scaleEffect(0.3 + lvl * 0.7)
                        .opacity(0.35 + Double(lvl) * 0.55)
                        .animation(.easeOut(duration: 0.08), value: lvl)
                }
                .frame(width: orbSize, height: orbSize)
                .clipShape(Circle())

                // Glass rim
                Circle()
                    .strokeBorder(.white.opacity(0.55), lineWidth: 0.6)
                    .frame(width: orbSize, height: orbSize)

                // Top specular highlight
                Ellipse()
                    .fill(.white.opacity(0.75))
                    .frame(width: orbSize * 0.36, height: orbSize * 0.16)
                    .offset(x: -orbSize * 0.10, y: -orbSize * 0.20)
                    .blur(radius: 2.2)

                // Thinking trace — only when processing
                if case .thinking = state.connection {
                    TraceArc(time: t, radius: orbSize * 0.54)
                }
            }
            .shadow(color: auroraShadow.opacity(0.55), radius: orbSize * 0.25, y: 3)
        }
    }

    private var statusPill: some View {
        Text(statusText)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.96))
            .multilineTextAlignment(.center)
            .lineLimit(isErrorState ? 4 : 1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: isErrorState ? 240 : .infinity)
            // Stacked shadows = soft halo that keeps text readable on any backdrop.
            .shadow(color: .black.opacity(0.9), radius: 1, y: 0)
            .shadow(color: .black.opacity(0.7), radius: 3, y: 0)
            .shadow(color: .black.opacity(0.5), radius: 8, y: 1)
    }

    /// Tiny running spend estimate for this session.
    private var costPill: some View {
        Text("~\(CostMeter.short(state.sessionCost)) this session")
            .font(.system(size: 9.5, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.6))
            .shadow(color: .black.opacity(0.8), radius: 2, y: 0)
            .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
    }

    private var isErrorState: Bool {
        if case .error = state.connection { return true } else { return false }
    }

    /// Last ~180 chars of the model's spoken transcript so the bubble stays compact.
    private var trimmedTranscript: String {
        let t = state.lastTranscript
        guard !t.isEmpty else { return "" }
        if t.count <= 180 { return t }
        return "…" + String(t.suffix(178))
    }

    private var transcriptBubble: some View {
        Text(trimmedTranscript)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.96))
            .multilineTextAlignment(.center)
            .lineLimit(5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 240)
            // Same shadow-halo trick — no rectangle, just legible floating text.
            .shadow(color: .black.opacity(0.9), radius: 1, y: 0)
            .shadow(color: .black.opacity(0.7), radius: 4, y: 0)
            .shadow(color: .black.opacity(0.5), radius: 10, y: 2)
    }

    private var statusText: String {
        // Tool activity wins — shows what's actually happening right now.
        if let t = state.activeTool { return t + "…" }
        switch state.connection {
        case .idle:        return "ready"
        case .connecting:  return "connecting…"
        case .listening:   return "listening"
        case .thinking:    return "thinking"
        case .speaking:    return "speaking"
        case .error(let m): return Self.shortenError(m)
        }
    }

    /// Strip URLs and trailing diagnostic chatter from API errors so the pill
    /// shows the useful human-readable bit ("You exceeded your current quota…").
    private static func shortenError(_ raw: String) -> String {
        var s = raw
        // Drop "For more information…" tail and any URL.
        if let r = s.range(of: " For more information") { s = String(s[..<r.lowerBound]) }
        if let r = s.range(of: " read the docs:") { s = String(s[..<r.lowerBound]) }
        // Cap total length.
        if s.count > 160 { s = String(s.prefix(157)) + "…" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Reveal/dismiss

    private func runReveal() {
        phase = .appearing
        scale = 0.25; opacity = 0; blurAmount = 14
        shockProgress = 0; shockOpacity = 0.6

        withAnimation(.spring(response: 0.38, dampingFraction: 0.66)) {
            scale = 1.0
            opacity = 1
            blurAmount = 0
        }
        withAnimation(.easeOut(duration: 0.8)) {
            shockProgress = 1
            shockOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
            phase = .settled
        }
    }

    private func runDismiss() {
        phase = .dismissing
        withAnimation(.easeIn(duration: 0.20)) {
            scale = 0.2
            opacity = 0
            blurAmount = 16
        }
    }

    // MARK: - Visuals helpers

    private func breathing(_ t: TimeInterval) -> Double {
        sin(t * 1.1) * 0.5 + 0.5
    }

    private var auroraShadow: Color {
        Color(red: 0.55, green: 0.30, blue: 0.95)
    }

    private func auroraGradient(time t: TimeInterval) -> AngularGradient {
        AngularGradient(
            colors: [
                Color(red: 0.55, green: 0.30, blue: 0.95),   // violet
                Color(red: 0.97, green: 0.45, blue: 0.78),   // pink
                Color(red: 0.40, green: 0.78, blue: 1.00),   // sky
                Color(red: 0.42, green: 0.97, blue: 0.90),   // mint
                Color(red: 0.55, green: 0.30, blue: 0.95)
            ],
            center: .center,
            angle: .degrees(t.truncatingRemainder(dividingBy: 8) * 45)
        )
    }
}

private struct TraceArc: View {
    let time: TimeInterval
    let radius: CGFloat
    var body: some View {
        let angle = time.truncatingRemainder(dividingBy: 1.4) * (360 / 1.4)
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(
                AngularGradient(
                    colors: [.white.opacity(0), .white.opacity(0.95), .white.opacity(0)],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
            )
            .frame(width: radius * 2, height: radius * 2)
            .rotationEffect(.degrees(angle))
    }
}
