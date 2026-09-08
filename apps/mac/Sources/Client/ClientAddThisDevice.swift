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

    private var normalized: String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ClientEmptyArt(kind: granted ? .serverReady : .workspaceAccess)
                    .frame(maxWidth: .infinity)
                Text(granted ? "You are in" : "Add this device")
                    .font(Theme.title.weight(.semibold))
                Text(granted
                    ? "\(hostName) has let this device open its work."
                    : "On \(hostName), run `tokenstat host access invite`. It prints one code, "
                    + "good for fifteen minutes and for one device.")
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                if !granted {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        TextField("WXYZ-2345", text: $code)
                            .textFieldStyle(.themed)
                            .font(.system(.title3, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Text(
                            "The code never leaves the machine that made it. tokenstat.ai "
                            + "cannot see it and cannot let a device in."
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
        .navigationTitle("Add this device")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Space.s) {
                if granted {
                    Button("Open \(hostName)", .next) {
                        onGranted?()
                        dismiss()
                    }
                    .clientProminentStyle()
                } else {
                    Button(working ? "Checking…" : "Use this code", .approve) {
                        Task { await redeem() }
                    }
                    .clientProminentStyle()
                    .disabled(working || normalized.count != 8)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func redeem() async {
        working = true
        error = nil
        defer { working = false }
        do {
            granted = try await Bridge.redeemWorkspaceAccess(peer: peer, code: normalized)
        } catch {
            self.error = ClientSetupModel.readable(error)
        }
    }
}

#endif
