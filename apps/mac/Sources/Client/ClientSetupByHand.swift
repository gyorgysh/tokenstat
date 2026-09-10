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
                    Text("Run it yourself")
                        .font(Theme.title.weight(.semibold))
                    Text(
                        "Paste this into a terminal on the server. tokenstat waits here for "
                        + "the machine to appear on your account."
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
                    Text("Preparing the command…")
                        .font(ClientType.label)
                        .foregroundStyle(.secondary)
                }
                Text(
                    "The machine signs itself in with that code, and lets this device open "
                    + "its work. Nothing about it goes through a browser."
                )
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                SetupActions {
                    Button(copied ? "Copied" : "Copy the command", copied ? ActionIcon.done : .copy) {
                        guard let line else { return }
                        UIPasteboard.general.string = line.oneLine
                        copied = true
                    }
                    .setupPrimaryStyle()
                    .disabled(line == nil || working)
                    Button("Generate a new code", .refresh) {
                        line = nil
                        code = nil
                        copied = false
                        Task { await prepare() }
                    }
                    .font(ClientType.label)
                    .disabled(working)
                    Button("I ran it, check my account", .next) {
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
        .navigationTitle("By hand")
        .navigationBarTitleDisplayMode(.inline)

        .task { await prepare() }
        .onDisappear {
            generation = UUID()
            working = false
        }
    }

    private func codeCard(_ code: PairingCode) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Your pairing code")
                .font(ClientType.label.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(code.code)
                .font(Theme.monoText(22, weight: .semibold, relativeTo: .title2))
                .textSelection(.enabled)
            Text(
                "Good for \(code.expiresIn / 60) minutes and for one machine. It is already "
                + "in the command below."
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
            Text("On the server")
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
