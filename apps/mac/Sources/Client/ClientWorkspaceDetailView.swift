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

/// A folder's sessions on a connected host, and the launcher that starts one.
///
/// Pushed from `ClientWorkspaceDetailView`, which is the folder's section
/// list. Launch lives here rather than a level up because starting an agent
/// and watching one are the same job, and the Mac puts them in the same
/// surface for the same reason.
struct ClientWorkspaceSessionsView: View {
    let peer: String
    let hostName: String
    let folder: WorkspaceFolder

    @State private var sessions: [PtySessionInfo] = []
    @State private var catalog: [RemoteLaunchProfile] = []
    @State private var openSession: ClientTerminalSession?
    @State private var errorMessage: String?
    @State private var isLaunching = false
    @State private var launchingID: String?
    @State private var installingID: String?
    @State private var showingCatalog = false
    @State private var pendingInstall: RemoteLaunchProfile?
    @State private var pendingHide: RemoteLaunchProfile?
    @State private var browserURL: String?
    @State private var forwardedPort: Int?
    @State private var pendingClose: PtySessionInfo?
    /// False until the first `pty.list` and catalog answer land. An empty list
    /// and an unasked question look identical and mean opposite things.
    @State private var loaded = false
    /// How many launch tiles this host had last time, so the grid opens at the
    /// size it will end up. Without it the row painted one Shell tile and then
    /// jumped to eight when the catalog answered.
    @AppStorage("client.launchTileCount") private var rememberedTileCount = 6
    @Environment(\.scenePhase) private var scenePhase

    private var workspaceID: String {
        ClientRemote.rawWorkspaceID(of: folder) ?? folder.id
    }

    private var visibility: LauncherVisibility { LauncherVisibility.shared }
    private var visibilityScope: String { peer }

    /// Installed and still on the row. Hidden ones live under +.
    ///
    /// Host `hidden` and this device's defaults both count: a hide on the
    /// Mac lands as catalog.hidden even when this phone has never hid it.
    private var visibleCatalog: [RemoteLaunchProfile] {
        catalog.filter { $0.installed && !isOffGrid($0) }
    }

    /// Not installed, or installed and hidden.
    private var extraCatalog: [RemoteLaunchProfile] {
        catalog.filter { !$0.installed || isOffGrid($0) }
    }

