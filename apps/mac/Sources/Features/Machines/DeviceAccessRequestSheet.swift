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
/// Opened from the sidebar card, from a notification, or from Devices, and
/// never on its own: the question waits in the corner until somebody goes to
/// it. Once it is open it is a sheet, because the answer decides whether
/// another machine can watch this screen or open every file on it.
///
/// The whole surface is painted in the app's own colours. A sheet that leaves
/// its background to the system draws the platform's grey, which is the one
/// tone this product never uses.
struct DeviceAccessRequestSheet: View {
    let request: DeviceAccessPending
    let model: DeviceAccessRequests

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnswering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            header
            DeviceAccessScene(kind: request.kind, reduceMotion: reduceMotion)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Approve only a device you recognise. Everything it reaches is encrypted between the two of them, and you can take this back in Devices at any time.")
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(scope)
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
            Spacer(minLength: 0)
            answers
        }
        .padding(Theme.Space.xl)
        .frame(width: 520, height: 460)
        // Painted, not inherited. See the type comment.
        .background(Theme.panel)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            ActionSeat(icon: request.kind == .screen ? .preview : .reveal, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(request.headline)
                    .font(Theme.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(request.detail)
                    .font(Theme.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var scope: String {
        switch request.kind {
        case .screen:
            return "Capture runs in the app, so tokenstat has to be open for this screen to be shared. The always-on helper keeps terminals and files working, not the screen."
        case .workspace:
            return "It will be able to read and change files in your workspaces, start terminals and agents, and commit and push. It cannot reach anything outside the folders you have added."
        }
    }

    private var answers: some View {
        HStack(spacing: Theme.Space.s) {
            Button("Deny", .revoke, role: .destructive) { answer(view: false, control: false) }
                .buttonStyle(SecondaryButtonStyle())
            Spacer(minLength: Theme.Space.s)
            // Both answers, always, for a screen. Offering only what the
            // device happened to ask for left no way to hand over the mouse
            // without making somebody go back to their phone and ask again for
            // the wider thing, which is a dead end rather than a safeguard.
            // The person at this machine is the one deciding, so they get the
            // whole decision.
            if request.kind == .screen {
                Button("View only", .preview) { answer(view: true, control: false) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Full access", .approve) { answer(view: true, control: true) }
                    .buttonStyle(AccentButtonStyle())
            } else {
                Button("Allow", .approve) { answer(view: true, control: false) }
                    .buttonStyle(AccentButtonStyle())
            }
        }
        .disabled(isAnswering)
    }

    private func answer(view: Bool, control: Bool) {
        isAnswering = true
        Task {
            await model.answer(request, view: view, control: control)
            isAnswering = false
        }
    }
}

/// The picture over the question: a device reaching for a machine.
///
/// The rules the client's empty-state art follows, in the app's own colours:
/// one stroke weight, one small loop, and a resting frame that Reduce Motion
/// lands on and stays at.
private struct DeviceAccessScene: View {
    let kind: DeviceAccessKind
    let reduceMotion: Bool

    @State private var reaching = false

    private var style: StrokeStyle {
        StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
    }

    var body: some View {
        ZStack {
            // The machine being asked.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.border, style: style)
                .frame(width: 96, height: 62)
                .overlay {
                    Image(systemName: kind == .screen ? "eye" : "folder")
                        .font(Theme.fixed(20))
                        .foregroundStyle(Theme.accent.opacity(0.65))
                }
                .offset(x: -58)

            // The device doing the asking.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.border, style: style)
                .frame(width: 38, height: 62)
                .offset(x: 78)

            // Three steps closing the gap, one after another, so the picture
            // reads as a request travelling rather than a thing blinking.
            HStack(spacing: 9) {
                ForEach(0..<3, id: \.self) { step in
                    Circle()
                        .fill(step == 1 ? Theme.secondary : Theme.accent)
                        .frame(width: 6, height: 6)
                        .opacity(reaching ? 1 : 0.25)
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeInOut(duration: 1.1)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(2 - step) * 0.22),
                            value: reaching
                        )
                }
            }
            .offset(x: 20)
        }
        .frame(height: 96)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            reaching = true
        }
    }
}

#endif
