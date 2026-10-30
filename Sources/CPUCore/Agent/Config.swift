import Foundation

/// Runtime settings. Read from `~/.config/cpu/config.json` when present, then overridden by
/// `CPU_*` environment variables. Every field is optional in the file.
public struct Config: Codable {
    /// Anthropic Messages-compatible endpoint (without `/v1/messages`).
    public var baseURL = "https://api.deepseek.com/anthropic"
    public var model = "deepseek-flash"
    /// Literal key; prefer `apiKeyEnv` so the key stays out of the file.
    public var apiKey: String?
    /// Environment variable holding the key. GUI launches do not inherit shell variables, so
    /// it is also looked up in the user's login shell.
    public var apiKeyEnv = "DEEPSEEK_API_KEY"
    /// `output_config.effort`; "low" keeps each step fast. nil leaves the provider default.
    public var effort: String? = "low"
    public var maxTokens = 8192
    /// Whether the model accepts images.
    public var vision = true
    /// never | auto (only when the outline is too thin) | always
    public var screenshots = "auto"
    public var maxSteps = 30
    /// Observations kept verbatim in the history; older ones are elided to keep requests small.
    public var keepObservations = 2
    /// "fn fn": double-tap Fn to open/close, hold Fn to talk. Or a chord such as "alt+space".
    public var hotkey = "fn fn"
    /// Speech recognition locale.
    public var locale = "zh-CN"
    /// Speech engine: "auto" (Doubao when DOUBAO_* credentials exist, else Apple on-device),
    /// "doubao", or "apple".
    public var voice = "auto"
    /// Read results aloud: "voice" (when the task was spoken), "always", or "never".
    public var speakReplies = "voice"
    /// Auto-submit after this much silence once something was said (hands-free mode).
    public var silenceSubmitSeconds = 1.1
    /// After a spoken task, keep the microphone open briefly for a follow-up. Off by default:
    /// in a room with other voices (people, videos) it turns their words into requests.
    public var listenAfterResult = false
    /// Apps the agent must not operate (names or bundle ids).
    public var blockedApps = [
        "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.apple.Passwords"
    ]
    /// Answer "打开X" / "open X" without a model call.
    public var fastPaths = true
    /// Network timeout for one model request.
    public var requestTimeout = 90.0
    /// Abandon and retry a model response that produces nothing for this many seconds.
    public var stallTimeout = 20.0

    public init() {}

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/cpu", isDirectory: true)
    }

    public static var fileURL: URL {
        directory.appendingPathComponent("config.json")
    }

    public static func load() -> Config {
        var config = Config()
        if let data = try? Data(contentsOf: fileURL) {
            do {
                config = try JSONDecoder().decode(PartialConfig.self, from: data).apply(to: config)
            } catch {
                helperLog(.warn, "ignoring invalid \(fileURL.path): \(error)")
            }
        }
        let env = ProcessInfo.processInfo.environment
        if let value = env["CPU_BASE_URL"], !value.isEmpty { config.baseURL = value }
        if let value = env["CPU_MODEL"], !value.isEmpty { config.model = value }
        if let value = env["CPU_API_KEY"], !value.isEmpty { config.apiKey = value }
        if let value = env["CPU_EFFORT"] { config.effort = value.isEmpty || value == "default" ? nil : value }
        if let value = env["CPU_SCREENSHOTS"], !value.isEmpty { config.screenshots = value }
        if let value = env["CPU_STALL_TIMEOUT"].flatMap(Double.init) { config.stallTimeout = max(1, value) }
        if let value = env["CPU_VOICE"], !value.isEmpty { config.voice = value }
        return config
    }

    /// Writes a starter file (without secrets) so users can find and edit the settings. Only
    /// the model fields go in: anything written here freezes, so other defaults can still
    /// change with new versions (every field in this struct may be added by hand).
    public static func writeTemplateIfMissing() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = Config()
        let template = """
        {
          "baseURL": "\(defaults.baseURL)",
          "model": "\(defaults.model)",
          "apiKeyEnv": "\(defaults.apiKeyEnv)",
          "hotkey": "\(defaults.hotkey)"
        }

        """
        try? Data(template.utf8).write(to: fileURL)
    }

    public func resolvedAPIKey() -> String? {
        if let apiKey, !apiKey.isEmpty {
            return apiKey
        }
        return ShellEnvironment.value(apiKeyEnv)
    }

    public var screenshotMode: ScreenshotMode {
        let mode = ScreenshotMode(rawValue: screenshots) ?? .auto
        // Text-only models still get OCR from automatic captures, never forced images.
        return !vision && mode == .always ? .auto : mode
    }
}

/// Same fields as `Config`, all optional, so a config file may set only what it changes.
private struct PartialConfig: Decodable {
    var baseURL: String?
    var model: String?
    var apiKey: String?
    var apiKeyEnv: String?
    var effort: String?
    var maxTokens: Int?
    var vision: Bool?
    var screenshots: String?
    var maxSteps: Int?
    var keepObservations: Int?
    var hotkey: String?
    var locale: String?
    var voice: String?
    var speakReplies: String?
    var silenceSubmitSeconds: Double?
    var listenAfterResult: Bool?
    var blockedApps: [String]?
    var fastPaths: Bool?
    var requestTimeout: Double?
    var stallTimeout: Double?

    func apply(to base: Config) -> Config {
        var config = base
        if let baseURL { config.baseURL = baseURL }
        if let model { config.model = model }
        if let apiKey { config.apiKey = apiKey }
        if let apiKeyEnv { config.apiKeyEnv = apiKeyEnv }
        if let effort { config.effort = effort.isEmpty || effort == "default" ? nil : effort }
        if let maxTokens { config.maxTokens = maxTokens }
        if let vision { config.vision = vision }
        if let screenshots { config.screenshots = screenshots }
        if let maxSteps { config.maxSteps = maxSteps }
        if let keepObservations { config.keepObservations = max(1, keepObservations) }
        if let hotkey { config.hotkey = hotkey }
        if let locale { config.locale = locale }
        if let voice { config.voice = voice }
        if let speakReplies { config.speakReplies = speakReplies }
        if let silenceSubmitSeconds { config.silenceSubmitSeconds = silenceSubmitSeconds }
        if let listenAfterResult { config.listenAfterResult = listenAfterResult }
        if let blockedApps { config.blockedApps = blockedApps }
        if let fastPaths { config.fastPaths = fastPaths }
        if let requestTimeout { config.requestTimeout = requestTimeout }
        if let stallTimeout { config.stallTimeout = max(5, stallTimeout) }
        return config
    }
}

/// Environment lookup that falls back to the user's login shell, because apps launched
/// from Finder or `open` do not see variables exported in ~/.zshrc.
public enum ShellEnvironment {
    private static let lock = NSLock()
    private static var cache: [String: String]?

    public static func value(_ name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
            return value
        }
        return loginShellEnvironment()[name]
    }

    /// Runs the login shell once and caches its environment.
    public static func loginShellEnvironment() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cache {
            return cache
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "env -0"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var result: [String: String] = [:]
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            for entry in data.split(separator: 0) {
                guard let line = String(data: Data(entry), encoding: .utf8), let equals = line.firstIndex(of: "=") else {
                    continue
                }
                result[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
        } catch {
            helperLog(.warn, "login shell environment unavailable: \(error)")
        }
        cache = result
        return result
    }
}
