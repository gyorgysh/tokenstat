// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if os(macOS)
import AppKit

/// The saved commands for the server whose shells are on screen.
///
/// The inspector used to force the host editor open beside a live session, on
/// the reasoning that somebody had just learned what the keepalive should have
/// been. That is a thing people do once. Reaching for a command they have
/// already saved is a thing they do all day, and on the Mac there was no way
/// to do it at all: the snippet menu is built for the phone's key bar and sits
/// behind `#if !os(macOS)`, so a Mac could write snippets and never run one.
///
/// Server settings are one click away in the chrome bar rather than in front.
struct SSHSessionInspector: View {
    let model: SSHLibraryModel
    @Bindable var sessions: SSHSessionsModel
    let hostID: String
    var onClose: () -> Void

    /// The snippet whose placeholders are being filled in.
    @State private var asking: SSHSnippet?
    /// The editor open over the list, and the way back out of it.
    ///
    /// Local rather than `model.selection`, which belongs to the library
    /// screen's own inspector. Writing to that from here would move a
    /// selection on a screen nobody is looking at and draw nothing on this
    /// one.
    @State private var editing: SSHLibraryRoute?
    /// The snippet whose deletion is waiting to be confirmed.
    @State private var deleting: SSHSnippet?

    private var host: SSHHost? { model.hosts.first { $0.id == hostID } }
    private var available: [SSHSnippet] { model.snippets(for: hostID) }

    /// Where a snippet runs. Nil when the server has no session in front,
    /// which is what disables the rows: a command sent into nothing looks
    /// exactly like a command that ran and printed nothing.
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
                        .buttonStyle(.plain)
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
        .background(Theme.background)
        .sheet(item: $asking) { snippet in
            SSHSnippetRunSheet(snippet: snippet) { command in type(command) }
        }
        // A different server's shells are a different set of snippets, and an
        // editor left open over the old one belongs to a record this column is
        // no longer about.
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
            // The button is handed to the empty state rather than stacked
            // under it. Stacked, it was wrapped in a `fixedSize` to stop the
            // empty state's infinite maximum height from pushing it to the
            // floor of the pane, and asking a view with an infinite maximum
            // for its ideal height resolves to something enormous: the pane
            // grew taller than the window, the window's content overflowed,
            // and the tab strip, the sidebar's Home row and the account
            // footer were all clipped off the edges.
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
                    // A snippet scoped to this server, rather than one of the
                    // general ones listed under it.
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
        .buttonStyle(.plain)
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
            // Deleting from here used to mean opening the editor and finding
            // the button in its footer, which is a long way round for a card
            // that is right under the pointer. Behind a confirmation, unlike
            // the library's own rows: this menu sits beside a live shell and a
            // mis-click here is a mis-click during work.
            Button(L10n.text("common.delete"), .delete, role: .destructive) { deleting = snippet }
        }
    }

    /// Run a snippet, or ask for its placeholders first.
    ///
    /// The same rule the phone's key bar follows: a snippet with placeholders
    /// goes through the sheet, where the filled command is on screen before it
    /// is sent, and everything else runs. A snippet is a command somebody
    /// saved in order to run it.
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
