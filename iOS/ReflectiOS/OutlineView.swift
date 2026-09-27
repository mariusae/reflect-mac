import SwiftUI
import ReflectCore

/// A note's outline, shown: each row at its depth, with its bullet,
/// checkbox, number or heading, and its Markdown drawn rather than shown.
struct OutlineView: View {
    let rows: [Row]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                RowView(row: row, compact: compact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RowView: View {
    let row: Row
    let compact: Bool
    @Environment(GraphStore.self) private var store

    private static let indent: CGFloat = 20

    var body: some View {
        switch row.kind {
        case .rule:
            Divider().padding(.vertical, 6)
        case .code:
            Text(CodeText.body(row.text))
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.fill.quaternary, in: .rect(cornerRadius: 8))
                .padding(.leading, CGFloat(row.depth) * Self.indent)
        case .heading(let level):
            Inline(text: row.text)
                .font(Self.headingFont(level))
                .fontWeight(.semibold)
                .padding(.top, compact ? 2 : 8)
                .padding(.leading, CGFloat(row.depth) * Self.indent)
        case .quote:
            HStack(spacing: 10) {
                Capsule().fill(.tertiary).frame(width: 3)
                Inline(text: row.text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, CGFloat(row.depth) * Self.indent)
        case .paragraph:
            Inline(text: row.text)
                .padding(.leading, CGFloat(row.depth) * Self.indent)
        case .bullet, .ordered:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                marker.frame(width: 16, alignment: .center)
                Inline(text: row.text, done: row.task?.isDone == true)
            }
            .padding(.leading, CGFloat(row.depth) * Self.indent)
        }
    }

    @ViewBuilder private var marker: some View {
        if let task = row.task {
            // Reflect's tasks are round, its checklist items square.
            let round = row.marker == "+"
            Image(systemName: task.isDone ? (round ? "checkmark.circle.fill" : "checkmark.square.fill")
                                          : (round ? "circle" : "square"))
                .foregroundStyle(task.isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .imageScale(.small)
        } else if row.kind == .ordered {
            Text("\(row.number)\(String(row.marker))").monospacedDigit().foregroundStyle(.secondary)
        } else {
            Circle().fill(.secondary).frame(width: 5, height: 5)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2
        case 2: .title3
        default: .headline
        }
    }
}

enum CodeText {
    /// A fenced block's code, its fences taken off.
    static func body(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") || first.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
            lines.removeFirst()
        }
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") || last.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}

/// A row's text with its inline Markdown drawn, and the pictures in it
/// beneath.
private struct Inline: View {
    let text: String
    var done = false
    @Environment(GraphStore.self) private var store

    var body: some View {
        let rendered = InlineText.render(text)
        VStack(alignment: .leading, spacing: 6) {
            if !rendered.text.characters.isEmpty || rendered.images.isEmpty {
                Text(rendered.text)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(rendered.images, id: \.source) { image in
                Picture(reference: image, root: store.root)
            }
        }
    }
}

/// A picture from the graph's `assets/`, or from the web.
private struct Picture: View {
    let reference: ImageReference
    let root: URL

    var body: some View {
        Group {
            if let url = url {
                if url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if !url.isFileURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 8).fill(.fill.tertiary).frame(height: 120)
                    }
                } else {
                    missing
                }
            } else {
                missing
            }
        }
        .frame(maxWidth: reference.width.map { CGFloat($0) }, alignment: .leading)
        .clipShape(.rect(cornerRadius: 8))
    }

    private var missing: some View {
        Label(reference.alt.isEmpty ? "Picture" : reference.alt, systemImage: "photo")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    /// As on the Mac: only a file inside `assets/`, and no `..` out of it.
    private var url: URL? {
        let source = reference.source
        if source.hasPrefix("https://") || source.hasPrefix("http://") { return URL(string: source) }
        let path = source.removingPercentEncoding ?? source
        guard path.hasPrefix("assets/"), !path.contains("\\") else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return root.appendingPathComponent(path)
    }
}
