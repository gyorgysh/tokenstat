#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Generate a Mac project using the real desktop views and synthetic chat data.

Run mac-chat-demo.py in another terminal first, then run this script and:
    xcodegen generate --spec target/mac-chat-demo/project.json
    xcodebuild -project target/mac-chat-demo/DesktopDemo.xcodeproj \
        -scheme DesktopDemo -configuration Debug \
        -derivedDataPath target/mac-chat-demo/build build

The generated app uses a separate preferences domain and a local fixture
socket. Generated projects, copied sources and build output stay in target/.

Use --live-projects for product captures with the existing tokenstat host:
real project names, Git status, history, files and GitHub integration remain
available. Only haynakoo is omitted from this capture app's project list;
the installed app and registered workspace list are unchanged.
This variant is generated in target/mac-chat-demo-live, separate from the
synthetic fixture and its project.
"""
import json
import socket
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / ('target/mac-chat-demo-live' if '--live-projects' in sys.argv else 'target/mac-chat-demo')
OUT.mkdir(parents=True, exist_ok=True)
fixture = OUT / 'fixture.json'
if '--live-projects' in sys.argv:
    fixture.write_text(json.dumps({'socket': str(Path.home() / 'Library/Application Support/ai.tokenstat.tokenstat/host.sock')}))
if not fixture.exists():
    raise SystemExit('Start scripts/tests/mac-chat-demo.py first.')
try:
    endpoint = json.loads(fixture.read_text())['socket']
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
        probe.settimeout(1)
        probe.connect(endpoint)
except (OSError, ValueError, KeyError) as error:
    raise SystemExit('The demo fixture is not running. Start scripts/tests/mac-chat-demo.py first.') from error

def replace_member(source, signature, replacement):
    start = source.index(signature)
    brace = source.index('{\n', start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[:start] + replacement + source[end:]

bridge = (ROOT / 'apps/mac/Sources/Bridge/Bridge.swift').read_text()
bridge = replace_member(bridge, '    static func connect() {', '''    static func connect() {
        let url = Bundle.main.url(forResource: "fixture", withExtension: "json")!
        let fixture = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: String]
        adopt(Route(transport: SocketTransport(path: fixture["socket"]!), isHosted: true))
    }''')
if '--live-projects' in sys.argv:
    bridge = replace_member(bridge, '    static func workspaces() async throws -> [WorkspaceFolder] {', '''    static func workspaces() async throws -> [WorkspaceFolder] {
        let folders = try await background("workspace.list", as: [WorkspaceFolder].self)
        return folders.filter { $0.name != "haynakoo" }
    }''')
(OUT / 'Bridge.swift').write_text(bridge)
launch = (ROOT / 'apps/mac/Sources/App/LaunchState.swift').read_text()
launch = replace_member(launch, '    func prepare() async {', '''    func prepare() async {
        await BridgeLaunch.wait()
        withAnimation(nil) { hostReady = true }
    }''')
(OUT / 'LaunchState.swift').write_text(launch)
capture = (ROOT / 'apps/mac/Sources/App/DebugUIHooks.swift').read_text()
capture = replace_member(capture, '    private static func capture(to path: String) {', '''    private static func capture(to path: String) {
        guard let window = shellWindow, let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Capture the app and its native window buttons without compositor overlays.
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    if let button = window.standardWindowButton(kind) {
                        button.cell?.draw(withFrame: view.convert(button.bounds, from: button), in: view)
                    }
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }''')
(OUT / 'DebugUIHooks.swift').write_text(capture)
(OUT / 'DesktopDemoApp.swift').write_text('''// Synthetic fixture entry point; never included in a shipping target.
import SwiftUI
import AppKit
@main struct DesktopDemoApp: App {
    init() {
        UserDefaults.standard.set(380.0, forKey: "shell.sidebarWidth")
        UserDefaults.standard.set(400.0, forKey: "shell.inspectorWidth")
        AppFonts.register(); BridgeLaunch.begin(); DebugUIHooks.install()
    }
    var body: some Scene {
        WindowGroup("tokenstat") {
            RootView().frame(minWidth: RootView.minimumContentWidth, minHeight: RootView.minimumContentHeight)
                .preferredColorScheme(Bundle.main.object(forInfoDictionaryKey: "DemoLight") as? Bool == true ? .light : .dark)
                .task {
                    TranscriptProbe.shared.startRecording()
                    try? await Task.sleep(for: .seconds(90))
                    TranscriptProbe.shared.finishRecording()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1684, height: 1083)
    }
}
''')
sources = [
    {'path': str(ROOT / 'apps/mac/Sources'), 'excludes': ['Bridge/Bridge.swift', 'App/LaunchState.swift', 'App/DebugUIHooks.swift']},
    {'path': str(OUT / 'Bridge.swift')}, {'path': str(OUT / 'LaunchState.swift')},
    {'path': str(OUT / 'DesktopDemoApp.swift')},
    {'path': str(OUT / 'DebugUIHooks.swift')},
    {'path': str(ROOT / 'apps/localization'), 'type': 'folder', 'buildPhase': 'resources'},
    {'path': str(ROOT / 'apps/mac/Resources'), 'buildPhase': 'resources'},
    {'path': str(ROOT / 'apps/mac/BrandResources'), 'buildPhase': 'resources'},
    {'path': str(fixture), 'buildPhase': 'resources'},
]
project = {'name': 'DesktopDemo', 'options': {'deploymentTarget': {'macOS': '14.0'}},
           'packages': {'SwiftTerm': {'url': 'https://github.com/migueldeicaza/SwiftTerm.git', 'exactVersion': '1.11.2'}},
           'settings': {'base': {'SWIFT_VERSION': '5.0', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG WORKBENCH_QA',
                                 'CODE_SIGN_IDENTITY': '-', 'MARKETING_VERSION': '1.7.0', 'CURRENT_PROJECT_VERSION': '1'}},
           'targets': {'DesktopDemo': {'type': 'application', 'platform': 'macOS', 'sources': sources,
                                      'dependencies': [{'framework': str(ROOT / 'apps/mac/Vendor/TokenstatFFI.xcframework'), 'embed': False}, {'package': 'SwiftTerm'}],
                                      'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'ai.tokenstat.desktopdemo',
                                                            'PRODUCT_MODULE_NAME': 'Tokenstat', 'GENERATE_INFOPLIST_FILE': 'YES'}}}}}
(OUT / 'project.json').write_text(json.dumps(project, indent=2))
print(OUT / 'project.json')
