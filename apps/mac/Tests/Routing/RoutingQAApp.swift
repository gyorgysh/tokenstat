// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Separate simulator app; never included in a shipping target.
import SwiftUI

@main struct RoutingQAApp: App {
    @State private var model = ChatModel()
    @State private var screen = "Settings"
    init() { AppFonts.register(); Bridge.connect() }
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                Text("Routing QA · simulated provider limit").font(Theme.caption).padding(Theme.Space.s)
                Picker("QA screen", selection: $screen) {
                    Text("Settings").tag("Settings")
                    Text("Limit").tag("Limit")
                }.pickerStyle(.segmented).padding(Theme.Space.m)
                if let chat = model.selected {
                    if screen == "Settings" {
                        ChatInspector(model: model, folder: nil, onClose: {}, showsHeader: false)
                    } else {
                        ScrollView {
                            ChatRoutingNotice(model: model, chat: chat).padding(Theme.Space.m)
                        }
                    }
                } else {
                    Text(model.error ?? "Loading disposable host…")
                    ProgressView()
                }
            }
            #if os(macOS)
            .frame(width: 640, height: 800)
            #endif
            .background(Theme.background)
            .tint(Theme.accent)
            .preferredColorScheme(.dark)
            .task {
                do {
                    let url = Bundle.main.url(forResource: "native-fixture", withExtension: "json")!
                    let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: String]
                    let account = try JSONDecoder().decode(Account.self, from: Data(#"{"signedIn":false,"host":"https://example.invalid","machines":[]}"#.utf8))
                    WorkSessionContext.shared.update(account: account)
                    await model.load(workspaceID: fixture["workspaceId"]!)
                    if let chat = model.chats.first(where: { $0.id == fixture["conversationId"] }) {
                        await model.select(chat)
                    }
                } catch { model.error = error.localizedDescription }
            }
        }
    }
}
