import Foundation

/// Whether accepted edits really are in the document, decided by reading it rather than by
/// trusting the app's find panel or the model's impression.
struct EditCheck {
    struct Outcome: Equatable {
        var applied: [Int] = []
        /// The original passage is still there and the replacement is not.
        var missing: [Int] = []
        /// Neither (or both) found: the text may have been reworded or tracked as a revision.
        var unclear: [Int] = []
    }

    static func verify(_ edits: [(number: Int, edit: ProposedEdit)], in document: String) -> Outcome {
        let text = normalize(document)
        var outcome = Outcome()
        for (number, edit) in edits {
            let original = normalize(edit.original)
            let replacement = normalize(edit.replacement)
            let hasOriginal = !original.isEmpty && text.contains(original)
            let hasReplacement = !replacement.isEmpty && text.contains(replacement)
            switch (hasOriginal, hasReplacement) {
            case (false, true):
                outcome.applied.append(number)
            case (true, false):
                outcome.missing.append(number)
            case (true, true):
                // One may contain the other ("very very good" → "very good").
                if original.contains(replacement) {
                    outcome.missing.append(number)
                } else if replacement.contains(original) {
                    outcome.applied.append(number)
                } else {
                    outcome.unclear.append(number)
                }
            case (false, false):
                // A deletion leaves nothing to find.
                if replacement.isEmpty {
                    outcome.applied.append(number)
                } else {
                    outcome.unclear.append(number)
                }
            }
        }
        return outcome
    }

    /// Ignores what copying and typing change on the way: curly vs straight quotes, spacing.
    static func normalize(_ value: String) -> String {
        var text = value
        for (curly, straight) in [("‘", "'"), ("’", "'"), ("“", "\""), ("”", "\""), ("\u{00A0}", " ")] {
            text = text.replacingOccurrences(of: curly, with: straight)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
