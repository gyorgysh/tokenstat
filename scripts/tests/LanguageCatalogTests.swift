// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with L10n.swift.
import Foundation

@main
enum LanguageCatalogTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ language: String, _ table: String, _ strings: [String: String]) throws {
            let folder = directory.appendingPathComponent(language)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(strings).write(to: folder.appendingPathComponent(table + ".json"))
        }
        try write("en", "common", ["shared": "English", "fallback": "Still English", "platform": "Common"])
        try write("en", "apple", ["platform": "Apple"])
        try write("hu", "common", ["shared": "Magyar", "base": "Base language"])
        try write("hu-HU", "apple", ["shared": "Regional", "platform": "Regional Apple"])
        try write("zh-Hant", "apple", ["shared": "Script language"])
        precondition(LanguageCatalog(directory: directory, platform: "apple", languages: ["zh-Hant-TW"]).text("shared") == "Script language")
        let regional = LanguageCatalog(directory: directory, platform: "apple", languages: ["hu_HU", "en"])
        precondition(regional.text("shared") == "Regional")
        precondition(regional.text("base") == "Base language")
        precondition(regional.text("platform") == "Regional Apple")
        precondition(regional.text("fallback") == "Still English")
        precondition(LanguageCatalog(directory: directory, platform: "apple", languages: ["zz", "hu"]).text("shared") == "Magyar")
        precondition(LanguageCatalog(directory: directory, platform: "apple", languages: ["en-US", "hu"]).text("shared") == "English")
        precondition(LanguageCatalog(directory: directory, platform: "apple", languages: ["zz"]).text("platform") == "Apple")
        let formatted = LanguageCatalog(strings: ["message": "Á😀 {1}: {0} / {1} · 100%", "overflow": "{999999999999999999999}"])
        precondition(formatted.text("message", arguments: ["{1}", "$5% \\ path"]) == "Á😀 $5% \\ path: {1} / $5% \\ path · 100%")
        precondition(formatted.text("message") == "Á😀 {1}: {0} / {1} · 100%")
        precondition(formatted.text("overflow", arguments: ["x"]) == "{999999999999999999999}")
        precondition(formatted.text("missing") == "missing")
        precondition(L10n.text("common.cancel") == "Cancel", "Bundled English catalog was not found")
        print("Language catalog fallback, formatting, and bundled English passed.")
    }
}
