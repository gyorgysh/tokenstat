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
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
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
                GettingStartedRail(steps: steps)
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                body: "Nobody installs a desktop app from an iPhone or iPad, so this step sends the "
                    + "address to it instead. \(Self.address)",
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Bring your machines")
                        .font(Theme.title.weight(.semibold))
                    Text(
                        "tokenstat reads the list of servers you already have and adds them "
                        + "to your SSH library. It never creates one and never spends money."
                    )
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    InlineBanner(text: error, kind: .danger) { self.error = nil }
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Picker("Provider", selection: $provider) {
                        ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if provider == .digitalOcean {
                        SecureField("Read-only API token", text: $token)
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
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .navigationTitle("Cloud")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Theme.Space.s) {
                if provider == .aws {
                    Button("Enter server address", .next) {
                        model.pickedHostID = nil
                        model.host.username = "ec2-user"
                        path.append(.where)
                    }
                    .clientProminentStyle()
                } else if imported == nil {
                    Button(working ? "Reading the list…" : "Read my servers", .download) {
                        Task { await load() }
                    }
                    .clientProminentStyle()
                    .disabled(working || (provider == .digitalOcean && token.isEmpty)
                        || username.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button("Pick a server", .next) { path.append(.where) }
                        .clientProminentStyle()
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func load() async {
        working = true
        error = nil
        defer { working = false }
        do {
            let result: SSHHostImport = provider == .digitalOcean
                ? try await Bridge.importDigitalOcean(token: token, username: username)
                : try await Bridge.importAWS(
                    profile: profile.isEmpty ? nil : profile,
                    region: region.isEmpty ? nil : region,
                    username: username
                )
            // Saved through the model, which is what also puts them in the
            // encrypted vault, so an import from the phone reaches every other
            // device the same way a hand-typed server does.
            for host in result.hosts {
                guard await library.save(host: host) != nil else {
                    throw BridgeError.core(code: "not_saved",
                        message: library.error ?? "The server could not be saved. Try again.")
                }
            }
            guard !result.hosts.isEmpty else {
                throw BridgeError.core(code: "no_servers",
                    message: "No servers were found. Check the account token or enter a server address instead.")
            }
            // The token was a credential and its job is done. It is never
            // written to the archive and is not eligible for sync.
            token = ""
            imported = result.imported
        } catch {
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
