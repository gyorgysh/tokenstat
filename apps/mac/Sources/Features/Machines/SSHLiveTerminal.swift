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
    /// The host's session id. Also this object's identity, because the two are
    /// the same thing: a session is the handle, and a second id would be a
    /// second answer to "which session is this" for the list to disagree with.
    let id: String
    /// Which saved record this came from, when it came from one.
    let hostID: String?
    let title: String
    private(set) var closed = false
    var error: String?
    @ObservationIgnored private var offset: UInt64 = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var terminalView: TerminalView?
    /// What the view is currently painted for, so a redraw is only done when
    /// the appearance actually changed.
    @ObservationIgnored private var colorSchemeIsDark: Bool?
    /// Characters drawn here the moment they were typed, before the far end
    /// has echoed them. See `predict`.
    @ObservationIgnored private var predicted: [UInt8] = []
    /// Set once a control key has moved the cursor away from the end of the
    /// guessed text, after which the guesses can no longer be rubbed out
    /// with backspaces: the cells behind the cursor are no longer ours.
    @ObservationIgnored private var predictionsDetachedFromCursor = false
    /// Typed, sent, and deliberately not drawn, because this line has not yet
    /// proved that it echoes at all. See `predict`.
    @ObservationIgnored private var probing: [UInt8] = []
    /// This line echoes what is typed into it.
    @ObservationIgnored private var lineEchoes = false
    /// This line was tested and does not echo. A password prompt, and the
    /// reason nothing is guessed on it for the rest of the line.
    @ObservationIgnored private var lineSilent = false
    /// The tail of what the far end has sent, for the echo test. Bounded and
    /// discarded: it exists for a substring search a few bytes long and never
    /// leaves this object.
    @ObservationIgnored private var recentOutput: [UInt8] = []
    /// What has been typed on this line since the last Return, as far as this
    /// side can tell. Kept only to ask the host what to offer for it, and
    /// dropped the moment a control key says the shell is now editing the
    /// line in a way that cannot be followed from here.
    @ObservationIgnored private var typedLine = ""
    /// Where the far end says the session is sitting, when it says so at all.
    /// A server that emits OSC 7 gets relative paths completed; one that does
    /// not gets absolute and `~` paths, and silence for the rest.
    @ObservationIgnored private var remoteDirectory: String?
    @ObservationIgnored private var suggestTask: Task<Void, Never>?
    /// Which request the answers being waited for belong to. An answer for an
    /// older one is thrown away rather than shown under a line that has moved
    /// on.
    @ObservationIgnored private var suggestGeneration = 0
    /// What the host is offering for the line as it stands.
    private(set) var suggestions: [SSHSuggestion] = []
    /// The line the rows on screen answer. Typing does not clear them, so
    /// what a row replaces is measured from here rather than from the row.
    @ObservationIgnored private var suggestionsFragment = ""
    /// A line somebody pressed Escape on. Nothing is offered for it again
    /// until they change it into something else, because a palette that came
    /// straight back would be an answer to a question they just closed.
    @ObservationIgnored private var dismissedLine: String?
    /// Which row the keyboard is on, and `nil` while nobody has stepped into
    /// the list. That difference is the whole of the key handling: until it
    /// is set, Tab, Return and Up still belong to the shell.
    private(set) var highlighted: Int?
    /// A saved command chosen from the palette that needs its placeholders
    /// filled before it can be typed. The screen showing this session asks.
    var snippetToFill: SSHSuggestion?
    /// How much of the line that command replaces, measured when it was
    /// chosen rather than when the sheet is answered.
    @ObservationIgnored private(set) var pendingReplacement = 0
    #if os(macOS)
    @ObservationIgnored private lazy var palette = SSHPaletteLayer { [weak self] event in
        self?.claimForPalette(event) ?? false
    }
    #else
    /// Where the palette goes, in the terminal's own coordinates. The phone
    /// and iPad draw it as an overlay on the screen, because the emulator
    /// there is a scroll view and a subview of one would scroll with the
    /// buffer.
    private(set) var paletteAnchor: CGPoint?
    private(set) var paletteLineHeight: CGFloat = 0
    #endif

    /// The handle, under the name the Bridge calls it. Kept so the call sites
    /// read as what they are rather than as `id` doing double duty.
    var handle: String { id }

    /// Alive until the far end hangs up. The tab strip greys a dead session
    /// rather than removing it: output somebody has not read yet is worth more
    /// than a tidy strip.
    var alive: Bool { !closed }

    /// The emulator, once it exists. `TerminalStack` reads this and nothing
    /// else, which is what lets one stack hold both kinds of session.
    var terminalViewIfLoaded: TerminalView? { terminalView }

    init(handle: SSHSessionHandle, title: String, hostID: String? = nil) {
        self.id = handle.id
        self.title = title
        self.hostID = hostID
        _ = view
        pollTask = Task { [weak self] in await self?.poll() }
    }

    /// Adopt a session the host is already holding.
    ///
    /// After a relaunch the shells are still up: the host owns them, not the
    /// app. Reading from offset zero replays whatever is still buffered, so a
    /// re-adopted tab opens on its scrollback rather than on a blank screen.
    init(adopting session: SSHSessionSummary) {
        self.id = session.id
        self.title = session.label
        self.hostID = session.hostID
        self.closed = !session.alive
        _ = view
        pollTask = Task { [weak self] in await self?.poll() }
    }

    var view: TerminalView {
        if let terminalView { return terminalView }
        #if os(macOS)
        let made = TerminalView(frame: .zero)
        made.font = AppFonts.terminal(size: 12)
        #else
        let made = TerminalView(frame: .zero)
        made.font = AppFonts.terminal(size: 12)
        made.inputAccessoryView = nil
        #endif
        // Before anything else. A terminal with no native background does not
        // erase a cell before drawing into it, so every repaint composited on
        // top of what was already there: old output stayed, new output landed
        // over it, and clear painted an absent colour over the same pixels and
        // changed nothing. This view was the one of the three that never set
        // it. See `TerminalPalette`.
        TerminalPalette.paint(dark: TerminalPalette.systemIsDark, to: made)
        made.optionAsMetaKey = true
        made.getTerminal().changeHistorySize(4_000)
        made.terminalDelegate = self
        terminalView = made
        return made
    }

    /// Follow the system between light and dark while the session is open.
    ///
    /// The colour is set once at creation from whatever the system was then,
    /// and a session outlives a change of appearance.
    func applyColors(dark: Bool) {
        guard let terminalView, dark != colorSchemeIsDark else { return }
        colorSchemeIsDark = dark
        TerminalPalette.paint(dark: dark, to: terminalView)
    }

    private func poll() async {
        while !Task.isCancelled && !closed {
            do {
                let chunk = try await Bridge.readSSHSession(id: handle, offset: offset)
                if !chunk.data.isEmpty { noteEcho(chunk.data) }
                // A gap in the stream says nothing about where the cursor is,
                // so there is nothing to reconcile a guess against and every
                // one of them comes off.
                if chunk.dropped {
                    withdrawPredictions()
                    view.feed(text: "\r\n[tokenstat: older output was dropped]\r\n")
                }
                if !chunk.data.isEmpty {
                    offset = chunk.nextOffset
                    // Before anything reaches the emulator, and only here.
                    // What was guessed and is not confirmed by this chunk has
                    // to come off the screen before the far end's own version
                    // of it goes on, or the line ends up saying everything
                    // twice. Both happen inside one turn on the main actor, so
                    // there is no frame in which the line is missing.
                    let rest = reconcilePredictions(with: chunk.data)
                    if !rest.isEmpty { view.feed(byteArray: rest) }
                    // The prompt may have moved down a line, or the shell may
                    // have redrawn it. The palette belongs beside the cursor,
                    // so it follows rather than being left where it was.
                    if !suggestions.isEmpty { placePalette() }
                }
                if chunk.closed {
                    closed = true
                    error = chunk.error
                    break
                }
                try? await Task.sleep(for: .milliseconds(chunk.data.isEmpty ? 50 : 16))
            } catch {
                self.error = error.localizedDescription
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - What to offer

    /// Follow the line being typed, so the host can be asked about it.
    ///
    /// Printable characters extend it and backspace shortens it. Anything
    /// else, a Return, an arrow, a paste, a chord, means the shell is now
    /// editing this line somewhere only it can see, so the record is dropped
    /// rather than kept and wrong. Nothing here is stored or sent anywhere:
    /// it lives for as long as the line does.
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
            // Submitted. Hand it to the host so the session can offer it back
            // and follow a `cd` with it, but only if this line proved it
            // echoes: a prompt with echo off never confirms, so a password is
            // never one of these.
            if lineEchoes, !lineSilent, !typedLine.trimmingCharacters(in: .whitespaces).isEmpty {
                let handle = handle
                let line = typedLine
                let directory = remoteDirectory
                Task {
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

    /// This line is no longer one this side can follow.
    private func forgetLine() {
        typedLine = ""
        dismissedLine = nil
        closePalette()
    }

    /// Whether a palette may be shown at all right now.
    ///
    /// The strongest of these is `lineEchoes`: a palette only ever appears on
    /// a line the far end has been seen echoing, which is the same test that
    /// keeps a password from being drawn. A prompt with echo off never
    /// confirms, so nothing is ever offered beside one, and nothing typed
    /// into one is ever sent anywhere to be matched against.
    private var suggestionsWelcome: Bool {
        guard !closed, lineEchoes, !lineSilent else { return false }
        guard let terminal = terminalView?.getTerminal() else { return false }
        // A full-screen program owns every cell, and the palette would be
        // drawn over somebody's editor.
        return !terminal.isCurrentBufferAlternate
    }

    /// Ask the host what to offer, once the typing pauses.
    ///
    /// Debounced, because this runs on every keystroke, and generation-
    /// stamped, because an answer that arrives after the line has changed is
    /// an answer to a question nobody is asking any more. A host that says it
    /// is still fetching a directory is asked again shortly, so a listing
    /// that lands during a pause still reaches the screen.
    private func refreshSuggestions() {
        suggestTask?.cancel()
        suggestGeneration += 1
        let generation = suggestGeneration
        guard !closed, typedLine.count >= 2 else {
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
                guard !Task.isCancelled, let self, self.suggestGeneration == generation else {
                    return
                }
                guard self.suggestionsWelcome, self.typedLine == fragment else {
                    self.closePalette()
                    return
                }
                let answer = try? await Bridge.suggestSSHSession(
                    id: handle, fragment: fragment, directory: directory
                )
                guard !Task.isCancelled, self.suggestGeneration == generation else { return }
                guard let answer, answer.fragment == fragment else { return }
                // A directory the host has not read yet answers with what it
                // does have, which is usually nothing. Drawing that would
                // take the palette off the screen and put it back a moment
                // later, on every keystroke, which is what "it flickers and
                // then never appears" actually is. Wait for the settled
                // answer and leave what is showing alone.
                if !answer.pending || !answer.rows.isEmpty {
                    self.show(answer.rows)
                }
                guard answer.pending else { return }
                try? await Task.sleep(for: .milliseconds(Self.suggestRetryMs))
            }
        }
    }

    /// Put a fresh set of rows on screen.
    ///
    /// The keyboard's place in the list is kept when the rows are the same
    /// ones, and dropped when they are not: a highlight that stayed on index
    /// two while the list changed underneath would insert something nobody
    /// chose.
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

    /// Where the cursor is on screen, in the terminal's own coordinates with
    /// the origin at its top-left, and how tall one line is.
    ///
    /// The cell size comes from the emulator in device pixels, so it is
    /// divided by the same scale factor SwiftTerm multiplied by. Missing
    /// either means the view is not on a screen yet, and the palette waits.
    private var cursorAnchor: (point: CGPoint, lineHeight: CGFloat)? {
        guard let terminalView else { return nil }
        let terminal = terminalView.getTerminal()
        guard let cell = terminalView.cellSizeInPixels(source: terminal) else { return nil }
        #if os(macOS)
        let scale = terminalView.window?.backingScaleFactor ?? 1
        #else
        let scale = terminalView.window?.contentScaleFactor ?? 1
        #endif
        guard scale > 0, cell.width > 0, cell.height > 0 else { return nil }
        let width = CGFloat(cell.width) / scale
        let height = CGFloat(cell.height) / scale
        let cursor = terminal.getCursorLocation()
        return (CGPoint(x: CGFloat(cursor.x) * width, y: CGFloat(cursor.y) * height), height)
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

    /// Choose a row.
    ///
    /// A saved command with placeholders in it goes through the fill-in sheet
    /// first, because the values are hostnames, ticket numbers and passwords,
    /// and none of those belong in a saved record.
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

    /// How much of the line a row stands in for, now rather than when it was
    /// offered.
    ///
    /// The rows stay up for the fraction of a second between a keystroke and
    /// the host's next answer, and in that moment they are one or two
    /// characters behind the line. A row chosen then should still finish the
    /// word: whatever was typed since is part of what it replaces. A line
    /// that has changed some other way is not one these rows can answer.
    private func replacement(for row: SSHSuggestion) -> Int? {
        guard typedLine.hasPrefix(suggestionsFragment) else { return nil }
        let since = typedLine.count - suggestionsFragment.count
        let count = row.replace + since
        return count <= typedLine.count ? count : nil
    }

    /// Type text at the prompt in place of what it stands in for.
    ///
    /// No Return. A completion is somebody's line being finished for them,
    /// not a command being run for them, and the difference is the whole
    /// reason this is safe to offer.
    func insert(_ text: String, replacing count: Int) {
        guard alive, count <= typedLine.count else { return }
        // Our own guesses come off the screen before anything is sent: the
        // far end is about to echo the deletions and then the new text, and a
        // guess left standing would be rubbed out at the wrong column.
        withdrawPredictions()
        var bytes = [UInt8](repeating: 0x7f, count: count)
        bytes.append(contentsOf: Array(text.utf8))
        typedLine = String(typedLine.dropLast(count)) + text
        closePalette()
        let handle = handle
        Task { try? await Bridge.writeSSHSession(id: handle, data: bytes) }
    }

    /// Move the keyboard's place in the list, or leave it.
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

    /// Type whichever row the keyboard is on.
    func acceptHighlighted() {
        guard let index = highlighted, index < suggestions.count else { return }
        accept(suggestions[index])
    }

    /// Put the palette away without changing the line.
    ///
    /// For this line, not for this moment: it stays away while the line only
    /// grows, and comes back when the line becomes a different one.
    func dismissSuggestions() {
        dismissedLine = typedLine
        closePalette()
    }

    /// How long the typing has to pause before the host is asked.
    ///
    /// Short. The host answers a directory it already knows in about a
    /// millisecond, so this is the whole of the delay somebody feels between
    /// a keystroke and the list.
    private static let suggestDelayMs = 60
    /// How long to wait before asking again while a listing is still coming.
    private static let suggestRetryMs = 150
    /// How many times one pause will ask. Enough to sit through a cold
    /// directory on a server across an ocean, and bounded so a server that
    /// never answers costs a fixed amount and then stops.
    private static let suggestAttempts = 8

    // MARK: - Local echo

    /// Draw a typed character before the far end has said anything about it.
    ///
    /// A key press on a server across an ocean is a round trip before the
    /// letter appears, and the wait is the whole of what makes a remote shell
    /// feel remote: the typing itself is not slow, the confirmation is. The
    /// letter is almost always going to be exactly what the shell echoes back,
    /// so it is drawn here first and the echo replaces it when it lands.
    ///
    /// Three rules keep that from ever being a lie on screen.
    ///
    /// **Nothing is drawn until the line has proved it echoes.** The first
    /// character of every line is sent and not drawn. If the far end echoes
    /// it, the rest of the line is guessed; if it does not, nothing on that
    /// line is ever guessed. That is what makes a password prompt safe: a
    /// prompt with echo turned off never confirms, so no character of a
    /// password is drawn for even one frame. Every Return starts the test
    /// again, because the next line may be the prompt.
    ///
    /// **Only plain characters, only at the end of a line, only in the normal
    /// buffer.** A guess is undone with backspaces, which can only take back
    /// what was appended and cannot cross a line wrap. Anything else, a
    /// control key, an arrow, an escape sequence, a full-screen program, stops
    /// the guessing rather than being guessed at.
    ///
    /// **Every guess is taken back before the far end's output is drawn.**
    /// See `withdrawPredictions`.
    private func predict(_ bytes: [UInt8]) {
        noteTyped(bytes)
        guard bytes.count == 1, let byte = bytes.first else {
            // A paste, a chord, or a multi-byte key. Whatever comes back is
            // not going to be a letter appearing at the cursor.
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
                predicted.append(byte)
                view.feed(byteArray: ArraySlice([byte]))
            } else if !lineSilent {
                // Sent, not drawn. These are the characters that find out
                // whether the line echoes at all.
                probing.append(byte)
                if probing.count >= Self.probeLimit {
                    // Six characters in with nothing echoed back. This is a
                    // prompt that does not echo, and the rest of the line is
                    // never guessed at.
                    lineSilent = true
                    probing.removeAll()
                }
            }
        case 0x7f, 0x08:
            if predicted.isEmpty || predictionsDetachedFromCursor {
                // Nothing of ours left to take back, and the far end is about
                // to erase something we never drew.
                endPredictionLine()
            } else {
                predicted.removeLast()
                view.feed(byteArray: ArraySlice(Self.eraseCell))
            }
            if !probing.isEmpty { probing.removeLast() }
        default:
            // Return, tab, an arrow, Ctrl-anything. The guesses already on
            // screen stay until the answer arrives: taking them back now
            // would blank the line for a whole round trip, which is the
            // flicker this feature exists to remove. But the cursor has moved
            // somewhere only the far end knows, so the guesses are marked as
            // beyond reach rather than left where backspaces could erase the
            // wrong cells.
            endPredictionLine()
            predictionsDetachedFromCursor = true
        }
    }

    /// Settle the guesses against what the far end actually sent, and answer
    /// with the part of that output still to be drawn.
    ///
    /// The echo of a guess is not something to draw. It is the same character
    /// in the same cell, so a chunk that begins with exactly what was guessed
    /// confirms those guesses and is not fed to the emulator at all: the
    /// characters are already there, the cursor is already past them, and the
    /// guesses that follow stay where they are.
    ///
    /// This is what typing at speed needs. Taking every guess back on every
    /// chunk was correct and looked wrong: five characters typed in the time
    /// one round trip takes were rubbed out the moment the echo of the first
    /// two arrived, and put back a chunk at a time as the rest caught up. No
    /// character was lost, but the tail of the word collapsed and regrew while
    /// somebody was still typing it. Only the guesses this chunk does not
    /// account for are rubbed out now.
    ///
    /// Anything after the confirmed run is the far end saying something else,
    /// and everything still guessed comes off before it is drawn.
    private func reconcilePredictions(with data: [UInt8]) -> ArraySlice<UInt8> {
        // The far end's output is the repaint that says where the cursor is,
        // so by the time this returns the guesses are back in reach. Left set
        // once, the flag stayed set for the rest of the session: the first
        // Return raised it and every later guess was then dropped without
        // being rubbed out, so the echo landed beside it and the line said
        // each character twice.
        defer { predictionsDetachedFromCursor = false }
        guard !predicted.isEmpty else { return ArraySlice(data) }
        if predictionsDetachedFromCursor {
            predicted.removeAll()
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
        // Every byte was the echo of a guess. Nothing to draw, and whatever
        // is still guessed is still exactly where it was put.
        if rest.isEmpty { return rest }
        eraseRemainingPredictions()
        return rest
    }

    /// Take every guess back off the screen.
    ///
    /// Backspace, space, backspace per character: the same three bytes a
    /// terminal itself uses to rub out a character, which is safe precisely
    /// because a guess is only ever made by appending at the cursor. Once the
    /// cursor has moved on, nothing is synthesized; whatever the far end sends
    /// repaints the truth instead.
    private func withdrawPredictions() {
        defer { predictionsDetachedFromCursor = false }
        guard !predicted.isEmpty else { return }
        if predictionsDetachedFromCursor {
            predicted.removeAll()
            return
        }
        eraseRemainingPredictions()
    }

    /// Rub out every guess that is still standing, in reach of the cursor.
    private func eraseRemainingPredictions() {
        guard !predicted.isEmpty else { return }
        var undo: [UInt8] = []
        undo.reserveCapacity(predicted.count * Self.eraseCell.count)
        for _ in predicted { undo.append(contentsOf: Self.eraseCell) }
        predicted.removeAll()
        view.feed(byteArray: ArraySlice(undo))
    }

    /// Stop tracking guesses without touching the screen, for the cases where
    /// a repaint from the far end is the correction.
    private func forgetPredictions() {
        predicted.removeAll()
        predictionsDetachedFromCursor = false
        probing.removeAll()
        recentOutput.removeAll()
        lineEchoes = false
        lineSilent = false
    }

    /// This line is no longer one that can be guessed at. Anything already
    /// drawn stays until the next output withdraws it.
    private func endPredictionLine() {
        probing.removeAll()
        recentOutput.removeAll()
        lineEchoes = false
        lineSilent = false
    }

    /// Learn from the far end whether this line echoes.
    ///
    /// The test is deliberately literal: the characters that were sent and not
    /// drawn have to come back, next to each other, in the order they were
    /// typed. A prompt that echoes stars, or nothing at all, fails it and
    /// stays unguessed for the rest of the line.
    ///
    /// Two characters, not one, and matched against a running tail of output
    /// rather than against one chunk. One character is not evidence: a shell
    /// echoes a letter at a time, so a single letter appearing anywhere in a
    /// clock ticking beside a password prompt would have been enough to
    /// convince this, and the next character of the password would have been
    /// drawn on screen. Two adjacent characters arriving in the order they
    /// were typed is not something unrelated output produces by accident.
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

    /// Whether the cursor is somewhere a guess can be appended and taken back.
    private var canPredict: Bool {
        guard let terminal = terminalView?.getTerminal() else { return false }
        // A full-screen program owns every cell on the screen, and a letter
        // typed into one is as likely to be a command as a character.
        guard !terminal.isCurrentBufferAlternate else { return false }
        // One column of headroom, so a guess can never be the character that
        // wraps the line: a backspace at column zero does not go back up.
        return terminal.getCursorLocation().x + 2 < terminal.cols
    }

    #if os(macOS)
    /// The palette's four keys, taken only while it has something to offer.
    ///
    /// The rule that keeps this out of the way is that the palette has no
    /// place in the list until somebody puts it there. Up is the shell's
    /// history until then, Tab is the shell's own completion, and Return runs
    /// the line. One press of Down steps into the palette, and from that
    /// point the four keys are its own until Escape, an insertion, or the
    /// next thing typed.
    private func claimForPalette(_ event: NSEvent) -> Bool {
        guard !suggestions.isEmpty else { return false }
        // A chord is somebody reaching for the shell or the app, not for a
        // row. Caps lock is left in because it says nothing about intent.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isSubset(of: [.function, .numericPad, .capsLock]) else { return false }
        switch event.keyCode {
        case Self.keyDown:
            step(1)
            return true
        case Self.keyUp:
            // Above the first row is the shell's history again, so the first
            // Up on an unstepped palette is not ours to take.
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

    // Virtual key codes, which are the same whatever the keyboard layout is.
    private static let keyReturn: UInt16 = 36
    private static let keyTab: UInt16 = 48
    private static let keyEscape: UInt16 = 53
    private static let keyEnter: UInt16 = 76
    private static let keyUp: UInt16 = 126
    private static let keyDown: UInt16 = 125
    #endif

    /// Rub out the cell to the left of the cursor.
    private static let eraseCell: [UInt8] = [0x08, 0x20, 0x08]

    /// How many characters are typed into an unproven line before the guessing
    /// gives up on it. Small: a line that has echoed nothing by the sixth
    /// character is a prompt that never will.
    private static let probeLimit = 6

    /// How much of the far end's recent output the echo test looks back over.
    /// Enough to span a few characters echoed one at a time with the escape
    /// sequences a colouring shell puts between them, and no more.
    private static let echoWindow = 256

    /// Whether a drag scrolls the buffer rather than reaching the program.
    ///
    /// A full-screen program on the far end holds mouse reporting on, which
    /// turns a drag into an event for it and pins the view to the bottom.
    /// Reading back through the last screenful is half of what a phone does
    /// with a terminal, so it has to be possible to turn off.
    var scrolls: Bool = false {
        didSet {
            #if !os(macOS)
            guard scrolls != oldValue else { return }
            terminalView?.allowMouseReporting = !scrolls
            #endif
        }
    }

    /// Put the keyboard away, or bring it back, without ending the session.
    func toggleKeyboard() {
        #if !os(macOS)
        guard let view = terminalView else { return }
        if view.isFirstResponder {
            _ = view.resignFirstResponder()
        } else {
            _ = view.becomeFirstResponder()
        }
        #endif
    }

    /// Type raw bytes, for the key bar above the keyboard. The same path
    /// typing takes, so a tapped key and a typed one cannot arrive out of
    /// order.
    func sendBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let handle = handle
        // Through the same guess as typing, so a tapped `esc` ends a line's
        // local echo exactly as a typed one does.
        predict(bytes)
        Task { try? await Bridge.writeSSHSession(id: handle, data: bytes) }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        forgetPredictions()
        forgetLine()
        let handle = handle
        Task { await Bridge.closeSSHSession(id: handle) }
    }

    /// Stop reading, without touching the shell on the far end.
    ///
    /// For a terminal that turned out to be a second object for a session that
    /// already had one. `stop()` would close the session on the host, which is
    /// the opposite of what a duplicate wants: the shell is real and the other
    /// object is still showing it. This only lets go of the read loop, so the
    /// same bytes stop being fed into a second emulator.
    func detachPoll() {
        pollTask?.cancel()
        pollTask = nil
        closePalette()
    }

    /// Keep the terminal and its scrollback, but stop treating it as live.
    ///
    /// `ssh.session.list` reaps a session once its command has exited. The
    /// bookkeeping poll can therefore learn that a session ended before this
    /// terminal's read poll sees the final `closed` response. That is not a
    /// request to discard the tab: its last screenful is often the result the
    /// person came back to read.
    func markClosed(error: String? = nil) {
        pollTask?.cancel()
        pollTask = nil
        forgetPredictions()
        forgetLine()
        closed = true
        if let error { self.error = error }
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        // `id`, not `handle`: they are the same string, and this one is a
        // stored `let` a nonisolated method may read.
        let handle = id
        Task { @MainActor [weak self] in
            self?.predict(bytes)
            try? await Bridge.writeSSHSession(id: handle, data: bytes)
        }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        let handle = id
        Task { @MainActor [weak self] in
            // Dropped rather than withdrawn. A resize reflows the line and
            // then the far end repaints it, so the backspaces that would undo
            // a guess no longer land where the guess was drawn. Letting the
            // repaint be the correction is the only safe answer. The palette
            // goes with them: it was placed against a cursor that has moved.
            self?.forgetPredictions()
            self?.forgetLine()
            try? await Bridge.resizeSSHSession(id: handle, rows: newRows, cols: newCols)
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    /// The server saying where the session now is, via OSC 7.
    ///
    /// The one honest source for completing a relative path: the exec channel
    /// a listing runs on starts in the home directory, not in the shell's, so
    /// without this a relative word could only be completed against the wrong
    /// place. Servers that do not emit it get absolute and `~` paths and
    /// nothing else, which is the quiet answer rather than the wrong one.
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        let path = SSHLiveTerminal.directoryPath(fromOSC7: directory)
        Task { @MainActor [weak self] in self?.remoteDirectory = path }
    }

    /// The path out of a `file://host/path` the far end sent, or nothing.
    ///
    /// Anything that is not a plain absolute path is dropped. This string
    /// comes from the server and is only ever used as the argument to a
    /// quoted `ls`, but a value that is not a path is not one worth carrying
    /// that far.
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
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        Task { @MainActor in
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #else
            UIPasteboard.general.string = text
            #endif
        }
    }
}

#if os(macOS)
private struct SSHNativeTerminal: NSViewRepresentable {
    let session: SSHLiveTerminal
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> TerminalView { session.view }
    func updateNSView(_ view: TerminalView, context: Context) {
        session.applyColors(dark: colorScheme == .dark)
    }
}
#else
private struct SSHNativeTerminal: UIViewRepresentable {
    let session: SSHLiveTerminal
    @Environment(\.colorScheme) private var colorScheme
    func makeUIView(context: Context) -> TerminalView {
        DispatchQueue.main.async { _ = session.view.becomeFirstResponder() }
        return session.view
    }
    func updateUIView(_ view: TerminalView, context: Context) {
        session.applyColors(dark: colorScheme == .dark)
    }
}
#endif

/// One SSH session, full screen, with every other session on the same server
/// a tab away.
///
/// Leaving does not end it. The shell belongs to the host process, and this
/// screen used to stop it on `onDisappear`, which meant backing out to check
/// an address killed whatever was running. Ending one is now something you
/// ask for.
struct SSHLiveTerminalScreen: View {
    @Environment(\.dismiss) private var dismiss
    /// Which session is in front. The screen shows one of the model's, so a
    /// tab is a change of selection rather than a new screen.
    @Bindable var sessions: SSHSessionsModel
    let session: SSHLiveTerminal
    /// Saved snippets, so the bar can offer them. Nil where the screen was
    /// opened without a library beside it.
    var library: SSHLibraryModel?
    /// Open another shell on the same server.
    var onNewSession: (() -> Void)?

    @State private var asking: SSHSnippet?
    @State private var confirmingClose = false

    /// Every session on this session's server, which is what the strip shows.
    private var siblings: [SSHLiveTerminal] {
        guard let hostID = session.hostID else { return [session] }
        return sessions.sessions(for: hostID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.title).font(Theme.headline)
                if !session.alive {
                    Text("ended").font(Theme.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("End session", .disconnect) { confirmingClose = true }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                // "Done" leaves it running, which is why it is not "Close".
                Button("Done", .done) { dismiss() }
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
            // The same bar the agent terminals have. A phone keyboard has no
            // Esc, no Ctrl, no arrows and no back-tab, and an SSH session
            // needs every one of them as much as an agent session does. The
            // snippets key is the part that is specific to this screen.
            ClientTerminalKeys(
                send: { session.sendBytes($0) },
                toggleKeyboard: { session.toggleKeyboard() },
                scrolls: Binding(
                    get: { session.scrolls },
                    set: { session.scrolls = $0 }
                ),
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

        .confirmationDialog("End this session?", isPresented: $confirmingClose, titleVisibility: .visible) {
            Button("End session", role: .destructive) {
                let doomed = session
                dismiss()
                Task { await sessions.close(doomed) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Whatever is running in it stops. Nothing else on the server changes.")
        }
    }

    /// The other shells on this server, as a strip.
    ///
    /// A phone has no room for a split, so tabs are the whole of it. Same
    /// idea as the Mac's pane: switching is a selection, and a session that
    /// has ended keeps its tab because its last screenful is usually why
    /// somebody is looking.
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
                    .buttonStyle(.plain)
                }
                if let onNewSession {
                    Button("New session", .create, action: onNewSession)
                        .buttonStyle(SecondaryButtonStyle(small: true))
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.bottom, Theme.Space.xs)
        }
        .scrollIndicators(.hidden)
    }

    /// Saved commands, as one key. Nil when there is nothing to offer, because
    /// a menu that opens on an empty list is a key that does nothing.
    #if !os(macOS)
    private var snippetKey: AnyView? {
        guard let library, !library.snippets.isEmpty else { return nil }
        return AnyView(
            Menu {
                ForEach(library.snippets) { snippet in
                    Button(snippet.title, .run) { run(snippet) }
                }
            } label: {
                Image(systemName: "text.append")
                    .font(Theme.font(13, weight: .medium))
                    .frame(minWidth: 34, minHeight: 30)
            }
            .accessibilityLabel("Snippets")
        )
    }
    #endif

    /// Run a snippet, or ask for its placeholders first.
    ///
    /// A snippet with placeholders goes through the sheet, where the filled
    /// command is on screen before it is sent. Everything else runs on the
    /// press: a snippet is a command somebody saved in order to run it.
    private func run(_ snippet: SSHSnippet) {
        if SSHSnippet.placeholders(in: snippet.command).isEmpty {
            session.sendBytes(SSHSnippet.bytesToRun(snippet.command))
        } else {
            asking = snippet
        }
    }
}

/// Fill in a snippet's placeholders before it is typed into the terminal.
///
/// Values are asked for every time and never stored. The useful ones are
/// hostnames, ticket numbers and passwords, and the last of those is the
/// reason this does not remember anything.
struct SSHSnippetRunSheet: View {
    @Environment(\.dismiss) private var dismiss
    let snippet: SSHSnippet
    /// What the button says, because the same sheet fills in a command that
    /// is about to run and one that is only being typed at the prompt.
    var action: String = "Run it"
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
            subtitle: "Values are asked for every time and never saved.",
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
            Button("Cancel", .dismiss) { dismiss() }
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
    /// Whether `other` appears in this array, in order and unbroken.
    ///
    /// Used on a short tail of terminal output against a handful of typed
    /// characters, so the obvious search is the right one.
    func contains(sequence other: [UInt8]) -> Bool {
        guard !other.isEmpty, count >= other.count else { return false }
        for start in 0...(count - other.count) {
            if self[start..<(start + other.count)].elementsEqual(other) { return true }
        }
        return false
    }
}
