// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import Foundation
import Observation
import SwiftTerm
import SwiftUI
import UIKit

/// One live terminal on a remote host, driven over the tunnel for the phone.
///
/// Same model as the Mac `TerminalSession` (host owns the process, we poll
/// and type), simplified for a full-screen mobile surface.
@MainActor
@Observable
final class ClientTerminalSession: TerminalViewDelegate, Identifiable {
    let id: String
    let peer: String
    let ownerScope = WorkSessionContext.shared.scope
    private let ownerGeneration = WorkSessionContext.shared.generation
    private var ownsSession: Bool {
        ownerScope != nil && ownerScope == WorkSessionContext.shared.scope
            && ownerGeneration == WorkSessionContext.shared.generation
    }
    private var mayOperate: Bool { ownsSession && !removed && !Task.isCancelled }
    private(set) var hostID: String
    let command: String
    let cwd: String
    private(set) var workspaceID: String?
    private(set) var sessionIdentities: SessionIdentities?
    var identityEntries: [SessionIdentityEntry] {
        SessionIdentityPresentation.entries(localID: hostID.hasPrefix("pending-") ? nil : hostID, kind: .terminal, sessions: sessionIdentities)
    }
    var workReference: WorkReference? {
        guard let ownerScope, ownerScope == WorkSessionContext.shared.scope,
              let workspaceID, !workspaceID.isEmpty, !hostID.hasPrefix("pending-") else { return nil }
        return WorkReference(scope: ownerScope, hostIdentity: peer, workspaceID: workspaceID, kind: .terminal, itemID: hostID)
    }

    private(set) var alive: Bool
    private(set) var exitCode: Int?
    private(set) var rows: Int
    private(set) var cols: Int
    private(set) var hasOutput = false
    private(set) var droppedOutput = false
    private(set) var outputPaused = false
    var transportError: String?

    /// Ctrl on the key bar armed for the next key. The bar has no letter keys,
    /// so the flag lives here and `send(source:data:)` folds the next typed
    /// byte to its C0 code. Cleared by that fold, or by the next bar key, so
    /// it behaves like a modifier tapped once.
    var controlArmed = false

    @ObservationIgnored private var terminalView: TerminalView?
    @ObservationIgnored private var offset: UInt64 = 0
    /// Output on its way to the emulator, minus what it cannot read correctly.
    @ObservationIgnored private var outputFilter = TerminalOutputFilter()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var writerTask: Task<Void, Never>?
    @ObservationIgnored private var removed = false
    @ObservationIgnored private var isPending = false
    /// Close was tapped before spawn returned. Kill the real id on attach.
    @ObservationIgnored private var closeWhenAttached = false
    @ObservationIgnored private var lastInfoAt = Date.distantPast
    @ObservationIgnored private var inForeground = true
    @ObservationIgnored private var liveInfo: PtySessionInfo?
    @ObservationIgnored private let observedAt = Date()

    private enum PtyEvent {
        case write([UInt8])
        case resize(rows: Int, cols: Int)
    }

    nonisolated private let eventStream = AsyncStream<PtyEvent>.makeStream()

    var view: TerminalView {
        if let terminalView { return terminalView }
        let created = Self.makeView(delegate: self)
        created.scrollMode = scrolls
        created.onReadingChanged = { [weak self] reading in
            DispatchQueue.main.async { self?.readingOutput = reading }
        }
        terminalView = created
        return created
    }

    init(peer: String, info: PtySessionInfo) {
        id = UUID().uuidString
        self.peer = peer
        liveInfo = info
        sessionIdentities = info.sessionIdentities
        hostID = info.id
        workspaceID = info.workspaceID
        command = info.command
        cwd = info.cwd
        alive = info.alive
        exitCode = info.exitCode
        rows = max(info.rows, 24)
        cols = max(info.cols, 80)
        _ = view
        start()
    }

    init(peer: String, pendingCommand: String, cwd: String, rows: Int, cols: Int) {
        id = UUID().uuidString
        self.peer = peer
        hostID = "pending-\(UUID().uuidString)"
        command = pendingCommand
        self.cwd = cwd
        alive = false
        exitCode = nil
        self.rows = rows
        self.cols = cols
        isPending = true
    }

