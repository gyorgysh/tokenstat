// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import AppKit
import Foundation
import Observation
import SwiftTerm
import SwiftUI

enum SessionState: Equatable {
    case none
    case starting
    case working
    case idle
    case needsAttention
    case done
    case failed
    case stopped

    var label: String {
        switch self {
        case .none: return L10n.text("apple.terminalsession.none.dc937b59")
        case .starting: return L10n.text("apple.terminalsession.starting.aeed4d26")
        case .working: return L10n.text("common.working")
        case .idle: return L10n.text("common.idle")
        case .needsAttention: return L10n.text("apple.terminalsession.needs_attention.c1ebc781")
        case .done: return L10n.text("common.done")
        case .failed: return L10n.text("common.failed")
        case .stopped: return L10n.text("apple.terminalsession.stopped.1a4f630a")
        }
    }
}

struct SessionMeter: Equatable, Sendable {
    var tokens: UInt64
    var costMicros: Int64?
    var estimated: Bool
    var complete: Bool
    var billing: String?
    var model: String?
    var contextUsed: UInt64?
    var contextWindow: UInt64?
    var contextEstimated: Bool

    var isPlan: Bool { billing == "plan" }
}

enum TerminalPreferences {
    private static let voiceOverKey = "terminal.accessibility.enabled"
    private static let noColorKey = "terminal.noColor.enabled"

    /// Expose the terminal's visible screen to VoiceOver as a text area.
    ///
    /// Defaults on when VoiceOver is already running the first time the key is
    /// read, so accessibility users are not left with a silent terminal until
    /// they find the Account toggle.
    ///
    /// Cached after the first read. This is checked on the output path, which
    /// for a printing process runs thousands of times a second, and a defaults
    /// lookup per line of a build log is a cost nobody asked for. The toggle
    /// writes through the cache, so the only way to miss a change is to edit
    /// the domain from outside the app.
    static var exposesToVoiceOver: Bool {
        get {
            if let cached = voiceOverCache { return cached }
            let value: Bool
            if UserDefaults.standard.object(forKey: voiceOverKey) == nil {
                value = NSWorkspace.shared.isVoiceOverEnabled
            } else {
                value = UserDefaults.standard.bool(forKey: voiceOverKey)
            }
            voiceOverCache = value
            return value
        }
        set {
            voiceOverCache = newValue
            UserDefaults.standard.set(newValue, forKey: voiceOverKey)
        }
    }

    private nonisolated(unsafe) static var voiceOverCache: Bool?

    static var disablesColor: Bool {
        get { UserDefaults.standard.bool(forKey: noColorKey) }
        set { UserDefaults.standard.set(newValue, forKey: noColorKey) }
    }
}

@MainActor
@Observable
final class TerminalSession: TerminalViewDelegate, TerminalPresentable {
    /// Stable for the life of this object. SwiftUI `ForEach` and selection use
    /// this, and it must never change: swapping it from `pending-…` to the
    /// host's `pty-N` made every chip and the terminal stack tear down and
    /// rebuild on attach, which is the blink / disappear / reappear glitch.
    let id: String
    private(set) var hostID: String
    nonisolated let workspaceID: String
    nonisolated let command: String
    nonisolated let cwd: String

    private(set) var sessionIdentities: SessionIdentities?
    var identityEntries: [SessionIdentityEntry] {
        SessionIdentityPresentation.entries(localID: isPending ? nil : hostID, kind: .terminal, sessions: sessionIdentities)
    }

    var workReference: WorkReference? {
        guard !isPending, let scope = WorkSessionContext.shared.scope else { return nil }
        let route = WorkDestinationResolver.route(folderID: workspaceID)
        guard let host = route.peer ?? WorkSessionContext.shared.localHostIdentity else { return nil }
        return WorkReference(scope: scope, hostIdentity: host, workspaceID: route.workspaceID,
                             kind: .terminal, itemID: hostID)
    }

    var customName: String? { SidebarTerminalNames.shared.name(for: workReference) }

    var harnessID: String? { Tokenstat.harnessID(forCommand: command) }

    var alive: Bool
    var exitCode: Int?
    var rows: Int
    var cols: Int

