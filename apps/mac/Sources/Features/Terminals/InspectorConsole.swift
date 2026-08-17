// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if os(macOS)
import SwiftUI

/// Bottom split of the workspace inspector: follow the focused session, or
/// a tiny login shell.
///
/// Follow is text, on purpose. The main `TerminalStack` already owns that
/// session's emulator, and a second parent would resize the pty.
struct InspectorConsole: View {
    let folder: WorkspaceFolder
    @Bindable var terminals: TerminalsModel

    @State private var followText = ""
    @State private var shellClaimsFocus = false
    @State private var consoleSize: CGSize = .zero

    private var mode: InspectorConsoleMode {
        terminals.inspectorConsoleMode(for: folder.id)
    }

    private var followed: TerminalSession? {
        terminals.active(in: folder.id)
    }

    private var shell: TerminalSession? {
        terminals.sessions(in: folder.id, includeInspector: true)
            .first(where: \.isInspectorShell)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            switch mode {
            case .follow:
                followPane
            case .shell:
                shellPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onDisappear { terminals.focusConsole([]) }
        .task(id: followTaskID) { await pumpFollow() }
        .task(id: shellTaskID) { await ensureShell() }
    }

    private var followTaskID: String {
        "\(folder.id)|\(mode.rawValue)|\(followed?.id ?? "")"
    }

    private var shellTaskID: String {
        let grid = TerminalMetrics.grid(fitting: consoleSize)
        return "\(folder.id)|\(mode.rawValue)|\(grid.rows)x\(grid.cols)"
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            SegmentedCapsulePicker(
                options: [
                    (InspectorConsoleMode.follow, "Follow", "eye"),
                    (InspectorConsoleMode.shell, "Shell", "terminal"),
                ],
                selection: modeBinding
            )
            Text(statusTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 5)
        .background(Theme.sidebar)
    }

    private var modeBinding: Binding<InspectorConsoleMode> {
        Binding(
            get: { terminals.inspectorConsoleMode(for: folder.id) },
            set: { terminals.setInspectorConsoleMode($0, for: folder.id) }
        )
    }

    private var statusTitle: String {
        switch mode {
        case .follow:
            if let followed {
                if let title = followed.title, !title.isEmpty { return title }
                return followed.command
            }
            return "No session"
        case .shell:
            return "This folder"
        }
    }

    private var followPane: some View {
        Group {
            if followed == nil {
                Text("Open a session to follow it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if followText.isEmpty {
                Text("Waiting for output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(followText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.s)
                            .id("tail")
                    }
                    .onChange(of: followText) {
                        proxy.scrollTo("tail", anchor: .bottom)
                    }
                }
            }
        }
        .onAppear { terminals.focusConsole([]) }
    }

    private var shellPane: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if let shell, shell.terminalViewIfLoaded != nil {
                    TerminalStack(
                        sessions: [shell],
                        leading: shell,
                        trailing: nil,
                        focused: shellClaimsFocus ? shell : nil,
                        splitAxis: nil,
                        fraction: 1,
                        claimsFocus: shellClaimsFocus,
                        onActivate: { _ in shellClaimsFocus = true }
                    )
                    .frame(width: size.width, height: size.height)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: size.width, height: size.height)
                }
            }
            .onAppear { consoleSize = size }
            .onChange(of: CGSize(
                width: quantised(size.width, step: 8),
                height: quantised(size.height, step: 8)
            )) { _, new in
                consoleSize = new
            }
        }
    }

    private func pumpFollow() async {
        guard mode == .follow else { return }
        while !Task.isCancelled {
            followText = followed?.followSnapshot() ?? ""
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func ensureShell() async {
        guard mode == .shell else {
            terminals.focusConsole([])
            return
        }
        guard consoleSize.width > 1, consoleSize.height > 1 else { return }
        let grid = TerminalMetrics.grid(fitting: consoleSize)
        let started = await terminals.startInspectorShell(
            workspace: folder,
            rows: grid.rows,
            cols: grid.cols
        )
        if let started {
            terminals.focusConsole([started.id])
        }
    }
}
#endif
