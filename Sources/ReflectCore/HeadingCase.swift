import Foundation

/// How headings are set: larger, in the family's bold, as they always
/// were; at the text's size, bold; in small capitals — the face's own, or
/// capitals made small where it has none; or in small, spaced capitals.
/// The Mac's and the phone's.
public enum HeadingCase: String, Codable, CaseIterable, Sendable {
    case family, bold, smallCaps, caps

    /// What the Settings call it.
    public var title: String {
        switch self {
        case .family: "Larger"
        case .bold: "Text size, bold"
        case .smallCaps: "Small caps"
        case .caps: "All caps"
        }
    }

    /// Capitals' size, as a share of the text's: as tall as its small
    /// letters, near enough — a first-level heading a little more.
    public static func capitalsScale(level: Int) -> Double { level == 1 ? 0.86 : 0.8 }
    /// How far apart capitals are set, in ems.
    public static let capitalsTracking = 0.07
}
