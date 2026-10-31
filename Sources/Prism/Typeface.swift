import AppKit
import ReflectCore
import PrismCore
import ReflectUI

/// What notes are set in: one of a few styles, each a face for the text,
/// one for headings, one for code, and how they are set — ready made, the
/// size alone to change.
enum Typeface: String, CaseIterable {
    case ideal, apple, system

    /// Ideal Sans is not bundled — its licence does not allow it — and is
    /// offered only where it is installed, or was copied in at build.
    static var available: [Typeface] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return allCases.filter { $0 != .ideal || installed.contains("Ideal Sans SSm") }
    }

    var title: String {
        switch self {
        case .ideal: "Ideal Sans"
        case .apple: "New York"
        case .system: "System"
        }
    }

    /// What it is, under its name where it is chosen.
    var detail: String {
        switch self {
        case .ideal: "Hoefler’s Ideal Sans, in its Book, with Semibold headings"
        case .apple: "Apple’s New York, a serif for reading, with SF Mono"
        case .system: "SF Pro and SF Mono, as the system sets them"
        }
    }

    private var family: String? {
        switch self {
        case .ideal: "Ideal Sans SSm"
        case .apple: Typography.newYork
        case .system: nil
        }
    }

    private var monoFamily: String? {
        // Hoefler's own, when it is installed; else the system's.
        self == .ideal && Self.isInstalled("Operator Mono SSm") ? "Operator Mono SSm" : nil
    }

    private static func isInstalled(_ family: String) -> Bool {
        NSFontManager.shared.availableFontFamilies.contains(family)
    }

    /// The code face chosen in its family, by style name.
    private var monoStyle: String? {
        self == .ideal ? "Book" : nil
    }

    /// A face of a family by its style name, as the family names it.
    private static func face(_ style: String?, in family: String?) -> String? {
        guard let style, let family else { return nil }
        return Typography.Face.all(in: family).first { $0.style.caseInsensitiveCompare(style) == .orderedSame }?.name
    }

    // MARK: Settings

    /// How a style is set: its size, and the rest as it comes.
    struct Settings: Codable, Equatable {
        /// Points.
        var size: Double
        /// Each line's height, in ems: the same measure whatever the face.
        var lineHeight: Double
        /// The space between rows, in ems.
        var rowSpacing: Double
        /// How far each level of the outline is indented, in ems.
        var indent: Double
        /// The widest the text column is, in points.
        var lineLength: Double
        /// How much larger a first-level heading is than the text.
        var headingScale: Double
        /// The faces of the family the text and headings are set in, by
        /// style name; nil for the family's own regular and bold.
        var textStyle: String?
        var headingStyle: String?
        /// Whether text is drawn with the font smoothing that thickens it.
        var smoothing: Bool
        /// How headings are set; nil, as they always were — larger, bold.
        var headingCase: HeadingCase? = nil
    }

    /// How the style is set.
    var defaults: Settings {
        switch self {
        case .ideal:
            Settings(size: 14.5, lineHeight: 1.36, rowSpacing: 0.34, indent: 1.6, lineLength: 660, headingScale: 1.25,
                     textStyle: "Book", headingStyle: "Semibold", smoothing: true)
        case .apple:
            Settings(size: 15, lineHeight: 1.42, rowSpacing: 0.3, indent: 1.6, lineLength: 640, headingScale: 1.3,
                     textStyle: nil, headingStyle: nil, smoothing: true)
        case .system:
            Settings(size: 14, lineHeight: 1.36, rowSpacing: 0.32, indent: 1.6, lineLength: 660, headingScale: 1.3,
                     textStyle: nil, headingStyle: nil, smoothing: true)
        }
    }

    private var sizeKey: String { "TypeSize." + rawValue }

    /// How it is set: as it comes, at the size chosen.
    var settings: Settings {
        get {
            var settings = defaults
            if let size = UserDefaults.standard.object(forKey: sizeKey) as? Double { settings.size = size }
            return settings
        }
        nonmutating set {
            UserDefaults.standard.set(newValue.size == defaults.size ? nil : newValue.size, forKey: sizeKey)
        }
    }

    /// The face's own line height, in ems: what its designer gave it.
    private func naturalLine(style: String?) -> Double {
        let font = Typography.font(family, face: Self.face(style, in: family), size: 100)
        return Double(NSLayoutManager().defaultLineHeight(for: font) / 100)
    }

    /// The outline's settings for this face, as it is set.
    func typography() -> Typography {
        let settings = settings
        let textFace = Self.face(settings.textStyle, in: family)
        var typography = Typography(bodyFamily: family, headingFamily: family, monospaceFamily: monoFamily,
                          bodyFace: textFace, headingFace: Self.face(settings.headingStyle, in: family),
                          monospaceFace: Self.face(monoStyle, in: monoFamily),
                          size: CGFloat(settings.size), lineHeight: CGFloat(settings.lineHeight / naturalLine(style: settings.textStyle)),
                          rowSpacing: CGFloat(settings.rowSpacing), headingScale: CGFloat(settings.headingScale),
                          lineLength: CGFloat(settings.lineLength), indent: CGFloat(settings.indent),
                          ink: Ink.notes, smoothing: settings.smoothing, headingAxes: [:],
                          headingCase: settings.headingCase ?? .family)
        typography.flat = PageStyle.flat
        // Ideal Sans in its Book: bold within the text its Semibold, an even step up.
        if self == .ideal, settings.textStyle == "Book" { typography.boldStyle = "Semibold" }
        ProgressRing.monochrome = PageStyle.flat
        return typography
    }

    /// The face for the window's own words — the sidebar, the finder, the
    /// scrubber's labels — as the notes are set: plain words in the text's
    /// face, those set off in the headings'.
    func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let typography = typography()
        if weight.rawValue >= NSFont.Weight.medium.rawValue {
            return typography.headingFont(size: size, weight: weight)
        }
        return Typography.font(typography.bodyFamily, face: typography.bodyFace, size: size, weight: weight)
    }

    /// Makes the bundled fonts available to this process: from the app's
    /// Resources, or, run from the package, from Frameworks/.
    static func registerBundled() {
        var places = [Bundle.main.resourceURL?.appendingPathComponent("Fonts")]
        places.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Frameworks"))
        for case let place? in places {
            guard let files = FileManager.default.enumerator(at: place, includingPropertiesForKeys: nil) else { continue }
            var any = false
            for case let url as URL in files where ["otf", "ttf"].contains(url.pathExtension) {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                any = true
            }
            if any { return }
        }
    }
}

