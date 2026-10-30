import Foundation

/// A JSON object as decoded by JSONSerialization; content blocks are kept in this raw form
/// so provider-specific fields (thinking signatures, cache metadata) round-trip unchanged.
public typealias JSONObject = [String: Any]

public struct LLMResponse {
    /// Assistant content blocks exactly as received (thinking, text, tool_use, ...).
    public var content: [JSONObject] = []
    public var stopReason: String?
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var firstTokenMs = 0
    public var totalMs = 0

    public var text: String {
        content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    public var toolUses: [JSONObject] {
        content.filter { $0["type"] as? String == "tool_use" }
    }
}

public enum StreamDelta {
    case thinking(String)
    case text(String)
    case toolStart(String)
    /// The request failed or stalled and is being sent again.
    case retry(String)
}

public struct LLMError: Error, CustomStringConvertible {
    public let description: String
    public let retryable: Bool
}

/// Minimal streaming client for the Anthropic Messages API (and compatible endpoints such
/// as DeepSeek, MiniMax and Kimi). Raw HTTP: there is no official Swift SDK.
public final class AnthropicClient {
    private let config: Config
    private let apiKey: String
    private let session: URLSession

    public init(config: Config, apiKey: String) {
        self.config = config
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = config.requestTimeout
        configuration.timeoutIntervalForResource = config.requestTimeout * 4
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    private var endpoint: URL {
        var base = config.baseURL
        while base.hasSuffix("/") {
            base.removeLast()
        }
        if base.hasSuffix("/v1/messages") {
            return URL(string: base)!
        }
        return URL(string: base.hasSuffix("/v1") ? "\(base)/messages" : "\(base)/v1/messages")!
    }

    private var isFirstParty: Bool {
        endpoint.host?.hasSuffix("anthropic.com") == true
    }

    /// Opens the TLS connection ahead of the first request (saves a round trip or two).
    public func warmUp() {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        session.dataTask(with: request).resume()
    }

    public func send(
        system: String,
        tools: [JSONObject],
        messages: [JSONObject],
        maxTokens: Int? = nil,
        onDelta: @escaping (StreamDelta) -> Void
    ) async throws -> LLMResponse {
        let request = try makeRequest(system: system, tools: tools, messages: messages, maxTokens: maxTokens)
        var attempt = 0
        while true {
            do {
                return try await sendOnce(request, onDelta: onDelta)
            } catch {
                guard attempt < 2, !Interrupts.isStopped, AnthropicClient.isRetryable(error) else {
                    throw error
                }
                attempt += 1
                helperLog(.warn, "model request failed (\(error)); retry \(attempt)")
                onDelta(.retry(String(describing: error)))
                try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            }
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? LLMError {
            return error.retryable
        }
        if let error = error as? URLError {
            let transient: Set<URLError.Code> = [
                .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed
            ]
            return transient.contains(error.code)
        }
        return false
    }

    /// One short answer without tools, e.g. a task title.
    public func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        let response = try await send(
            system: system, tools: [], messages: [["role": "user", "content": [["type": "text", "text": user]]]],
            maxTokens: maxTokens, onDelta: { _ in }
        )
        return response.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeRequest(system: String, tools: [JSONObject], messages: [JSONObject], maxTokens: Int?) throws -> URLRequest {
        var body: JSONObject = [
            "model": config.model,
            "max_tokens": maxTokens ?? config.maxTokens,
            "stream": true,
            // Stable prefix first (tools, system) with a breakpoint, so every step reuses it.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": AnthropicClient.withRollingCacheBreakpoint(messages)
        ]
        if !tools.isEmpty {
            body["tools"] = tools
        }
        if let effort = config.effort {
            body["output_config"] = ["effort": effort]
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(isFirstParty ? "2026-10-21" : "2023-06-01", forHTTPHeaderField: "anthropic-version")
        // Sorted keys keep the serialized prefix identical across steps, so it stays cached.
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Streams one attempt under a watchdog: a response that produces nothing for
    /// `stallTimeout` seconds is abandoned (and retried by `send`) instead of waiting for the
    /// network timeout, and Escape cancels the request immediately.
    private func sendOnce(_ request: URLRequest, onDelta: @escaping (StreamDelta) -> Void) async throws -> LLMResponse {
        let progress = StreamProgress()
        let limit = config.stallTimeout
        return try await withThrowingTaskGroup(of: LLMResponse.self) { group in
            group.addTask {
                try await self.stream(request, progress: progress, onDelta: onDelta)
            }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    if Interrupts.isStopped {
                        throw CancellationError()
                    }
                    let (idle, receiving) = progress.idle()
                    if idle > limit {
                        throw LLMError(
                            description: receiving ? "the response stalled for \(Int(idle))s" : "no response within \(Int(idle))s",
                            retryable: true
                        )
                    }
                }
            }
            defer {
                group.cancelAll()
            }
            guard let result = try await group.next() else {
                throw LLMError(description: "No response", retryable: true)
            }
            return result
        }
    }

    private func stream(_ request: URLRequest, progress: StreamProgress, onDelta: @escaping (StreamDelta) -> Void) async throws -> LLMResponse {
        let started = Date()
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError(description: "No HTTP response", retryable: true)
        }
        if http.statusCode != 200 {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 8000 {
                    break
                }
            }
            let message = String(data: data, encoding: .utf8) ?? ""
            let retryable = http.statusCode == 429 || http.statusCode == 529 || http.statusCode >= 500
            throw LLMError(description: "HTTP \(http.statusCode): \(message.prefix(600))", retryable: retryable)
        }

        var result = LLMResponse()
        var blocks: [Int: JSONObject] = [:]
        var partialJSON: [Int: String] = [:]
        var sawFirstToken = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else {
                continue
            }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
                  let type = event["type"] as? String else {
                continue
            }
            if type != "ping" {
                progress.touch()
            }
            switch type {
            case "message_start":
                if let usage = (event["message"] as? JSONObject)?["usage"] as? JSONObject {
                    result.inputTokens = usage["input_tokens"] as? Int ?? 0
                    result.cacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0
                }
            case "content_block_start":
                guard let index = event["index"] as? Int, let block = event["content_block"] as? JSONObject else {
                    continue
                }
                blocks[index] = block
                if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                    onDelta(.toolStart(name))
                }
            case "content_block_delta":
                guard let index = event["index"] as? Int, let delta = event["delta"] as? JSONObject,
                      var block = blocks[index] else {
                    continue
                }
                if !sawFirstToken {
                    sawFirstToken = true
                    result.firstTokenMs = Int(Date().timeIntervalSince(started) * 1000)
                }
                switch delta["type"] as? String {
                case "text_delta":
                    let text = delta["text"] as? String ?? ""
                    block["text"] = (block["text"] as? String ?? "") + text
                    onDelta(.text(text))
                case "thinking_delta":
                    let text = delta["thinking"] as? String ?? ""
                    block["thinking"] = (block["thinking"] as? String ?? "") + text
                    onDelta(.thinking(text))
                case "signature_delta":
                    block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
                case "input_json_delta":
                    partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                default:
                    break
                }
                blocks[index] = block
            case "content_block_stop":
                guard let index = event["index"] as? Int, var block = blocks[index] else {
                    continue
                }
                if block["type"] as? String == "tool_use" {
                    let raw = partialJSON[index] ?? ""
                    if raw.isEmpty {
                        block["input"] = block["input"] ?? JSONObject()
                    } else if let data = raw.data(using: .utf8),
                              let input = try? JSONSerialization.jsonObject(with: data) as? JSONObject {
                        block["input"] = input
                    } else {
                        // Keep the call so the loop can answer it with an error result.
                        block["input"] = JSONObject()
                        block["_invalid_input"] = raw
                    }
                }
                blocks[index] = block
            case "message_delta":
                if let delta = event["delta"] as? JSONObject, let reason = delta["stop_reason"] as? String {
                    result.stopReason = reason
                }
                if let usage = event["usage"] as? JSONObject {
                    result.outputTokens = usage["output_tokens"] as? Int ?? result.outputTokens
                }
            case "error":
                let error = event["error"] as? JSONObject
                let kind = error?["type"] as? String ?? "error"
                let message = error?["message"] as? String ?? payload
                throw LLMError(description: "\(kind): \(message)", retryable: kind == "overloaded_error" || kind == "api_error")
            default:
                break
            }
        }
        result.content = blocks.keys.sorted().compactMap { blocks[$0] }
        result.totalMs = Int(Date().timeIntervalSince(started) * 1000)
        if result.content.isEmpty {
            throw LLMError(description: "The model returned an empty response.", retryable: true)
        }
        return result
    }

    /// Time since the stream last produced an event (pings excluded).
    private final class StreamProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        private var receiving = false

        func touch() {
            lock.lock()
            last = Date()
            receiving = true
            lock.unlock()
        }

        func idle() -> (TimeInterval, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (Date().timeIntervalSince(last), receiving)
        }
    }

    /// Marks the last block of the last message so the conversation so far is cached and
    /// the next step only pays for what it appends.
    static func withRollingCacheBreakpoint(_ messages: [JSONObject]) -> [JSONObject] {
        guard var last = messages.last, var content = last["content"] as? [JSONObject], var block = content.last else {
            return messages
        }
        block["cache_control"] = ["type": "ephemeral"]
        content[content.count - 1] = block
        last["content"] = content
        var copy = messages
        copy[copy.count - 1] = last
        return copy
    }
}
