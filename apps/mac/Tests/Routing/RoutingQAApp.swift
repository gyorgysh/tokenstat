// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Separate simulator app; never included in a shipping target.
import SwiftUI

@main struct RoutingQAApp: App {
    @State private var model = ChatModel()
    @State private var screen = "Settings"
    #if os(iOS)
    @State private var account = AccountModel()
    @State private var navigation = ClientNavigationModel()
    #endif
    init() { AppFonts.register(); Bridge.connect() }
    private func limitNotice(_ chat: ChatConversation) -> some View {
        ScrollView { ChatRoutingNotice(model: model, chat: chat).padding(Theme.Space.m) }
    }
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                Text("Routing QA · simulated provider limit").font(Theme.caption).padding(Theme.Space.s)
                Picker("QA screen", selection: $screen) {
                    Text("Settings").tag("Settings")
                    Text("Limit").tag("Limit")
                    #if os(iOS)
                    Text("Conversation").tag("Conversation")
                    #endif
                }.pickerStyle(.segmented).padding(Theme.Space.m)
                if let chat = model.selected {
                    if screen == "Settings" {
                        ChatInspector(model: model, folder: nil, onClose: {}, showsHeader: false)
                    } else {
                        #if os(iOS)
                        if screen == "Conversation" {
                            ClientChatThread(model: model, chatID: chat.id, folderName: "Routing QA", hostName: "Disposable host")
                                .environment(account).environment(navigation)
                        } else { limitNotice(chat) }
                        #else
                        limitNotice(chat)
                        #endif
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
