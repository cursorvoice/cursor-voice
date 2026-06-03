import AVFoundation
import Accelerate
import CoreAudio

/// Captures mic audio at 24kHz mono PCM16 and plays back PCM16 chunks
/// received from the Realtime API. Exposes input/output level callbacks.
final class AudioEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let mixer = AVAudioMixerNode()

    private let sampleRate: Double = 24000
    private var inputConverter: AVAudioConverter?

    /// UID of the input device to use (nil = system default). Set before start().
    var preferredInputUID: String?

    /// Fires on the audio thread — hop to main if updating UI.
    var onInputChunk: ((Data) -> Void)?
    var onInputLevel: ((Float) -> Void)?
    var onOutputLevel: ((Float) -> Void)?

    private(set) var isRunning = false

    init() {
        engine.attach(player)
        engine.attach(mixer)
    }

    func start() throws {
        guard !isRunning else { return }
        // Try with acoustic echo cancellation (voice-processing I/O) first — it
        // stops the mic hearing the assistant through the speakers. But VPIO
        // fails to initialize on some setups (external/USB mics, Mac mini, etc.)
        // with errors like -10875, so fall back to a plain engine if it throws.
        do {
            try configureAndStart(useVoiceProcessing: true)
            NSLog("AudioEngine: started with echo cancellation")
        } catch {
            NSLog("AudioEngine: AEC start failed (\((error as NSError).code)) — retrying without it")
            cleanupNodes()
            try configureAndStart(useVoiceProcessing: false)
            NSLog("AudioEngine: started without echo cancellation")
        }
        isRunning = true
    }

    private func configureAndStart(useVoiceProcessing: Bool) throws {
        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(useVoiceProcessing)

        applyPreferredInputDevice()
        let inputFormat = input.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: true)!
        inputConverter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer: buffer, targetFormat: targetFormat)
        }

        // Playback chain: player → mixer → output.
        let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: mixer, format: playbackFormat)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)

        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.report(level: Self.level(buffer: buffer), as: \AudioEngine.onOutputLevel)
        }

        engine.prepare()
        try engine.start()
        player.play()
    }

    /// Undo taps/engine state so we can retry configuration cleanly.
    private func cleanupNodes() {
        engine.inputNode.removeTap(onBus: 0)
        mixer.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
    }

    /// Point the engine's input node at the user-selected Core Audio device.
    /// Must be set on the input node's audio unit before the engine starts.
    private func applyPreferredInputDevice() {
        guard let uid = preferredInputUID,
              let deviceID = AudioDevices.deviceID(forUID: uid),
              let au = engine.inputNode.audioUnit else { return }
        var dev = deviceID
        let status = AudioUnitSetProperty(au,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            NSLog("AudioEngine: failed to set input device \(uid) (\(status)) — using default")
        } else {
            NSLog("AudioEngine: using input device \(uid)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        mixer.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        isRunning = false
    }

    /// Schedule a PCM16 24kHz mono chunk for playback.
    func enqueueOutput(_ data: Data) {
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0 else { return }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        guard let channel = buffer.floatChannelData?[0] else { return }
        data.withUnsafeBytes { raw in
            let int16Ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frameCount) {
                channel[i] = Float(int16Ptr[i]) / 32768.0
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Clear queued playback (used when the model is interrupted). Drops
    /// volume to zero almost instantly, stops + flushes the player, then
    /// restores volume — gives a quick cut with no audible click.
    func cancelPlayback() {
        let originalVol = mixer.outputVolume
        mixer.outputVolume = 0
        player.stop()
        // Brief gap before restoring volume + restarting the player,
        // so any straggler buffers we DO end up enqueueing get dropped
        // by the stop() above instead of leaking out at full volume.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.player.play()
            self?.mixer.outputVolume = originalVol
        }
    }

    // MARK: - Private

    private func handleInput(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter = inputConverter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * (targetFormat.sampleRate / buffer.format.sampleRate)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var supplied = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil { return }
        guard out.frameLength > 0 else { return }

        // Emit raw PCM16 bytes.
        let byteCount = Int(out.frameLength) * 2
        if let ptr = out.int16ChannelData?[0] {
            let data = Data(bytes: ptr, count: byteCount)
            onInputChunk?(data)
        }
        report(level: Self.level(buffer: out), as: \AudioEngine.onInputLevel)
    }

    private func report(level: Float, as keyPath: KeyPath<AudioEngine, ((Float) -> Void)?>) {
        if let cb = self[keyPath: keyPath] { cb(level) }
    }

    /// RMS level normalized to 0…1 (roughly).
    private static func level(buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        if frames == 0 { return 0 }
        if let f = buffer.floatChannelData?[0] {
            var rms: Float = 0
            vDSP_rmsqv(f, 1, &rms, vDSP_Length(frames))
            return min(1, rms * 6)
        }
        if let i = buffer.int16ChannelData?[0] {
            var sum: Float = 0
            for n in 0..<frames {
                let v = Float(i[n]) / 32768
                sum += v * v
            }
            return min(1, sqrt(sum / Float(frames)) * 6)
        }
        return 0
    }
}
