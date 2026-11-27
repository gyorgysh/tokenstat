// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

enum ActionIcon {
    case save
    case claim
    case create
    case upload
    case copy
    case download

    case signIn
    case signOut
    case account
    case settings
    case security
    case team
    case invite
    case permissions
    case edit

    case plans
    case billing
    case appStore
    case playStore
    case autoRenew
    case downgrade
    case cancelPlan
    case token
    case preview
    case visibility
    case theme
    case layout

    case connect
    case disconnect
    case approve
    case pair
    case refresh
    case revoke
    case device

    case run
    case stop
    case history
    case move
    case archive
    case restore
    case pin
    case pinned
    case browser
    case collapse
    case commit
    case merge
    case comment
    case reopen
    case checkout
    case filter
    case enterFullScreen
    case exitFullScreen

    case delete

    case external
    case next
    case latest
    case back
    case more
    case search
    case searchAll
    case reveal
    case docs
    case source
    case profile
    case home
    case help

    case send
    case attach
    case dictate
    case fastMode
    case routing
    case persona
    case plan
    case allow
    case deny
    case apply
    case calculate
    case compare
    case benchmarks

    case dismiss
    case done
    case hideKeyboard
    case scheduled
    case currentPlan

    var symbol: String {
        switch self {
        case .save, .currentPlan, .done: return "checkmark"
        case .claim, .approve: return "checkmark.seal"
        case .create: return "plus"
        case .upload: return "arrow.up.circle"
        case .copy: return "doc.on.doc"
        case .download: return "arrow.down.circle"

        case .signIn: return "person.crop.circle"
        case .signOut: return "rectangle.portrait.and.arrow.right"
        case .account, .profile: return "person.crop.circle"
        case .settings: return "gearshape"
        case .security: return "lock.shield"
        case .team: return "person.2"
        case .invite: return "person.badge.plus"
        case .permissions: return "lock.shield"
        case .edit: return "pencil"

        case .plans: return "crown"
        case .billing: return "creditcard"
        case .appStore: return "arrow.up.forward.app"
        case .playStore: return "play.rectangle"
        case .autoRenew: return "arrow.triangle.2.circlepath"
        case .downgrade: return "arrow.down"
        case .cancelPlan, .dismiss: return "xmark"
        case .hideKeyboard: return "keyboard.chevron.compact.down"
        case .token, .pair: return "key"
        case .preview, .visibility: return "eye"
        case .theme: return "paintpalette"
        case .layout: return "square.grid.2x2"

        case .connect: return "link"
        case .disconnect: return "xmark.circle"
        case .refresh: return "arrow.clockwise"
        case .revoke: return "minus.circle"
        case .device: return "laptopcomputer"

        case .run: return "play"
        case .stop: return "stop"
        case .history: return "clock.arrow.circlepath"
        case .move: return "arrow.right.circle"
        case .archive: return "archivebox"
        case .restore: return "arrow.uturn.backward"
        case .pin: return "pin"
        case .pinned: return "pin.fill"
        case .browser: return "globe"
        case .collapse: return "chevron.up"
        case .enterFullScreen: return "arrow.up.left.and.arrow.down.right"
        case .exitFullScreen: return "arrow.down.right.and.arrow.up.left"
        case .commit: return "checkmark.circle"
        case .merge: return "arrow.triangle.merge"
        case .comment: return "bubble.left"
        case .reopen: return "arrow.uturn.backward.circle"
        case .checkout: return "arrow.down.to.line"
        case .filter: return "line.3.horizontal.decrease"

        case .delete: return "trash"

        case .external: return "arrow.up.right"
        case .next: return "arrow.right"
        case .latest: return "arrow.down"
        case .back: return "arrow.left"
        case .more: return "chevron.down"
        case .search: return "magnifyingglass"
        case .searchAll: return "text.magnifyingglass"
        case .reveal: return "folder"
        case .docs: return "book"
        case .source: return "chevron.left.forwardslash.chevron.right"
        case .home: return "house"
        case .help: return "questionmark.circle"

        case .send: return "paperplane"
        case .attach: return "paperclip"
        case .dictate: return "mic"
        case .fastMode: return "bolt.fill"
        case .routing: return "arrow.triangle.branch"
        case .persona: return "person.text.rectangle"
        case .plan: return "list.clipboard"
        case .allow: return "checkmark.circle"
        case .deny: return "xmark.circle"
        case .apply: return "line.3.horizontal.decrease.circle"
        case .calculate: return "plus.forwardslash.minus"
        case .compare: return "rectangle.split.2x1"
        case .benchmarks: return "chart.bar"

        case .scheduled: return "clock"
        }
    }

    var trails: Bool {
        switch self {
        case .next, .latest, .external, .more, .collapse: return true
        default: return false
        }
    }

    func label(_ title: String) -> ActionLabel {
        ActionLabel(title: title, icon: self)
    }
}

private struct CompactActionsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Buttons under this draw their glyph alone, with the title as the help
    /// and the accessibility label.
    ///
    /// For chrome that has run out of width. A row of buttons in a narrow
    /// window has three ways to go: wrap the labels, which turns "Library" into
    /// one letter per line, scroll, which puts Save and Run somewhere off the
    /// right edge, or shrink. This is shrink, and it is the only one of the
    /// three that keeps every action both readable and reachable.
    var compactActions: Bool {
        get { self[CompactActionsKey.self] }
        set { self[CompactActionsKey.self] = newValue }
    }
}

struct ActionLabel: View {
    let title: String
    let icon: ActionIcon

    @Environment(\.compactActions) private var compact

    var body: some View {
        if compact {
            Image(systemName: icon.symbol)
                .accessibilityLabel(title)
                .help(title)
        } else if icon.trails {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: icon.symbol)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
        } else {
            Label(title, systemImage: icon.symbol)
        }
    }
}

extension Button where Label == ActionLabel {
    init(_ title: String, _ icon: ActionIcon, action: @escaping () -> Void) {
        self.init(action: action) { icon.label(title) }
    }

    init(_ title: String, _ icon: ActionIcon, role: ButtonRole?, action: @escaping () -> Void) {
        self.init(role: role, action: action) { icon.label(title) }
    }
}

struct ActionSeat: View {
    let icon: ActionIcon
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(Theme.accent.opacity(0.12))
            Image(systemName: icon.symbol)
                .font(Theme.font(size * 0.44, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
