// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Separate native app using the shipping model, views and in-process bridge.
import SwiftUI
import Vision
import CoreML
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private struct Fixture: Decodable {
    let root, workspaceId, conversationId, hostKey: String
}

@MainActor @Observable private final class HistorySession {
    let model = ChatModel()
    var showing = true
    var overview = false
    var phase = "Encrypted history QA"
    var layoutPage: String?
    var layoutScheme: ColorScheme = .dark
    var layoutType: DynamicTypeSize = .large
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var command = 0
    @ObservationIgnored private var blankSamples = 0
    @ObservationIgnored private var errors: [[String: String]] = []
    @ObservationIgnored private var previousState = Data()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    let fixture: Fixture
    let role: String
    let output: URL

    init() {
        let environment = ProcessInfo.processInfo.environment
        fixture = try! JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: URL(fileURLWithPath: environment["TOKENSTAT_NATIVE_HISTORY_FIXTURE"]!)))
        role = environment["TOKENSTAT_NATIVE_HISTORY_ROLE"]!
        output = URL(fileURLWithPath: fixture.root).appendingPathComponent(role)
        try? save(["pid": ProcessInfo.processInfo.processIdentifier], "process.json")
    }

    private func save(_ value: Any, _ name: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
            .write(to: output.appendingPathComponent(name), options: .atomic)
    }

    private func noteState() {
        if model.selected?.id == fixture.conversationId && !model.events.isEmpty { loaded = true }
        if loaded && showing && model.selected?.id == fixture.conversationId && model.events.isEmpty {
            blankSamples += 1
        }
        let state: [String: Any] = ["role": role, "loaded": loaded, "showing": showing,
            "events": model.events.count, "lastSeq": model.events.last?.seq ?? 0,
            "uniqueSeq": Set(model.events.compactMap(\.seq)).count,
            "selected": model.selected?.id ?? "", "blankSamples": blankSamples,
            "running": model.selected?.running ?? false,
            "smoothStreaming": UserDefaults.standard.bool(forKey: "chat.smoothStreaming"),
            "error": model.error ?? "", "failures": errors, "command": command]
        guard let bytes = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              bytes != previousState else { return }
        previousState = bytes
        try? bytes.write(to: output.appendingPathComponent("state.json"), options: .atomic)
    }

    private func image() throws -> CGImage {
        #if os(macOS)
        try save(NSApplication.shared.windows.map { ["title": $0.title,
            "visible": $0.isVisible, "width": $0.frame.width, "height": $0.frame.height] }, "windows.json")
        guard let view = NSApplication.shared.windows.first(where: {
            $0.isVisible && ($0.contentView?.bounds.height ?? 0) > 100
        })?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileReadUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw CocoaError(.fileReadUnknown) }
        return image
        #else
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: { $0.isKeyWindow }) else { throw CocoaError(.fileReadUnknown) }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let result = image.cgImage else { throw CocoaError(.fileReadUnknown) }
        return result
        #endif
    }

    private func texts(_ image: CGImage) async throws -> [String] {
        try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            // Keep visual assertions independent of Neural Engine model
            // compilation and the app's GPU rendering workload.
            guard let cpu = MLComputeDevice.allComputeDevices.first(where: {
                if case .cpu = $0 { return true }; return false
            }) else { throw CocoaError(.featureUnsupported) }
            request.setComputeDevice(cpu, for: .main)
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }.value
    }

    private func scrollGeometry() -> [[String: Any]] {
        #if os(macOS)
        var pending = NSApplication.shared.windows.filter(\.isVisible).compactMap(\.contentView)
        var result: [[String: Any]] = []
        while let view = pending.popLast() {
            pending.append(contentsOf: view.subviews)
            if let scroll = view as? NSScrollView, scroll.bounds.height > 100 {
                result.append(["type": String(describing: type(of: scroll)),
                    "offset": scroll.contentView.bounds.minY,
                    "contentHeight": scroll.documentView?.frame.height ?? 0,
                    "viewportHeight": scroll.contentView.bounds.height,
                    "insetBottom": scroll.contentInsets.bottom,
                    "flipped": scroll.documentView?.isFlipped ?? false])
            }
        }
        return result
        #else
        var pending = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter(\.isKeyWindow).flatMap(\.subviews)
        var result: [[String: Any]] = []
        while let view = pending.popLast() {
            pending.append(contentsOf: view.subviews)
            if let scroll = view as? UIScrollView, scroll.bounds.height > 100 {
                result.append(["type": String(describing: type(of: scroll)),
                    "offset": scroll.contentOffset.y, "contentHeight": scroll.contentSize.height,
                    "viewportHeight": scroll.bounds.height, "insetBottom": scroll.adjustedContentInset.bottom,
                    "tracking": scroll.isTracking, "dragging": scroll.isDragging,
                    "decelerating": scroll.isDecelerating])
            }
        }
        return result
        #endif
    }

    private func saveImage(_ image: CGImage, _ id: Int) throws {
        #if os(macOS)
        let encoded = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        #else
        let encoded = UIImage(cgImage: image).pngData()
        #endif
        guard let encoded else { throw CocoaError(.fileWriteUnknown) }
        try encoded.write(to: output.appendingPathComponent("snapshot-\(id).png"))
    }

    private func snapshot(_ id: Int, expected: String?) async throws -> [String] {
        var observed: [String] = []
        var lastCapture: CGImage?
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var attempt = 0
        repeat {
            try save(["id": id, "stage": "capture", "attempt": attempt], "snapshot-progress.json")
            let capture = try image()
            lastCapture = capture
            try saveImage(capture, id)
            try save(["id": id, "stage": "recognize", "attempt": attempt], "snapshot-progress.json")
            observed = try await texts(capture)
            try save(["id": id, "stage": "recognized", "attempt": attempt,
                "texts": observed, "scrolls": scrollGeometry()], "snapshot-progress.json")
            // Vision can insert spaces inside words and split a wrapped token
            // across observations. Keep matching every literal character.
            if let expected {
                let marker = expected.filter { !$0.isWhitespace }
                if observed.joined().filter({ !$0.isWhitespace }).contains(marker) {
                    return observed
                }
            } else {
                return observed
            }
            try await Task.sleep(for: .milliseconds(200))
            attempt += 1
        } while ContinuousClock.now < deadline
        if let lastCapture { try saveImage(lastCapture, id) }
        try save(observed, "missing-\(id).json")
        throw NSError(domain: "HistoryQA", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Missing visible text \(expected ?? ""); model holds \(model.events.count) events"])
    }

    func start() async {
        guard !started else { return }; started = true
        // Each fixture starts from the same presentation, independent of prior runs.
        ChatDetailPreference.shared.level = .standard
        UserDefaults.standard.set(true, forKey: "chat.smoothStreaming")
        BridgeObserver.report = { [weak self] method, _, error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in
                guard let self, self.errors.count < 100 else { return }
                self.errors.append(["method": method, "message": message])
            }
        }
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.noteState()
                try? await Task.sleep(for: .milliseconds(100))
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.readCommand()
                try? await Task.sleep(for: .milliseconds(100))
            }
        })
        do {
            if ProcessInfo.processInfo.environment["TOKENSTAT_NATIVE_HISTORY_RELAY"] == "1"
                && role != "desktop" {
                _ = try await Bridge.startLogin()
                _ = try await Bridge.pollLogin()
            }
            WorkSessionContext.shared.update(account: try await Bridge.account())
            let local = role == "desktop" && ProcessInfo.processInfo.environment["TOKENSTAT_NATIVE_HISTORY_DESKTOP_LOCAL"] == "1"
            await model.load(workspaceID: fixture.workspaceId, peer: local ? nil : fixture.hostKey, selectFirst: false)
            if let chat = model.chats.first(where: { $0.id == fixture.conversationId }) {
                await model.select(chat)
            }
        } catch { phase = error.localizedDescription }
        #if os(macOS)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
        noteState()
    }

    private func readCommand() async {
        guard let bytes = try? Data(contentsOf: output.appendingPathComponent("command.json")),
              let request = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let id = request["id"] as? Int, id > command else { return }
        command = id
        do {
            switch request["action"] as? String {
            case "hide": showing = false
            case "show": showing = true
            case "earlier": await model.loadEarlier()
            case "fold-steps":
                ChatDetailPreference.shared.level = .minimal
                model.setAllGroups(open: false)
            case "search-folded-step":
                guard let row = model.displayItems.first(where: {
                    if case let .tool(tool) = $0.kind { return tool.callId == "qa-search-first" }
                    return false
                }), var reference = model.currentReference else { throw CocoaError(.coderValueNotFound) }
                guard ChatTranscriptFold.owner(of: row.id, in: model.transcriptItems) != nil else {
                    throw NSError(domain: "HistoryQA", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Search fixture target was not folded"])
                }
                reference.anchor = row.id
                guard model.restoreSearchReadingPosition(reference) else { throw CocoaError(.coderInvalidValue) }
            case "snapshot": break
            case "new-chat-layout", "list-layout", "tab-layout": layoutPage = request["action"] as? String
            case "light": layoutScheme = .light
            case "dark": layoutScheme = .dark
            case "large-text": layoutType = .accessibility3
            case "extra-large-text": layoutType = .xxxLarge
            case "largest-text": layoutType = .accessibility5
            case "normal-text": layoutType = .large
            case "smooth-off": UserDefaults.standard.set(false, forKey: "chat.smoothStreaming")
            case "smooth-on": UserDefaults.standard.set(true, forKey: "chat.smoothStreaming")
            case "conversation": layoutPage = nil
            default: throw CocoaError(.coderInvalidValue)
            }
            try await Task.sleep(for: .milliseconds(200))
            let observed = try await snapshot(id, expected: request["expected"] as? String)
            try save(["id": id, "ok": true, "texts": observed], "result-\(id).json")
        } catch {
            try? save(["id": id, "ok": false, "error": error.localizedDescription], "result-\(id).json")
        }
        noteState()
    }
}