    /// The size AppKit last reported, kept outside observation.
    ///
    /// `sizeChanged` arrives from inside an AppKit layout pass. Comparing
    /// against `rows`/`cols` there would be an observed *read* during layout,
    /// and writing them would be an observed write, which invalidates SwiftUI
    /// mid-pass. This shadow is what the delegate compares and writes; the
    /// observed pair catches up on the next turn.
    ///
    /// Nil until the view has laid out and said what it can show. Seeding it
    /// from the host would defeat the point: the host's size is the size agreed
    /// across *every* viewer, so on a session a phone has already clamped it is
    /// the phone's, and adopting it would make this Mac announce the phone's
    /// width as its own and stay pinned to it.
    @ObservationIgnored private var reportedSize: (rows: Int, cols: Int)?

    var transportError: String?

    var title: String?
    var reportedCwd: String?

    var droppedOutput = false
    private(set) var outputPaused = false

    private(set) var hasOutput = false

    @ObservationIgnored private(set) var lastOutputAt: Date?

    private(set) var state: SessionState = .none
    private(set) var programStatus: PtyProgramStatus?

    var statusLabel: String {
        if state == .needsAttention { return programStatus?.attentionLabel ?? state.label }
        if state == .working, let progress = programStatus?.progress {
            return "\(state.label) · \(progress)%"
        }
        return state.label
    }

    private(set) var cpuPercent: Double?

    private(set) var memoryMb: Double?

    private(set) var meter: SessionMeter?

    private var hostReportedActivity = false

    private var idleCheckTask: Task<Void, Never>?

    private static let idleThreshold: TimeInterval = 20

    @ObservationIgnored private var terminalView: TerminalView?

    var terminalViewIfLoaded: TerminalView? { terminalView }

    func terminalReturnedToFront() {
        guard let size = reportedSize, size.rows > 0, size.cols > 0 else { return }
        eventStream.continuation.yield(.resize(rows: size.rows, cols: size.cols))
    }

    var view: TerminalView {
        if let terminalView { return terminalView }
        let created = Self.makeTerminalView(for: self)
        terminalView = created
        return created
    }

