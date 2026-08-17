// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// One glyph per action. Case names match `shared/web/actionIcons.js`.
enum ActionIcon {
    // Confirm and create
    case save
    case claim
    case create
    case upload
    case copy
    case download

    // Account and session
    case signIn
    case signOut
    case account
    case settings
    case security
    case edit

    // Money
    case plans
    case billing
    case appStore
    case autoRenew
    case downgrade
    case cancelPlan
    case token
    case preview
    case visibility
    case theme
    case layout

    // Devices and sync
    case connect
    case disconnect
    case approve
    case pair
    case refresh
    case revoke
    case device

    // Jobs, runs and cards. App-only cases, same enum so every button
    // still picks from one list.
    case run
    case stop
    case history
    case move
    case archive
    case restore
    case browser
    case collapse
    case commit

    // Destructive
    case delete

    // Navigation out of the current surface
    case external
    case next
    case back
    case more
    case search
    case reveal
    case docs
    case source
    case profile
    case home
    case help

    // Tools
    case send
    case apply
    case calculate
    case compare
    case benchmarks

    // States that sit in a button row and would otherwise be the one bare
    // capsule among glyphed ones.
    case dismiss
    case done
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
        case .edit: return "pencil"

        case .plans: return "crown"
        case .billing: return "creditcard"
        case .appStore: return "arrow.up.forward.app"
        case .autoRenew: return "arrow.triangle.2.circlepath"
        case .downgrade: return "arrow.down"
        case .cancelPlan, .dismiss: return "xmark"
        case .token, .pair: return "key"
        case .preview, .visibility: return "eye"
        case .theme: return "paintpalette"
        case .layout: return "square.grid.2x2"

        case .connect: return "cable.connector"
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
        case .browser: return "globe"
        case .collapse: return "chevron.up"
        case .commit: return "checkmark.circle"

        case .delete: return "trash"

        case .external: return "arrow.up.right"
        case .next: return "arrow.right"
        case .back: return "arrow.left"
        case .more: return "chevron.down"
        case .search: return "magnifyingglass"
        case .reveal: return "folder"
        case .docs: return "book"
        case .source: return "chevron.left.forwardslash.chevron.right"
        case .home: return "house"
        case .help: return "questionmark.circle"

        case .send: return "paperplane"
        case .apply: return "line.3.horizontal.decrease.circle"
        case .calculate: return "plus.forwardslash.minus"
        case .compare: return "rectangle.split.2x1"
        case .benchmarks: return "chart.bar"

        case .scheduled: return "clock"
        }
    }

    /// Arrow actions sit after the title so they point onward.
    var trails: Bool {
        switch self {
        case .next, .external, .more, .collapse: return true
        default: return false
        }
    }

    func label(_ title: String) -> ActionLabel {
        ActionLabel(title: title, icon: self)
    }
}

/// Glyph and title, in the order `trails` asks for.
struct ActionLabel: View {
    let title: String
    let icon: ActionIcon

    var body: some View {
        if icon.trails {
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
    /// `Button("Save", .save) { … }`
    init(_ title: String, _ icon: ActionIcon, action: @escaping () -> Void) {
        self.init(action: action) { icon.label(title) }
    }

    /// Destructive and cancel actions outside alerts. Alerts stay text-only.
    init(_ title: String, _ icon: ActionIcon, role: ButtonRole?, action: @escaping () -> Void) {
        self.init(role: role, action: action) { icon.label(title) }
    }
}
