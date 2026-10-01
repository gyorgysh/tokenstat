// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// App-owned copy is resolved separately from identifiers and user content.
enum L10n {
    private static let catalog = LanguageCatalog(
        directory: (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("localization"),
        platform: "apple",
        languages: Locale.preferredLanguages
    )

    static func text(_ key: String, _ arguments: String...) -> String {
        catalog.text(key, arguments: arguments)
    }

    static func enumLabel<Value: RawRepresentable>(_ value: Value) -> String where Value.RawValue == String {
        let key = "apple.enum.\(String(describing: Value.self)).\(value.rawValue)"
        return catalog.strings[key] ?? value.rawValue
    }
}

struct LanguageCatalog {
    let strings: [String: String]
    private static let placeholder = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    init(strings: [String: String]) {
        self.strings = strings
    }

    init(directory: URL, platform: String, languages: [String]) {
        func load(_ language: String, _ table: String) -> [String: String] {
            let url = directory.appendingPathComponent(language).appendingPathComponent("\(table).json")
            guard let data = try? Data(contentsOf: url),
                  let strings = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            return strings
        }
        var merged = load("en", "common").merging(load("en", platform)) { _, platform in platform }
        for language in languages {
            let normalized = language.replacingOccurrences(of: "_", with: "-")
            let components = normalized.split(separator: "-")
            var translated: [String: String] = [:]
            for count in 1...max(1, components.count) {
                let tag = components.prefix(count).joined(separator: "-")
                translated.merge(load(tag, "common").merging(load(tag, platform)) { _, platform in platform }) { _, regional in regional }
            }
            if !translated.isEmpty {
                merged.merge(translated) { _, translated in translated }
                break
            }
        }
        strings = merged
    }

    func text(_ key: String, arguments: [String] = []) -> String {
        guard let template = strings[key] else { return key }
        guard !arguments.isEmpty else { return template }
        let result = NSMutableString(string: template)
        let range = NSRange(template.startIndex..., in: template)
        for match in Self.placeholder.matches(in: template, range: range).reversed() {
            guard let indexRange = Range(match.range(at: 1), in: template),
                  let index = Int(template[indexRange]), arguments.indices.contains(index) else { continue }
            result.replaceCharacters(in: match.range, with: arguments[index])
        }
        return result as String
    }
}
