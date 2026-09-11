// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI
#if !os(macOS)
import UIKit
#endif

#if !os(macOS)

/// Door one: the computer somebody already works on.
///
/// The phone cannot do any of the three steps, so this screen's job is to be
/// **checkable** rather than instructive. It watches the account, and each
/// step ticks itself off as it happens. The one genuinely useful thing a phone
/// can do here is put the address in front of the person, so the share sheet
/// is the action rather than a link that opens a page the phone cannot use.
struct ClientSetupMacDoor: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss

    @State private var sharing = false
    @State private var arrived: Machine?

    private static let address = "https://tokenstat.ai/download"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(spacing: Theme.Space.s) {
                    ClientEmptyArt(kind: .macDoor)
                    Text("Your computer")
                        .font(Theme.title.weight(.semibold))
                    Text(
                        "Three things, all of them on the computer. This screen watches your "
                        + "account and ticks each one off as it happens."
                    )
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                GettingStartedRail(steps: steps)
                // No link button beside the share sheet: the address leaves
                // the phone through "Send it to my computer", and a second
                // copy of it was dead weight on the screen.
                if arrived != nil {
                    Text(
                        "One step is left and it happens on the computer: when this device asks "
                        + "to open a folder, say yes there."
                    )
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Space.m)
            .setupColumn()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .navigationTitle("On my Mac")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $sharing) {
            ClientShareSheet(items: [Self.address])
        }
        .task {
            await watch()
        }
    }

    private var steps: [GettingStartedStep] {
        [
            GettingStartedStep(
                number: 1,
                title: "Install tokenstat on the computer",
                body: "Send the download link to the computer. AirDrop it or message it to "
                    + "yourself, then open it there.",
                state: arrived == nil ? .now : .done,
                actionTitle: arrived == nil ? "Send it to my computer" : nil,
                actionIcon: .send,
                action: arrived == nil ? { sharing = true } : nil
            ),
            GettingStartedStep(
                number: 2,
                title: "Sign in to this account",
                body: arrived.map { "\($0.label ?? "It") is on your account." }
                    ?? "Open it there and sign in with the same account this device uses.",
                state: arrived == nil ? .next : .done
            ),
            GettingStartedStep(
                number: 3,
                title: "Let this device in",
                body: "Folders and terminals are only open to devices that computer has "
                    + "allowed. Ask from Workspaces, and say yes on the computer.",
                state: arrived == nil ? .next : .now
            ),
        ]
    }

    /// Recognize a Mac already on the account as well as one just added.
    ///
    /// Ends when one arrives or when the screen goes away. Nothing is written
    /// and nothing is installed: this is a screen watching, which is the only
    /// thing a phone can honestly do for this door.
    private func watch() async {
        let deadline = Date().addingTimeInterval(600)
        while arrived == nil, Date() < deadline, !Task.isCancelled {
            await account.load()
            arrived = (account.account?.machines ?? []).first { machine in
                let platform = machine.platform?.lowercased() ?? ""
                return machine.isHost && (platform.contains("macos") || platform.contains("darwin"))
            }
            if arrived != nil { return }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

/// Door three: a machine somebody already rents.
///
/// Reading an inventory, and nothing else. **Creating a machine is out of
/// scope**: a write-scoped provider token on a phone can spend somebody's
/// money, and that is a different trust conversation from a read-only list.
/// So this says "pick one you have" and means it.
///
/// Once the servers are imported they are ordinary saved hosts, and door two
/// takes over from its first step with the address already known.
struct ClientSetupCloudDoor: View {
    @Bindable var model: ClientSetupModel
    @Bindable var library: SSHLibraryModel
    @Binding var path: [SetupStep]

    private enum Provider: String, CaseIterable, Identifiable {
        case digitalOcean = "DigitalOcean"
        case aws = "AWS"
        var id: String { rawValue }
    }

    @State private var provider = Provider.digitalOcean
    @State private var token = ""
    @State private var profile = ""
    @State private var region = ""
    @State private var username = "root"
    @State private var imported: Int?
    @State private var working = false
    @State private var error: String?
    @State private var generation = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(spacing: Theme.Space.s) {
                    ClientEmptyArt(kind: .cloudDoor)
                    Text("A cloud machine")
                        .font(Theme.title.weight(.semibold))
                    Text(
                        "Import an existing server from your provider, then connect over SSH. "
                        + "No servers are created and nothing is purchased."
                    )
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                // First, because somebody with no server at all cannot use
                // anything below this and would otherwise read a form asking
                // for an account token they have no reason to have.
                needOne
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    // The platform segmented control is a grey track with a
                    // grey pill, which is the one piece of chrome on this
                    // screen wearing somebody else's palette.
                    #if os(macOS)
                    SegmentedTabs(options: Provider.allCases, selection: $provider)
                        .disabled(working)
                    #else
                    // Phone: DigitalOcean only. AWS inventory import needs the
                    // desktop app, so there is no second tab to offer.
                    #endif
                    if provider == .digitalOcean {
                        Text("Read-only API token")
                            .font(ClientType.caption).foregroundStyle(.secondary)
                        SecureField("Paste your DigitalOcean token", text: $token)
                            .textFieldStyle(.themed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        Label("Connect with your server’s address", systemImage: "server.rack")
                            .font(ClientType.body)
                        Text("Find the public address in your AWS console. On the next screen, enter it with your SSH username and key. AWS inventory import requires the desktop app.")
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if provider == .digitalOcean {
                        Text("SSH username")
                            .font(ClientType.caption).foregroundStyle(.secondary)
                        TextField("SSH username", text: $username)
                            .textFieldStyle(.themed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Text(provider == .digitalOcean
                        ? "Only the droplet list is read. The token is used once and is not saved."
                        : "Use ec2-user for Amazon Linux, or ubuntu for Ubuntu.")
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
                if let imported {
                    Text(imported == 1
                        ? "One server is in your library. Pick it on the next screen."
                        : "\(imported) servers are in your library. Pick one on the next screen.")
                        .font(ClientType.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SetupActions {
                    if provider == .aws {
                        Button("Enter server address", .next) {
                            model.pickedHostID = nil
                            model.host.username = "ec2-user"
                            path.append(.where)
                        }
                        .setupPrimaryStyle()
                    } else if imported == nil {
                        Button(working ? "Reading the list…" : "Read my servers", .download) {
                            Task { await load() }
                        }
                        .setupPrimaryStyle()
                        .disabled(working || (provider == .digitalOcean && token.isEmpty)
                            || username.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        Button("Pick a server", .next) { path.append(.where) }
                            .setupPrimaryStyle()
                    }
                }
            }
            .padding(Theme.Space.m)
            .setupColumn()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .navigationTitle("Cloud")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            generation = UUID()
            working = false
            token = ""
        }

    }

    /// The way out for somebody who has none yet.
    ///
    /// It lives here rather than as a door of its own: "I have a cloud server"
    /// and "I need a cloud server" are the same question asked by people one
    /// step apart, and splitting them across the first screen made somebody
    /// choose between two doors that both said cloud.
    private var needOne: some View {
        NavigationLink(value: SetupStep.needServer) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: "cart")
                    .font(Theme.fixed(19, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 42, height: 42)
                    .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("I do not have one yet")
                        .font(ClientType.body.weight(.medium))
                    Text("What a machine has to be, who bills you for it, and where people "
                        + "rent one. Nothing there spends money.")
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
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("setup.cloud.needServer")
    }

    private func load() async {
        guard !working, let scope = model.activeScope else { return }
        let request = UUID()
        generation = request
        func isCurrent() -> Bool {
            !Task.isCancelled && generation == request && model.activeScope == scope
        }
        working = true
        error = nil
        defer { if generation == request { working = false } }
        do {
            let result: SSHHostImport = provider == .digitalOcean
                ? try await Bridge.importDigitalOcean(token: token, username: username)
                : try await Bridge.importAWS(
                    profile: profile.isEmpty ? nil : profile,
                    region: region.isEmpty ? nil : region,
                    username: username
                )
            guard isCurrent() else { return }
            // Import already writes the local SSH library. Refresh those rows
            // without issuing a second save for every imported server.
            await library.reload()
            guard isCurrent() else { return }
            guard !result.hosts.isEmpty else {
                throw BridgeError.core(code: "no_servers",
                    message: "No servers were found. Check the account token or enter a server address instead.")
            }
            // The token was a credential and its job is done. It is never
            // written to the archive and is not eligible for sync.
            token = ""
            imported = result.imported
        } catch {
            guard isCurrent() else { return }
            self.error = ClientSetupModel.readable(error)
        }
    }
}

/// The system share sheet, for the one thing a phone can do about a computer.
struct ClientShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#endif
