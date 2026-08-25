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
        made.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        #else
        let made = TerminalView(frame: .zero)
        made.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        made.inputAccessoryView = nil
        #endif
        made.optionAsMetaKey = true
        made.getTerminal().changeHistorySize(4_000)
        made.terminalDelegate = self
        terminalView = made
        return made
    }

    private func poll() async {
        while !Task.isCancelled && !closed {
            do {
                let chunk = try await Bridge.readSSHSession(id: handle, offset: offset)
                if chunk.dropped { view.feed(text: "\r\n[tokenstat: older output was dropped]\r\n") }
                if !chunk.data.isEmpty {
                    offset = chunk.nextOffset
                    view.feed(byteArray: ArraySlice(chunk.data))
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
        Task { try? await Bridge.writeSSHSession(id: handle, data: bytes) }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        let handle = handle
        Task { await Bridge.closeSSHSession(id: handle) }
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
        closed = true
        if let error { self.error = error }
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        Task { try? await Bridge.writeSSHSession(id: handle, data: bytes) }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        Task { try? await Bridge.resizeSSHSession(id: handle, rows: newRows, cols: newCols) }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
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
    func makeNSView(context: Context) -> TerminalView { session.view }
    func updateNSView(_ view: TerminalView, context: Context) {}
}
#else
private struct SSHNativeTerminal: UIViewRepresentable {
    let session: SSHLiveTerminal
    func makeUIView(context: Context) -> TerminalView {
        DispatchQueue.main.async { _ = session.view.becomeFirstResponder() }
        return session.view
    }
    func updateUIView(_ view: TerminalView, context: Context) {}
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
                Text(session.title).font(.headline)
                if !session.alive {
                    Text("ended").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("End session", .disconnect) { confirmingClose = true }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                // "Done" leaves it running, which is why it is not "Close".
                Button("Done", .done) { dismiss() }
            }
            .padding(Theme.Space.s)
            if siblings.count > 1 { tabs }
            Divider()
            SSHNativeTerminal(session: session)
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
        .background(Color.black)
        .sheet(item: $asking) { snippet in
            SSHSnippetRunSheet(snippet: snippet) { command in
                session.sendBytes(Array(command.utf8))
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
                                .font(.caption)
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
                    Button(snippet.title, .apply) { run(snippet) }
                }
            } label: {
                Image(systemName: "text.append")
                    .font(.system(size: 13, weight: .medium))
                    .frame(minWidth: 34, minHeight: 30)
            }
            .accessibilityLabel("Snippets")
        )
    }
    #endif

    /// Send a snippet, or ask for its placeholders first.
    ///
    /// A snippet is typed rather than run: the line lands at the prompt with
    /// no trailing Return, so what is about to happen can be read before it
    /// happens. Somebody's saved command is not something to fire off because
    /// a thumb landed on the wrong row of a menu.
    private func run(_ snippet: SSHSnippet) {
        if SSHSnippet.placeholders(in: snippet.command).isEmpty {
            session.sendBytes(Array(snippet.command.utf8))
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
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.title).font(.title3.weight(.semibold))
                    Text("Values are asked for every time and never saved.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                InspectorCloseButton(action: { dismiss() }, help: "Close", label: "Close snippet")
            }
            Divider()
            ForEach(names, id: \.self) { name in
                SSHEditorField(label: name) {
                    TextField(name, text: Binding(
                        get: { values[name] ?? "" },
                        set: { values[name] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
            Text(filled)
                .font(Theme.mono(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                Button("Cancel", .dismiss) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(minWidth: Theme.Control.pairedWidth)
                Spacer()
                Button("Type it", .send) {
                    onFilled(filled)
                    dismiss()
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(!ready)
            }
        }
        .padding(Theme.Space.l)
        .sshSheetFrame(width: 480, height: 420)
    }
}
