// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Built by check-simulator.py with the actual native simulator sources.
import AppKit
import simd
import Metal

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
        let missing = SimulatorInventory(apple: { throw SimulatorSetupIssue.missingXcode }, android: { throw SimulatorSetupIssue.missingAndroidSDK })
        let missingSnapshot = try await missing.inspect(force: true)
        precondition(missingSnapshot.devices.isEmpty && missingSnapshot.setup.apple == .toolsMissing && missingSnapshot.setup.android == .toolsMissing)
        precondition(!missingSnapshot.setup.apple.isAuthoritative, "Missing tools cannot disprove an attach request's device identity")
        let noDevices = SimulatorInventory(apple: { [] }, android: { [] })
        let noDevicesSnapshot = try await noDevices.inspect(force: true)
        precondition(noDevicesSnapshot.setup.apple == .noDevices && noDevicesSnapshot.setup.android == .noDevices)
        precondition(noDevicesSnapshot.setup.apple.isAuthoritative)
        let mixed = SimulatorInventory(apple: { [phone] }, android: { throw SimulatorSetupIssue.missingAndroidSDK })
        let mixedSnapshot = try await mixed.inspect(force: true)
        precondition(mixedSnapshot.devices == [phone] && mixedSnapshot.setup.apple == .ready(1) && mixedSnapshot.setup.android == .toolsMissing,
                     "A missing optional platform must leave the installed platform usable")
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
        for tablet in [false, true] {
            for aspect: Float in [0.46, 0.75, 1.5] {
                let mesh = SimulatorDeviceMesh(aspect: aspect, tablet: tablet)
                precondition(!mesh.vertices.isEmpty && mesh.vertices.count % 3 == 0)
                precondition(abs(max(mesh.width, mesh.height) - 2.2) < 0.0001,
                             "Rotating a device must preserve its physical depth and long edge")
                let depth = mesh.vertices.map(\.position.z)
                precondition(depth.max()! - depth.min()! >= mesh.depth,
                             "The preview must be a solid volume, including edge and rear geometry")
                precondition(mesh.vertices.contains { $0.texture.z == 1 && $0.normal.z > 0 })
                precondition(mesh.vertices.contains { $0.normal.z < 0 })
                precondition(mesh.vertices.allSatisfy { v in
                    [v.position.x, v.position.y, v.position.z, v.normal.x, v.normal.y, v.normal.z].allSatisfy(\.isFinite)
                })
            }
        }
        var orbit = SimulatorOrbit()
        let original = orbit.rotation
        orbit.advance(velocity: [1, 0, 0], seconds: .pi * 2)
        precondition(abs(simd_dot(original.vector, orbit.rotation.vector)) > 0.999,
                     "Orbit must pass both poles and complete a full vertical turn")
        for _ in 0..<10_000 { orbit.advance(velocity: [0.8, -1.2, 0.3], seconds: 1 / 60) }
        precondition(abs(simd_length(orbit.rotation.vector) - 1) < 0.0001)
        _ = orbit.rotate(from: [1, 0, 0], to: [-1, 0, 0])
        precondition(orbit.rotation.vector.x.isFinite && orbit.rotation.vector.w.isFinite,
                     "Crossing an opposite arcball edge must not produce an invalid rotation")
        for orientation in 1...4 {
            let raw = CGSize(width: 1, height: 2.2)
            let displayed = SimulatorGeometry.displaySize(pixels: raw, orientation: orientation)
            let rotation = SimulatorOrbit.deviceRotation(orientation: orientation)
            for uv in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.8)] {
                let point = rotation.act(SIMD3<Float>(Float(uv.x - 0.5), Float((0.5 - uv.y) * raw.height), 0))
                let screen = CGPoint(x: Double(point.x) / displayed.width + 0.5, y: 0.5 - Double(point.y) / displayed.height)
                let sampled = SimulatorGeometry.devicePoint(screen, orientation: orientation)
                precondition(abs(sampled.x - uv.x) < 0.0001 && abs(sampled.y - uv.y) < 0.0001,
                             "Physical model rotation must preserve the flat display's texture mapping")
            }
        }
        let model = SimulatorDeviceModelView()
        if MTLCreateSystemDefaultDevice() != nil {
            precondition(model.isAvailable, "The native solid-device Metal shader must compile")
        } else { print("SKIP: native Metal rendering requires a GPU, geometry and orbit checks still ran") }
        model.setShape(pixels: CGSize(width: 1206, height: 2622), tablet: false)
        first.register(model)
        first.updateModelOrbit(orbit)
        let expandedModel = SimulatorDeviceModelView()
        first.register(expandedModel)
        precondition(expandedModel.orbit.rotation.vector == model.orbit.rotation.vector,
                     "Expanding a model must preserve the inspector's current orbit")
        model.clear()
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
        print("PASS: production simulator setup, discovery recovery, preferences, owner isolation, solid device mesh, full orbit, native Metal shader and H264 framing")
    }
}
