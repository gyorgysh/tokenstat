// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

#if !os(macOS)
import SwiftUI

extension Account {
    /// The scope pins file under. Same account the recent places use, so a
    /// pin and the history row it came from never disagree about whose they
    /// are.
    var pinnedWorkScope: WorkReference.Scope? {
        guard signedIn else { return nil }
        return PinnedWorkStore.scope(host: host, handle: handle)
    }
}

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

/// Pin and unpin, with the sealed copy following the pin.
///
/// A pinned conversation's copy survives age eviction; unpinning hands it
/// back to the ordinary quota. Either way the pin itself is only ever
/// identifiers and a label.
@MainActor
enum PinnedWorkActions {
    @discardableResult
    static func pin(_ reference: WorkReference, label: String, folderName: String) async -> Bool {
        guard PinnedWorkStore.shared.pin(reference, label: label, folderName: folderName) else { return false }
        await WorkCacheStore.shared.setPinned(true, for: reference)
        return true
    }

    static func unpin(_ reference: WorkReference) async {
        PinnedWorkStore.shared.unpin(reference)
        await WorkCacheStore.shared.setPinned(false, for: reference)
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

    private var pins: [PinnedWorkStore.Pin] {
        pinsStore.pins(in: account.account?.pinnedWorkScope)
    }

    var body: some View {
        if !pins.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ClientSectionTitle(title: "Pinned", mark: "mark_pin")
                VStack(spacing: 0) {
                    ForEach(pins.indices, id: \.self) { index in
                        let pin = pins[index]
                        if let place = pin.place {
                            HStack(spacing: 0) {
                                NavigationLink {
                                    ClientSavedPlaceView(place: place)
                                } label: {
                                    content(pin)
                                }
                                .buttonStyle(.plain)
                                Button {
                                    Task { await PinnedWorkActions.unpin(pin.reference) }
                                } label: {
                                    ActionIcon.pinned.label("Unpin \(pin.label)")
                                        .labelStyle(.iconOnly)
                                        .font(ClientType.body)
                                        .foregroundStyle(Theme.accent)
                                        .frame(width: 44, height: 44)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Unpin \(pin.label)")
                                .accessibilityHint("Removes this from Home. The conversation stays where it is.")
                            }
                            if index != pins.indices.last {
                                ThemeRule().padding(.horizontal, Theme.Space.m)
                            }
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
        let state = connectivity.isOffline ? "Asleep"
            : machine == nil ? "No longer linked"
            : machine?.online == true ? "Awake"
            : machine?.online == false ? "Asleep" : "Status unknown"
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
                (Text("\(pin.folderName) · \(machine?.displayName ?? "Machine") · \(state)")
                    + Text(" · Pinned"))
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
                (pinned ? ActionIcon.pinned : ActionIcon.pin).label(pinned ? "Pinned" : "Pin")
                    .labelStyle(.iconOnly)
                    .font(ClientType.body)
                    .foregroundStyle(pinned ? Theme.accent : refused ? Theme.danger : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pinned ? "Unpin \(label)" : "Pin \(label)")
            .accessibilityHint(refused ? "The shelf holds eight pins" : "Keep this on Home")
        }
    }
}
#endif
