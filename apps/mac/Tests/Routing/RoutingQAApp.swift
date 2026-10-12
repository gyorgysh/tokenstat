// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Separate simulator app; never included in a shipping target.
import SwiftUI
#if os(iOS)
import SwiftTerm
import UIKit
#endif

@main struct RoutingQAApp: App {
    @State private var model = ChatModel()
    @State private var screen = "Settings"
    #if os(iOS)
    @State private var account = AccountModel()
    @State private var navigation = ClientNavigationModel()
    @State private var connectivity = ConnectivityModel()
    @State private var inputSearch = ""
    @State private var inputCode = ""
    @State private var terminalQA: TerminalTypingQA?
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
                    Text("Inputs").tag("Inputs")
                    Text("Terminal").tag("Terminal")
                    #endif
                }.pickerStyle(.segmented).padding(Theme.Space.m)
                #if os(iOS)
                if screen == "Terminal", let terminalQA {
                    VStack(spacing: 0) {
                        HStack {
                            Button("Measure typing") { terminalQA.measure() }
                            Text("Frame changes: \(terminalQA.frameChanges)")
                                .accessibilityIdentifier("terminal.frameChanges")
                        }.font(Theme.caption)
                        ClientTerminalScreen(session: terminalQA.session)
                            .environment(account).environment(navigation)
                    }
                } else if screen == "Inputs" {
                    ThemedSheet(title: "Keyboard QA", subtitle: "Search and numeric input preview", onClose: {}) {
                        VStack(spacing: Theme.Space.m) {
                            TextField("Search", text: $inputSearch)
                                .textFieldStyle(.themed)
                                .accessibilityIdentifier("keyboard.searchField")
                            TextField("Code", text: $inputCode)
                                .textFieldStyle(.themed)
                                .keyboardType(.numberPad)
                                .accessibilityIdentifier("keyboard.codeField")
                        }
                    }
                } else {
                    conversation
                }
                #else
                conversation
                #endif
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
                    #if os(iOS)
                    terminalQA = TerminalTypingQA()
                    #endif
                    await model.load(workspaceID: fixture["workspaceId"]!)
                    if let chat = model.chats.first(where: { $0.id == fixture["conversationId"] }) {
                        await model.select(chat)
                    }
                } catch { model.error = error.localizedDescription }
            }
        }
    }

    @ViewBuilder private var conversation: some View {
        if let chat = model.selected {
            if screen == "Settings" {
                ChatInspector(model: model, folder: nil, onClose: {}, showsHeader: false)
            } else {
                #if os(iOS)
                if screen == "Conversation" {
                    ClientChatThread(model: model, chatID: chat.id, folderName: "Routing QA", hostName: "Disposable host")
                        .environment(account).environment(navigation).environment(connectivity)
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
}

#if os(iOS)
/// Real production screen and UIKit text input, with a local TUI echo instead
/// of a provider or network. Samples every display frame, including transient
/// motion that a screenshot after typing could miss.
@Observable @MainActor
private final class TerminalTypingQA: NSObject, TerminalViewDelegate {
    let session = ClientTerminalSession(peer: "", pendingCommand: "QA terminal", cwd: "/QA", rows: 24, cols: 80)
    var frameChanges = 0
    private var baseline: CGRect?
    private var display: Timer?
    private var keyboardObserver: NSObjectProtocol?
    private var input = ""

    override init() {
        super.init()
        session.view.accessibilityIdentifier = "terminal.qa"
        session.view.terminalDelegate = self
        session.view.feedOutput("\u{1b}[?1049h\u{1b}[2 q\u{1b}[2J\u{1b}[HLocal terminal typing QA\r\n> ")
        display = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.measure() }
        }
    }

    func measure() {
        frameChanges = 0
        baseline = session.view.convert(session.view.bounds, to: nil)
    }
    private func sample() {
        guard let baseline, session.view.window != nil else { return }
        let current = session.view.convert(session.view.bounds, to: nil)
        if abs(current.minY - baseline.minY) > 1 || abs(current.height - baseline.height) > 1 {
            frameChanges += 1
            self.baseline = current
        }
    }
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        Task { @MainActor in
            input += String(decoding: bytes, as: UTF8.self)
            // Exercise the real write-error/recovery layout on successive
            // keys, as well as cursor-only TUI redraws.
            session.transportError = input.count.isMultiple(of: 2) ? nil : "QA transient write failure"
            session.view.feedOutput("\u{1b}[2;1H\u{1b}[2K> " + input)
        }
    }
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
    nonisolated func bell(source: TerminalView) {}
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif
