#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the Apple model coordinator with controlled WebKit callbacks."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/mac/Sources/Client/ClientChatModelWebView.swift').read_text()
start = source.index('    final class Coordinator:')
end = source.index('\n}\n', start)
coordinator = source[start:end].replace(
    'Bundle.main.url(forResource: "runtime", withExtension: nil)',
    'Runtime.directory',
)
stubs = r'''
import Foundation
@MainActor protocol WKNavigationDelegate {}
final class WKNavigation {}
enum WKNavigationActionPolicy { case allow, cancel }
struct Request { var url: URL? }
struct WKNavigationAction { var request: Request }
@MainActor enum Runtime { static var directory: URL? = URL(fileURLWithPath: "/runtime") }
@MainActor final class WKWebView {
    var scripts: [String] = []
    var completions: [(Any?, Error?) -> Void] = []
    func loadFileURL(_ file: URL, allowingReadAccessTo directory: URL) {}
    func evaluateJavaScript(_ code: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        scripts.append(code)
        if let completionHandler { completions.append(completionHandler) }
    }
}
'''
tests = r'''
@main struct Tests {
    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try! await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Coordinator did not finish within two seconds")
    }
    @MainActor static func settle() async {
        try! await Task.sleep(for: .milliseconds(100))
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8)
        let file = root.appendingPathComponent("model.obj")
        try valid.write(to: file)
        let bigFile = root.appendingPathComponent("large.obj")
        try Data(repeating: 0, count: 12 * 1024 * 1024 + 1).write(to: bigFile)
        for (label, data, url, succeeds) in [
            ("data", Optional(valid), nil as URL?, true),
            ("file", nil, Optional(file), true),
            ("empty", Optional(Data()), nil, false),
            ("oversized", Optional(Data(repeating: 0, count: 12 * 1024 * 1024 + 1)), nil, false),
            ("missing", nil, Optional(root.appendingPathComponent("missing.obj")), false),
            ("directory", nil, Optional(root), false),
            ("oversized file", nil, Optional(bigFile), false),
        ] {
            let web = WKWebView(), coordinator = Coordinator()
            var failures = 0
            coordinator.start(web: web, name: "model.obj", data: data, file: url, background: "#000000", onFailure: { failures += 1 })
            await settle()
            assert(web.scripts.isEmpty, "Wait for the document before sending bytes: \(label)")
            coordinator.webView(web, didFinish: nil)
            await waitUntil { failures > 0 || !web.scripts.isEmpty }
            assert(failures == (succeeds ? 0 : 1), "Expected failure state: \(label)")
            if succeeds {
                assert(web.scripts.count == 1 && web.scripts[0].contains(valid.base64EncodedString()), "Send the selected payload: \(label)")
                assert(web.scripts[0].hasPrefix("void "), "Do not return a JavaScript promise through evaluateJavaScript")
                coordinator.webView(web, didFinish: nil)
                assert(web.scripts.count == 1, "Do not send the same model twice")
            } else { assert(web.scripts.isEmpty, "Invalid bytes must not reach WebKit") }
            coordinator.dispose()
        }
        for failure in ["navigation", "provisional", "process", "javascript"] {
            let web = WKWebView(), oldWeb = WKWebView(), coordinator = Coordinator()
            var failures = 0
            coordinator.start(web: web, name: "model.obj", data: valid, file: nil, background: "#000000", onFailure: { failures += 1 })
            coordinator.webView(web, didFinish: nil)
            await waitUntil { !web.scripts.isEmpty }
            assert(web.scripts.count == 1, "Payload also loads when the document finishes first")
            let error = NSError(domain: "fixture", code: 1)
            coordinator.webView(oldWeb, didFail: nil, withError: error)
            coordinator.webView(oldWeb, didFailProvisionalNavigation: nil, withError: error)
            coordinator.webViewWebContentProcessDidTerminate(oldWeb)
            assert(failures == 0, "Ignore callbacks from another surface")
            switch failure {
            case "navigation": coordinator.webView(web, didFail: nil, withError: error)
            case "provisional": coordinator.webView(web, didFailProvisionalNavigation: nil, withError: error)
            case "process": coordinator.webViewWebContentProcessDidTerminate(web)
            default: web.completions[0](nil, error)
            }
            assert(failures == 1, "Show failure for \(failure)")
            coordinator.webViewWebContentProcessDidTerminate(web)
            assert(failures == 1, "Report failure once")
            coordinator.dispose()
            web.completions[0](nil, error)
            assert(failures == 1, "Ignore JavaScript completion after disposal")
        }
        do {
            let web = WKWebView(), coordinator = Coordinator()
            var failures = 0
            coordinator.start(web: web, name: "model.obj", data: valid, file: nil, background: "#000000", onFailure: { failures += 1 })
            coordinator.dispose()
            await settle()
            coordinator.webView(web, didFinish: nil)
            assert(failures == 0 && web.scripts.count == 1 && web.scripts[0].contains("dispose"), "A disposed load must not publish")
        }
        Runtime.directory = nil
        let web = WKWebView(), coordinator = Coordinator()
        var failures = 0
        coordinator.start(web: web, name: "model.obj", data: valid, file: nil, background: "#000000", onFailure: { failures += 1 })
        assert(failures == 0, "Do not update SwiftUI state during makeView")
        await waitUntil { failures > 0 }
        assert(failures == 1, "A missing runtime must show a failure")
        print("Model preview payload, navigation, failure and disposal checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-model-preview-') as directory:
    path = Path(directory)
    (path / 'Tests.swift').write_text(stubs + coordinator + tests)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Tests.swift'), '-o', str(path / 'tests')], check=True)
    subprocess.run([str(path / 'tests')], check=True)
