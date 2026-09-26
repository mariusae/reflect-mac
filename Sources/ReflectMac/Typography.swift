import AppKit

/// How the notes are set: the typefaces, the size, and the spacing — the
/// Typography settings, kept in the user defaults, and told to every note
/// open when they change.
struct Typography: Equatable {
    /// A family's name, or nil for the system's own.
    var bodyFamily: String?
    var headingFamily: String?
    var monospaceFamily: String?
    /// The face chosen in each family, by PostScript name — nil for the
    /// family's own regular (for headings, its bold).
    var bodyFace: String?
    var headingFace: String?
    var monospaceFace: String?
    var size: CGFloat = 15
    /// Each line's height, as a multiple of the font's own.
    var lineHeight: CGFloat = 1.18
    /// The space between rows, as a fraction of the size.
    var rowSpacing: CGFloat = 0.2
    /// How much larger a first-level heading is than body text; the others
    /// step down from it.
    var headingScale: CGFloat = 1.5
    /// The widest the text column is, in points.
    var lineLength: CGFloat = 720

    static let defaults = Typography()

    /// Settings made to go together, by name — each with only typefaces
    /// every Mac has.
    static let presets: [(name: String, typography: Typography)] = [
        ("System", .defaults),
        ("Book", Typography(bodyFamily: "Charter", headingFamily: "Georgia", monospaceFamily: "Menlo",
                            size: 15, lineHeight: 1.5, rowSpacing: 0.4, headingScale: 1.5, lineLength: 720)),
        ("Compact", Typography(size: 13, lineHeight: 1.1, rowSpacing: 0.1, headingScale: 1.3, lineLength: 900)),
        ("Relaxed", Typography(size: 17, lineHeight: 1.45, rowSpacing: 0.35, headingScale: 1.5, lineLength: 640)),
        ("Palatino", Typography(bodyFamily: "Palatino", headingFamily: "Optima", monospaceFamily: "Menlo",
                                size: 16, lineHeight: 1.4, rowSpacing: 0.3, headingScale: 1.45, lineLength: 680)),
        ("Hoefler", Typography(bodyFamily: "Hoefler Text", headingFamily: "Hoefler Text", monospaceFamily: "Monaco",
                               size: 16, lineHeight: 1.35, rowSpacing: 0.3, headingScale: 1.6, lineLength: 680)),
        ("Modern", Typography(bodyFamily: "Avenir Next", headingFamily: "Avenir Next", monospaceFamily: "Menlo",
                              size: 15, lineHeight: 1.3, rowSpacing: 0.25, headingScale: 1.5, lineLength: 720)),
        ("Typewriter", Typography(bodyFamily: "American Typewriter", headingFamily: "American Typewriter", monospaceFamily: "Menlo",
                                  size: 15, lineHeight: 1.5, rowSpacing: 0.3, headingScale: 1.3, lineLength: 640)),
    ].filter { preset in
        // Only those whose typefaces are here.
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return [preset.1.bodyFamily, preset.1.headingFamily, preset.1.monospaceFamily].allSatisfy { $0.map(installed.contains) ?? true }
    }

    /// The preset some settings are, if any.
    var preset: String? {
        Self.presets.first { $0.typography == self }?.name
    }
    static let sizes: ClosedRange<CGFloat> = 10...32

    private static let prefix = "Typography."
    /// Where the text size has always been kept.
    static let sizeKey = "FontSize"
    static let didChange = Notification.Name("TypographyDidChange")

