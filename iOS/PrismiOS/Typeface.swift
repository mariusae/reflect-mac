import CoreText
import UIKit
import ReflectCore

/// What notes are set in, as on the Mac: a face for the text, one for
/// headings — most often the same — and a fixed-width one for code.
enum Typeface: String, CaseIterable, Identifiable {
    case system, lato, alegreya, mona, plex, source, literata, fraunces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mona: "Mona Sans"
        case .literata: "Literata"
        case .fraunces: "Literata & Fraunces"
        case .source: "Source Serif & Sans"
        case .plex: "IBM Plex"
        case .alegreya: "Alegreya Sans"
        case .lato: "Lato"
        case .system: "SF Pro"
        }
    }

    /// The faces differ in how big they look at a size: each is scaled to
    /// read as Mona Sans does.
    private var scale: CGFloat {
        switch self {
        case .mona, .system, .plex: 1
        case .lato: 1
        case .literata, .fraunces: 0.97
        case .source: 1.05
        case .alegreya: 1.12
        }
    }

    /// Line height, in ems.
    var lineHeight: CGFloat {
        switch self {
        case .mona: 1.42
        case .plex: 1.4
        case .alegreya, .lato: 1.4
        case .system: 1.33
        case .literata, .fraunces, .source: 1.5
        }
    }

    private var family: String? {
        switch self {
        case .mona: "Mona Sans"
        case .literata, .fraunces: "Literata"
        case .source: "Source Serif 4"
        case .plex: "IBM Plex Sans"
        case .alegreya: "Alegreya Sans"
        case .lato: "Lato"
        case .system: nil
        }
    }

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
        case .literata, .fraunces, .alegreya: "JetBrains Mono"
        case .lato: "Roboto Mono"
        case .source: "Source Code Pro"
        case .plex: "IBM Plex Mono"
        case .system: nil
        }
    }

    /// The size text is set at, for a size asked for.
    func size(_ base: CGFloat) -> CGFloat { round(base * scale * 2) / 2 }

    func body(_ size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false) -> UIFont {
        font(family, size: size, weight: weight, italic: italic)
    }

    func heading(_ size: CGFloat, weight: UIFont.Weight = .bold) -> UIFont {
        var font = font(headingFamily, size: size, weight: weight)
        // Fraunces softened, its corners rounded.
        if self == .fraunces {
            let soft = "SOFT".utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            var axes = (CTFontCopyVariation(font as CTFont) as? [NSNumber: Any]) ?? [:]
            axes[NSNumber(value: soft)] = 100
            font = UIFont(descriptor: font.fontDescriptor.addingAttributes([UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): axes]),
                          size: size)
        }
        return font
    }

    func mono(_ size: CGFloat) -> UIFont {
        guard let monoFamily, let font = UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: monoFamily]), size: size) as UIFont?,
              font.familyName == monoFamily else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return font
    }

    private func font(_ family: String?, size: CGFloat, weight: UIFont.Weight, italic: Bool = false) -> UIFont {
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
        return font
    }

    /// The faces of each family — name, weight, italic — as registered.
    nonisolated(unsafe) private static var faces: [String: [(name: String, weight: CGFloat, italic: Bool)]] = [:]
    private static let facesLock = NSLock()

    /// The face of `family` nearest `weight`, italic or not as asked when
    /// it can be.
    private static func face(in family: String, weight: UIFont.Weight, italic: Bool) -> String? {
        facesLock.lock()
        defer { facesLock.unlock() }
        if faces[family] == nil {
            let found = UIFont.fontNames(forFamilyName: family).compactMap { name -> (String, CGFloat, Bool)? in
                guard let font = UIFont(name: name, size: 12) else { return nil }
                let traits = CTFontCopyTraits(font as CTFont) as NSDictionary
                let weight = (traits[kCTFontWeightTrait] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
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

    /// The face chosen in Settings; else Lato, as on the Mac.
    static var current: Typeface {
        get { UserDefaults.standard.string(forKey: "Typeface").flatMap(Typeface.init(rawValue:)) ?? .lato }
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

    // As Threads has it: white and near-black, ink black and near-white,
    // greys for the rest.
    static let paper = dynamic(.white, hex(0x101010))
    /// What the cards lie on, a little darker than they are.
    static let page = dynamic(hex(0xf3f2ef), hex(0x000000))
    /// A note's card.
    static let card = dynamic(hex(0xfdfdfc), hex(0x1a1a1a))
    static let text = dynamic(hex(0x000000), hex(0xf3f5f7))
    static let secondary = dynamic(hex(0x999999), hex(0x777777))
    static let faint = dynamic(hex(0x000000, alpha: 0.3), hex(0xf3f5f7, alpha: 0.3))
    static let rule = dynamic(hex(0x000000, alpha: 0.15), hex(0xf3f5f7, alpha: 0.15))
    static let hover = dynamic(hex(0x000000, alpha: 0.04), hex(0xf3f5f7, alpha: 0.06))
    static let shelf = dynamic(hex(0xf5f5f5), hex(0x1e1e1e))
    static let codeBack = dynamic(hex(0x000000, alpha: 0.05), hex(0xf3f5f7, alpha: 0.08))
    /// The floating compose button.
    static let composeBack = dynamic(.white, hex(0x2a2a2a))
    static let composeInk = dynamic(.black, .white)
    static let accent = dynamic(hex(0x0095f6), hex(0x4cb5f9))
    static let pill = dynamic(UIColor(red: 0.15, green: 0.36, blue: 0.82, alpha: 0.09), UIColor(red: 0.52, green: 0.68, blue: 1, alpha: 0.14))
    static let week = dynamic(UIColor(red: 0.78, green: 0.52, blue: 0.12, alpha: 1), UIColor(red: 0.93, green: 0.7, blue: 0.32, alpha: 1))
    static let marked = dynamic(UIColor(red: 1, green: 0.86, blue: 0.3, alpha: 0.45), UIColor(red: 0.85, green: 0.7, blue: 0.2, alpha: 0.35))
}

/// How a face is set, past its size: lines' height, the space between rows,
/// the outline's indent, and how large headings are — each face its own,
/// as on the Mac, kept as changed in Settings.
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

    static func defaults(_ face: Typeface) -> PhoneSpacing {
        // Lato as the Mac sets it.
        if face == .lato { return PhoneSpacing(lineHeight: 1.39, rowSpacing: 0.34, indent: 1.6, headingScale: 1.25, headingCase: .smallCaps) }
        return PhoneSpacing(lineHeight: Double(face.lineHeight), rowSpacing: 0.32, indent: 1.35, headingScale: 1.55)
    }

    private static func key(_ face: Typeface) -> String { "Spacing." + face.rawValue }

    /// A face's, as set.
    static func of(_ face: Typeface) -> PhoneSpacing {
        guard let data = UserDefaults.standard.data(forKey: key(face)),
              let stored = try? JSONDecoder().decode(PhoneSpacing.self, from: data) else { return defaults(face) }
        return stored
    }

    /// Keeps a face's; its defaults, kept as none.
    static func set(_ spacing: PhoneSpacing, for face: Typeface) {
        if spacing == defaults(face) {
            UserDefaults.standard.removeObject(forKey: key(face))
        } else if let data = try? JSONEncoder().encode(spacing) {
            UserDefaults.standard.set(data, forKey: key(face))
        }
    }
}