@main struct HistoryQAApp: App {
    @State private var session = HistorySession()
    @State private var account = AccountModel()
    #if os(iOS)
    @State private var navigation = ClientNavigationModel()
    @State private var connectivity = ConnectivityModel()
    @State private var layoutDraft = ChatStartDraft()
    @State private var teams = TeamStore(api: .live)
    #endif
    init() { AppFonts.register(); Bridge.connect() }
    var body: some Scene {
        WindowGroup("Encrypted chat history QA") {
            VStack(spacing: 0) {
                Text(session.phase).font(.caption).padding(6)
                Button(session.showing ? "Overview" : "Conversation") { session.showing.toggle() }
                    .padding(6)
                #if os(iOS)
                if session.layoutPage == "new-chat-layout" {
                    ChatStartPage(draft: layoutDraft, repositories: [],
                        hostPicker: AnyView(Menu("Choose a computer", systemImage: "desktopcomputer") {}),
                        allowsSend: false, showsEmptyComposer: true, requiresHostSelection: true,
                        repositoriesLoading: true, onAdd: {}, onSend: {})
                        .environment(navigation).environment(connectivity)
                } else if session.layoutPage == "list-layout" {
                    layoutLists.environment(teams).environment(navigation)
                } else {
                    phoneConversation
                }
                #else
                if session.showing, let _ = session.model.selected {
                    ChatView(model: session.model, workspaceID: session.fixture.workspaceId,
                        showingOverview: $session.overview, loadsWorkspace: false)
                } else { Text("History overview").frame(maxWidth: .infinity, maxHeight: .infinity) }
                #endif
            }
            #if os(macOS)
            .frame(width: 760, height: 820)
            #endif
            .background(Theme.background).tint(Theme.accent).preferredColorScheme(session.layoutScheme)
            .dynamicTypeSize(session.layoutType)
            .environment(\.layoutDirection, ProcessInfo.processInfo.environment["TOKENSTAT_NATIVE_HISTORY_RTL"] == "1" ? .rightToLeft : .leftToRight)
            .environment(account).task { await session.start() }
        }
    }

