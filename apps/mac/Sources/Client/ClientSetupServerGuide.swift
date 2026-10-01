// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

/// For somebody who does not have a server yet.
///
/// The other doors all assume a machine exists. This one is the honest answer
/// to the person who read "runs on a machine that stays on" and has none: what
/// it has to be, who takes the money, and where to go and get one.
///
/// tokenstat does not create servers and does not bill for them. Renting one is
/// something that happens at a provider, in their account, on their card, and
/// saying so before somebody leaves is the whole point of this screen.
struct ClientSetupServerGuide: View {
    @Binding var path: [SetupStep]

    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                VStack(spacing: Theme.Space.s) {
                    ClientEmptyArt(kind: .rentServer)
                    Text(L10n.text("apple.clientsetupserverguide.renting_a_server.f1a1e2a6"))
                        .font(Theme.title.weight(.semibold))
                    Text(
                        L10n.text("apple.clientsetupserverguide.this_device_is_where_you_work_the_machine.2bf93b68")
                    )
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

                section(L10n.text("apple.clientsetupserverguide.what_it_has_to_be.db0d043b")) {
                    requirement(L10n.text("apple.clientsetupserverguide.linux_with_systemd.02486325"), L10n.text("apple.clientsetupserverguide.setup_uses_systemd_to_keep_the_helper_runn.08263b69"))
                    requirement(L10n.text("apple.clientsetupserverguide.64_bit_intel_or_amd.6b85ad70"), L10n.text("apple.clientsetupserverguide.the_standard_server_image_at_any_provider.0a8d231e"))
                    requirement(L10n.text("apple.clientsetupserverguide.ssh_access.4755492e"), L10n.text("apple.clientsetupserverguide.a_login_setup_can_use_a_password_or_an_ssh.0805316c"))
                }

                section(L10n.text("apple.clientsetupserverguide.what_size_is_enough.3ea0c00a")) {
                    Text(L10n.text("apple.clientsetupserverguide.the_coding_agent_your_project_and_any_loca.ea37ed75"))
                        .font(ClientType.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    bullet(L10n.text("apple.clientsetupserverguide.check_the_agent_s_system_requirements_and.9af69248"))
                    bullet(L10n.text("apple.clientsetupserverguide.grow_when_the_projects_do_disk_and_memory.29b9c033"))
                }

                section(L10n.text("apple.clientsetupserverguide.who_takes_the_money.7df75402")) {
                    Text(L10n.text("apple.clientsetupserverguide.three_separate_things_and_only_one_of_them.08df69a7"))
                        .font(ClientType.label)
                        .fixedSize(horizontal: false, vertical: true)
                    bullet(L10n.text("apple.clientsetupserverguide.the_provider_bills_you_for_the_server_mont.429cf30a"))
                    bullet(L10n.text("apple.clientsetupserverguide.the_coding_agent_is_billed_by_whoever_make.efc06607"))
                    bullet(L10n.text("apple.clientsetupserverguide.tokenstat_charges_for_its_own_plan_nothing.6a1be7f0"))
                }

                section(L10n.text("apple.clientsetupserverguide.where_to_get_one.dead684a")) {
                    Text(L10n.text("apple.clientsetupserverguide.choose_a_provider_with_a_server_that_meets.67e8b16b"))
                        .font(ClientType.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    provider("DigitalOcean", "https://m.do.co/c/638545628ff0")
                    Text(L10n.text("apple.clientsetupserverguide.the_digitalocean_link_is_a_referral_link_s.b3c5c9a2"))
                        .font(ClientType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(L10n.text("apple.clientsetupserverguide.come_back_here_when_the_server_exists_and.d77e7d9e"))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SetupActions {
                    Button(L10n.text("apple.clientsetupserverguide.i_have_a_server_now.7af0bb61"), .next) { path = [.where] }
                        .setupPrimaryStyle()
                        .accessibilityIdentifier("setup.serverGuide.continue")
                }
            }
            .padding(Theme.Space.m)
            .setupColumn()
        }
        .background(Theme.background)
        .navigationTitle(L10n.text("apple.clientsetupserverguide.i_need_a_server.e6c65b43"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("setup.serverGuide")

    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title)
                .font(ClientType.label.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Theme.Space.s) { content() }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
        }
    }

    private func requirement(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: "checkmark.circle.fill")
                .font(ClientType.body)
                .foregroundStyle(Theme.accent)
                .labelStyle(.titleAndIcon)
            Text(detail)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Circle().fill(Theme.accent).frame(width: 5, height: 5).padding(.top, 6)
                .accessibilityHidden(true)
            Text(text)
                .font(ClientType.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Leaves the app on purpose.
    ///
    /// Renting a server means an account, a card and a console, and all three
    /// belong in the browser where somebody's saved details already are. An
    /// in-app view of somebody's provider login is a worse place to type a
    /// password, not a better one.
    private func provider(_ name: String, _ address: String) -> some View {
        Button(name, .external) {
            if let url = URL(string: address) { openURL(url) }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("setup.serverGuide.\(name.lowercased())")
    }
}

#endif
