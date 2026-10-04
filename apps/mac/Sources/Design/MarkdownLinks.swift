// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

enum MarkdownLinks {
    private static let schemes: Set<String> = ["http", "https", "mailto"]

    /// Styling and URL filtering share one pass: an unsafe URL becomes plain
    /// text, while a safe link keeps emphasis and gains a visible affordance.
    static func styled(_ attributed: AttributedString, color: Color) -> AttributedString {
        guard attributed.runs.contains(where: { $0.link != nil }) else { return attributed }
        var result = attributed
        for run in attributed.runs {
            guard let url = run.link else { continue }
            if !schemes.contains(url.scheme?.lowercased() ?? "") {
                result[run.range].link = nil
            } else {
                // Explicit attributes survive an enclosing foreground style,
                // selection and mixed inline formatting on supported OSes.
                result[run.range].foregroundColor = color
                result[run.range].underlineStyle = Text.LineStyle(pattern: .solid, color: color)
            }
        }
        return result
    }
}