    func attach(info: PtySessionInfo) {
        guard isPending, ownsSession else { return }
        if removed && !closeWhenAttached { return }
        hostID = info.id
        liveInfo = info
        if sessionIdentities != info.sessionIdentities { sessionIdentities = info.sessionIdentities }
        workspaceID = info.workspaceID
        alive = info.alive
        exitCode = info.exitCode
        rows = info.rows
        cols = info.cols
        isPending = false
        if closeWhenAttached || removed {
            let peer = peer
            let id = info.id
            Task {
                guard self.ownsSession else { return }
                try? await ClientRemote.ptyClose(peer: peer, id: id)
            }
            endLocalWork()
            return
        }
        _ = view
        start()
    }

    func stop() {
        removed = true
        // The reported bug, from this end: closing a session here used to leave
        // the Mac's own terminal clamped to the phone's width. Giving up the
        // claim puts it straight back. Fire and forget: the host expires the
        // claim on its own, and closing a screen must not wait on the tunnel.
        if ownsSession, !isPending, !hostID.isEmpty {
            let id = hostID
            let peer = peer
            Task {
                guard self.ownsSession else { return }
                try? await ClientRemote.ptyDetach(peer: peer, id: id)
            }
        }
        endLocalWork()
    }

    /// Stop the process on the host, then drop the phone's hold.
    ///
    /// Done only detaches. Close is what the Mac tab close does.
    /// Throws when the host never heard the close, so the caller can keep
    /// the row instead of pretending the process is gone.
    func close() async throws {
        guard ownsSession, !Task.isCancelled else { throw CancellationError() }
        if isPending {
            closeWhenAttached = true
            removed = true
            endLocalWork()
            return
        }
        guard !hostID.isEmpty else {
            removed = true
            endLocalWork()
            return
        }
        do {
            try await ClientRemote.ptyClose(peer: peer, id: hostID)
        } catch {
            if ownsSession { transportError = error.localizedDescription }
            throw error
        }
        guard ownsSession, !Task.isCancelled else { throw CancellationError() }
        alive = false
        exitCode = nil
        await updateLiveActivity(stopped: true)
        removed = true
        endLocalWork()
    }

    private func endLocalWork() {
        pollTask?.cancel()
        pollTask = nil
        writerTask?.cancel()
        writerTask = nil
        eventStream.continuation.finish()
    }

    /// The screen is on screen. Backgrounded polls skip the held read so a
    /// frozen phone does not sit in a tunnel wait, and coming back nudges
    /// the supervisor instead of waiting out a leftover backoff.
    func setForeground(_ active: Bool) {
        inForeground = active
    }

    func updateLiveActivity(stopped: Bool = false) async {
        guard ownsSession, var info = liveInfo else { return }
        info.alive = alive
        info.exitCode = exitCode
        await LiveWorkController.shared.track(terminal: info, peer: peer,
            projectName: URL(fileURLWithPath: cwd).lastPathComponent, observedAt: observedAt, stopped: stopped,
            mayStart: { self.mayOperate && self.alive && self.hostID == info.id })
    }

    /// A path change is not a dead process. Drop the last transport error so
    /// the next poll can reattach by pty id over a new dial.
    func clearTransientTunnelError() {
        if let error = transportError, ClientTunnelCopy.isAbsent(error) {
            transportError = nil
        }
    }

