// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// The app's string lookup, reduced to what the persona engine asks for.
///
/// The engine names each mood through `L10n.text`, as it does inside the app.
/// The lab reads the same English catalogs from the checkout, so a label here
/// is the label the app shows. A key the catalogs do not hold reads as itself,
/// which is loud enough to notice and never stops the lab from drawing.
enum L10n {
    private static let catalog: [String: String] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PersonaLab
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // PersonaLab package
            .deletingLastPathComponent()   // apps/mac
            .deletingLastPathComponent()   // apps
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
