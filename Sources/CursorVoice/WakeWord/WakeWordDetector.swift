import Foundation
import Speech
import AVFoundation

/// Continuous speech recognition that fires `onDetect` when the wake phrase
/// appears in a partial transcript. Requires mic + speech recognition perms.
/// Auto-restarts every ~55s (SFSpeechRecognitionTask has a ~1min ceiling).
final class WakeWordDetector {
    var onDetect: (() -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var phrase: String = "hey cursor"
    private var phraseTokens: [String] = ["hey", "cursor"]
    private var isRunning = false
    private var restartTimer: Timer?

    func start(phrase: String) {
        let normalized = phrase.lowercased().trimmingCharacters(in: .whitespaces)
        self.phrase = normalized
        self.phraseTokens = normalized.split(separator: " ").map(String.init)
        NSLog("WakeWord: requested with phrase=\(normalized)")

        // Need both speech-recognition + microphone authorization.
        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            NSLog("WakeWord: speech auth status=\(speechStatus.rawValue)")
            guard speechStatus == .authorized else {
                NSLog("WakeWord: NOT authorized for speech recognition — bailing")
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                NSLog("WakeWord: mic granted=\(micGranted)")
                guard micGranted else { return }
                DispatchQueue.main.async { self?.spinUp() }
            }
        }
    }

    func stop() {
        isRunning = false
        restartTimer?.invalidate()
        restartTimer = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            NSLog("WakeWord: stopped")
        }
    }

    private func spinUp() {
        guard !isRunning else { return }
        let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let rec = rec else {
            NSLog("WakeWord: no recognizer for en-US")
            return
        }
        guard rec.isAvailable else {
            NSLog("WakeWord: recognizer not available; will retry in 4s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.spinUp() }
            return
        }
        // Prefer on-device but accept server if it's the only option.
        let preferOnDevice = rec.supportsOnDeviceRecognition
        recognizer = rec

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = preferOnDevice
        // Bias the recognizer toward the wake phrase + its words. This is the
        // single biggest accuracy lever for short trigger phrases.
        req.contextualStrings = Array(Set([phrase] + phraseTokens))
        if #available(macOS 13, *) { req.addsPunctuation = false }
        request = req
        NSLog("WakeWord: starting (onDevice=\(preferOnDevice))")

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Defensive: AVAudioEngine sometimes hands back a 0Hz format briefly
        // right after a permission grant. Retry if that happens.
        guard format.sampleRate > 0 else {
            NSLog("WakeWord: input format invalid (sr=\(format.sampleRate)); retry")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.spinUp() }
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("WakeWord: engine.start() failed: \(error)")
            return
        }

        var lastLogged = ""
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString.lowercased()
                if text != lastLogged && !text.isEmpty {
                    NSLog("WakeWord: heard \"\(text)\"")
                    lastLogged = text
                }
                if self.matches(text) {
                    NSLog("WakeWord: MATCH in \"\(text)\"")
                    self.onDetect?()
                    self.cycle()
                }
            }
            if let error = error {
                let nsErr = error as NSError
                // Code 1110 = "no speech detected" / 203 = "retry" — these are normal.
                if nsErr.code != 1110 && nsErr.code != 203 {
                    NSLog("WakeWord: recognition error \(nsErr.code): \(nsErr.localizedDescription)")
                }
                self.cycle()
            }
        }

        isRunning = true
        NSLog("WakeWord: live, listening for \"\(phrase)\"")
        restartTimer = Timer.scheduledTimer(withTimeInterval: 55, repeats: true) { [weak self] _ in
            self?.cycle()
        }
    }

    /// Fuzzy match: the phrase tokens appear in order, each allowing a small
    /// spelling slip (homophones / mis-hearings like "curser", "cursur").
    /// Also fires if the most distinctive token (the longest one, e.g.
    /// "cursor") shows up near-verbatim — covers cases where the recognizer
    /// drops the leading "hey".
    private func matches(_ text: String) -> Bool {
        guard !phraseTokens.isEmpty else { return false }
        let words = text.split(whereSeparator: { !$0.isLetter }).map { String($0).lowercased() }
        guard !words.isEmpty else { return false }

        // In-order fuzzy sequence match.
        var idx = 0
        for w in words {
            if fuzzyEqual(w, phraseTokens[idx]) {
                idx += 1
                if idx == phraseTokens.count { return true }
            }
        }

        // Fallback: the key (longest) token appears near-verbatim.
        if let key = phraseTokens.max(by: { $0.count < $1.count }), key.count >= 5 {
            if words.contains(where: { fuzzyEqual($0, key) }) { return true }
        }
        return false
    }

    /// Equal allowing edit distance ≤1 for tokens of length ≥4 (else exact).
    private func fuzzyEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard b.count >= 4 else { return false }
        return levenshtein(a, b) <= 1
    }

    private func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if abs(s.count - t.count) > 1 { return 2 }   // early-out; we only care about ≤1
        var prev = Array(0...t.count)
        var cur = [Int](repeating: 0, count: t.count + 1)
        for i in 1...max(1, s.count) {
            guard i <= s.count else { break }
            cur[0] = i
            for j in 1...max(1, t.count) {
                guard j <= t.count else { break }
                let cost = s[i-1] == t[j-1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[t.count]
    }

    private func cycle() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.spinUp()
        }
    }
}
