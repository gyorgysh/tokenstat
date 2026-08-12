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
/// The wording follows the privacy rule in `CLAUDE.md`: the guarantee is the
/// boundary. Nothing here says tokenstat "cannot see" something it never
/// receives in the first place.
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
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("End to end encrypted")
                            .font(ClientType.sectionTitle)
                        Text(isExpanded
                            ? "Keys and fingerprints are visible"
                            : "Keys are hidden until you choose to view them")
                            .font(ClientType.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Theme.Space.s)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the encryption keys" : "Shows the encryption keys")

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
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .cardSurface()
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
