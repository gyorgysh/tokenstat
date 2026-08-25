// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Observation
import SwiftUI

/// The SSH sessions this app is showing.
///
/// The shape `TerminalsModel` already has for workspace terminals, and for the
/// same reason: the sessions belong to the host process, so this is a window
/// onto them rather than their owner. It reconciles against `ssh.session.list`,
/// adopts what a relaunch left running, and closes what somebody is done with.
///
/// It exists at all because an SSH terminal used to be `@State` in whichever
/// view happened to open it, presented as a cover. One at a time, nothing else
/// on screen, and closing the cover killed the shell. Nothing outside that one
/// view could know a session existed, which is why there were no tabs, no
/// split, and no sign of a live session anywhere in the sidebar.
@MainActor
@Observable
final class SSHSessionsModel {
    private(set) var sessions: [SSHLiveTerminal] = []
    /// The session the pane is showing, or the leading half when split.
    var selectedID: String?
    var error: String?

    /// Which host each pane was last looking at, so returning to a server
    /// opens on the session that was in front rather than on the first one.
    private var selectedByHost: [String: String] = [:]

    /// Sessions whose close is still in flight.
    ///
    /// Closing takes a tab off screen straight away and tells the host
    /// afterwards, so for a moment the host still lists a session this app has
    /// forgotten. Without this the next reconcile adopts it back and the tab
    /// somebody just closed reappears.
    @ObservationIgnored private var closingIDs: Set<String> = []

    var selected: SSHLiveTerminal? {
        sessions.first { $0.id == selectedID }
    }

    func sessions(for hostID: String) -> [SSHLiveTerminal] {
        sessions.filter { $0.hostID == hostID }
    }

    /// Sessions with no saved record behind them. A one-off connection is
    /// still a session and still needs somewhere to be listed.
    var looseSessions: [SSHLiveTerminal] {
        sessions.filter { $0.hostID == nil }
    }

    func liveCount(for hostID: String) -> Int {
        sessions(for: hostID).filter(\.alive).count
    }

    /// The session a host's pane is showing, or nil when it has none.
    ///
    /// Host-scoped on purpose. `selected` is global, so on a server whose pane
    /// has not been touched yet it names a shell on a different machine, and
    /// anything that types into it would type into the wrong server. The
    /// inspector and the pane both read this rather than each deciding, so a
    /// snippet cannot land somewhere other than the tab in front.
    func activeSession(for hostID: String) -> SSHLiveTerminal? {
        let mine = sessions(for: hostID)
        return mine.first { $0.id == selectedID } ?? mine.last
    }

    // MARK: - Reconciling with the host

    /// Adopt what the host is holding and let go of what it is not.
    ///
    /// Runs on a timer while a pane is open, and once at launch. A session the
    /// host has forgotten is dropped here rather than left as a tab that
    /// writes into nothing.
    func reconcile() async {
        guard let summaries = try? await Bridge.sshSessions() else { return }
        let known = Set(sessions.map(\.id))
        for summary in summaries where !known.contains(summary.id) && !closingIDs.contains(summary.id) {
            sessions.append(SSHLiveTerminal(adopting: summary))
        }
        let held = Set(summaries.map(\.id))
        // `ssh.session.list` reaps an ended shell before answering. Keep its
        // local terminal and scrollback until the person explicitly closes
        // the tab; otherwise the five-second bookkeeping poll can erase the
        // command's final output before it has been read. A session removed
        // explicitly is already absent from `sessions` and is unaffected.
        for session in sessions where session.alive && !held.contains(session.id) {
            session.markClosed()
        }
        closingIDs.formIntersection(held)
        if selectedID == nil || !sessions.contains(where: { $0.id == selectedID }) {
            selectedID = sessions.last?.id
        }
    }

