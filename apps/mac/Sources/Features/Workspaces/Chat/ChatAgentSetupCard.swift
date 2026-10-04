// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct AgentSetupStatus: Decodable, Sendable {
    let readiness: String
    /// True when the CLI itself answered. False or absent means the host fell
    /// back to what its files say, which is not enough to stop a send.
    let checked: Bool?
}
private struct AgentSetupAck: Decodable {}

/// Setup stays beside the unsent draft, including on a remote host.
struct ChatAgentSetupCard: View {
    @Bindable var model: ChatModel
    let backend: ChatBackend
    let running: Bool
    @State private var showingSignIn = false
    @State private var checking = false

    var body: some View {
        Group {
            // Only a state with a next step. Many agents keep their login
            // where nothing can read it and are always "unknown", and a
            // banner over every one of those chats would be noise.
            if backend.installed != false && backend.id != "sh" && ["needsSignIn", "expired"].contains(backend.readiness ?? "") {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Label(backend.readiness == "expired"
                          ? L10n.text("apple.agentsetup.expired", backend.label)
                          : backend.readiness == "needsSignIn"
                          ? L10n.text("apple.agentsetup.sign_in", backend.label)
                          : L10n.text("apple.agentsetup.check_setup", backend.label), systemImage: "person.crop.circle.badge.key")
                        .font(Theme.callout.weight(.semibold))
                    Text(model.peer == nil ? L10n.text("apple.agentsetup.local") : L10n.text("apple.agentsetup.remote"))
                        .font(Theme.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if backend.signInFlow?.supported == true {
                            Button(L10n.text("apple.agentsetup.open_terminal"), .signIn) { showingSignIn = true }
                                .buttonStyle(SecondaryButtonStyle(small: true))
                                .disabled(running || checking)
                        }
                        Button(checking ? L10n.text("apple.agentsetup.checking") : L10n.text("apple.agentsetup.check_again"), .refresh) {
                            Task { await check() }
                        }.buttonStyle(SecondaryButtonStyle(small: true)).disabled(checking || running)
                    }
                    if backend.signInFlow?.supported != true {
                        Text(L10n.text("apple.agentsetup.legacy", backend.label)).font(Theme.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.backendRefreshError {
                        Text(error).font(Theme.caption).foregroundStyle(Theme.warning)
                    }
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            }
        }
        .task(id: "\(backend.id):\(model.peer ?? "local")") {
            if ["claude", "claude_code", "codex"].contains(backend.id) { await check() }
        }
        .sheet(isPresented: $showingSignIn, onDismiss: signInDismissed) {
            AgentSignInSheet(backend: backend, peer: model.peer) {
                await model.reloadBackends()
                await check()
            }
        }
    }

    private func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        await model.checkSignIn(backend)
    }

    private func signInDismissed() { Task { await check() } }
}

/// The provider's real terminal handles browser links, device codes and code
/// paste-back. Nothing is scraped into a chat message or a credential store.
struct AgentSignInSheet: View {
    let backend: ChatBackend
    let peer: String?
    let onCheck: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var error: String?
    @State private var checking = false
    @State private var info: PtySessionInfo?
    #if os(macOS)
    @State private var terminal: TerminalSession?
    #else
    @State private var terminal: ClientTerminalSession?
    #endif

    var body: some View {
        ThemedSheet(title: L10n.text("apple.agentsetup.setup_title", backend.label),
                    subtitle: peer == nil ? L10n.text("apple.agentsetup.this_computer") : L10n.text("apple.agentsetup.chat_host"),
                    icon: .signIn, scrolls: scrolls, fills: true, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(L10n.text("apple.agentsetup.step_open")).font(Theme.callout)
                Text(backend.signInFlow?.kind == "deviceCode" ? L10n.text("apple.agentsetup.step_device")
                     : backend.signInFlow?.kind == "browserCode" ? L10n.text("apple.agentsetup.step_browser")
                     : L10n.text("apple.agentsetup.step_cli"))
                    .font(Theme.callout).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("apple.agentsetup.step_return")).font(Theme.callout)
                if let error { Text(error).font(Theme.caption).foregroundStyle(Theme.warning).textSelection(.enabled) }
                if let terminal {
                    #if os(macOS)
                    TerminalViewRepresentable(session: terminal).id(terminal.id)
                        .frame(minHeight: 240)
                        .onAppear {
                            DispatchQueue.main.async { terminal.view.window?.makeFirstResponder(terminal.view) }
                        }
                    #else
                    ClientTerminalRepresentable(session: terminal).id(terminal.id)
                        .frame(minHeight: 240)
                    ClientTerminalKeys(send: { terminal.sendBytes($0) }, toggleKeyboard: { terminal.toggleKeyboard() },
                                       scrolls: Binding(get: { terminal.scrolls }, set: { terminal.scrolls = $0 }),
                                       control: Binding(get: { terminal.controlArmed }, set: { terminal.controlArmed = $0 }))
                    #endif
                } else if error == nil {
                    ProgressView(L10n.text("apple.agentsetup.starting"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } actions: {
            Button(L10n.text("common.close"), .dismiss) { dismiss() }
                .buttonStyle(SecondaryButtonStyle(comfortable: true))
            Button(checking ? L10n.text("apple.agentsetup.checking") : L10n.text("apple.agentsetup.finished"), .refresh) {
                Task {
                    checking = true
                    await onCheck()
                    checking = false
                    dismiss()
                }
            }.buttonStyle(AccentButtonStyle(comfortable: true)).disabled(checking || info == nil)
        }
        .modalFrame(width: 860, height: 620)
        .task { await start() }
        .onDisappear { close() }
    }

    private func start() async {
        guard let id = backend.launcherID else { return }
        do {
            var started = try await Bridge.agentSetupSignIn(peer: peer, id: id, dark: colorScheme == .dark)
            if Task.isCancelled {
                if let peer { let _: AgentSetupAck? = try? await Bridge.onPeer(peer, "pty.close", ["id": started.id], as: AgentSetupAck.self) }
                else { try? await Bridge.ptyClose(id: started.id) }
                return
            }
            info = started
            #if os(macOS)
            if let peer { started.id = "remote:\(peer):\(started.id)" }
            let session = TerminalSession(info: started)
            session.isFocused = true
            terminal = session
            #else
            if let peer { terminal = ClientTerminalSession(peer: peer, info: started) }
            #endif
        } catch { self.error = error.localizedDescription }
    }

    private var scrolls: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

    private func close() {
        terminal?.stop()
        guard let info else { return }
        let peer = peer
        Task {
            if let peer { let _: AgentSetupAck? = try? await Bridge.onPeer(peer, "pty.close", ["id": info.id], as: AgentSetupAck.self) }
            else { try? await Bridge.ptyClose(id: info.id) }
        }
    }
}
