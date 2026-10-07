import AppKit
import ReflectCore

/// The colours notes are set in: the words, those set back — quotes, done
/// tasks — the faintest marks, and the rules between things.
package struct TextInk: Equatable {
    package var text: NSColor
    package var secondary: NSColor
    package var tertiary: NSColor
    package var rule: NSColor

    package init(text: NSColor, secondary: NSColor, tertiary: NSColor, rule: NSColor) {
        self.text = text
        self.secondary = secondary
        self.tertiary = tertiary
        self.rule = rule
    }

    /// The system's own, following its appearance.
    package static let system = TextInk(text: .textColor, secondary: .secondaryLabelColor, tertiary: .tertiaryLabelColor,
                                        rule: .separatorColor)
}

/// How the notes are set: the typefaces, the size, and the spacing — the
/// Typography settings, kept in the user defaults, and told to every note
/// open when they change.
package struct Typography: Equatable {
    /// A family's name, or nil for the system's own.
    package var bodyFamily: String?
    package var headingFamily: String?
    package var monospaceFamily: String?
    /// The face chosen in each family, by PostScript name — nil for the
    /// family's own regular (for headings, its bold).
    package var bodyFace: String?
    package var headingFace: String?
    package var monospaceFace: String?
    package var size: CGFloat = 15
    /// Each line's height, as a multiple of the font's own.
    package var lineHeight: CGFloat = 1.18
    /// The space between rows, as a fraction of the size.
    package var rowSpacing: CGFloat = 0.2
    /// How much larger a first-level heading is than body text; the others
    /// step down from it.
    package var headingScale: CGFloat = 1.5
    /// The widest the text column is, in points.
    package var lineLength: CGFloat = 720
    /// How far each level of the outline is indented, as a multiple of the size.
    package var indent: CGFloat = 1.6
    /// The colours the words are set in.
    package var ink = TextInk.system
    /// Axes of a variable heading face set, by tag — Fraunces's softness,
    /// `SOFT` — over what its face has.
    package var headingAxes: [String: Double] = [:]
    /// Whether text is drawn with the system's font smoothing, which
    /// thickens strokes — light text on dark the most. A face whose
    /// regular is heavy already reads better without it.
    package var smoothing = true
    /// How headings are set.
    package var headingCase: HeadingCase = .family

    package init(bodyFamily: String? = nil, headingFamily: String? = nil, monospaceFamily: String? = nil,
                 bodyFace: String? = nil, headingFace: String? = nil, monospaceFace: String? = nil,
                 size: CGFloat = 15, lineHeight: CGFloat = 1.18, rowSpacing: CGFloat = 0.2,
                 headingScale: CGFloat = 1.5, lineLength: CGFloat = 720, indent: CGFloat = 1.6, ink: TextInk = .system,
                 smoothing: Bool = true, headingAxes: [String: Double] = [:], headingCase: HeadingCase = .family) {
        self.bodyFamily = bodyFamily
        self.headingFamily = headingFamily
        self.monospaceFamily = monospaceFamily
        self.bodyFace = bodyFace
        self.headingFace = headingFace
        self.monospaceFace = monospaceFace
        self.size = size
        self.lineHeight = lineHeight
        self.rowSpacing = rowSpacing
        self.headingScale = headingScale
        self.lineLength = lineLength
        self.indent = indent
        self.ink = ink
        self.smoothing = smoothing
        self.headingAxes = headingAxes
        self.headingCase = headingCase
    }

    package static let defaults = Typography()

    /// Settings made to go together, by name — each with only typefaces
    /// every Mac has.
    package static let presets: [(name: String, typography: Typography)] = [
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
    package var preset: String? {
        Self.presets.first { $0.typography == self }?.name
    }
    package static let sizes: ClosedRange<CGFloat> = 10...32

    private static let prefix = "Typography."
    /// Where the text size has always been kept.
    package static let sizeKey = "FontSize"
    package static let didChange = Notification.Name("TypographyDidChange")

    /// The settings as last saved; the text size where it always was.
    package static var current: Typography {
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

    /// A heading's font: the heading face, its axes set as asked, the
    /// others as the face has them.
    /// Whether the headings' face has small capitals of its own.
    package var headingHasSmallCaps: Bool {
        let font = Self.font(headingFamily, face: headingFace, size: 12, weight: .bold)
        guard let table = CTFontCopyTable(font as CTFont, CTFontTableTag(kCTFontTableGSUB), []) as Data? else { return false }
        return table.range(of: Data("smcp".utf8)) != nil
    }

    /// Whether headings are drawn in capitals the text does not have: all
    /// caps, or small caps made so for a face without its own.
    package var headingsInCapitals: Bool {
        headingCase == .caps || (headingCase == .smallCaps && !headingHasSmallCaps)
    }

    package func headingFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let font = Self.font(headingFamily, face: headingFace, size: size, weight: weight)
        guard !headingAxes.isEmpty else { return font }
        var axes = (CTFontCopyVariation(font as CTFont) as? [NSNumber: Any]) ?? [:]
        for (tag, value) in headingAxes {
            let code = tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            axes[NSNumber(value: code)] = value
        }
        return NSFont(descriptor: font.fontDescriptor.addingAttributes([.variation: axes]), size: size) ?? font
    }

    /// A font of a family at a size: the face chosen in it, else its
    /// regular (or, for `heavy`, its bold); the system's, for no family — or
    /// for one no longer installed.
    package static func font(_ family: String?, face: String? = nil, size: CGFloat, weight: NSFont.Weight = .regular,
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
    package struct Face: Equatable {
        package var name: String
        package var style: String
        package var weight: Int
        package var italic: Bool

        /// A family's faces, as it lists them.
        package static func all(in family: String) -> [Face] {
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
        package var heaviness: Int {
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
        package static func regular(in faces: [Face]) -> Face? {
            let upright = faces.filter { !$0.italic }
            for name in ["Regular", "Book", "Roman", "Text", "Normal", "Medium"] {
                if let face = upright.first(where: { $0.style.caseInsensitiveCompare(name) == .orderedSame }) { return face }
            }
            return upright.min { abs($0.heaviness - 5) < abs($1.heaviness - 5) } ?? faces.first
        }

        /// The face for headings: named Bold, else the upright nearest it.
        package static func bold(in faces: [Face]) -> Face? {
            let upright = faces.filter { !$0.italic }
            if let face = upright.first(where: { $0.style.caseInsensitiveCompare("Bold") == .orderedSame }) { return face }
            return upright.min { abs($0.heaviness - 9) < abs($1.heaviness - 9) } ?? faces.first
        }
    }

    /// The families installed, by name.
    package static var families: [String] { NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    /// The families whose regular face is fixed-pitch.
    package static var monospaceFamilies: [String] {
        families.filter { family in
            NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch ?? false
        }
    }
}
