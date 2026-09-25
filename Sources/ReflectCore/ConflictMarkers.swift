import Foundation

/// Conflict markers in a note, as Reflect writes and reads them.
///
/// A sync merge that conflicts writes standard Git markers into the note —
/// labelled `this device` and `other device` rather than with branch names —
/// and commits them, so the note carries the conflict and nothing waits on
/// it. A note has a conflict only when a whole block is there, in order:
/// `<<<<<<< ` then `=======` then `>>>>>>> `; prose that mentions one marker
/// line is not one. These are line for line the rules of Reflect's
/// `conflict_markers.rs`, so both apps see the same blocks and resolve them
/// the same way.
public enum ConflictMarkers {
    /// Which side of each block to keep.
    public enum Resolution: Sendable {
        /// The first side: this device's, for a Git conflict.
        case ours
        /// The second side.
        case theirs
        /// Both, first then second.
        case both
    }

    public struct Side: Equatable, Sendable {
        /// The label on the marker line.
        public var label: String
        /// The side's lines, joined with line breaks; may be empty.
        public var text: String
    }

    /// Plain text, or one whole conflict block.
    public enum Segment: Equatable, Sendable {
        case text(String)
        case conflict(ours: Side, theirs: Side)
    }

    public static let ourLabel = "this device"
    public static let theirLabel = "other device"

    private enum Section { case text, ours, theirs }

    /// The lines of a note, and each without the carriage return a Windows
    /// line break leaves on it.
    private static func lines(_ source: String) -> [(raw: Substring, line: Substring)] {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            (raw, raw.hasSuffix("\r") ? raw.dropLast() : raw)
        }
    }

    /// Whether a note holds a whole conflict block.
    public static func detect(_ source: String) -> Bool {
        blockCount(source) > 0
    }

    /// How many whole conflict blocks a note holds.
    public static func blockCount(_ source: String) -> Int {
        var count = 0
        var stage = 0
        for (_, line) in lines(source) {
            switch stage {
            case 0 where line.hasPrefix("<<<<<<< "): stage = 1
            case 1 where line == "=======": stage = 2
            case 2 where line.hasPrefix(">>>>>>> "):
                count += 1
                stage = 0
            default: break
            }
        }
        return count
    }

    /// The labels of the first whole block, when both have one.
    public static func labels(_ source: String) -> (ours: String, theirs: String)? {
        var ours: String?
        var sawSeparator = false
        for (_, line) in lines(source) {
            if ours == nil {
                if line.hasPrefix("<<<<<<< ") { ours = trimmed(line.dropFirst(8)) }
            } else if !sawSeparator {
                if line == "=======" { sawSeparator = true }
            } else if line.hasPrefix(">>>>>>> ") {
                let theirs = trimmed(line.dropFirst(8))
                guard let ours, !ours.isEmpty, !theirs.isEmpty else { return nil }
                return (ours, theirs)
            }
        }
        return nil
    }

    /// Resolves every block by keeping the chosen side, or both. Everything
    /// outside the blocks stays byte for byte; a block cut off before its
    /// end keeps what was chosen of it.
    public static func resolve(_ source: String, keeping keep: Resolution) -> String {
        var out: [Substring] = []
        var section = Section.text
        for (raw, line) in lines(source) {
            switch section {
            case .text:
                if line.hasPrefix("<<<<<<< ") { section = .ours } else { out.append(raw) }
            case .ours:
                if line == "=======" { section = .theirs } else if keep != .theirs { out.append(raw) }
            case .theirs:
                if line.hasPrefix(">>>>>>> ") { section = .text } else if keep != .ours { out.append(raw) }
            }
        }
        return out.joined(separator: "\n")
    }

    /// The note as runs of text and whole blocks, in order. A block cut off
    /// before its end goes back into the text, marker lines and all.
    public static func segments(_ source: String) -> [Segment] {
        var segments: [Segment] = []
        var text: [Substring] = []
        var pending: [Substring] = []
        var ours: [Substring] = []
        var theirs: [Substring] = []
        var oursLabel = ""
        var section = Section.text

        func flushText() {
            guard !text.isEmpty else { return }
            segments.append(.text(text.joined(separator: "\n")))
            text = []
        }

        for (raw, line) in lines(source) {
            switch section {
            case .text:
                if line.hasPrefix("<<<<<<< ") {
                    section = .ours
                    oursLabel = trimmed(line.dropFirst(8))
                    pending = [raw]
                    ours = []
                    theirs = []
                } else {
                    text.append(raw)
                }
            case .ours:
                pending.append(raw)
                if line == "=======" { section = .theirs } else { ours.append(raw) }
            case .theirs:
                if line.hasPrefix(">>>>>>> ") {
                    flushText()
                    segments.append(.conflict(
                        ours: Side(label: oursLabel, text: ours.joined(separator: "\n")),
                        theirs: Side(label: trimmed(line.dropFirst(8)), text: theirs.joined(separator: "\n"))))
                    section = .text
                    pending = []
                } else {
                    pending.append(raw)
                    theirs.append(raw)
                }
            }
        }
        if section != .text { text.append(contentsOf: pending) }
        flushText()
        return segments
    }

    private static func trimmed(_ text: Substring) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
