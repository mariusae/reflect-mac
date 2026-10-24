import CoreText
import Foundation

/// The OpenType features a family is set with, wherever it is used: Paper
/// Mono with its coding ligatures (`ss01`) and slashed zero; Ideal Sans with
/// lining figures (`lnum`), level with its capitals, not its old style.
public enum FontFeatures {
    public static let byFamily: [String: [String]] = [
        "Paper Mono": ["ss01", "zero"],
        "Ideal Sans SSm": ["lnum"],
    ]

    /// A font descriptor's feature settings turning a family's features on.
    public static func settings(family: String) -> [[CFString: Any]] {
        (byFamily[family] ?? []).map { [kCTFontOpenTypeFeatureTag: $0 as CFString, kCTFontOpenTypeFeatureValue: 1] }
    }
}
