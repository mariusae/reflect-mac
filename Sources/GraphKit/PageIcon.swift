import Foundation
import ReflectCore

extension PageIcon {
    /// A page's icon, as its frontmatter has it: nil for none.
    public static func symbol(of page: Page) -> String? {
        let value: String? = switch page[field: key] {
        case .text(let text): text
        case .list(let items): items.first
        case nil: nil
        }
        let symbol = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return symbol.isEmpty ? nil : symbol
    }
}
