// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Standalone fixture app. Compile with production ChatChartView.swift and L10n.swift.
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
            }.padding(12)
            ScrollView { ChatChartView(source: source).padding(16) }
        }.preferredColorScheme(dark ? .dark : .light)
    }
}

// The fixture provides the app type scale without loading the production application.
enum Theme { static var callout: Font { .custom("Manrope", size: 12) } }
