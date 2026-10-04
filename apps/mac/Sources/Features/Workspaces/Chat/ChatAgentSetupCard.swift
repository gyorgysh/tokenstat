// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import SwiftUI

struct AgentSetupStatus: Decodable, Sendable {
    let readiness: String
    /// True when the CLI itself answered. False or absent means the host fell
    /// back to what its files say, which is not enough to stop a send.
    let checked: Bool?
}
private struct AgentSetupAck: Decodable {}

enum AgentSignInCheckOutcome { case signedIn, unconfirmed, needsSignIn, unavailable }

/// Native vector art shares the persona's reduced-motion and visibility gates.
struct AgentSignInArtwork: View {
    var seed: UInt64 = 0
    var ready = false
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 22).fill(Theme.accent.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Theme.accent.opacity(0.20)))
            PersonaMark(seed: seed, size: 58, state: ready ? .ok : .idle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Image(systemName: ready ? "checkmark" : "key.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 25, height: 25)
                .background(ready ? Theme.success : Theme.accent, in: Circle())
                .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 3))
                .offset(x: 3, y: 3)
        }
        .frame(width: 76, height: 76)
        .accessibilityHidden(true)
    }
}

struct AgentSignInSteps: View {
    var step: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3) { index in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(index <= step ? Theme.accent : Theme.border)
                        if index < step {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(index == step ? .white : .secondary)
                        }
                    }.frame(width: 20, height: 20)
                    Text([L10n.text("apple.agentsetup.phase_signin"), L10n.text("apple.agentsetup.phase_confirm"), L10n.text("apple.agentsetup.phase_continue")][index])
                        .font(Theme.caption.weight(index == step ? .semibold : .regular))
                        .foregroundStyle(index == step ? .primary : .secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A single recovery card replaces the CLI refusal beside the saved message.
struct ChatAgentSetupCard: View {
    @Bindable var model: ChatModel
    let backend: ChatBackend
    let running: Bool
    var recoveryFailureID: String? = nil
    @State private var showingSignIn = false
    @State private var checking = false
    @State private var confirmed = false
    @State private var readyFor: String?
    @State private var continuing = false

    private var ready: Bool {
        confirmed && readyFor == recoveryFailureID
            && !(backend.signInVerified && ["needsSignIn", "expired"].contains(backend.readiness ?? ""))
    }

    var body: some View {
        Group {
            if backend.installed != false && backend.id != "sh" &&
                (["needsSignIn", "expired"].contains(backend.readiness ?? "") || recoveryFailureID != nil) {
                AgentSignInPrompt(agent: backend.label, seed: model.faceSeed, ready: ready,
                                  savedMessage: recoveryFailureID != nil, remote: model.peer != nil,
                                  checking: checking, continuing: continuing,
                                  supported: backend.signInFlow?.supported == true,
                                  error: model.backendRefreshError,
                                  signIn: { showingSignIn = true },
                                  check: { Task { _ = await check(explicit: true) } },
                                  continueMessage: {
                    let gate = model.signInGateRowID
                    let owner = model.currentReference
                    Task {
                        continuing = true
                        defer { continuing = false }
                        await model.continueAfterSignIn(gateID: gate, owner: owner)
                    }
                })
                .disabled(running)
            }
        }
        .task(id: "\(backend.id):\(model.peer ?? "local"):\(recoveryFailureID ?? "setup")") {
            if ["claude", "claude_code", "codex"].contains(backend.id) { _ = await check() }
        }
        .sheet(isPresented: $showingSignIn) {
            AgentSignInSheet(backend: backend, peer: model.peer) { await check(explicit: true) }
        }
    }

    private func check(explicit: Bool = false) async -> AgentSignInCheckOutcome {
        guard !checking else { return .unavailable }
        checking = true
        defer { checking = false }
        let owner = model.currentReference
        let offered = recoveryFailureID
        let status = await model.checkSignIn(backend)
        guard owner == model.currentReference, offered == model.signInFailureID,
              model.selected?.backend == backend.id else { return .unavailable }
        guard model.backendRefreshError == nil else { return .unavailable }
        if status?.checked == true, ["needsSignIn", "expired"].contains(status?.readiness ?? "") {
            confirmed = false
            return .needsSignIn
        }
        if status?.checked == true, status?.readiness == "signedIn" {
            confirmed = true
            readyFor = offered
            return .signedIn
        }
        // Older CLIs cannot prove their status. An explicit acknowledgement
        // can offer a retry, but automatic probes never claim a successful login.
        if explicit { confirmed = true; readyFor = offered }
        return .unconfirmed
    }
}

/// Kept independent of the model so every phase can be visually reviewed
/// without launching a provider or sending a real message.
struct AgentSignInPrompt: View {
    let agent: String
    var seed: UInt64 = 0
    var ready = false
    var savedMessage = true
    var remote = false
    var checking = false
    var continuing = false
    var supported = true
    var error: String? = nil
    var signIn: () -> Void = {}
    var check: () -> Void = {}
    var continueMessage: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 18) {
                AgentSignInArtwork(seed: seed, ready: ready)
                VStack(alignment: .leading, spacing: 6) {
                    Text(ready ? L10n.text("apple.agentsetup.ready") : L10n.text("apple.agentsetup.required"))
                        .font(Theme.title3.weight(.semibold))
                    Text(ready ? L10n.text("apple.agentsetup.ready_detail", agent)
                         : (remote ? L10n.text("apple.agentsetup.remote", agent) : L10n.text("apple.agentsetup.local", agent)))
                        .font(Theme.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            AgentSignInSteps(step: ready ? 2 : checking ? 1 : 0)
            if savedMessage {
                Label(L10n.text("apple.agentsetup.message_saved"), systemImage: "bookmark.fill")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                VStack(alignment: .leading, spacing: 10) { actions }
            }
            if !supported {
                Text(L10n.text("apple.agentsetup.legacy", agent)).font(Theme.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.accent.opacity(0.24)))
    }

    @ViewBuilder private var actions: some View {
        if ready && savedMessage {
            Button(continuing ? L10n.text("apple.agentsetup.continuing") : L10n.text("apple.agentsetup.continue_message"), .send, action: continueMessage)
                .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(continuing || checking)
        } else if supported {
            Button(L10n.text("apple.agentsetup.sign_in", agent), .signIn, action: signIn)
                .buttonStyle(AccentButtonStyle(comfortable: true)).disabled(checking)
        }
        if !ready {
            Button(checking ? L10n.text("apple.agentsetup.checking") : L10n.text("apple.agentsetup.check_again"), .refresh, action: check)
                .buttonStyle(SecondaryButtonStyle(comfortable: true)).disabled(checking)
        }
    }
}

/// The provider's real terminal handles browser links, device codes and code
/// paste-back. Nothing is scraped into a chat message or a credential store.
struct AgentSignInSheet: View {
    let backend: ChatBackend
    let peer: String?
    let onCheck: () async -> AgentSignInCheckOutcome
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var error: String?
    @State private var checking = false
    @State private var info: PtySessionInfo?
    @State private var checkMessage: String?
    @State private var starting = false
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
                HStack(alignment: .center, spacing: 16) {
                    AgentSignInArtwork()
                    VStack(alignment: .leading, spacing: 8) {
                        AgentSignInSteps(step: checking ? 1 : 0)
                        Text(L10n.text("apple.agentsetup.step_open"))
                            .font(Theme.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(backend.signInFlow?.kind == "deviceCode" ? L10n.text("apple.agentsetup.step_device")
                     : backend.signInFlow?.kind == "browserCode" ? L10n.text("apple.agentsetup.step_browser")
                     : L10n.text("apple.agentsetup.step_cli"))
                    .font(Theme.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("apple.agentsetup.step_return")).font(Theme.caption).foregroundStyle(.secondary)
                if let checkMessage {
                    Label(checkMessage, systemImage: "info.circle").font(Theme.callout).foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.text("apple.agentsetup.open_failed")).font(Theme.callout)
                        DisclosureGroup(L10n.text("apple.agentsetup.details")) {
                            Text(error).font(Theme.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Button(L10n.text("apple.agentsetup.open_terminal"), .refresh) { Task { await start() } }
                            .buttonStyle(SecondaryButtonStyle(small: true)).disabled(starting)
                    }
                }
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
                    let outcome = await onCheck()
                    checking = false
                    switch outcome {
                    case .signedIn, .unconfirmed: dismiss()
                    case .needsSignIn: checkMessage = L10n.text("apple.agentsetup.not_finished")
                    case .unavailable: checkMessage = L10n.text("apple.agentsetup.check_failed")
                    }
                }
            }.buttonStyle(AccentButtonStyle(comfortable: true)).disabled(checking || info == nil)
        }
        .modalFrame(width: 860, height: 740)
        .task { await start() }
        .onDisappear { close() }
    }

    private func start() async {
        guard !starting, info == nil, let id = backend.launcherID else { return }
        starting = true
        error = nil
        defer { starting = false }
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
