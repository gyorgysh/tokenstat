// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Observation
import SwiftTerm
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Observable
final class SSHLiveTerminal: TerminalViewDelegate, TerminalPresentable {
    private var outputFilter = TerminalOutputFilter()
    @ObservationIgnored private let inputQueue = SSHInputQueue()
    let id: String
    let hostID: String?
    var title: String
    private(set) var closed = false
    var attached: Bool { !reader.retired }
    private var readError: String?
    private var closeError: String?
    var error: String? {
        get { closeError ?? readError }
        set { readError = newValue }
    }
    @ObservationIgnored private var resizeRevision: UInt64 = 0
    @ObservationIgnored private var focusPresentation: UUID?
    @ObservationIgnored private let closeFlight = Singleflight<Bool>()
    @ObservationIgnored private lazy var reader = SSHOutputReader(
        read: { [id] offset in
            do {
                let chunk = try await Bridge.readSSHSession(id: id, offset: offset)
                return SSHOutputChunk(data: chunk.data, nextOffset: chunk.nextOffset,
                                      dropped: chunk.dropped, closed: chunk.closed, error: chunk.error)
            } catch {
                if Bridge.isSSHSessionMissing(error) { throw SSHOutputReaderError.sessionMissing }
                throw error
            }
        },
        deliver: { [weak self] chunk in self?.consumeOutput(chunk) },
        failed: { [weak self] error in
            guard let self else { return }
            if case SSHOutputReaderError.sessionMissing = error { self.markClosed(error: error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    )
    @ObservationIgnored private var terminalView: TerminalView?
    @ObservationIgnored private var colorSchemeIsDark: Bool?
    @ObservationIgnored private var predicted: [UInt8] = []
    @ObservationIgnored private var predictedSince: Date?
    @ObservationIgnored private var predictionsDetachedFromCursor = false
    @ObservationIgnored private var probing: [UInt8] = []
    @ObservationIgnored private var lineEchoes = false
    @ObservationIgnored private var lineSilent = false
    @ObservationIgnored private var recentOutput: [UInt8] = []
    @ObservationIgnored private var typedLine = ""
    @ObservationIgnored private var remoteDirectory: String?
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    @ObservationIgnored private var suggestGeneration = 0
    private(set) var suggestions: [SSHSuggestion] = []
    @ObservationIgnored private var suggestionsFragment = ""
    @ObservationIgnored private var dismissedLine: String?
    private(set) var highlighted: Int?
    var snippetToFill: SSHSuggestion?
    @ObservationIgnored private(set) var pendingReplacement = 0
    #if os(macOS)
    @ObservationIgnored private lazy var palette = SSHPaletteLayer { [weak self] event in
        self?.claimForPalette(event) ?? false
    }
    #else
    private(set) var paletteAnchor: CGPoint?
    private(set) var paletteLineHeight: CGFloat = 0
    #endif

    var handle: String { id }

    var alive: Bool { !closed }

    var terminalViewIfLoaded: TerminalView? { terminalView }

    func terminalReturnedToFront() {
        guard reader.foreground, attached else { return }
        withdrawPredictions()
        reassertSize()
    }

    private func reassertSize() {
        guard reader.canInput, let size = terminalView?.terminalDimensions else { return }
        queueResize(rows: size.rows, cols: size.cols)
    }

    private func queueResize(rows: Int, cols: Int) {
        guard reader.canInput, rows > 0, cols > 0 else { return }
        resizeRevision &+= 1
        let revision = resizeRevision, epoch = reader.inputEpoch
        let handle = id
        inputQueue.enqueue { [weak self] in
            guard let self, self.reader.acceptsInput(epoch), self.resizeRevision == revision else { return false }
            try? await Bridge.resizeSSHSession(id: handle, rows: rows, cols: cols)
            return true
        }
    }

    init(handle: SSHSessionHandle, title: String, hostID: String? = nil) {
        self.id = handle.id
        self.title = title
        self.hostID = hostID
        _ = view
        reader.start()
    }

    init(adopting session: SSHSessionSummary) {
        self.id = session.id
        self.title = session.label
        self.hostID = session.hostID
        self.closed = !session.alive
        _ = view
        if closed { reader.noteShellEnded() }
        reader.start()
    }

    var view: TerminalView {
        if let terminalView { return terminalView }
        #if os(macOS)
        let made = TerminalSelectionView(frame: .zero)
        made.font = AppFonts.terminal(size: 12)
        #else
        let made = ClientTerminalInputView(frame: .zero)
        made.font = AppFonts.terminal(size: 12)
        made.inputAccessoryView = nil
        #endif
        #if os(macOS)
        let dark = made.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #else
        let dark = made.traitCollection.userInterfaceStyle == .dark
        #endif
        TerminalPalette.paint(dark: dark, to: made)
        made.optionAsMetaKey = true
        made.changeScrollback(4_000)
        made.terminalDelegate = self
        #if !os(macOS)
        made.scrollMode = scrolls
        made.onReadingChanged = { [weak self] reading in
            guard let self else { return }
            let epoch = self.reader.inputEpoch
            DispatchQueue.main.async { [weak self] in
                guard let self, self.attached, self.reader.foreground, self.reader.inputEpoch == epoch else { return }
                if self.readingOutput != reading { self.readingOutput = reading }
            }
        }
        #endif
        terminalView = made
        return made
    }

    func applyColors(dark: Bool) {
        guard let terminalView, dark != colorSchemeIsDark else { return }
        colorSchemeIsDark = dark
        TerminalPalette.paint(dark: dark, to: terminalView)
    }

    private func consumeOutput(_ chunk: SSHOutputChunk) {
        self.error = nil
        if !chunk.data.isEmpty { noteEcho(chunk.data) }
        if chunk.dropped {
            withdrawPredictions()
            feedView(text: "\r\n[tokenstat: older output was dropped]\r\n")
        }
        if !chunk.data.isEmpty {
            let rest = reconcilePredictions(with: chunk.data)
            if !rest.isEmpty { feedView(outputFilter.filter(rest)[...]) }
            if !suggestions.isEmpty { placePalette() }
        }
        if chunk.closed {
            closed = true
            error = chunk.error
        }
    }

    func setForeground(_ value: Bool) {
        guard reader.foreground != value else { return }
        withdrawPredictions()
        forgetLine()
        reader.setForeground(value)
        if value { reassertSize() }
    }


    private func noteTyped(_ bytes: [UInt8]) {
        guard bytes.count == 1, let byte = bytes.first else {
            forgetLine()
            return
        }
        switch byte {
        case 0x20...0x7e:
            typedLine.append(Character(UnicodeScalar(byte)))
        case 0x7f, 0x08:
            if typedLine.isEmpty {
                forgetLine()
                return
            }
            typedLine.removeLast()
        case 0x0d, 0x0a:
            if lineEchoes, !lineSilent, !typedLine.trimmingCharacters(in: .whitespaces).isEmpty {
                let handle = handle
                let line = typedLine
                let directory = remoteDirectory
                let epoch = reader.inputEpoch
                Task { [weak self] in
                    guard let self, self.reader.acceptsInput(epoch) else { return }
                    await Bridge.sshSessionRan(id: handle, command: line, directory: directory)
                }
            }
            forgetLine()
            return
        default:
            forgetLine()
            return
        }
        refreshSuggestions()
    }

    private func forgetLine() {
        typedLine = ""
        dismissedLine = nil
        closePalette()
    }

    private var suggestionsWelcome: Bool {
        guard reader.canInput, lineEchoes, !lineSilent else { return false }
        guard let terminal = terminalView?.terminalInputStateSnapshot() else { return false }
        return !terminal.isAlternateBuffer
    }

    private func refreshSuggestions() {
        suggestTask?.cancel()
        suggestGeneration += 1
        let generation = suggestGeneration, epoch = reader.inputEpoch
        guard reader.canInput, typedLine.count >= 2 else {
            closePalette()
            return
        }
        if let dismissedLine, typedLine.hasPrefix(dismissedLine) {
            closePalette()
            return
        }
        let fragment = typedLine
        let directory = remoteDirectory
        let handle = handle
        suggestTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.suggestDelayMs))
            for _ in 0..<Self.suggestAttempts {
                guard !Task.isCancelled, let self, self.reader.acceptsInput(epoch),
                      self.suggestGeneration == generation else {
                    return
                }
                guard self.suggestionsWelcome, self.typedLine == fragment else {
                    self.closePalette()
                    return
                }
                let answer = try? await Bridge.suggestSSHSession(
                    id: handle, fragment: fragment, directory: directory
                )
                guard !Task.isCancelled, self.reader.acceptsInput(epoch),
                      self.suggestGeneration == generation else { return }
                guard let answer, answer.fragment == fragment else { return }
                if !answer.pending || !answer.rows.isEmpty {
                    self.show(answer.rows)
                }
                guard answer.pending else { return }
                try? await Task.sleep(for: .milliseconds(Self.suggestRetryMs))
            }
        }
    }

