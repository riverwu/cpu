import AppKit
import ApplicationServices
import Foundation

/// Runs code the model writes (shell, AppleScript, JXA, Python) in a workspace of its own and
/// reports exactly what happened: exit status, the script's result, errors decoded to a line
/// and a meaning, its output, the files it wrote, changed or removed (with their facts), the
/// windows it opened, and whether it took the front app (which is given back).
///
/// One runner per task. Existing files the code names are backed up before it runs and files
/// it creates are remembered, so 撤销 can put things back. `rm` inside the code moves files
/// outside the workspace to the Trash.
public final class CodeRunner: @unchecked Sendable {
    public enum Language: String, CaseIterable {
        case shell, applescript, jxa, python

        var fileExtension: String {
            switch self {
            case .shell: return "sh"
            case .applescript: return "applescript"
            case .jxa: return "js"
            case .python: return "py"
            }
        }

        var name: String {
            switch self {
            case .shell: return "shell"
            case .applescript: return "AppleScript"
            case .jxa: return "JavaScript for Automation"
            case .python: return "Python"
            }
        }
    }

    public struct Request {
        public var language: Language
        public var code: String
        /// Written into the workspace before the code runs (relative path → text).
        public var files: [String: String] = [:]
        public var timeout: TimeInterval = 60

        public init(language: Language, code: String, files: [String: String] = [:], timeout: TimeInterval = 60) {
            self.language = language
            self.code = code
            self.files = files
            self.timeout = timeout
        }
    }

