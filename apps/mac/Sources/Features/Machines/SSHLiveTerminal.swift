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
        }
        .background(Color.black)
        .onDisappear { session.stop() }
    }
}
