// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import SwiftUI

extension PinnedWorkStore.Pin {
    /// The row navigates the way a Continue row does: the destination owns
    /// reachability, and a machine that is asleep says so there.
    var place: ClientRecentPlaces.Place? {
        let kind: ClientRecentPlaces.Kind
        switch reference.kind {
        case .workspace: kind = .workspace
        case .conversation: kind = .chat
        case .terminal, .commit, .savedDiff: return nil
        }
        let id = ClientRecentPlaces.Place.ID(
            peer: reference.hostIdentity, workspaceID: reference.workspaceID,
            kind: kind, itemID: reference.itemID
        )
        return ClientRecentPlaces.Place(id: id, workspaceName: folderName, openedAt: pinnedAt)
    }
}

/// The shelf: up to eight folders and conversations, newest first.
///
/// Empty collapses to nothing and keeps its arranged position: an empty
/// section is not an error, and the editor still shows where it sits. Rows
/// open through the same destination Continue uses, so a pin to work on a
/// sleeping machine says so there rather than here.
struct ClientPinnedWorkSection: View {
    @Environment(AccountModel.self) private var account
    @Environment(ConnectivityModel.self) private var connectivity
    /// Observed, so pinning from a thread or unpinning here redraws the card
    /// without leaving Home and coming back.
    @State private var pinsStore = PinnedWorkStore.shared

    /// One row, with the identity it is drawn under.
    ///
    /// **Never a position.** The shelf is rebuilt from the store on every
    /// read, and a row keyed by index can be asked to draw itself after that
    /// store has changed: pinning from a thread and unpinning from this card
    /// both do it, and `pins[index]` then reaches past the end of a shorter
    /// list, which crashes rather than drawing a stale row. Rows keyed by the
    /// pin's own key simply disappear instead.
    private struct Row: Identifiable {
        let id: String
        let pin: PinnedWorkStore.Pin
        let place: ClientRecentPlaces.Place
    }

    private var rows: [Row] {
        pinsStore.pins(in: account.account?.pinnedWorkScope).compactMap { pin in
            guard let id = pin.key, let place = pin.place else { return nil }
            return Row(id: id, pin: pin, place: place)
        }
    }

    var body: some View {
        // Read once for the whole pass. The store decodes on every access, and
        // reading it again inside the loop is what let the list change shape
        // underneath the rows being built from it.
        let shelf = rows
        if !shelf.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ClientSectionTitle(title: L10n.text("apple.clientpinnedworksection.pinned.f20c8794"), mark: "mark_pin")
                VStack(spacing: 0) {
                    ForEach(shelf) { row in
                        HStack(spacing: 0) {
                            ClientOwnedNavigationLink {
                                ClientSavedPlaceView(place: row.place)
                            } label: {
                                content(row.pin)
                            }
                            .buttonStyle(.plain)
                            Button {
                                Task { await PinnedWorkActions.unpin(row.pin.reference) }
                            } label: {
                                ActionIcon.pinned.label(L10n.text("apple.clientpinnedworksection.unpin_0.450ccf9f", "\(row.pin.label)"))
                                    .labelStyle(.iconOnly)
                                    .font(ClientType.body)
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 44, height: 44)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.text("apple.clientpinnedworksection.unpin_0.450ccf9f", "\(row.pin.label)"))
                            .accessibilityHint(L10n.text("apple.clientpinnedworksection.removes_this_from_home_the_conversation_st.372f0dc3"))
                        }
                        if row.id != shelf.last?.id {
                            ThemeRule().padding(.horizontal, Theme.Space.m)
                        }
                    }
                }
                .cardSurface()
            }
            .accessibilityIdentifier("home.pinned")
        }
    }

    /// The tappable row. The unpin button beside it stays its own VoiceOver
    /// target: combining the whole row would swallow it.
    private func content(_ pin: PinnedWorkStore.Pin) -> some View {
        let machine = account.account?.machines.first { $0.publicIdentity == pin.reference.hostIdentity }
        let state = machine == nil ? L10n.text("apple.clientpinnedworksection.no_longer_linked.e409e8a7")
            : connectivity.isOffline ? L10n.text("apple.clientpinnedworksection.you_are_offline.4d5c9439")
            : machine?.online == true ? L10n.text("apple.clientpinnedworksection.awake.9123b5f4")
            : machine?.online == false ? L10n.text("apple.clientpinnedworksection.asleep.60135e8f") : L10n.text("apple.clientpinnedworksection.status_unknown.e412d872")
        return HStack(spacing: Theme.Space.m) {
            Image(systemName: pin.reference.kind == .workspace ? "folder" : "bubble.left.and.bubble.right")
                .font(ClientType.body)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(pin.label)
                    .font(ClientType.label.weight(.semibold))
                    .lineLimit(2)
                (Text("\(pin.folderName) · \(machine?.displayName ?? L10n.text("apple.clientpinnedworksection.machine.8f1cc42d")) · \(state)")
                    + Text(L10n.text("apple.clientpinnedworksection.pinned.9cd70bcf")))
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(ClientType.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(Theme.Space.m)
        .frame(minHeight: 60)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// One pin toggle for rows that already name their destination.
///
/// The pin glyph fills with the theme accent when set; unfilled and quiet
/// when not. Full shelves refuse with words: the row says the shelf holds
/// eight, rather than the oldest pin silently going.
struct PinToggleButton: View {
    var reference: WorkReference?
    var label: String
    var folderName: String

    @State private var store = PinnedWorkStore.shared
    @State private var refused = false

    private var pinned: Bool {
        guard let reference else { return false }
        return store.isPinned(reference)
    }

    var body: some View {
        if let reference {
            Button {
                Task {
                    if pinned {
                        await PinnedWorkActions.unpin(reference)
                        refused = false
                    } else if await PinnedWorkActions.pin(reference, label: label, folderName: folderName) {
                        refused = false
                    } else {
                        refused = true
                    }
                }
            } label: {
                (pinned ? ActionIcon.pinned : ActionIcon.pin).label(pinned ? L10n.text("apple.clientpinnedworksection.pinned.f20c8794") : L10n.text("apple.clientpinnedworksection.pin.ff1cee74"))
                    .labelStyle(.iconOnly)
                    .font(ClientType.body)
                    .foregroundStyle(pinned ? Theme.accent : refused ? Theme.danger : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pinned ? L10n.text("apple.clientpinnedworksection.unpin_0.450ccf9f", "\(label)") : L10n.text("apple.clientpinnedworksection.pin_0.67fd141b", "\(label)"))
            .accessibilityHint(refused ? L10n.text("apple.clientpinnedworksection.the_shelf_holds_eight_pins.5cd37254") : L10n.text("apple.clientpinnedworksection.keep_this_on_home.ee17cc72"))
        }
    }
}
#endif
