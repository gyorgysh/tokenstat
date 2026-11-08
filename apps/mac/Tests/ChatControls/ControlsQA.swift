// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

@main struct ControlsQA: App {
    @State private var path = [1]
    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                Text("Previous page")
                    .navigationDestination(for: Int.self) { _ in ControlsProbe() }
            }
        }
    }
}

private struct ControlsProbe: View {
    @State private var collapsed = false
    @State private var panel = "Chat"
    @State private var taps = 0
    @State private var sheet = false
    @State private var draft = ""
    @State private var closed = false
    @State private var cover = false

    var body: some View {
        Group {
            if closed {
                Text("Conversation list")
            } else {
                reader
            }
        }
    }

    private var reader: some View {
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
            NavigationLink("Open pushed chat") { PushedControlsProbe() }
            Button("Open covered chat") { cover = true }
            Spacer()
            TextField("Message", text: $draft)
            Button(collapsed ? "Show controls" : "Hide controls") { collapsed.toggle() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(ClientChatControlsSwipe(upward: false, enabled: collapsed, maximumStartY: 56) { collapsed = false })
        .modifier(ClientChatBackSwipe(enabled: collapsed) { closed = true })
        .toolbar(collapsed ? .hidden : .visible, for: .navigationBar)
        .fullScreenCover(isPresented: $cover) {
            NavigationStack { PushedControlsProbe(onBack: { cover = false }) }
        }
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

private struct PushedControlsProbe: View {
    var onBack: (() -> Void)? = nil
    @State private var collapsed = false

    var body: some View {
        VStack {
            Text("Pushed chat")
            Button("Hide pushed controls") { collapsed = true }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar(collapsed ? .hidden : .visible, for: .navigationBar)
        .modifier(ClientChatBackSwipe(enabled: collapsed, action: onBack))
    }
}
