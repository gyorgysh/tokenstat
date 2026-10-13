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
"""
import json
import socket
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'target/mac-chat-demo'
OUT.mkdir(parents=True, exist_ok=True)
fixture = OUT / 'fixture.json'
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
(OUT / 'Bridge.swift').write_text(bridge)
launch = (ROOT / 'apps/mac/Sources/App/LaunchState.swift').read_text()
launch = replace_member(launch, '    func prepare() async {', '''    func prepare() async {
        await BridgeLaunch.wait()
        withAnimation(nil) { hostReady = true }
    }''')
(OUT / 'LaunchState.swift').write_text(launch)
(OUT / 'DesktopDemoApp.swift').write_text('''// Synthetic fixture entry point; never included in a shipping target.
import SwiftUI
import AppKit
@main struct DesktopDemoApp: App {
    init() { AppFonts.register(); BridgeLaunch.begin() }
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
        .defaultSize(width: 1600, height: 1000)
    }
}
''')
sources = [
    {'path': str(ROOT / 'apps/mac/Sources'), 'excludes': ['Bridge/Bridge.swift', 'App/LaunchState.swift']},
    {'path': str(OUT / 'Bridge.swift')}, {'path': str(OUT / 'LaunchState.swift')},
    {'path': str(OUT / 'DesktopDemoApp.swift')},
    {'path': str(ROOT / 'apps/localization'), 'type': 'folder', 'buildPhase': 'resources'},
    {'path': str(ROOT / 'apps/mac/Resources'), 'buildPhase': 'resources'},
    {'path': str(ROOT / 'apps/mac/BrandResources'), 'buildPhase': 'resources'},
    {'path': str(fixture), 'buildPhase': 'resources'},
]
project = {'name': 'DesktopDemo', 'options': {'deploymentTarget': {'macOS': '14.0'}},
           'packages': {'SwiftTerm': {'url': 'https://github.com/migueldeicaza/SwiftTerm.git', 'exactVersion': '1.11.2'}},
           'settings': {'base': {'SWIFT_VERSION': '5.0', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG WORKBENCH_QA',
                                 'CODE_SIGN_IDENTITY': '-', 'MARKETING_VERSION': '1.6.1', 'CURRENT_PROJECT_VERSION': '1'}},
           'targets': {'DesktopDemo': {'type': 'application', 'platform': 'macOS', 'sources': sources,
                                      'dependencies': [{'framework': str(ROOT / 'apps/mac/Vendor/TokenstatFFI.xcframework'), 'embed': False}, {'package': 'SwiftTerm'}],
                                      'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'ai.tokenstat.desktopdemo',
                                                            'PRODUCT_MODULE_NAME': 'Tokenstat', 'GENERATE_INFOPLIST_FILE': 'YES'}}}}}
(OUT / 'project.json').write_text(json.dumps(project, indent=2))
print(OUT / 'project.json')