    private func show(_ rows: [SSHSuggestion]) {
        let same = rows.map(\.id) == suggestions.map(\.id)
        suggestions = rows
        suggestionsFragment = typedLine
        if !same || rows.isEmpty { highlighted = nil }
        placePalette()
    }

    private func closePalette() {
        suggestTask?.cancel()
        suggestTask = nil
        suggestions = []
        highlighted = nil
        #if os(macOS)
        palette.hide()
        #else
        paletteAnchor = nil
        #endif
    }

    private var cursorAnchor: (point: CGPoint, lineHeight: CGFloat)? {
        terminalView?.terminalCursorAnchor
    }

    private func placePalette() {
        guard !suggestions.isEmpty, let anchor = cursorAnchor else {
            #if os(macOS)
            palette.hide()
            #else
            paletteAnchor = nil
            #endif
            return
        }
        #if os(macOS)
        guard let terminalView else { return }
        palette.show(
            SSHSuggestionPanel(session: self),
            in: terminalView,
            cursor: anchor.point,
            lineHeight: anchor.lineHeight
        )
        #else
        paletteAnchor = anchor.point
        paletteLineHeight = anchor.lineHeight
        #endif
    }

    func accept(_ row: SSHSuggestion) {
        guard alive, let count = replacement(for: row) else {
            closePalette()
            return
        }
        if row.isSnippet, !row.variables.isEmpty {
            pendingReplacement = count
            snippetToFill = row
            closePalette()
            return
        }
        insert(row.insert, replacing: count)
    }

