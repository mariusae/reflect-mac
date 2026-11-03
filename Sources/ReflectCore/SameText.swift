import Foundation

extension String {
    /// Whether two texts are the same, byte for byte: a note's — not `==`'s
    /// Unicode equivalence, which goes through a long one's every
    /// character, normalizing, to tell it from one a letter longer.
    public func isSameText(as other: String) -> Bool {
        var a = self, b = other
        return a.withUTF8 { x in
            b.withUTF8 { y in x.count == y.count && (x.count == 0 || memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0) }
        }
    }

    /// Whether a text has another in it, byte for byte: for a long note,
    /// asked as it is typed in — Foundation's `contains` goes a character
    /// at a time.
    public func containsText(_ other: String) -> Bool {
        var a = self, b = other
        return a.withUTF8 { x in
            b.withUTF8 { y in
                guard y.count > 0 else { return true }
                guard x.count >= y.count else { return false }
                return memmem(x.baseAddress!, x.count, y.baseAddress!, y.count) != nil
            }
        }
    }
}
