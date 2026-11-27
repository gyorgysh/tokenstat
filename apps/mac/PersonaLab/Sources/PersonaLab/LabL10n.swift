// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

enum L10n {
    private static let catalog: [String: String] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("localization/en")
        var merged: [String: String] = [:]
        for name in ["common", "apple"] {
            let file = root.appendingPathComponent("\(name).json")
            guard let data = try? Data(contentsOf: file),
                  let table = try? JSONDecoder().decode([String: String].self, from: data)
            else { continue }
            merged.merge(table) { current, _ in current }
        }
        return merged
    }()

    static func text(_ key: String, _ arguments: String...) -> String {
        var value = catalog[key] ?? key
        for (index, argument) in arguments.enumerated() {
            value = value.replacingOccurrences(of: "{\(index)}", with: argument)
        }
        return value
    }
}
