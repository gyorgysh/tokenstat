// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// Step eight: the project, which is the point of all of it.
///
/// Setup used to end on a machine and a list of folders that was empty, which
/// is a working server and nothing to do with it. This ends inside a project,
/// with a first task already typed and not sent.
///
/// Neither route is new work: cloning and picking a folder are the same two
/// screens the workspace list offers, reached from here so that nobody has to
/// find them afterwards.
struct ClientSetupProjectStep: View {
    @Bindable var model: ClientSetupModel
    var onFinish: () -> Void

    @Environment(ClientNavigationModel.self) private var navigation

    @State private var route: ProjectRoute?
    @State private var opened: String?
    @State private var failure: ClientSetupFailure?

    private enum ProjectRoute: String, Hashable, Identifiable {
        case clone, existing
        var id: String { rawValue }
    }

    private var peer: String? { model.expectedPeer }

    var body: some View {
        StepScaffold(
            title: "Choose a project",
            subtitle: "The agent works inside one folder at a time. Bring a repository "
                + "down onto the machine, or point at a folder it already has.",
            number: 8,
            failure: failure,
            onDismissError: { failure = nil }
        ) {
            route(
                .clone,
                title: "Clone a repository",
                body: "tokenstat runs git on the machine and registers the folder when it "
                    + "finishes. You watch the whole thing, so a passphrase or an unknown "
                    + "host key is something you can answer.",
                symbol: "arrow.down.doc"
            )
            route(
                .existing,
                title: "A folder already on the machine",
                body: "Browse the machine's disk and register a folder that is there. "
                    + "Nothing is copied and nothing is changed.",
                symbol: "folder"
            )
            Text("Whichever you choose, the machine opens with a first task written into "
                + "the message box. Nothing is sent until you send it.")
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            Button("Not now", .next) { finish(folderID: nil) }
                .buttonStyle(.bordered)
        }
        .navigationTitle("Project")
        .accessibilityIdentifier("setup.project")
        .navigationDestination(item: $route) { chosen in
            if let peer {
                switch chosen {
                case .clone:
                    ClientCloneRepository(peer: peer, hostName: model.machineName) { id in
                        opened = id
                    }
                case .existing:
                    ClientFolderPicker(peer: peer, hostName: model.machineName) { folder in
                        opened = folder.id
                    }
                }
            }
        }
        // The two screens dismiss themselves on success, so the handoff waits
        // for the pop rather than tearing the stack down underneath them.
        .onChange(of: opened) { _, id in
            guard let id, let peer else { return }
            finish(folderID: "remote:\(peer):\(id)")
        }
    }

    /// Leave setup, on the project if there is one.
    ///
    /// The draft is forgotten here and nowhere earlier: this is the first
    /// moment when nothing is left half done.
    private func finish(folderID: String?) {
        guard model.completeSetup() else {
            // Forgetting the draft is the only thing that can fail here, and
            // it is worth saying: leaving now would offer to continue a setup
            // that is finished.
            failure = model.failure ?? ClientSetupFailure(
                explanation: "The saved setup could not be cleared, so leaving now would "
                    + "offer to continue this again.",
                action: .retry,
                details: nil
            )
            opened = nil
            return
        }
        if let folderID {
            navigation.suggestedPrompt = (folderID: folderID, text: Self.firstTask)
            navigation.open(folderID: folderID, section: .chat)
        } else {
            navigation.destination = .workspaces
        }
        onFinish()
    }

    /// A first task that reads the project and changes nothing.
    ///
    /// Deliberately not "fix" or "add": the first thing somebody sends should
    /// not be a change they have to review before they have seen the place.
    static let firstTask =
        "Give me a short tour of this project: what it does, how it is laid out, "
        + "and where you would start."

    private func route(
        _ value: ProjectRoute,
        title: String,
        body: String,
        symbol: String
    ) -> some View {
        Button {
            route = value
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: symbol)
                    .font(Theme.fixed(21, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 46, height: 46)
                    .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(title).font(ClientType.body.weight(.medium))
                    Text(body)
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Theme.fixed(12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .buttonStyle(.plain)
        .disabled(peer == nil)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("setup.project.\(value.rawValue)")
    }
}

#endif
