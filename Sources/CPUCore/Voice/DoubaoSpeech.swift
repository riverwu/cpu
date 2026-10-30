import AVFoundation
import Foundation

/// Volcengine (Doubao) speech credentials, from the environment or the login shell:
/// DOUBAO_APP_ID + DOUBAO_ACCESS_TOKEN (or DOUBAO_API_KEY), resource ids and voice optional.
public struct DoubaoCredentials {
    let appId: String?
    let accessToken: String?
    let apiKey: String?
    let asrResource: String
    let ttsResource: String
    let voice: String

    public static func load() -> DoubaoCredentials? {
        func value(_ name: String) -> String? {
            ShellEnvironment.value(name).flatMap { $0.isEmpty ? nil : $0 }
        }
        let appId = value("DOUBAO_APP_ID")
        let accessToken = value("DOUBAO_ACCESS_TOKEN")
        // The console API key works for both services; app id + token only for synthesis.
        let apiKey = value("DOUBAO_ASR_API_KEY") ?? value("DOUBAO_API_KEY")
        guard (appId != nil && accessToken != nil) || apiKey != nil else {
            return nil
        }
        let ttsResource = value("DOUBAO_TTS_RESOURCE_ID") ?? "seed-tts-2.0"
        var voice = value("DOUBAO_TTS_VOICE") ?? "zh_female_cancan_uranus_bigtts"
        // Speech 2.0 (seed-tts) voices are the "uranus" generation of the 1.0 "mars" ones.
        if ttsResource.hasPrefix("seed-tts") {
            voice = voice.replacingOccurrences(of: "_mars_", with: "_uranus_")
        }
        return DoubaoCredentials(
            appId: appId, accessToken: accessToken, apiKey: apiKey,
            asrResource: value("DOUBAO_ASR_RESOURCE_ID") ?? "volc.bigasr.sauc.duration",
            ttsResource: ttsResource, voice: voice
        )
    }
}

// MARK: - Binary frames

/// The openspeech v3 framing: 4-byte header (version/size, type/flags, serialization/
/// compression), optional sequence, 4-byte payload size, payload.
enum OpenSpeechFrame {
    static func make(type: UInt8, flags: UInt8, json: Bool, payload: Data) -> Data {
        var frame = Data([0x11, (type << 4) | flags, ((json ? 1 : 0) << 4) | 0x1, 0x00])
        let compressed = Gzip.compress(payload)
        var size = UInt32(compressed.count).bigEndian
        frame.append(Data(bytes: &size, count: 4))
        frame.append(compressed)
        return frame
    }

    struct Parsed {
        let type: UInt8
        let final: Bool
        let errorCode: UInt32?
        let json: [String: Any]?
    }

    static func parse(_ data: Data) -> Parsed? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else {
            return nil
        }
        let headerSize = Int(bytes[0] & 0x0F) * 4
        let type = bytes[1] >> 4
        let flags = bytes[1] & 0x0F
        let compressed = bytes[2] & 0x0F == 0x1
        var position = headerSize
        func readUInt32() -> UInt32? {
            guard position + 4 <= bytes.count else {
                return nil
            }
            defer { position += 4 }
            return UInt32(bytes[position]) << 24 | UInt32(bytes[position + 1]) << 16 | UInt32(bytes[position + 2]) << 8 | UInt32(bytes[position + 3])
        }
        func payload(size: UInt32) -> [String: Any]? {
            let end = min(bytes.count, position + Int(size))
            var body = Data(bytes[position..<end])
            if compressed {
                body = Gzip.decompress(body) ?? body
            }
            return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
        if type == 0xF {
            let code = readUInt32()
            let size = readUInt32() ?? 0
            return Parsed(type: type, final: true, errorCode: code, json: payload(size: size))
        }
        var final = flags == 0x3
        if flags & 0x1 != 0, let sequence = readUInt32() {
            final = final || Int32(bitPattern: sequence) < 0
        }
        let size = readUInt32() ?? 0
        return Parsed(type: type, final: final, errorCode: nil, json: payload(size: size))
    }
}

// MARK: - Streaming recognition

/// Doubao big-model streaming ASR (bigmodel_async): 16 kHz mono PCM up, full text down.
public final class DoubaoTranscriber: Transcriber {
    public let name = "doubao"
    public var onPartial: ((String) -> Void)?
    public var onEndpoint: (() -> Void)?
    /// Utterances the server has closed so far; each new one is a possible end of the request.
    private var definiteCount = 0
    private let credentials: DoubaoCredentials
    private let session = URLSession(configuration: .default)
    private var socket: URLSessionWebSocketTask?
    private var converter: AVAudioConverter?
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private let lock = NSLock()
    private var pending = Data()
    private var text = ""
    private var done = false
    private var failure: String?
    private var waiter: Once<String>?
    /// 200 ms of 16 kHz 16-bit audio per frame, as the service recommends.
    private let frameBytes = 6_400

    init(credentials: DoubaoCredentials) {
        self.credentials = credentials
    }

    /// Nil without Doubao credentials.
    public static func make() -> DoubaoTranscriber? {
        DoubaoCredentials.load().map(DoubaoTranscriber.init)
    }

