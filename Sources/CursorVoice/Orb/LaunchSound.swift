import AVFoundation

/// A soft, synthesized "aurora" chime for the launch intro — an ascending,
/// gently-detuned chord that shimmers in and fades out. Self-contained
/// (no audio asset), played once.
enum LaunchSound {
    nonisolated(unsafe) private static var engine: AVAudioEngine?
    nonisolated(unsafe) private static var player: AVAudioPlayerNode?

    static func play(duration: Double = 2.8) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let sr = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2) else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let frames = AVAudioFrameCount(sr * duration)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let L = buf.floatChannelData?[0], let R = buf.floatChannelData?[1] else { return }
        buf.frameLength = frames

        // A dreamy ascending voicing (C, G, C, E, G across two octaves).
        let freqs: [Double] = [261.63, 392.00, 523.25, 659.25, 783.99]

        for n in 0..<Int(frames) {
            let t = Double(n) / sr
            let env = envelope(t, duration)
            var s = 0.0
            for (i, f) in freqs.enumerated() {
                // Stagger each note's entrance for a rising shimmer.
                let start = Double(i) * 0.16
                let noteEnv = t > start ? min(1, (t - start) / 0.35) : 0
                let amp = noteEnv * (0.15 / Double(freqs.count))
                s += sin(2 * .pi * f * t) * amp
                s += sin(2 * .pi * (f * 1.004) * t) * amp * 0.5   // subtle detune
            }
            let v = Float(s * env)
            L[n] = v; R[n] = v
        }

        engine.prepare()
        do { try engine.start() } catch { return }
        player.play()
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        self.engine = engine; self.player = player

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.4) {
            player.stop(); engine.stop()
            self.player = nil; self.engine = nil
        }
    }

    /// Slow attack, sustain, gentle release.
    private static func envelope(_ t: Double, _ dur: Double) -> Double {
        let attack = 0.6, release = 1.4
        if t < attack { return t / attack }
        if t > dur - release { return max(0, (dur - t) / release) }
        return 1
    }
}
