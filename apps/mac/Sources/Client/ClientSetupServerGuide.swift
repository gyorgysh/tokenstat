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
                    Text("Renting a server")
                        .font(Theme.title.weight(.semibold))
                    Text(
                        "This device is where you work. The machine is what runs the "
                        + "agent, holds your projects and stays on when you close this. A "
                        + "small rented Linux server is the usual way to have one."
                    )
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

                section("What it has to be") {
                    requirement("Linux with systemd", "Setup uses systemd to keep the "
                        + "helper running, including after a reboot.")
                    requirement("64-bit Intel or AMD", "The standard server image at "
                        + "any provider.")
                    requirement("SSH access", "A login setup can use: a password or an "
                        + "SSH key. Root works, and so does an ordinary user that can "
                        + "write to its own home directory.")
                }

                section("What size is enough") {
                    Text("The coding agent, your project and any local models determine "
                        + "how much memory, disk space and processing power you need.")
                        .font(ClientType.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    bullet("Check the agent's system requirements and leave room for "
                        + "your project's builds and tests.")
                    bullet("Grow when the projects do. Disk and memory follow "
                        + "your checkouts and models, not us.")
                }

                section("Who takes the money") {
                    Text("Three separate things, and only one of them is ours.")
                        .font(ClientType.label)
                        .fixedSize(horizontal: false, vertical: true)
                    bullet("The provider bills you for the server, monthly or by the hour, "
                        + "until you delete it. Deleting the machine is how the charge "
                        + "stops, and that happens in their console, not here.")
                    bullet("The coding agent is billed by whoever makes it, through the "
                        + "account you sign in to on the machine.")
                    bullet("tokenstat charges for its own plan. Nothing here buys a server "
                        + "and nothing here includes agent usage.")
                }

                section("Where to get one") {
                    Text("Choose a provider with a server that meets the requirements above. "
                        + "Setup can import DigitalOcean servers on this device; for AWS, "
                        + "enter the server's SSH address. You create and manage the server "
                        + "in the provider's own account.")
                        .font(ClientType.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    provider("DigitalOcean", "https://www.digitalocean.com/products/droplets")
                    provider("AWS", "https://aws.amazon.com/ec2/")
                }

                Text("Come back here when the server exists and you have its address. "
                    + "Nothing on this screen has to be finished in one sitting.")
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SetupActions {
                    Button("I have a server now", .next) { path = [.where] }
                        .setupPrimaryStyle()
                        .accessibilityIdentifier("setup.serverGuide.continue")
                }
            }
            .padding(Theme.Space.m)
            .setupColumn()
        }
        .background(Theme.background)
        .navigationTitle("I need a server")
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
