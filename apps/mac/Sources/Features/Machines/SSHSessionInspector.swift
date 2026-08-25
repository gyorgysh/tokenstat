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

    private var host: SSHHost? { model.hosts.first { $0.id == hostID } }
    private var available: [SSHSnippet] { model.snippets(for: hostID) }

    /// Where a snippet is typed. Nil when the server has no session in front,
    /// which is what disables the rows: a command typed into nothing looks
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
                    Button("Snippets", .back) { editing = nil }
                        .buttonStyle(.plain)
                        .padding(.leading, Theme.Space.s)
                } else {
                    Text("Snippets")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .padding(.leading, Theme.Space.m)
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
        }
    }

    @ViewBuilder
    private var accessory: some View {
        if editing == nil, let host {
            Button("Server settings", .settings) { editing = .host(host.id) }
                .buttonStyle(SecondaryButtonStyle(small: true))
                .padding(.trailing, Theme.Space.xs)
                .help("Address, authentication and settings for \(host.label)")
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
            VStack(spacing: Theme.Space.m) {
                InspectorEmptyState(
                    systemImage: "text.append",
                    title: "No snippets yet",
                    subtitle: "Save a command you run often and it lands here, one click from the prompt."
                )
                .fixedSize(horizontal: false, vertical: true)
                Button("Add snippet", .create) { editing = .newSnippet }
                    .buttonStyle(AccentButtonStyle(small: true))
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(available) { snippet in row(snippet) }
                    Text(
                        target == nil
                            ? "Open a session on this server to type a snippet into it."
                            : "A snippet is typed at the prompt, not run. Press Return when you have read it."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Space.xs)
                    Button("Add snippet", .create) { editing = .newSnippet }
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
                    Image(systemName: ActionIcon.apply.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(target == nil ? Color.secondary : Theme.accent)
                    Text(snippet.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    // A snippet scoped to this server, rather than one of the
                    // general ones listed under it.
                    if snippet.hostIDs.contains(hostID) {
                        Text("this server")
                            .font(.system(size: 10))
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
            Button("Type it", .send) { run(snippet) }
                .disabled(target == nil)
            Button("Copy command", .copy) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(snippet.command, forType: .string)
            }
            Divider()
            Button("Edit", .edit) { editing = .snippet(snippet.id) }
        }
    }

    /// Type a snippet, or ask for its placeholders first.
    ///
    /// The same rule the phone's key bar follows, for the same reason: the
    /// line lands at the prompt with no trailing Return, so what is about to
    /// happen can be read before it happens. Somebody's saved command is not
    /// something to fire off because a click landed on the wrong card.
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
        target.sendBytes(Array(command.utf8))
    }
}
#endif