    private func replacement(for row: SSHSuggestion) -> Int? {
        SSHCompletionReplacement.count(replacing: row.replace, fragment: suggestionsFragment, current: typedLine)
    }

    func insert(_ text: String, replacing count: Int) {
        guard reader.canInput, count >= 0, count <= typedLine.count else { return }
        withdrawPredictions()
        var bytes = [UInt8](repeating: 0x7f, count: count)
        bytes.append(contentsOf: Array(text.utf8))
        typedLine = String(typedLine.dropLast(count)) + text
        closePalette()
        let handle = handle, epoch = reader.inputEpoch
        inputQueue.enqueue { [weak self] in
            guard let self, self.reader.acceptsInput(epoch) else { return false }
            try? await Bridge.writeSSHSession(id: handle, data: bytes)
            return true
        }
    }

    func step(_ direction: Int) {
        guard !suggestions.isEmpty else { return }
        guard let current = highlighted else {
            if direction > 0 { highlighted = 0 }
            placePalette()
            return
        }
        let next = current + direction
        highlighted = next < 0 ? nil : min(next, suggestions.count - 1)
        placePalette()
    }

    func acceptHighlighted() {
        guard let index = highlighted, index < suggestions.count else { return }
        accept(suggestions[index])
    }

    func dismissSuggestions() {
        dismissedLine = typedLine
        closePalette()
    }

    private static let suggestDelayMs = 60
    private static let suggestRetryMs = 150
    private static let suggestAttempts = 8


    private func predict(_ bytes: [UInt8]) {
        noteTyped(bytes)
        guard bytes.count == 1, let byte = bytes.first else {
            endPredictionLine()
            return
        }
        switch byte {
        case 0x20...0x7e:
            guard canPredict else {
                endPredictionLine()
                return
            }
            if lineEchoes {
                if predicted.isEmpty { predictedSince = Date() }
                predicted.append(byte)
                feedView(ArraySlice([byte]))
            } else if !lineSilent {
                probing.append(byte)
                if probing.count >= Self.probeLimit {
                    lineSilent = true
                    probing.removeAll()
                }
            }
        case 0x7f, 0x08:
            if predicted.isEmpty || predictionsDetachedFromCursor {
                endPredictionLine()
            } else {
                predicted.removeLast()
                feedView(ArraySlice(Self.eraseCell))
            }
            if !probing.isEmpty { probing.removeLast() }
        default:
            endPredictionLine()
            predictionsDetachedFromCursor = true
        }
    }

