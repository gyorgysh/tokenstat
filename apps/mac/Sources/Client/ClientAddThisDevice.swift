// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// Letting this device into a machine nobody is sitting at.
///
/// Being on the account is not being allowed in, and on a server there is
/// nobody at the machine to answer a request. So the machine mints a code at
/// its own console and this screen redeems it. Three states and no more:
/// waiting for a code, refused, and granted.
///
/// The refusal copy distinguishes expired from wrong on purpose. Somebody who
/// is told only "that code is not right" retypes a code that was correct a
/// minute ago, forever.
struct ClientAddThisDevice: View {
    let peer: String
    let hostName: String
    /// Called once the machine has said yes, so the screen behind can load.
    var onGranted: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var working = false
    @State private var granted = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var visible = false

    private var normalized: String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ClientEmptyArt(kind: granted ? .serverReady : .workspaceAccess)
                    .frame(maxWidth: .infinity)
                Text(granted ? L10n.text("apple.clientaddthisdevice.you_are_in.0c6dac04") : L10n.text("apple.clientaddthisdevice.add_this_device.c93a44d1"))
                    .font(Theme.title.weight(.semibold))
                Text(LocalizedStringKey(granted
                    ? L10n.text("apple.clientaddthisdevice.0_has_let_this_device_open_its_work.cd7156ad", "\(hostName)")
                    : L10n.text("apple.clientaddthisdevice.on_0_run_tokenstat_host_access_invite_it_p.b7c9caf7", "\(hostName)")
                    + L10n.text("apple.clientaddthisdevice.good_for_fifteen_minutes_and_for_one_devic.514498e6")))
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                if !granted {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        TextField(L10n.text("apple.clientaddthisdevice.wxyz_2345.5e7774a6"), text: $code)
                            .textFieldStyle(.themed)
                            .font(Theme.monoText(20, relativeTo: .title3))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .disabled(working)
                        Text(
                            L10n.text("apple.clientaddthisdevice.the_machine_checks_this_code_over_your_enc.c96bb0a1")
                        )
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .navigationTitle(L10n.text("apple.clientaddthisdevice.add_this_device.c93a44d1"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Space.s) {
                if granted {
                    Button(L10n.text("apple.clientaddthisdevice.open_0.e71b4013", "\(hostName)"), .next) {
                        onGranted?()
                        dismiss()
                    }
                    .clientProminentStyle()
                } else {
                    Button(working ? L10n.text("apple.clientaddthisdevice.checking.ec963ffc") : L10n.text("apple.clientaddthisdevice.use_this_code.34617e30"), .approve) {
                        Task { await redeem() }
                    }
                    .clientProminentStyle()
                    .disabled(working || normalized.count != 8)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity)
            .background(Theme.background)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; reset() }
        .onChange(of: WorkSessionContext.shared.scope) { _, _ in reset() }
    }

    private func reset() {
        generation = UUID()
        code = ""
        working = false
        granted = false
        error = nil
    }

    private func redeem() async {
        guard visible, !working, let scope = WorkSessionContext.shared.scope, scope.kind == .account else { return }
        let attempt = generation
        working = true
        error = nil
        defer { if generation == attempt { working = false } }
        do {
            let accepted = try await Bridge.redeemWorkspaceAccess(peer: peer, code: normalized)
            guard generation == attempt, WorkSessionContext.shared.scope == scope, !Task.isCancelled else { return }
            granted = accepted
        } catch {
            guard generation == attempt, WorkSessionContext.shared.scope == scope, !Task.isCancelled else { return }
            self.error = ClientSetupModel.readable(error)
        }
    }
}

#endif
