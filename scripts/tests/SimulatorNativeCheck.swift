// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Built by check-simulator.py with the actual native simulator sources.
import AppKit

@main struct SimulatorNativeCheck {
    @MainActor static func main() throws {
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