    private func reconcilePredictions(with data: [UInt8]) -> ArraySlice<UInt8> {
        defer { predictionsDetachedFromCursor = false }
        guard !predicted.isEmpty else { return ArraySlice(data) }
        if predictionsDetachedFromCursor {
            predicted.removeAll()
            predictedSince = nil
            return ArraySlice(data)
        }
        if let since = predictedSince,
           Date().timeIntervalSince(since) > Self.maxEchoAge {
            eraseRemainingPredictions()
            return ArraySlice(data)
        }
        var confirmed = 0
        while confirmed < predicted.count,
              confirmed < data.count,
              predicted[confirmed] == data[confirmed] {
            confirmed += 1
        }
        if confirmed > 0 { predicted.removeFirst(confirmed) }
        let rest = data[confirmed...]
        if rest.isEmpty { return rest }
        eraseRemainingPredictions()
        return rest
    }

    private func withdrawPredictions() {
        defer { predictionsDetachedFromCursor = false }
        guard !predicted.isEmpty else { return }
        if predictionsDetachedFromCursor {
            predicted.removeAll()
            return
        }
        eraseRemainingPredictions()
    }

    private func eraseRemainingPredictions() {
        guard !predicted.isEmpty else { return }
        var undo: [UInt8] = []
        undo.reserveCapacity(predicted.count * Self.eraseCell.count)
        for _ in predicted { undo.append(contentsOf: Self.eraseCell) }
        predicted.removeAll()
        predictedSince = nil
        feedView(ArraySlice(undo))
    }

    private func forgetPredictions() {
        predicted.removeAll()
        predictedSince = nil
        predictionsDetachedFromCursor = false
        probing.removeAll()
        recentOutput.removeAll()
        lineEchoes = false
        lineSilent = false
    }

    private func endPredictionLine() {
        probing.removeAll()
        recentOutput.removeAll()
        lineEchoes = false
        lineSilent = false
    }

    private func noteEcho(_ data: [UInt8]) {
        guard !probing.isEmpty else { return }
        recentOutput.append(contentsOf: data)
        if recentOutput.count > Self.echoWindow {
            recentOutput.removeFirst(recentOutput.count - Self.echoWindow)
        }
        guard probing.count >= 2, recentOutput.contains(sequence: probing) else { return }
        lineEchoes = true
        probing.removeAll()
        recentOutput.removeAll()
    }

    private var canPredict: Bool {
        guard let terminal = terminalView?.terminalInputStateSnapshot() else { return false }
        guard !terminal.isAlternateBuffer else { return false }
        guard let view = terminalView else { return false }
        return view.terminalStateSnapshot().cursor.col + 2 < terminal.dimensions.cols
    }

    #if os(macOS)
    private func claimForPalette(_ event: NSEvent) -> Bool {
        guard !suggestions.isEmpty else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isSubset(of: [.function, .numericPad, .capsLock]) else { return false }
        switch event.keyCode {
        case Self.keyDown:
            step(1)
            return true
        case Self.keyUp:
            guard highlighted != nil else { return false }
            step(-1)
            return true
        case Self.keyTab, Self.keyReturn, Self.keyEnter:
            guard highlighted != nil else { return false }
            acceptHighlighted()
            return true
        case Self.keyEscape:
            dismissSuggestions()
            return true
        default:
            return false
        }
    }

    private static let keyReturn: UInt16 = 36
    private static let keyTab: UInt16 = 48
    private static let keyEscape: UInt16 = 53
    private static let keyEnter: UInt16 = 76
    private static let keyUp: UInt16 = 126
    private static let keyDown: UInt16 = 125
    #endif

    private static let eraseCell: [UInt8] = [0x08, 0x20, 0x08]