    public func start(format: AVAudioFormat) async throws {
        converter = AVAudioConverter(from: format, to: pcmFormat)
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!)
        let id = UUID().uuidString
        request.setValue(credentials.asrResource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(id, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue(id, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        if let apiKey = credentials.apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        } else if let appId = credentials.appId, let token = credentials.accessToken {
            request.setValue(appId, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(token, forHTTPHeaderField: "X-Api-Access-Key")
        }
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        let setup: [String: Any] = [
            "user": ["uid": "cpu-mac"],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16_000, "bits": 16, "channel": 1],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "show_utterances": true,
                "result_type": "full",
                // Marks an utterance definite after 800 ms of silence; `Endpointing` decides
                // whether that ends the request or is a pause mid-thought.
                "end_window_size": 800
            ]
        ]
        let payload = try JSONSerialization.data(withJSONObject: setup)
        try await socket.send(.data(OpenSpeechFrame.make(type: 0x1, flags: 0x0, json: true, payload: payload)))
        receive()
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .success(.data(let data)):
                self.handle(OpenSpeechFrame.parse(data))
                self.lock.lock()
                let finished = self.done
                self.lock.unlock()
                if !finished {
                    self.receive()
                }
            case .success:
                self.receive()
            case .failure(let error):
                self.end(failure: String(describing: error))
            }
        }
    }

    private func handle(_ frame: OpenSpeechFrame.Parsed?) {
        guard let frame else {
            return
        }
        if let code = frame.errorCode {
            end(failure: "Doubao ASR error \(code): \(frame.json ?? [:])")
            return
        }
        var latest: String?
        var utterances: [[String: Any]] = []
        if let result = frame.json?["result"] as? [String: Any] {
            latest = result["text"] as? String
            utterances = result["utterances"] as? [[String: Any]] ?? []
        } else if let results = frame.json?["result"] as? [[String: Any]] {
            latest = results.compactMap { $0["text"] as? String }.joined()
            utterances = results.flatMap { $0["utterances"] as? [[String: Any]] ?? [] }
        }
        if let latest {
            lock.lock()
            text = latest
            lock.unlock()
            onPartial?(latest)
        }
        // The server marks an utterance definite after `end_window_size` of silence. Reported
        // after the words, so the listener judges the newest text.
        let definite = utterances.filter { $0["definite"] as? Bool == true }.count
        if definite > definiteCount, !(latest ?? "").isEmpty {
            definiteCount = definite
            onEndpoint?()
        }
        if frame.final {
            end(failure: nil)
        }
    }

    private func end(failure: String?) {
        lock.lock()
        if failure != nil, self.failure == nil {
            self.failure = failure
        }
        done = true
        let text = self.text
        let waiter = self.waiter
        lock.unlock()
        if let failure {
            helperLog(.warn, failure)
        }
        waiter?.resume(text)
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else {
            return
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else {
            return
        }
        var fed = false
        converter.convert(to: output, error: nil) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard let samples = output.int16ChannelData?[0] else {
            return
        }
        lock.lock()
        pending.append(Data(bytes: samples, count: Int(output.frameLength) * 2))
        var frames: [Data] = []
        while pending.count >= frameBytes {
            frames.append(pending.prefix(frameBytes))
            pending.removeFirst(frameBytes)
        }
        lock.unlock()
        for frame in frames {
            socket?.send(.data(OpenSpeechFrame.make(type: 0x2, flags: 0x0, json: false, payload: frame))) { _ in }
        }
    }

    public func finish() async -> String {
        let (rest, alreadyDone) = takePending()
        if !alreadyDone {
            // The last audio frame carries flag 0x2; the server then sends the final result.
            socket?.send(.data(OpenSpeechFrame.make(type: 0x2, flags: 0x2, json: false, payload: rest))) { _ in }
        }
        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            awaitFinal(Once(continuation))
        }
        socket?.cancel(with: .normalClosure, reason: nil)
        return text
    }

    private func takePending() -> (Data, Bool) {
        lock.lock()
        defer { lock.unlock() }
        let rest = pending
        pending = Data()
        return (rest, done)
    }

    /// Resolves with the final text, or with what there is after 3 s.
    private func awaitFinal(_ once: Once<String>) {
        lock.lock()
        waiter = once
        let finished = done
        let current = text
        lock.unlock()
        if finished {
            once.resume(current)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            once.resume(self?.snapshot ?? current)
        }
    }

    private var snapshot: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }

    public func cancel() {
        lock.lock()
        done = true
        lock.unlock()
        socket?.cancel(with: .normalClosure, reason: nil)
    }
}

// MARK: - Speech output

