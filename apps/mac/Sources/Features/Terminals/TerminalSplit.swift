// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import SwiftUI

/// How the workspace terminal column is arranged.
///
/// Stored per folder. Session pairing is not: the focused tab and the other
/// half are live, and a persisted client id would be stale after a relaunch.
enum TerminalSplitLayout: String, Sendable, Equatable {
    case single
    case side
    case stacked

    var isSplit: Bool { self != .single }

    var axis: Axis? {
        switch self {
        case .single: return nil
        case .side: return .horizontal
        case .stacked: return .vertical
        }
    }
}

extension WorkspacePreference {
    private static let splitKey = "workspace.split"
    private static let splitFractionKey = "workspace.splitFraction"
    private static let consoleShellKey = "workspace.consoleShell"

    static func splitLayout(for workspaceID: String) -> TerminalSplitLayout {
        let raw = UserDefaults.standard.string(forKey: "\(splitKey).\(workspaceID)") ?? ""
        return TerminalSplitLayout(rawValue: raw) ?? .single
    }

    static func setSplitLayout(_ layout: TerminalSplitLayout, for workspaceID: String) {
        let key = "\(splitKey).\(workspaceID)"
        if layout == .single {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(layout.rawValue, forKey: key)
        }
    }

    static func splitFraction(for workspaceID: String) -> Double {
        let value = UserDefaults.standard.double(forKey: "\(splitFractionKey).\(workspaceID)")
        return value > 0 ? min(0.8, max(0.2, value)) : 0.5
    }

    static func setSplitFraction(_ fraction: Double, for workspaceID: String) {
        UserDefaults.standard.set(fraction, forKey: "\(splitFractionKey).\(workspaceID)")
    }

    static func inspectorShellHostID(for workspaceID: String) -> String? {
        UserDefaults.standard.string(forKey: "\(consoleShellKey).\(workspaceID)")
    }

    static func setInspectorShellHostID(_ hostID: String?, for workspaceID: String) {
        let key = "\(consoleShellKey).\(workspaceID)"
        if let hostID, !hostID.isEmpty {
            UserDefaults.standard.set(hostID, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// Drag handle between two terminal halves.
struct TerminalSplitHandle: View {
    let axis: Axis
    @Binding var fraction: Double

    var body: some View {
        GeometryReader { geo in
            let length = axis == .horizontal ? geo.size.width : geo.size.height
            let minFrac = min(0.45, max(0.2, 240 / max(length, 1)))
            let pos = length * fraction
            Rectangle()
                .fill(Theme.border)
                .frame(
                    width: axis == .horizontal ? 1 : geo.size.width,
                    height: axis == .vertical ? 1 : geo.size.height
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                .padding(
                    axis == .horizontal ? .leading : .top,
                    max(0, pos - 0.5)
                )
                .contentShape(splitHitBox(in: geo.size, at: pos))
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let raw = axis == .horizontal
                                ? value.location.x / max(length, 1)
                                : value.location.y / max(length, 1)
                            fraction = min(1 - minFrac, max(minFrac, raw))
                        }
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                        if axis == .vertical {
                            NSCursor.pop()
                            NSCursor.resizeUpDown.push()
                        }
                    } else {
                        NSCursor.pop()
                    }
                }
        }
        .allowsHitTesting(true)
    }

    private var alignment: Alignment {
        axis == .horizontal ? .leading : .top
    }

    private func splitHitBox(in size: CGSize, at pos: CGFloat) -> Path {
        if axis == .horizontal {
            return Path(CGRect(x: pos - 4, y: 0, width: 8, height: size.height))
        }
        return Path(CGRect(x: 0, y: pos - 4, width: size.width, height: 8))
    }
}

/// Empty half: a session has not been placed here yet.
struct TerminalSplitPlaceholder: View {
    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: ActionIcon.compare.symbol)
                .font(Theme.font(22, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.65))
            Text("Another session")
                .font(Theme.callout.weight(.medium))
            Text("Option-click a tab, or pick Open in split.")
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
#endif