    /// Keep the list honest while a pane is open. Slow on purpose: this is a
    /// bookkeeping poll, and the host excludes it from what holds sleep open.
    func watch() async {
        while !Task.isCancelled {
            await reconcile()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    // MARK: - Opening and closing

    /// Take a freshly opened session, select it, and remember it for its host.
    func adopt(_ session: SSHLiveTerminal) {
        sessions.append(session)
        select(session)
    }

    func select(_ session: SSHLiveTerminal) {
        selectedID = session.id
        if let hostID = session.hostID { selectedByHost[hostID] = session.id }
    }

    /// The session to show when a host's pane opens.
    func restoreSelection(for hostID: String) {
        let mine = sessions(for: hostID)
        guard !mine.isEmpty else { return }
        if let remembered = selectedByHost[hostID], mine.contains(where: { $0.id == remembered }) {
            selectedID = remembered
        } else {
            selectedID = mine.last?.id
        }
    }

    func close(_ session: SSHLiveTerminal) async {
        closingIDs.insert(session.id)
        sessions.removeAll { $0.id == session.id }
        if selectedID == session.id { selectedID = sessions.last?.id }
        let selectedHosts = selectedByHost.compactMap { host, id in
            id == session.id ? host : nil
        }
        for host in selectedHosts {
            selectedByHost.removeValue(forKey: host)
        }
        #if os(macOS)
        // Splits name sessions by id, so a half pointing at a closed one has
        // to let go or the pane draws an empty rectangle beside a live shell.
        let leadingHosts = splitLeadingID.compactMap { host, id in
            id == session.id ? host : nil
        }
        for host in leadingHosts {
            splitLeadingID.removeValue(forKey: host)
        }
        let trailingHosts = splitTrailingID.compactMap { host, id in
            id == session.id ? host : nil
        }
        for host in trailingHosts {
            splitTrailingID.removeValue(forKey: host)
        }
        #endif
        session.stop()
    }

    /// Close every session on one host. Used when a saved record is deleted.
    func closeAll(for hostID: String) async {
        for session in sessions(for: hostID) {
            await close(session)
        }
    }

    // MARK: - Layout

    #if os(macOS)
    /// How each host's pane is arranged. Per host rather than global, because
    /// two servers are two workspaces: a split that suits a log tail beside an
    /// editor has no business following you to a different machine.
    private(set) var splitLayout: [String: TerminalSplitLayout] = [:]
    private(set) var splitFraction: [String: Double] = [:]
    private(set) var splitLeadingID: [String: String] = [:]
    private(set) var splitTrailingID: [String: String] = [:]

    func layout(for hostID: String) -> TerminalSplitLayout {
        if let cached = splitLayout[hostID] { return cached }
        let stored = SSHPreference.splitLayout(for: hostID)
        splitLayout[hostID] = stored
        return stored
    }

    func setLayout(_ layout: TerminalSplitLayout, for hostID: String) {
        splitLayout[hostID] = layout
        SSHPreference.setSplitLayout(layout, for: hostID)
        guard layout.isSplit else {
            splitTrailingID.removeValue(forKey: hostID)
            return
        }
        // Turning a split on with nothing in the other half shows a live
        // terminal beside an empty rectangle, so the second-newest session
        // fills it. Nothing to fill it with is not a split.
        if splitTrailingID[hostID] == nil {
            let mine = sessions(for: hostID)
            let other = mine.last { $0.id != selectedID }
            splitTrailingID[hostID] = other?.id
        }
        splitLeadingID[hostID] = splitLeadingID[hostID] ?? selectedID
    }

    func fraction(for hostID: String) -> Double {
        if let cached = splitFraction[hostID] { return cached }
        let stored = SSHPreference.splitFraction(for: hostID)
        splitFraction[hostID] = stored
        return stored
    }

    func setFraction(_ value: Double, for hostID: String) {
        let clamped = min(0.8, max(0.2, value))
        splitFraction[hostID] = clamped
        SSHPreference.setSplitFraction(clamped, for: hostID)
    }

    func leadingSession(in hostID: String) -> SSHLiveTerminal? {
        session(splitLeadingID[hostID]) ?? selected
    }

    func trailingSession(in hostID: String) -> SSHLiveTerminal? {
        session(splitTrailingID[hostID])
    }

    /// Put a session in the half that is not showing it, so a tab can be
    /// dragged into the other side without a drag.
    func sendToOtherHalf(_ session: SSHLiveTerminal, in hostID: String) {
        guard layout(for: hostID).isSplit else { return }
        if splitLeadingID[hostID] == session.id { return }
        splitTrailingID[hostID] = session.id
    }

    #endif

    private func session(_ id: String?) -> SSHLiveTerminal? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }
}

/// Where a host's pane layout is remembered.
///
/// Keyed by the saved record's id, which survives a relaunch. Which session
/// was in which half is not stored: those ids are handed out per connection
/// and a stored one would name a shell that no longer exists.
#if os(macOS)
enum SSHPreference {
    private static let splitKey = "ssh.split"
    private static let fractionKey = "ssh.splitFraction"

    static func splitLayout(for hostID: String) -> TerminalSplitLayout {
        let raw = UserDefaults.standard.string(forKey: "\(splitKey).\(hostID)") ?? ""
        return TerminalSplitLayout(rawValue: raw) ?? .single
    }

    static func setSplitLayout(_ layout: TerminalSplitLayout, for hostID: String) {
        let key = "\(splitKey).\(hostID)"
        if layout == .single {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(layout.rawValue, forKey: key)
        }
    }

    static func splitFraction(for hostID: String) -> Double {
        let value = UserDefaults.standard.double(forKey: "\(fractionKey).\(hostID)")
        return value > 0 ? min(0.8, max(0.2, value)) : 0.5
    }

    static func setSplitFraction(_ fraction: Double, for hostID: String) {
        UserDefaults.standard.set(fraction, forKey: "\(fractionKey).\(hostID)")
    }
}
#endif
