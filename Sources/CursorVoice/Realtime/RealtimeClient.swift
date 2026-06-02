import Foundation

/// WebSocket client for the OpenAI Realtime API.
/// Streams microphone audio up, plays audio chunks down, dispatches tool calls.
final class RealtimeClient: NSObject, URLSessionWebSocketDelegate {
    private let apiKey: String
    private let model: String
    private let voice: String
    private let instructions: String

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private let audio = AudioEngine()
    private let tools = ToolHandler()

    var onStateChange: ((ConnectionState) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onInputActivity: ((Bool) -> Void)?
    var onToolStart: ((String) -> Void)?
    var onToolEnd: (() -> Void)?

    private var transcriptBuffer = ""
    private var pendingToolArgs: [String: String] = [:] // call_id -> json string
    private var lastServerError: String?

    // Interruption tracking: who's speaking, how much, what to truncate.
    private var activeResponseId: String?
    private var activeAssistantItemId: String?
    private var emittedOutputBytes: Int = 0   // total PCM16 24kHz bytes received this response

    init(apiKey: String, model: String, voice: String, instructions: String) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        self.instructions = instructions
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

        audio.onInputChunk = { [weak self] data in self?.sendAudioChunk(data) }
        audio.onInputLevel = { [weak self] level in self?.onAudioLevel?(level) }
        audio.onOutputLevel = { _ in }

        // Hook tool activity (for the cursor halo) — forward into the client's callback.
        Task { [weak self] in
            await self?.tools.setInputActivityCallback { active in
                self?.onInputActivity?(active)
            }
            await self?.tools.setToolCallbacks(
                start: { label in self?.onToolStart?(label) },
                end:   { self?.onToolEnd?() }
            )
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        NSLog("Realtime: WebSocket opened (protocol=\(proto ?? "none"))")
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        NSLog("Realtime: WebSocket closed code=\(closeCode.rawValue) reason=\(reasonStr)")
        // Prefer the server-provided error (e.g. quota exceeded) over a generic close code.
        if let server = lastServerError {
            onStateChange?(.error(server))
        } else if !reasonStr.isEmpty {
            onStateChange?(.error(reasonStr))
        } else {
            onStateChange?(.error("ws closed (\(closeCode.rawValue))"))
        }
    }

    func urlSession(_ session: URLSession,
                    task urlTask: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            let nsErr = error as NSError
            NSLog("Realtime: task error domain=\(nsErr.domain) code=\(nsErr.code) msg=\(nsErr.localizedDescription)")
            onStateChange?(.error("\(nsErr.localizedDescription)"))
            return
        }
        if let http = urlTask.response as? HTTPURLResponse {
            NSLog("Realtime: handshake HTTP \(http.statusCode)")
            if http.statusCode != 101 {
                onStateChange?(.error("auth/HTTP \(http.statusCode)"))
            }
        }
    }

    // MARK: - Connect / disconnect

