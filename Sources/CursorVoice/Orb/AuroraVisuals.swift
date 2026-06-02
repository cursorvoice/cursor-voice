import SwiftUI

/// Shared aurora visuals used by the launch intro and the sign-in gate.

/// Flowing northern-lights bands: sine-displaced thick strokes, heavily blurred
/// so they read as soft aurora curtains.
struct AuroraRibbons: View {
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
                        path.addLine(to: CGPoint(x: x, y: yBase + sin(phase) * amp))
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

/// The glowing iridescent glass orb (rotating aurora core + glow + highlight).
struct AuroraOrb: View {
    var size: CGFloat = 120
    var reduceMotion: Bool = false

    private let v = Color(red: 0.55, green: 0.30, blue: 0.95)
    private let p = Color(red: 0.97, green: 0.45, blue: 0.78)
    private let s = Color(red: 0.40, green: 0.78, blue: 1.00)
    private let m = Color(red: 0.42, green: 0.97, blue: 0.90)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().fill(aurora(t))
                    .frame(width: size * 1.8, height: size * 1.8)
                    .blur(radius: size * 0.34).opacity(0.65)
                Circle().fill(RadialGradient(
                        colors: [.white.opacity(0.95), .white.opacity(0.5), .white.opacity(0.08)],
                        center: .center, startRadius: 0, endRadius: size / 2))
                    .frame(width: size * 0.8, height: size * 0.8)
                Circle().fill(aurora(t * 1.1))
                    .frame(width: size * 0.8, height: size * 0.8)
                    .blur(radius: size * 0.1).opacity(0.7).blendMode(.screen)
                Ellipse().fill(.white.opacity(0.7))
                    .frame(width: size * 0.3, height: size * 0.16)
                    .offset(x: -size * 0.16, y: -size * 0.22).blur(radius: 6)
                Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.8)
                    .frame(width: size * 0.8, height: size * 0.8)
            }
            .shadow(color: v.opacity(0.6), radius: size * 0.34)
        }
        .frame(width: size, height: size)
    }

    private func aurora(_ t: TimeInterval) -> AngularGradient {
        AngularGradient(colors: [v, p, s, m, v], center: .center,
                        angle: .degrees(reduceMotion ? 220 : t.truncatingRemainder(dividingBy: 8) * 45))
    }
}