    /// Feed the emulator. On Mac this keeps a drag selection unless the guest
    /// enabled mouse mode; on iOS the phone's scroll toggle owns that flag.
    private func feedView(_ bytes: ArraySlice<UInt8>) {
        view.feedOutput(bytes)
    }

    private func feedView(text: String) {
        view.feedOutput(text)
    }

    private static let probeLimit = 6

    private static let echoWindow = 256

    private static let maxEchoAge: TimeInterval = 3

    var scrolls: Bool = false {
        didSet {
            #if !os(macOS)
            guard scrolls != oldValue else { return }
            (terminalView as? ClientTerminalInputView)?.scrollMode = scrolls
            #endif
        }
    }

    #if !os(macOS)
    var readingOutput = false
    func followOutput() { (terminalView as? ClientTerminalInputView)?.followLatest() }
    #endif

    var controlArmed: Bool = false

    func toggleKeyboard() {
        #if !os(macOS)
        guard reader.canInput, let view = terminalView else { return }
        if view.isFirstResponder {
            _ = view.resignFirstResponder()
        } else {
            _ = view.becomeFirstResponder()
        }
        #endif
    }

    func sendBytes(_ bytes: [UInt8]) {
        guard reader.canInput, !bytes.isEmpty else { return }
        let handle = handle, epoch = reader.inputEpoch
        predict(bytes)
        inputQueue.enqueue { [weak self] in
            guard let self, self.reader.acceptsInput(epoch) else { return false }
            try? await Bridge.writeSSHSession(id: handle, data: bytes)
            return true
        }
    }

    func sendStartupBytes(_ bytes: [UInt8], beforeDispatch: @escaping @MainActor () -> Bool) async -> Bool {
        guard reader.canInput, !bytes.isEmpty else { return false }
        let epoch = reader.inputEpoch
        return await inputQueue.enqueue { [weak self] in
            guard let self, self.reader.acceptsInput(epoch), beforeDispatch() else { return false }
            self.predict(bytes)
            try? await Bridge.writeSSHSession(id: self.id, data: bytes)
            return true
        }.value
    }

    func stop() {
        Task { [self] in _ = await closeRemote() }
    }

    func closeRemote() async -> Bool {
        guard attached else { return true }
        return await closeFlight.run { [self] in
            guard let token = reader.beginClose() else { return !attached }
            withdrawPredictions()
            forgetLine()
            do {
                try await Bridge.closeSSHSession(id: id)
                reader.finishClose(token, succeeded: true)
                closed = true
                closeError = nil
                error = nil
                return true
            } catch {
                reader.finishClose(token, succeeded: false)
                if attached { self.closeError = error.localizedDescription }
                return false
            }
        }
    }

    func detachPoll() {
        reader.retire()
        withdrawPredictions()
        forgetLine()
        closePalette()
    }

    func markClosed(error: String? = nil) {
        reader.noteShellEnded()
        withdrawPredictions()
        forgetLine()
        closed = true
        if let error { self.error = error }
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            guard source === terminalView, reader.canInput else { return }
            var out = Array(data)
            if controlArmed {
                controlArmed = false
                if !out.isEmpty, let folded = TerminalControlCode.fold(out[0]) { out[0] = folded }
            }
            sendBytes(out)
        }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard Thread.isMainThread, newCols > 0, newRows > 0 else { return }
        MainActor.assumeIsolated {
            guard source === terminalView, reader.canInput else { return }
            forgetPredictions()
            forgetLine()
            queueResize(rows: newRows, cols: newCols)
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            guard source === terminalView, attached, reader.foreground else { return }
            remoteDirectory = SSHLiveTerminal.directoryPath(fromOSC7: directory)
        }
    }

    nonisolated static func directoryPath(fromOSC7 value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("file://") {
            guard let url = URL(string: value), url.isFileURL, !url.path.isEmpty else {
                return nil
            }
            return url.path
        }
        return value.hasPrefix("/") ? value : nil
    }
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard Thread.isMainThread, let text = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated {
            guard source === terminalView, attached, reader.foreground else { return }
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #else
            UIPasteboard.general.string = text
            #endif
        }
    }

    func claimFocusPresentation() -> UUID {
        let token = UUID()
        focusPresentation = token
        return token
    }

    func acceptsFocus(_ token: UUID, epoch: UInt64) -> Bool {
        focusPresentation == token && reader.acceptsInput(epoch)
    }

    func releaseFocusPresentation(_ token: UUID) {
        if focusPresentation == token { focusPresentation = nil }
    }

    var inputEpoch: UInt64 { reader.inputEpoch }

}