    private func start() {
        guard !isPending, mayOperate else { return }
        let bridgeID = hostID
        let peer = peer
        if writerTask == nil {
            let events = eventStream.stream
            writerTask = Task.detached(priority: .userInitiated) { [weak self] in
                var lastError: String?
                for await event in events {
                    guard !Task.isCancelled, await self?.mayOperate == true else { break }
                    switch event {
                    case let .write(bytes):
                        let failure: String?
                        do {
                            try await ClientRemote.ptyWrite(peer: peer, id: bridgeID, bytes: bytes)
                            failure = nil
                        } catch {
                            failure = error.localizedDescription
                        }
                        if failure != lastError {
                            lastError = failure
                            Task { @MainActor [weak self] in
                                guard let self, self.mayOperate else { return }
                                self.transportError = failure
                            }
                        }
                    case let .resize(rows, cols):
                        _ = try? await ClientRemote.ptyResize(
                            peer: peer,
                            id: bridgeID,
                            rows: rows,
                            cols: cols
                        )
                    }
                }
            }
        }
        guard pollTask == nil else { return }
        pollTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.poll(peer: peer, id: bridgeID)
        }
    }

    nonisolated private func poll(peer: String, id: String) async {
        var recoveryDelay = 50
        var failedReads = 0
        while !Task.isCancelled {
            guard let plan = await makePlan() else { break }
            do {
                let chunk = try await ClientRemote.ptyRead(
                    peer: peer,
                    id: id,
                    offset: plan.offset,
                    waitMs: plan.waitMs
                )
                let shouldStop = await apply(chunk)
                if shouldStop { break }
                if plan.checkAlive, !(await checkLiveness(peer: peer, id: id)) { break }
                recoveryDelay = 50
                failedReads = 0
            } catch {
                failedReads += 1
                let retry = await notePollFailure(
                    peer: peer,
                    id: id,
                    error: error,
                    failedReads: failedReads
                )
                if !retry || Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(recoveryDelay))
                recoveryDelay = min(recoveryDelay * 2, 2_000)
                continue
            }
            if plan.delay > 0 {
                try? await Task.sleep(for: .milliseconds(plan.delay))
            }
        }
        await MainActor.run { [weak self] in self?.pollTask = nil }
    }

    @MainActor
    private func notePollFailure(
        peer: String,
        id: String,
        error: Error,
        failedReads: Int
    ) async -> Bool {
        guard mayOperate else { return false }
        let message = error.localizedDescription
        if transportError != message { transportError = message }
        guard failedReads.isMultiple(of: 8) else { return true }
        guard let info = try? await ClientRemote.ptyInfo(peer: peer, id: id) else {
            guard mayOperate else { return false }
            if failedReads >= 40 {
                do {
                    let sessions = try await ClientRemote.ptyList(peer: peer)
                    guard mayOperate else { return false }
                    if !sessions.contains(where: { $0.id == id }) {
                        alive = false
                        await updateLiveActivity(stopped: true)
                        return false
                    }
                } catch {
                    // A failed list is still a transport outage, not proof
                    // that the remote PTY disappeared.
                }
            }
            return true
        }
        guard mayOperate else { return false }
        liveInfo = info
        if sessionIdentities != info.sessionIdentities { sessionIdentities = info.sessionIdentities }
        if rows != info.rows { rows = info.rows }
        if cols != info.cols { cols = info.cols }
        if alive != info.alive { alive = info.alive }
        if let code = info.exitCode {
            exitCode = code
            alive = false
            return false
        }
        if info.alive { transportError = nil }
        // EOF can precede reaping, including during tunnel recovery.
        return info.exitCode == nil
    }

    private struct Plan: Sendable {
        var offset: UInt64
        var waitMs: Int
        var delay: Int
        var checkAlive: Bool
    }

    @MainActor
    private func makePlan() -> Plan? {
        guard mayOperate else { return nil }
        return Plan(
            offset: offset,
            waitMs: inForeground ? 250 : 0,
            delay: inForeground ? (hasOutput ? 16 : 50) : 2_000,
            checkAlive: inForeground
        )
    }

    @MainActor
    private func apply(_ chunk: PtyChunk) async -> Bool {
        guard mayOperate else { return true }
        if outputPaused != chunk.paused { outputPaused = chunk.paused }
        if chunk.dropped > 0 { droppedOutput = true }
        if !chunk.bytes.isEmpty {
            offset = chunk.nextOffset
            hasOutput = true
            // Same filter as the Mac pane, for the same reason: this build's
            // SwiftTerm mistakes the kitty keyboard announcement for a cursor
            // restore. See `TerminalOutputFilter`.
            let bytes = outputFilter.filter([UInt8](chunk.bytes)[...])
            let slice = 24 * 1024
            var start = 0
            while start < bytes.count {
                guard mayOperate else { return true }
                let end = min(start + slice, bytes.count)
                view.feedOutput(ArraySlice(bytes[start..<end]))
                start = end
                if start < bytes.count {
                    try? await Task.sleep(for: .milliseconds(8))
                }
            }
        }
        return false
    }

    /// Ask the host whether the process is still running. A clean exit used
    /// to leave this screen saying Running until the next failed read.
    @MainActor
    private func checkLiveness(peer: String, id: String) async -> Bool {
        guard mayOperate else { return false }
        guard Date().timeIntervalSince(lastInfoAt) >= 0.25 else { return true }
        lastInfoAt = Date()
        guard let info = try? await ClientRemote.ptyInfo(peer: peer, id: id) else {
            return true
        }
        guard mayOperate else { return false }
        liveInfo = info
        if sessionIdentities != info.sessionIdentities { sessionIdentities = info.sessionIdentities }
        if rows != info.rows { rows = info.rows }
        if cols != info.cols { cols = info.cols }
        if alive != info.alive { alive = info.alive }
        if let code = info.exitCode {
            exitCode = code
            alive = false
            return false
        }
        if !info.alive {
            alive = false
            // Give the wait thread a chance to expose a real exit status.
            return info.exitCode == nil
        }
        transportError = nil
        return true
    }

    private static func makeView(delegate: TerminalViewDelegate) -> ClientTerminalInputView {
        let view = ClientTerminalInputView(frame: CGRect(x: 0, y: 0, width: 360, height: 640))
        let dark = UITraitCollection.current.userInterfaceStyle == .dark
        let background: UInt32 = dark ? 0x0A0A0B : 0xF7F7F8
        let foreground: UInt32 = dark ? 0xDCDCE0 : 0x1C1C1F
        view.nativeBackgroundColor = uiColor(background)
        view.nativeForegroundColor = uiColor(foreground)
        view.font = AppFonts.terminal(size: 12)
        view.optionAsMetaKey = true
        view.getTerminal().changeHistorySize(4_000)
        view.terminalDelegate = delegate
        // Soft keyboard: TerminalView is a UIKeyInput scroll view.
        view.isUserInteractionEnabled = true
        // SwiftTerm's own accessory has no Shift and no back-tab, which is the
        // one chord an agent session needs. `ClientTerminalKeys` replaces it,
        // and two bars stacked would be worse than the gap it fills.
        view.inputAccessoryView = nil
        return view
    }

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    // MARK: - TerminalViewDelegate

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in
            guard mayOperate, newCols > 0, newRows > 0 else { return }
            // Against what was last announced, not against `rows`/`cols`. Those
            // are the host's answer, and the host's answer is the *agreed* size
            // across every viewer, which on a phone attached to a wider Mac is
            // smaller than this screen. Comparing against it would suppress the
            // announcement of the phone's real width, and the pty would keep
            // wrapping to a geometry this screen cannot show.
            if announced?.rows == newRows, announced?.cols == newCols { return }
            announced = (rows: newRows, cols: newCols)
            eventStream.continuation.yield(.resize(rows: newRows, cols: newCols))
        }
    }

    /// What this screen last told the host it can show.
    @ObservationIgnored private var announced: (rows: Int, cols: Int)?

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// Whether a drag scrolls the buffer instead of reaching the program.
    ///
    /// An agent that asks for mouse reporting gets every drag as an event,
    /// which pins the view to the bottom of a 4,000 line scrollback. Turning
    /// reporting off hands panning back to the terminal. Starts off, because
    /// typing is what a keyboard is for and a scroll is the deliberate act.
    var scrolls: Bool = false {
        didSet {
            guard scrolls != oldValue else { return }
            (terminalView as? ClientTerminalInputView)?.scrollMode = scrolls
        }
    }

    var readingOutput = false

    func followOutput() { (terminalView as? ClientTerminalInputView)?.followLatest() }

    /// The visible screen as plain text. Empty until the view exists, and it
    /// never creates one: the sheet that reads it does not own the mount.
    func screenText() -> String {
        guard let terminal = terminalView?.getTerminal() else { return "" }
        let dims = terminal.getDims()
        let top = terminal.getTopVisibleRow()
        return terminal.getText(start: Position(col: 0, row: top),
                                end: Position(col: max(0, dims.cols), row: top + max(0, dims.rows)))
    }

    /// Put the keyboard away, or bring it back, without ending the session.
    ///
    /// Hiding it is what makes a phone readable, and until the terminal is
    /// tapped there is nothing that says how to get it back. The same key
    /// does both.
    func toggleKeyboard() {
        guard let view = terminalView else { return }
        if view.isFirstResponder {
            _ = view.resignFirstResponder()
        } else {
            _ = view.becomeFirstResponder()
        }
    }

    /// Type raw bytes, for the key bar above the keyboard.
    ///
    /// The same queue typing uses, so a tapped key and a typed one cannot
    /// arrive out of order.
    func sendBytes(_ bytes: [UInt8]) {
        guard mayOperate, !bytes.isEmpty else { return }
        eventStream.continuation.yield(.write(bytes))
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        Task { @MainActor in
            // Ctrl armed on the bar applies to the key that is typed here, not
            // to a bar key. The fold and the clear happen on the main actor so
            // they cannot race the bar's toggle.
            guard mayOperate else { return }
            var out = bytes
            if controlArmed {
                controlArmed = false
                if let first = out.first, let folded = ClientTerminalKeys.controlCode(first) {
                    out[0] = folded
                }
            }
            eventStream.continuation.yield(.write(out))
        }
    }

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) {
            Task { @MainActor in
                guard mayOperate else { return }
                UIPasteboard.general.string = text
            }
        }
    }

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// SwiftUI host for the SwiftTerm iOS view.
struct ClientTerminalRepresentable: UIViewRepresentable {
    let session: ClientTerminalSession

