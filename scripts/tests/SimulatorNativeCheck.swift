// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Built by check-simulator.py with the actual native simulator sources.
import AppKit

private actor SimulatorDiscoveryFixture {
    enum Failure: Error { case temporarilyUnavailable }
    var appleDevices: [SimulatorDevice]
    var androidDevices: [SimulatorDevice]
    var failApple = false
    var failAndroid = false
    init(apple: [SimulatorDevice], android: [SimulatorDevice]) { appleDevices = apple; androidDevices = android }
    func setFailures(apple: Bool, android: Bool) { failApple = apple; failAndroid = android }
    func removeAndroid() { androidDevices = [] }
    func apple() throws -> [SimulatorDevice] { if failApple { throw Failure.temporarilyUnavailable }; return appleDevices }
    func android() throws -> [SimulatorDevice] { if failAndroid { throw Failure.temporarilyUnavailable }; return androidDevices }
}

private actor SimulatorSnapshotFixture {
    var devices: [SimulatorDevice] = []
    var started = false
    private var blocked: CheckedContinuation<Void, Never>?
    func discover() async -> [SimulatorDevice] {
        let snapshot = devices
        if !started {
            started = true
            await withCheckedContinuation { blocked = $0 }
        }
        return snapshot
    }
    func replace(with devices: [SimulatorDevice]) { self.devices = devices; blocked?.resume(); blocked = nil }
}

