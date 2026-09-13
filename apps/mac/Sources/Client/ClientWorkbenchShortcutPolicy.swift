// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation

/// The iPhone/iPad keyboard map, in one place, without any view code.
///
/// Views translate these into real buttons (`ClientShortcut` or
/// `.keyboardShortcut` on the toolbar button that already performs the
/// action), so holding Command lists the same titles that touch users tap.
/// Keeping the keys here means the standalone tests can prove the collision
/// rules without a simulator: nothing here may claim bare Return (that would
/// start work from chat composition), nothing here may claim the terminal's
/// forwarding chords, and every entry states when it refuses to fire.
///
/// Scoping is part of the contract and lives with the views, not here:
/// editor shortcuts mount only in editor surfaces, job shortcuts only in the
/// job surface they act on, and terminal screens mount none of these so typed
/// keys keep reaching the program.
enum WorkbenchShortcut: String, CaseIterable {
    case save
    case find
    case findNext
    case findPrevious
    case new
    case run
    case inspector

    /// Modifiers as plain flags so this file compiles without SwiftUI.
    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
    }

    /// The printable key, lowercased. Never Return: starting work always
    /// names its target through a confirm, never through a bare key.
    var key: String {
        switch self {
        case .save: return "s"
        case .find: return "f"
        case .findNext: return "g"
        case .findPrevious: return "g"
        case .new: return "n"
        case .run: return "r"
        case .inspector: return "i"
        }
    }

    var modifiers: Modifiers {
        switch self {
        case .save: return .command
        case .find: return .command
        case .findNext: return .command
        case .findPrevious: return [.command, .shift]
        case .new: return .command
        case .run: return [.command, .shift]
        case .inspector: return [.command, .option]
        }
    }

    /// True when this entry is bare Return, which the map forbids.
    var isBareReturn: Bool { key == "\r" || key == "\n" }
}

/// When the editor shortcuts may fire.
struct EditorShortcutState: Equatable {
    var dirty = false
    var saving = false
    /// A newer host copy is waiting for an explicit choice.
    var conflict = false
    var canNavigate = false
    var findShowing = false
    /// A terminal cover owns the keyboard; typed keys go to the program.
    var terminalOpen = false
}

/// When the focused job Run shortcut may fire.
struct JobRunShortcutState: Equatable {
    var working = false
    var hasSelection = false
    var hasLiveRun = false
    /// An unconfirmed create/run is waiting for Check/Retry, not a new Run.
    var hasPendingLaunch = false
    /// An editor, history sheet or confirm is already on screen.
    var modalPresented = false
    var terminalOpen = false
}

/// When the contextual New shortcut may fire.
struct NewShortcutState: Equatable {
    var modalPresented = false
    var terminalOpen = false
}

/// When the inspector toggle may fire.
struct InspectorShortcutState: Equatable {
    /// False where there is no inspector to show (no folder, compact phone
    /// without a pushed surface, unknown workspace).
    var hasIdentity = false
    var terminalOpen = false
}

enum WorkbenchShortcutPolicy {
    /// Save writes the open draft. Refuses while clean, while a save is in
    /// flight, while a conflict waits for Reload/Keep, and while a terminal
    /// owns the keyboard.
    static func canSave(_ state: EditorShortcutState) -> Bool {
        guard !state.terminalOpen else { return false }
        return state.dirty && !state.saving && !state.conflict
    }

    /// Find toggles the bar. Always available in the editor except over a
    /// terminal, where Command-F belongs to the program.
    static func canFind(_ state: EditorShortcutState) -> Bool {
        !state.terminalOpen
    }

    /// Next/previous match. When the bar is hidden the same chord opens it
    /// instead of doing nothing, so the shortcut stays enabled there; the
    /// views route hidden-presses to `showing = true` and visible-presses to
    /// `goNext`/`goPrevious`, which no-op honestly without matches.
    static func canFindNext(_ state: EditorShortcutState) -> Bool {
        guard !state.terminalOpen else { return false }
        return state.findShowing ? state.canNavigate : true
    }

    static func canFindPrevious(_ state: EditorShortcutState) -> Bool {
        guard !state.terminalOpen else { return false }
        return state.findShowing ? state.canNavigate : true
    }

    /// Focused Run. Only for the selected job on screen, only when starting
    /// is unambiguous, and never while a modal or terminal owns the screen.
    /// Task placement (foreground/background/chat) stays an explicit choice,
    /// so tasks expose no single-key Run.
    static func canRun(_ state: JobRunShortcutState) -> Bool {
        guard !state.modalPresented, !state.terminalOpen else { return false }
        guard !state.working, state.hasSelection else { return false }
        return !state.hasLiveRun && !state.hasPendingLaunch
    }

    /// Contextual New (task/automation/workflow for the open surface).
    static func canCreate(_ state: NewShortcutState) -> Bool {
        !state.modalPresented && !state.terminalOpen
    }

    /// Inspector toggle (workspace tools, review pane). Needs something to
    /// show and a screen that is not a terminal.
    static func canToggleInspector(_ state: InspectorShortcutState) -> Bool {
        state.hasIdentity && !state.terminalOpen
    }

    /// Every entry in the map, for the no-collision tests.
    static func binding(of shortcut: WorkbenchShortcut) -> (key: String, modifiers: WorkbenchShortcut.Modifiers) {
        (shortcut.key, shortcut.modifiers)
    }
}
