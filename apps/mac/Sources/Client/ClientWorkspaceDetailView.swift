// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI
import UIKit
import WebKit

/// One remote folder on a connected host: sessions, launch, files, ports.
struct ClientWorkspaceDetailView: View {
    let peer: String
    let hostName: String
    let folder: WorkspaceFolder

    @State private var sessions: [PtySessionInfo] = []
    @State private var catalog: [RemoteLaunchProfile] = []
    @State private var openSession: ClientTerminalSession?
    @State private var errorMessage: String?
    @State private var isLaunching = false
    @State private var showFiles = false
    @State private var showPort = false
    @State private var portText = "5173"
    @State private var browserURL: String?
    @State private var forwardedPort: Int?
    @State private var isLoading = false

    private var workspaceID: String {
        ClientRemote.rawWorkspaceID(of: folder) ?? folder.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await reload() }
                    }
                }

                headerCard
                launchCard
                sessionsCard
                toolsCard
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await ClientRefresh.pull("workspace-\(workspaceID)") { await reload() }
        }
        .task { await reload() }
        .fullScreenCover(item: $openSession) { session in
            ClientTerminalScreen(session: session)
        }
        .sheet(isPresented: $showFiles) {
            NavigationStack {
                ClientFilesView(peer: peer, workspace: workspaceID, folderName: folder.name)
            }
        }
        .sheet(isPresented: $showPort) {
            portSheet
        }
        .fullScreenCover(item: Binding(
            get: { browserURL.map { BrowserURL(url: $0) } },
            set: { browserURL = $0?.url }
        )) { item in
            ClientBrowserScreen(url: item.url) {
                browserURL = nil
                if let port = forwardedPort {
                    forwardedPort = nil
                    Task { await Bridge.proxyUnlisten(peer: peer, host: "127.0.0.1", port: port) }
                }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(hostName)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
            Text(folder.path)
                .font(ClientType.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            if let subtitle = folder.subtitle {
                Text(subtitle)
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var launchCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Start")
                .font(ClientType.sectionTitle)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.s) {
                    if catalog.isEmpty {
                        // Keep the surface useful while the owning host's
                        // catalog is loading. Once it arrives, it supplies the
                        // host's actual shell and the Shell tile is not added a
                        // second time here.
                        launchChip(RemoteLaunchProfile(
                            id: "shell",
                            name: "Shell",
                            command: "/bin/zsh",
                            args: ["-l"],
                            bypassArgs: [],
                            harnessId: nil,
                            symbol: "terminal",
                            openUrl: nil
                        ))
                    } else {
                        ForEach(catalog, id: \.id) { profile in
                            launchChip(profile)
                        }
                    }
                }
            }
        }
    }

    private func launchChip(_ profile: RemoteLaunchProfile) -> some View {
        Button {
            Task { await launch(profile) }
        } label: {
            Text(profile.name)
                .font(ClientType.caption.weight(.semibold))
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.accent.opacity(0.15))
                .foregroundStyle(Theme.accent)
                .clipShape(Capsule())
        }
        .disabled(isLaunching)
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Sessions")
                .font(ClientType.sectionTitle)
            if sessions.isEmpty {
                Text("No sessions in this folder yet. Start one above.")
                    .font(ClientType.body)
                    .foregroundStyle(.secondary)
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
            } else {
                ForEach(sessions) { session in
                    Button {
                        openExisting(session)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: session.command).lastPathComponent)
                                    .font(ClientType.label.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(session.alive ? "Running · tap to open" : "Stopped · tap to open")
                                    .font(ClientType.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "terminal")
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardSurface()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var toolsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Tools")
                .font(ClientType.sectionTitle)
            Button {
                showFiles = true
            } label: {
                toolRow(symbol: "folder", title: "Files", subtitle: "Browse and edit on the host")
            }
            .buttonStyle(.plain)

            Button {
                showPort = true
            } label: {
                toolRow(symbol: "globe", title: "Browse a port", subtitle: "Local service on the host via tunnel")
            }
            .buttonStyle(.plain)
        }
    }

    private func toolRow(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ClientType.label.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(ClientType.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Space.m)
        .cardSurface()
    }

    private var portSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Opens a loopback bridge to that port on \(hostName) and shows it in the in-app browser.")
                }
            }
            .navigationTitle("Browse port")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPort = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        Task { await openPort() }
                    }
                    .disabled(isLoading || UInt16(portText) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func reload() async {
        errorMessage = nil
        do {
            let all = try await ClientRemote.ptyList(peer: peer)
            sessions = all.filter { session in
                if let ws = session.workspaceID, !ws.isEmpty {
                    return ws == workspaceID
                }
                // Fall back to cwd match when the host did not tag workspace.
                return session.cwd == folder.path || session.cwd.hasPrefix(folder.path + "/")
            }
            if catalog.isEmpty {
                catalog = (try? await ClientRemote.launcherCatalog(peer: peer)) ?? []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openExisting(_ info: PtySessionInfo) {
        openSession = ClientTerminalSession(peer: peer, info: info)
    }

    private func launch(_ profile: RemoteLaunchProfile) async {
        isLaunching = true
        defer { isLaunching = false }
        errorMessage = nil
        let dark = UITraitCollection.current.userInterfaceStyle == .dark
        let pending = ClientTerminalSession(
            peer: peer,
            pendingCommand: profile.command,
            cwd: folder.path,
            rows: 40,
            cols: 100
        )
        openSession = pending
        do {
            let info = try await ClientRemote.ptySpawn(
                peer: peer,
                workspaceID: workspaceID,
                command: profile.command,
                args: profile.args,
                rows: 40,
                cols: 100,
                dark: dark
            )
            pending.attach(info: info)
            await reload()
        } catch {
            pending.stop()
            openSession = nil
            errorMessage = error.localizedDescription
            return
        }
        // The process is already up. A failed port forward must not kill it.
        guard let page = profile.openUrl, let port = URL(string: page)?.port else { return }
        do {
            try? await Task.sleep(for: .seconds(2))
            let result = try await Bridge.proxyListen(
                peer: peer,
                host: "127.0.0.1",
                port: port
            )
            forwardedPort = port
            if let proxy = URL(string: result.url) {
                _ = await Self.waitForPage(proxy)
            }
            openSession = nil
            browserURL = result.url
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// True when the harness answered. The local proxy writes 502 while the
    /// peer port is still closed, so that status is "not yet", not ready.
    private static func waitForPage(_ url: URL, timeout: TimeInterval = 40) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            request.httpMethod = "GET"
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse,
               http.statusCode != 502 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    private func openPort() async {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespaces)) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await Bridge.proxyListen(peer: peer, host: "127.0.0.1", port: Int(port))
            showPort = false
            forwardedPort = Int(port)
            browserURL = result.url
        } catch {
            errorMessage = error.localizedDescription
            showPort = false
        }
    }
}

private struct BrowserURL: Identifiable {
    var id: String { url }
    var url: String
}

// MARK: - Files

struct ClientFilesView: View {
    let peer: String
    let workspace: String
    let folderName: String

    @Environment(\.dismiss) private var dismiss
    @State private var pathStack: [String] = [""]
    @State private var children: [TreeEntry] = []
    @State private var errorMessage: String?
    @State private var openFile: OpenFile?

    private var currentPath: String { pathStack.last ?? "" }

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Theme.danger)
            }
            ForEach(children) { entry in
                Button {
                    Task { await open(entry) }
                } label: {
                    HStack {
                        Image(systemName: entry.isDir ? "folder.fill" : "doc.text")
                            .foregroundStyle(entry.isDir ? Theme.accent : .secondary)
                        Text(entry.name)
                            .foregroundStyle(entry.ignored ? .secondary : .primary)
                        Spacer()
                        if entry.isDir {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle(currentPath.isEmpty ? folderName : (currentPath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .topBarLeading) {
                if pathStack.count > 1 {
                    Button("Up") {
                        pathStack.removeLast()
                        Task { await load() }
                    }
                }
            }
        }
        .task(id: currentPath) { await load() }
        .sheet(item: $openFile) { file in
            ClientFileEditor(peer: peer, workspace: workspace, path: file.path, content: file.content)
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            children = try await ClientRemote.tree(peer: peer, workspace: workspace, path: currentPath)
        } catch {
            errorMessage = error.localizedDescription
            children = []
        }
    }

    private func open(_ entry: TreeEntry) async {
        if entry.isDir {
            pathStack.append(entry.path)
            return
        }
        do {
            let file = try await ClientRemote.readFile(peer: peer, workspace: workspace, path: entry.path)
            openFile = OpenFile(path: entry.path, content: file.content)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct OpenFile: Identifiable {
    var id: String { path }
    var path: String
    var content: String
}

struct ClientFileEditor: View {
    let peer: String
    let workspace: String
    let path: String
    @State var content: String
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var original: String = ""
    @State private var confirmClose = false

    var body: some View {
        NavigationStack {
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .padding(Theme.Space.s)
                .navigationTitle((path as NSString).lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            if content != original {
                                confirmClose = true
                            } else {
                                dismiss()
                            }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? "Saving…" : "Save") {
                            Task { await save() }
                        }
                        .disabled(isSaving || content == original)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(ClientType.caption)
                            .foregroundStyle(Theme.danger)
                            .padding()
                    }
                }
        }
        .onAppear { original = content }
        .confirmationDialog(
            "Discard changes?",
            isPresented: $confirmClose,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This file has edits that are not saved on the host.")
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await ClientRemote.writeFile(
                peer: peer,
                workspace: workspace,
                path: path,
                content: content
            )
            original = content
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Browser

struct ClientBrowserScreen: View {
    let url: String
    var onClose: () -> Void
    @State private var address: String
    @State private var loadError: String?

    init(url: String, onClose: @escaping () -> Void) {
        self.url = url
        self.onClose = onClose
        _address = State(initialValue: url)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("URL", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(ClientType.caption)
                    .padding(Theme.Space.s)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button("Reload") {
                    loadError = nil
                    // Force WebView identity change via address nudge is
                    // unnecessary; ClientWebView reloads when urlString matches.
                    let current = address
                    address = ""
                    DispatchQueue.main.async { address = current }
                }
                .font(ClientType.caption.weight(.semibold))
                Button("Done", action: onClose)
                    .font(ClientType.caption.weight(.semibold))
            }
            .padding(Theme.Space.m)
            if let loadError {
                Text(loadError)
                    .font(ClientType.caption)
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.m)
            }
            ClientWebView(urlString: address, onError: { loadError = $0 })
        }
        .background(Theme.background)
    }
}

struct ClientWebView: UIViewRepresentable {
    let urlString: String
    var onError: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        if let url = URL(string: urlString) {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onError = onError
        if let url = URL(string: urlString),
           uiView.url?.absoluteString != urlString,
           !urlString.isEmpty
        {
            uiView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onError: (String) -> Void

        init(onError: @escaping (String) -> Void) {
            self.onError = onError
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(Self.allows(navigationAction.request.url) ? .allow : .cancel)
        }

        static func allows(_ url: URL?) -> Bool {
            guard let url, let scheme = url.scheme?.lowercased() else { return false }
            if scheme == "about" { return true }
            if let host = url.host, host == "127.0.0.1" || host == "localhost" {
                return scheme == "http" || scheme == "https"
            }
            return scheme == "https" && (url.host == "tokenstat.ai" || url.host?.hasSuffix(".tokenstat.ai") == true)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            onError(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            onError(error.localizedDescription)
        }
    }
}

#endif
