import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    static let storageKey = "appLanguage"
    static let environmentKey = "DISK_ANALYZER_LANGUAGE"

    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var selectionTitle: String {
        switch self {
        case .simplifiedChinese: return "中文"
        case .english: return "English"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    var resourceFolderName: String {
        switch self {
        case .simplifiedChinese: return "zh-hans"
        case .english: return "en"
        }
    }

    static var current: AppLanguage {
        resolve(
            environmentValue: ProcessInfo.processInfo.environment[environmentKey],
            storedValue: UserDefaults.standard.string(forKey: storageKey)
        )
    }

    static func resolve(
        environmentValue: String?,
        storedValue: String?
    ) -> AppLanguage {
        if let environmentValue,
           let language = AppLanguage(rawValue: environmentValue) {
            return language
        }
        if let storedValue,
           let language = AppLanguage(rawValue: storedValue) {
            return language
        }
        return .simplifiedChinese
    }
}

enum L10n {
    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        localizedText(key, language: AppLanguage.current, arguments: arguments)
    }

    static func text(
        _ key: String,
        language: AppLanguage,
        _ arguments: CVarArg...
    ) -> String {
        localizedText(key, language: language, arguments: arguments)
    }

    private static func localizedText(
        _ key: String,
        language: AppLanguage,
        arguments: [CVarArg]
    ) -> String {
        let format = localizedBundle(for: language)
            .localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: language.locale, arguments: arguments)
    }

    private static func localizedBundle(for language: AppLanguage) -> Bundle {
        let container = localizationContainer
        guard let resourceURL = container.resourceURL,
              let bundle = Bundle(url: resourceURL.appendingPathComponent(
                "\(language.resourceFolderName).lproj",
                isDirectory: true
              )) else {
            return container
        }
        return bundle
    }

    private static var localizationContainer: Bundle {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return .main
        }
        return .module
    }
}
