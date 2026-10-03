import AppKit
import ReflectUI

/// What notes are set in: a face for the text, one for headings — most
/// often the same — and a fixed-width one for code.
enum Typeface: String, CaseIterable {
    case mona, literata, fraunces, source, plex, alegreya, styrene, ideal, charter, recursive, go, system

    /// Faces not bundled — their licences do not allow it — offered only
    /// where they are installed.
    private var isBundled: Bool { self != .styrene && self != .ideal }

    /// The faces there are on this Mac.
    static var available: [Typeface] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return allCases.filter { face in face.isBundled || face.family.map(installed.contains) == true }
    }

    var title: String {
        switch self {
        case .mona: "Mona Sans"
        case .literata: "Literata"
        case .fraunces: "Literata & Fraunces"
        case .alegreya: "Alegreya Sans"
        case .source: "Source Serif & Sans"
        case .plex: "IBM Plex"
        case .styrene: "Styrene B"
        case .ideal: "Ideal Sans"
        case .charter: "Charter"
        case .recursive: "Recursive"
        case .go: "Go"
        case .system: "SF Pro"
        }
    }

    /// The faces differ in how big they look at a size: each is scaled to
    /// read as Mona Sans does.
    private var scale: CGFloat {
        switch self {
        case .mona, .system, .plex: 1
        case .ideal: 1.02
        case .literata, .fraunces, .styrene: 0.97
        // Its small letters are small: set larger to read as large.
        case .alegreya: 1.12
        case .source: 1.05
        case .charter: 1.03
        case .recursive: 0.95
        case .go: 0.93
        }
    }

    /// Line height, as a multiple of the face's own: the sans faces set tall
    /// already; the serifs, for reading at length, are given more.
    private var leading: CGFloat {
        switch self {
        case .mona, .recursive: 1.22
        case .go, .plex: 1.26
        case .styrene, .ideal, .alegreya: 1
        case .charter, .system: 1.32
        case .literata, .fraunces, .source: 1.36
        }
    }

    private var family: String? {
        switch self {
        case .mona: "Mona Sans"
        case .literata, .fraunces: "Literata"
        case .alegreya: "Alegreya Sans"
        case .source: "Source Serif 4"
        case .plex: "IBM Plex Sans"
        case .styrene: "Styrene B LC"
        case .ideal: "Ideal Sans SSm"
        case .charter: "Charter"
        case .recursive: "Recursive Sans Linear Static"
        case .go: "Go"
        case .system: nil
        }
    }

    /// Headings: Source's in its sans, over the serif text.
    private var headingFamily: String? {
        switch self {
        case .source: "Source Sans 3"
        case .fraunces: "Fraunces"
        default: family
        }
    }

    private var monoFamily: String? {
        switch self {
        case .mona: "Monaspace Xenon"
        case .literata, .fraunces, .alegreya, .styrene: "JetBrains Mono"
        // Hoefler's own, when it is installed; else the bundled one.
        case .ideal: Self.isInstalled("Operator Mono SSm") ? "Operator Mono SSm" : "JetBrains Mono"
        case .source: "Source Code Pro"
        case .plex: "IBM Plex Mono"
        case .recursive: "Recursive Mono Linear Static"
        case .go: "Go Mono"
        case .charter, .system: nil
        }
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

    /// Where its defaults are not wanted: what the Settings window sets,
    /// for each face its own — the faces differ in how they want setting.
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
    }

    /// How the face is set unless changed: sized to read as Mona Sans does
    /// at 16 points; lines as tall as suits it; the faces of families set
    /// by named styles — Book, Light, Semibold — named, not guessed at.
    var defaults: Settings {
        let styles: (text: String?, heading: String?) = switch self {
        case .styrene: ("Regular", "Bold")
        // Its Book reads heavy on screen; its Semibold claims Book's weight.
        case .ideal: ("Light", "Semibold")
        case .fraunces: (nil, "SemiBold")
        default: (nil, nil)
        }
        let lineHeight: Double = switch self {
        case .styrene: 1.42
        case .ideal, .alegreya: 1.45
        // As it was: a multiple of the face's own line.
        default: (naturalLine(style: styles.text) * leading * 100).rounded() / 100
        }
        return Settings(size: Double(round(16 * scale * 2) / 2), lineHeight: lineHeight, rowSpacing: 0.34, indent: 1.6,
                        lineLength: 660, headingScale: 1.5, textStyle: styles.text, headingStyle: styles.heading,
                        // Styrene's regular is heavy already: without the
                        // smoothing that thickens strokes, it reads as a regular should.
                        smoothing: self != .styrene)
    }

    private var settingsKey: String { "Typography." + rawValue }

    /// How it is set: its defaults, as changed in Settings.
    var settings: Settings {
        get {
            guard let data = UserDefaults.standard.data(forKey: settingsKey),
                  let stored = try? JSONDecoder().decode(Settings.self, from: data) else { return defaults }
            return stored
        }
        nonmutating set {
            if newValue == defaults {
                UserDefaults.standard.removeObject(forKey: settingsKey)
            } else if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: settingsKey)
            }
        }
    }

    /// The face's own line height, in ems: what its designer gave it.
    private func naturalLine(style: String?) -> Double {
        let font = Typography.font(family, face: Self.face(style, in: family), size: 100)
        return Double(NSLayoutManager().defaultLineHeight(for: font) / 100)
    }

    /// Axes set on the headings' face: Fraunces softened, its corners rounded.
    private var headingAxes: [String: Double] {
        self == .fraunces ? ["SOFT": 100] : [:]
    }

    /// The upright styles of the text's family, and of the headings', lightest first.
    var textStyles: [String] { Self.uprightStyles(in: family) }
    var headingStyles: [String] { Self.uprightStyles(in: headingFamily) }

    private static func uprightStyles(in family: String?) -> [String] {
        guard let family else { return [] }
        return Typography.Face.all(in: family).filter { !$0.italic }.sorted { $0.heaviness < $1.heaviness }.map(\.style)
    }

    /// The outline's settings for this face, as it is set.
    func typography() -> Typography {
        let settings = settings
        let textFace = Self.face(settings.textStyle, in: family)
        return Typography(bodyFamily: family, headingFamily: headingFamily, monospaceFamily: monoFamily,
                          bodyFace: textFace, headingFace: Self.face(settings.headingStyle, in: headingFamily),
                          monospaceFace: Self.face(monoStyle, in: monoFamily),
                          size: CGFloat(settings.size), lineHeight: CGFloat(settings.lineHeight / naturalLine(style: settings.textStyle)),
                          rowSpacing: CGFloat(settings.rowSpacing), headingScale: CGFloat(settings.headingScale),
                          lineLength: CGFloat(settings.lineLength), indent: CGFloat(settings.indent),
                          ink: Ink.notes, smoothing: settings.smoothing, headingAxes: headingAxes)
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
    /// Weeks, among the days: a warm ochre.
    static let week = dynamic(NSColor(srgbRed: 0.78, green: 0.52, blue: 0.12, alpha: 1),
                              NSColor(srgbRed: 0.93, green: 0.7, blue: 0.32, alpha: 1))
    static let marked = dynamic(NSColor(srgbRed: 1, green: 0.86, blue: 0.3, alpha: 0.45),
                                NSColor(srgbRed: 0.85, green: 0.7, blue: 0.2, alpha: 0.35))

    /// What the notes themselves are set in.
    static let notes = TextInk(text: text, secondary: secondary, tertiary: faint, rule: rule)

    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
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
