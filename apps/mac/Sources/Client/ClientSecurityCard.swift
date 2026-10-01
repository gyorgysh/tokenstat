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

// The client is iOS and iPadOS only.
#if !os(macOS)

/// What protects a connection between this phone and a computer, in the words
/// and the numbers it actually runs on.
///
/// The claim is the product, so this screen shows the mechanism rather than a
/// padlock: the keys are on the two devices, the relay carries bytes it cannot
/// read, and the fingerprints below are the ones a person can compare against
/// the other machine's Machines screen. Two devices showing the same pair of
/// words are talking to each other and to nobody in between.
///
/// On the work list it sits as a glass divider, not a fourth device card. The
/// keys stay a tap away. The wording follows the project's privacy rule:
/// **the guarantee is the boundary, not the read.** Nothing here says
/// tokenstat "cannot see" something it never receives in the first place,
/// because a claim that overstates is a claim somebody can catch out.
struct ClientSecurityCard: View {
    /// The far end, when there is one. Nil shows this device alone.
    var peerKey: String?
    var peerName: String?

    @State private var identity: MachineIdentity?
    @State private var peer: Peer?
    @State private var copied: String?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: Theme.Space.s) {
                    ThemeRule()
                    HStack(spacing: 6) {
                        Image(systemName: ActionIcon.security.symbol)
                            .font(ClientType.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                        Text(L10n.text("apple.clientsecuritycard.end_to_end_encrypted.e3ac807e"))
                            .font(ClientType.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(Theme.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.s)
                    .fixedSize()
                    .clientGlassChip()
                    ThemeRule()
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: Theme.Control.heightComfortable)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("apple.clientsecuritycard.end_to_end_encrypted.e3ac807e"))
            .accessibilityValue(isExpanded ? L10n.text("apple.clientsecuritycard.expanded.e72d5d8d") : L10n.text("apple.clientsecuritycard.collapsed.b322b652"))
            .accessibilityHint(isExpanded
                ? L10n.text("apple.clientsecuritycard.hides_the_encryption_keys.d8fa35b1")
                : L10n.text("apple.clientsecuritycard.shows_the_encryption_keys_keys_are_hidden.1d8406ea"))

            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(L10n.text("apple.clientsecuritycard.a_connection_between_your_devices_is_encry.b8a28ce2"))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if let identity {
                        keyRow(
                            title: L10n.text("apple.clientsecuritycard.this_device.d052579c"),
                            words: identity.words,
                            fingerprint: identity.fingerprint,
                            key: identity.key
                        )
                    }
                    if let peer {
                        keyRow(
                            title: peerName ?? (peer.label.isEmpty ? L10n.text("apple.clientsecuritycard.the_other_device.80640982") : peer.label),
                            words: peer.words,
                            fingerprint: peer.fingerprint,
                            key: peer.key
                        )
                    }

                    Text(L10n.text("apple.clientsecuritycard.noise_xx_handshake_x25519_keys_chacha20_po.233e27b7"))
                        .font(Theme.font(10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Theme.Space.s)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: peerKey) { await load() }
    }

    private func keyRow(title: String, words: String?, fingerprint: String, key: String) -> some View {
        Button {
            UIPasteboard.general.string = key
            copied = key
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                Text(words ?? fingerprint)
                    .font(ClientType.label.weight(.medium))
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(fingerprint)
                        .font(ClientType.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if copied == key {
                        Text(L10n.text("apple.clientsecuritycard.copied.fb30593c"))
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityHint(L10n.text("apple.clientsecuritycard.copies_the_full_public_key.7c229829"))
    }

    private func load() async {
        // The task id is `peerKey`, but a task already past its first await is
        // not stopped by the next one starting. Capture what this run is for
        // and refuse to publish into a different peer's screen.
        let wanted = peerKey
        let identity = try? await Bridge.machineIdentity()
        guard !Task.isCancelled, wanted == peerKey else { return }
        self.identity = identity
        guard let wanted else {
            peer = nil
            return
        }
        let found = (try? await Bridge.peers())?.first { $0.key == wanted }
        guard !Task.isCancelled, wanted == peerKey else { return }
        peer = found
    }
}

#endif
