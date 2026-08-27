// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)

import SwiftUI

/// A device is asking for something. Say yes, yes to less, or no.
///
/// Opened from the toast, from its notification, or from Devices, and never on
/// its own: the question is worth answering, not worth stopping what somebody
/// was doing. Once it is open it is a sheet, because the answer decides
/// whether another machine can watch this screen or open every file on it.
struct DeviceAccessRequestSheet: View {
    let request: DeviceAccessPending
    let model: DeviceAccessRequests

    @State private var isAnswering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                ActionSeat(icon: request.kind == .screen ? .preview : .reveal, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.headline)
                        .font(Theme.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(request.detail)
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Text("Approve only a device you recognise. Everything it reaches is encrypted between the two of them, and you can take this back in Devices at any time.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if request.kind == .screen {
                Text("Capture runs in the app, so tokenstat has to be open for this screen to be shared. The always-on helper keeps terminals and files working, not the screen.")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("It will be able to read and change files in your workspaces, start terminals and agents, and commit and push. It cannot reach anything outside the folders you have added.")
                    .font(Theme.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Theme.Space.s) {
                Button("Deny", .revoke, role: .destructive) {
                    answer(view: false, control: false)
                }
                .buttonStyle(SecondaryButtonStyle())
                Spacer(minLength: Theme.Space.s)
                // Control is only offered when it was asked for. Handing mouse
                // and keyboard to a device that only wanted the picture is
                // giving away more than anybody was asked about. Workspace
                // access has no half, so it is one button.
                if request.control {
                    Button("View only", .preview) { answer(view: true, control: false) }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Full access", .approve) { answer(view: true, control: true) }
                        .buttonStyle(AccentButtonStyle())
                } else {
                    Button(request.kind == .screen ? "View only" : "Allow", .approve) {
                        answer(view: true, control: false)
                    }
                    .buttonStyle(AccentButtonStyle())
                }
            }
            .disabled(isAnswering)
        }
        .padding(Theme.Space.l)
        .frame(width: 460)
    }

    private func answer(view: Bool, control: Bool) {
        isAnswering = true
        Task {
            await model.answer(request, view: view, control: control)
            isAnswering = false
        }
    }
}

#endif
