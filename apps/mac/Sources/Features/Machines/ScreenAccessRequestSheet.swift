// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)

import SwiftUI

/// A device is asking to see this screen. Say yes, yes to less, or no.
///
/// A sheet rather than a card somebody has to go and find. This is the one
/// question in the product where the answer decides whether another machine
/// can watch what you are doing, and it arrives while you are looking at
/// something else.
struct ScreenAccessRequestSheet: View {
    let request: ScreenAccessPending
    let model: ScreenAccessRequests

    @State private var isAnswering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                ActionSeat(icon: .preview, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(request.displayName) wants to see this screen")
                        .font(Theme.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(request.control
                        ? "It asked for the picture, and for mouse and keyboard."
                        : "It asked for the picture only.")
                        .font(Theme.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Text("Approve only a device you recognise. Everything it sees is encrypted between the two of them, and you can take this back in Devices at any time.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Capture runs in the app, so tokenstat has to be open for this screen to be shared. The always-on helper keeps terminals and files working, not the screen.")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

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
                // Full access is only offered when it was asked for. Handing
                // mouse and keyboard to a device that only wanted the picture
                // is giving away more than anybody was asked about. Whichever
                // of the two is the answer to the question actually asked is
                // the prominent one.
                if request.control {
                    Button("View only", .preview) { answer(view: true, control: false) }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Full access", .approve) { answer(view: true, control: true) }
                        .buttonStyle(AccentButtonStyle())
                } else {
                    Button("View only", .preview) { answer(view: true, control: false) }
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
