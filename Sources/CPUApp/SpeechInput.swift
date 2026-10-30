import AVFoundation
import CPUCore
import Foundation
import Speech

/// Microphone → transcriber (Doubao streaming by default, Apple on-device as fallback).
/// The microphone starts at once and buffers while the engine connects, so the first words
/// are not lost. Callbacks arrive on the main queue.
final class SpeechInput {
    var onPartial: (String) -> Void = { _ in }
    var onLevel: (Float) -> Void = { _ in }
    /// The engine heard the end of a sentence (hands-free mode can submit now).
    var onEndpoint: () -> Void = {}
    /// Final transcript (possibly empty) once recognition stops.
    var onFinal: (String) -> Void = { _ in }
    /// The microphone opened or closed (called on main).
    var onRunningChanged: (Bool) -> Void = { _ in }

    private let config: Config
    private let audio = AVAudioEngine()
    private var transcriber: Transcriber?
    private var queued: [AVAudioPCMBuffer] = []
    private let lock = NSLock()
    private var session = 0
    private(set) var isRunning = false
    /// Name of the engine in use, for diagnostics.
    private(set) var engineName = ""

    init(config: Config) {
        self.config = config
    }

    /// Microphone access, plus speech recognition when Apple's engine may be used. Calls back
    /// on main with an error message or nil.
    func authorize(_ completion: @escaping (String?) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard granted else {
                DispatchQueue.main.async {
                    completion("未获得麦克风权限：请在 系统设置 → 隐私与安全性 → 麦克风 中允许 CPU。")
                }
                return
            }
            guard self.config.voice == "apple" || DoubaoCredentials.load() == nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    completion(status == .authorized ? nil : "未获得语音识别权限：请在 系统设置 → 隐私与安全性 → 语音识别 中允许 CPU。")
                }
            }
        }
    }

    func start() throws {
        stopAudio()
        session += 1
        let current = session
        lock.lock()
        queued = []
        transcriber = nil
        lock.unlock()

        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else {
                return
            }
            self.reportLevel(buffer)
            self.lock.lock()
            if let transcriber = self.transcriber {
                self.lock.unlock()
                transcriber.append(buffer)
            } else {
                // Still connecting: keep the audio (copied, the tap reuses its buffer).
                if let copy = SpeechInput.copy(buffer) {
                    self.queued.append(copy)
                }
                self.lock.unlock()
            }
        }
        audio.prepare()
        try audio.start()
        isRunning = true
        onRunningChanged(true)

        Task { [weak self] in
            guard let self else {
                return
            }
            let engine = await self.connect(format: format)
            guard current == self.session, let engine else {
                engine?.cancel()
                return
            }
            self.engineName = engine.name
            engine.onPartial = { [weak self] text in
                DispatchQueue.main.async {
                    if self?.session == current {
                        self?.onPartial(text)
                    }
                }
            }
            engine.onEndpoint = { [weak self] in
                DispatchQueue.main.async {
                    if self?.session == current {
                        self?.onEndpoint()
                    }
                }
            }
            self.flushQueue(into: engine)
        }
    }

    /// The configured engine, falling back to Apple's on-device recognizer when the cloud
    /// engine cannot connect.
    private func connect(format: AVAudioFormat) async -> Transcriber? {
        let preferred = await Transcribers.make(config: config)
        do {
            try await preferred.start(format: format)
            return preferred
        } catch {
            helperLog(.warn, "\(preferred.name) unavailable (\(error)); using Apple on-device recognition")
        }
        let fallback = AppleDictationTranscriber(locale: Locale(identifier: config.locale))
        do {
            try await fallback.start(format: format)
            return fallback
        } catch {
            DispatchQueue.main.async {
                self.onFinal("")
            }
            return nil
        }
    }

    private func flushQueue(into engine: Transcriber) {
        lock.lock()
        let backlog = queued
        queued = []
        transcriber = engine
        lock.unlock()
        for buffer in backlog {
            engine.append(buffer)
        }
    }

    /// Stops listening and delivers the final transcript.
    func stop() {
        guard isRunning else {
            return
        }
        stopAudio()
        let current = session
        lock.lock()
        let engine = transcriber
        lock.unlock()
        Task { [weak self] in
            let text = await engine?.finish() ?? ""
            DispatchQueue.main.async {
                guard let self, self.session == current else {
                    return
                }
                self.session += 1
                self.onFinal(text)
            }
        }
    }

    /// Stops without delivering a transcript.
    func cancel() {
        session += 1
        stopAudio()
        lock.lock()
        let engine = transcriber
        transcriber = nil
        queued = []
        lock.unlock()
        engine?.cancel()
    }

    private func stopAudio() {
        if audio.isRunning {
            audio.stop()
        }
        audio.inputNode.removeTap(onBus: 0)
        if isRunning {
            isRunning = false
            onRunningChanged(false)
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if let source = buffer.floatChannelData, let target = copy.floatChannelData {
            for channel in 0..<channels {
                target[channel].update(from: source[channel], count: Int(buffer.frameLength))
            }
        } else if let source = buffer.int16ChannelData, let target = copy.int16ChannelData {
            for channel in 0..<channels {
                target[channel].update(from: source[channel], count: Int(buffer.frameLength))
            }
        }
        return copy
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            return
        }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            sum += channel[index] * channel[index]
        }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let level = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40))
        DispatchQueue.main.async { [weak self] in
            self?.onLevel(level)
        }
    }
}
