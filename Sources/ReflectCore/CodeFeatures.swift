import CoreText
import Foundation

/// The OpenType features code is set with, by family: Paper Mono with its
/// coding ligatures (`ss01`) and slashed zero.
public enum CodeFeatures {
    public static let byFamily: [String: [String]] = [
        "Paper Mono": ["ss01", "zero"],
    ]

    /// A font descriptor's feature settings turning a family's features on.
    public static func settings(family: String) -> [[CFString: Any]] {
        (byFamily[family] ?? []).map { [kCTFontOpenTypeFeatureTag: $0 as CFString, kCTFontOpenTypeFeatureValue: 1] }
    }
}