    #if os(iOS)
    @ViewBuilder private var phoneConversation: some View {
        if session.showing, let chat = session.model.selected {
            ClientChatThread(model: session.model, chatID: chat.id,
                folderName: "Native history", hostName: "Disposable host",
                availableWorkbenchWidth: session.layoutPage == "tab-layout" ? 500 : nil)
                .environment(navigation).environment(connectivity)
        } else { Text("History overview").frame(maxWidth: .infinity, maxHeight: .infinity) }
    }

    private var layoutLists: some View {
        let folder = try! JSONDecoder().decode(WorkspaceFolder.self, from: Data(#"{"id":"layout","path":"/Users/qa/git/tokenstat","name":"tokenstat","addedAtMs":0,"exists":true,"git":{"isRepo":true,"branch":"main","files":[],"ahead":0,"behind":0,"added":0,"removed":0,"partial":false}}"#.utf8))
        var chats = try! JSONDecoder().decode([ChatRecentConversation].self, from: Data(#"[{"id":"one","workspaceId":"layout","title":"Check chat spacing","backend":"codex"},{"id":"two","workspaceId":"layout","title":"Review the composer","backend":"claude"},{"id":"three","workspaceId":"layout","title":"Test expanded rows","backend":"codex"}]"#.utf8))
        for index in chats.indices {
            chats[index].lastMessageAtMs = Int64(Date().timeIntervalSince1970 * 1000) - Int64(index * 1000)
        }
        return NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Text("Repositories").font(ClientType.caption).padding()
                    ClientFolderRow(folder: folder, grouped: true)
                    ThemeRule().padding(.leading, Theme.Space.m)
                    ClientFolderRow(folder: folder, grouped: true)
                    ThemeRule().padding(.leading, Theme.Space.m)
                    ClientRecentChatsSection(peer: session.fixture.hostKey, hostName: "QA host",
                        folders: [folder], chats: chats, onNewChat: {}, grouped: true)
                }.cardSurface().padding(Theme.Space.m)
            }
        }
    }
    #endif
}
