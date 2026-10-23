// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Standalone fixture app. Compile with production ChatChartView.swift, ChartViewport.swift and L10n.swift.
import SwiftUI
import WebKit

@main struct ChartQA: App {
    var body: some Scene {
        WindowGroup("Chart QA") { ChartQABody().frame(minWidth: 360, minHeight: 600) }
    }
}
private struct ChartQABody: View {
    @State private var kind = 0
    @State private var dark = false
    @State private var many = false
    private let examples: [[String: Any]] = {
        guard let file = Bundle.main.url(forResource: "examples", withExtension: "json"),
              let data = try? Data(contentsOf: file),
              let examples = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return examples
    }()
    private var source: String {
        guard examples.indices.contains(kind), let data = try? JSONSerialization.data(withJSONObject: examples[kind]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
    var body: some View {
        VStack {
            HStack {
                Picker("Chart type", selection: $kind) {
                    ForEach(Array(examples.enumerated()), id: \.offset) { index, item in
                        Text(item["type"] as? String ?? "Chart").tag(index)
                    }
                }.frame(maxWidth: 250)
                Toggle("Dark", isOn: $dark)
                Toggle("12 charts", isOn: $many)
            }.padding(12)
            ScrollView {
                VStack {
                    ForEach(0..<(many ? 12 : 1), id: \.self) { index in
                        Text("Chart \(index + 1)")
                        ChatChartView(source: source)
                    }
                }.padding(16)
            }
        }.preferredColorScheme(dark ? .dark : .light)
    }
}

// The fixture provides the app type scale without loading the production application.
enum Theme {
    static var callout: Font { .custom("Manrope", size: 12) }
    static var panel: Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 16 / 255, green: 14 / 255, blue: 26 / 255, alpha: 1) : .white
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 16 / 255, green: 14 / 255, blue: 26 / 255, alpha: 1) : .white
        })
        #endif
    }
}