    func connect() {
        onStateChange?(.connecting)
        let urlString = "wss://api.openai.com/v1/realtime?model=\(model)"
        NSLog("Realtime: connecting to \(urlString)")
        var req = URLRequest(url: URL(string: urlString)!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // GA API — no OpenAI-Beta header.
        task = session.webSocketTask(with: req)
        task?.resume()
        receive()
        sendSessionUpdate()
        do {
            try audio.start()
            onStateChange?(.listening)
            NSLog("Realtime: audio engine started")
        } catch {
            NSLog("Realtime: audio engine FAILED: \(error)")
            onStateChange?(.error("mic: \(error.localizedDescription)"))
        }
    }

    func disconnect() {
        audio.stop()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onStateChange?(.idle)
    }

    // MARK: - Outgoing

    private func sendSessionUpdate() {
        let allTools = ToolHandler.toolDefinitions
        let session: [String: Any] = [
            "type": "realtime",
            "model": model,
            "output_modalities": ["audio"],
            "instructions": instructions,
            "audio": [
                "input": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    // server_vad is more responsive for interruption (volume-based)
                    // than semantic_vad (content-based, can ignore quick barge-ins).
                    // threshold MUST be a value exactly representable in IEEE-754
                    // (otherwise JSONSerialization sends 17 decimal places and the
                    // server rejects the entire session.update). 0.5 is exact.
                    "turn_detection": [
                        "type": "server_vad",
                        "threshold": 0.5,
                        "prefix_padding_ms": 200,
                        "silence_duration_ms": 400
                    ],
                    "transcription": ["model": "whisper-1"]
                ],
                "output": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "voice": voice
                ]
            ],
            "tools": allTools,
            "tool_choice": "auto"
        ]
        send(event: ["type": "session.update", "session": session])
    }

    private func sendAudioChunk(_ pcm16: Data) {
        let b64 = pcm16.base64EncodedString()
        send(event: ["type": "input_audio_buffer.append", "audio": b64])
    }

    private func send(event: [String: Any]) {
        guard let task = task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let str = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { error in
            if let error = error { NSLog("WS send error: \(error)") }
        }
    }

    /// User barged in while the model was speaking. Stop local playback,
    /// cancel any in-flight response on the server, and truncate the
    /// assistant's current message so the conversation history reflects
    /// only what the user actually heard.
    private func barge() {
        NSLog("Realtime: barge-in (played ≈ \(playedMs) ms)")
        audio.cancelPlayback()
        if activeResponseId != nil {
            send(event: ["type": "response.cancel"])
        }
        if let itemId = activeAssistantItemId, playedMs > 50 {
            send(event: [
                "type": "conversation.item.truncate",
                "item_id": itemId,
                "content_index": 0,
                "audio_end_ms": playedMs
            ])
        }
        activeResponseId = nil
        activeAssistantItemId = nil
        emittedOutputBytes = 0
        // Reset transcript buffer too so the next response starts fresh.
        transcriptBuffer = ""
        onTranscript?("")
        onStateChange?(.listening)
    }

    /// PCM16 mono @ 24 kHz → 2 bytes/sample → 24_000 samples/sec.
    private var playedMs: Int { (emittedOutputBytes / 2) * 1000 / 24000 }

    private func sendToolOutput(callId: String, output: String, imageBase64: String? = nil) {
        // If the tool attached a screenshot, inject it as an input_image
        // user message first so it becomes part of the conversation history.
        if let b64 = imageBase64 {
            send(event: [
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_image",
                            "image_url": "data:image/jpeg;base64,\(b64)"
                        ]
                    ]
                ]
            ])
        }
        send(event: [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": output
            ]
        ])
        send(event: ["type": "response.create"])
    }

    // MARK: - Incoming

    private func receive() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                self.onStateChange?(.error(err.localizedDescription))
            case .success(let msg):
                switch msg {
                case .string(let s): self.handle(string: s)
                case .data(let d):
                    if let s = String(data: d, encoding: .utf8) { self.handle(string: s) }
                @unknown default: break
                }
                self.receive()
            }
        }
    }

    private func handle(string: String) {
        guard let data = string.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "response.created":
            if let resp = obj["response"] as? [String: Any], let id = resp["id"] as? String {
                activeResponseId = id
            }
            emittedOutputBytes = 0
            activeAssistantItemId = nil

        case "response.output_item.added":
            if let item = obj["item"] as? [String: Any],
               let id = item["id"] as? String,
               (item["role"] as? String) == "assistant" {
                activeAssistantItemId = id
            }

        case "response.done":
            activeResponseId = nil
            activeAssistantItemId = nil
            emittedOutputBytes = 0

        case "response.output_audio.delta", "response.audio.delta":
            // If we've barged, drop any straggler deltas the server emitted
            // before it processed our response.cancel — otherwise it keeps
            // talking after we interrupt.
            guard activeResponseId != nil else { break }
            if let b64 = obj["delta"] as? String, let data = Data(base64Encoded: b64) {
                emittedOutputBytes += data.count
                audio.enqueueOutput(data)
                onStateChange?(.speaking)
            }
        case "response.output_audio.done", "response.audio.done":
            guard activeResponseId != nil else { break }
            onStateChange?(.listening)
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            guard activeResponseId != nil else { break }
            if let delta = obj["delta"] as? String {
                transcriptBuffer += delta
                onTranscript?(transcriptBuffer)
            }
        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            // Keep last completed transcript visible until next response starts.
            break
        case "input_audio_buffer.speech_started":
            // User started talking — barge in.
            barge()
        case "input_audio_buffer.speech_stopped":
            onStateChange?(.thinking)
        case "response.function_call_arguments.delta":
            if let callId = obj["call_id"] as? String, let delta = obj["delta"] as? String {
                pendingToolArgs[callId, default: ""] += delta
            }
        case "response.function_call_arguments.done":
            if let callId = obj["call_id"] as? String,
               let name = obj["name"] as? String {
                let args = pendingToolArgs[callId] ?? (obj["arguments"] as? String ?? "{}")
                pendingToolArgs[callId] = nil
                Task.detached { [weak self] in
                    guard let self = self else { return }
                    let result = await self.tools.dispatch(name: name, argsJSON: args)
                    self.sendToolOutput(callId: callId,
                                        output: result.outputJSON,
                                        imageBase64: result.attachedImageBase64)
                }
            }
        case "error":
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                NSLog("Realtime: server error \(msg)")
                lastServerError = msg
                onStateChange?(.error(msg))
            }
        case "session.created", "session.updated":
            NSLog("Realtime: \(type)")
        default:
            break
        }
    }
}
