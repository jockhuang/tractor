import Foundation

enum L10n {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    static var speechLanguageCode: String {
        let language = Bundle.main.preferredLocalizations.first ?? Locale.current.identifier
        if language.hasPrefix("zh-Hant") || language.hasPrefix("zh-TW") || language.hasPrefix("zh-HK") {
            return "zh-TW"
        }
        if language.hasPrefix("zh-Hans") || language.hasPrefix("zh-CN") || language.hasPrefix("zh-SG") {
            return "zh-CN"
        }
        return "en-US"
    }
}
