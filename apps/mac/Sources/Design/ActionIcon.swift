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
    case merge
    case comment
    case reopen
    case checkout
    case filter
    case enterFullScreen
    case exitFullScreen

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
    case attach
    case persona
    case plan
    case allow
    case deny
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

        // A plug, not the USB-C connector outline this used to be: that
        // glyph is a thin cable end, it reads as a port rather than as an
        // action, and it was carrying every Connect in the app. The website's
        // vocabulary already says "plug" for this key, so the two products
        // show the same picture now.
        case .connect: return "powerplug.fill"
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
        // The two arrows every platform draws for this, rather than the
        // generic "leaves this surface" arrow the button used to borrow.
        // Filling a display is not going somewhere else, and the pair also
        // says which direction it is about to go in.
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
        case .back: return "arrow.left"
        case .more: return "chevron.down"
        case .search: return "magnifyingglass"
        case .reveal: return "folder"
        case .docs: return "book"
        case .source: return "chevron.left.forwardslash.chevron.right"
        case .home: return "house"
        case .help: return "questionmark.circle"

        case .send: return "paperplane"
        case .attach: return "paperclip"
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

/// Glyph and title, in the order `trails` asks for.
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
    /// `Button("Save", .save) { … }`
    init(_ title: String, _ icon: ActionIcon, action: @escaping () -> Void) {
        self.init(action: action) { icon.label(title) }
    }

    /// Destructive and cancel actions outside alerts. Alerts stay text-only.
    init(_ title: String, _ icon: ActionIcon, role: ButtonRole?, action: @escaping () -> Void) {
        self.init(role: role, action: action) { icon.label(title) }
    }
}

/// An action's glyph on a tinted square.
///
/// The same seat `HarnessMark` draws a product logo on, at the same radius and
/// the same tint, so a row that leads with an action and a row that leads with
/// a harness read as one list rather than two. For whole-row targets, where the
/// glyph has to carry the row's weight and an inline `Label` is too small to
/// find.
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
