import SwiftUI

/// The action vocabulary: one case per thing a button does, one glyph per case.
///
/// The twin of `shared/web/actionIcons.js` on tokenstat.ai. The case names are
/// deliberately identical to the keys there, so "save" is a checkmark in the
/// app and on the website, and a reviewer can diff the two lists. Add a case
/// here and add the key there in the same change.
///
/// Symbols rather than the site's Lucide paths: SF Symbols scale with Dynamic
/// Type, match the optical weight of the surrounding text for free, and stay
/// native next to the platform chrome. Same meaning, drawn in the local accent.
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

    // Jobs, runs and cards — app-only, no website twin (there is no scheduler
    // or board on the site). Kept in the same enum so a run button and a save
    // button are still picked from one list.
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

        case .signIn: return "rectangle.portrait.and.arrow.forward"
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

    /// Whether the glyph belongs after the title instead of before it.
    ///
    /// Only the ones that point somewhere: an arrow that means "onwards" reads
    /// backwards when it sits to the left of the word it is pushing.
    var trails: Bool {
        switch self {
        case .next, .external, .more, .collapse: return true
        default: return false
        }
    }

    /// The label to put inside a button: glyph, then title (or the reverse for
    /// the pointing ones).
    func label(_ title: String) -> ActionLabel {
        ActionLabel(title: title, icon: self)
    }
}

/// A button's contents: one glyph and one title, in the order the action wants.
///
/// The leading case stays a real `Label`, so menus and toolbars keep the
/// platform's own treatment of icon-and-title.
struct ActionLabel: View {
    let title: String
    let icon: ActionIcon

    var body: some View {
        if icon.trails {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: icon.symbol)
                    .imageScale(.small)
            }
        } else {
            Label(title, systemImage: icon.symbol)
        }
    }
}

extension Button where Label == ActionLabel {
    /// `Button("Save", .save) { … }` — the one-line way to give an action its
    /// glyph. Keeps every call site honest: the icon comes from the vocabulary,
    /// never from a symbol name typed inline.
    init(_ title: String, _ icon: ActionIcon, action: @escaping () -> Void) {
        self.init(action: action) { icon.label(title) }
    }

    /// The `role:` variant, for destructive and cancel actions outside alerts.
    /// Alerts and confirmation dialogs stay text-only on purpose — the platform
    /// draws those buttons itself, and a glyph on "Don't Save" reads as a trap.
    init(_ title: String, _ icon: ActionIcon, role: ButtonRole?, action: @escaping () -> Void) {
        self.init(role: role, action: action) { icon.label(title) }
    }
}