    func makeUIView(context: Context) -> TerminalView {
        let view = session.view
        view.setNeedsDisplay()
        // Become first responder so the software keyboard can type.
        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // Focus is taken once, on appear. Taking it back on every update
        // would make Hide keyboard last until the next redraw, which on a
        // live terminal is immediately.
        (uiView as? ClientTerminalInputView)?.scrollMode = session.scrolls
    }
}

/// Full-screen terminal for one remote session.
struct ClientTerminalScreen: View {
    @Environment(ClientNavigationModel.self) private var navigation
    @Environment(AccountModel.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let session: ClientTerminalSession
    var hostName: String = ""
    var embedded = false
    var onClose: (() -> Void)?
    var onClosedProcess: (() -> Void)?

    @State private var confirmClose = false
    @State private var showingWorkspace = false
    @State private var showingTransportDetails = false

    private var statusText: String {
        if let error = session.transportError { return ClientTunnelCopy.display(error, host: hostName) }
        if session.outputPaused { return L10n.text("apple.clientterminalsession.output_paused_while_the_terminal_catches_u.c3cbbc1c") }
        return session.alive ? session.cwd : (session.exitCode.map { L10n.text("apple.clientterminalsession.exited_0.39ec5073", "\($0)") } ?? L10n.text("apple.clientterminalsession.stopped.8322e87d"))
    }

    private var statusColor: SwiftUI.Color {
        if let error = session.transportError {
            return ClientTunnelCopy.isAbsent(error) ? Theme.warning : Theme.danger
        }
        return session.outputPaused ? Theme.warning : SwiftUI.Color.secondary
    }

    private func rememberTerminal() {
        guard session.ownerScope != nil, session.ownerScope == WorkSessionContext.shared.scope,
              !session.hostID.hasPrefix("pending-") else { return }
        if !embedded, let reference = session.workReference, reference.scope.kind == .account {
            navigation.showTerminal(reference, owner: session.id)
        }
        // A basename is a label. Never hand the working directory or command
        // (which may include a prompt) to the persistence boundary.
        ClientRecentPlaces.shared.record(
            in: account.account?.recentPlacesScope, peer: session.peer,
            workspaceID: session.workspaceID,
            workspaceName: URL(fileURLWithPath: session.cwd).lastPathComponent,
            kind: .terminal, itemID: session.hostID
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(SidebarTerminalNames.shared.name(for: session.workReference) ?? URL(fileURLWithPath: session.command).lastPathComponent)
                        .font(ClientType.label.weight(.semibold))
                        .lineLimit(1)
                    // Write failures and catch-up status can change on each
                    // typed key. Keep them in the existing fixed header line
                    // so they never resize the terminal or its remote PTY.
                    Button { showingTransportDetails = true } label: {
                        HStack(spacing: Theme.Space.xs) {
                            Text(statusText).lineLimit(1).truncationMode(.middle)
                            Image(systemName: ActionIcon.help.symbol)
                        }
                        .font(ClientType.caption)
                        .foregroundStyle(statusColor)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingTransportDetails) {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            Text(statusText).font(Theme.body)
                            ThemeRule()
                            Text(L10n.text("common.session_identity.title")).font(Theme.callout.weight(.semibold))
                            SessionIdentityRows(entries: session.identityEntries,
                                truncated: session.sessionIdentities?.truncated ?? false, reportedTotal: session.sessionIdentities?.total)
                        }
                        .padding(Theme.Space.m).frame(idealWidth: 320, maxWidth: 420)
                        .presentationCompactAdaptation(.popover)
                    }
                }
                Spacer()
                if session.droppedOutput {
                    Text(L10n.text("apple.clientterminalsession.output_dropped.99ba5f69"))
                        .font(ClientType.caption)
                        .foregroundStyle(Theme.warning)
                }
                if session.workspaceID != nil {
                    PinToggleButton(reference: session.workReference,
                        label: SidebarTerminalNames.shared.name(for: session.workReference) ?? L10n.text("apple.clientterminalsession.terminal.e0926fda"),
                        folderName: URL(fileURLWithPath: session.cwd).lastPathComponent)
                    Button(L10n.text("apple.clientterminalsession.project.98595978"), .source) { showingWorkspace = true }
                        .font(ClientType.caption.weight(.semibold))
                        .accessibilityLabel(L10n.text("apple.clientterminalsession.project_files_changes_and_history.4da56c40"))
                }
                Button(L10n.text("common.close"), .dismiss, role: .destructive) {
                    confirmClose = true
                }
                .font(ClientType.caption.weight(.semibold))
                Button(L10n.text("common.done"), .done) {
                    navigation.leaveTerminal(owner: session.id)
                    onClose?()
                    if !embedded { dismiss() }
                }
                .font(ClientType.caption.weight(.semibold))
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.background)