    private var offset: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var colorSchemeApplied: ColorScheme?

    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            if isFocused {
                Self.frameScheduler.setFocused(id)
                wake()
                acknowledgeAttention()
            } else {
                Self.frameScheduler.clearFocused(id)
            }
        }
    }

    private var pollDelay = minPollDelay
    private static let minPollDelay = 16
    private static let backgroundPollDelay = 200
    private static let maxPollDelay = 400

    private var pollFloor: Int {
        isFocused ? Self.minPollDelay : Self.backgroundPollDelay
    }

    private var readWaitMs: Int {
        isFocused ? Self.readHold : 0
    }
    private var sinceInfo = 0
    private var lastLoopAt = Date()
    nonisolated private static let readHold = 250

    private enum PtyEvent {
        case write([UInt8])
        case resize(rows: Int, cols: Int)
    }

    nonisolated private let eventStream = AsyncStream<PtyEvent>.makeStream()

    init(info: PtySessionInfo) {
        id = UUID().uuidString
        hostID = info.id
        workspaceID = info.workspaceID ?? ""
        command = info.command
        cwd = info.cwd
        alive = info.alive
        exitCode = info.exitCode
        rows = info.rows
        cols = info.cols
        applyState(
            alive: info.alive,
            exitCode: info.exitCode,
            lastActivityAtMs: info.lastActivityAtMs,
            activity: info.activity,
            cpuPercent: info.cpuPercent,
            memoryMb: info.memoryMb,
            attention: info.attention,
            programStatus: info.programStatus
        )
        applyMeter(from: info)
        _ = view
        start()
    }

    init(pendingCommand command: String, workspace: WorkspaceFolder, rows: Int, cols: Int) {
        id = UUID().uuidString
        hostID = "pending-\(UUID().uuidString)"
        workspaceID = workspace.id
        self.command = command
        cwd = workspace.path
        alive = false
        exitCode = nil
        self.rows = rows
        self.cols = cols
        state = .starting
        isPending = true
    }

    var isPending = false

    var isInspectorShell = false

    var showsHostLine: Bool {
        exitCode != nil
    }

    var showsStartingState: Bool {
        (isPending || !hasOutput) && exitCode == nil
    }

    func attach(info: PtySessionInfo) {
        guard isPending, !removed else { return }
        hostID = info.id
        alive = info.alive
        exitCode = info.exitCode
        rows = info.rows
        cols = info.cols
        isPending = false
        applyState(
            alive: info.alive,
            exitCode: info.exitCode,
            lastActivityAtMs: info.lastActivityAtMs,
            activity: info.activity,
            cpuPercent: info.cpuPercent,
            memoryMb: info.memoryMb,
            attention: info.attention,
            programStatus: info.programStatus
        )
        applyMeter(from: info)
        _ = view
        start()
    }

    private static func makeTerminalView(for session: TerminalSession) -> TerminalView {
        let view = TerminalDropView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        // Colour it before SwiftUI's first layout pass, not after.
        //
        // A TUI asks the emulator what its background is (OSC 11) within
        // milliseconds of starting, and SwiftTerm answers from the colour the
        // view is currently carrying. Waiting for `updateNSView` meant the
        // answer could still be the default black while the window was in
        // light mode, and an agent only asks once: it then drew for a dark
        // terminal for the rest of the session.
        applyAppearance(NSApp.effectiveAppearance, to: view)
        view.font = TerminalMetrics.font
        view.optionAsMetaKey = true
        view.changeScrollback(scrollbackLines)
        view.terminalDelegate = session
        view.session = session
        return view
    }

    private var removed = false

    private static let scrollbackLines = 20_000

    func applyColors(scheme: ColorScheme, to view: TerminalView) {
        guard scheme != colorSchemeApplied else { return }
        colorSchemeApplied = scheme
        Self.paint(dark: scheme == .dark, to: view)
    }

    /// The same, from an `NSAppearance`, for the moment before SwiftUI has
    /// had a chance to say what the scheme is.
    private static func applyAppearance(_ appearance: NSAppearance, to view: TerminalView) {
        paint(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, to: view)
    }

    private static func paint(dark: Bool, to view: TerminalView) {
        let background: UInt32 = dark ? 0x0A0A0B : 0xF7F7F8
        let foreground: UInt32 = dark ? 0xDCDCE0 : 0x1C1C1F
        view.nativeBackgroundColor = nsColor(background)
        view.nativeForegroundColor = nsColor(foreground)
        view.caretColor = NSColor(Theme.accent)
        view.setNeedsDisplay(view.bounds)
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    func start() {
        guard !isPending, !removed else { return }
        let bridgeID = hostID
        if !holdsActivity {
            holdsActivity = true
            TerminalActivity.retain()
        }
        if writerTask == nil {
            let events = eventStream.stream
            writerTask = Task.detached(priority: .userInitiated) { [weak self] in
                var lastError: String?
                for await event in events {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case let .write(bytes):
                        var failure: String?
                        do {
                            try await Bridge.ptyWrite(id: bridgeID, bytes: bytes)
                        } catch {
                            failure = error.localizedDescription
                        }
                        Task { @MainActor [weak self] in self?.wake() }
                        if failure != lastError {
                            lastError = failure
                            let transportFailure = failure
                            Task { @MainActor [weak self] in
                                self?.transportError = transportFailure
                            }
                        }
                    case let .resize(rows, cols):
                        _ = try? await Bridge.ptyResize(id: bridgeID, rows: rows, cols: cols)
                    }
                }
            }
        }
        guard pollTask == nil else { return }
        pollTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.poll(id: bridgeID)
        }
    }

    @ObservationIgnored private var holdsActivity = false

    private func releaseActivity() {
        guard holdsActivity else { return }
        holdsActivity = false
        TerminalActivity.release()
    }

    func stop() {
        clearAttention()
        removed = true
        if !isPending, !hostID.isEmpty {
            let id = hostID
            Task.detached { try? await Bridge.ptyDetach(id: id) }
        }
        releaseActivity()
        idleCheckTask?.cancel()
        idleCheckTask = nil
        state = .none
        pollTask?.cancel()
        pollTask = nil
        endNap()
        writerTask?.cancel()
        writerTask = nil
        eventStream.continuation.finish()
        pendingFeed.removeAll()
        pendingFeedHead = 0
        pendingFeedBytes = 0
    }

    nonisolated private func poll(id: String) async {
        var recoveryDelay = 50
        var failedReads = 0
        while !Task.isCancelled {
            if await renderBackpressureActive() {
                try? await Task.sleep(for: .milliseconds(10))
                continue
            }
            guard let plan = await makePollPlan() else { break }

            var unheld = false
            do {
                let askedAt = ContinuousClock.now
                let chunk = try await Bridge.ptyRead(
                    id: id,
                    offset: plan.offset,
                    waitMs: plan.waitMs
                )
                let shouldStop = await applyChunk(chunk, plan: plan)
                if shouldStop { break }
                recoveryDelay = 50
                failedReads = 0
                unheld = plan.focused
                    && chunk.bytes.isEmpty
                    && ContinuousClock.now - askedAt < Self.heldFloor
            } catch {
                failedReads += 1
                let retry = await notePollFailure(error, failedReads: failedReads)
                if !retry || Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(recoveryDelay))
                recoveryDelay = min(recoveryDelay * 2, 2_000)
                continue
            }

            guard let napMs = await afterPollNapMilliseconds(unheld: unheld) else { break }
            if napMs > 0 {
                await nap(napMs)
            }
        }
        await finishPoll()
    }

    @MainActor
    private func notePollFailure(_ error: Error, failedReads: Int) async -> Bool {
        guard !removed else { return false }
        let message = error.localizedDescription
        if transportError != message { transportError = message }
        guard failedReads.isMultiple(of: 8) else { return true }
        guard let info = try? await Bridge.ptyInfo(id: hostID) else {
            if failedReads >= 40 {
                do {
                    let sessions = try await Bridge.ptyList()
                    if !sessions.contains(where: { $0.id == hostID }) {
                        state = .stopped
                        return false
                    }
                } catch {
                }
            }
            return true
        }
        if rows != info.rows { rows = info.rows }
        if cols != info.cols { cols = info.cols }
        if alive != info.alive { alive = info.alive }
        if let code = info.exitCode {
            exitCode = code
            state = .stopped
            return false
        }
        if info.alive { transportError = nil }
        return info.alive
    }

    @MainActor
    private func makePollPlan() -> PollPlan? {
        guard !removed else { return nil }
        return PollPlan(
            offset: offset,
            waitMs: readWaitMs,
            floor: pollFloor,
            focused: isFocused,
            hot: Date() < hotUntil,
            delay: pollDelay
        )
    }

    @MainActor
    private func renderBackpressureActive() -> Bool {
        pendingFeedBytes >= Self.renderHighWater
    }

    @MainActor
    private func finishPoll() {
        pollTask = nil
        releaseActivity()
    }

    private struct PollPlan: Sendable {
        var offset: UInt64
        var waitMs: Int
        var floor: Int
        var focused: Bool
        var hot: Bool
        var delay: Int
    }

    @MainActor
    private func applyChunk(_ chunk: PtyChunk, plan: PollPlan) -> Bool {
        guard !Task.isCancelled, !removed else { return true }
        if outputPaused != chunk.paused { outputPaused = chunk.paused }
        if chunk.dropped > 0, !droppedOutput { droppedOutput = true }
        if !chunk.bytes.isEmpty {
            offset = chunk.nextOffset
            pollDelay = plan.floor
            acceptBytes(chunk.bytes)
        } else if plan.hot {
            pollDelay = plan.floor
        } else {
            pollDelay = min(max(pollDelay, plan.floor) * 2, Self.maxPollDelay)
        }
        return false
    }

    @MainActor
    private func afterPollNapMilliseconds(unheld: Bool) async -> Int? {
        guard !removed else { return nil }

        sinceInfo += max(pollDelay, Int(Date().timeIntervalSince(lastLoopAt) * 1000))
        lastLoopAt = Date()
        let infoInterval = pollDelay >= Self.maxPollDelay ? 2_000 : 250
        if sinceInfo >= infoInterval, Date() >= hotUntil {
            sinceInfo = 0
            if let info = try? await Bridge.ptyInfo(id: hostID) {
                guard !removed, !Task.isCancelled else { return nil }
                if rows != info.rows { rows = info.rows }
                if cols != info.cols { cols = info.cols }
                if alive != info.alive {
                    alive = info.alive
                    if !info.alive {
                        clearAttention()
                        idleCheckTask?.cancel()
                        idleCheckTask = nil
                        state = info.exitCode != nil ? .stopped : .none
                    }
                }
                if info.alive {
                    applyActivity(
                        info.activity,
                        cpuPercent: info.cpuPercent,
                        memoryMb: info.memoryMb,
                        attention: info.attention,
                        programStatus: info.programStatus
                    )
                }
                applyMeter(from: info)
                if let code = info.exitCode {
                    clearAttention()
                    exitCode = code
                    idleCheckTask?.cancel()
                    idleCheckTask = nil
                    state = .stopped
                    while !removed, !Task.isCancelled {
                        let previous = offset
                        guard let final = try? await Bridge.ptyRead(id: hostID, offset: previous),
                              !removed, !Task.isCancelled else { break }
                        if final.dropped > 0, !droppedOutput { droppedOutput = true }
                        offset = final.nextOffset
                        if !final.bytes.isEmpty { acceptBytes(final.bytes) }
                        if final.nextOffset <= previous { break }
                        while pendingFeedBytes >= Self.renderHighWater, !removed, !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(10))
                        }
                    }
                    return nil
                }
            }
        }

        if !isFocused {
            return pollDelay
        }
        if unheld {
            return Self.minPollDelay
        }
        return 0
    }

    @ObservationIgnored private var pendingFeed: [Data] = []
    @ObservationIgnored private var pendingFeedHead = 0
    @ObservationIgnored private var pendingFeedBytes = 0
    @ObservationIgnored private var outputFilter = TerminalOutputFilter()
    @ObservationIgnored private var feedInFlight = false
    @ObservationIgnored private var feedPumpScheduled = false
    private static let renderHighWater = 8 * 1024 * 1024

    private var isCatchingUp: Bool {
        pendingFeedBytes >= Self.catchUpBacklog
    }

    private static let catchUpBacklog = feedSliceCatchUp

    private func acceptBytes(_ bytes: Data) {
        guard !removed, !bytes.isEmpty else { return }
        if !hasOutput { hasOutput = true }
        lastOutputAt = Date()
        if alive, !hostReportedActivity {
            if state != .working { state = .working }
            ensureIdleCheck()
        }
        pendingFeed.append(bytes)
        pendingFeedBytes += bytes.count
        if !feedInFlight, !feedPumpScheduled {
            feedPumpScheduled = true
            Task { await pumpFeed() }
        }
    }

    private func pumpFeed() async {
        feedPumpScheduled = false
        guard !feedInFlight else { return }
        feedInFlight = true
        Self.frameScheduler.begin(id: id)
        defer { Self.frameScheduler.end(id: id) }
        defer { feedInFlight = false }
        while !removed, pendingFeedHead < pendingFeed.count {
            let chunk = pendingFeed[pendingFeedHead]
            pendingFeed[pendingFeedHead] = Data()
            pendingFeedHead += 1
            pendingFeedBytes -= chunk.count
            await feedToView(chunk, sessionID: id)
            if pendingFeedHead >= Self.feedCompactAfter {
                pendingFeed.removeFirst(pendingFeedHead)
                pendingFeedHead = 0
            }
        }
        if pendingFeedHead == pendingFeed.count {
            pendingFeed.removeAll(keepingCapacity: true)
            pendingFeedHead = 0
        }
    }

    private static let feedCompactAfter = 64

    private func feedToView(_ bytes: Data, sessionID: String) async {
        let slice = isCatchingUp ? Self.feedSliceCatchUp : Self.feedSlice
        let all = outputFilter.filter([UInt8](bytes)[...])
        guard !all.isEmpty else { return }
        var start = 0
        while start < all.count {
            await Self.frameScheduler.acquire(id: sessionID)
            guard !removed, !Task.isCancelled else { return }
            let end = min(start + slice, all.count)
            let began = ContinuousClock.now
            view.feedOutput(all[start..<end])
            Self.frameScheduler.record(ContinuousClock.now - began)
            Self.frameScheduler.finish(id: sessionID)
            start = end
            if start < all.count { await pace() }
        }
        if TerminalPreferences.exposesToVoiceOver {
            publishAccessibilityValue()
        }
    }

    private static let feedSlice = 24 * 1024
    private static let feedSliceCatchUp = 64 * 1024

    private static var frameInterval: Duration {
        .seconds(1.0 / Double(screenRefreshRate))
    }

    private static var cachedRefreshRate: (hz: Int, at: ContinuousClock.Instant)?

    private static var screenRefreshRate: Int {
        let now = ContinuousClock.now
        if let cached = cachedRefreshRate, now - cached.at < .seconds(1) {
            return cached.hz
        }
        let hz = min(max(NSScreen.main?.maximumFramesPerSecond ?? 60, 30), 240)
        cachedRefreshRate = (hz, now)
        return hz
    }

    private static var frameBudget: Duration { frameInterval * 0.6 }
    private static var frameBudgetCatchUp: Duration { frameInterval * 0.9 }

    @MainActor
    private final class FrameBudgetScheduler {
        private var frameStart = ContinuousClock.now
        private var spent: Duration = .zero
        private var active: [String] = []
        private var current: String?
        private var focused: String?
        private var rotation = 0

        func begin(id: String) {
            guard !active.contains(id) else { return }
            active.append(id)
            current = current ?? id
        }

        func end(id: String) {
            active.removeAll { $0 == id }
            if current == id { current = preferred() }
        }

        func setFocused(_ id: String?) {
            focused = id
        }

        func clearFocused(_ id: String) {
            if focused == id { focused = nil }
        }

        private func preferred() -> String? {
            if let focused, active.contains(focused) { return focused }
            return active.first
        }

        func acquire(id: String) async {
            while !Task.isCancelled, current != id, active.contains(id) {
                try? await Task.sleep(for: Self.turnPoll)
            }
        }

        private static let turnPoll: Duration = .milliseconds(4)

        func finish(id: String) {
            guard current == id, active.count > 1 else { return }
            if let focused, focused != id, active.contains(focused) {
                current = focused
                return
            }
            let others = active.filter { $0 != focused }
            guard !others.isEmpty else { return }
            rotation = (rotation + 1) % others.count
            current = others[rotation]
        }

        func record(_ duration: Duration) {
            spent += duration
        }

        func pace(budget: Duration, interval: Duration) async {
            let now = ContinuousClock.now
            if now - frameStart >= interval {
                frameStart = now
                spent = .zero
                await Task.yield()
                return
            }
            guard spent >= budget else {
                await Task.yield()
                return
            }
            let remaining = interval - (now - frameStart)
            try? await Task.sleep(for: remaining)
            frameStart = ContinuousClock.now
            spent = .zero
        }
    }

    private static let frameScheduler = FrameBudgetScheduler()

    private func pace() async {
        let budget = isCatchingUp ? Self.frameBudgetCatchUp : Self.frameBudget
        await Self.frameScheduler.pace(budget: budget, interval: Self.frameInterval)
    }

    private func applyState(
        alive: Bool,
        exitCode: Int?,
        lastActivityAtMs: Int64?,
        activity: String? = nil,
        cpuPercent: Double? = nil,
        memoryMb: Double? = nil,
        attention: String? = nil,
        programStatus: PtyProgramStatus? = nil
    ) {
        idleCheckTask?.cancel()
        idleCheckTask = nil
        if !alive {
            self.cpuPercent = nil
            self.memoryMb = nil
            clearAttention()
            state = exitCode != nil ? .stopped : .none
            return
        }
        if activity != nil || attention != nil {
            applyActivity(
                activity,
                cpuPercent: cpuPercent,
                memoryMb: memoryMb,
                attention: attention,
                programStatus: programStatus
            )
            return
        }
        if let last = lastActivityAtMs {
            let ageMs = Date().timeIntervalSince1970 * 1000 - Double(last)
            state = ageMs <= Self.idleThreshold * 1000 ? .working : .idle
        } else {
            state = .working
        }
        if state == .working {
            ensureIdleCheck()
        }
    }

    private var attentionAcknowledged = false
    private var attentionRevision: UInt64?
    private var hostNeedsAttention = false

    private func clearAttention() {
        if hostNeedsAttention { RunNotifications.shared.attentionHandled(sessionID: id) }
        hostNeedsAttention = false
        attentionAcknowledged = false
        attentionRevision = nil
    }

    private func applyActivity(
        _ activity: String?,
        cpuPercent: Double?,
        memoryMb: Double? = nil,
        attention: String? = nil,
        programStatus: PtyProgramStatus? = nil
    ) {
        if activity == nil && attention == nil { return }
        let reportedActivity = ["done", "error"].contains(programStatus?.state ?? "") ? programStatus?.state : activity
        if activity != nil { hostReportedActivity = true }
        let newEpisode = attentionRevision != programStatus?.revision
        if newEpisode { attentionAcknowledged = false }
        attentionRevision = programStatus?.revision
        if self.programStatus != programStatus { self.programStatus = programStatus }
        idleCheckTask?.cancel()
        idleCheckTask = nil
        let cpu = cpuPercent.map { ($0).rounded() }
        let memory = memoryMb.map { ($0).rounded() }
        if self.cpuPercent != cpu { self.cpuPercent = cpu }
        if self.memoryMb != memory { self.memoryMb = memory }
        let waiting = !(attention?.isEmpty ?? true)
        if !waiting { clearAttention() }
        let next: SessionState
        if waiting {
            next = .needsAttention
            if !attentionAcknowledged && (!hostNeedsAttention || newEpisode) { announceAttention() }
            hostNeedsAttention = true
        } else if reportedActivity == "working" {
            next = .working
        } else if reportedActivity == "done" {
            next = .done
        } else if reportedActivity == "error" {
            next = .failed
        } else if reportedActivity != nil {
            next = .idle
        } else {
            return
        }
        if state != next { state = next }
    }

    func acknowledgeAttention() {
        attentionAcknowledged = true
        RunNotifications.shared.attentionHandled(sessionID: id)
    }

    private func announceAttention() {
        guard !isFocused || !NSApp.isActive else { return }
        RunNotifications.shared.attention(
            sessionID: id,
            name: attentionName,
            workspaceID: workspaceID
        )
    }

    private var attentionName: String {
        guard let title, !title.isEmpty else { return command }
        guard title.contains("/") else { return title }
        return title.split(separator: "/").last.map(String.init) ?? title
    }

    private func applyMeter(from info: PtySessionInfo) {
        if sessionIdentities != info.sessionIdentities { sessionIdentities = info.sessionIdentities }
        let tokens = info.tokens ?? 0
        let cost = info.costMicros
        let used = info.contextUsed
        let window = info.contextWindow.flatMap { $0 > 0 ? $0 : nil }
        let next: SessionMeter?
        if tokens > 0 || cost != nil || used != nil {
            next = SessionMeter(
                tokens: tokens,
                costMicros: cost,
                estimated: info.costEstimated ?? false,
                complete: info.costComplete ?? true,
                billing: info.billing,
                model: info.model,
                contextUsed: used,
                contextWindow: window,
                contextEstimated: info.contextEstimated ?? false
            )
        } else {
            next = nil
        }
        if meter != next { meter = next }
    }

    func refreshDetails() async {
        guard !removed, !isPending, let reference = workReference,
              WorkCacheAccess.canRead(reference) else { return }
        let generation = WorkSessionContext.shared.generation
        guard let info = try? await Bridge.ptyInfo(id: hostID), !Task.isCancelled,
              !removed, workReference == reference,
              generation == WorkSessionContext.shared.generation,
              WorkCacheAccess.canRead(reference) else { return }
        if alive != info.alive { alive = info.alive }
        if exitCode != info.exitCode { exitCode = info.exitCode }
        applyState(alive: info.alive, exitCode: info.exitCode, lastActivityAtMs: info.lastActivityAtMs,
                   activity: info.activity, cpuPercent: info.cpuPercent, memoryMb: info.memoryMb,
                   attention: info.attention, programStatus: info.programStatus)
        applyMeter(from: info)
    }

    private func ensureIdleCheck() {
        guard idleCheckTask == nil else { return }
        idleCheckTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.alive {
                try? await Task.sleep(for: .seconds(Self.idleThreshold))
                guard !Task.isCancelled, self.alive else { break }
                if let last = self.lastOutputAt,
                   Date().timeIntervalSince(last) < Self.idleThreshold
                {
                    continue
                }
                if self.state == .working {
                    self.state = .idle
                }
                break
            }
            self?.idleCheckTask = nil
        }
    }

    func followSnapshot(lines: Int = 48) -> String {
        guard let loaded = terminalViewIfLoaded else { return "" }
        return loaded.tailTextSnapshot(lines: lines).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The terminal's visible screen as plain text, for VoiceOver.
    var visibleTerminalText: String {
        guard TerminalPreferences.exposesToVoiceOver else { return "" }
        return view.visibleTextSnapshot()
    }

    private var lastAccessibilityValueAt: Date?

    private func publishAccessibilityValue() {
        let now = Date()
        if let last = lastAccessibilityValueAt,
           now.timeIntervalSince(last) < 0.25
        {
            return
        }
        lastAccessibilityValueAt = now
        view.setAccessibilityValue(visibleTerminalText)
    }

    func wake() {
        pollDelay = pollFloor
        hotUntil = Date().addingTimeInterval(Self.hotWindow)
        endNap()
    }

    private var hotUntil = Date.distantPast
    private static let hotWindow: TimeInterval = 0.4
    nonisolated private static let heldFloor: Duration = .milliseconds(readHold / 4)

    private var napper: CheckedContinuation<Void, Never>?

    nonisolated private func nap(_ milliseconds: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor [weak self] in
                guard let self, !self.removed else {
                    continuation.resume()
                    return
                }
                if let previous = self.napper {
                    self.napper = nil
                    previous.resume()
                }
                self.napper = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                    self?.endNap()
                }
            }
        }
    }

    func endNap() {
        guard let continuation = napper else { return }
        napper = nil
        continuation.resume()
    }

    func sendEnter() {
        wake()
        eventStream.continuation.yield(.write([0x0d]))
    }

    func paste(text: String) {
        guard !text.isEmpty else { return }
        wake()
        let bracketed = terminalViewIfLoaded?.terminalInputStateSnapshot()?.bracketedPasteMode ?? false
        var bytes: [UInt8] = []
        if bracketed { bytes += EscapeSequences.bracketedPasteStart }
        bytes += Array(text.utf8)
        if bracketed { bytes += EscapeSequences.bracketedPasteEnd }
        eventStream.continuation.yield(.write(bytes))
    }

    func sendBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        wake()
        eventStream.continuation.yield(.write(bytes))
    }


    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // AppKit delivers keystrokes on the main thread, where the actor lives.
        MainActor.assumeIsolated { wake() }
        eventStream.continuation.yield(.write(Array(data)))
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // AppKit calls this on the main thread, which is where the actor lives.
        let changed = MainActor.assumeIsolated {
            guard newCols != reportedSize?.cols || newRows != reportedSize?.rows else {
                return false
            }
            reportedSize = (newRows, newCols)
            // Out of the layout pass this arrived in. AppKit is inside
            // `setFrameSize` here, and an observed write from there makes
            // SwiftUI invalidate a hierarchy AppKit is still laying out.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if cols != newCols { cols = newCols }
                if rows != newRows { rows = newRows }
            }
            return true
        }
        guard changed else { return }
        eventStream.continuation.yield(.resize(rows: newRows, cols: newCols))
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated {
            if self.title != title { self.title = title }
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated {
            if reportedCwd != directory { reportedCwd = directory }
        }
    }

    /// The emulator scrolled.
    ///
    /// **Once per line**, from inside the feed, so a build log calls this
    /// thousands of times a second. It used to hop to the main actor with a
    /// `Task` and clear the accessibility throttle, which meant a queue of
    /// main-actor jobs as long as the output, each one rebuilding the visible
    /// screen as text. That queue is what a keystroke had to wait behind, and
    /// it grows for as long as the process prints: the longer the stream, the
    /// further behind typing fell.
    ///
    /// Nothing to do here when the screen is not exposed to VoiceOver, and
    /// when it is, the throttled path already refreshes it four times a second.
    nonisolated func scrolled(source: TerminalView, position: Double) {
        guard TerminalPreferences.exposesToVoiceOver else { return }
        MainActor.assumeIsolated { publishAccessibilityValue() }
    }

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
}
#endif
