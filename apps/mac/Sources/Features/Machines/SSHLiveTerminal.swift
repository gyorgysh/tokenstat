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
final class SSHLiveTerminal: TerminalViewDelegate, Identifiable {
    let id = UUID()
    let handle: String
    let title: String
    private(set) var closed = false
    var error: String?
    @ObservationIgnored private var offset: UInt64 = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var terminalView: TerminalView?

    init(handle: SSHSessionHandle, title: String) {
        self.handle = handle.id
        self.title = title
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

struct SSHLiveTerminalScreen: View {
    @Environment(\.dismiss) private var dismiss
    let session: SSHLiveTerminal
    /// Saved snippets, so the bar can offer them. Nil where the screen was
    /// opened without a library beside it.
    var library: SSHLibraryModel?

    @State private var asking: SSHSnippet?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.title).font(.headline)
                Spacer()
                if session.closed { Text("Disconnected").foregroundStyle(.secondary) }
                Button("Done", .done) { session.stop(); dismiss() }
            }
            .padding(Theme.Space.s)
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
        .onDisappear { session.stop() }
        .sheet(item: $asking) { snippet in
            SSHSnippetRunSheet(snippet: snippet) { command in
                session.sendBytes(Array(command.utf8))
            }
        }
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
