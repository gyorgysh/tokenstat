#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production sidebar heading and connected shell geometry."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "apps/mac/Sources/App/RootView.swift").read_text()
start = source.index("private struct SidebarGroupHeader<")
end = source.index("extension SidebarGroupHeader where", start)
header = source[start:end]
shell = (root / "apps/mac/Sources/App/ShellChrome.swift").read_text()
metrics = shell[shell.index("enum ShellMetrics {"):shell.index("extension View {")]
geometry = shell[shell.index("private struct DesktopChromeShape: Shape {"):
                 shell.index("/// The sidebar floated over")]
# Small dependencies keep this a focused SwiftUI layout test; the header itself
# is compiled directly from production, including ViewThatFits and controls.
harness = r'''
import SwiftUI
import AppKit
struct Theme {
    struct Space { static let xs: CGFloat = 4; static let m: CGFloat = 12; static let l: CGFloat = 20 }
    static func font(_ size: CGFloat, weight: Font.Weight) -> Font { .system(size: size, weight: weight) }
    static let sectionHeader = Font.system(size: 11)
    static let background = Color.black
}
struct SectionLabel: View {
    var text: String
    var count: Int?
    var body: some View { HStack { Text(text.uppercased()).font(Theme.sectionHeader); Spacer(); if let count { Text("\(count)") } } }
}
enum L10n { static func text(_ key: String, _ value: String) -> String { value } }
let DetailChromeBarHeight: CGFloat = 40
''' + metrics + header + geometry + r'''
@main struct SidebarHeaderCheck {
    @MainActor static func main() {
        let heights = [220.0, 440.0].map { width in
            let view = SidebarGroupHeader(title: "Repositories", count: 15, isExpanded: true, toggle: {}) {
                HStack(spacing: 4) {
                    Color.red.frame(width: 68, height: 28)
                    ForEach(0..<3) { _ in Color.blue.frame(width: 28, height: 28) }
                }
            }.frame(width: width).fixedSize(horizontal: false, vertical: true)
            guard let image = ImageRenderer(content: view).nsImage else { fatalError("No rendered heading") }
            return image.size.height
        }
        let (narrow, wide) = (heights[0], heights[1])
        precondition(wide == 44, "Wide controls did not stay beside the title")
        precondition(narrow >= wide + 12 && narrow < 80, "Narrow controls did not move to a second row")
        for (width, sidebar) in [(565.0, 76.0), (1024.0, 296.0), (1650.0, 410.0)] {
            let rect = CGRect(x: 0, y: 0, width: width, height: 720)
            let outline = DesktopChromeShape(sidebarWidth: sidebar).path(in: rect)
            let seam = ShellMetrics.headerHeight
            for point in [CGPoint(x: 0.5, y: 0.5),
                          CGPoint(x: width - 0.5, y: 0.5),
                          CGPoint(x: 0.5, y: rect.maxY - 0.5),
                          CGPoint(x: sidebar + 0.5, y: seam - 0.5),
                          CGPoint(x: sidebar - 0.5, y: seam + 0.5)] {
                precondition(outline.contains(point), "Chrome has a gap at \(point) for width \(width)")
            }
            // The content corner is square, so the chrome stops exactly at it.
            precondition(!outline.contains(CGPoint(x: sidebar + 0.5, y: seam + 0.5)),
                         "The material extends into the content")
        }
        for width in [660.0, 1000.0] {
            let columns = DesktopDetailLayout(minimumDetail: 480, inspectorWidth: 400) {
                Color.red
                Color.blue
            }.frame(width: width, height: 40)
            guard let data = ImageRenderer(content: columns).nsImage?.tiffRepresentation,
                  let pixels = NSBitmapImageRep(data: data) else { fatalError("No rendered columns") }
            let left = pixels.colorAt(x: 2, y: 15)!.usingColorSpace(.deviceRGB)!
            let right = pixels.colorAt(x: Int(width) - 2, y: 15)!.usingColorSpace(.deviceRGB)!
            precondition(left.redComponent > 0.8, "Inspector moved the leading content")
            precondition(width < 880 ? right.redComponent > 0.8 : right.blueComponent > 0.8,
                         "Docking did not respect the actual width while resizing")
        }
        print("Sidebar heading and connected shell geometry passed")
    }
}
'''
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "check.swift"
    binary = Path(tmp) / "check"
    path.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(path), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