/// Speaks replies: Doubao (seed-tts) streamed and played as it arrives, else the system
/// voice. One utterance at a time; `stop` cuts it off (the user started talking).
public final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let credentials: DoubaoCredentials?
    private let locale: String
    private let synthesizer = AVSpeechSynthesizer()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var streaming: Task<Void, Never>?
    private var completion: (() -> Void)?
    private var generation = 0
    /// Milliseconds from the request to the first audio of the last utterance.
    public private(set) var lastFirstAudioMs: Int?

    public init(config: Config) {
        credentials = config.voice == "apple" ? nil : DoubaoCredentials.load()
        locale = config.locale
        super.init()
        synthesizer.delegate = self
    }

    public var engineName: String {
        credentials == nil ? "apple" : "doubao"
    }

    public private(set) var isSpeaking = false

    /// Calls `completion` on the main queue when done or stopped.
    public func speak(_ text: String, completion: (() -> Void)? = nil) {
        stop()
        let spoken = Speaker.speakable(text)
        guard !spoken.isEmpty else {
            completion.map { DispatchQueue.main.async(execute: $0) }
            return
        }
        generation += 1
        self.completion = completion
        isSpeaking = true
        if let credentials {
            let generation = self.generation
            streaming = Task { [weak self] in
                let played = await self?.streamDoubao(spoken, credentials: credentials, generation: generation) ?? false
                if !played, let self, self.generation == generation {
                    // Network or quota trouble: still answer out loud.
                    DispatchQueue.main.async { self.speakWithSystemVoice(spoken) }
                }
            }
        } else {
            speakWithSystemVoice(spoken)
        }
    }

    public func stop() {
        generation += 1
        streaming?.cancel()
        streaming = nil
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finish()
    }

    private func finish() {
        isSpeaking = false
        guard let completion else {
            return
        }
        self.completion = nil
        DispatchQueue.main.async(execute: completion)
    }

    /// Replies are read, not recited: no markdown, no file paths, at most two sentences.
    static func speakable(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: #"\*\*|__|`|#+\s"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"(/[^\s/]+){2,}"#, with: "", options: .regularExpression)
        var sentences: [String] = []
        var current = ""
        for character in cleaned {
            current.append(character)
            if "。！？!?\n".contains(character) {
                sentences.append(current)
                current = ""
                if sentences.count == 2 {
                    break
                }
            }
        }
        if sentences.count < 2, !current.isEmpty {
            sentences.append(current)
        }
        return sentences.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func speakWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: locale)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        let started = Date()
        synthesizer.speak(utterance)
        lastFirstAudioMs = Int(Date().timeIntervalSince(started) * 1000)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish()
    }

    /// Streams 24 kHz PCM from the unidirectional endpoint into a player node. Returns false
    /// when nothing could be played.
    private func streamDoubao(_ text: String, credentials: DoubaoCredentials, generation: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "https://openspeech.bytedance.com/api/v3/tts/unidirectional")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.ttsResource, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        if let apiKey = credentials.apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        } else if let appId = credentials.appId, let token = credentials.accessToken {
            request.setValue(appId, forHTTPHeaderField: "X-Api-App-Id")
            request.setValue(token, forHTTPHeaderField: "X-Api-Access-Key")
        }
        let body: [String: Any] = [
            "user": ["uid": "cpu-mac"],
            "req_params": [
                "text": text,
                "speaker": credentials.voice,
                "audio_params": ["format": "pcm", "sample_rate": 24_000]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        let started = Date()
        var scheduled = 0
        do {
            let (lines, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                helperLog(.warn, "Doubao TTS HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return false
            }
            for try await line in lines.lines {
                guard self.generation == generation else {
                    return true
                }
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    continue
                }
                if let code = object["code"] as? Int, code != 0, code != 20_000_000 {
                    helperLog(.warn, "Doubao TTS error \(code): \(object["message"] ?? "")")
                    return scheduled > 0
                }
                guard let base64 = object["data"] as? String, let audio = Data(base64Encoded: base64), audio.count >= 2 else {
                    continue
                }
                let frames = audio.count / 2
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                    continue
                }
                buffer.frameLength = AVAudioFrameCount(frames)
                audio.withUnsafeBytes { raw in
                    let samples = raw.bindMemory(to: Int16.self)
                    let target = buffer.floatChannelData![0]
                    for index in 0..<frames {
                        target[index] = Float(Int16(littleEndian: samples[index])) / 32_768
                    }
                }
                if scheduled == 0 {
                    lastFirstAudioMs = Int(Date().timeIntervalSince(started) * 1000)
                    await MainActor.run { self.startPlayer(format: format) }
                }
                scheduled += 1
                let isLastSoFar = scheduled
                await MainActor.run {
                    self.player?.scheduleBuffer(buffer) { [weak self] in
                        DispatchQueue.main.async {
                            // The last scheduled buffer finished: the utterance is over.
                            if self?.generation == generation, self?.pendingBuffers == isLastSoFar {
                                self?.stop()
                            }
                        }
                    }
                    self.pendingBuffers = isLastSoFar
                }
            }
            return scheduled > 0
        } catch {
            helperLog(.warn, "Doubao TTS failed: \(error)")
            return scheduled > 0
        }
    }

    private var pendingBuffers = 0

    private func startPlayer(format: AVAudioFormat) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            player.play()
            self.engine = engine
            self.player = player
        } catch {
            helperLog(.warn, "audio output failed: \(error)")
        }
    }
}
