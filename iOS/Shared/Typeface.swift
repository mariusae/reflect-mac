import CoreText
import UIKit
import ReflectCore

/// What notes are set in, as on the Mac: one of a few styles — a face for
/// the text, one for headings, one for code, and how they are set — ready
/// made, the size alone to change.
enum Typeface: String, CaseIterable, Identifiable {
    case ideal, apple, system

    /// The styles this build has: Ideal Sans only when its fonts were there
    /// to bundle — Hoefler's, copied from the owner's own, never fetched.
    static let available: [Typeface] = {
        let bundled = Bundle.main.resourceURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Fonts/IdealSansSSm-Book-Pro.otf").path)
        } ?? false
        return allCases.filter { $0 != .ideal || bundled }
    }()

    var id: String { rawValue }

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
        case .ideal: "Hoefler’s Ideal Sans, in its Book"
        case .apple: "Apple’s New York, a serif for reading"
        case .system: "SF Pro, as the system sets it"
        }
    }

    /// The faces differ in how big they look at a size: each is scaled to
    /// read alike.
    private var scale: CGFloat { self == .ideal ? 1.02 : 1 }

    /// Line height, in ems.
    var lineHeight: CGFloat {
        switch self {
        case .ideal: 1.38
        case .apple: 1.42
        case .system: 1.36
        }
    }

    /// Apple's New York, as a family's name: the system's serif, which no
    /// family name reaches.
    static let newYork = "New York"

    private var family: String? {
        switch self {
        case .ideal: "Ideal Sans SSm"
        case .apple: Self.newYork
        case .system: nil
        }
    }

    private var headingFamily: String? { family }

    private var monoFamily: String? { self == .ideal ? "Operator Mono SSm" : nil }

    /// The weight bold is set in: Ideal Sans's Semibold, as on the Mac.
    var boldWeight: UIFont.Weight { self == .ideal ? .semibold : .bold }

    /// A font of a family at a weight, italic or not, picked from the
    /// family's own faces by name — not by traits, which can land on any.
    static func font(family: String, weight: UIFont.Weight, italic: Bool, size: CGFloat) -> UIFont? {
        face(in: family, weight: weight, italic: italic).flatMap { UIFont(name: $0, size: size) }.map { withFeatures($0) }
    }

    /// A font with the features its family is set with turned on — Ideal
    /// Sans's lining figures — and any others asked for, small capitals.
    static func withFeatures(_ font: UIFont, adding more: [[UIFontDescriptor.FeatureKey: Int]] = []) -> UIFont {
        let features: [Any] = FontFeatures.settings(family: font.familyName) + more
        guard !features.isEmpty else { return font }
        return UIFont(descriptor: font.fontDescriptor.addingAttributes([.featureSettings: features]), size: font.pointSize)
    }

    /// A text weight as the face is set. Ideal Sans: bold within the text
    /// its Semibold, an even step up from its Book.
    private func textWeight(_ weight: UIFont.Weight) -> UIFont.Weight {
        guard self == .ideal else { return weight }
        switch weight {
        case .bold: return .semibold
        case .heavy, .black: return .bold
        default: return weight
        }
    }

    /// The size text is set at, for a size asked for.
    func size(_ base: CGFloat) -> CGFloat { round(base * scale * 2) / 2 }

    func body(_ size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false) -> UIFont {
        font(family, size: size, weight: textWeight(weight), italic: italic)
    }

    func heading(_ size: CGFloat, weight: UIFont.Weight = .bold) -> UIFont {
        font(headingFamily, size: size, weight: weight)
    }

    func mono(_ size: CGFloat) -> UIFont {
        // Its regular face, by name: asked for by family alone, the system
        // may give any — Operator Mono's Bold.
        guard let monoFamily, let name = Self.face(in: monoFamily, weight: .regular, italic: false),
              let font = UIFont(name: name, size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        // With the stylistic sets it is set in turned on.
        let features = FontFeatures.settings(family: monoFamily)
        guard !features.isEmpty else { return font }
        return UIFont(descriptor: font.fontDescriptor.addingAttributes([.featureSettings: features]), size: size)
    }

    private func font(_ family: String?, size: CGFloat, weight: UIFont.Weight, italic: Bool = false) -> UIFont {
        // New York: the system's serif, by its design.
        if family == Self.newYork {
            var descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
            descriptor = descriptor.withDesign(.serif) ?? descriptor
            if italic, let slanted = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) { descriptor = slanted }
            return UIFont(descriptor: descriptor, size: size)
        }
        guard let family else {
            var descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
            if italic, let slanted = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) { descriptor = slanted }
            return UIFont(descriptor: descriptor, size: size)
        }
        // The face picked from the family's own, by name: matched by
        // descriptor, Bold Text turns a weight heavier, to a face — Lato
        // Black — of a family of its own, and the text fell to the system's.
        guard let name = Self.face(in: family, weight: weight, italic: italic),
              let font = UIFont(name: name, size: size) else { return .systemFont(ofSize: size, weight: weight) }
        return Self.withFeatures(font)
    }

    /// The faces of each family — name, weight, italic — as registered.
    nonisolated(unsafe) private static var faces: [String: [(name: String, weight: CGFloat, italic: Bool)]] = [:]
    private static let facesLock = NSLock()

    /// A face's weight by the style its name gives — `IdealSansSSm-Semibold-Pro`
    /// — on the system's scale: the weights some families report are their
    /// own, Hoefler's Bold claiming a regular's 0 and its Book less.
    private static func styleWeight(_ name: String) -> CGFloat? {
        let parts = name.lowercased().split(separator: "-").dropFirst()
        let style = parts.first.map { $0.replacingOccurrences(of: "italic", with: "").replacingOccurrences(of: "oblique", with: "") } ?? ""
        let scale: [String: UIFont.Weight] = [
            "thin": .thin, "hairline": .ultraLight, "extralight": .ultraLight, "xlight": .ultraLight, "ultralight": .ultraLight,
            "light": .light, "book": .regular, "regular": .regular, "": .regular, "roman": .regular,
            "medium": .medium, "semibold": .semibold, "demibold": .semibold, "bold": .bold,
            "extrabold": .heavy, "heavy": .heavy, "black": .black,
        ]
        return scale[style].map { $0.rawValue }
    }

    /// The face of `family` nearest `weight`, italic or not as asked when
    /// it can be.
    private static func face(in family: String, weight: UIFont.Weight, italic: Bool) -> String? {
        facesLock.lock()
        defer { facesLock.unlock() }
        if faces[family] == nil {
            let found = UIFont.fontNames(forFamilyName: family).compactMap { name -> (String, CGFloat, Bool)? in
                guard let font = UIFont(name: name, size: 12) else { return nil }
                let traits = CTFontCopyTraits(font as CTFont) as NSDictionary
                let weight = styleWeight(name) ?? (traits[kCTFontWeightTrait] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
                return (name, weight, font.fontDescriptor.symbolicTraits.contains(.traitItalic))
            }
            // Not yet registered: asked again next time.
            guard !found.isEmpty else { return nil }
            faces[family] = found.map { (name: $0.0, weight: $0.1, italic: $0.2) }
        }
        let all = faces[family] ?? []
        let styled = all.filter { $0.italic == italic }
        return (styled.isEmpty ? all : styled).min { abs($0.weight - weight.rawValue) < abs($1.weight - weight.rawValue) }?.name
    }

    /// The style chosen in Settings; else Ideal Sans, as on the Mac — the
    /// system's, where it wasn't bundled.
    static var current: Typeface {
        get {
            let fallback: Typeface = available.contains(.ideal) ? .ideal : .system
            return UserDefaults.standard.string(forKey: "Typeface").flatMap(Typeface.init(rawValue:))
                .flatMap { available.contains($0) ? $0 : nil } ?? fallback
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "Typeface") }
    }

    /// Makes the bundled fonts — copied into the app at build — available.
    /// The bundled fonts, registered off the main thread: started at
    /// launch, waited on before the first note is drawn.
    static let registration = Task.detached(priority: .userInitiated) { registerBundled() }

    nonisolated static func registerBundled() {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for url in files where ["otf", "ttf"].contains(url.pathExtension) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

/// Prism's colours: warm paper and warm ink, light and dark.
enum Ink {
    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255, alpha: alpha)
    }

    static func dynamic(_ light: UIColor, _ dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    // In the light, the Mac's: warm paper and warm ink — cream, and a
    // brown-black — greys warmed to go with them. In the dark, the phone's
    // own: near-black, for its screen, and near-white ink.
    static let paper = dynamic(hex(0xfaf7f2), hex(0x101010))
    static let page = paper
    /// A note's card: lighter than the paper, as the Mac's.
    static let card = dynamic(hex(0xfdfcf9), hex(0x1a1a1a))
    /// What links to a note, on its card: lifted off the page — white on
    /// the cream; in the dark, a grey well above the near-black.
    static let backlinkCard = dynamic(hex(0xfefdfb), hex(0x232325))
    static let text = dynamic(hex(0x2b2724), hex(0xf3f5f7))
    static let secondary = dynamic(hex(0x958c83), hex(0x777777))
    /// The small lines in spaced capitals over things: quieter than the
    /// text, a shade firmer than the secondary grey, to read at their size.
    static let label = dynamic(hex(0x7a7067), hex(0x9e9e9e))
    static let faint = dynamic(hex(0x2b2724, alpha: 0.32), hex(0xf3f5f7, alpha: 0.3))
    static let rule = dynamic(hex(0x2b2724, alpha: 0.13), hex(0xf3f5f7, alpha: 0.15))
    static let hover = dynamic(hex(0x2b2724, alpha: 0.05), hex(0xf3f5f7, alpha: 0.06))
    static let shelf = dynamic(hex(0xf2ede5), hex(0x1e1e1e))
    static let codeBack = dynamic(hex(0x2b2724, alpha: 0.05), hex(0xf3f5f7, alpha: 0.08))
    /// The floating compose button.
    static let composeBack = dynamic(hex(0xfdfcf9), hex(0x2a2a2a))
    static let composeInk = dynamic(hex(0x2b2724), .white)
    static let accent = dynamic(hex(0x0095f6), hex(0x4cb5f9))
    static let pill = dynamic(UIColor(red: 0.15, green: 0.36, blue: 0.82, alpha: 0.09), UIColor(red: 0.52, green: 0.68, blue: 1, alpha: 0.14))
    static let week = dynamic(UIColor(red: 0.78, green: 0.52, blue: 0.12, alpha: 1), UIColor(red: 0.93, green: 0.7, blue: 0.32, alpha: 1))
    /// Now: the block on, its ring running down about Daily — the Mac's red too.
    static let now = dynamic(UIColor(red: 0.88, green: 0.27, blue: 0.22, alpha: 1), UIColor(red: 1.0, green: 0.42, blue: 0.36, alpha: 1))
    static let marked = dynamic(UIColor(red: 1, green: 0.86, blue: 0.3, alpha: 0.45), UIColor(red: 0.85, green: 0.7, blue: 0.2, alpha: 0.35))
}

/// How a style is set, past its size: lines' height, the space between
/// rows, the outline's indent, and how large headings are — as it comes.
struct PhoneSpacing: Codable, Equatable {
    /// Each line's height, in ems.
    var lineHeight: Double
    /// The space after each row, in ems.
    var rowSpacing: Double
    /// Each level of the outline, in ems.
    var indent: Double
    /// A first-level heading, as a multiple of the text.
    var headingScale: Double
    /// How headings are set; nil, as they always were — larger, bold.
    var headingCase: HeadingCase? = nil

    static func of(_ face: Typeface) -> PhoneSpacing {
        switch face {
        case .ideal: PhoneSpacing(lineHeight: 1.38, rowSpacing: 0.32, indent: 1.35, headingScale: 1.55)
        case .apple: PhoneSpacing(lineHeight: 1.42, rowSpacing: 0.3, indent: 1.35, headingScale: 1.45)
        case .system: PhoneSpacing(lineHeight: 1.36, rowSpacing: 0.3, indent: 1.35, headingScale: 1.45)
        }
    }
}
