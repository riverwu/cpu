import AVFoundation
import Foundation
import Speech

/// Speech-to-text fed with audio buffers in real time (from the microphone, or a file in
/// benchmarks). Implementations: Doubao streaming ASR (cloud), Apple SpeechAnalyzer and Apple
/// SFSpeechRecognizer (both on-device).
public protocol Transcriber: AnyObject {
    var name: String { get }
    /// The whole text so far, on any queue.
    var onPartial: ((String) -> Void)? { get set }
    /// The engine decided the speaker finished a sentence (server-side endpointing), so a
    /// hands-free turn can end without waiting out a local silence timer.
    var onEndpoint: (() -> Void)? { get set }
    func start(format: AVAudioFormat) async throws
    func append(_ buffer: AVAudioPCMBuffer)
    /// Ends the audio and returns the final text.
    func finish() async -> String
    func cancel()
}

public enum Transcribers {
    /// The engine `config.voice` asks for: "doubao", "apple", or "auto" (Doubao when its
    /// credentials exist, else Apple's newest on-device engine).
    public static func make(config: Config) async -> Transcriber {
        let locale = Locale(identifier: config.locale)
        if config.voice != "apple", let credentials = DoubaoCredentials.load() {
            return DoubaoTranscriber(credentials: credentials)
        }
        if #available(macOS 26.0, *), let analyzer = await AppleAnalyzerTranscriber.make(locale: locale) {
            return analyzer
        }
        return AppleDictationTranscriber(locale: locale)
    }
}

/// Resumes a continuation once, from whichever comes first (result or timeout).
final class Once<Value> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

// MARK: - Apple SFSpeechRecognizer

/// The classic recognizer (on-device when the locale allows). Fallback for older systems.
public final class AppleDictationTranscriber: Transcriber {
    public let name = "apple-dictation"
    public var onPartial: ((String) -> Void)?
    public var onEndpoint: (() -> Void)?
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var text = ""
    private var done = false
    private var waiter: Once<String>?

    public init(locale: Locale) {
        recognizer = SFSpeechRecognizer(locale: locale)
        // Results on a background queue: the main thread may be busy (or waiting).
        recognizer?.queue = OperationQueue()
    }

    public func start(format: AVAudioFormat) async throws {
        guard let recognizer, recognizer.isAvailable else {
            throw HelperError("语音识别当前不可用")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else {
                return
            }
            self.lock.lock()
            if let result {
                self.text = result.bestTranscription.formattedString
            }
            let ended = result?.isFinal == true || error != nil
            if ended {
                self.done = true
            }
            let text = self.text
            let waiter = ended ? self.waiter : nil
            self.lock.unlock()
            if result != nil {
                self.onPartial?(text)
            }
            waiter?.resume(text)
        }
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    public func finish() async -> String {
        request?.endAudio()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            awaitFinal(Once(continuation))
        }
    }

    /// Resolves with the final result, or with what there is after 1.2 s.
    private func awaitFinal(_ once: Once<String>) {
        lock.lock()
        let alreadyDone = done
        waiter = once
        let current = text
        lock.unlock()
        if alreadyDone {
            once.resume(current)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) { [weak self] in
            once.resume(self?.currentText ?? current)
        }
    }

    private var currentText: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }

    public func cancel() {
        task?.cancel()
        request = nil
    }
}

// MARK: - Apple SpeechAnalyzer

/// macOS 26's on-device engine: SpeechTranscriber with volatile and fast results.
@available(macOS 26.0, *)
public final class AppleAnalyzerTranscriber: Transcriber {
    public let name = "apple-analyzer"
    public var onPartial: ((String) -> Void)?
    public var onEndpoint: (() -> Void)?
    private let locale: Locale
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var builder: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var collector: Task<Void, Never>?
    private let lock = NSLock()
    private var finals = ""
    private var volatile = ""

    private init(locale: Locale) {
        self.locale = locale
    }

    /// Nil when the locale is unsupported or its model is not installed yet.
    public static func make(locale: Locale) async -> AppleAnalyzerTranscriber? {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return nil
        }
        let probe = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        var status = await AssetInventory.status(forModules: [probe])
        if status == .supported || status == .downloading {
            // Models are reserved per app: this reserves the locale, and starts a download in
            // the background when the system does not have the model yet.
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                Task.detached {
                    try? await request.downloadAndInstall()
                }
            }
            status = await AssetInventory.status(forModules: [probe])
        }
        guard status == .installed else {
            helperLog(.info, "SpeechAnalyzer model for \(supported.identifier) is \(status); using the classic recognizer")
            return nil
        }
        return AppleAnalyzerTranscriber(locale: supported)
    }

    public func start(format: AVAudioFormat) async throws {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: format) else {
            throw HelperError("没有可用的语音格式")
        }
        try await analyzer.prepareToAnalyze(in: target)
        converter = AVAudioConverter(from: format, to: target)
        analyzerFormat = target
        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
        self.builder = builder
        self.transcriber = transcriber
        self.analyzer = analyzer
        collector = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else {
                        return
                    }
                    let text = self.add(String(result.text.characters), final: result.isFinal)
                    self.onPartial?(text)
                }
            } catch {
                helperLog(.warn, "speech analyzer results ended: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Final pieces accumulate; the volatile one is replaced until it becomes final.
    private func add(_ piece: String, final: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        if final {
            finals += piece
            volatile = ""
        } else {
            volatile = piece
        }
        return finals + volatile
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let analyzerFormat else {
            return
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * analyzerFormat.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
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
        builder?.yield(AnalyzerInput(buffer: output))
    }

    public func finish() async -> String {
        builder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await collector?.value
        return transcript
    }

    private var transcript: String {
        lock.lock()
        defer { lock.unlock() }
        return finals + volatile
    }

    public func cancel() {
        builder?.finish()
        let analyzer = self.analyzer
        Task {
            await analyzer?.cancelAndFinishNow()
        }
        collector?.cancel()
    }
}