    /// The settings as last saved; the text size where it always was.
    static var current: Typography {
        get {
            let store = UserDefaults.standard
            var value = Typography()
            value.bodyFamily = store.string(forKey: prefix + "body")
            value.headingFamily = store.string(forKey: prefix + "heading")
            value.monospaceFamily = store.string(forKey: prefix + "monospace")
            value.bodyFace = store.string(forKey: prefix + "bodyFace")
            value.headingFace = store.string(forKey: prefix + "headingFace")
            value.monospaceFace = store.string(forKey: prefix + "monospaceFace")
            func number(_ key: String, _ fallback: CGFloat) -> CGFloat {
                store.object(forKey: key) == nil ? fallback : CGFloat(store.double(forKey: key))
            }
            value.size = min(max(number(sizeKey, value.size), sizes.lowerBound), sizes.upperBound)
            value.lineHeight = number(prefix + "lineHeight", value.lineHeight)
            value.rowSpacing = number(prefix + "rowSpacing", value.rowSpacing)
            value.headingScale = number(prefix + "headingScale", value.headingScale)
            value.lineLength = number(prefix + "lineLength", value.lineLength)
            return value
        }
        set {
            let store = UserDefaults.standard
            for (key, family) in [("body", newValue.bodyFamily), ("heading", newValue.headingFamily), ("monospace", newValue.monospaceFamily),
                                  ("bodyFace", newValue.bodyFace), ("headingFace", newValue.headingFace),
                                  ("monospaceFace", newValue.monospaceFace)] {
                if let family { store.set(family, forKey: prefix + key) } else { store.removeObject(forKey: prefix + key) }
            }
            store.set(Double(newValue.size), forKey: sizeKey)
            store.set(Double(newValue.lineHeight), forKey: prefix + "lineHeight")
            store.set(Double(newValue.rowSpacing), forKey: prefix + "rowSpacing")
            store.set(Double(newValue.headingScale), forKey: prefix + "headingScale")
            store.set(Double(newValue.lineLength), forKey: prefix + "lineLength")
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    // MARK: Fonts

    /// A font of a family at a size: the face chosen in it, else its
    /// regular (or, for `heavy`, its bold); the system's, for no family — or
    /// for one no longer installed.
    static func font(_ family: String?, face: String? = nil, size: CGFloat, weight: NSFont.Weight = .regular,
                     monospaced: Bool = false) -> NSFont {
        let system = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        guard let family else { return system }
        let faces = Face.all(in: family)
        if let face, faces.contains(where: { $0.name == face }), let font = NSFont(name: face, size: size) { return font }
        guard let chosen = weight >= .semibold ? Face.bold(in: faces) : Face.regular(in: faces),
              let font = NSFont(name: chosen.name, size: size) else { return system }
        return font
    }

    /// A face of a family: its PostScript name, what the family calls it,
    /// how heavy, and whether it slants.
    struct Face: Equatable {
        var name: String
        var style: String
        var weight: Int
        var italic: Bool

        /// A family's faces, as it lists them.
        static func all(in family: String) -> [Face] {
            (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { member in
                guard member.count >= 4, let name = member[0] as? String, let style = member[1] as? String else { return nil }
                let weight = (member[2] as? NSNumber)?.intValue ?? 5
                let traits = NSFontTraitMask(rawValue: (member[3] as? NSNumber)?.uintValue ?? 0)
                let slanted = traits.contains(.italicFontMask) || style.localizedCaseInsensitiveContains("italic")
                    || style.localizedCaseInsensitiveContains("oblique")
                return Face(name: name, style: style, weight: weight, italic: slanted)
            }
        }

        /// How heavy a face reads: its name, where the weight number lies —
        /// some families give Book and Semibold the same one.
        var heaviness: Int {
            let style = style.lowercased()
            let named: [(String, Int)] = [("hairline", 1), ("thin", 2), ("extra light", 3), ("xlight", 3), ("ultralight", 3),
                                          ("light", 4), ("book", 5), ("regular", 5), ("roman", 5), ("normal", 5), ("text", 5),
                                          ("medium", 6), ("semibold", 7), ("demi", 7), ("bold", 9), ("heavy", 11),
                                          ("black", 12), ("ultra", 12)]
            // The longest name found wins: "semibold" over "bold".
            return named.filter { style.contains($0.0) }.max { $0.0.count < $1.0.count }?.1 ?? weight
        }

        /// The face to set text in: named Regular, Book, Roman…, else the
        /// upright one nearest a regular weight.
        static func regular(in faces: [Face]) -> Face? {
            let upright = faces.filter { !$0.italic }
            for name in ["Regular", "Book", "Roman", "Text", "Normal", "Medium"] {
                if let face = upright.first(where: { $0.style.caseInsensitiveCompare(name) == .orderedSame }) { return face }
            }
            return upright.min { abs($0.heaviness - 5) < abs($1.heaviness - 5) } ?? faces.first
        }

        /// The face for headings: named Bold, else the upright nearest it.
        static func bold(in faces: [Face]) -> Face? {
            let upright = faces.filter { !$0.italic }
            if let face = upright.first(where: { $0.style.caseInsensitiveCompare("Bold") == .orderedSame }) { return face }
            return upright.min { abs($0.heaviness - 9) < abs($1.heaviness - 9) } ?? faces.first
        }
    }

    /// The families installed, by name.
    static var families: [String] { NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    /// The families whose regular face is fixed-pitch.
    static var monospaceFamilies: [String] {
        families.filter { family in
            NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch ?? false
        }
    }
}
