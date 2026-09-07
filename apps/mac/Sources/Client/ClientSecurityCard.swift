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
                        Text("End to end encrypted")
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
            .accessibilityLabel("End to end encrypted")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded
                ? "Hides the encryption keys"
                : "Shows the encryption keys. Keys are hidden until you choose to view them.")

            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("""
                    A connection between your devices is encrypted on one and decrypted \
                    on the other, with keys that never leave them. The relay forwards \
                    the bytes and cannot read them, and neither can tokenstat. Your \
                    folders, terminals and agents are on your own computer.
                    """)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if let identity {
                        keyRow(
                            title: "This device",
                            words: identity.words,
                            fingerprint: identity.fingerprint,
                            key: identity.key
                        )
                    }
                    if let peer {
                        keyRow(
                            title: peerName ?? (peer.label.isEmpty ? "The other device" : peer.label),
                            words: peer.words,
                            fingerprint: peer.fingerprint,
                            key: peer.key
                        )
                    }

                    Text("Noise XX handshake, X25519 keys, ChaCha20-Poly1305. "
                        + "Compare the words with the other device to be sure.")
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
                        Text("copied")
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Copies the full public key")
    }

    private func load() async {
        identity = try? await Bridge.machineIdentity()
        guard let peerKey else {
            peer = nil
            return
        }
        peer = (try? await Bridge.peers())?.first { $0.key == peerKey }
    }
}

#endif
