// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Observation
import Foundation

@MainActor
@Observable
final class SSHSessionsModel {
    private(set) var sessions: [SSHLiveTerminal] = []
    var selectedID: String?
    var error: String?
    private(set) var loaded = false
    @ObservationIgnored private var active = true
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var reconcileFlights: [UInt64: Singleflight<Bool>] = [:]
    @ObservationIgnored private var startupTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var startupTickets: [String: UUID] = [:]
    @ObservationIgnored private var startups: [String: Startup] = [:]
    @ObservationIgnored private let startupSleep: @MainActor (UInt64) async throws -> Void
    @ObservationIgnored private let isOwnerCurrent: @MainActor () -> Bool
    private struct Startup { var commands: [[UInt8]]; var next = 0 }
    private(set) var closeErrors: [String: String] = [:]

    init(isOwnerCurrent: @escaping @MainActor () -> Bool = { true },
         startupSleep: @escaping @MainActor (UInt64) async throws -> Void = {
        try await Task.sleep(for: .milliseconds($0))
    }) {
        self.startupSleep = startupSleep
        self.isOwnerCurrent = isOwnerCurrent
    }

    private var selectedByHost: [String: String] = [:]

    @ObservationIgnored private var closingIDs: Set<String> = []

    var selected: SSHLiveTerminal? {
        sessions.first { $0.id == selectedID }
    }

    func sessions(for hostID: String) -> [SSHLiveTerminal] {
        sessions.filter { $0.hostID == hostID }
    }

    var looseSessions: [SSHLiveTerminal] {
        sessions.filter { $0.hostID == nil }
    }

    func liveCount(for hostID: String) -> Int {
        sessions(for: hostID).filter(\.alive).count
    }

    func activeSession(for hostID: String) -> SSHLiveTerminal? {
        let mine = sessions(for: hostID)
        return mine.first { $0.id == selectedID }
            ?? mine.first { $0.id == selectedByHost[hostID] }
            ?? mine.last
    }


    @discardableResult
    func reconcile() async -> Bool {
        let attempt = epoch
        guard isCurrent(attempt) else { return false }
        let flight = reconcileFlights[attempt] ?? Singleflight<Bool>()
        reconcileFlights[attempt] = flight
        defer {
            if reconcileFlights[attempt] === flight { reconcileFlights.removeValue(forKey: attempt) }
        }
        return await flight.run { [self] in
            guard isCurrent(attempt) else { return false }
            let observed = Set(sessions.map(\.id))
            do {
                let summaries = try await Bridge.sshSessions()
                guard isCurrent(attempt) else { return false }
                var known = Set(sessions.map(\.id))
                for summary in summaries where !closingIDs.contains(summary.id) && known.insert(summary.id).inserted {
                    let terminal = SSHLiveTerminal(adopting: summary)
                    terminal.setForeground(foreground)
                    sessions.append(terminal)
                }
                let held = Set(summaries.map(\.id))
                let ended = Set(summaries.filter { !$0.alive }.map(\.id))
                for session in sessions where session.alive && observed.contains(session.id)
                    && (!held.contains(session.id) || ended.contains(session.id)) {
                    session.markClosed()
                }
                if selectedID == nil || !sessions.contains(where: { $0.id == selectedID }) {
                    let next = sessions.last?.id
                    if selectedID != next { selectedID = next }
                }
                if !loaded { loaded = true }
                if error != nil { error = nil }
                return true
            } catch {
                guard isCurrent(attempt) else { return false }
                if self.error != error.localizedDescription { self.error = error.localizedDescription }
                return false
            }
        }
    }

