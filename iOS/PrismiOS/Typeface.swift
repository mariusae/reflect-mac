import CoreText
import UIKit

/// What notes are set in, as on the Mac: a face for the text, one for
/// headings — most often the same — and a fixed-width one for code.
enum Typeface: String, CaseIterable, Identifiable {
    case mona, literata, fraunces, source, plex, alegreya, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mona: "Mona Sans"
        case .literata: "Literata"
        case .fraunces: "Literata & Fraunces"
        case .source: "Source Serif & Sans"
        case .plex: "IBM Plex"
        case .alegreya: "Alegreya Sans"
        case .system: "SF Pro"
        }
    }

    /// The faces differ in how big they look at a size: each is scaled to
    /// read as Mona Sans does.
    private var scale: CGFloat {
        switch self {
        case .mona, .system, .plex: 1
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
        case .alegreya: 1.4
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
        var descriptor: UIFontDescriptor
        if let family {
            descriptor = UIFontDescriptor(fontAttributes: [
                .family: family, .traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue],
            ])
        } else {
            descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        }
        if italic, let slanted = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) { descriptor = slanted }
        let font = UIFont(descriptor: descriptor, size: size)
        if let family, font.familyName != family { return .systemFont(ofSize: size, weight: weight) }
        return font
    }

    static var current: Typeface {
        // Set as Threads is: the system's own face.
        get { .system }
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