/// Prism's few colours: warm paper and warm ink — off-white and off-black,
/// in the light; in the dark, the same turned about — ink in three
/// strengths, and one accent.
enum Ink {
    /// sRGB from a hex number: 0xfaf7f2.
    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255, alpha: alpha)
    }

    static let paper = dynamic(hex(0xfaf7f2), hex(0x1d1b18))
    /// What the cards lie on: a shade under the paper.
    static let page = dynamic(hex(0xf0ece5), hex(0x161412))
    /// A note's card: lighter than the page.
    static let card = dynamic(hex(0xfdfcf9), hex(0x23201d))
    static let text = dynamic(hex(0x2b2724), hex(0xece6dc))
    static let secondary = dynamic(hex(0x6f665d), hex(0xa79e92))
    static let faint = dynamic(hex(0x2b2724, alpha: 0.32), hex(0xece6dc, alpha: 0.3))
    static let rule = dynamic(hex(0x2b2724, alpha: 0.1), hex(0xece6dc, alpha: 0.1))
    static let hover = dynamic(hex(0x2b2724, alpha: 0.05), hex(0xece6dc, alpha: 0.07))
    /// The sidebar's card: a shade off the paper.
    static let shelf = dynamic(hex(0xf2ede5), hex(0x262320))
    static let codeBack = dynamic(hex(0x2b2724, alpha: 0.04), hex(0xece6dc, alpha: 0.06))
    static let accent = dynamic(NSColor(srgbRed: 0.15, green: 0.36, blue: 0.82, alpha: 1),
                                NSColor(srgbRed: 0.52, green: 0.68, blue: 1, alpha: 1))
    /// Now: the block on, its ring running down about Daily; the line across today's hours.
    static let now = dynamic(NSColor(srgbRed: 0.88, green: 0.27, blue: 0.22, alpha: 1),
                             NSColor(srgbRed: 1.0, green: 0.42, blue: 0.36, alpha: 1))
    /// Weeks, among the days: a warm ochre.
    static let week = dynamic(NSColor(srgbRed: 0.78, green: 0.52, blue: 0.12, alpha: 1),
                              NSColor(srgbRed: 0.93, green: 0.7, blue: 0.32, alpha: 1))
    /// The small lines in spaced capitals over things: firmer than the
    /// secondary ink, to read at their size.
    static let label = dynamic(hex(0x7a7067), hex(0xa79e92))
    static let marked = dynamic(NSColor(srgbRed: 1, green: 0.86, blue: 0.3, alpha: 0.45),
                                NSColor(srgbRed: 0.85, green: 0.7, blue: 0.2, alpha: 0.35))

    /// What the notes themselves are set in.
    static let notes = TextInk(text: text, secondary: secondary, tertiary: faint, rule: rule, label: label)

    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
}

/// The notes flat on the page — parted by a hairline, headed in small
/// capitals, links underlined: the one way they are set.
enum PageStyle {
    static let flat = true
}

/// Light, dark, or as the system is: View ▸ Appearance.
enum Appearance: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static var current: Appearance {
        get { UserDefaults.standard.string(forKey: "Appearance").flatMap(Appearance.init(rawValue:)) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "Appearance")
            newValue.apply()
        }
    }

    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
