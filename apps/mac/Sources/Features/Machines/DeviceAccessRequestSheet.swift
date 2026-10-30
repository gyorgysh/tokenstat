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
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if loaded {
                    DeviceAccessChoices(selection: $selection)
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
        // Every choice fits at the normal type size; larger text scrolls in
        // the body while the decision buttons remain fixed and visible.
        .modalFrame(width: 600, height: 560)
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
            var proposed = loadedSelection
            switch request.kind {
            case .workspace: proposed.workspace = true
            case .screen:
                proposed.view = true
                if request.control { proposed.control = true }
            }
            selection = proposed
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

private struct DeviceAccessChoices: View {
    @Binding var selection: DeviceAccessSelection

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(L10n.text("apple.deviceaccessrequestsheet.choose_access"))
                .font(Theme.callout.weight(.semibold))
            VStack(spacing: 0) {
                permissionRow(
                    L10n.text("apple.deviceaccessrequestsheet.open_projects"),
                    detail: L10n.text("apple.deviceaccessrequestsheet.projects_detail"),
                    isOn: $selection.workspace
                )
                ThemeRule()
                permissionRow(
                    L10n.text("apple.deviceaccessrequestsheet.view_screen"),
                    detail: L10n.text("apple.deviceaccessrequestsheet.view_detail"),
                    isOn: $selection.view
                )
                ThemeRule()
                permissionRow(
                    L10n.text("apple.deviceaccessrequestsheet.control_screen"),
                    detail: L10n.text("apple.deviceaccessrequestsheet.control_detail"),
                    isOn: $selection.control
                )
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
            .onChange(of: selection.view) { _, view in
                if !view { selection.control = false }
            }
            .onChange(of: selection.control) { _, control in
                if control { selection.view = true }
            }
            Text(L10n.text("apple.deviceaccessrequestsheet.security_note"))
                .font(Theme.caption)
                .foregroundStyle(Theme.controlGlyph)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title)
                    .font(Theme.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.checkbox)
        .frame(minHeight: 64)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.xs)
    }
}

#Preview("Device access") {
    @Previewable @State var selection = DeviceAccessSelection(workspace: true)
    ThemedSheet(
        title: "Android phone wants to open your work",
        subtitle: "Folders, files, terminals and the agents running in them.",
        icon: .reveal,
        scrolls: true,
        onClose: {}
    ) {
        DeviceAccessChoices(selection: $selection)
    } actions: {
        HStack {
            Button("Deny") {}
                .buttonStyle(SecondaryButtonStyle())
            Spacer()
            Button("Allow selected access") {}
                .buttonStyle(AccentButtonStyle())
        }
    }
    .modalFrame(width: 600, height: 560)
}

#endif
