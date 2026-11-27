// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if os(macOS)
import AppKit

struct SSHSessionInspector: View {
    let model: SSHLibraryModel
    @Bindable var sessions: SSHSessionsModel
    let hostID: String
    var onClose: () -> Void

    @State private var asking: SSHSnippet?
    @State private var editing: SSHLibraryRoute?
    @State private var deleting: SSHSnippet?

    private var host: SSHHost? { model.hosts.first { $0.id == hostID } }
    private var available: [SSHSnippet] { model.snippets(for: hostID) }

    private var target: SSHLiveTerminal? {
        guard let active = sessions.activeSession(for: hostID), active.alive else { return nil }
        return active
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorChromeBar(onClose: onClose) {
                accessory
            } content: {
                if editing != nil {
                    Button(L10n.text("apple.sshsessioninspector.snippets.ff717209"), .back) { editing = nil }
                        .buttonStyle(QuietLinkStyle())
                        .padding(.leading, Theme.Space.s)
                } else {
                    InspectorTitle(title: L10n.text("apple.sshsessioninspector.snippets.ff717209"), symbol: "text.badge.plus")
                }
                Spacer(minLength: 0)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .desktopPaneBackground()
        .sheet(item: $asking) { snippet in
            SSHSnippetRunSheet(snippet: snippet) { command in type(command) }
        }
        .onChange(of: hostID) { _, _ in
            editing = nil
            asking = nil
            deleting = nil
        }
        .confirmationDialog(
            L10n.text("apple.sshsessioninspector.delete_this_snippet.58a04ce8"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.text("common.delete"), role: .destructive) {
                guard let doomed = deleting else { return }
                deleting = nil
                Task { await model.delete(snippet: doomed) }
            }
            Button(L10n.text("common.cancel"), role: .cancel) { deleting = nil }
        } message: {
            Text(L10n.text("apple.sshsessioninspector.it_is_removed_from_every_device_signed_in.49df64ed"))
        }
    }

    @ViewBuilder
    private var accessory: some View {
        if editing == nil, let host {
            Button(L10n.text("apple.sshsessioninspector.server_settings.3e8fb11e"), .settings) { editing = .host(host.id) }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .padding(.trailing, Theme.Space.xs)
                .help(L10n.text("apple.sshsessioninspector.address_authentication_and_settings_for_0.993a6dcc", "\(host.label)"))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch editing {
        case let .host(id):
            SSHHostEditor(model: model, hostID: id, folderID: nil) { editing = nil }.id(id)
        case let .snippet(id):
            SSHSnippetEditor(model: model, snippetID: id) { editing = nil }.id(id)
        case .newSnippet:
            SSHSnippetEditor(model: model, snippetID: nil) { editing = nil }
        default:
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        if available.isEmpty {
            InspectorEmptyState(
                systemImage: "text.append",
                title: L10n.text("apple.sshsessioninspector.no_snippets_yet.6e213185"),
                subtitle: L10n.text("apple.sshsessioninspector.save_a_command_you_run_often_and_it_lands.226f24dc")
            ) {
                Button(L10n.text("apple.sshsessioninspector.add_snippet.a1f802b9"), .create) { editing = .newSnippet }
                    .buttonStyle(AccentButtonStyle(small: true))
                    .padding(.top, Theme.Space.xs)
            }
            .padding(Theme.Space.m)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(available) { snippet in row(snippet) }
                    Text(
                        target == nil
                            ? L10n.text("apple.sshsessioninspector.open_a_session_on_this_server_to_run_a_sni.e33cc3bd")
                            : L10n.text("apple.sshsessioninspector.a_snippet_runs_in_the_session_in_front_one.86b1e21a")
                    )
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Space.xs)
                    Button(L10n.text("apple.sshsessioninspector.add_snippet.a1f802b9"), .create) { editing = .newSnippet }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ snippet: SSHSnippet) -> some View {
        Button {
            guard target != nil else { return }
            run(snippet)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: ActionIcon.run.symbol)
                        .font(Theme.font(11))
                        .foregroundStyle(target == nil ? Color.secondary : Theme.accent)
                    Text(snippet.title)
                        .font(Theme.font(13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if snippet.hostIDs.contains(hostID) {
                        Text(L10n.text("apple.sshsessioninspector.this_server.98bf14a4"))
                            .font(Theme.font(10))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(snippet.command)
                    .font(Theme.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(CardButtonStyle())
        .help(snippet.command)
        .contextMenu {
            Button(L10n.text("apple.sshsessioninspector.run_it.958ca26c"), .run) { run(snippet) }
                .disabled(target == nil)
            Button(L10n.text("apple.sshsessioninspector.copy_command.9a01feec"), .copy) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(snippet.command, forType: .string)
            }
            ThemeRule()
            Button(L10n.text("common.edit"), .edit) { editing = .snippet(snippet.id) }
            Button(L10n.text("common.delete"), .delete, role: .destructive) { deleting = snippet }
        }
    }

    private func run(_ snippet: SSHSnippet) {
        if SSHSnippet.placeholders(in: snippet.command).isEmpty {
            type(snippet.command)
        } else {
            asking = snippet
        }
    }

    private func type(_ command: String) {
        guard let target else { return }
        sessions.select(target)
        target.sendBytes(SSHSnippet.bytesToRun(command))
    }
}
#endif