    private func isOffGrid(_ profile: RemoteLaunchProfile) -> Bool {
        profile.hidden == true || visibility.isHidden(profile.id, scope: visibilityScope)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let errorMessage {
                    ClientErrorCard(message: errorMessage) {
                        Task { await reload() }
                    }
                }

                launchCard
                sessionsCard
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 96)
        }
        .background(Theme.background)
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            // Its own key. The section list this was pushed from pulls on
            // "workspace-<id>", and `ClientRefresh` throttles by key, so
            // sharing one meant a pull here right after a pull there was
            // swallowed while the spinner said otherwise.
            await ClientRefresh.pull("workspace-sessions-\(workspaceID)") { await reload() }
        }
        .task {
            // A wireframe that cannot end is worse than the spinner it
            // replaced: it promises an answer is on its way. If the host has
            // not answered in ten seconds, stop promising and show what is
            // known, which is nothing and why.
            let watchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, !loaded else { return }
                loaded = true
                if errorMessage == nil {
                    errorMessage = ClientTunnelCopy.waiting(hostName)
                }
            }
            await reload()
            watchdog.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectivityRestored)) { _ in
            Task { await recoverAfterNetworkChange() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await recoverAfterNetworkChange() }
        }
        .fullScreenCover(item: $openSession) { session in
            ClientTerminalScreen(
                session: session,
                hostName: hostName,
                onClosedProcess: { Task { await reload() } }
            )
        }
        .confirmationDialog(
            "Close this session?",
            isPresented: Binding(
                get: { pendingClose != nil },
                set: { if !$0 { pendingClose = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Close", role: .destructive) {
                if let session = pendingClose {
                    Task { await closeSession(session) }
                }
                pendingClose = nil
            }
            Button("Keep it", role: .cancel) { pendingClose = nil }
        } message: {
            Text("Stops the process on \(hostName).")
        }
        .confirmationDialog(
            pendingInstall.map { "Install \($0.name) on \(hostName)?" } ?? "Install this tool?",
            isPresented: Binding(
                get: { pendingInstall != nil },
                set: { if !$0 { pendingInstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Install") {
                if let profile = pendingInstall {
                    Task { await install(profile) }
                }
                pendingInstall = nil
            }
            Button("Not now", role: .cancel) { pendingInstall = nil }
        } message: {
            Text("This runs its official installer.")
        }
        .confirmationDialog(
            pendingHide.map { "Remove \($0.name) from the launcher?" } ?? "Remove this tool?",
            isPresented: Binding(
                get: { pendingHide != nil },
                set: { if !$0 { pendingHide = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let profile = pendingHide {
                    Task { await hideOnHost(profile) }
                }
                pendingHide = nil
            }
            Button("Keep", role: .cancel) { pendingHide = nil }
        } message: {
            Text("The tool stays on \(hostName). You can add it again from +.")
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

    private var launchCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Start")
                .font(ClientType.sectionTitle)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Theme.Space.s),
                    GridItem(.flexible(), spacing: Theme.Space.s),
                ],
                spacing: Theme.Space.s
            ) {
                if !loaded, catalog.isEmpty {
                    // Placeholders at the count this host had last time. The
                    // real tiles replace them in place, so nothing moves under
                    // a thumb already reaching for one.
                    ForEach(0..<max(2, rememberedTileCount), id: \.self) { index in
                        ClientLaunchTilePlaceholder(phase: Double(index) * 0.08)
                    }
                } else if catalog.isEmpty {
                    // The host answered and has no catalog: keep the surface
                    // useful. Once one arrives it supplies the host's actual
                    // shell, and the Shell tile is not added a second time.
                    launchTile(RemoteLaunchProfile(
                        id: "shell",
                        name: "Shell",
                        command: "/bin/zsh",
                        args: ["-l"],
                        bypassArgs: [],
                        harnessId: nil,
                        symbol: "terminal",
                        openUrl: nil,
                        installed: true,
                        hidden: false,
                        installCommand: nil
                    ))
                } else {
                    ForEach(visibleCatalog, id: \.id) { profile in
                        launchTile(profile)
                    }
                    if !extraCatalog.isEmpty {
                        ClientMoreTile(showing: showingCatalog) {
                            showingCatalog.toggle()
                        }
                    }
                    if showingCatalog {
                        ForEach(extraCatalog, id: \.id) { profile in
                            launchTile(profile)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func launchTile(_ profile: RemoteLaunchProfile) -> some View {
        if profile.installed, !isOffGrid(profile) {
            ClientLaunchTile(
                profile: profile,
                isLaunching: launchingID == profile.id,
                isBusy: isLaunching && launchingID != profile.id
            ) {
                Task { await launch(profile) }
            }
            .contextMenu {
                if profile.id != "shell" {
                    Button("Remove from launcher", .delete) { pendingHide = profile }
                }
            }
        } else if profile.installed {
            ClientLaunchTile(profile: profile, isMuted: true) {
                Task { await showAgain(profile) }
            }
        } else if profile.installCommand != nil {
            ClientLaunchTile(
                profile: profile,
                isMuted: true,
                isBusy: installingID != nil && installingID != profile.id,
                caption: installingID == profile.id ? "Installing…" : profile.name
            ) {
                pendingInstall = profile
            }
        } else {
            ClientLaunchTile(profile: profile, isMuted: true, isBusy: true) {}
        }
    }

    private func install(_ profile: RemoteLaunchProfile) async {
        guard installingID == nil else { return }
        installingID = profile.id
        defer { installingID = nil }
        do {
            let result = try await ClientRemote.launcherInstall(peer: peer, id: profile.id)
            guard result.ok else {
                let tail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                errorMessage = tail.isEmpty
                    ? "\(profile.name) could not be installed (exit \(result.exitCode ?? 1))"
                    : tail
                return
            }
            visibility.show(profile.id, scope: visibilityScope)
            catalog = (try? await ClientRemote.launcherCatalog(peer: peer)) ?? catalog
            adoptHostHidden()
            if !visibleCatalog.isEmpty { rememberedTileCount = visibleCatalog.count }
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        loaded = true
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Sessions")
                .font(ClientType.sectionTitle)
            if !loaded {
                ClientWireframe.Rows(count: 2)
            } else if sessions.isEmpty {
                ClientSectionEmpty(
                    text: "Nothing running here",
                    art: .sessions,
                    message: "Start an agent from the row above and it opens right here."
                )
            } else {
                List {
                    ForEach(sessions) { session in
                        Button {
                            openExisting(session)
                        } label: {
                            ClientSessionRow(session: session)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: Theme.Space.s, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Close", role: .destructive) {
                                pendingClose = session
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .frame(minHeight: CGFloat(sessions.count) * 78)
            }
        }
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
            catalog = (try? await ClientRemote.launcherCatalog(peer: peer)) ?? catalog
            adoptHostHidden()
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
        // Outside the catch, like every other section screen: the question has
        // been asked and answered, and a refusal is an answer. Without this the
        // wireframe only ever ended on the watchdog, which the `.task` cancels
        // the moment a *successful* load returns, so the screen that worked was
        // the one that pulsed forever.
        loaded = true
    }

    private func recoverAfterNetworkChange() async {
        openSession?.clearTransientTunnelError()
        await reload()
    }

    private func openExisting(_ info: PtySessionInfo) {
        openSession = ClientTerminalSession(peer: peer, info: info)
    }

    private func closeSession(_ info: PtySessionInfo) async {
        do {
            if openSession?.hostID == info.id {
                try await openSession?.close()
                openSession = nil
            } else {
                try await ClientRemote.ptyClose(peer: peer, id: info.id)
            }
            sessions.removeAll { $0.id == info.id }
        } catch {
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
        }
    }

    private func adoptHostHidden() {
        let hostHidden = Set(catalog.compactMap { $0.hidden == true ? $0.id : nil })
        if !hostHidden.isEmpty {
            visibility.replace(hostHidden, scope: visibilityScope)
        }
    }

    private func hideOnHost(_ profile: RemoteLaunchProfile) async {
        visibility.hide(profile.id, scope: visibilityScope)
        do {
            try await ClientRemote.launcherHide(peer: peer, id: profile.id)
        } catch {
            // Older host: the local set is the whole answer.
        }
        catalog = (try? await ClientRemote.launcherCatalog(peer: peer)) ?? catalog
        adoptHostHidden()
    }

    private func showAgain(_ profile: RemoteLaunchProfile) async {
        visibility.show(profile.id, scope: visibilityScope)
        do {
            try await ClientRemote.launcherShow(peer: peer, id: profile.id)
        } catch {
            // Older host: the local set is the whole answer.
        }
        catalog = (try? await ClientRemote.launcherCatalog(peer: peer)) ?? catalog
        adoptHostHidden()
    }

    private func launch(_ profile: RemoteLaunchProfile) async {
        guard profile.installed, !isOffGrid(profile) else { return }
        isLaunching = true
        launchingID = profile.id
        defer {
            isLaunching = false
            launchingID = nil
        }
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
            errorMessage = ClientTunnelCopy.display(error.localizedDescription, host: hostName)
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
}

struct BrowserURL: Identifiable {
    var id: String { url }
    var url: String
}

// MARK: - Files

struct ClientFilesView: View {
    let peer: String
    let workspace: String
    let folderName: String

    @State private var pathStack: [String] = [""]
    @State private var children: [TreeEntry] = []
    @State private var errorMessage: String?
    @State private var openFile: OpenFile?
    /// False until this folder has answered. An empty list and a folder nobody
    /// has read yet look identical and mean opposite things, so the empty
    /// state waits rather than calling a full folder empty for a moment.
    @State private var loaded = false

    private var currentPath: String { pathStack.last ?? "" }

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Theme.danger)
            }
            if loaded, children.isEmpty, errorMessage == nil {
                ClientSectionEmpty(
                    text: "Nothing in this folder",
                    art: .files,
                    message: "Files an agent writes here show up as it works."
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
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
            ToolbarItem(placement: .topBarLeading) {
                if pathStack.count > 1 {
                    Button("Up") {
                        pathStack.removeLast()
                        Task { await load() }
                    }
                }
            }
        }
        .task(id: currentPath) {
            loaded = false
            await load()
        }
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
        loaded = true
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

/// One file from the host, open for editing.
///
/// Backed by the same `EditorDocument` the Mac editor uses, so the phone gets
/// the same colours from the same parse. `highlight` is a sessionless host
/// method over the buffer rather than the path, so it answers in this process
/// without asking the machine that owns the file.
struct ClientFileEditor: View {
    let peer: String
    let workspace: String
    let path: String

    @State private var document: EditorDocument
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmClose = false

    @MainActor
    init(peer: String, workspace: String, path: String, content: String) {
        self.peer = peer
        self.workspace = workspace
        self.path = path
        _document = State(
            initialValue: EditorDocument(workspaceID: workspace, path: path, content: content)
        )
    }

    var body: some View {
        NavigationStack {
            IOSCodeTextView(document: document)
                .background(Theme.background)
                .navigationTitle((path as NSString).lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            if document.isDirty {
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
                        .disabled(isSaving || !document.isDirty)
                    }
                }
                .safeAreaInset(edge: .bottom) { status }
        }
        // The first parse, before anybody types. Colour is not worth blocking
        // the sheet on, so the text is up either way.
        .task { await document.highlightNow() }
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

    /// The line under the buffer. A failed save is the loud case; a file with
    /// no grammar is the quiet one, and saying so beats leaving somebody to
    /// wonder why their config is grey.
    @ViewBuilder
    private var status: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(ClientType.caption)
                .foregroundStyle(Theme.danger)
                .padding()
        } else if let note = document.highlightNote {
            Text(note)
                .font(ClientType.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
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
                content: document.text
            )
            document.markSaved()
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
                Button("Reload", .refresh) {
                    loadError = nil
                    // Force WebView identity change via address nudge is
                    // unnecessary; ClientWebView reloads when urlString matches.
                    let current = address
                    address = ""
                    DispatchQueue.main.async { address = current }
                }
                .font(ClientType.caption.weight(.semibold))
                Button("Done", .done, action: onClose)
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
