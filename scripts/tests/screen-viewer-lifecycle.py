#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compile the actual viewer model against inert transport/audio fixtures.

No screen capture, clipboard access, network, permissions or application launch.
The enclosing SwiftUI view and hardware decoder are deliberately excluded.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / 'apps/mac/Sources/Features/Machines/ScreenViewerView.swift').read_text()
model = source[source.index('@MainActor @Observable\nprivate final class ScreenViewerModel'):source.index('@MainActor\nprivate final class ScreenAudioPlayer')]
model = model.replace('private final class ScreenViewerModel', 'final class ScreenViewerModel')
capture = (ROOT / 'apps/mac/Sources/Features/Machines/ScreenCaptureCoordinator.swift').read_text()
model += capture[capture.index('private actor ScreenEncoderChanges'):capture.index('private final class ScreenVideoEncoder:')]
stubs = r'''
import Foundation
import Observation
import CryptoKit
import AppKit

enum L10n { static func text(_ key: String, _ args: String...) -> String { key } }
enum ScreenQualityChoice: String { case auto; var wire: String? { nil } }
struct ScreenDisplay: Codable { var id: UInt32; var name: String; var width: Int; var height: Int }
struct ScreenMetadata: Codable { var type: String; var displays: [ScreenDisplay]?; var selected: UInt32?; var text: String? }
struct ScreenEncodedFrame { var width = 10; var height = 10; init?(_ data: Data) {} }
@MainActor final class ScreenH264Decoder { var decoded = 0; func reset() {}; func decode(_ value: ScreenEncodedFrame) -> Bool { decoded += 1; return true } }
@MainActor final class ScreenAudioPlayer { func reset() {}; func play(_ data: Data) {} }
struct ScreenCapability { var token = "capability" }
struct ScreenViewerSession { var id: String; var sessionId: String? = "host"; var transport = "direct"; var control = false }
struct ScreenViewerRead { var metadata: String?; var frame: String?; var audio: String?; var active = true; var error: String? }
struct ScreenTransferOpen { var offset: UInt64; var chunkBytes: Int }
struct ScreenTransferChunk { var offset: UInt64 }
struct ScreenTransferSaved {}
struct ScreenTransferCancelled {}
struct Identity { var key = "device" }
struct Access { var granted: Bool? = false }
struct Notice { var signedIn = false; var enabled = false; var sent = 0 }
@MainActor enum Bridge {
    static var holdOpen = false
    static var openWaiter: CheckedContinuation<ScreenViewerSession, Never>?
    static var reads: [String: CheckedContinuation<ScreenViewerRead, Never>] = [:]
    static var closed: [String] = []
    static var nextID = "initial"
    static var changed: [Int] = []
    static var changeWaiter: CheckedContinuation<Void, Never>?
    static func machineIdentity() async throws -> Identity { Identity() }
    static func onPeer<T>(_ peer: String, _ method: String, _ params: [String: Any], as: T.Type) async throws -> T { ScreenCapability() as! T }
    static func screenViewerOpen(peer: String, capability: String, control: Bool, quality: ScreenQualityChoice) async throws -> ScreenViewerSession {
        if holdOpen { return await withCheckedContinuation { openWaiter = $0 } }
        return ScreenViewerSession(id: nextID, control: control)
    }
    static func screenViewerRead(id: String) async throws -> ScreenViewerRead { await withCheckedContinuation { reads[id] = $0 } }
    static func screenViewerClose(id: String) async { closed.append(id) }
    static func screenViewerInput(id: String, data: Data) async throws {}
    static func askScreenAccess(peer: String, control: Bool) async throws -> Access { Access() }
    static func requestScreenAccess() async throws -> Notice { Notice() }
    static func setScreenQuality(peer: String, sessionID: String, capability: String, quality: String) async throws {}
    static func setScreenControl(peer: String, sessionID: String, capability: String, control: Bool) async throws {}
}
@main struct LifecycleTests {
    @MainActor static func main() async throws {
        func waitFor(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
            preconditionFailure("timed out")
        }
        Bridge.holdOpen = true
        let closed = ScreenViewerModel()
        let opening = Task { await closed.start(peer: "peer", tier: "legend", control: false) }
        try await waitFor { Bridge.openWaiter != nil }
        closed.stop()
        Bridge.openWaiter?.resume(returning: ScreenViewerSession(id: "late-open"))
        Bridge.openWaiter = nil
        await opening.value
        assert(Bridge.closed.contains("late-open"), "late open must be closed after leaving viewer")
        assert(Bridge.reads["late-open"] == nil, "late open must never start reading")

        Bridge.holdOpen = false
        Bridge.nextID = "old"
        let switching = ScreenViewerModel()
        await switching.start(peer: "peer", tier: "legend", control: false)
        try await waitFor { Bridge.reads["old"] != nil }
        Bridge.nextID = "new"
        await switching.start(peer: "peer", tier: "legend", control: false)
        try await waitFor { Bridge.reads["new"] != nil }
        Bridge.reads.removeValue(forKey: "old")?.resume(returning: ScreenViewerRead(frame: Data([1]).base64EncodedString()))
        try await Task.sleep(for: .milliseconds(30))
        assert(switching.decoder.decoded == 0, "old session cannot publish into new decoder")
        assert(switching.state == .connecting)
        switching.stop()
        Bridge.reads.removeValue(forKey: "new")?.resume(returning: ScreenViewerRead(active: false))
        try await Task.sleep(for: .milliseconds(30))
        let changes = ScreenEncoderChanges()
        let first = Task {
            try await changes.perform {
                await MainActor.run { Bridge.changed.append(1) }
                await withCheckedContinuation { waiter in Task { @MainActor in Bridge.changeWaiter = waiter } }
                await MainActor.run { Bridge.changed.append(2) }
            }
        }
        try await waitFor { Bridge.changeWaiter != nil }
        let second = Task { try await changes.perform { await MainActor.run { Bridge.changed.append(3) } } }
        try await Task.sleep(for: .milliseconds(30))
        assert(Bridge.changed == [1], "reconfiguration cannot overlap across suspension")
        Bridge.changeWaiter?.resume()
        Bridge.changeWaiter = nil
        try await first.value
        try await second.value
        assert(Bridge.changed == [1, 2, 3])
        print("Screen viewer late-open cleanup, stale-read isolation and encoder serialization passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-screen-review-') as temp:
    folder = Path(temp)
    swift = folder / 'ScreenViewerLifecycle.swift'
    swift.write_text(stubs + '\n' + model)
    executable = folder / 'ScreenViewerLifecycle'
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(swift), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
