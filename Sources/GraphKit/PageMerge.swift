import Foundation
import ReflectCore

/// Two devices' changes to one page, put together: the frontmatter field
/// by field — tags as sets, `modified` the later, another field changed on
/// both going to whichever side was modified later — so that only the body
/// is left to merge by lines.
public enum PageMerge {
    /// The three sides of a file both devices changed, each given the one
    /// merged frontmatter: what `Git.prepareMerge` asks for. Nil for a file
    /// that is no page with frontmatter on every side.
    public static func prepare(path: String, ours: Data, base: Data, theirs: Data) -> (ours: Data, base: Data, theirs: Data)? {
        guard PageFolder.isPage(path) else { return nil }
        let sources = [ours, base, theirs].map { String(decoding: $0, as: UTF8.self) }
        guard sources.allSatisfy({ PageFile.split($0).header != nil }) else { return nil }
        let fallback = PageFolder.fallbackTitle(for: path)
        let sides = sources.map { PageFile.read($0, fallbackTitle: fallback, fixedTitle: PageFolder.titleIsFixed(path)) }
        let header = merge(base: sides[1], ours: sides[0], theirs: sides[2])
        // Every side written over this device's file, so their frontmatter
        // is the same text, and only their bodies differ.
        let rewritten = sides.map { side -> Data in
            var page = header
            page.text = side.text
            return Data(PageFile.write(page, over: sources[0], fallbackTitle: fallback, fixedTitle: PageFolder.titleIsFixed(path)).utf8)
        }
        return (rewritten[0], rewritten[1], rewritten[2])
    }

    /// The frontmatter of two sides put together over their base; the body
    /// is this device's.
    public static func merge(base: Page, ours: Page, theirs: Page) -> Page {
        let oursLater = (ours.modified ?? .distantPast) >= (theirs.modified ?? .distantPast)
        func pick<Value: Equatable>(_ base: Value, _ ours: Value, _ theirs: Value) -> Value {
            if ours == theirs || theirs == base { return ours }
            if ours == base { return theirs }
            return oursLater ? ours : theirs
        }
        var merged = ours
        merged.title = pick(base.title, ours.title, theirs.title)
        merged.id = pick(base.id, ours.id, theirs.id)
        merged.created = pick(base.created, ours.created, theirs.created)
        merged.modified = [ours.modified, theirs.modified].compactMap { $0 }.max()
        merged.tags = mergeList(base: base.tags, ours: ours.tags, theirs: theirs.tags)
        var names: [String] = []
        for field in ours.fields + theirs.fields + base.fields where !names.contains(field.name) { names.append(field.name) }
        merged.fields = names.compactMap { name in
            let value: Page.Value?
            if case .list(let a)? = ours[field: name], case .list(let b)? = theirs[field: name] {
                value = .list(mergeList(base: base[field: name]?.list ?? [], ours: a, theirs: b))
            } else {
                value = pick(base[field: name], ours[field: name], theirs[field: name])
            }
            return value.map { Page.Field(name, $0) }
        }
        return merged
    }

    /// This device's list, without what the other took out, with what the
    /// other put in after it.
    static func mergeList(base: [String], ours: [String], theirs: [String]) -> [String] {
        let removed = Set(base).subtracting(theirs)
        var result = ours.filter { !removed.contains($0) }
        for item in theirs where !base.contains(item) && !result.contains(item) { result.append(item) }
        return result
    }

    /// A draft saved over a file that changed while it was written: the
    /// frontmatter put together, and the body this device's when only this
    /// device changed it, the other's when only the other did, or both
    /// between conflict markers, to review.
    public static func merge(draft: Page, base: Page, current: Page) -> Page {
        var merged = merge(base: base, ours: draft, theirs: current)
        if draft.text == base.text {
            merged.text = current.text
        } else if current.text != base.text && current.text != draft.text {
            func line(_ text: String) -> String { text.hasSuffix("\n") || text.isEmpty ? text : text + "\n" }
            merged.text = "<<<<<<< \(ConflictMarkers.ourLabel)\n" + line(draft.text) + "=======\n" + line(current.text)
                + ">>>>>>> \(ConflictMarkers.theirLabel)\n"
        }
        return merged
    }
}
