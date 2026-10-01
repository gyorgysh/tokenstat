// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)
import UIKit

/// The same install, run by the person instead of by the app.
///
/// Not a lesser path. Handing an app an SSH key is a reasonable thing to
/// decline for a server that matters, and the line already exists, so the
/// whole cost of offering it is one screen. It is also the fallback whenever
/// the SSH path fails for a reason tokenstat cannot fix: a bastion, an
/// agent-forwarded key, or a provider console that is the only way in.
///
/// The pairing code is on screen here, and that is acceptable only because it
/// is single use and short lived. Do not extend its life to make this screen
/// nicer.
struct ClientSetupByHand: View {
    @Bindable var model: ClientSetupModel
    @Binding var path: [SetupStep]

    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss

    @State private var code: PairingCode?
    @State private var line: InstallLine?
    @State private var working = false
    @State private var error: String?
    @State private var copied = false
    @State private var generation = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(spacing: Theme.Space.s) {
                    ClientEmptyArt(kind: .byHand)
                    Text(L10n.text("apple.clientsetupbyhand.run_it_yourself.b3ab2275"))
                        .font(Theme.title.weight(.semibold))
                    Text(
                        L10n.text("apple.clientsetupbyhand.paste_this_into_a_terminal_on_the_server_t.f90ccb47")
                    )
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                if let code {
                    codeCard(code)
                }
                if let line {
                    commandCard(line)
                } else if working {
                    Text(L10n.text("apple.clientsetupbyhand.preparing_the_command.dc40c381"))
                        .font(ClientType.label)
                        .foregroundStyle(.secondary)
                }
                Text(
                    L10n.text("apple.clientsetupbyhand.the_machine_signs_itself_in_with_that_code.63c89f28")
                )
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                SetupActions {
                    Button(copied ? L10n.text("apple.clientsetupbyhand.copied.8d525e5f") : L10n.text("apple.clientsetupbyhand.copy_the_command.5a677843"), copied ? ActionIcon.done : .copy) {
                        guard let line else { return }
                        UIPasteboard.general.string = line.oneLine
                        copied = true
                    }
                    .setupPrimaryStyle()
                    .disabled(line == nil || working)
                    Button(L10n.text("apple.clientsetupbyhand.generate_a_new_code.01dcaf62"), .refresh) {
                        line = nil
                        code = nil
                        copied = false
                        Task { await prepare() }
                    }
                    .font(ClientType.label)
                    .disabled(working)
                    Button(L10n.text("apple.clientsetupbyhand.i_ran_it_check_my_account.db748611"), .next) {
                        model.manualInstall = true
                        model.expectedPeer = nil
                        path.append(.finish)
                    }
                        .font(ClientType.label)
                }
            }
            .padding(Theme.Space.m)
            .setupColumn()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .navigationTitle(L10n.text("apple.clientsetupbyhand.by_hand.573ad125"))
        .navigationBarTitleDisplayMode(.inline)

        .task { await prepare() }
        .onDisappear {
            generation = UUID()
            working = false
        }
    }

    private func codeCard(_ code: PairingCode) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.clientsetupbyhand.your_pairing_code.4385c97f"))
                .font(ClientType.label.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(code.code)
                .font(Theme.monoText(22, weight: .semibold, relativeTo: .title2))
                .textSelection(.enabled)
            Text(
                L10n.text("apple.clientsetupbyhand.good_for_0_minutes_and_for_one_machine_it.ee887227", "\(code.expiresIn / 60)")
            )
            .font(ClientType.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// The annotated form, because this one is read as well as run.
    private func commandCard(_ line: InstallLine) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(L10n.text("apple.clientsetupbyhand.on_the_server.3f5514e0"))
                .font(ClientType.label.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(line.annotated)
                    .font(Theme.monoText(13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func prepare() async {
        guard line == nil, !working, let scope = model.activeScope else { return }
        let request = UUID()
        generation = request
        func isCurrent() -> Bool {
            !Task.isCancelled && generation == request && model.activeScope == scope
        }
        working = true
        error = nil
        defer { if generation == request { working = false } }
        do {
            try await model.chooseAvailableMachineName()
            guard isCurrent() else { return }
            let key = try await Bridge.machineIdentity().key
            guard isCurrent() else { return }
            model.prepareManualInstall()
            let minted = try await Bridge.mintPairingCode()
            guard isCurrent() else { return }
            let preparedLine = try await Bridge.installLine(
                allow: key,
                name: model.machineName.isEmpty ? nil : model.machineName,
                agents: model.agents,
                printInvite: false,
                codeFile: false,
                code: minted.code
            )
            guard isCurrent() else { return }
            code = minted
            line = preparedLine
        } catch {
            guard isCurrent() else { return }
            self.error = ClientSetupModel.readable(error)
        }
    }
}

#endif
