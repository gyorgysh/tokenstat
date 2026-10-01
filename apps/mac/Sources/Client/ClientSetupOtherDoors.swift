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
                    Text(L10n.text("apple.clientsetupotherdoors.your_computer.49361195"))
                        .font(Theme.title.weight(.semibold))
                    Text(
                        L10n.text("apple.clientsetupotherdoors.three_things_all_of_them_on_the_computer_t.63c1a537")
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
                        L10n.text("apple.clientsetupotherdoors.one_step_is_left_and_it_happens_on_the_com.6a5d8111")
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
        .navigationTitle(L10n.text("apple.clientsetupotherdoors.on_my_mac.8282732a"))
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
                title: L10n.text("apple.clientsetupotherdoors.install_tokenstat_on_the_computer.8d9833fb"),
                body: L10n.text("apple.clientsetupotherdoors.send_the_download_link_to_the_computer_air.dd5ff111"),
                state: arrived == nil ? .now : .done,
                actionTitle: arrived == nil ? L10n.text("apple.clientsetupotherdoors.send_it_to_my_computer.3260803b") : nil,
                actionIcon: .send,
                action: arrived == nil ? { sharing = true } : nil
            ),
            GettingStartedStep(
                number: 2,
                title: L10n.text("apple.clientsetupotherdoors.sign_in_to_this_account.d3d7f116"),
                body: arrived.map { L10n.text("apple.clientsetupotherdoors.0_is_on_your_account.5704eab4", "\($0.label ?? L10n.text("apple.clientsetupotherdoors.it.555c7b8b"))") }
                    ?? L10n.text("apple.clientsetupotherdoors.open_it_there_and_sign_in_with_the_same_ac.d3ddaa5f"),
                state: arrived == nil ? .next : .done
            ),
            GettingStartedStep(
                number: 3,
                title: L10n.text("apple.clientsetupotherdoors.let_this_device_in.35808989"),
                body: L10n.text("apple.clientsetupotherdoors.folders_and_terminals_are_only_open_to_dev.e9f4d10a"),
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

    /// AWS inventory import needs the desktop app, so the phone offers
    /// DigitalOcean alone. The selector stays with one option, ready for
    /// the next provider, instead of vanishing and reappearing.
    #if os(macOS)
    private var providers: [Provider] { Provider.allCases }
    #else
    private var providers: [Provider] { [.digitalOcean] }
    #endif

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
                    Text(L10n.text("apple.clientsetupotherdoors.a_cloud_machine.e66ba82a"))
                        .font(Theme.title.weight(.semibold))
                    Text(
                        L10n.text("apple.clientsetupotherdoors.import_an_existing_server_from_your_provid.24352ead")
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
                    SegmentedTabs(options: providers, selection: $provider)
                        .disabled(working)
                    if provider == .digitalOcean {
                        Text(L10n.text("apple.clientsetupotherdoors.read_only_api_token.8a4f07c1"))
                            .font(ClientType.caption).foregroundStyle(.secondary)
                        SecureField(L10n.text("apple.clientsetupotherdoors.paste_your_digitalocean_token.2e2aa61f"), text: $token)
                            .textFieldStyle(.themed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if let tokens = URL(string: "https://cloud.digitalocean.com/account/api/tokens") {
                            Link(L10n.text("apple.clientsetupotherdoors.where_to_find_the_token.625cfc6d"), destination: tokens)
                                .font(ClientType.caption)
                        }
                    } else {
                        Label(L10n.text("apple.clientsetupotherdoors.connect_with_your_server_s_address.cfcd220c"), systemImage: "server.rack")
                            .font(ClientType.body)
                        Text(L10n.text("apple.clientsetupotherdoors.find_the_public_address_in_your_aws_consol.4549ae4e"))
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if provider == .digitalOcean {
                        Text(L10n.text("apple.clientsetupotherdoors.ssh_username.04940ab1"))
                            .font(ClientType.caption).foregroundStyle(.secondary)
                        TextField(L10n.text("apple.clientsetupotherdoors.ssh_username.04940ab1"), text: $username)
                            .textFieldStyle(.themed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Text(provider == .digitalOcean
                        ? L10n.text("apple.clientsetupotherdoors.only_the_droplet_list_is_read_the_token_is.d730f946")
                        : L10n.text("apple.clientsetupotherdoors.use_ec2_user_for_amazon_linux_or_ubuntu_fo.bf59c231"))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
                if let imported {
                    Text(imported == 1
                        ? L10n.text("apple.clientsetupotherdoors.one_server_is_in_your_library_pick_it_on_t.3984faae")
                        : L10n.text("apple.clientsetupotherdoors.0_servers_are_in_your_library_pick_one_on.85b3ca0e", "\(imported)"))
                        .font(ClientType.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SetupActions {
                    if provider == .aws {
                        Button(L10n.text("apple.clientsetupotherdoors.enter_server_address.da02e13e"), .next) {
                            model.pickedHostID = nil
                            model.host.username = L10n.text("apple.clientsetupotherdoors.ec2_user.4346840f")
                            path.append(.where)
                        }
                        .setupPrimaryStyle()
                    } else if imported == nil {
                        Button(working ? L10n.text("apple.clientsetupotherdoors.reading_the_list.0fd8ea35") : L10n.text("apple.clientsetupotherdoors.read_my_servers.0e3c3c94"), .download) {
                            Task { await load() }
                        }
                        .setupPrimaryStyle()
                        .disabled(working || (provider == .digitalOcean && token.isEmpty)
                            || username.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        Button(L10n.text("apple.clientsetupotherdoors.pick_a_server.3ff63c9e"), .next) { path.append(.where) }
                            .setupPrimaryStyle()
                    }
                }
            }
            .padding(Theme.Space.m)
            .setupColumn()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .navigationTitle(L10n.text("apple.clientsetupotherdoors.cloud.b977b950"))
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
                    Text(L10n.text("apple.clientsetupotherdoors.i_do_not_have_one_yet.1bfb41c7"))
                        .font(ClientType.body.weight(.medium))
                    Text(L10n.text("apple.clientsetupotherdoors.what_a_machine_has_to_be_who_bills_you_for.b01df46d"))
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
                    message: L10n.text("apple.clientsetupotherdoors.no_servers_were_found_check_the_account_to.e590f2d6"))
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