    func watch() async {
        while active && !Task.isCancelled {
            await reconcile()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func isCurrent(_ value: UInt64) -> Bool { active && foreground && epoch == value && isOwnerCurrent() }

    func setForeground(_ value: Bool) {
        guard active, foreground != value else { return }
        foreground = value
        epoch &+= 1
        reconcileFlights.removeAll()
        cancelStartups()
        for session in sessions { session.setForeground(value) }
        if value {
            for session in sessions { resumeStartup(in: session) }
            let attempt = epoch
            Task { [weak self] in
                guard let self, self.isCurrent(attempt) else { return }
                await self.reconcile()
            }
        }
    }


    @discardableResult
    func adopt(_ session: SSHLiveTerminal, startup: [SSHSnippet] = []) -> SSHLiveTerminal? {
        guard active, isOwnerCurrent(), !closingIDs.contains(session.id) else {
            session.detachPoll()
            return nil
        }
        // One object per session id, always.
        //
        // Opening a shell and the five-second bookkeeping poll race each
        // other: `ssh.session.list` reports a new session the moment the host
        // creates it, which is before `openSSHSession` has returned and before
        // this method is called. A `reconcile` landing in that window adopts
        // the same shell, so the list ended up holding two terminals for one
        // id, each running its own read loop from offset zero and each feeding
        // its own emulator with the same bytes. The tab strip then showed the
        // session twice, and a `ForEach` over identifiers that are no longer
        // unique renders whatever SwiftUI feels like.
        //
        // The one already in the list wins: it is what is on screen and what
        // has already drawn the scrollback. The newcomer lets go of its read
        // loop and is dropped. It must not be `stop()`ped, which would close
        // the shell both of them are pointing at.
        if let existing = sessions.first(where: { $0.id == session.id }), existing !== session {
            session.detachPoll()
            select(existing)
            start(startup, in: existing)
            return existing
        }
        if !sessions.contains(where: { $0 === session }) {
            session.setForeground(foreground)
            sessions.append(session)
        }
        select(session)
        start(startup, in: session)
        return session
    }

    private func start(_ snippets: [SSHSnippet], in session: SSHLiveTerminal) {
        guard !snippets.isEmpty, startups[session.id] == nil else { return }
        startups[session.id] = Startup(commands: snippets.filter {
            SSHSnippet.placeholders(in: $0.command).isEmpty
        }.map { SSHSnippet.bytesToRun($0.command) })
        resumeStartup(in: session)
    }

    private func resumeStartup(in session: SSHLiveTerminal) {
        let id = session.id
        guard isCurrent(epoch), !closingIDs.contains(id), session.alive,
              startupTickets[id] == nil, let progress = startups[id],
              progress.next < progress.commands.count else { return }
        let token = UUID(), attempt = epoch
        startupTickets[id] = token
        let sleep = startupSleep
        startupTasks[id] = Task { [weak self, weak session] in
            defer {
                if self?.startupTickets[id] == token {
                    self?.startupTickets.removeValue(forKey: id)
                    self?.startupTasks.removeValue(forKey: id)
                }
            }
            do {
                try await sleep(progress.next == 0 ? 600 : 120)
                while !Task.isCancelled {
                    guard let self, self.isCurrent(attempt), self.startupTickets[id] == token,
                          let session, session.alive, self.sessions.contains(where: { $0 === session }),
                          let next = self.startups[id], next.next < next.commands.count else { return }
                    let dispatched = await session.sendStartupBytes(next.commands[next.next]) { [weak self] in
                        guard let self, !Task.isCancelled, self.isCurrent(attempt),
                              self.startupTickets[id] == token, !self.closingIDs.contains(id) else { return false }
                        self.startups[id]?.next += 1
                        return true
                    }
                    guard dispatched else { return }
                    try await sleep(120)
                }
            } catch { return }
        }
    }

    private func cancelStartups() {
        for task in startupTasks.values { task.cancel() }
        startupTasks.removeAll()
        startupTickets.removeAll()
    }

    func deactivate() {
        guard active else { return }
        active = false
        epoch &+= 1
        reconcileFlights.removeAll()
        cancelStartups()
        startups.removeAll()
        for session in sessions { session.detachPoll() }
    }

    func select(_ session: SSHLiveTerminal) {
        guard active, isOwnerCurrent(), sessions.contains(where: { $0 === session }) else { return }
        #if os(macOS)
        if let hostID = session.hostID {
            var selection = paneSelection(for: hostID)
            selection.select(session.id, available: sessions(for: hostID).map(\.id),
                             split: layout(for: hostID).isSplit)
            apply(selection, for: hostID)
        }
        #endif
        selectedID = session.id
        if let hostID = session.hostID { selectedByHost[hostID] = session.id }
    }

    func restoreSelection(for hostID: String) {
        guard active else { return }
        let mine = sessions(for: hostID)
        guard !mine.isEmpty else { return }
        if let remembered = selectedByHost[hostID], mine.contains(where: { $0.id == remembered }) {
            selectedID = remembered
        } else {
            selectedID = mine.last?.id
        }
    }

    @discardableResult
    func close(_ session: SSHLiveTerminal) async -> Bool {
        guard active, isOwnerCurrent(), sessions.contains(where: { $0 === session }), closingIDs.insert(session.id).inserted else { return false }
        startupTasks.removeValue(forKey: session.id)?.cancel()
        startupTickets.removeValue(forKey: session.id)
        if let count = startups[session.id]?.commands.count { startups[session.id]?.next = count }
        let succeeded = await session.closeRemote()
        guard active, isOwnerCurrent(), sessions.contains(where: { $0 === session }) else { return false }
        guard succeeded else {
            closingIDs.remove(session.id)
            closeErrors[session.id] = session.error ?? L10n.text("apple.sshliveterminal.could_not_end_retry")
            return false
        }
        closeErrors.removeValue(forKey: session.id)
        startups.removeValue(forKey: session.id)
        #if os(macOS)
        let oldSelection = session.hostID.map { paneSelection(for: $0) }
        #endif
        sessions.removeAll { $0.id == session.id }
        let selectedHosts = selectedByHost.compactMap { host, id in
            id == session.id ? host : nil
        }
        for host in selectedHosts {
            selectedByHost.removeValue(forKey: host)
        }
        #if os(macOS)
        if let hostID = session.hostID, var selection = oldSelection {
            if selection.reconcile(available: sessions(for: hostID).map(\.id)) {
                splitLayout[hostID] = .single
                SSHPreference.setSplitLayout(.single, for: hostID)
            }
            apply(selection, for: hostID)
        }
        #endif
        if selectedID == session.id {
            selectedID = session.hostID.flatMap { activeSession(for: $0)?.id } ?? sessions.last?.id
        }
        return true
    }

    func closeAll(for hostID: String) async {
        for session in sessions(for: hostID) {
            await close(session)
        }
    }


    #if os(macOS)
    private(set) var splitLayout: [String: TerminalSplitLayout] = [:]
    private(set) var splitFraction: [String: Double] = [:]
    private(set) var splitLeadingID: [String: String] = [:]
    private(set) var splitTrailingID: [String: String] = [:]

    private func paneSelection(for hostID: String) -> TerminalPaneSelection {
        TerminalPaneSelection(selectedID: activeSession(for: hostID)?.id,
                              leadingID: splitLeadingID[hostID], trailingID: splitTrailingID[hostID])
    }

    private func apply(_ selection: TerminalPaneSelection, for hostID: String) {
        selectedByHost[hostID] = selection.selectedID
        splitLeadingID[hostID] = selection.leadingID
        splitTrailingID[hostID] = selection.trailingID
    }

    func layout(for hostID: String) -> TerminalSplitLayout {
        if let cached = splitLayout[hostID] { return cached }
        let stored = SSHPreference.splitLayout(for: hostID)
        splitLayout[hostID] = stored
        return stored
    }

    func setLayout(_ layout: TerminalSplitLayout, for hostID: String) {
        splitLayout[hostID] = layout
        SSHPreference.setSplitLayout(layout, for: hostID)
        var selection = paneSelection(for: hostID)
        selection.setSplit(layout.isSplit, available: sessions(for: hostID).map(\.id))
        apply(selection, for: hostID)
    }

    func fraction(for hostID: String) -> Double {
        if let cached = splitFraction[hostID] { return cached }
        let stored = SSHPreference.splitFraction(for: hostID)
        splitFraction[hostID] = stored
        return stored
    }

    func swapPanes(in hostID: String) {
        guard layout(for: hostID).isSplit else { return }
        var selection = paneSelection(for: hostID)
        selection.swapPanes(available: sessions(for: hostID).map(\.id))
        apply(selection, for: hostID)
    }

    func setFraction(_ value: Double, for hostID: String) {
        let clamped = min(0.8, max(0.2, value))
        splitFraction[hostID] = clamped
        SSHPreference.setSplitFraction(clamped, for: hostID)
    }

    func leadingSession(in hostID: String) -> SSHLiveTerminal? {
        let mine = sessions(for: hostID)
        let id = paneSelection(for: hostID).panes(in: mine.map(\.id), split: layout(for: hostID).isSplit).leading
        return mine.first { $0.id == id }
    }

    func trailingSession(in hostID: String) -> SSHLiveTerminal? {
        let mine = sessions(for: hostID)
        let id = paneSelection(for: hostID).panes(in: mine.map(\.id), split: layout(for: hostID).isSplit).trailing
        return mine.first { $0.id == id }
    }

    func sendToOtherHalf(_ session: SSHLiveTerminal, in hostID: String) {
        guard session.hostID == hostID else { return }
        if !layout(for: hostID).isSplit { setLayout(.side, for: hostID) }
        var selection = paneSelection(for: hostID)
        selection.sendToOtherHalf(session.id, available: sessions(for: hostID).map(\.id))
        apply(selection, for: hostID)
        selectedID = selection.selectedID
    }

    #endif

    private func session(_ id: String?) -> SSHLiveTerminal? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }
}

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
