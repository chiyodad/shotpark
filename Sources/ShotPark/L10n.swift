import Foundation

/// Minimal two-language helper. Follows the macOS language order (including a per-app language
/// set in System Settings or `-AppleLanguages "(en)"`): Korean if it comes first, English otherwise.
enum L10n {
    static let isKorean: Bool = {
        let langs = Locale.preferredLanguages
        guard let first = langs.first else { return false }
        return first.lowercased().hasPrefix("ko")
    }()
}

@inline(__always)
func L(_ ko: String, _ en: String) -> String { L10n.isKorean ? ko : en }
