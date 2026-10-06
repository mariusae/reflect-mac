import Foundation

/// Two versions of a note merged line by line, from the version both came
/// from — git's three-way merge, done in the app, so an editor saving over
/// a note a sync changed meanwhile keeps both: what was typed here and what
/// came in. Where both changed the same lines, both are kept between
/// conflict markers, this device's first, to be settled as a sync's are.
public enum TextMerge {
    public struct Result: Equatable, Sendable {
        public var text: String
        /// Whether some lines both changed, and are between markers.
        public var conflicted: Bool

        public init(text: String, conflicted: Bool) {
            self.text = text
            self.conflicted = conflicted
        }
    }

    public static func merge(base: String, ours: String, theirs: String,
                             labels: (ours: String, theirs: String) = (ConflictMarkers.ourLabel, ConflictMarkers.theirLabel)) -> Result {
        if ours == theirs || theirs == base { return Result(text: ours, conflicted: false) }
        if ours == base { return Result(text: theirs, conflicted: false) }
        // A last line with no break is the same line as one with: lines are
        // compared each ended, and the end put back as the side that changed it has it.
        func ended(_ text: String) -> Bool { text.isEmpty || text.hasSuffix("\n") }
        let endsWithBreak = ended(ours) != ended(base) ? ended(ours) : ended(theirs)
        let o = terminated(lines(base)[...]), a = terminated(lines(ours)[...]), b = terminated(lines(theirs)[...])
        let toA = matches(o, a), toB = matches(o, b)
        var out: [Substring] = []
        var conflicted = false
        // Walk from one line both kept to the next; between, each side's run.
        var i = 0, ia = 0, ib = 0
        func emit(_ baseRun: ArraySlice<Substring>, _ aRun: ArraySlice<Substring>, _ bRun: ArraySlice<Substring>) {
            if aRun.elementsEqual(baseRun) { out += bRun }
            else if bRun.elementsEqual(baseRun) || aRun.elementsEqual(bRun) { out += aRun }
            else {
                conflicted = true
                out.append("<<<<<<< \(labels.ours)\n")
                out += terminated(aRun)
                out.append("=======\n")
                out += terminated(bRun)
                out.append(">>>>>>> \(labels.theirs)\n")
            }
        }
        while i <= o.count {
            // The next base line kept on both sides, at or after i.
            var j = i
            while j < o.count, toA[j] == nil || toB[j] == nil { j += 1 }
            let endA = j < o.count ? toA[j]! : a.count
            let endB = j < o.count ? toB[j]! : b.count
            if j > i || endA > ia || endB > ib {
                emit(o[i..<j], a[ia..<endA], b[ib..<endB])
            }
            guard j < o.count else { break }
            out.append(o[j])
            i = j + 1
            ia = endA + 1
            ib = endB + 1
        }
        var text = out.joined()
        if !endsWithBreak, !conflicted || !text.hasSuffix(">>>>>>> \(labels.theirs)\n"), text.hasSuffix("\n") { text.removeLast() }
        return Result(text: text, conflicted: conflicted)
    }

    /// A text's lines, each with its line break, the last one maybe without.
    static func lines(_ text: String) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        while start < text.endIndex {
            if let newline = text[start...].firstIndex(of: "\n") {
                let next = text.index(after: newline)
                result.append(text[start..<next])
                start = next
            } else {
                result.append(text[start...])
                break
            }
        }
        return result
    }

    /// Within markers every line must end in a break, or the marker after
    /// it would join it.
    private static func terminated(_ run: ArraySlice<Substring>) -> [Substring] {
        run.map { $0.hasSuffix("\n") ? $0 : Substring(String($0) + "\n") }
    }

    /// For each base line, where it is in the other version, if it is kept.
    private static func matches(_ base: [Substring], _ other: [Substring]) -> [Int?] {
        let difference = other.difference(from: base)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result = [Int?](repeating: nil, count: base.count)
        var k = 0
        for index in base.indices where !removed.contains(index) {
            while inserted.contains(k) { k += 1 }
            result[index] = k
            k += 1
        }
        return result
    }
}
