#!/usr/bin/env python3
"""Exercise the actual SwiftUI sidebar heading at narrow and wide widths."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "apps/mac/Sources/App/RootView.swift").read_text()
start = source.index("private struct SidebarGroupHeader<")
end = source.index("extension SidebarGroupHeader where", start)
header = source[start:end]
# Small dependencies keep this a focused SwiftUI layout test; the header itself
# is compiled directly from production, including ViewThatFits and controls.
harness = r'''
import SwiftUI
import AppKit
struct Theme {
    struct Space { static let xs: CGFloat = 4; static let m: CGFloat = 12; static let l: CGFloat = 20 }
    static func font(_ size: CGFloat, weight: Font.Weight) -> Font { .system(size: size, weight: weight) }
    static let sectionHeader = Font.system(size: 11)
}
struct SectionLabel: View {
    var text: String
    var count: Int?
    var body: some View { HStack { Text(text.uppercased()).font(Theme.sectionHeader); Spacer(); if let count { Text("\(count)") } } }
}
enum L10n { static func text(_ key: String, _ value: String) -> String { value } }
''' + header + r'''
@main struct SidebarHeaderCheck {
    @MainActor static func main() {
        for width in [220.0, 440.0] {
            let view = SidebarGroupHeader(title: "Repositories", count: 15, isExpanded: true, toggle: {}) {
                HStack(spacing: 4) {
                    Color.red.frame(width: 68, height: 28)
                    ForEach(0..<3) { _ in Color.blue.frame(width: 28, height: 28) }
                }
            }.frame(width: width).fixedSize(horizontal: false, vertical: true)
            guard let image = ImageRenderer(content: view).nsImage else { fatalError("No rendered heading") }
            let height = image.size.height
            precondition(height < 100, "Heading wrapped into a tall column")
            if width == 220 { precondition(height > 65, "Narrow controls did not move to another row") }
            if width == 440 { precondition(height < 65, "Wide controls did not stay beside the title") }
        }
        print("Sidebar header: narrow and wide SwiftUI layouts passed")
    }
}
'''
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "check.swift"
    binary = Path(tmp) / "check"
    path.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(path), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
