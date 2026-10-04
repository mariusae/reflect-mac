import Foundation

/// A bare web address as a pill shows it: where it goes, not all it says —
/// its site, the first and last parts of its path, the rest hidden. The
/// Mac's and the phone's links alike.
public enum AddressShortening {
    /// What of an address is hidden: its first characters — scheme and
    /// `www.` — the middle of its path, between its first and last parts,
    /// and what follows its path. In the address's own characters.
    public static func shortened(_ address: String) -> (prefix: Int, middle: NSRange?, rest: NSRange?) {
        let text = address as NSString
        let scheme = text.range(of: "://")
        guard scheme.location != NSNotFound else { return (0, nil, nil) }
        var hostStart = NSMaxRange(scheme)
        if text.length > hostStart + 4, text.substring(with: NSRange(location: hostStart, length: 4)).lowercased() == "www." {
            hostStart += 4
        }
        // Where the path ends: at a query or a fragment.
        var end = text.length
        for mark in ["?", "#"] {
            let found = text.range(of: mark, options: [], range: NSRange(location: hostStart, length: text.length - hostStart))
            if found.location != NSNotFound { end = min(end, found.location) }
        }
        // Not a trailing slash, either.
        while end > hostStart, text.character(at: end - 1) == 0x2F { end -= 1 }
        let rest = end < text.length ? NSRange(location: end, length: text.length - end) : nil
        let slash = text.range(of: "/", options: [], range: NSRange(location: hostStart, length: end - hostStart))
        guard slash.location != NSNotFound else { return (hostStart, nil, rest) }
        // The path's parts: a middle only for three or more.
        var starts: [Int] = []
        var at = slash.location
        while at < end {
            if text.character(at: at) == 0x2F { starts.append(at) }
            at += 1
        }
        guard starts.count >= 3 else { return (hostStart, nil, rest) }
        // Kept: `/first`, then `/…/last`: hidden from after the first part to the last slash.
        let hiddenStart = starts[1] + 1
        let hiddenEnd = starts[starts.count - 1]
        return (hostStart, NSRange(location: hiddenStart, length: hiddenEnd - hiddenStart), rest)
    }
}