            ClientTerminalRepresentable(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // A row in the stack, not a `safeAreaInset`. The terminal is a
            // UIKit view that draws across its whole frame and ignores the
            // safe area it is handed, so an inset reserved nothing and the
            // bar covered the last lines of output. Taking the space out of
            // the layout is the only thing the terminal reflows around.
            //
            // Above the keyboard when it is up, above the home indicator when
            // it is not. Either way it is where a thumb already is.
            ClientTerminalKeys(
                send: { session.sendBytes($0) },
                toggleKeyboard: { session.toggleKeyboard() },
                scrolls: Binding(
                    get: { session.scrolls },
                    set: { session.scrolls = $0 }
                ),
                control: Binding(
                    get: { session.controlArmed },
                    set: { session.controlArmed = $0 }
                ),
                readingOutput: session.readingOutput,
                followOutput: { session.followOutput() }
            )
        }
        .background(TerminalPalette.surface.ignoresSafeArea())
        .navigationBarHidden(!embedded)
        .onAppear {
            session.setForeground(true)
            rememberTerminal()
        }
        .onChange(of: session.hostID) { _, _ in rememberTerminal() }
        .onChange(of: session.workReference) { _, _ in showingTransportDetails = false }
        .task(id: "live-\(session.hostID)-\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await session.updateLiveActivity()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            session.setForeground(phase == .active)
            if phase == .active {
                Task { await Bridge.nudgeTunnel() }
            }
        }
        .onDisappear {
            // Full-screen dismiss: stop draining when nobody is watching.
            // Re-open attaches a fresh session from pty.list.
            session.stop()
            navigation.leaveTerminal(owner: session.id)
        }
        .confirmationDialog(
            L10n.text("apple.clientterminalsession.close_this_session.2b66ce2d"),
            isPresented: $confirmClose,
            titleVisibility: .visible
        ) {
            Button(L10n.text("common.close"), role: .destructive) {
                Task {
                    do {
                        try await session.close()
                        navigation.leaveTerminal(owner: session.id)
                        ClientRecentPlaces.shared.remove(in: account.account?.recentPlacesScope,
                            peer: session.peer, workspaceID: session.workspaceID,
                            kind: .terminal, itemID: session.hostID)
                        onClosedProcess?()
                        onClose?()
                        if !embedded { dismiss() }
                    } catch {
                        // Keep the screen. The process is still running.
                    }
                }
            }
            Button(L10n.text("apple.clientterminalsession.keep_it.fdce5da2"), role: .cancel) {}
        } message: {
            Text(hostName.isEmpty
                ? L10n.text("apple.clientterminalsession.stops_the_process_on_the_computer.c5651cd1")
                : L10n.text("apple.clientterminalsession.stops_the_process_on_0.7aa0b494", "\(hostName)"))
        }
        .sheet(isPresented: $showingWorkspace) {
            if let workspaceID = session.workspaceID {
                NavigationStack {
                    ClientWorkspaceToolsView(
                        peer: session.peer,
                        workspaceID: workspaceID,
                        folderName: URL(fileURLWithPath: session.cwd).lastPathComponent,
                        hostName: hostName
                    )
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.text("common.done"), .done) { showingWorkspace = false }
                        }
                    }
                }
            }
        }
    }
}

#endif
