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
/// Opened when a request arrives, from the sidebar card, from a notification,
/// or from Devices. Once it is open it is a sheet, because the answer decides
/// whether another machine can watch this screen or open every file on it.
///
/// The whole surface is painted in the app's own colours. A sheet that leaves
/// its background to the system draws the platform's grey, which is the one
/// tone this product never uses.
struct DeviceAccessRequestSheet: View {
    let request: DeviceAccessPending
    let model: DeviceAccessRequests

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnswering = false
    @State private var selection = DeviceAccessSelection()
    @State private var original = DeviceAccessSelection()
    @State private var loaded = false
    @State private var loadError: String?

    var body: some View {
        ThemedSheet(
            title: request.headline,
            subtitle: request.detail,
            icon: request.kind == .screen ? .preview : .reveal,
            scrolls: true,
            onClose: { deny() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                DeviceAccessScene(kind: request.kind, reduceMotion: reduceMotion)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(L10n.text("apple.deviceaccessrequestsheet.approve_only_a_device_you_recognise_everyt.97e32c7d"))
                        .font(Theme.callout)
                        .foregroundStyle(Theme.controlGlyph)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if loaded {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        Toggle(L10n.text("apple.deviceaccessrequestsheet.open_projects"), isOn: $selection.workspace)
                            .frame(minHeight: 44)
                        Text(L10n.text("apple.deviceaccessrequestsheet.it_will_be_able_to_read_and_change_files_i.511878d6"))
                            .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                        Toggle(L10n.text("apple.deviceaccessrequestsheet.view_screen"), isOn: $selection.view)
                            .frame(minHeight: 44)
                        Toggle(L10n.text("apple.deviceaccessrequestsheet.control_screen"), isOn: $selection.control)
                            .frame(minHeight: 44)
                            .disabled(!selection.view)
                        Text(L10n.text("apple.deviceaccessrequestsheet.capture_runs_in_the_app_so_tokenstat_has_t.e2be3644"))
                            .font(Theme.caption).foregroundStyle(Theme.controlGlyph)
                    }
                    .onChange(of: selection.view) { _, view in
                        if !view { selection.control = false }
                    }
                } else if loadError == nil {
                    ProgressView()
                }
                if let loadError {
                    Text(loadError).font(Theme.caption).foregroundStyle(Theme.danger)
                    Button(L10n.text("common.retry"), .refresh) { Task { await loadSelection() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if let error = model.errorMessage {
                    Text(error)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            answers
        }
        // The choices scroll at larger text sizes while the decision buttons
        // remain visible in the footer.
        .frame(width: 540)
        .frame(minHeight: 520)
        .background(Theme.background)
        .presentationBackground(Theme.background)
        .task(id: "\(request.id):\(request.askedAt)") { await loadSelection() }
    }

    private var answers: some View {
        HStack(spacing: Theme.Space.s) {
            Button(L10n.text("apple.deviceaccessrequestsheet.deny.05a2d733"), .revoke, role: .destructive) { deny() }
                .buttonStyle(SecondaryButtonStyle())
            Spacer(minLength: Theme.Space.s)
            Button(L10n.text("apple.deviceaccessrequestsheet.allow_selected"), .approve) { apply() }
                .buttonStyle(AccentButtonStyle())
                .disabled(!loaded || !(selection.workspace || selection.view))
        }
        .disabled(isAnswering || model.answeringIDs.contains(request.id))
    }

    private func loadSelection() async {
        loaded = false; loadError = nil
        do {
            async let workspaces = Bridge.workspaceAccessList()
            async let screens = Bridge.screenPermissions()
            let workspace = (try await workspaces).contains(request.peerID)
            let screen = (try await screens).first { $0.peerID == request.peerID }
            guard !Task.isCancelled else { return }
            let loadedSelection = DeviceAccessSelection(workspace: workspace,
                view: screen?.view == true, control: screen?.control == true)
            selection = loadedSelection
            original = loadedSelection
            loaded = true
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }

    private func apply() {
        isAnswering = true
        Task {
            await model.answerConfigured(request, selection: selection, original: original)
            isAnswering = false
            if model.errorMessage != nil { await loadSelection() }
        }
    }

    private func deny() {
        isAnswering = true
        Task {
            await model.denyPending(request)
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