#if os(macOS)
struct SSHNativeTerminal: NSViewRepresentable {
    let session: SSHLiveTerminal
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> TerminalView { session.view }
    func updateNSView(_ view: TerminalView, context: Context) {
        session.applyColors(dark: colorScheme == .dark)
    }
}
#else
struct SSHNativeTerminal: UIViewRepresentable {
    let session: SSHLiveTerminal
    @Environment(\.colorScheme) private var colorScheme
    final class Coordinator {
        var token: UUID?
        weak var session: SSHLiveTerminal?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> TerminalView {
        let view = session.view
        let token = session.claimFocusPresentation(), epoch = session.inputEpoch
        context.coordinator.token = token
        context.coordinator.session = session
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            guard coordinator?.token == token, let view,
                  session.acceptsFocus(token, epoch: epoch), let window = view.window,
                  window.windowScene?.activationState == .foregroundActive,
                  !view.bounds.isEmpty, view.alpha > 0.01,
                  view.convert(view.bounds, to: window).intersects(window.bounds) else { return }
            var ancestor: UIView? = view
            while let current = ancestor {
                guard !current.isHidden, current.alpha > 0.01 else { return }
                ancestor = current.superview
            }
            _ = view.becomeFirstResponder()
        }
        return view
    }
    func updateUIView(_ view: TerminalView, context: Context) {
        session.applyColors(dark: colorScheme == .dark)
    }
    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        if let token = coordinator.token { coordinator.session?.releaseFocusPresentation(token) }
        coordinator.token = nil
    }

}
#endif

