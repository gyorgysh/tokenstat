// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

@main struct ControlsQA: App {
    var body: some Scene { WindowGroup { ControlsProbe() } }
}

private struct ControlsProbe: View {
    @State private var collapsed = false
    @State private var panel = "Chat"
    @State private var taps = 0
    @State private var sheet = false
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            if !collapsed {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(["Chat", "Changes", "Terminal", "Browser"], id: \.self) { name in
                            Button(name) { panel = name; collapsed = false }
                                .frame(width: 110, height: 44)
                                .modifier(ClientChatControlsSwipe(upward: true) { collapsed = true })
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            Button("Message at top") { taps += 1 }.frame(height: 44)
            Text("Tapped \(taps)")
            Text("Panel \(panel)")
            Button("Open sheet") { sheet = true }.padding(.top, 60)
            Spacer()
            TextField("Message", text: $draft)
            Button(collapsed ? "Show controls" : "Hide controls") { collapsed.toggle() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(ClientChatControlsSwipe(upward: false, enabled: collapsed, maximumStartY: 56) { collapsed = false })
        .sheet(isPresented: $sheet) {
            VStack {
                Button("Sheet action") { taps += 1 }.frame(height: 44)
                Button("Close sheet") { sheet = false }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .presentationDetents([.large])
            .interactiveDismissDisabled()
        }
    }
}
