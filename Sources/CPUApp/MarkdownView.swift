import CPUCore
import SwiftUI

/// A reply rendered from Markdown: headings, lists, tables, code and quotes, with inline
/// bold, code and links. Plain text comes out as one paragraph.
struct MarkdownView: View {
    let text: String
    var size: CGFloat = 14
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .foregroundStyle(color)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            MarkdownView.inline(text)
                .font(.system(size: level <= 1 ? size + 3 : level == 2 ? size + 1 : size, weight: .semibold))
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            MarkdownView.inline(text)
                .font(.system(size: size))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.system(size: size).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        MarkdownView.inline(item.text)
                            .font(.system(size: size))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
        case .table(let header, let alignments, let rows):
            table(header: header, alignments: alignments, rows: rows)
        case .code(let code):
            Text(code)
                .font(.system(size: size - 2, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                MarkdownView.inline(text)
                    .font(.system(size: size))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Divider()
        }
    }

    private func table(header: [String], alignments: [MarkdownAlignment], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                    MarkdownView.inline(cell)
                        .font(.system(size: size - 1, weight: .semibold))
                        .gridColumnAlignment(alignments[column].horizontal)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        MarkdownView.inline(cell)
                            .font(.system(size: size - 1).monospacedDigit())
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Bold, italics, inline code, strikethrough and links; the raw text if it does not parse.
    static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}

private extension MarkdownAlignment {
    var horizontal: HorizontalAlignment {
        switch self {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }
}

/// Content that takes only the height it needs, up to `maxHeight`, and scrolls beyond.
struct FitScroll<Content: View>: View {
    /// Tallest it grows before scrolling.
    var maxHeight: CGFloat = .infinity
    @ViewBuilder let content: Content
    // A reference box rather than @State: this toolchain has no SwiftUI macro plugin.
    @StateObject private var contentHeight = Measured()

    var body: some View {
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight.value = $0 }
        }
        // A definite height: the card takes its ideal height, which a scroll view does not have.
        .frame(height: min(max(contentHeight.value, 1), maxHeight))
    }
}

final class Measured: ObservableObject {
    @Published var value: CGFloat = 0
}