@main struct SimulatorNativeCheck {
    @MainActor static func main() async throws {
        let domain = "ai.tokenstat.simulator-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let phone = SimulatorDevice(id: "00000000-0000-0000-0000-000000000001", name: "Phone", runtime: "iOS 27.0", platform: .ios, deviceType: "iPhone", isBooted: false)
        let tablet = SimulatorDevice(id: "00000000-0000-0000-0000-000000000002", name: "Tablet", runtime: "iOS 27.0", platform: .ios, deviceType: "iPad", isBooted: true)
        let first = SimulatorSession(preferenceKey: "first", defaults: defaults)
        first.devices = [phone, tablet]
        first.selectedID = phone.id
        first.defaultID = tablet.id
        first.toggleFavorite(phone.id)
        first.followsAgents = false
        precondition(first.orderedDevices.first?.id == phone.id, "Favorite devices must lead the picker")
        let reopened = SimulatorSession(preferenceKey: "first", defaults: defaults)
        precondition(reopened.selectedID == tablet.id && reopened.defaultID == tablet.id)
        precondition(reopened.favorites == [phone.id] && !reopened.followsAgents)
        let other = SimulatorSession(preferenceKey: "other-owner", defaults: defaults)
        precondition(other.selectedID == nil && other.defaultID == nil && other.favorites.isEmpty && other.followsAgents,
                     "Simulator preferences crossed an owner boundary")
        first.attach("unavailable")
        precondition(!first.busy && first.attachedID == nil, "Missing devices must never start a command")
        first.detach(); first.setActive(false)
        precondition(first.attachedID == nil && !first.busy && !first.hasFrame)

        let android = SimulatorDevice(id: "android:qa", name: "Android", runtime: "Android", platform: .android, deviceType: "phone", isBooted: true, serial: "emulator-5554", transportID: 7)
        let discovery = SimulatorDiscoveryFixture(apple: [tablet], android: [android])
        let inventory = SimulatorInventory(apple: { try await discovery.apple() }, android: { try await discovery.android() })
        let initial = try await inventory.load(force: true)
        let live = SimulatorSession(preferenceKey: "live-discovery", defaults: defaults, inventory: inventory)
        live.attachedID = tablet.id
        var boots = SimulatorBootTracker()
        precondition(boots.observe(initial, follows: true) == nil)
        for failures in [(true, false), (false, false), (false, true), (false, false)] {
            await discovery.setFailures(apple: failures.0, android: failures.1)
            let devices = try await inventory.load(force: true)
            precondition(devices == initial, "Transient discovery failure removed a live device")
            await live.refresh(force: true)
            precondition(live.attachedID == tablet.id, "Discovery failure detached a live session")
            precondition(boots.observe(devices, follows: true) == nil, "Discovery recovery was mistaken for an agent boot")
        }
        await discovery.removeAndroid()
        let removed = try await inventory.load(force: true)
        precondition(removed == [tablet], "A successful empty inventory must still remove stopped devices")
        let recoveringSource = SimulatorDiscoveryFixture(apple: [phone], android: [])
        await recoveringSource.setFailures(apple: true, android: false)
        let recoveringInventory = SimulatorInventory(apple: { try await recoveringSource.apple() }, android: { [] })
        let recovering = SimulatorSession(preferenceKey: "recovering-discovery", defaults: defaults, inventory: recoveringInventory)
        await recovering.refresh(force: true)
        precondition(recovering.devices.isEmpty && recovering.error != nil)
        await recoveringSource.setFailures(apple: false, android: false)
        await recovering.refresh(force: true)
        precondition(recovering.devices == [phone] && recovering.error == nil, "Successful discovery left its unavailable-tools error visible")
        recovering.error = "An unrelated device control failed"
        await recovering.refresh(force: true)
        precondition(recovering.error != nil, "Discovery must not clear unrelated device errors")
        let snapshot = SimulatorSnapshotFixture()
        let freshInventory = SimulatorInventory(apple: { await snapshot.discover() }, android: { [] })
        let oldFlight = Task { try await freshInventory.load() }
        while !(await snapshot.started) { await Task.yield() }
        let force = Task { try await freshInventory.load(force: true) }
        try await Task.sleep(for: .milliseconds(30))
        await snapshot.replace(with: [phone])
        let oldSnapshot = try await oldFlight.value, freshSnapshot = try await force.value
        precondition(oldSnapshot.isEmpty && freshSnapshot == [phone], "An explicit attach reused a discovery started before its device existed")

        _ = NSApplication.shared
        let screen = SimulatorScreenNSView(frame: .zero)
        screen.setFrameSize(CGSize(width: 320, height: 640))
        precondition(screen.subviews.first?.frame.size == screen.bounds.size,
                     "The native display did not resize when mounted in another window")

        var parser = SimulatorAnnexBReader()
        let stream = Data([0,0,0,1,0x67,0x11,0,0,1,0x68,0x22,0,0,0,1,0x65,0x80,0x33,0,0,1,9])
        var units: [Data] = []
        for byte in stream { units.append(contentsOf: parser.append(Data([byte]))) }
        precondition(units == [Data([0x67,0x11]),Data([0x68,0x22]),Data([0x65,0x80,0x33])],
                     "H264 start codes split across reads lost or merged a picture")
        precondition(parser.drain() == [Data([9])], "A still stream lost its final NAL")
        precondition(parser.drain().isEmpty, "Quiet flushing repeated an already delivered NAL")
        precondition(parser.append(Data([0,0,1,0x65,0x80])).isEmpty)
        precondition(parser.drain() == [Data([0x65,0x80])], "A resumed stream lost its first picture")
        var recovery = SimulatorAnnexBReader()
        _ = recovery.append(Data(repeating: 0xff, count: 17 * 1024 * 1024))
        precondition(recovery.append(Data([0,0,1,0x67,1,0,0,1,0x68,2])).first == Data([0x67,1]),
                     "Oversized video input could not recover at a fresh start code")

        do {
            _ = try NativeSimulatorConnection(developerDirectory: "/missing-tokenstat-test-xcode/Developer", deviceID: phone.id)
            preconditionFailure("Missing Xcode unexpectedly attached a device")
        } catch { precondition(!error.localizedDescription.isEmpty) }
        print("PASS: production simulator preferences, owner isolation, detach, incremental H264 framing and missing-Xcode recovery")
    }
}
