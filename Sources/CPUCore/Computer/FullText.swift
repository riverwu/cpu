import ApplicationServices
import Foundation

/// The whole text of a window's page or document, including what is scrolled out of view, as
/// a screen reader reads it: the body (web area, text area) rather than the toolbars around it.
enum FullText {
    struct Result {
        let text: String
        /// The window has a document body that keeps its text from accessibility (Word's
        /// layout area): its app has to hand the text over another way.
        let opaqueDocument: Bool
        /// False when reading stopped at the size, node or time limit before the end.
        var complete = true
        /// The text view holds only what is on screen (editors that load lines as they
        /// scroll): the share of the document its scroll bar says is visible.
        var visibleShare: Double?
    }

    static func collect(from window: AXUIElement, limit: Int, timeBudget: TimeInterval = 8) -> Result {
        let started = Date()
        var candidates: [(element: AXUIElement, role: String, length: Int, area: CGFloat)] = []
        var opaque = false
        var visited = 0
        // Find the content: the longest text area, else the largest web area.
        func find(_ element: AXUIElement, depth: Int) {
            guard depth < 14, visited < 4_000, Date().timeIntervalSince(started) < timeBudget / 3 else {
                return
            }
            visited += 1
            let values = AX.multiple(element, [kAXRoleAttribute, kAXValueAttribute, kAXSizeAttribute, kAXChildrenAttribute])
            let role = AX.stringFromValue(values[kAXRoleAttribute]) ?? ""
            let size = AX.sizeFromValue(values[kAXSizeAttribute]) ?? .zero
            switch role {
            case "AXTextArea":
                let length = (values[kAXValueAttribute] as? String)?.count ?? 0
                candidates.append((element, role, length, size.width * size.height))
                return
            case "AXWebArea":
                candidates.append((element, role, 0, size.width * size.height))
                return
            case "AXLayoutArea":
                if (values[kAXChildrenAttribute] as? [AXUIElement] ?? []).isEmpty, size.width * size.height > 40_000 {
                    opaque = true
                }
            default:
                break
            }
            for child in values[kAXChildrenAttribute] as? [AXUIElement] ?? [] {
                find(child, depth: depth + 1)
            }
        }
        find(window, depth: 0)

        if let area = candidates.filter({ $0.role == "AXTextArea" }).max(by: { $0.length < $1.length }), area.length >= 200,
           let value = AX.string(area.element, kAXValueAttribute) {
            return Result(text: String(value.prefix(limit)), opaqueDocument: false, complete: value.count <= limit,
                          visibleShare: visibleShare(of: area.element))
        }
        let root = candidates.filter { $0.role == "AXWebArea" }.max(by: { $0.area < $1.area })?.element ?? window
        var pieces = Joiner(limit: limit)
        var nodes = 0
        var stopped = false
        func gather(_ element: AXUIElement, depth: Int) {
            guard depth < 60, !stopped else {
                return
            }
            guard nodes < 200_000, !pieces.full, Date().timeIntervalSince(started) < timeBudget else {
                stopped = true
                return
            }
            nodes += 1
            let values = AX.multiple(element, [kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute])
            let role = AX.stringFromValue(values[kAXRoleAttribute]) ?? ""
            if AXRoles.skippedSubtrees.contains(role) || role == "AXToolbar" || role == "AXMenuBar" || role == "AXTabGroup" && depth < 3 {
                return
            }
            let frame = AXSnapshot.frame(from: values)
            switch role {
            case "AXStaticText", "AXTextArea", "AXTextField":
                let text = (values[kAXValueAttribute] as? String) ?? (AX.stringFromValue(values[kAXTitleAttribute]) ?? "")
                pieces.add(text, frame: frame)
                return
            default:
                break
            }
            for child in values[kAXChildrenAttribute] as? [AXUIElement] ?? [] {
                gather(child, depth: depth + 1)
            }
        }
        gather(root, depth: 0)
        return Result(text: pieces.text, opaqueDocument: opaque && pieces.text.count < 200, complete: !stopped)
    }

    /// For a text view inside a scroll area that is no taller than the area itself (so it
    /// holds only what is on screen), the share of the document the scroll bar shows. Nil when
    /// the view holds the whole document, or there is nothing to tell.
    static func visibleShare(of element: AXUIElement) -> Double? {
        var current = element
        for _ in 0..<4 {
            guard let parent = AX.element(current, kAXParentAttribute) else {
                return nil
            }
            if AX.role(parent) == "AXScrollArea" {
                guard let area = AX.frame(parent), let view = AX.frame(element), view.height <= area.height * 1.3,
                      let bar = AX.element(parent, kAXVerticalScrollBarAttribute), let track = AX.frame(bar), track.height > 0,
                      let thumb = AX.elements(bar, kAXChildrenAttribute).first(where: { AX.role($0) == "AXValueIndicator" }).flatMap(AX.frame) else {
                    return nil
                }
                let share = Double(thumb.height / track.height)
                return share < 0.6 ? share : nil
            }
            current = parent
        }
        return nil
    }

    /// Joins text pieces into lines by their position: a piece below the previous one starts a
    /// new line, one beside it continues the line (web pages split a paragraph at every link).
    struct Joiner {
        let limit: Int
        private(set) var text = ""
        /// Kept as it grows: counting a long String each time would be quadratic.
        private var count = 0
        private var lastFrame: CGRect?

        init(limit: Int) {
            self.limit = limit
        }

        var full: Bool {
            count >= limit
        }

        mutating func add(_ raw: String, frame: CGRect?) {
            let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty, !full else {
                return
            }
            if !text.isEmpty {
                if let frame, let last = lastFrame, frame.minY < last.maxY - 2, frame.minX >= last.minX {
                    // Same line: a space only between two Latin words.
                    if let previous = text.last, let next = piece.first, previous.isASCII, next.isASCII,
                       previous.isLetter || previous.isNumber || previous == ",", next.isLetter || next.isNumber {
                        text += " "
                        count += 1
                    }
                } else {
                    text += "\n"
                    count += 1
                }
            }
            text += piece
            count += piece.count
            if let frame {
                lastFrame = frame
            }
        }
    }
}
