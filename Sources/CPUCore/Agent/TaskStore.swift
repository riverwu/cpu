import Foundation

/// A finished task, for the recent list and "再做一次".
public struct TaskRecord: Codable {
    public let request: String
    public var title: String
    public var result: String
    public var succeeded: Bool
    public var date: Date

    public init(request: String, title: String, result: String, succeeded: Bool, date: Date) {
        self.request = request
        self.title = title
        self.result = result
        self.succeeded = succeeded
        self.date = date
    }
}

/// A name the user gave to a request ("日报" → the full instruction).
public struct Shortcut: Codable {
    public let name: String
    public let request: String
}

/// Something the user taught by demonstration: what it is for, how to do it (with
/// placeholders for what changes), and the recorded steps.
public struct Skill: Codable {
    public let name: String
    public var summary: String
    public var procedure: String
    public var steps: [String]
    public var createdAt: Date
}

/// Task history, shortcuts and recorded trajectories, in ~/Library/Application Support/CPU.
/// Small JSON files, read once and rewritten on change; safe to use from any thread.
public final class TaskStore {
    public static let shared = TaskStore()

    private let lock = NSLock()
    private let directory: URL
    private var historyItems: [TaskRecord]
    private var shortcutItems: [Shortcut]
    private var skillItems: [Skill]
    /// Normalized request → recorded procedure (see `Agent` for the format).
    private var trajectoryItems: [String: JSONObject]

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CPU")) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        historyItems = (try? decoder.decode([TaskRecord].self, from: Data(contentsOf: directory.appendingPathComponent("history.json")))) ?? []
        shortcutItems = (try? decoder.decode([Shortcut].self, from: Data(contentsOf: directory.appendingPathComponent("shortcuts.json")))) ?? []
        skillItems = (try? decoder.decode([Skill].self, from: Data(contentsOf: directory.appendingPathComponent("skills.json")))) ?? []
        trajectoryItems = (try? Data(contentsOf: directory.appendingPathComponent("trajectories.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: JSONObject] } ?? [:]
    }

    // MARK: - History

    /// Newest first.
    public var history: [TaskRecord] {
        lock.lock()
        defer { lock.unlock() }
        return historyItems
    }

    public func record(_ record: TaskRecord) {
        lock.lock()
        historyItems.removeAll { TaskStore.normalize($0.request) == TaskStore.normalize(record.request) }
        historyItems.insert(record, at: 0)
        historyItems = Array(historyItems.prefix(50))
        let items = historyItems
        lock.unlock()
        write(items, to: "history.json")
    }

    // MARK: - Shortcuts

    public var shortcuts: [Shortcut] {
        lock.lock()
        defer { lock.unlock() }
        return shortcutItems
    }

    public func saveShortcut(name: String, request: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !request.isEmpty else {
            return
        }
        lock.lock()
        shortcutItems.removeAll { TaskStore.normalize($0.name) == TaskStore.normalize(name) }
        shortcutItems.insert(Shortcut(name: name, request: request), at: 0)
        let items = shortcutItems
        lock.unlock()
        write(items, to: "shortcuts.json")
    }

    public func removeShortcut(name: String) {
        lock.lock()
        shortcutItems.removeAll { $0.name == name }
        let items = shortcutItems
        lock.unlock()
        write(items, to: "shortcuts.json")
    }

    /// What the user's words stand for: a shortcut name expands to its request, and "再做一次"
    /// to the last task. Nil when the words are a request of their own.
    public func expand(_ words: String) -> String? {
        let key = TaskStore.normalize(words)
        lock.lock()
        defer { lock.unlock() }
        if let shortcut = shortcutItems.first(where: { TaskStore.normalize($0.name) == key }) {
            return shortcut.request
        }
        if TaskStore.repeatPhrases.contains(key) {
            return historyItems.first?.request
        }
        return nil
    }

    private static let repeatPhrases: Set<String> = [
        "再做一次", "再来一次", "再来一遍", "再做一遍", "重复上次", "重复上一次", "和上次一样", "像上次那样", "照上次做",
        "again", "doitagain", "repeat"
    ]

    // MARK: - Skills

    public var skills: [Skill] {
        lock.lock()
        defer { lock.unlock() }
        return skillItems
    }

    public func saveSkill(_ skill: Skill) {
        lock.lock()
        skillItems.removeAll { TaskStore.normalize($0.name) == TaskStore.normalize(skill.name) }
        skillItems.insert(skill, at: 0)
        let items = skillItems
        lock.unlock()
        write(items, to: "skills.json")
    }

    public func removeSkill(name: String) {
        lock.lock()
        skillItems.removeAll { $0.name == name }
        let items = skillItems
        lock.unlock()
        write(items, to: "skills.json")
        removeTrajectory(for: name)
    }

    // MARK: - Trajectories

    func trajectory(for request: String) -> JSONObject? {
        lock.lock()
        defer { lock.unlock() }
        return trajectoryItems[TaskStore.normalize(request)]
    }

    func saveTrajectory(_ trajectory: JSONObject, for request: String) {
        lock.lock()
        trajectoryItems[TaskStore.normalize(request)] = trajectory
        let items = trajectoryItems
        lock.unlock()
        writeJSON(items, to: "trajectories.json")
    }

    func removeTrajectory(for request: String) {
        lock.lock()
        trajectoryItems.removeValue(forKey: TaskStore.normalize(request))
        let items = trajectoryItems
        lock.unlock()
        writeJSON(items, to: "trajectories.json")
    }

    // MARK: - Files

    /// Case, spaces and punctuation do not make two requests different.
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && !CharacterSet.punctuationCharacters.contains(scalar)
        })
    }

    private func write<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? encoder.encode(value) {
            try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }

    private func writeJSON(_ value: Any, to name: String) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }
}
