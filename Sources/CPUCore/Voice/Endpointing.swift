import Foundation

/// When hands-free speech is finished. People pause to think in the middle of a request
/// ("这里还提到了这个现金流的……还有"), so a short silence ends only words that read as
/// complete; words that trail off get a longer pause before they are submitted.
public enum Endpointing {
    /// Silence wanted after the last new words before submitting them.
    public static func pause(after text: String, base: TimeInterval) -> TimeInterval {
        looksUnfinished(text) ? max(base, 1.8) : base
    }

    /// Whether the engine's end-of-utterance (a short silence) may submit the words now.
    /// A word or two ("用它……") is rarely a whole request either.
    public static func endpointEnds(_ text: String) -> Bool {
        text.filter { $0.isLetter || $0.isNumber }.count >= 4 && !looksUnfinished(text)
    }

    /// Ends on a comma, a connective, a particle that needs more after it, or a filler.
    public static func looksUnfinished(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else {
            return false
        }
        if "，,、；;：:—…".contains(last) {
            return true
        }
        // Recognizers often close a pause with a full stop; the words before it decide.
        let words = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "。.！!？?")).lowercased()
        if trailingChinese.contains(where: { words.hasSuffix($0) }) {
            return true
        }
        let lastWord = words.split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
        return trailingEnglish.contains(lastWord)
    }

    private static let trailingChinese = [
        "的", "地", "和", "跟", "与", "及", "或", "还", "把", "给", "在", "从", "对", "向", "让", "被", "比",
        "就", "也", "都", "又", "而", "但", "因为", "所以", "如果", "然后", "还有", "以及", "或者", "而且",
        "并且", "那个", "这个", "就是", "呃", "嗯", "额"
    ]
    private static let trailingEnglish: Set<String> = [
        "and", "or", "but", "the", "a", "an", "to", "of", "with", "for", "in", "on", "um", "uh", "so", "then"
    ]
}