    /// Where the task's scratch files go; the code runs here.
    public let workspace: URL
    /// The executable that answers `cpu …` inside scripts (`--cpu-helper`), when there is one.
    private let helper: String?
    private let lock = NSLock()
    private var step = 0
    private var prepared = false
    private var jobs: [Int: Job] = [:]
    private var backups: [(original: URL, backup: URL)] = []
    private var created: [URL] = []

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CPU/work", isDirectory: true)
    }

    public init(task: String, helper: String? = Bundle.main.executablePath) {
        workspace = CodeRunner.root.appendingPathComponent(task, isDirectory: true)
        self.helper = helper
    }

    // MARK: - Running

    public struct Result {
        public let report: String
        /// Images the code wrote, for a look at what they show.
        public let images: [URL]
        /// Paths of the files it created and changed outside the workspace (what the user gets).
        public var created: [String] = []
        public var changed: [String] = []
    }

    /// Runs the code and waits for it to finish (or time out, or the user to stop).
    public func run(_ request: Request) throws -> Result {
        let job = try start(request)
        let report = job.finish(timeout: request.timeout)
        return Result(report: report, images: job.images, created: job.created, changed: job.changed)
    }

    /// Starts the code and returns at once; `wait(job:)` reports it when it is done.
    public func startInBackground(_ request: Request) throws -> (id: Int, note: String) {
        let job = try start(request)
        return (job.number, "Started job \(job.number) (\(request.language.name)) in the background. Check it with {\"job\": \(job.number)}; it is stopped after \(Int(request.timeout))s.")
    }

    /// Waits up to `timeout` seconds for a background job; reports it when done, else what it
    /// has printed so far.
    public func wait(job number: Int, timeout: TimeInterval, stop: Bool = false) -> String {
        lock.lock()
        let job = jobs[number]
        lock.unlock()
        guard let job else {
            return "There is no job \(number)."
        }
        if stop {
            job.terminate()
        }
        return job.finish(timeout: stop ? 2 : timeout, keepRunning: !stop)
    }

    /// Stops every job still running (the task ended or the user pressed stop).
    public func stopAll() {
        lock.lock()
        let running = jobs.values.filter(\.isRunning)
        lock.unlock()
        running.forEach { $0.terminate() }
    }

    private func start(_ request: Request) throws -> Job {
        try prepare()
        lock.lock()
        step += 1
        let number = step
        lock.unlock()
        let scratch = workspace.appendingPathComponent(".cpu", isDirectory: true)
        for (name, text) in request.files {
            guard !name.hasPrefix("/"), !name.hasPrefix("~"), !name.split(separator: "/").contains("..") else {
                throw HelperError("files: \"\(name)\" must be a path inside the workspace (relative, without ..).")
            }
            let url = workspace.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let script = scratch.appendingPathComponent("step-\(number).\(request.language.fileExtension)")
        try request.code.write(to: script, atomically: true, encoding: .utf8)
        let arguments = try CodeRunner.command(for: request.language, script: script.path)

        // What the code names: back up the files it may change; watch the folders it may write to.
        let mentioned = CodeRunner.mentionedPaths(in: request.code + "\n" + request.files.values.joined(separator: "\n"))
        var watched = RecentFiles.folders(document: nil)
        var saved: [(original: URL, backup: URL)] = []
        for path in mentioned {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    watched.append(url)
                    continue
                }
                watched.append(url.deletingLastPathComponent())
                let system = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/", "/Applications/", "/private/etc/", "/etc/"].contains { url.path.hasPrefix($0) }
                if !system, !url.path.hasPrefix(workspace.standardizedFileURL.path + "/"), saved.count < 20,
                   let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 200_000_000 {
                    let backup = scratch.appendingPathComponent("backup/\(number)-\(saved.count)-\(url.lastPathComponent)")
                    if (try? FileManager.default.copyItem(at: url, to: backup)) != nil {
                        saved.append((url, backup))
                    }
                }
            } else if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
                watched.append(url.deletingLastPathComponent())
            }
        }
        var unique: [URL] = []
        for folder in watched where !unique.contains(where: { $0.standardizedFileURL == folder.standardizedFileURL }) {
            unique.append(folder)
        }

        let job = Job(
            number: number,
            request: request,
            runner: self,
            output: scratch.appendingPathComponent("step-\(number).out"),
            errors: scratch.appendingPathComponent("step-\(number).err"),
            before: FileSnapshot.take(workspace: workspace, folders: unique),
            folders: unique,
            backups: saved
        )
        try job.launch(arguments: arguments, environment: environment())
        lock.lock()
        jobs[number] = job
        lock.unlock()
        return job
    }

    /// Called by a finished job: what 撤销 needs to know.
    fileprivate func record(backups changed: [(original: URL, backup: URL)], created files: [URL]) {
        lock.lock()
        backups += changed
        created += files
        lock.unlock()
    }

    // MARK: - Undo

    public var hasUndoableFiles: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !backups.isEmpty || !created.isEmpty
    }

    /// Puts changed or removed files back from their backups and moves created files to the
    /// Trash. Returns a sentence for the user, or nil when there was nothing to undo.
    public func undoFiles() -> String? {
        lock.lock()
        let restore = backups
        let remove = created
        backups = []
        created = []
        lock.unlock()
        var restored = 0
        var trashed = 0
        for entry in restore.reversed() {
            try? FileManager.default.removeItem(at: entry.original)
            if (try? FileManager.default.copyItem(at: entry.backup, to: entry.original)) != nil {
                restored += 1
            }
        }
        for file in remove where FileManager.default.fileExists(atPath: file.path) {
            if (try? FileManager.default.trashItem(at: file, resultingItemURL: nil)) != nil {
                trashed += 1
            }
        }
        guard restored + trashed > 0 else {
            return nil
        }
        var parts: [String] = []
        if restored > 0 {
            parts.append("\(restored) 个文件恢复成了运行代码前的样子")
        }
        if trashed > 0 {
            parts.append("代码新建的 \(trashed) 个文件移到了废纸篓")
        }
        return parts.joined(separator: "，")
    }

    // MARK: - Environment

    private func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !prepared else {
            return
        }
        CodeRunner.prune(olderThanDays: 7)
        let scratch = workspace.appendingPathComponent(".cpu", isDirectory: true)
        for name in ["bin", "tmp", "backup"] {
            try FileManager.default.createDirectory(at: scratch.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let bin = scratch.appendingPathComponent("bin")
        try CodeRunner.trashingRemove.write(to: bin.appendingPathComponent("rm"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("rm").path)
        if let helper {
            let shim = "#!/bin/zsh -f\nexec \(CodeRunner.quoted(helper)) --cpu-helper \"$@\"\n"
            try shim.write(to: bin.appendingPathComponent("cpu"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("cpu").path)
        }
        prepared = true
    }

    /// A fixed, predictable environment: no shell startup files, Homebrew on the PATH, UTF-8,
    /// and none of CPU's own variables (API keys stay out of scripts).
    private func environment() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let scratch = workspace.appendingPathComponent(".cpu")
        return [
            "PATH": ([scratch.appendingPathComponent("bin").path] + CodeRunner.searchPath).joined(separator: ":"),
            "HOME": home,
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "SHELL": "/bin/zsh",
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8",
            "PYTHONIOENCODING": "utf-8",
            "PYTHONDONTWRITEBYTECODE": "1",
            "TERM": "dumb",
            "TMPDIR": scratch.appendingPathComponent("tmp").path + "/",
            "CPU_WORK": workspace.path
        ]
    }

    static let searchPath = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    static func command(for language: Language, script: String) throws -> [String] {
        switch language {
        case .shell:
            return ["/bin/zsh", "-f", script]
        case .applescript:
            return ["/usr/bin/osascript", script]
        case .jxa:
            return ["/usr/bin/osascript", "-l", "JavaScript", script]
        case .python:
            guard let python = pythonPath else {
                throw HelperError("Python is not installed on this Mac. Use shell, AppleScript or JXA (installing Python needs the user's OK).")
            }
            return [python, "-u", script]
        }
    }

    /// A real python3: Homebrew's, or the one that comes with the Command Line Tools (the
    /// /usr/bin stub would offer to install them instead).
    static let pythonPath: String? = {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/Library/Developer/CommandLineTools/usr/bin/python3", "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// `rm` inside scripts: files outside the workspace go to the Trash; scratch files in the
    /// workspace and temporary folders are removed for real.
    private static let trashingRemove = #"""
    #!/bin/zsh -f
    # CPU's rm: files outside the workspace go to the Trash, so they can be brought back.
    work=${CPU_WORK:A}
    force=0
    files=()
    for arg in "$@"; do
      case $arg in
        --) ;;
        -*) [[ $arg == *f* ]] && force=1 ;;
        *) files+=("$arg") ;;
      esac
    done
    code=0
    for f in $files; do
      if [[ ! -e $f && ! -L $f ]]; then
        (( force )) || { print -u2 "rm: $f: No such file or directory"; code=1 }
        continue
      fi
      full=${f:A}
      if [[ $full == $work/* || $full == /private/tmp/* || $full == /tmp/* || $full == /private/var/folders/* ]]; then
        /bin/rm -rf -- "$f" || code=1
      elif [[ -x /usr/bin/trash ]]; then
        /usr/bin/trash "$f" >/dev/null || code=1
      else
        mv -- "$f" ~/.Trash/ || code=1
      fi
    done
    exit $code
    """#

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Paths the code names: quoted strings and bare words that start with / or ~.
    static func mentionedPaths(in code: String) -> [String] {
        let patterns = [#"["']((?:~|/)[^"'\n]{1,400})["']"#, #"(?:^|[\s=(])((?:~|/(?:Users|Volumes|private|tmp))/[^\s"';|&<>()]{1,400})"#]
        var found: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
                continue
            }
            for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let range = Range(match.range(at: 1), in: code) else {
                    continue
                }
                var path = String(code[range]).trimmingCharacters(in: .whitespaces)
                path = (path as NSString).expandingTildeInPath
                if path.count > 1, !found.contains(path), !path.contains("$"), !path.contains("*") {
                    found.append(path)
                }
            }
        }
        return Array(found.prefix(60))
    }

    private static func prune(olderThanDays days: Double) {
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if modified < cutoff {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    // MARK: - What this Mac has

    /// One line for the model: interpreters, notable command-line tools, Chinese voices.
    /// Takes a few hundred milliseconds; compute it off the main thread once.
    public static func environmentFacts() -> String {
        let tools = ["ffmpeg", "ffprobe", "pandoc", "magick", "jq", "yt-dlp", "pdftotext", "node", "git", "rg", "sqlite3"]
        let present = tools.filter { tool in searchPath.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(tool)") } }
        var parts = ["macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)"]
        if let python = pythonPath {
            let version = capture([python, "--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(version.isEmpty ? "python3" : version.lowercased())
        } else {
            parts.append("no Python")
        }
        if !present.isEmpty {
            parts.append(present.joined(separator: ", "))
        }
        var builtIn = "built in: say, afconvert, sips, textutil, mdls, qlmanage, pbpaste, curl, trash"
        // "Tingting (中文（中国大陆）) zh_CN    # 你好！我叫婷婷。": the -v name is before the locale.
        var voices: [String] = []
        for line in capture(["/usr/bin/say", "-v", "?"]).split(separator: "\n") where line.contains(" zh_CN ") {
            guard let range = line.range(of: " zh_CN ") else {
                continue
            }
            let name = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let short = name.hasPrefix("Tingting") ? "Tingting" : name
            if !voices.contains(short) {
                voices.append(short)
            }
        }
        voices.sort { ($0 == "Tingting" ? 0 : 1) < ($1 == "Tingting" ? 0 : 1) }
        if !voices.isEmpty {
            builtIn += " (say's Mandarin voices, names for -v: \(voices.prefix(4).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: ", ")))"
        }
        parts.append(builtIn)
        return parts.joined(separator: "; ")
    }

    private static func capture(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - One run

private final class Job: @unchecked Sendable {
    let number: Int
    let request: CodeRunner.Request
    weak var runner: CodeRunner?
    let output: URL
    let errors: URL
    let before: FileSnapshot
    let folders: [URL]
    let backups: [(original: URL, backup: URL)]
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var started = Date()
    private var status: Int32?
    private var stopped = false
    private var timedOut = false
    private var report: String?
    private var windowsBefore: [CGWindowID: String] = [:]
    private var frontBefore: pid_t?
    /// Images created or changed, newest first.
    private(set) var images: [URL] = []
    /// Files created and changed outside the workspace, found when the run is described.
    private(set) var created: [String] = []
    private(set) var changed: [String] = []

    init(number: Int, request: CodeRunner.Request, runner: CodeRunner, output: URL, errors: URL, before: FileSnapshot, folders: [URL], backups: [(original: URL, backup: URL)]) {
        self.number = number
        self.request = request
        self.runner = runner
        self.output = output
        self.errors = errors
        self.before = before
        self.folders = folders
        self.backups = backups
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return status == nil && pid > 0
    }

    func launch(arguments: [String], environment: [String: String]) throws {
        windowsBefore = Job.windows()
        frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group, so a timeout or stop ends everything it started; and none of
        // CPU's open files.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_addopen(&actions, 2, errors.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if let workspace = runner?.workspace.path {
            posix_spawn_file_actions_addchdir_np(&actions, workspace)
        }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        started = Date()
        let result = posix_spawn(&child, arguments[0], &actions, &attributes, argv, envp)
        guard result == 0 else {
            throw HelperError("Could not start \(arguments[0]): \(String(cString: strerror(result))).")
        }
        lock.lock()
        pid = child
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let target = pid
        let running = status == nil
        if running {
            stopped = true
        }
        lock.unlock()
        guard running, target > 0 else {
            return
        }
        kill(-target, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            if self?.isRunning == true {
                kill(-target, SIGKILL)
            }
        }
    }

    /// Waits for the process (up to `timeout`, or until the user stops the task) and reports
    /// it. With `keepRunning`, a job still running after `timeout` is reported as running.
    func finish(timeout: TimeInterval, keepRunning: Bool = false) -> String {
        lock.lock()
        if let report {
            lock.unlock()
            return report
        }
        let target = pid
        lock.unlock()
        let deadline = Date().addingTimeInterval(timeout)
        let hardDeadline = started.addingTimeInterval(request.timeout)
        while true {
            var raw: Int32 = 0
            let done = waitpid(target, &raw, WNOHANG)
            if done == target || done == -1 {
                lock.lock()
                status = done == -1 ? -1 : raw
                lock.unlock()
                break
            }
            if Interrupts.isStopped {
                terminate()
            } else if Date() >= hardDeadline {
                lock.lock()
                timedOut = true
                lock.unlock()
                terminate()
            } else if keepRunning, Date() >= deadline {
                return progress()
            }
            usleep(50_000)
        }
        let text = describe()
        lock.lock()
        report = text
        lock.unlock()
        return text
    }

    private func progress() -> String {
        let elapsed = Int(Date().timeIntervalSince(started))
        let printed = Job.excerpt(Job.read(output), limit: 2000)
        return "Job \(number) is still running (\(elapsed)s so far)." + (printed.isEmpty ? "" : " Output so far:\n\(printed)")
    }

    // MARK: Report

    private func describe() -> String {
        let elapsed = Date().timeIntervalSince(started)
        let out = Job.read(output)
        let err = Job.read(errors)
        var lines: [String] = []
        let seconds = String(format: "%.1fs", elapsed)
        lock.lock()
        let raw = status ?? -1
        let wasStopped = stopped && !timedOut
        let wasTimedOut = timedOut
        lock.unlock()
        let exited = raw != -1 && (raw & 0x7f) == 0
        let exitCode = exited ? Int((raw >> 8) & 0xff) : nil
        let signal = raw != -1 && !exited ? Int(raw & 0x7f) : nil
        if wasTimedOut {
            lines.append("Stopped after \(seconds): it ran longer than its \(String(format: "%g", request.timeout))s limit (pass a larger timeout, or background: true).")
        } else if wasStopped {
            lines.append("Stopped after \(seconds) because the task was stopped.")
        } else if let exitCode {
            lines.append("Ran \(request.language.name) in \(seconds): exit \(exitCode)\(exitCode == 0 ? " (success)" : " (failed)").")
        } else if let signal {
            lines.append("Ran \(request.language.name) in \(seconds): killed by signal \(signal).")
        } else {
            lines.append("Ran \(request.language.name) in \(seconds); its exit status is unknown.")
        }
        let scripted = request.language == .applescript || request.language == .jxa
        if !out.isEmpty {
            lines.append((scripted && exitCode == 0 ? "Result:" : "Output:") + "\n" + Job.excerpt(out, limit: 8000, file: shown(output)))
        } else if exitCode == 0 {
            lines.append("It printed nothing.")
        }
        if !err.isEmpty {
            lines.append("Errors:\n" + Job.excerpt(err, limit: 4000, file: shown(errors)))
        }
        lines += explain(errors: err, exitCode: exitCode)
        lines += fileChanges()
        lines += windowChanges()
        return lines.joined(separator: "\n")
    }

    /// What an error means and what to do next, for the errors seen most often.
    private func explain(errors text: String, exitCode: Int?) -> [String] {
        var notes: [String] = []
        if request.language == .applescript || request.language == .jxa {
            let regex = try? NSRegularExpression(pattern: #"^.*?:(\d+):(\d+): (?:execution|script) error: (.*?)(?: \((-?\d+)\))?$"#, options: [.anchorsMatchLines])
            for match in regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(2) ?? [] {
                func group(_ index: Int) -> String? {
                    Range(match.range(at: index), in: text).map { String(text[$0]) }
                }
                var note = "Error"
                if let offset = group(1).flatMap(Int.init) {
                    let (number, source) = Job.line(at: offset, in: request.code)
                    note += " at line \(number) (\(compactText(source, limit: 100)))"
                }
                if let code = group(4).flatMap(Int.init) {
                    note += " \(code)"
                    if let meaning = Job.appleScriptErrors[code] {
                        note += ": \(meaning)"
                    }
                } else if let message = group(3) {
                    note += ": \(message)"
                }
                notes.append(note)
            }
            if text.contains("JavaScript"), text.contains("Apple") {
                notes.append("The browser does not allow scripts from CPU yet. Ask the user (hand_over) to turn it on once: Chrome: 显示 ▸ 开发者 ▸ 允许 Apple 事件中的 JavaScript; Safari: 开发 ▸ 允许来自 Apple 事件的 JavaScript (设置 ▸ 高级 ▸ 显示网页开发者功能 first).")
            }
            if text.contains("Not authorized to send Apple events"), !notes.contains(where: { $0.contains("-1743") }) {
                notes.append(Job.appleScriptErrors[-1743]!)
            }
        }
        if exitCode == 127 || text.contains("command not found") {
            notes.append("A command was not found. What this Mac has: \(CodeRunner.environmentFacts())")
        } else if exitCode == 126 {
            notes.append("A command could not be executed (not executable, or permission denied).")
        }
        if let module = text.range(of: #"No module named '([^']+)'"#, options: .regularExpression).map({ String(text[$0]) }) {
            notes.append("\(module): it is not installed. Use the standard library or the tools this Mac has; installing a package needs the user's OK.")
        }
        return notes
    }

    static let appleScriptErrors: [Int: String] = [
        -1743: "CPU is not allowed to control this app yet. Ask the user (hand_over) to allow it: System Settings → Privacy & Security → Automation → CPU, turn on the app; or click OK in the prompt macOS shows.",
        -1728: "the object does not exist (a wrong name, index or path, or the app has no such element).",
        -1719: "an index is out of range.",
        -1708: "the app does not understand this command (check its scripting dictionary).",
        -1700: "a value could not be converted to the needed type.",
        -1712: "the app did not answer in time (busy, or showing a dialog).",
        -10000: "the app could not carry out the command.",
        -10004: "the app does not allow this from a script (privilege violation).",
        -10006: "the property cannot be set.",
        -10010: "the command cannot handle this kind of object (use a different object class, or the app's own command).",
        -2753: "a variable is used before it was set.",
        -2740: "syntax error.",
        -2741: "syntax error: something is missing or out of place.",
        -600: "the app is not running.",
        -609: "the app quit or the connection broke.",
        -128: "cancelled (by the user or a dialog).",
        -43: "file or folder not found.",
        -48: "a file with that name already exists.",
        -54: "permission denied, or the file is locked.",
        -61: "no permission to write here."
    ]

    private static func line(at offset: Int, in code: String) -> (Int, String) {
        let text = code as NSString
        let clamped = max(0, min(offset, text.length))
        let before = text.substring(to: clamped)
        let number = before.components(separatedBy: "\n").count
        let lines = code.components(separatedBy: "\n")
        return (number, number - 1 < lines.count ? lines[number - 1].trimmingCharacters(in: .whitespaces) : "")
    }

    private func fileChanges() -> [String] {
        guard let runner else {
            return []
        }
        let after = FileSnapshot.take(workspace: runner.workspace, folders: folders)
        let change = before.changes(to: after)
        var lines: [String] = []
        let workspacePath = runner.workspace.path
        created = change.created.filter { !$0.hasPrefix(workspacePath + "/") }
        changed = change.modified.filter { !$0.hasPrefix(workspacePath + "/") }
        func shown(_ path: String) -> String {
            path.hasPrefix(workspacePath + "/") ? "workspace/" + path.dropFirst(workspacePath.count + 1) : path
        }
        func described(_ path: String) -> String {
            let url = URL(fileURLWithPath: path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return RecentFiles.describe(url, size: size).replacingOccurrences(of: path, with: shown(path)) + Job.textFacts(url)
        }
        if !change.created.isEmpty {
            lines.append("Files created: " + change.created.prefix(12).map(described).joined(separator: "; ") + (change.created.count > 12 ? "; … \(change.created.count - 12) more" : ""))
        }
        if !change.modified.isEmpty {
            let backedUp = Set(backups.map(\.original.path))
            lines.append("Files changed: " + change.modified.prefix(12).map { described($0) + (backedUp.contains($0) ? " [backup kept; 撤销 restores it]" : "") }.joined(separator: "; "))
        }
        if !change.deleted.isEmpty {
            let backedUp = Set(backups.map(\.original.path))
            lines.append("Files removed (rm moves them to the Trash): " + change.deleted.prefix(12).map { shown($0) + (backedUp.contains($0) ? " [backup kept; 撤销 restores it]" : "") }.joined(separator: "; "))
        }
        if change.created.isEmpty && change.modified.isEmpty && change.deleted.isEmpty {
            lines.append("No files changed in the workspace, 下载, 桌面, 文稿 or the folders the code names.")
        }
        // For 撤销: backups of files that did change, and files created outside the workspace.
        let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
        images = (change.created + change.modified).map { URL(fileURLWithPath: $0) }.filter { imageTypes.contains($0.pathExtension.lowercased()) }
        let touched = Set(change.modified + change.deleted)
        runner.record(
            backups: backups.filter { touched.contains($0.original.path) },
            created: change.created.filter { !$0.hasPrefix(workspacePath + "/") }.map { URL(fileURLWithPath: $0) }
        )
        return lines
    }

    /// Lines and the first line of a text file, so the model sees it is the right content.
    private static func textFacts(_ url: URL) -> String {
        guard ["txt", "md", "csv", "json", "html", "srt", "log", "xml", "yaml", "yml", "tsv"].contains(url.pathExtension.lowercased()),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0)
        let first = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { compactText(String($0), limit: 60) } ?? ""
        return " [\(lines.count) line\(lines.count == 1 ? "" : "s"), \(text.count) characters\(first.isEmpty ? "" : ", starts \"\(first)\"")]"
    }

    private func windowChanges() -> [String] {
        var lines: [String] = []
        let now = Job.windows()
        let opened = now.filter { windowsBefore[$0.key] == nil }.map(\.value)
        let closed = windowsBefore.filter { now[$0.key] == nil }.map(\.value)
        if !opened.isEmpty {
            lines.append("Windows opened: " + opened.prefix(6).joined(separator: "; "))
        }
        if !closed.isEmpty {
            lines.append("Windows closed: " + closed.prefix(6).joined(separator: "; "))
        }
        // A script that activates an app takes the user's front window: give it back.
        let front = NSWorkspace.shared.frontmostApplication
        if let before = frontBefore, let front, front.processIdentifier != before, before != ProcessInfo.processInfo.processIdentifier,
           NSRunningApplication(processIdentifier: before)?.isTerminated == false {
            AX.set(AXUIElementCreateApplication(before), kAXFrontmostAttribute, kCFBooleanTrue)
            let name = NSRunningApplication(processIdentifier: before)?.localizedName ?? "the user's app"
            lines.append("The code brought \(front.localizedName ?? "an app") to the front; CPU gave the front back to \(name). Do not activate apps in code.")
        }
        return lines
    }

    private static func windows() -> [CGWindowID: String] {
        var map: [CGWindowID: String] = [:]
        for window in WindowCatalog.list(includeOffscreen: false) {
            map[window.id] = window.title.isEmpty ? "\(window.app) (\(window.id))" : "\(window.app) \"\(compactText(window.title, limit: 50))\" (\(window.id))"
        }
        return map
    }

    private static func read(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The whole text when short; else its start and end (where errors and results show),
    /// and how to read the rest, as every long text result says it.
    static func excerpt(_ text: String, limit: Int, file: String? = nil) -> String {
        guard text.count > limit else {
            return text
        }
        let half = limit / 2
        let omitted = text.count - 2 * half
        let rest = file.map { "; the whole of it is \($0): read_file it from a line, or search it with code (grep -n)" } ?? ""
        return String(text.prefix(half)) + "\n[… \(omitted) of \(text.count) characters left out here\(rest) …]\n" + String(text.suffix(half))
    }

    /// A file of this run as the model names it: relative to the workspace.
    private func shown(_ file: URL) -> String {
        guard let workspace = runner?.workspace.standardizedFileURL.path, file.standardizedFileURL.path.hasPrefix(workspace + "/") else {
            return file.path
        }
        return String(file.standardizedFileURL.path.dropFirst(workspace.count + 1))
    }
}

/// Sizes and modification dates of the files where code output lands: the whole workspace,
/// and the top level of 下载, 桌面, 文稿 and the folders the code names.
struct FileSnapshot {
    var entries: [String: (size: Int, date: Date)] = [:]

    static func take(workspace: URL, folders: [URL]) -> FileSnapshot {
        var snapshot = FileSnapshot()
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        func add(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                return
            }
            snapshot.entries[url.standardizedFileURL.path] = (values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        let scratch = workspace.appendingPathComponent(".cpu").standardizedFileURL.path
        if let walker = FileManager.default.enumerator(at: workspace, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            var count = 0
            for case let url as URL in walker where count < 3000 {
                if url.standardizedFileURL.path.hasPrefix(scratch) {
                    continue
                }
                add(url)
                count += 1
            }
        }
        for folder in folders where !folder.standardizedFileURL.path.hasPrefix(workspace.standardizedFileURL.path) {
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? [] {
                add(url)
            }
        }
        return snapshot
    }

    func changes(to after: FileSnapshot) -> (created: [String], modified: [String], deleted: [String]) {
        var created: [String] = []
        var modified: [String] = []
        for (path, now) in after.entries {
            if let old = entries[path] {
                if old.size != now.size || old.date != now.date {
                    modified.append(path)
                }
            } else {
                created.append(path)
            }
        }
        let deleted = entries.keys.filter { after.entries[$0] == nil }
        let newest: (String, String) -> Bool = { (after.entries[$0]?.date ?? .distantPast) > (after.entries[$1]?.date ?? .distantPast) }
        return (created.sorted(by: newest), modified.sorted(by: newest), deleted.sorted())
    }
}

/// A small JPEG of an image the code produced, so the model can see it came out right. A
/// long image is shown from its top, at a readable width.
public enum ImagePreview {
    public static func jpeg(_ url: URL, maxSide: CGFloat = 1000) -> (data: Data, note: String)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        var region = CGRect(x: 0, y: 0, width: width, height: height)
        var note = "\(url.lastPathComponent), \(image.width)x\(image.height) px"
        if height > width * 1.6 {
            region.size.height = width * 1.6
            note += ", its top \(Int(region.height / height * 100))%"
        }
        guard let cropped = image.cropping(to: region) else {
            return nil
        }
        let scale = min(1, maxSide / max(region.width, region.height))
        let size = CGSize(width: Int(region.width * scale), height: Int(region.height * scale))
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        context.setFillColor(.white)
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(origin: .zero, size: size))
        guard let small = context.makeImage() else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return (data as Data, note)
    }
}