struct SSHLiveTerminalScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var sessions: SSHSessionsModel
    let session: SSHLiveTerminal
    var library: SSHLibraryModel?
    var onNewSession: (() -> Void)?

    @State private var asking: SSHSnippet?
    @State private var confirmingClose = false
    @State private var closeTicket: UUID?
    @State private var closeFailure: String?

    private var siblings: [SSHLiveTerminal] {
        guard let hostID = session.hostID else { return [session] }
        return sessions.sessions(for: hostID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.title).font(Theme.headline)
                if !session.alive {
                    Text(L10n.text("apple.sshliveterminal.ended.e87ba7a0")).font(Theme.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("apple.sshliveterminal.end_session.f00b921f"), .disconnect) { confirmingClose = true }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .disabled(closeTicket != nil)
                Button(L10n.text("common.done"), .done) { dismiss() }
            }
            .padding(Theme.Space.s)
            if siblings.count > 1 { tabs }
            ThemeRule()
            #if os(macOS)
            SSHNativeTerminal(session: session)
            #else
            SSHNativeTerminal(session: session)
                .overlay(alignment: .topLeading) { SSHPaletteOverlay(session: session) }
                .paletteSnippetSheet(session)
            #endif
            #if !os(macOS)
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
                followOutput: { session.followOutput() },
                leading: snippetKey
            )
            #endif
        }
        .background(TerminalPalette.surface)
        .sheet(item: $asking) { snippet in
            SSHSnippetRunSheet(snippet: snippet) { command in
                session.sendBytes(SSHSnippet.bytesToRun(command))
            }
        }

        .confirmationDialog(L10n.text("apple.sshliveterminal.end_this_session.2a445dc0"), isPresented: $confirmingClose, titleVisibility: .visible) {
            Button(L10n.text("apple.sshliveterminal.end_session.f00b921f"), role: .destructive) {
                endSession()
            }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("apple.sshliveterminal.whatever_is_running_in_it_stops_nothing_el.f25aee6b"))
        }
        .alert(L10n.text("apple.sshliveterminal.could_not_end_retry"), isPresented: Binding(
            get: { closeFailure != nil }, set: { if !$0 { closeFailure = nil } }
        )) {
            Button(L10n.text("apple.clientsetupstate.try_again.d8b8392e")) { endSession() }
            Button(L10n.text("common.cancel"), role: .cancel) {}
        } message: { Text(closeFailure ?? "") }
        .onDisappear { closeTicket = nil }
        .onChange(of: session.id) { _, _ in closeTicket = nil; closeFailure = nil }
    }

    private func endSession() {
        guard closeTicket == nil else { return }
        let token = UUID(), doomed = session
        closeTicket = token
        Task {
            let ended = await sessions.close(doomed)
            guard closeTicket == token else { return }
            closeTicket = nil
            if ended { dismiss() }
            else { closeFailure = doomed.error ?? L10n.text("apple.sshliveterminal.could_not_end_retry") }
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Space.xs) {
                ForEach(siblings) { other in
                    Button {
                        sessions.select(other)
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(other.alive ? Theme.accent : Theme.stateIdle)
                                .frame(width: 6, height: 6)
                            Text(other.title)
                                .font(Theme.caption)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.vertical, 5)
                        .background(
                            other.id == session.id ? Theme.panel : Color.clear,
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                other.id == session.id ? Theme.border : .clear,
                                lineWidth: 1
                            )
                        )
                        .foregroundStyle(other.id == session.id ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(QuietLinkStyle())
                }
                if let onNewSession {
                    Button(L10n.text("apple.sshliveterminal.new_terminal.fe544556"), .create, action: onNewSession)
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.bottom, Theme.Space.xs)
        }
        .scrollIndicators(.hidden)
    }

    #if !os(macOS)
    private var snippetKey: AnyView? {
        guard let library else { return nil }
        let snippets = session.hostID.map { library.snippets(for: $0) }
            ?? library.snippets.filter { $0.hostIDs.isEmpty }
        guard !snippets.isEmpty else { return nil }
        return AnyView(
            Menu {
                ForEach(snippets) { snippet in
                    Button(snippet.title, .run) { run(snippet) }
                }
            } label: {
                Image(systemName: "text.append")
                    .font(Theme.font(13, weight: .medium))
                    .frame(minWidth: 34, minHeight: 30)
            }
            .accessibilityLabel(L10n.text("apple.sshliveterminal.snippets.ff717209"))
        )
    }
    #endif

    private func run(_ snippet: SSHSnippet) {
        if SSHSnippet.placeholders(in: snippet.command).isEmpty {
            session.sendBytes(SSHSnippet.bytesToRun(snippet.command))
        } else {
            asking = snippet
        }
    }
}

struct SSHSnippetRunSheet: View {
    @Environment(\.dismiss) private var dismiss
    let snippet: SSHSnippet
    var action: String = L10n.text("apple.sshliveterminal.run_it.958ca26c")
    var icon: ActionIcon = .run
    let onFilled: (String) -> Void

    @State private var values: [String: String] = [:]

    private var names: [String] { SSHSnippet.placeholders(in: snippet.command) }

    private var filled: String {
        var out = snippet.command
        for name in names {
            out = out.replacingOccurrences(of: "{{\(name)}}", with: values[name] ?? "")
        }
        return out
    }

    private var ready: Bool {
        names.allSatisfy { !(values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        ThemedSheet(
            title: snippet.title,
            subtitle: L10n.text("apple.sshliveterminal.values_are_asked_for_every_time_and_never.407fc629"),
            icon: .run,
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ForEach(names, id: \.self) { name in
                    SSHEditorField(label: name) {
                        TextField(name, text: Binding(
                            get: { values[name] ?? "" },
                            set: { values[name] = $0 }
                        ))
                        .textFieldStyle(.themed)
                    }
                }
                Text(filled)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.controlGlyph)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } actions: {
            Button(L10n.text("common.cancel"), .dismiss) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(action, icon) {
                onFilled(filled)
                dismiss()
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(!ready)
            .keyboardShortcut(.defaultAction)
        }
        .modalFrame(width: 540, height: 480)
    }
}

private extension Array where Element == UInt8 {
    func contains(sequence other: [UInt8]) -> Bool {
        guard !other.isEmpty, count >= other.count else { return false }
        for start in 0...(count - other.count) {
            if self[start..<(start + other.count)].elementsEqual(other) { return true }
        }
        return false
    }
}
